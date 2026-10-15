"""STT backends: mlx-whisper models and Qwen3-ASR (mlx-audio), behind one API.

All models live in the HF cache under ./models (set by config). Loaded models
are cached in-process so several can be resident at once and alternated
without reloading.
"""

import config  # noqa: F401  (must come first: sets HF_HUB_CACHE)

import json
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass(frozen=True)
class ModelSpec:
    key: str
    repo: str
    kind: str  # "mlx-whisper" | "qwen3-asr"
    label: str
    size_gb: float
    default: bool  # downloaded by `download.py` with no args


MODELS: dict[str, ModelSpec] = {
    s.key: s
    for s in [
        ModelSpec("turbo", "mlx-community/whisper-large-v3-turbo", "mlx-whisper",
                  "Whisper large-v3 turbo", 1.61, False),
        ModelSpec("large-v3", "mlx-community/whisper-large-v3-mlx", "mlx-whisper",
                  "Whisper large-v3", 3.08, True),
        ModelSpec("tr-ft", "denizyldz24/whisper-large-v3-turkish-general-mlx", "mlx-whisper",
                  "Whisper large-v3 Turkish fine-tune", 3.08, False),
        ModelSpec("qwen3-1.7b", "mlx-community/Qwen3-ASR-1.7B-8bit", "qwen3-asr",
                  "Qwen3-ASR 1.7B (8-bit)", 2.47, False),
        ModelSpec("turbo-q4", "mlx-community/whisper-large-v3-turbo-q4", "mlx-whisper",
                  "Whisper large-v3 turbo (4-bit)", 0.46, False),
        ModelSpec("qwen3-0.6b", "mlx-community/Qwen3-ASR-0.6B-8bit", "qwen3-asr",
                  "Qwen3-ASR 0.6B (8-bit)", 1.01, False),
    ]
}


@dataclass
class Result:
    text: str
    seconds: float
    model_key: str
    prompt_used: bool


# MLX inference and mlx_whisper's global ModelHolder are not safe to drive from
# several threads at once; serialize all loads and transcriptions.
_LOCK = threading.RLock()


# --------------------------------------------------------------------------- cache

def local_path(key: str) -> Path | None:
    """Snapshot dir of a fully downloaded model, or None."""
    spec = MODELS[key]
    from huggingface_hub import snapshot_download

    try:
        path = Path(snapshot_download(spec.repo, local_files_only=True))
    except Exception:
        return None
    # A snapshot dir can exist while a download is still running; files only get
    # linked into it once their blob is complete, so check the required ones.
    if not (path / "config.json").exists():
        return None
    if spec.kind == "mlx-whisper":
        ok = (path / "weights.safetensors").exists() or (path / "weights.npz").exists()
    else:
        required = ["vocab.json", "merges.txt", "tokenizer_config.json",
                    "preprocessor_config.json"]
        index = path / "model.safetensors.index.json"
        if index.exists():
            required += sorted(set(json.loads(index.read_text())["weight_map"].values()))
        else:
            required.append("model.safetensors")
        ok = all((path / f).exists() for f in required)
    return path if ok else None


def is_downloaded(key: str) -> bool:
    return local_path(key) is not None


def available_keys() -> list[str]:
    return [k for k in MODELS if is_downloaded(k)]


# --------------------------------------------------------------------------- backends

class Backend:
    spec: ModelSpec
    load_seconds: float | None = None

    def __init__(self, spec: ModelSpec):
        self.spec = spec
        self.load_seconds = None

    def load(self) -> None:
        raise NotImplementedError

    def transcribe(self, audio: np.ndarray, *, language: str = "tr",
                   prompt: str | None = None,
                   hotwords: list[str] | None = None) -> Result:
        raise NotImplementedError

    def _path(self) -> str:
        path = local_path(self.spec.key)
        if path is None:
            raise RuntimeError(
                f"Model '{self.spec.key}' ({self.spec.repo}) is not downloaded. "
                f"Run: uv run download.py {self.spec.key}")
        return str(path)


def _as_audio(audio: np.ndarray) -> np.ndarray:
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim != 1:
        audio = audio.reshape(-1)
    return audio


