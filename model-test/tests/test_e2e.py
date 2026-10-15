"""End-to-end smoke test without a microphone: macOS TTS (Yelda) audio is fed through
record_utterance (silence endpointing) -> all downloaded models -> fixes -> scoring.

    uv run python tests/test_e2e.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402,F401

import subprocess  # noqa: E402
import tempfile  # noqa: E402

import numpy as np  # noqa: E402
import yaml  # noqa: E402

import audio  # noqa: E402
import backends  # noqa: E402
import listen  # noqa: E402
import terms as termlib  # noqa: E402


def tts(text: str) -> np.ndarray:
    with tempfile.TemporaryDirectory() as d:
        aiff, wav = f"{d}/s.aiff", f"{d}/s.wav"
        subprocess.run(["say", "-v", "Yelda", "-o", aiff, text], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", aiff, "-ar", "16000", "-ac", "1", wav],
                       check=True)
        return audio.load_wav(wav)


def chunks(x: np.ndarray, n: int = 1000):
    for i in range(0, len(x), n):
        yield x[i:i + n]


def main() -> None:
    sentences = {s["id"]: s for s in yaml.safe_load(config.SENTENCES_YAML.read_text())["sentences"]}
    picks = [sentences[k] for k in ("dev01", "dev02", "dev03", "dev04")]

    term_list = termlib.load_terms()
    prompt, hotwords = termlib.build_whisper_prompt(term_list), termlib.hotwords(term_list)
    state = listen.State(models=backends.available_keys(), compare=True, prompt_on=True,
                         silence_s=3.0, script=True)
    for k in state.active_models():
        listen.load_backend(k)

    rng = np.random.default_rng(0)
    for s in picks:
        speech = tts(s["text"])
        tail = rng.normal(0, 0.002, int(4.0 * config.SAMPLE_RATE)).astype(np.float32)
        lead = rng.normal(0, 0.002, int(0.5 * config.SAMPLE_RATE)).astype(np.float32)
        print(f"\n===== {s['id']} =====\n{s['text']}")
        rec = audio.record_utterance(source=chunks(np.concatenate([lead, speech, tail])),
                                     on_status=listen.on_status)
        print(f"end_reason={rec.end_reason}, {rec.duration_s:.1f} sn")
        assert rec.end_reason == "silence", rec.end_reason
        listen.transcribe_and_report(state, rec, "(tts)", s, term_list, prompt, hotwords)


if __name__ == "__main__":
    config.RESULTS_CSV = Path(tempfile.gettempdir()) / "stt_e2e_results.csv"  # keep real results clean
    main()
