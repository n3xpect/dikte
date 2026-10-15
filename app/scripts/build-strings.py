#!/usr/bin/env python3
"""Merge app/dikte/i18n/*.json (Turkish key → English text) into the String Catalog and check
coverage against the source.

    python3 app/scripts/build-strings.py          # merge + check
    python3 app/scripts/build-strings.py --check  # check only (exit 1 on problems)

Checks: every L("…") key used in app/dikte/Sources has an English translation; format
specifiers (%@, %d, %lld, %.1f, …) match between Turkish and English; the same key isn't
translated differently in two JSON files. Keys no longer used in the source are reported
(and dropped from the catalog on merge).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "dikte"
I18N = APP / "i18n"
CATALOG = APP / "Sources" / "Resources" / "Localizable.xcstrings"
SOURCES = APP / "Sources"

# L("…") / L("…", args) — first argument is a plain string literal (escapes allowed).
CALL = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfFeEgGcCsSaA%]")


def unescape(s: str) -> str:
    return s.encode().decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in s else s


def used_keys() -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for f in sorted(SOURCES.rglob("*.swift")):
        code = "\n".join(line for line in f.read_text(encoding="utf-8").splitlines()
                         if not line.lstrip().startswith("//"))  # skip doc-comment examples
        for m in CALL.finditer(code):
            keys.setdefault(unescape(m.group(1)), []).append(str(f.relative_to(APP)))
    return keys


def specs(s: str) -> list[str]:
    return sorted(x for x in SPEC.findall(s) if x != "%%")


def main() -> int:
    check_only = "--check" in sys.argv
    problems: list[str] = []

    translations: dict[str, str] = {}
    origin: dict[str, str] = {}
    for f in sorted(I18N.glob("*.json")):
        for k, v in json.loads(f.read_text(encoding="utf-8")).items():
            if k in translations and translations[k] != v:
                problems.append(f"farklı çeviri: {k!r}: {origin[k]}={translations[k]!r} / {f.name}={v!r}")
            translations.setdefault(k, v)
            origin.setdefault(k, f.name)
    if not check_only and CATALOG.exists():  # keep translations already in the catalog
        for k, v in json.loads(CATALOG.read_text(encoding="utf-8")).get("strings", {}).items():
            en = v.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
            if en and k not in translations:
                translations[k] = en

    used = used_keys()
    for k, files in sorted(used.items()):
        if k not in translations:
            problems.append(f"çevirisi yok: {k!r} ({files[0]})")
        elif specs(k) != specs(translations[k]):
            problems.append(f"biçim belirteci uyuşmuyor: {k!r} → {translations[k]!r}")
    unused = sorted(set(translations) - set(used))

    if not check_only:
        catalog = {
            "sourceLanguage": "tr",
            "strings": {
                k: {"localizations": {"en": {"stringUnit": {"state": "translated",
                                                             "value": translations[k]}}}}
                for k in sorted(used) if k in translations
            },
            "version": "1.0",
        }
        CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"{CATALOG.relative_to(APP.parent.parent)}: {len(catalog['strings'])} metin")

    print(f"kodda {len(used)} metin, çevirisi olan {sum(k in translations for k in used)}")
    if unused:
        print(f"kullanılmayan {len(unused)} çeviri (katalogdan çıkarıldı): " + ", ".join(map(repr, unused[:10]))
              + (" …" if len(unused) > 10 else ""))
    for p in problems:
        print("✗", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
