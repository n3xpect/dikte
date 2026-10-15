"""Mic capture with Silero-VAD endpointing (stops after a silence timeout)."""

import config  # noqa: F401  (must come first: sets HF cache env)

import queue
import sys
import time
import wave
import warnings
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from pathlib import Path

import numpy as np

SR = config.SAMPLE_RATE
CHUNK = config.CHUNK
PREROLL_S = 0.3   # kept before the first speech frame
POSTROLL_S = 0.2  # kept after the last speech frame
MIN_SPEECH_FRAMES = 3  # ~96 ms of consecutive speech before "speech_start" (rejects clicks)


class MicPermissionError(RuntimeError):
    pass


@dataclass
class Recording:
    audio: np.ndarray  # float32 mono 16 kHz, silence-trimmed (lead/trail), ready for ASR
    raw: np.ndarray  # full untrimmed float32 recording
    duration_s: float  # len(audio) / SAMPLE_RATE
    end_reason: str  # "silence" | "max_duration" | "manual" | "no_speech"
    t_end_detected: float  # time.perf_counter() at the moment end was detected


_model = None


def _vad():
    global _model
    if _model is None:
        import torch
        from silero_vad import load_silero_vad

        torch.set_num_threads(1)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", FutureWarning)  # torch.jit.load deprecation
            _model = load_silero_vad(onnx=False)
    return _model


def _rechunk(chunks: Iterable[np.ndarray]) -> Iterator[np.ndarray]:
    """Yield exactly CHUNK-sized float32 frames from arbitrary-sized chunks (tail is dropped)."""
    buf = np.zeros(0, dtype=np.float32)
    for c in chunks:
        buf = np.concatenate([buf, np.asarray(c, dtype=np.float32).reshape(-1)])
        while len(buf) >= CHUNK:
            yield buf[:CHUNK]
            buf = buf[CHUNK:]


def _mic_chunks(q: "queue.Queue[np.ndarray]") -> Iterator[np.ndarray]:
    while True:
        yield q.get()


def record_utterance(
    *,
    silence_s: float = 3.0,
    max_duration_s: float = 120.0,
    start_timeout_s: float = 15.0,
    vad_threshold: float = 0.5,
    on_status: Callable[[str], None] | None = None,
    source: Iterable[np.ndarray] | None = None,
) -> Recording:
    """Record one utterance and stop at the first end condition.

    Endpointing uses the raw Silero probability per 512-sample frame with the same
    hysteresis as silero's VADIterator (speech >= threshold, silence < threshold-0.15).
    "Silence" is measured from the first sub-threshold frame after the last speech
    frame, in samples (so `source=` tests run faster than real time).
    If `source` runs out, end_reason is "manual"
    (or "no_speech" if no speech was seen).
    """
    import torch

    emit = on_status or (lambda _s: None)
    model = _vad()
    model.reset_states()
    neg_threshold = max(vad_threshold - 0.15, 0.01)

    frames: list[np.ndarray] = []
    pos = 0  # samples consumed
    speech_run = 0
    speech_started = False
    first_speech = 0  # sample index of first speech frame
    last_speech_end = 0  # sample index just after last speech frame
    silence_start: int | None = None
    end_reason = "manual"

    stream = None
    if source is None:
        import sounddevice as sd

        q: queue.Queue[np.ndarray] = queue.Queue()

        def cb(indata, _frames, _time, status):
            if status:
                print(f"[audio] {status}", file=sys.stderr)
            q.put(indata[:, 0].copy())

        stream = sd.InputStream(
            samplerate=SR, channels=1, dtype="float32", blocksize=CHUNK, callback=cb
        )
        stream.start()
        chunks: Iterable[np.ndarray] = _mic_chunks(q)
    else:
        chunks = source

    emit("listening")
    try:
        with torch.no_grad():
            for frame in _rechunk(chunks):
                frames.append(frame)
                prob = model(torch.from_numpy(frame.copy()), SR).item()
                pos += CHUNK

                if prob >= vad_threshold:
                    speech_run += 1
                    silence_start = None
                    if not speech_started and speech_run >= MIN_SPEECH_FRAMES:
                        speech_started = True
                        first_speech = pos - speech_run * CHUNK
                        emit("speech_start")
                    if speech_started:
                        last_speech_end = pos
                else:
                    speech_run = 0
                    if speech_started and silence_start is None and prob < neg_threshold:
                        silence_start = pos - CHUNK

                if not speech_started:
                    if pos >= start_timeout_s * SR:
                        end_reason = "no_speech"
                        break
                elif silence_start is not None and pos - silence_start >= silence_s * SR:
                    end_reason = "silence"
                    break

                if pos >= max_duration_s * SR:
                    end_reason = "max_duration"
                    break
            else:
                if not speech_started:
                    end_reason = "no_speech"
    except KeyboardInterrupt:
        end_reason = "manual"
    finally:
        t_end = time.perf_counter()
        if stream is not None:
            stream.stop()
            stream.close()

    emit(f"end:{end_reason}")
    raw = np.concatenate(frames) if frames else np.zeros(0, dtype=np.float32)
    if speech_started and end_reason != "no_speech":
        # Trim with the online VAD bounds: frame-accurate and avoids a second VAD pass.
        lo = max(0, first_speech - int(PREROLL_S * SR))
        hi = min(len(raw), last_speech_end + int(POSTROLL_S * SR))
        audio = raw[lo:hi].copy()
    else:
        audio = np.zeros(0, dtype=np.float32)
    return Recording(audio, raw, len(audio) / SR, end_reason, t_end)