class WhisperBackend(Backend):
    """mlx-whisper. Each instance owns its model; before transcribing it is
    swapped into mlx_whisper's single-slot ModelHolder so no reload happens."""

    def __init__(self, spec: ModelSpec):
        super().__init__(spec)
        self._model = None
        self._path_str: str | None = None

    def load(self) -> None:
        with _LOCK:
            if self._model is not None:
                return
            import mlx.core as mx
            from mlx_whisper.load_models import load_model

            t0 = time.perf_counter()
            self._path_str = self._path()
            # fp16 matches what mlx_whisper.transcribe uses by default (fp16=True)
            self._model = load_model(self._path_str, dtype=mx.float16)
            self.load_seconds = time.perf_counter() - t0

    def transcribe(self, audio, *, language="tr", prompt=None, hotwords=None) -> Result:
        import mlx.core as mx
        import mlx_whisper
        from mlx_whisper.transcribe import ModelHolder

        self.load()
        audio = _as_audio(audio)
        prompt = (prompt or "").strip() or None
        with _LOCK:
            ModelHolder.model = self._model
            ModelHolder.model_path = self._path_str
            t0 = time.perf_counter()
            out = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=self._path_str,  # == ModelHolder.model_path → no reload
                verbose=None,
                language=language,
                temperature=0.0,
                condition_on_previous_text=False,
                initial_prompt=prompt,
            )
            text = out["text"].strip()
            mx.synchronize()
            seconds = time.perf_counter() - t0
        return Result(text, seconds, self.spec.key, prompt is not None)


QWEN_HOTWORD_PREFIX = "Teknik terimler: "


class Qwen3AsrBackend(Backend):
    """Qwen3-ASR via mlx-audio. Biasing via `hotwords` (folded into the system
    prompt by mlx-audio); `prompt` is ignored."""

    def __init__(self, spec: ModelSpec):
        super().__init__(spec)
        self._model = None

    def load(self) -> None:
        with _LOCK:
            if self._model is not None:
                return
            from mlx_audio.stt import load

            t0 = time.perf_counter()
            self._model = load(self._path())
            self.load_seconds = time.perf_counter() - t0

    @staticmethod
    def _language_name(language: str | None) -> str | None:
        # Qwen3-ASR wants the full English name ("Turkish"); accept ISO codes too.
        if not language:
            return None
        from mlx_whisper.tokenizer import LANGUAGES

        return LANGUAGES.get(language.lower(), language).title()

    def transcribe(self, audio, *, language="tr", prompt=None, hotwords=None) -> Result:
        import mlx.core as mx

        self.load()
        audio = _as_audio(audio)
        words = [w.strip() for w in (hotwords or []) if w and w.strip()]
        duration = len(audio) / config.SAMPLE_RATE
        with _LOCK:
            t0 = time.perf_counter()
            out = self._model.generate(
                audio,
                language=self._language_name(language),
                # Same as mlx-audio's `hotwords=` (a bare "a, b, c" system prompt)
                # but labelled: the bare list barely biased the 1.7B model in our
                # test, while "Teknik terimler: ..." fixed every term.
                system_prompt=QWEN_HOTWORD_PREFIX + ", ".join(words) if words else None,
                temperature=0.0,
                # Bound runaway repetition loops (default is 8192 tokens).
                max_tokens=int(64 + 16 * duration),
            )
            text = _strip_language_tag(out.text)
            mx.synchronize()
            seconds = time.perf_counter() - t0
        return Result(text, seconds, self.spec.key, bool(words))


def _strip_language_tag(text: str) -> str:
    # With a fixed language the tag is part of the prompt, not the output; this is
    # just a guard for auto-detect mode ("language Turkish<asr_text>...").
    if "<asr_text>" in text:
        text = text.split("<asr_text>", 1)[1]
    return text.strip()


# --------------------------------------------------------------------------- registry

_BACKENDS: dict[str, Backend] = {}


def get_backend(key: str) -> Backend:
    """Loaded backend for `key`, cached for the life of the process."""
    if key not in MODELS:
        raise KeyError(f"Unknown model '{key}'. Known: {', '.join(MODELS)}")
    with _LOCK:
        backend = _BACKENDS.get(key)
        if backend is None:
            spec = MODELS[key]
            cls = WhisperBackend if spec.kind == "mlx-whisper" else Qwen3AsrBackend
            backend = cls(spec)
            backend.load()
            _BACKENDS[key] = backend
        return backend


def warmup(backend: Backend) -> None:
    """Run ~1 s of low noise through the model so MLX compiles its kernels now
    rather than on the first real utterance."""
    rng = np.random.default_rng(0)
    noise = (rng.standard_normal(config.SAMPLE_RATE) * 1e-3).astype(np.float32)
    backend.transcribe(noise, language=config.LANGUAGE)
