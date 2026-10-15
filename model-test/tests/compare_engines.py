"""Phase-1 engine validation: re-transcribe the user's recordings with whisper.cpp (and read
WhisperKit reports if present), then score against the same references as the MLX run.

    uv run python tests/compare_engines.py [--whisperkit-reports DIR] [--skip-whispercpp]
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402

import argparse  # noqa: E402
import csv  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import statistics as st  # noqa: E402
import subprocess  # noqa: E402

import terms as T  # noqa: E402

WHISPERCPP_MODEL = config.MODELS_DIR / "whispercpp" / "ggml-large-v3.bin"
OUT_CSV = config.ROOT / "engine_results.csv"


def mlx_rows() -> dict[str, dict]:
    rows = csv.DictReader(open(config.RESULTS_CSV, encoding="utf-8"))
    return {Path(r["wav"]).name: r for r in rows
            if r["model"] == "large-v3" and r["reference"] and "184008" not in r["wav"]}


def run_whispercpp(wav: Path, prompt: str) -> tuple[str, float]:
    p = subprocess.run(
        ["whisper-cli", "-m", str(WHISPERCPP_MODEL), "-l", "tr", "--prompt", prompt,
         "-nt", "-bs", "0", "-bo", "1", "-nf", "-f", str(wav)],
        capture_output=True, text=True, check=True)
    t = {k: float(v) for k, v in re.findall(r"(\w+) time =\s+([\d.]+) ms", p.stderr)}
    # exclude model load (the app keeps the model resident); mel+encode+prompt+decode
    secs = (t.get("total", 0) - t.get("load", 0)) / 1000
    return " ".join(p.stdout.split()), secs


def score(name: str, items: list[tuple[str, str, float]], terms: list[T.Term]) -> dict:
    """items: (hyp, ref, seconds)"""
    w, c, hits, tot, secs, perfect = [], [], 0, 0, [], 0
    for hyp, ref, s in items:
        hyp, _ = T.apply_fixes(hyp, terms)
        a, b = T.wer_cer(hyp, ref)
        h, n, _ = T.term_hits(hyp, ref, terms)
        w.append(a); c.append(b); hits += h; tot += n; secs.append(s); perfect += a == 0
    return {"engine": name, "n": len(items), "wer": st.mean(w), "cer": st.mean(c),
            "terms": f"{hits}/{tot}", "term_acc": hits / tot, "perfect": perfect,
            "sec_mean": st.mean(secs), "sec_max": max(secs)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--whisperkit-reports", type=Path)
    ap.add_argument("--skip-whispercpp", action="store_true")
    args = ap.parse_args()

    terms = T.load_terms()
    prompt = T.build_whisper_prompt(terms)
    mlx = mlx_rows()
    results: dict[str, list[tuple[str, str, float]]] = {
        "mlx large-v3": [(r["text_raw"], r["reference"], float(r["transcribe_s"])) for r in mlx.values()]}
    texts: dict[str, dict[str, str]] = {"mlx large-v3": {n: r["text_raw"] for n, r in mlx.items()}}

    if not args.skip_whispercpp:
        items, tx = [], {}
        for i, (name, r) in enumerate(sorted(mlx.items()), 1):
            hyp, secs = run_whispercpp(config.RECORDINGS_DIR / name, prompt)
            items.append((hyp, r["reference"], secs)); tx[name] = hyp
            print(f"[{i}/{len(mlx)}] whisper.cpp {secs:.2f}s {r['sentence_id']}: {hyp}", flush=True)
        results["whisper.cpp large-v3"], texts["whisper.cpp large-v3"] = items, tx

    if args.whisperkit_reports:
        items, tx = [], {}
        for name, r in sorted(mlx.items()):
            f = args.whisperkit_reports / (Path(name).stem + ".json")
            if f.exists():
                d = json.loads(f.read_text())
                hyp = re.sub(r"<\|[^|]*\|>", "", d["text"]).strip()
                items.append((hyp, r["reference"], d["timings"]["fullPipeline"])); tx[name] = hyp
        results["whisperkit large-v3"], texts["whisperkit large-v3"] = items, tx

    print(f"\n{'motor':<22}{'n':>4}{'WER':>8}{'CER':>7}{'terim':>10}{'hatasız':>9}{'ort sn':>8}{'maks sn':>9}")
    for name, items in results.items():
        s = score(name, items, terms)
        print(f"{name:<22}{s['n']:>4}{s['wer']:>8.1%}{s['cer']:>7.1%}{s['terms']:>10}{s['perfect']:>9}"
              f"{s['sec_mean']:>8.2f}{s['sec_max']:>9.2f}")

    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["wav", "sentence_id", "reference", *texts])
        for name, r in sorted(mlx.items()):
            w.writerow([name, r["sentence_id"], r["reference"], *(t.get(name, "") for t in texts.values())])
    print(f"\nmetinler: {OUT_CSV.relative_to(config.ROOT)}")


if __name__ == "__main__":
    main()
