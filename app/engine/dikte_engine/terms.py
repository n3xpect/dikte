"""Term library: Whisper prompt, output fixes and scoring helpers.

Suffix handling (Turkish attaches suffixes to English terms):
- apply_fixes only keeps a suffix written after an apostrophe ("brenç'i" -> "branch'i").
  A directly attached suffix ("brençi") is left alone on purpose: "komit" + "e" is
  "komite", a real word, so guessing there would corrupt normal text.
- term_hits always accepts an apostrophe suffix. For forms of 4+ characters it also
  accepts a directly attached suffix ("testleri", "repoyu") when it starts with a letter
  that can begin a Turkish suffix. 2-3 character forms need the apostrophe
  ("bug" + "ün" = "bugün", "git" + "mek" = "gitmek").

Matching folds case Turkish-style and treats ı/i as equal; normalize() (WER) keeps ı/i.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_TERMS_JSON = Path(__file__).with_name("default_terms.json")

APOSTROPHES = "'’‘ʼ`´"
_APOS_CLASS = "[" + re.escape(APOSTROPHES) + "]"
# Letters a directly attached Turkish suffix can start with (no o/ö/r/p/b/f/g/h/j/v/z).
_ATTACHED_SUFFIX = r"[aeıiuüldtnysmkcçğ][^\W\d_]*"
_ATTACHED_MIN_LEN = 4
_PROMPT_TOKEN_BUDGET = 150
_PROMPT_HEAD = "Bugün yazılım projesinde şu konular üzerinde çalışacağız: "


@dataclass
class Term:
    term: str
    accept: list[str] = field(default_factory=list)
    fix: list[str] = field(default_factory=list)


def _as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        raise ValueError(f"expected a list of strings, got {value!r}")
    return [str(v).strip() for v in value if str(v).strip()]


def parse_terms(items: Any) -> list[Term]:
    """[{term, accept, fix}] (JSON) -> [Term]. Raises ValueError on malformed input."""
    if not isinstance(items, list):
        raise ValueError("terms must be a list")
    out = []
    for i, item in enumerate(items):
        if not isinstance(item, dict) or not str(item.get("term") or "").strip():
            raise ValueError(f"terms[{i}] has no 'term': {item!r}")
        out.append(Term(str(item["term"]).strip(), _as_list(item.get("accept")),
                        _as_list(item.get("fix"))))
    return out


def default_terms_json() -> list[dict]:
    return json.loads(DEFAULT_TERMS_JSON.read_text(encoding="utf-8"))["terms"]


def load_default_terms() -> list[Term]:
    return parse_terms(default_terms_json())


def _estimate_tokens(text: str) -> int:
    # Whisper's multilingual BPE measures ~3.7 chars/token on this kind of term list;
    # 3.0 keeps a safety margin.
    return int(len(text) / 3.0) + 1


def build_whisper_prompt(terms: list[Term]) -> str:
    """Natural punctuated Turkish sentence listing the canonical terms (first N that fit)."""
    names: list[str] = []
    for t in terms:
        candidate = _PROMPT_HEAD + ", ".join(names + [t.term]) + "."
        if _estimate_tokens(candidate) > _PROMPT_TOKEN_BUDGET:
            break
        names.append(t.term)
    return _PROMPT_HEAD + ", ".join(names) + "." if names else ""


def tr_lower(s: str) -> str:
    return s.replace("İ", "i").replace("I", "ı").lower()


def _fold(s: str) -> str:
    """Length-preserving matching key: Turkish lowercase, ı==i, unified apostrophes."""
    out = []
    for c in s:
        lc = tr_lower(c)
        if len(lc) != 1:
            lc = c
        if lc == "ı":
            lc = "i"
        elif lc in APOSTROPHES:
            lc = "'"
        out.append(lc)
    return "".join(out)


def _form_pattern(form: str) -> str:
    return r"\s+".join(re.escape(w) for w in _fold(form).split())


def _accepted(t: Term) -> list[str]:
    forms = {_fold(f).strip(): f for f in [t.term, *t.accept]}
    return sorted(forms, key=len, reverse=True)


def apply_fixes(text: str, terms: list[Term]) -> tuple[str, list[tuple[str, str]]]:
    """Replace known misspellings with canonical terms. Returns (text, [(wrong, right)])."""
    by_form: dict[str, str] = {}
    for t in terms:
        canon = _fold(t.term)
        for f in t.fix:
            key = " ".join(_fold(f).split())
            if key and key != canon:
                by_form.setdefault(key, t.term)
    if not text or not by_form:
        return text, []

    alts = "|".join(_form_pattern(f) for f in sorted(by_form, key=len, reverse=True))
    pattern = re.compile(rf"(?<!\w)(?P<stem>{alts})(?P<suf>'\w+)?(?!\w)")

    folded = _fold(text)  # same length as text, so spans map 1:1
    out, changes, pos = [], [], 0
    for m in pattern.finditer(folded):
        start, stem_end = m.span("stem")
        wrong = text[start:stem_end]
        right = by_form[" ".join(m.group("stem").split())]
        if wrong[:1].isupper() and not wrong.isupper() and right == right.lower():
            right = right[:1].upper() + right[1:]  # sentence-initial "Brenç" -> "Branch"
        out.append(text[pos:start])
        out.append(right)
        pos = stem_end  # suffix (with the user's own apostrophe char) is copied as-is
        changes.append((wrong, right))
    out.append(text[pos:])
    return "".join(out), changes


# --------------------------------------------------------------------------- scoring

def normalize(text: str) -> str:
    """WER normalisation: Turkish lowercase, apostrophes joined, punctuation dropped.
    All-caps ASCII acronyms are lowercased the English way so "API" == "api" (not "apı")."""
    s = re.sub(r"(?<!\w)[A-Z]{2,}(?!\w)", lambda m: m.group().lower(), text or "")
    s = tr_lower(s)
    s = re.sub(_APOS_CLASS, "", s)
    s = re.sub(r"[^\w\s]|_", " ", s)
    return " ".join(s.split())


def wer_cer(hyp: str, ref: str) -> tuple[float, float]:
    import jiwer  # dev dependency (tests only)

    h, r = normalize(hyp), normalize(ref)
    if not r:
        return (0.0, 0.0) if not h else (1.0, 1.0)
    if not h:
        return 1.0, 1.0
    return float(jiwer.wer(r, h)), float(jiwer.cer(r, h))


def _term_regex(t: Term) -> re.Pattern[str]:
    alts = []
    for f in _accepted(t):
        p = _form_pattern(f)
        if len(f) >= _ATTACHED_MIN_LEN:
            alts.append(rf"{p}(?:'\w*|{_ATTACHED_SUFFIX})?")
        else:
            alts.append(rf"{p}(?:'\w*)?")
    return re.compile(rf"(?<!\w)(?:{'|'.join(alts)})(?!\w)")


def _count(text: str, t: Term) -> int:
    return len(_term_regex(t).findall(_fold(text or "")))


def term_hits(hyp: str, ref: str, terms: list[Term]) -> tuple[int, int, list[str]]:
    """Per term: occurrences in ref vs. occurrences of an accepted form in hyp."""
    hits = total = 0
    missed: list[str] = []
    for t in terms:
        n_ref = _count(ref, t)
        if not n_ref:
            continue
        n_hit = min(n_ref, _count(hyp, t))
        total += n_ref
        hits += n_hit
        missed.extend([t.term] * (n_ref - n_hit))
    return hits, total, missed
