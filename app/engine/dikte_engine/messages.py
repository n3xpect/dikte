"""Every human-readable text the engine sends, in Turkish and English (config `ui_language`).

Messages are kept as Msg(key, **params) and rendered when sent, so stored errors (ModelInfo.error)
follow a later ui_language change. Params named `*_gb` are byte counts, formatted per language.
"""

from __future__ import annotations

from typing import Any

UI_LANGUAGES = ("tr", "en")

TEXTS: dict[str, dict[str, str]] = {
    # HTTP / WS errors (key = error code unless noted)
    "unauthorized": {"tr": "Yetkisiz istek.", "en": "Unauthorized request."},
    "invalid_json": {"tr": "Geçersiz JSON.", "en": "Invalid JSON."},
    "bad_request": {"tr": "Geçersiz istek: {detail}", "en": "Bad request: {detail}"},
    "start_expected": {"tr": "İlk mesaj start olmalı.", "en": "The first message must be start."},
    "invalid_config": {"tr": "Geçersiz ayar: {detail}", "en": "Invalid setting: {detail}"},
    "unknown_model": {"tr": "Bilinmeyen model: {id}", "en": "Unknown model: {id}"},
    "repo_not_found": {"tr": "Hugging Face'te bulunamadı: {repo}",
                       "en": "Not found on Hugging Face: {repo}"},
    "network_error": {"tr": "Hugging Face'e ulaşılamadı. İnternet bağlantını kontrol et.",
                      "en": "Could not reach Hugging Face. Check your internet connection."},
    "not_downloaded": {"tr": "{label} indirilmemiş.", "en": "{label} is not downloaded."},
    "insufficient_ram": {
        "tr": "Yeterli bellek yok: {label} için {needed_gb} gerekli, kullanılabilir "
              "{available_gb}. Bazı uygulamaları kapatıp tekrar dene.",
        "en": "Not enough memory: {label} needs {needed_gb}, {available_gb} available. "
              "Close some apps and try again."},
    "load_failed": {"tr": "Model yüklenemedi: {error}", "en": "Could not load the model: {error}"},
    "insufficient_disk": {
        "tr": "Diskte yeterli boş alan yok: indirme sonrası en az {min_free_gb} boş kalmalı.",
        "en": "Not enough free disk space: at least {min_free_gb} must stay free after the "
              "download."},
    "already_downloading": {"tr": "{label} zaten iniyor.", "en": "{label} is already downloading."},
    "already_downloaded": {"tr": "{label} zaten indirilmiş.",
                           "en": "{label} is already downloaded."},
    "not_downloading": {"tr": "{label} indirilmiyor.", "en": "{label} is not downloading."},
    "model_loaded": {"tr": "{label} bellekte; önce boşalt.",
                     "en": "{label} is loaded; unload it first."},
    "invalid_repo": {"tr": "Geçersiz depo adı. Biçim: kurulus/model-adi",
                     "en": "Invalid repository name. Format: org/model-name"},
    "already_exists": {"tr": "{label} zaten listede.", "en": "{label} is already in the list."},
    "unsupported_model": {
        "tr": "Bu model desteklenmiyor. MLX Whisper modeli olmalı "
              "(config.json + weights.npz/safetensors).",
        "en": "This model is not supported. It must be an MLX Whisper model "
              "(config.json + weights.npz/safetensors)."},
    "not_custom": {"tr": "{label} yerleşik bir model; kaldırılamaz.",
                   "en": "{label} is a built-in model and can't be removed."},
    "no_model_selected": {"tr": "Model seçilmedi.", "en": "No model selected."},
    "busy": {"tr": "Başka bir dikte sürüyor.", "en": "Another dictation is in progress."},
    "internal": {"tr": "Motor hatası: {error}", "en": "Engine error: {error}"},
    "dictation_expired": {
        "tr": "Bu diktenin sesi artık yok (10 dakikadan eski ya da sonra yeni bir dikte yapıldı).",
        "en": "The audio of this dictation is gone (older than 10 minutes, or a newer "
              "dictation was made)."},
    # ModelInfo.error of a paused / failed download
    "download_paused_disk": {
        "tr": "Diskte yeterli boş alan yok: indirme sonrası en az {min_free_gb} boş kalmalı. "
              "İndirme duraklatıldı.",
        "en": "Not enough free disk space: at least {min_free_gb} must stay free after the "
              "download. The download was paused."},
    "download_failed": {"tr": "İndirme başarısız: {error}", "en": "Download failed: {error}"},
    "size_mismatch": {"tr": "{file}: boyut uyuşmuyor ({got} != {want})",
                      "en": "{file}: size mismatch ({got} != {want})"},
    "checksum_failed": {"tr": "{file}: SHA-256 doğrulaması başarısız",
                        "en": "{file}: SHA-256 check failed"},
    # ModelInfo.note of built-in models
    "note_large_v3": {"tr": "WER 7,9% · terim 96% · ~0,8 sn", "en": "WER 7.9% · terms 96% · ~0.8 s"},
    "note_turbo": {"tr": "WER 8,3% · ~0,5 sn", "en": "WER 8.3% · ~0.5 s"},
}

_lang = "tr"


def set_language(lang: str) -> None:
    global _lang
    _lang = lang


def _gb(n: float, lang: str) -> str:
    s = f"{n / 1e9:.1f}"
    return (s.replace(".", ",") if lang == "tr" else s) + " GB"


def render(key: str, lang: str | None = None, **params: Any) -> str:
    lang = lang or _lang
    params = {k: _gb(v, lang) if k.endswith("_gb") else v for k, v in params.items()}
    return TEXTS[key][lang].format(**params)


class Msg:
    def __init__(self, key: str, **params: Any):
        self.key, self.params = key, params

    def __str__(self) -> str:
        return render(self.key, **self.params)


class LocalizedError(Exception):
    """An exception whose text is a Msg (rendered in the current ui_language)."""

    def __init__(self, msg: Msg):
        super().__init__(msg.key)
        self.msg = msg

    def __str__(self) -> str:
        return str(self.msg)
