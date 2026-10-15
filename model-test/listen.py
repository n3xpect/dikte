"""Interactive Turkish STT test app.

    uv run listen.py                     # default model (large-v3)
    uv run listen.py --model turbo
    uv run listen.py --compare           # run every downloaded model on each recording
    uv run listen.py --script            # read sentences from test_sentences.yaml, score WER/terms
"""

import config  # noqa: F401  (must be first: sets HF cache dir)

import argparse
import csv
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime

import yaml

import audio
import backends
import terms as termlib

BOLD, DIM, GREEN, YELLOW, RED, CYAN, RESET = (
    "\033[1m", "\033[2m", "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[0m")

CSV_FIELDS = [
    "time", "wav", "sentence_id", "model", "prompt", "end_reason", "audio_s",
    "transcribe_s", "latency_s", "fixes", "text_raw", "text",
    "reference", "wer", "cer", "term_hits", "term_total", "terms_missed",
]


@dataclass
class State:
    models: list[str]
    compare: bool
    prompt_on: bool
    silence_s: float
    script: bool
    sentences: list[dict] = field(default_factory=list)
    sentence_idx: int = 0
    last: audio.Recording | None = None
    last_wav: str = ""
    last_sentence: dict | None = None

    def active_models(self) -> list[str]:
        return self.models if self.compare else self.models[:1]


def log(msg: str, color: str = "") -> None:
    print(f"{color}{msg}{RESET}" if color else msg, flush=True)


def load_backend(key: str) -> backends.Backend:
    log(f"⏳ {key} yükleniyor...", DIM)
    b = backends.get_backend(key)
    t0 = time.perf_counter()
    backends.warmup(b)
    log(f"✅ {b.spec.label} hazır (yükleme {b.load_seconds or 0:.1f} sn, ısınma {time.perf_counter() - t0:.1f} sn)",
        GREEN)
    return b


def on_status(event: str) -> None:
    labels = {
        "listening": ("🎙  Dinliyorum... (bitirmek için sus)", CYAN),
        "speech_start": ("🗣  Konuşma algılandı", DIM),
    }
    if event in labels:
        log(*labels[event])
    elif event.startswith("end:"):
        reasons = {"silence": "sessizlik", "max_duration": "azami süre",
                   "manual": "elle durduruldu", "no_speech": "konuşma algılanmadı"}
        r = event.split(":", 1)[1]
        log(f"⏹  Bitti: {reasons.get(r, r)}", CYAN)


