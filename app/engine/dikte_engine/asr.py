"""STT backend (mlx-whisper). One model is resident at a time.

MLX is not safe to drive from several threads; the engine runs every call in this module
on one dedicated thread.
"""

from __future__ import annotations

import gc
import logging
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .catalog import WHISPER, ModelSpec
from .shims import import_mlx_whisper

log = logging.getLogger("dikte.asr")
SR = 16_000


@dataclass
class Transcript:
    text: str
    seconds: float


class Backend:
    def __init__(self, spec: ModelSpec, path: Path):
        self.spec = spec
        self.path = str(path)

    def transcribe(self, audio: np.ndarray, *, language: str, prompt: str) -> Transcript:
        raise NotImplementedError

    def close(self) -> None:
        raise NotImplementedError


class WhisperBackend(Backend):
    def __init__(self, spec: ModelSpec, path: Path):
        import_mlx_whisper()
        import mlx.core as mx
        from mlx_whisper.load_models import load_model

        super().__init__(spec, path)
        # fp16 matches what mlx_whisper.transcribe uses by default (fp16=True)
        self._model = load_model(self.path, dtype=mx.float16)

    def transcribe(self, audio, *, language, prompt) -> Transcript:
        import mlx.core as mx
        import mlx_whisper
        from mlx_whisper.transcribe import ModelHolder

        # Hand our model to mlx_whisper's single-slot cache so transcribe() does not reload it.
        ModelHolder.model = self._model
        ModelHolder.model_path = self.path
        t0 = time.perf_counter()
        out = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.path,
            verbose=None,
            language=language,
            temperature=0.0,
            condition_on_previous_text=False,
            initial_prompt=prompt.strip() or None,
        )
        mx.synchronize()
        return Transcript(str(out["text"]).strip(), time.perf_counter() - t0)

    def close(self) -> None:
        from mlx_whisper.transcribe import ModelHolder

        ModelHolder.model = None
        ModelHolder.model_path = None
        self._model = None


def load(spec: ModelSpec, path: Path, language: str) -> Backend:
    t0 = time.perf_counter()
    if spec.kind != WHISPER:
        raise ValueError(f"unsupported model kind: {spec.kind}")
    backend: Backend = WhisperBackend(spec, path)
    t1 = time.perf_counter()
    # ~1 s of low noise so MLX compiles its kernels now, not on the first real utterance
    noise = (np.random.default_rng(0).standard_normal(SR) * 1e-3).astype(np.float32)
    backend.transcribe(noise, language=language, prompt="")
    log.info("loaded %s in %.1fs (+%.1fs warmup), mlx active %.2f GB", spec.id, t1 - t0,
             time.perf_counter() - t1, active_memory() / 1e9)
    return backend


def unload(backend: Backend) -> None:
    import mlx.core as mx

    before = active_memory()
    backend.close()
    gc.collect()
    mx.clear_cache()
    log.info("unloaded %s: mlx active %.2f -> %.2f GB", backend.spec.id, before / 1e9,
             active_memory() / 1e9)


def active_memory() -> int:
    import mlx.core as mx

    return int(mx.get_active_memory())
