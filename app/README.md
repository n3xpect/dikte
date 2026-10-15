# Dikte

Yerel Türkçe dikte uygulaması: Swift arayüz (`dikte/`) + uygulamanın içine gömülen Python MLX motoru (`engine/`).

## Paketleme

```bash
app/package.sh          # → dist/dikte.app + dist/dikte-<sürüm>.dmg (Release, gömülü Python, yerel imza)
app/make-dmg.sh         # sadece DMG'yi mevcut dist/dikte.app'ten yeniden üret
```

İlk çalıştırmada login anahtar zincirine `Dikte Local Signing` adlı bir imza sertifikası eklenir (her derlemede mikrofon izni tekrar sorulmasın diye). Kaldırmak için:
`security delete-identity -c "Dikte Local Signing" ~/Library/Keychains/login.keychain-db`

Kurulum: `dist/dikte-<sürüm>.dmg`'yi aç, `dikte.app`'i Uygulamalar'a sürükle.
`dist/dikte.app`'i doğrudan çalıştırma; denemek için önce bir kopyasını al (imzalı paket değişmemeli).

## Geliştirme

```bash
cd app/engine && uv sync                       # motor ortamı (.venv)
cd app/dikte && xcodegen generate && open dikte.xcodeproj
```

Debug derleme motoru repo'daki `app/engine/.venv` ile başlatır. Ortam değişkenleri:
- `DIKTE_ENGINE_DIR` — motor klasörü
- `DIKTE_DATA_DIR` — veri klasörü (varsayılan `~/Library/Application Support/dikte`)

Testler:
- Motor: `cd app/engine && uv run python tests/test_integration.py` (diğerleri `tests/` altında)
- Uygulama + motor: `dikte.app/Contents/MacOS/dikte --selftest <kayıt.wav> [--realtime]`
- Arayüz önizlemeleri: `dikte --render-ui-previews <klasör>` (Debug)

Motor API sözleşmesi: [`engine/api.md`](engine/api.md).

## Veriler

`~/Library/Application Support/dikte/`: `settings.json`, `history.json`, `terms.json`, `models/` (Hugging Face önbellek düzeni), `engine/`, `logs/engine.log`.