def transcribe_and_report(state: State, rec: audio.Recording, wav: str, sentence: dict | None,
                          term_list: list[termlib.Term], prompt: str, hotwords: list[str]) -> None:
    ref = sentence["text"] if sentence else ""
    rows = []
    for i, key in enumerate(state.active_models()):
        b = backends.get_backend(key)
        res = b.transcribe(rec.audio, prompt=prompt if state.prompt_on else None,
                           hotwords=hotwords if state.prompt_on else None)
        latency = time.perf_counter() - rec.t_end_detected if i == 0 else None
        text, fixes = termlib.apply_fixes(res.text.strip(), term_list)

        log(f"\n{BOLD}[{b.spec.label}]{RESET} {DIM}prompt={'açık' if res.prompt_used else 'kapalı'}{RESET}")
        log(f"📝 {text}")
        timing = f"⏱  çeviri {res.seconds:.2f} sn"
        if latency is not None:
            timing += f" · konuşma bitişinden metne {latency:.2f} sn"
        if fixes:
            timing += f" · düzeltme: {', '.join(f'{a}→{b_}' for a, b_ in fixes)}"
        log(timing, DIM)

        row = {
            "time": datetime.now().isoformat(timespec="seconds"), "wav": wav,
            "sentence_id": sentence["id"] if sentence else "", "model": key,
            "prompt": int(res.prompt_used), "end_reason": rec.end_reason,
            "audio_s": round(rec.duration_s, 2), "transcribe_s": round(res.seconds, 3),
            "latency_s": round(latency, 3) if latency is not None else "",
            "fixes": "; ".join(f"{a}->{b_}" for a, b_ in fixes),
            "text_raw": res.text.strip(), "text": text, "reference": ref,
        }
        if ref:
            wer, cer = termlib.wer_cer(text, ref)
            hits, total, missed = termlib.term_hits(text, ref, term_list)
            color = GREEN if wer < 0.1 else YELLOW if wer < 0.25 else RED
            log(f"🎯 WER {wer:.1%} · CER {cer:.1%} · terim {hits}/{total}"
                + (f" · kaçan: {', '.join(missed)}" if missed else ""), color)
            row.update(wer=round(wer, 4), cer=round(cer, 4), term_hits=hits, term_total=total,
                       terms_missed="; ".join(missed))
        rows.append(row)

    new = not config.RESULTS_CSV.exists()
    with open(config.RESULTS_CSV, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        if new:
            w.writeheader()
        w.writerows(rows)


def choose_model(state: State) -> None:
    keys = backends.available_keys()
    for i, k in enumerate(keys, 1):
        mark = "●" if k == state.models[0] else " "
        log(f"  {mark} {i}) {k:<11} {backends.MODELS[k].label}")
    pick = input("Model numarası: ").strip()
    if pick.isdigit() and 1 <= int(pick) <= len(keys):
        key = keys[int(pick) - 1]
        load_backend(key)
        state.models = [key] + [k for k in state.models if k != key]


def help_line(state: State) -> str:
    mode = f"karşılaştırma ({', '.join(state.models)})" if state.compare else state.models[0]
    parts = [f"model: {BOLD}{mode}{RESET}", f"prompt: {'açık' if state.prompt_on else 'kapalı'}",
             f"sessizlik: {state.silence_s:g} sn"]
    keys = "[Enter] konuş · [r] son kaydı tekrar çevir · [m] model · [c] karşılaştırma · [p] prompt · [q] çık"
    if state.script:
        keys = "[Enter] konuş · [n] sonraki cümle · [b] önceki · " + keys.split("· ", 1)[1]
    return f"\n{DIM}{' · '.join(parts)}{RESET}\n{DIM}{keys}{RESET}"


def main() -> None:
    p = argparse.ArgumentParser(description="Türkçe STT test uygulaması")
    p.add_argument("--model", default="large-v3", help=f"model anahtarı: {', '.join(backends.MODELS)}")
    p.add_argument("--compare", nargs="*", metavar="KEY",
                   help="her kaydı birden fazla modelle çevir (anahtar verilmezse indirilmiş tüm modeller)")
    p.add_argument("--no-prompt", action="store_true", help="terim ipucunu (prompt/hotwords) kapat")
    p.add_argument("--silence", type=float, default=3.0, help="bitiş için sessizlik süresi (sn)")
    p.add_argument("--script", action="store_true", help="test_sentences.yaml cümlelerini okut ve puanla")
    args = p.parse_args()

    available = backends.available_keys()
    if not available:
        sys.exit("Hiç model indirilmemiş. Önce: uv run download.py")
    if args.compare is not None:
        models = args.compare or available
    else:
        models = [args.model]
    missing = [k for k in models if k not in available]
    if missing:
        sys.exit(f"İndirilmemiş model(ler): {', '.join(missing)}. İndir: uv run download.py {' '.join(missing)}")

    try:
        peak = audio.check_mic()
        log(f"🎤 Mikrofon çalışıyor (tepe seviye {peak:.3f})", DIM)
    except audio.MicPermissionError as e:
        sys.exit(f"{RED}{e}\nSistem Ayarları → Gizlilik ve Güvenlik → Mikrofon bölümünden terminal "
                 f"uygulamana izin ver ve terminali yeniden başlat.{RESET}")

    term_list = termlib.load_terms()
    prompt = termlib.build_whisper_prompt(term_list)
    hotwords = termlib.hotwords(term_list)
    log(f"📚 {len(term_list)} terim yüklendi", DIM)

    state = State(models=models, compare=args.compare is not None, prompt_on=not args.no_prompt,
                  silence_s=args.silence, script=args.script)
    if state.script:
        state.sentences = yaml.safe_load(config.SENTENCES_YAML.read_text(encoding="utf-8"))["sentences"]

    for key in state.active_models():
        load_backend(key)
    config.RECORDINGS_DIR.mkdir(exist_ok=True)

    while True:
        sentence = state.sentences[state.sentence_idx] if state.script else None
        log(help_line(state))
        if sentence:
            log(f"\n{BOLD}[{state.sentence_idx + 1}/{len(state.sentences)}] {sentence['id']}{RESET}\n"
                f"  {YELLOW}{sentence['text']}{RESET}")
        try:
            cmd = input("> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            break

        if cmd == "q":
            break
        if cmd == "m":
            choose_model(state)
            continue
        if cmd == "c":
            state.compare = not state.compare
            if state.compare and len(state.models) == 1:
                state.models += [k for k in backends.available_keys() if k not in state.models]
            for key in state.active_models():
                load_backend(key)
            continue
        if cmd == "p":
            state.prompt_on = not state.prompt_on
            continue
        if state.script and cmd in ("n", "b"):
            step = 1 if cmd == "n" else -1
            state.sentence_idx = (state.sentence_idx + step) % len(state.sentences)
            continue
        if cmd == "r":
            if state.last is None:
                log("Henüz kayıt yok.", YELLOW)
                continue
            transcribe_and_report(state, state.last, state.last_wav, state.last_sentence,
                                  term_list, prompt, hotwords)
            continue
        if cmd:
            log("Bilinmeyen komut.", YELLOW)
            continue

        rec = audio.record_utterance(silence_s=state.silence_s, on_status=on_status)
        if rec.end_reason == "no_speech" or rec.duration_s < 0.3:
            log("Konuşma algılanmadı.", YELLOW)
            continue

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        name = f"{stamp}_{sentence['id']}.wav" if sentence else f"{stamp}.wav"
        wav_path = config.RECORDINGS_DIR / name
        audio.save_wav(wav_path, rec.audio)
        log(f"💾 {rec.duration_s:.1f} sn ses → recordings/{name}", DIM)

        state.last, state.last_wav, state.last_sentence = rec, str(wav_path.relative_to(config.ROOT)), sentence
        transcribe_and_report(state, rec, state.last_wav, sentence, term_list, prompt, hotwords)
        if state.script:
            state.sentence_idx = (state.sentence_idx + 1) % len(state.sentences)

    log("Görüşürüz 👋")


if __name__ == "__main__":
    main()
