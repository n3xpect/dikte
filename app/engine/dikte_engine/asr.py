"""STT backend (mlx-whisper). One model is resident at a time.

MLX is not safe to drive from several threads; the engine runs every call in this module
on one dedicated thread.
"""

from __future__ import annotations

import contextlib
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
LANGUAGES = ("tr", "en")


@dataclass
class Transcript:
    text: str
    seconds: float
    language: str  # the language used: "tr" | "en"


class Backend:
    def __init__(self, spec: ModelSpec, path: Path):
        self.spec = spec
        self.path = str(path)

    def transcribe(self, audio: np.ndarray, *, language: str,
                   prompts: dict[str, str]) -> Transcript:
        """language: "auto" (tr or en, detected) | "tr" | "en"; prompts: language -> prompt."""
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

    def transcribe(self, audio, *, language, prompts) -> Transcript:
        import mlx.core as mx
        import mlx_whisper
        from mlx_whisper.transcribe import ModelHolder

        # Hand our model to mlx_whisper's single-slot cache so transcribe() does not reload it.
        ModelHolder.model = self._model
        ModelHolder.model_path = self.path
        t0 = time.perf_counter()
        reuse: contextlib.AbstractContextManager = contextlib.nullcontext()
        if language == "auto":
            language, reuse = self._detect(audio)
        with reuse:
            out = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=self.path,
                verbose=None,
                language=language,
                temperature=0.0,
                condition_on_previous_text=False,
                initial_prompt=prompts.get(language, "").strip() or None,
            )
        mx.synchronize()
        return Transcript(str(out["text"]).strip(), time.perf_counter() - t0, language)

    def _detect(self, audio) -> tuple[str, contextlib.AbstractContextManager]:
        """tr or en, whichever Whisper finds more likely in the first 30 s window (the window
        mlx_whisper.transcribe decodes first). Returns a context that hands that window's
        encoder output to the transcription, so the encoder runs once."""
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
        from mlx_whisper.decoding import detect_language

        model = self._model
        if not model.is_multilingual:
            return "en", contextlib.nullcontext()
        # same steps as mlx_whisper.transcribe for seek=0, so the mel is bit-identical
        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        mel = mel[: min(N_FRAMES, mel.shape[-2] - N_FRAMES)]
        mel = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)[None]
        features = model.encoder(mel)
        _, probs = detect_language(model, features)
        language = max(LANGUAGES, key=lambda c: probs[0][c])
        return language, _reuse_encoder(model, mel, features)

    def close(self) -> None:
        from mlx_whisper.transcribe import ModelHolder

        ModelHolder.model = None
        ModelHolder.model_path = None
        self._model = None


@contextlib.contextmanager
def _reuse_encoder(model, mel, features):
    import mlx.core as mx

    encoder = model.encoder

    def encode(x):
        if x.size == mel.size and mx.array_equal(x.reshape(mel.shape), mel).item():
            return features
        return encoder(x)

    # An instance attribute shadows the submodule (nn.Module keeps children as dict items).
    object.__setattr__(model, "encoder", encode)
    try:
        yield
    finally:
        object.__delattr__(model, "encoder")


def load(spec: ModelSpec, path: Path) -> Backend:
    t0 = time.perf_counter()
    if spec.kind != WHISPER:
        raise ValueError(f"unsupported model kind: {spec.kind}")
    backend: Backend = WhisperBackend(spec, path)
    t1 = time.perf_counter()
    # ~1 s of low noise so MLX compiles its kernels now, not on the first real utterance
    noise = (np.random.default_rng(0).standard_normal(SR) * 1e-3).astype(np.float32)
    backend.transcribe(noise, language="auto", prompts={})  # also compiles detection
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
