"""Plain-assert tests for terms.py. Run: uv run python tests/test_terms.py"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402
import yaml  # noqa: E402

import terms as T  # noqa: E402

TERMS = T.load_terms()
PASSED = []


def check(name):
    def deco(fn):
        fn()
        PASSED.append(name)
        print(f"ok  {name}")
        return fn
    return deco


@check("load_terms")
def _():
    assert len(TERMS) >= 35, len(TERMS)
    names = [t.term for t in TERMS]
    assert len(names) == len(set(names)), "duplicate canonical terms"
    for want in ["git", "branch", "pull request", "Go", "PostgreSQL", "socket", "WebSocket", "API"]:
        assert want in names, want
    assert all(isinstance(t.accept, list) and isinstance(t.fix, list) for t in TERMS)


@check("fix lists never contain an accepted form (would rewrite correct text)")
def _():
    accepted = {T._fold(f) for t in TERMS for f in T._accepted(t)}
    for t in TERMS:
        for f in t.fix:
            assert T._fold(f) not in accepted, (t.term, f)


@check("whisper prompt")
def _():
    prompt = T.build_whisper_prompt(TERMS)
    assert prompt.endswith(".") and "branch" in prompt and "PostgreSQL" in prompt, prompt
    print("    prompt:", prompt)
    try:
        from mlx_whisper.tokenizer import get_tokenizer
        n = len(get_tokenizer(True, num_languages=100, language="tr").encode(" " + prompt))
        print(f"    whisper tokens: {n} (limit ~224), estimate {T._estimate_tokens(prompt)}")
        assert n < 224, n
    except ImportError:
        import tiktoken
        n = len(tiktoken.get_encoding("gpt2").encode(prompt))
        print(f"    gpt2 tokens (rough): {n}")
    included = sum(1 for t in TERMS if t.term in prompt)
    print(f"    terms in prompt: {included}/{len(TERMS)}")
    assert T.hotwords(TERMS)[:3] == ["git", "branch", "commit"]


@check("apply_fixes")
def _():
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

    # directly attached suffix is deliberately not touched
    for s in ["brençi", "komite toplandı", "soketler"]:
        assert T.apply_fixes(s, TERMS)[0] == s, s

    plain = ("Geçen hafta İzmir'deki ailemi ziyaret ettim. Annem sofrayı çeşit çeşit yemeklerle "
             "donattı, babamla bahçedeki ağaçları budadık. Komite toplantısı yarın saat onda, "
             "dosyaları masanın üstüne bıraktım. Bugün işe gitmeden önce markete uğradım; pars "
             "belgeseli izledik, keş peyniri aldık, liman konteyneri ve marka imajı konuşuldu. "
             "Işıkları kapat, İstanbul'a gidiyoruz!")
    out, ch = T.apply_fixes(plain, TERMS)
    assert out == plain and ch == [], ch


@check("tr_lower / normalize")
def _():
    assert T.tr_lower("İSTANBUL IŞIK") == "istanbul ışık"
    assert T.normalize("  Bu branch'i, Main’e merge et!  ") == "bu branchi maine merge et"
    assert T.normalize("Saat 14:30'da.") == "saat 14 30da"
    assert T.normalize("API'ye") == T.normalize("api'ye") == "apiye"  # acronyms: English casing
    assert T.normalize("IŞIK İSTANBUL") == "ışık istanbul"  # Turkish words keep Turkish casing


@check("wer_cer")
def _():
    assert T.wer_cer("Bu branch'i sil.", "bu branch’i sil") == (0.0, 0.0)
    w, c = T.wer_cer("bu brenç'i sil", "bu branch'i sil")
    assert abs(w - 1 / 3) < 1e-9 and 0 < c < 1, (w, c)
    assert T.wer_cer("", "") == (0.0, 0.0)
    assert T.wer_cer("bir şey", "") == (1.0, 1.0)
    assert T.wer_cer("", "bir şey") == (1.0, 1.0)


@check("term_hits")
def _():
    ref = "Bu değişiklikleri commit'leyip main branch'e merge edelim."
    assert T.term_hits("bu değişiklikleri commitleyip main branche merge edelim", ref, TERMS) == (4, 4, [])
    hits, total, missed = T.term_hits("bu değişiklikleri komitleyip meyn brenç'e mörç edelim", ref, TERMS)
    assert (hits, total) == (0, 4) and set(missed) == {"commit", "main", "branch", "merge"}, missed

    ref = "PR'ı açtım, pull request'i de güncelledim, testleri çalıştır."
    assert T.term_hits("PR'ı açtım, Pull Request'i de güncelledim, testleri çalıştır", ref, TERMS) == (3, 3, [])
    assert T.term_hits("pi ar açtım", "PR'ı açtım", TERMS) == (0, 1, ["pull request"])
    assert T.term_hits("api'ye bak", "API'ye bak", TERMS)[0] == 1
    assert T.term_hits("Golang ile yaz", "Go ile yaz", TERMS) == (1, 1, [])
    assert T.term_hits("x", "Önce WebSocket, sonra socket.", TERMS)[1] == 2

    # Turkish words that start with a short term must not count
    for s in ["Bugün gitmek istiyorum.", "Restoranda logo tasarımını konuştuk, raporu okudum."]:
        assert T.term_hits(s, s, TERMS)[1] == 0, (s, T.term_hits(s, s, TERMS))


@check("test_sentences: schema, terms present in terms.yaml")
def _():
    data = yaml.safe_load(config.SENTENCES_YAML.read_text(encoding="utf-8"))
    items = data["sentences"]
    assert 28 <= len(items) <= 36, len(items)
    ids = [s["id"] for s in items]
    assert len(ids) == len(set(ids))

    proper_nouns = {"izmir", "öztürk", "istanbul", "yilmaz", "ahmet"}
    english_like = re.compile(r"w|q|x|ck|sh|th|ea|oo")
    known = {w for t in TERMS for f in T._accepted(t) for w in f.split()}
    used: set[str] = set()
    for s in items:
        text = s["text"]
        n = T.term_hits(text, text, TERMS)[1]
        if s["id"].startswith("gen"):
            assert n == 0, (s["id"], "everyday sentence matched a term")
        if s["id"].startswith("dev"):
            assert n >= 1, s["id"]
        used |= {t.term for t in TERMS if T._count(text, t)}
        for word in re.findall(r"[^\W\d_]+(?:'[^\W\d_]+)?", T._fold(text)):
            stem = word.split("'")[0]
            if "'" in word and stem not in proper_nouns:
                assert stem in known, (s["id"], word, "apostrophe stem is not a term")
            if english_like.search(stem):
                assert any(stem.startswith(k) for k in known), (s["id"], word, "English-looking, not a term")
    unused = [t.term for t in TERMS if t.term not in used]
    print(f"    {len(items)} sentences; terms used {len(used)}/{len(TERMS)}; unused: {unused}")


print(f"\n{len(PASSED)} checks passed")
