"""English + language detection on synthetic speech (tests/en_sentences.yaml, macOS `say`):
English sentences with several English voices, language auto vs forced en (WER, terms, latency);
very short utterances in both languages (detection with little audio; Turkish uses Yelda).
Run: uv run python tests/test_english.py"""

import asyncio
import statistics as st
import sys
from pathlib import Path

import numpy as np
import yaml
from common import EngineProc, Events, dictate, make_data_dir, model_of, noise, tts

import dikte_engine.terms as T

EN_VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Rishi"]
MAX_WER, MIN_TERM_ACC = 0.10, 0.90
MIN_DETECT_LONG, MIN_DETECT_SHORT = 1.0, 0.85


async def run_set(eng: EngineProc, clips: list[dict], language: str) -> list[dict]:
    assert await eng.req("PUT", "/config", {"language": language}) == (200, {"ok": True})
    terms, rows = T.load_default_terms(), []
    for c in clips:
        r = await dictate(eng, np.concatenate([noise(0.3), c["audio"], noise(3.5)]), speed=0)
        res = r["result"] or {"text": "", "language": None, "transcribe_s": 0.0}
        wer, _ = T.wer_cer(res["text"], c["text"])
        hits, total, _ = T.term_hits(res["text"], c["text"], terms)
        rows.append({**c, "hyp": res["text"], "detected": res["language"], "wer": wer,
                     "hits": hits, "total": total, "transcribe_s": res["transcribe_s"]})
    return rows


def summary(name: str, rows: list[dict]) -> dict:
    hits, total = sum(r["hits"] for r in rows), sum(r["total"] for r in rows)
    out = {"wer": st.mean(r["wer"] for r in rows), "terms": (hits, total),
           "detect": sum(r["detected"] == r["lang"] for r in rows) / len(rows),
           "transcribe_s": st.mean(r["transcribe_s"] for r in rows)}
    print(f"{name:22} n={len(rows):3}  WER {out['wer']:5.1%}  terms {hits}/{total}  "
          f"lang ok {out['detect']:.0%}  transcribe_s {out['transcribe_s']:.3f}", flush=True)
    for r in rows:
        if r["detected"] != r["lang"] or r["wer"] > 0.25:
            print(f"    {r['voice']:8} [{r['detected']}] {r['text']!r} -> {r['hyp']!r}")
    return out


async def main() -> int:
    data = yaml.safe_load((Path(__file__).with_name("en_sentences.yaml")).read_text("utf-8"))
    long = [{"text": s["text"], "lang": "en", "voice": v, "audio": tts(s["text"], v)}
            for s in data["sentences"] for v in EN_VOICES]
    short = [{"text": s["text"], "lang": s["lang"], "voice": v, "audio": tts(s["text"], v)}
             for s in data["short"] for v in (EN_VOICES if s["lang"] == "en" else ["Yelda"])]
    eng = EngineProc(make_data_dir())
    await eng.start()
    try:
        async with Events(eng) as ev:
            mark = ev.mark()
            await eng.req("POST", "/models/large-v3/load")
            await ev.wait_for(lambda s: model_of(s, "large-v3")["state"] == "loaded", 120,
                              since=mark)
            auto = summary("EN long, auto", await run_set(eng, long, "auto"))
            forced = summary("EN long, forced en", await run_set(eng, long, "en"))
            short_rows = await run_set(eng, short, "auto")
            for lang in ("en", "tr"):
                summary(f"short {lang}, auto", [r for r in short_rows if r["lang"] == lang])
    finally:
        await eng.stop()

    added = (auto["transcribe_s"] - forced["transcribe_s"]) * 1000
    print(f"auto vs forced en: +{added:.0f} ms transcribe_s")
    short_detect = st.mean(r["detected"] == r["lang"] for r in short_rows)
    ok = (auto["detect"] >= MIN_DETECT_LONG and auto["wer"] <= MAX_WER
          and forced["wer"] <= MAX_WER
          and min(auto["terms"][0], forced["terms"][0]) >= MIN_TERM_ACC * auto["terms"][1]
          and short_detect >= MIN_DETECT_SHORT)
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
