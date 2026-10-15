"""Endpointer unit tests (synthetic Turkish speech via `say -v Yelda`).
Run: uv run python tests/test_vad.py"""

import numpy as np
from common import SR, noise, run_tests, tts

from dikte_engine.vad import Endpointer

S1 = tts("Yarın saat üçte toplantı odasında buluşalım.")
S2 = tts("Raporu bitirdim.")


def feed(ep: Endpointer, x: np.ndarray, size: int) -> list[str]:
    events: list[str] = []
    for i in range(0, len(x), size):
        events += ep.feed(x[i:i + size])
        if ep.end_reason:
            break
    return events


def check_silence_end(size: int) -> None:
    x = np.concatenate([noise(1.0), S1, noise(4.0)])
    ep = Endpointer(silence_s=3.0)
    ev = feed(ep, x, size)
    assert ev == ["speech_start", "end:silence"], ev
    # ended ~3 s after the speech, before the end of the input
    assert ep.pos < len(x) - 0.5 * SR, (ep.pos / SR, len(x) / SR)
    assert abs(ep.pos / SR - (1.0 + len(S1) / SR + 3.0)) < 0.6, ep.pos / SR
    a = ep.audio()
    assert abs(len(a) / SR - len(S1) / SR) < 0.8, (len(a) / SR, len(S1) / SR)
    assert ep.feed(noise(1.0)) == []  # ended: further audio is ignored


def test_silence_end_512():
    check_silence_end(512)


def test_silence_end_odd_chunks():
    for size in (100, 777, 1600, 4000):  # 1600 = the app's 100 ms frames
        check_silence_end(size)


def test_silence_s_config():
    x = np.concatenate([noise(0.5), S2, noise(1.5)])
    ep = Endpointer(silence_s=1.0)
    assert feed(ep, x, 1600) == ["speech_start", "end:silence"]


def test_pause_shorter_than_silence_keeps_recording():
    x = np.concatenate([noise(0.5), S1, noise(1.5), S2, noise(4.0)])
    ep = Endpointer(silence_s=3.0)
    assert feed(ep, x, 1600) == ["speech_start", "end:silence"]
    assert len(ep.audio()) / SR > (len(S1) + len(S2)) / SR + 1.0  # both parts kept


def test_no_speech_timeout():
    ep = Endpointer(start_timeout_s=2.0)
    ev = feed(ep, noise(5.0), 1600)
    assert ev == ["end:no_speech"] and abs(ep.pos / SR - 2.0) < 0.05, (ev, ep.pos / SR)
    assert len(ep.audio()) == 0


def test_max_duration():
    x = np.concatenate([S1, S1, S1, noise(4.0)])
    ep = Endpointer(max_duration_s=3.0)
    ev = feed(ep, x, 1600)
    assert ev == ["speech_start", "end:max_duration"], ev
    assert abs(ep.pos / SR - 3.0) < 0.05
    assert len(ep.audio()) > 2.5 * SR


def test_finish_and_cancel():
    ep = Endpointer()
    feed(ep, np.concatenate([noise(0.5), S1]), 1600)
    assert ep.speech_started and ep.end_reason is None
    assert ep.stop("finish") == "finish"
    assert abs(len(ep.audio()) / SR - len(S1) / SR) < 0.8

    ep = Endpointer()
    feed(ep, np.concatenate([noise(0.5), S1]), 1600)
    assert ep.stop("cancel") == "cancel" and len(ep.audio()) == 0

    ep = Endpointer()  # finish before any speech -> no_speech
    feed(ep, noise(1.0), 1600)
    assert ep.stop("finish") == "no_speech" and len(ep.audio()) == 0


def test_preroll_postroll():
    lead = 1.0
    x = np.concatenate([noise(lead), S1, noise(4.0)])
    ep = Endpointer()
    feed(ep, x, 512)
    lo, hi = ep._first_speech - int(0.3 * SR), ep._last_speech_end + int(0.2 * SR)
    assert abs(ep._first_speech / SR - lead) < 0.3, ep._first_speech / SR
    assert np.array_equal(ep.audio(), ep.raw[lo:hi])


if __name__ == "__main__":
    run_tests(dict(globals()))
