"""Push-based Silero VAD endpointer: feed arbitrary PCM chunks, get events.

Endpointing uses the raw Silero probability per 512-sample frame with the same hysteresis
as silero's VADIterator (speech >= threshold, silence < threshold - 0.15). All timeouts
are measured in samples, so audio fed faster than real time behaves identically.
"""

from __future__ import annotations

import threading
import warnings
from typing import Any

import numpy as np

SR = 16_000
FRAME = 512  # samples per VAD frame (32 ms), required by Silero at 16 kHz
PREROLL_S = 0.3  # kept before the first speech frame
POSTROLL_S = 0.2  # kept after the last speech frame
MIN_SPEECH_FRAMES = 3  # ~96 ms of consecutive speech before speech_start (rejects clicks)
START_TIMEOUT_S = 15.0

_model: Any = None
_model_lock = threading.Lock()


def load_vad() -> Any:
    """Silero VAD (torch JIT), loaded once per process."""
    global _model
    with _model_lock:
        if _model is None:
            import torch
            from silero_vad import load_silero_vad

            torch.set_num_threads(1)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", FutureWarning)  # torch.jit.load deprecation
                _model = load_silero_vad(onnx=False)
        return _model


class Endpointer:
    """Not thread-safe; also resets the shared Silero state, so one instance at a time."""

    def __init__(self, *, silence_s: float = 3.0, max_duration_s: float = 120.0,
                 start_timeout_s: float = START_TIMEOUT_S, threshold: float = 0.5):
        self.silence_samples = int(silence_s * SR)
        self.max_samples = int(max_duration_s * SR)
        self.start_timeout_samples = int(start_timeout_s * SR)
        self.threshold = threshold
        self.neg_threshold = max(threshold - 0.15, 0.01)

        self.model = load_vad()
        self.model.reset_states()
        self._frames: list[np.ndarray] = []
        self._pending = np.zeros(0, dtype=np.float32)
        self.pos = 0  # samples run through the VAD
        self._speech_run = 0
        self.speech_started = False
        self._first_speech = 0
        self._last_speech_end = 0
        self._silence_start: int | None = None
        self.end_reason: str | None = None

    def feed(self, pcm: np.ndarray) -> list[str]:
        """Consume samples; return new events: "speech_start", "end:<reason>"."""
        import torch

        if self.end_reason is not None:
            return []
        events: list[str] = []
        buf = np.concatenate([self._pending, np.asarray(pcm, dtype=np.float32).reshape(-1)])
        n = len(buf) // FRAME * FRAME
        self._pending = buf[n:].copy()
        with torch.no_grad():
            for i in range(0, n, FRAME):
                frame = buf[i:i + FRAME]
                self._frames.append(frame)
                prob = self.model(torch.from_numpy(frame.copy()), SR).item()
                self.pos += FRAME
                if prob >= self.threshold:
                    self._speech_run += 1
                    self._silence_start = None
                    if not self.speech_started and self._speech_run >= MIN_SPEECH_FRAMES:
                        self.speech_started = True
                        self._first_speech = self.pos - self._speech_run * FRAME
                        events.append("speech_start")
                    if self.speech_started:
                        self._last_speech_end = self.pos
                else:
                    self._speech_run = 0
                    if (self.speech_started and self._silence_start is None
                            and prob < self.neg_threshold):
                        self._silence_start = self.pos - FRAME

                reason = None
                if not self.speech_started:
                    if self.pos >= self.start_timeout_samples:
                        reason = "no_speech"
                elif (self._silence_start is not None
                      and self.pos - self._silence_start >= self.silence_samples):
                    reason = "silence"
                if reason is None and self.pos >= self.max_samples:
                    reason = "max_duration" if self.speech_started else "no_speech"
                if reason:
                    self.end_reason = reason
                    events.append(f"end:{reason}")
                    break
        return events

    def stop(self, reason: str) -> str:
        """End by client request ("finish" / "cancel"). Returns the effective reason:
        "finish" without any detected speech becomes "no_speech"."""
        if self.end_reason is None:
            if reason == "finish" and not self.speech_started:
                reason = "no_speech"
            self.end_reason = reason
        return self.end_reason

    @property
    def raw(self) -> np.ndarray:
        return np.concatenate(self._frames) if self._frames else np.zeros(0, dtype=np.float32)

    def audio(self) -> np.ndarray:
        """Speech segment with pre/post-roll, ready for ASR (empty if no speech)."""
        if not self.speech_started or self.end_reason in ("no_speech", "cancel"):
            return np.zeros(0, dtype=np.float32)
        raw = self.raw
        lo = max(0, self._first_speech - int(PREROLL_S * SR))
        hi = min(len(raw), self._last_speech_end + int(POSTROLL_S * SR))
        return raw[lo:hi].copy()
