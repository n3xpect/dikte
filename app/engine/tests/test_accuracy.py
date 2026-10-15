"""Accuracy regression: stream the user's recordings (model-test/recordings) through /dictate
with large-v3 + default terms and score against the sentences they read
(model-test/test_sentences.yaml; the id is the file name suffix, e.g. `…_dev02.wav`).
Prior MLX bench: WER ~7.6–7.9%, terms 74/77. With language auto every take must be detected as tr.
Run: uv run python tests/test_accuracy.py [auto|tr]   (config language, default auto)"""

import asyncio
import statistics as st
import sys

import numpy as np
import yaml
from common import MODEL_TEST, EngineProc, Events, dictate, load_wav, make_data_dir, model_of, noise

import dikte_engine.terms as T

SKIP = {"20261015-184008_dev01.wav"}  # 120 s noise take
MAX_WER, MIN_TERM_ACC = 0.10, 0.93


def references() -> dict[str, tuple[str, str]]:
    """wav file name → (sentence id, reference text)."""
    data = yaml.safe_load((MODEL_TEST / "test_sentences.yaml").read_text(encoding="utf-8"))
    texts = {s["id"]: s["text"] for s in data["sentences"]}
    out = {}
    for wav in sorted((MODEL_TEST / "recordings").glob("*.wav")):
        sid = wav.stem.rsplit("_", 1)[-1]
        if wav.name not in SKIP and sid in texts:
            out[wav.name] = (sid, texts[sid])
    return out


async def main(language: str) -> int:
    refs = references()
    terms = T.load_default_terms()
    eng = EngineProc(make_data_dir())
    await eng.start()
    rows = []
    try:
        async with Events(eng) as ev:
            _, d = await eng.req("GET", "/terms/default")
            await eng.req("PUT", "/config", {"selected_model": "large-v3", "terms": d["terms"],
                                             "language": language})
            mark = ev.mark()
            await eng.req("POST", "/models/large-v3/load")
            await ev.wait_for(lambda s: model_of(s, "large-v3")["state"] == "loaded", 120,
                              since=mark)
            for i, (name, (sid, ref)) in enumerate(sorted(refs.items()), 1):
                speech = load_wav(MODEL_TEST / "recordings" / name)
                audio = np.concatenate([noise(0.3), speech, noise(3.5)])
                r = await dictate(eng, audio, chunk_s=0.1, speed=8.0)
                res = r["result"]
                assert res is not None, (name, r["msgs"])
                end = next(m for m in r["msgs"] if m["type"] == "end")["reason"]
                wer, cer = T.wer_cer(res["text"], ref)
                hits, total, missed = T.term_hits(res["text"], ref, terms)
                rows.append({"id": sid, "wer": wer, "cer": cer, "hits": hits, "total": total,
                             "language": res["language"],
                             "transcribe_s": res["transcribe_s"],
                             "latency_s": r["t_result"] - r["t_end"], "end": end})
                flag = "" if wer == 0 else f"  <- {res['text']!r} | missed {missed}"
                print(f"[{i:2}/{len(refs)}] {sid:6} {end:8} {res['language']} WER {wer:5.1%} terms {hits}/{total}"
                      f" {res['transcribe_s']:.2f}s{flag}", flush=True)
    finally:
        await eng.stop()

    hits = sum(r["hits"] for r in rows)
    total = sum(r["total"] for r in rows)
    wer = st.mean(r["wer"] for r in rows)
    print(f"\nn={len(rows)}  mean WER {wer:.1%}  mean CER {st.mean(r['cer'] for r in rows):.1%}  "
          f"terms {hits}/{total} ({hits / total:.0%})  perfect {sum(r['wer'] == 0 for r in rows)}")
    print(f"transcribe_s mean {st.mean(r['transcribe_s'] for r in rows):.2f} "
          f"max {max(r['transcribe_s'] for r in rows):.2f} | end->result mean "
          f"{st.mean(r['latency_s'] for r in rows):.2f} max {max(r['latency_s'] for r in rows):.2f}")
    print(f"end reasons: {sorted({r['end'] for r in rows})}  language {language}: "
          f"{sum(r['language'] == 'tr' for r in rows)}/{len(rows)} tr")
    ok = (len(rows) == len(refs) and wer <= MAX_WER and hits / total >= MIN_TERM_ACC
          and all(r["end"] == "silence" and r["language"] == "tr" for r in rows))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "auto")))
