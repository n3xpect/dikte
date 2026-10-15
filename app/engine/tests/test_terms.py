"""Term prompt / fixes / scoring. Run: uv run python tests/test_terms.py"""

import json

from common import run_tests

import dikte_engine.terms as T

TERMS = T.load_default_terms()


def test_default_terms():
    assert len(TERMS) >= 35, len(TERMS)
    names = [t.term for t in TERMS]
    assert len(names) == len(set(names)), "duplicate canonical terms"
    for want in ["git", "branch", "pull request", "Go", "PostgreSQL", "socket", "WebSocket", "API"]:
        assert want in names, want
    raw = json.loads(T.DEFAULT_TERMS_JSON.read_text(encoding="utf-8"))["terms"]
    assert raw == T.default_terms_json() and all(set(t) == {"term", "accept", "fix"} for t in raw)


def test_parse_terms():
    ts = T.parse_terms([{"term": " x ", "accept": "y", "fix": ["z", " "]}, {"term": "w"}])
    assert [(t.term, t.accept, t.fix) for t in ts] == [("x", ["y"], ["z"]), ("w", [], [])]
    for bad in [{"term": "x"}, [{"accept": []}], [{"term": ""}], [{"term": "x", "fix": 3}]]:
        try:
            T.parse_terms(bad)
        except ValueError:
            continue
        raise AssertionError(f"accepted {bad!r}")


def test_fix_lists_never_contain_accepted_form():
    accepted = {T._fold(f) for t in TERMS for f in T._accepted(t)}
    for t in TERMS:
        for f in t.fix:
            assert T._fold(f) not in accepted, (t.term, f)


def test_whisper_prompt():
    prompt = T.build_whisper_prompt(TERMS)
    assert prompt.endswith(".") and "branch" in prompt and "PostgreSQL" in prompt, prompt
    from dikte_engine.shims import import_mlx_whisper

    import_mlx_whisper()
    from mlx_whisper.tokenizer import get_tokenizer

    n = len(get_tokenizer(True, num_languages=100, language="tr").encode(" " + prompt))
    assert n < 224, n
    assert T.build_whisper_prompt([]) == ""


def test_apply_fixes():
    out, ch = T.apply_fixes("yeni bir brenç açalım", TERMS)
    assert out == "yeni bir branch açalım" and ch == [("brenç", "branch")], (out, ch)
    out, _ = T.apply_fixes("bu brenç'i sil, sonra brenc’e geç", TERMS)
    assert out == "bu branch'i sil, sonra branch’e geç", out
    out, _ = T.apply_fixes("Brenç açtım.", TERMS)
    assert out == "Branch açtım.", out
    out, ch = T.apply_fixes("Veb App ile soket bağlantısı, Postgres kuel ve web soket.", TERMS)
    assert out == "Web app ile socket bağlantısı, PostgreSQL ve WebSocket.", out
    assert len(ch) == 4, ch
    out, _ = T.apply_fixes("EYPİAY'ye istek at, KOMİT'le", TERMS)
    assert out == "API'ye istek at, commit'le", out
    for s in ["brençi", "komite toplandı", "soketler"]:  # attached suffix: untouched
        assert T.apply_fixes(s, TERMS)[0] == s, s
    plain = ("Geçen hafta İzmir'deki ailemi ziyaret ettim. Komite toplantısı yarın saat onda. "
             "Bugün işe gitmeden önce markete uğradım; pars belgeseli izledik, keş peyniri "
             "aldık, liman konteyneri ve marka imajı konuşuldu. Işıkları kapat!")
    assert T.apply_fixes(plain, TERMS) == (plain, [])
    assert T.apply_fixes("", TERMS) == ("", [])


def test_normalize_and_wer():
    assert T.normalize("  Bu branch'i, Main’e merge et!  ") == "bu branchi maine merge et"
    assert T.normalize("API'ye") == T.normalize("api'ye") == "apiye"
    assert T.normalize("IŞIK İSTANBUL") == "ışık istanbul"
    assert T.wer_cer("Bu branch'i sil.", "bu branch’i sil") == (0.0, 0.0)
    w, c = T.wer_cer("bu brenç'i sil", "bu branch'i sil")
    assert abs(w - 1 / 3) < 1e-9 and 0 < c < 1


def test_term_hits():
    ref = "Bu değişiklikleri commit'leyip main branch'e merge edelim."
    assert T.term_hits("bu değişiklikleri commitleyip main branche merge edelim", ref, TERMS) == (4, 4, [])
    hits, total, missed = T.term_hits("komitleyip meyn brenç'e mörç edelim", ref, TERMS)
    assert (hits, total) == (0, 4) and set(missed) == {"commit", "main", "branch", "merge"}
    for s in ["Bugün gitmek istiyorum.", "Restoranda logo tasarımını konuştuk, raporu okudum."]:
        assert T.term_hits(s, s, TERMS)[1] == 0, s


if __name__ == "__main__":
    run_tests(dict(globals()))
