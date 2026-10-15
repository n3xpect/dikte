"""STT backends (mlx-whisper, Qwen3-ASR via mlx-audio). One model is resident at a time.

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

log = logging.getLogger("dikte.asr")
SR = 16_000
QWEN_HOTWORD_PREFIX = "Teknik terimler: "


@dataclass
class Transcript:
    text: str
    seconds: float


class Backend:
    def __init__(self, spec: ModelSpec, path: Path):
        self.spec = spec
        self.path = str(path)

    def transcribe(self, audio: np.ndarray, *, language: str, prompt: str,
                   hotwords: list[str]) -> Transcript:
        raise NotImplementedError

    def close(self) -> None:
        raise NotImplementedError


class WhisperBackend(Backend):
    def __init__(self, spec: ModelSpec, path: Path):
        import mlx.core as mx
        from mlx_whisper.load_models import load_model

        super().__init__(spec, path)
        # fp16 matches what mlx_whisper.transcribe uses by default (fp16=True)
        self._model = load_model(self.path, dtype=mx.float16)

    def transcribe(self, audio, *, language, prompt, hotwords) -> Transcript:
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


class QwenBackend(Backend):
    """Biasing via a labelled system prompt: a bare "a, b, c" hotword list barely biased
    the 1.7B model in our test, "Teknik terimler: ..." fixed every term."""

    def __init__(self, spec: ModelSpec, path: Path):
        from mlx_audio.stt import load

        super().__init__(spec, path)
        self._model = load(self.path)

    def transcribe(self, audio, *, language, prompt, hotwords) -> Transcript:
        import mlx.core as mx
        from mlx_whisper.tokenizer import LANGUAGES

        words = [w.strip() for w in hotwords if w and w.strip()]
        t0 = time.perf_counter()
        out = self._model.generate(
            audio,
            language=LANGUAGES.get(language.lower(), language).title() if language else None,
            system_prompt=QWEN_HOTWORD_PREFIX + ", ".join(words) if words else None,
            temperature=0.0,
            max_tokens=int(64 + 16 * len(audio) / SR),  # bounds runaway repetition loops
        )
        text = out.text
        if "<asr_text>" in text:  # auto-detect mode prefixes "language X<asr_text>"
            text = text.split("<asr_text>", 1)[1]
        mx.synchronize()
        return Transcript(text.strip(), time.perf_counter() - t0)

    def close(self) -> None:
        self._model = None


def load(spec: ModelSpec, path: Path, language: str) -> Backend:
    t0 = time.perf_counter()
    backend: Backend = (WhisperBackend if spec.kind == WHISPER else QwenBackend)(spec, path)
    t1 = time.perf_counter()
    # ~1 s of low noise so MLX compiles its kernels now, not on the first real utterance
    noise = (np.random.default_rng(0).standard_normal(SR) * 1e-3).astype(np.float32)
    backend.transcribe(noise, language=language, prompt="", hotwords=[])
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
