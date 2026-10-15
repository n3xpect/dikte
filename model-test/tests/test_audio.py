"""Offline tests for audio.py. Run: uv run python tests/test_audio.py
Speech is synthesized with macOS `say -v Yelda` + ffmpeg (no mic needed)."""

import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402

import numpy as np  # noqa: E402

import audio  # noqa: E402

SR = config.SAMPLE_RATE
TMP = Path(tempfile.mkdtemp(prefix="stt_test_"))
rng = np.random.default_rng(0)


def tts(name: str, text: str, rate: int = SR, channels: int = 1) -> Path:
    aiff, wav = TMP / f"{name}.aiff", TMP / f"{name}.wav"
    subprocess.run(["say", "-v", "Yelda", "-o", str(aiff), text], check=True)
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", str(rate),
         "-ac", str(channels), str(wav)],
        check=True,
    )
    return wav


def noise(seconds: float, level: float = 0.002) -> np.ndarray:
    return (rng.standard_normal(int(seconds * SR)) * level).astype(np.float32)


def chunks(x: np.ndarray, size: int = 512):
    for i in range(0, len(x), size):
        yield x[i : i + size]


def run(x: np.ndarray, size: int = 512, **kw) -> tuple[audio.Recording, list[str]]:
    events: list[str] = []
    rec = audio.record_utterance(source=chunks(x, size), on_status=events.append, **kw)
    return rec, events


S1 = audio.load_wav(tts("s1", "Yarın saat üçte toplantı odasında buluşalım."))
S2 = audio.load_wav(tts("s2", "Raporu bitirdim, over."))
S3 = audio.load_wav(tts("s3", "Birinci kısım tamam."))


def test_wav_io():
    x44 = audio.load_wav(tts("s1_44k", "Yarın saat üçte toplantı odasında buluşalım.", 44100, 2))
    assert x44.dtype == np.float32 and x44.ndim == 1
    assert abs(len(x44) - len(S1)) < SR * 0.01, (len(x44), len(S1))
    p = TMP / "rt.wav"
    audio.save_wav(p, S1)
    y = audio.load_wav(p)
    assert len(y) == len(S1) and np.abs(y - S1).max() < 1e-3


def test_trim_silence():
    x = np.concatenate([noise(1.0), S1, noise(2.0)])
    t = audio.trim_silence(x, pad_ms=200)
    assert len(S1) * 0.7 < len(t) < len(S1) + 0.6 * SR, (len(t) / SR, len(S1) / SR)
    assert len(audio.trim_silence(noise(2.0))) == 0


def test_silence_end(size: int = 512):
    x = np.concatenate([noise(1.0), S1, noise(4.0)])
    rec, ev = run(x, size)
    assert rec.end_reason == "silence", rec.end_reason
    assert ev[0] == "listening" and ev[1] == "speech_start" and ev[-1] == "end:silence", ev
    # ended ~3 s after speech, not at end of source
    assert len(rec.raw) < len(x) - 0.5 * SR, (len(rec.raw) / SR, len(x) / SR)
    assert abs(rec.duration_s - len(S1) / SR) < 0.8, (rec.duration_s, len(S1) / SR)
    assert rec.duration_s == len(rec.audio) / SR
    return rec


def test_no_speech():
    rec, ev = run(noise(5.0), start_timeout_s=1.0)
    assert rec.end_reason == "no_speech" and len(rec.audio) == 0 and rec.duration_s == 0
    assert abs(len(rec.raw) / SR - 1.0) < 0.05 and "speech_start" not in ev


def test_max_duration():
    x = np.concatenate([S1, S1, S1, noise(4.0)])
    rec, _ = run(x, max_duration_s=3.0)
    assert rec.end_reason == "max_duration" and abs(len(rec.raw) / SR - 3.0) < 0.05


def test_source_exhausted_and_interrupt():
    rec, _ = run(np.concatenate([noise(0.5), S1]))
    assert rec.end_reason == "manual" and rec.duration_s > 1.0

    def interrupted():
        yield from chunks(np.concatenate([noise(0.5), S1]))
        raise KeyboardInterrupt

    rec = audio.record_utterance(source=interrupted())
    assert rec.end_reason == "manual" and rec.duration_s > 1.0


def test_odd_chunks():
    for size in (100, 777, 4000):
        test_silence_end(size)



if __name__ == "__main__":
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {name}: {e}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
