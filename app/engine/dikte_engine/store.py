"""Models on disk (Hugging Face cache layout): completeness, sizes, resumable download, delete.

huggingface_hub 2.x discards partial files when a download is interrupted, so downloads are
done here with HTTP Range requests into `blobs/<etag>.incomplete`, then moved into place
with the regular cache layout (refs/main, snapshots/<sha>/<file> -> ../../blobs/<etag>).
Models fetched by huggingface_hub itself (incl. its shared xet blob store) are read as-is.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import shutil
from collections.abc import Callable
from pathlib import Path
from urllib.parse import quote

import aiohttp

from .catalog import WHISPER, ModelSpec, RepoFile, RepoFiles

log = logging.getLogger("dikte.store")

CHUNK = 1 << 20
GUARD_EVERY = 200 * 1024 * 1024  # re-check the disk rule every ~200 MB


class DiskGuard(Exception):
    """Raised by the guard callback to stop a download (disk rule violated)."""


class Store:
    def __init__(self, models_dir: Path):
        self.models_dir = models_dir

    def repo_dir(self, repo: str) -> Path:
        return self.models_dir / ("models--" + repo.replace("/", "--"))

    def disk_free(self) -> int:
        # statvfs f_bavail: strictly free space, APFS purgeable space not included
        return shutil.disk_usage(self.models_dir.resolve()).free

    def snapshot_dir(self, repo: str) -> Path | None:
        rd = self.repo_dir(repo)
        try:
            sha = (rd / "refs" / "main").read_text().strip()
            if sha and (rd / "snapshots" / sha).is_dir():
                return rd / "snapshots" / sha
        except OSError:
            pass
        snaps = [p for p in (rd / "snapshots").glob("*") if p.is_dir()]
        return max(snaps, key=lambda p: p.stat().st_mtime) if snaps else None

    def local_path(self, spec: ModelSpec) -> Path | None:
        """Snapshot dir if every file the backend needs is present, else None."""
        path = self.snapshot_dir(spec.repo)
        if path is None or not (path / "config.json").exists():
            return None
        if spec.kind == WHISPER:
            ok = (path / "weights.safetensors").exists() or (path / "weights.npz").exists()
        else:
            ok = False
        return path if ok else None

    def downloaded_bytes(self, repo: str) -> int:
        """Bytes of this repo on disk: complete files (each blob once) + partial downloads."""
        rd = self.repo_dir(repo)
        seen: set[str] = set()
        total = 0
        for root, _dirs, files in os.walk(rd / "snapshots"):
            for name in files:
                try:
                    real = os.path.realpath(os.path.join(root, name))
                    if real not in seen:
                        seen.add(real)
                        total += os.stat(real).st_size
                except OSError:
                    pass
        for part in (rd / "blobs").glob("*.incomplete"):
            try:
                total += part.stat().st_size
            except OSError:
                pass
        return total

    def weights_on_disk(self, repo: str) -> int:
        snap = self.snapshot_dir(repo)
        if snap is None:
            return 0
        return sum(p.stat().st_size for p in snap.rglob("*")
                   if p.name.endswith((".npz", ".safetensors")) and p.exists())

    def delete(self, repo: str) -> None:
        """Remove the repo (complete and partial files) and shared xet blobs only it used."""
        rd = self.repo_dir(repo)
        targets: list[Path] = []
        try:
            from huggingface_hub.utils import _shared_blobs as sb

            for blob in (rd / "blobs").glob("*"):
                if t := sb.shared_blob_target(blob, self.models_dir):
                    targets.append(t)
        except Exception:  # private API: if it changes, worst case a shared blob leaks
            sb = None
        shutil.rmtree(rd, ignore_errors=True)
        if sb is not None:
            for t in targets:
                sb.sweep_shared_blob(t, cache_dir=self.models_dir)

    async def download(self, http: aiohttp.ClientSession, repo: str, rf: RepoFiles,
                       on_bytes: Callable[[int], None], guard: Callable[[], None]) -> None:
        """Fetch every file of `rf`, resuming partial blobs. `on_bytes(n)` reports new bytes;
        `guard()` is called every ~200 MB and may raise DiskGuard. Cancel the task to pause."""
        from huggingface_hub import constants

        rd = self.repo_dir(repo)
        (rd / "blobs").mkdir(parents=True, exist_ok=True)
        (rd / "refs").mkdir(parents=True, exist_ok=True)
        (rd / "refs" / "main").write_text(rf.sha)
        snap = rd / "snapshots" / rf.sha
        since_guard = 0

        for f in sorted(rf.files, key=lambda f: f.size):  # small files first
            blob = rd / "blobs" / f.etag
            link = snap / f.path
            if _size(link) == f.size:
                continue
            if _size(blob) != f.size:
                part = blob.with_name(blob.name + ".incomplete")
                offset = _size(part) or 0
                if offset > f.size:
                    part.unlink()
                    offset = 0
                if offset < f.size:
                    url = f"{constants.ENDPOINT}/{repo}/resolve/{rf.sha}/{quote(f.path)}"
                    headers = {"Accept-Encoding": "identity"}
                    if offset:
                        headers["Range"] = f"bytes={offset}-"
                    async with http.get(url, headers=headers) as r:
                        r.raise_for_status()
                        if offset and r.status != 206:
                            offset = 0  # server ignored Range: start over
                        with open(part, "ab" if offset else "wb") as fh:
                            async for chunk in r.content.iter_chunked(CHUNK):
                                fh.write(chunk)
                                offset += len(chunk)
                                on_bytes(len(chunk))
                                since_guard += len(chunk)
                                if since_guard >= GUARD_EVERY:
                                    since_guard = 0
                                    guard()
                if _size(part) != f.size:
                    raise OSError(f"{f.path}: boyut uyuşmuyor ({_size(part)} != {f.size})")
                if f.lfs and not await asyncio.get_running_loop().run_in_executor(
                        None, _sha256_matches, part, f):
                    part.unlink(missing_ok=True)
                    raise OSError(f"{f.path}: SHA-256 doğrulaması başarısız")
                part.replace(blob)
            link.parent.mkdir(parents=True, exist_ok=True)
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(os.path.relpath(blob, link.parent))
        log.info("download complete: %s (%d files)", repo, len(rf.files))


def _size(p: Path) -> int | None:
    try:
        return p.stat().st_size
    except OSError:
        return None


def _sha256_matches(path: Path, f: RepoFile) -> bool:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(8 * CHUNK):
            h.update(chunk)
    return h.hexdigest() == f.etag
