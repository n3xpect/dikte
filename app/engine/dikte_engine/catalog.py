"""Model catalog (built-in + custom), HF repo metadata and the sizes cache."""

from __future__ import annotations

import json
import re
import threading
from dataclasses import asdict, dataclass
from pathlib import Path

WHISPER = "mlx-whisper"
CUSTOM_PREFIX = "hf:"
_REPO_RE = re.compile(r"^[A-Za-z0-9][\w.-]*/[\w.-]+$")


@dataclass(frozen=True)
class ModelSpec:
    id: str
    label: str
    repo: str
    kind: str  # WHISPER (the only supported kind)
    custom: bool = False
    recommended: bool = False
    note: str = ""
    est_weights_bytes: int | None = None  # used for ram_bytes until HF sizes are known


BUILTIN: list[ModelSpec] = [
    ModelSpec("large-v3", "Whisper large-v3", "mlx-community/whisper-large-v3-mlx", WHISPER,
              recommended=True, note="WER 7,9% · terim 96% · ~0,8 sn",
              est_weights_bytes=3_083_520_416),
    ModelSpec("turbo", "Whisper large-v3 turbo", "mlx-community/whisper-large-v3-turbo", WHISPER,
              note="WER 8,3% · ~0,5 sn", est_weights_bytes=1_613_977_612),
]


@dataclass(frozen=True)
class RepoFile:
    path: str
    size: int
    etag: str  # cache blob name: LFS sha256, else git blob id
    lfs: bool


@dataclass(frozen=True)
class RepoFiles:
    sha: str
    files: list[RepoFile]

    @property
    def total(self) -> int:
        return sum(f.size for f in self.files)

    @property
    def weights(self) -> int:
        return sum(f.size for f in self.files if f.path.endswith((".npz", ".safetensors")))


class RepoNotFound(Exception):
    pass


class UnsupportedModel(Exception):
    pass


class NetworkError(Exception):
    pass


def custom_id(repo: str) -> str:
    return CUSTOM_PREFIX + repo


def valid_repo(repo: str) -> bool:
    return bool(_REPO_RE.match(repo)) and ".." not in repo


# --------------------------------------------------------------------------- HF (blocking)

def fetch_repo_files(repo: str) -> RepoFiles:
    """File list with exact sizes from the Hub. Blocking; run in an executor."""
    from huggingface_hub import HfApi
    from huggingface_hub.errors import (
        GatedRepoError,
        RepositoryNotFoundError,
        RevisionNotFoundError,
    )

    try:
        info = HfApi().model_info(repo, files_metadata=True, timeout=20)
    except (RepositoryNotFoundError, RevisionNotFoundError, GatedRepoError) as e:
        raise RepoNotFound(repo) from e
    except Exception as e:  # connection errors, HTTP 5xx, ...
        raise NetworkError(str(e)) from e
    files = []
    for s in info.siblings or []:
        if s.size is None:
            continue
        lfs = s.lfs is not None
        etag = s.lfs.sha256 if s.lfs is not None else s.blob_id
        if etag:
            files.append(RepoFile(s.rfilename, int(s.size), etag, lfs))
    if not info.sha:
        raise NetworkError(f"{repo}: no commit sha")
    return RepoFiles(info.sha, files)


def detect_kind(repo: str, rf: RepoFiles) -> str:
    """mlx-whisper: whisper config + weights.npz|weights.safetensors (the only supported kind)."""
    from huggingface_hub import hf_hub_url
    from huggingface_hub.utils import get_session

    names = {f.path for f in rf.files}
    if "config.json" not in names:
        raise UnsupportedModel("config.json yok")
    try:
        r = get_session().get(hf_hub_url(repo, "config.json", revision=rf.sha), timeout=20,
                              follow_redirects=True)
        r.raise_for_status()
        config = r.json()
    except Exception as e:
        raise NetworkError(str(e)) from e
    if not isinstance(config, dict):
        raise UnsupportedModel("config.json okunamadı")
    if ("n_mels" in config or "n_audio_state" in config) and (
            names & {"weights.npz", "weights.safetensors"}):
        return WHISPER
    raise UnsupportedModel(f"model_type={config.get('model_type')!r}")


# --------------------------------------------------------------------------- persistence

class SizesCache:
    """<data-dir>/engine/sizes.json: repo -> RepoFiles, so offline listing keeps sizes."""

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.Lock()
        self._data: dict[str, RepoFiles] = {}
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            for repo, v in raw.items():
                self._data[repo] = RepoFiles(v["sha"], [RepoFile(**f) for f in v["files"]])
        except (OSError, ValueError, KeyError, TypeError):
            pass

    def get(self, repo: str) -> RepoFiles | None:
        return self._data.get(repo)

    def put(self, repo: str, rf: RepoFiles) -> None:
        with self._lock:
            self._data[repo] = rf
            out = {r: {"sha": v.sha, "files": [asdict(f) for f in v.files]}
                   for r, v in self._data.items()}
            _atomic_write(self.path, json.dumps(out, indent=1))


def load_custom(path: Path) -> list[ModelSpec]:
    try:
        items = json.loads(path.read_text(encoding="utf-8"))["models"]
        return [ModelSpec(custom_id(m["repo"]), m.get("label") or m["repo"].split("/")[-1],
                          m["repo"], m["kind"], custom=True) for m in items
                if m.get("kind") == WHISPER and valid_repo(m.get("repo", ""))]
    except (OSError, ValueError, KeyError, TypeError):
        return []


def save_custom(path: Path, specs: list[ModelSpec]) -> None:
    items = [{"repo": s.repo, "kind": s.kind, "label": s.label} for s in specs if s.custom]
    _atomic_write(path, json.dumps({"models": items}, indent=1))


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
