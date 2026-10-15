"""Languages (api.md v2): prompts, Turkish-only fixes, ui_language messages, config validation.
No model needed. Run: uv run python tests/test_languages.py"""

import asyncio
import re
import string
import tempfile
from pathlib import Path

from common import ENGINE_ROOT, run_tests

import dikte_engine.messages as M
import dikte_engine.terms as T
from dikte_engine import asr
from dikte_engine.catalog import BUILTIN
from dikte_engine.engine import GB, Engine, EngineError

TERMS = T.load_default_terms()


def _engine() -> Engine:
    d = Path(tempfile.mkdtemp(prefix="dikte_unit_"))
    (d / "models").mkdir()
    return Engine(d)


def test_prompt_per_language():
    tr, en = T.build_whisper_prompt(TERMS, "tr"), T.build_whisper_prompt(TERMS, "en")
    assert tr == T.build_whisper_prompt(TERMS) and tr.startswith("Bugün yazılım"), tr
    assert en.startswith("Today we'll work on these software topics: "), en
    # same term list, same budget (the shorter English lead-in may fit a few more terms)
    tr_names, en_names = (p.split(": ", 1)[1].rstrip(".").split(", ") for p in (tr, en))
    assert en_names[:len(tr_names)] == tr_names and len(tr_names) >= 20, (tr_names, en_names)
    for p in (tr, en):
        assert T._estimate_tokens(p) <= T._PROMPT_TOKEN_BUDGET
    from dikte_engine.shims import import_mlx_whisper

    import_mlx_whisper()
    from mlx_whisper.tokenizer import get_tokenizer

    for lang, p in (("tr", tr), ("en", en)):
        n = len(get_tokenizer(True, num_languages=100, language=lang).encode(" " + p))
        assert n < 224, (lang, n)
    assert T.build_whisper_prompt([], "en") == ""
    e = _engine()
    assert e.prompts == {"tr": tr, "en": en}


class FakeBackend(asr.Backend):
    def __init__(self, text: str, language: str):
        super().__init__(BUILTIN[0], Path("/nonexistent"))
        self.text, self.language, self.calls = text, language, []

    def transcribe(self, audio, *, language, prompts):
        self.calls.append((language, prompts))
        lang = self.language if language == "auto" else language
        return asr.Transcript(self.text, 0.1, lang)


def test_fixes_only_for_turkish():
    async def run():
        e = _engine()
        audio = asr.np.zeros(asr.SR, dtype="float32")
        b = FakeBackend("yeni bir brenç açalım", "tr")
        r = await e.transcribe(b, audio, "auto")
        assert r["language"] == "tr" and r["text"] == "yeni bir branch açalım", r
        assert r["fixes"] == [["brenç", "branch"]] and r["audio_s"] == 1.0
        assert b.calls[0] == ("auto", e.prompts)
        for lang, b in (("en", FakeBackend("open a brenç", "tr")),
                        ("auto", FakeBackend("open a brenç", "en"))):
            r = await e.transcribe(b, audio, lang)
            assert r["language"] == "en" and r["text"] == r["raw_text"] == "open a brenç", r
            assert r["fixes"] == [], r
        assert set(r) == {"raw_text", "text", "fixes", "audio_s", "transcribe_s", "model",
                          "language"}

    asyncio.run(run())


def test_messages_both_languages():
    fields = lambda s: {f for _, f, _, _ in string.Formatter().parse(s) if f}
    for key, texts in M.TEXTS.items():
        assert set(texts) == set(M.UI_LANGUAGES), key
        assert texts["tr"] != texts["en"] or key.startswith("note_"), key
        assert fields(texts["tr"]) == fields(texts["en"]), key
    assert M.render("insufficient_disk", "tr", min_free_gb=10 * GB).endswith("10,7 GB boş kalmalı.")
    assert "at least 10.7 GB" in M.render("insufficient_disk", "en", min_free_gb=10 * GB)
    # stored messages (and errors nested in them) follow the current language
    nested = M.Msg("download_failed", error=M.LocalizedError(M.Msg("checksum_failed", file="w")))
    err = EngineError(404, "unknown_model", M.Msg("unknown_model", id="x"))
    try:
        M.set_language("en")
        assert str(nested) == "Download failed: w: SHA-256 check failed", str(nested)
        assert err.body() == {"error": "unknown_model", "message": "Unknown model: x"}
        assert EngineError(409, "busy").message == "Another dictation is in progress."
    finally:
        M.set_language("tr")
    assert str(nested) == "İndirme başarısız: w: SHA-256 doğrulaması başarısız"
    assert err.message == "Bilinmeyen model: x"


def test_no_inline_texts():
    """Human-readable texts live in messages.py only (codes/details stay English)."""
    for name in ("engine.py", "server.py", "store.py", "asr.py", "catalog.py"):
        src = (ENGINE_ROOT / "dikte_engine" / name).read_text(encoding="utf-8")
        hits = [ln for ln in src.splitlines() if re.search(r"[çğıöşüÇĞİÖŞÜ]", ln)]
        assert not hits, (name, hits)


def test_config_validation_and_ui_language():
    async def run():
        e = _engine()
        assert e.config.language == "tr" and e.config.ui_language == "tr"
        for bad in [{"language": "de"}, {"language": "AUTO"}, {"language": 1},
                    {"ui_language": "auto"}, {"ui_language": None}, {"language": "auto", "x": 1}]:
            try:
                e.update_config(bad)
            except EngineError as err:
                assert err.status == 400 and err.code == "invalid_config", err.body()
                assert err.message.startswith("Geçersiz ayar"), err.message
                continue
            raise AssertionError(f"accepted {bad!r}")
        assert e.config.language == "tr"  # nothing applied
        for lang in ("auto", "en", "tr"):
            e.update_config({"language": lang})
            assert e.config.language == lang
        e.errors["large-v3"] = M.Msg("download_paused_disk", min_free_gb=10 * GB)
        assert e.model_info(BUILTIN[0])["error"].startswith("Diskte yeterli")
        assert e.model_info(BUILTIN[0])["note"].startswith("WER 7,9%")
        e.update_config({"ui_language": "en"})
        try:
            info = e.model_info(BUILTIN[0])
            assert info["error"].startswith("Not enough free disk space"), info["error"]
            assert info["note"] == "WER 7.9% · terms 96% · ~0.8 s", info["note"]
            try:
                e.update_config({"language": "fr"})
            except EngineError as err:
                assert err.message == "Invalid setting: language must be one of auto, tr, en"
        finally:
            e.update_config({"ui_language": "tr"})

    asyncio.run(run())


if __name__ == "__main__":
    run_tests(dict(globals()))
