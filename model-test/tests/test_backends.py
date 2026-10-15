"""Smoke test for backends.py on every downloaded model.

    uv run python tests/test_backends.py [model keys...]

Generates Turkish audio with macOS `say` (voice Yelda) unless /tmp/b.wav exists.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402,F401  (must come first: sets HF_HUB_CACHE)

import subprocess  # noqa: E402
import time  # noqa: E402
import wave  # noqa: E402

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402

import backends  # noqa: E402

SENTENCE = ("Önce git üzerinde yeni bir branch açalım, ardından Go ile session "
            "tutabilen bir web app hazırlayacağız.")
TERMS = ["git", "branch", "Go", "session", "web app", "database", "socket"]
PROMPT = ", ".join(TERMS)
WAV = Path("/tmp/b.wav")


def make_audio() -> np.ndarray:
    if not WAV.exists():
        subprocess.run(["say", "-v", "Yelda", "-o", "/tmp/b.aiff", SENTENCE], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", "/tmp/b.aiff",
                        "-ar", "16000", "-ac", "1", str(WAV)], check=True)
    with wave.open(str(WAV)) as w:
        assert w.getframerate() == config.SAMPLE_RATE and w.getnchannels() == 1
        assert w.getsampwidth() == 2
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return pcm.astype(np.float32) / 32768.0


def gb(n: int) -> str:
    return f"{n / 1e9:.2f} GB"


def main() -> None:
    audio = make_audio()
    print(f"audio: {len(audio) / config.SAMPLE_RATE:.2f} s\nreference: {SENTENCE}\n")

    keys = sys.argv[1:] or backends.available_keys()
    missing = [k for k in backends.MODELS if k not in keys]
    print(f"testing: {keys}\nnot downloaded / skipped: {missing}\n")

    rows = []
    for key in keys:
        mx.reset_peak_memory()
        b = backends.get_backend(key)
        t0 = time.perf_counter()
        backends.warmup(b)
        warm = time.perf_counter() - t0
        plain = b.transcribe(audio, language="tr")
        biased = b.transcribe(audio, language="tr", prompt=PROMPT, hotwords=TERMS)
        assert not plain.prompt_used and biased.prompt_used
        rows.append((key, b.load_seconds, warm, plain, biased, mx.get_peak_memory()))
        print(f"== {key}  load {b.load_seconds:.2f}s  warmup {warm:.2f}s  "
              f"peak {gb(mx.get_peak_memory())}  active {gb(mx.get_active_memory())}")
        print(f"   plain  {plain.seconds:5.2f}s  {plain.text}")
        print(f"   biased {biased.seconds:5.2f}s  {biased.text}\n")

    # Two whisper models resident and alternated: must not reload weights.
    whisper_keys = [k for k in keys if backends.MODELS[k].kind == "mlx-whisper"][:2]
    if len(whisper_keys) == 2:
        # the package re-exports the function `transcribe`, shadowing the module
        mt = sys.modules["mlx_whisper.transcribe"]
        loads = []
        orig = mt.load_model
        mt.load_model = lambda *a, **kw: loads.append(a) or orig(*a, **kw)
        try:
            print(f"== alternating {whisper_keys[0]} <-> {whisper_keys[1]}")
            for k in whisper_keys * 2:
                r = backends.get_backend(k).transcribe(audio, prompt=PROMPT)
                print(f"   {k:<11} {r.seconds:5.2f}s  {r.text}")
        finally:
            mt.load_model = orig
        assert not loads, f"mlx_whisper reloaded a model: {loads}"
        print("   no reloads ✓\n")
    else:
        print("== alternation test skipped (needs two downloaded whisper models)\n")

    print(f"{'model':<11} {'load s':>6} {'warm s':>6} {'plain s':>7} {'bias s':>6} "
          f"{'peak':>8}  text (plain | biased)")
    for key, load, warm, plain, biased, peak in rows:
        print(f"{key:<11} {load:6.2f} {warm:6.2f} {plain.seconds:7.2f} "
              f"{biased.seconds:6.2f} {gb(peak):>8}  {plain.text} | {biased.text}")
    print(f"\nresident models: {list(backends._BACKENDS)}  "
          f"active memory {gb(mx.get_active_memory())}")


if __name__ == "__main__":
    main()