def trim_silence(audio: np.ndarray, pad_ms: int = 200) -> np.ndarray:
    """Cut leading/trailing non-speech (Silero offline VAD); empty array if no speech."""
    import torch
    from silero_vad import get_speech_timestamps

    audio = np.asarray(audio, dtype=np.float32).reshape(-1)
    if len(audio) == 0:
        return audio
    ts = get_speech_timestamps(torch.from_numpy(audio.copy()), _vad(), sampling_rate=SR)
    if not ts:
        return np.zeros(0, dtype=np.float32)
    pad = int(pad_ms * SR / 1000)
    return audio[max(0, ts[0]["start"] - pad) : min(len(audio), ts[-1]["end"] + pad)].copy()


def save_wav(path: str | Path, audio: np.ndarray) -> None:
    """Write 16-bit PCM mono 16 kHz."""
    pcm = (np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0) * 32767).astype("<i2")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def load_wav(path: str | Path) -> np.ndarray:
    """Read integer-PCM WAV (8/16/24/32-bit, any channels/rate) as float32 mono 16 kHz.
    stdlib `wave` cannot read IEEE-float WAVs; convert those with ffmpeg first."""
    with wave.open(str(path), "rb") as w:
        n_ch, width, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        data = w.readframes(w.getnframes())

    if width == 1:
        x = (np.frombuffer(data, dtype=np.uint8).astype(np.float32) - 128) / 128
    elif width == 2:
        x = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768
    elif width == 3:
        b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = (np.where(v >= 1 << 23, v - (1 << 24), v)).astype(np.float32) / (1 << 23)
    elif width == 4:
        x = np.frombuffer(data, dtype="<i4").astype(np.float32) / (1 << 31)
    else:
        raise ValueError(f"unsupported sample width: {width}")

    x = x.reshape(-1, n_ch).mean(axis=1)
    if rate != SR:
        from math import gcd

        from scipy.signal import resample_poly

        g = gcd(SR, rate)
        x = resample_poly(x, SR // g, rate // g)
    return x.astype(np.float32)


def check_mic(seconds: float = 0.5) -> float:
    """Record briefly and return the peak level. macOS returns pure zeros (no error)
    when the terminal app lacks microphone permission."""
    import sounddevice as sd

    rec = sd.rec(int(seconds * SR), samplerate=SR, channels=1, dtype="float32")
    sd.wait()
    peak = float(np.abs(rec).max()) if rec.size else 0.0
    if peak == 0.0:
        raise MicPermissionError(
            "Microphone returned only zeros. Grant mic access to your terminal app in "
            "System Settings > Privacy & Security > Microphone, then restart it."
        )
    return peak
