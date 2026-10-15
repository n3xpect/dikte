# Dikte

[English](README.md) · **Türkçe**

Mac için yerel çalışan Türkçe ve İngilizce dikte uygulaması. **⌥ Space**'e bas, konuş; metin düzenlenebilir bir panelde çıkar, **Shift+Enter** ile panoya kopyalanır. Ses Mac'ten dışarı çıkmaz: konuşma, Apple Silicon üzerinde [MLX](https://github.com/ml-explore/mlx) ile çalışan **Whisper large-v3** modeliyle yazıya çevrilir.

Konuşmanın dili her diktede otomatik algılanır (Türkçe ya da İngilizce); yanlış algılanırsa paneldeki **TR/EN** düğmesiyle (⌘L) aynı kayıt diğer dilde yeniden çevrilir. Arayüz de Türkçe ve İngilizce.

Türkçe cümle içindeki İngilizce yazılım terimleri (branch, commit, deploy, session, socket…) için özel olarak ayarlandı: düzenlenebilir bir **terim listesi** hem modele ipucu olarak verilir hem de yaygın yanlış yazımları otomatik düzeltir. Panelde bir terimi düzelttiğinde Dikte bunu terim listesine eklemeyi önerir.

## Kurulum

1. [Releases](https://github.com/n3xpect/dikte/releases) sayfasından `dikte-<sürüm>.dmg`'yi indir.
2. DMG'yi aç, `dikte.app`'i **Uygulamalar**'a sürükle.
3. Uygulama Apple onaylı bir sertifikayla imzalı değil. "Geliştirici doğrulanamadı" uyarısı çıkarsa **Sistem Ayarları › Gizlilik ve Güvenlik › Yine de Aç**.
4. İlk açılışta karşılama ekranı seni dört adımda hazırlar: arayüz ve dikte dili, **Whisper large-v3**'ün indirilmesi (~3 GB), mikrofon izni ve kısayol. Hepsi sonradan değiştirilebilir.

**Gereksinimler:** Apple Silicon Mac, macOS 15+, ~4 GB boş RAM, model indirildikten sonra en az 10 GB boş disk.

## Kullanım

| Tuş | Ne yapar |
|---|---|
| **⌥ Space** | Dikteyi başlat (kayıt sırasında tekrar basınca bitirir) |
| 3 sn sessizlik / **Enter** | Kaydı bitir ve yazıya çevir |
| **Esc** | Kayıt sırasında vazgeç; metin ekranında paneli kapat |
| **Enter** (metin ekranında) | Yeni satır |
| **Shift+Enter** | Metni panoya kopyala ve paneli kapat |
| **⌘L** / TR-EN düğmesi | Aynı kaydı diğer dilde yeniden çevir |

Menü çubuğundaki simge durumu gösterir: yeşil nokta model bellekte, turuncu yükleniyor, kırmızı motor çalışmıyor. Ana ekranda dört sekme var:

- **Ayarlar** — arayüz dili (Türkçe / English, anında değişir), dikte dili (Otomatik / Türkçe / English), kısayol, mikrofon, sessizlik süresi, ses efektleri, modelin boşta kalma süresi (5 dk sonra bellekten boşaltılır), en az boş disk alanı, geçmiş sınırı, açılışta başlat.
- **Modeller** — Whisper large-v3 (önerilen), large-v3 turbo ve Hugging Face'ten elle eklenen MLX Whisper modelleri. Bellekteki model yeşil gösterilir. İndirme sonrası diskte 10 GB'tan az yer kalacaksa indirme başlamaz; RAM yetmiyorsa model yüklenmez.
- **Terimler** — terim listesi: her terimin doğru kabul edilen yazımları ve otomatik düzeltilen yanlış yazımları; arama, ekleme, düzenleme, silme.
- **Geçmiş** — tüm dikteler (dili, ham ve düzeltilmiş metin, aradaki fark), arama, kopyalama, silme.

TR/EN düğmesi yanlış algılanan dili düzeltmek içindir: doğru algılanmış bir kaydı diğer dile çevirmek metni tercüme eder.

## Neden Whisper large-v3?

**Türkçe** — kendi sesimle okunmuş 33 cümle (çoğu İngilizce yazılım terimli Türkçe dikte), terim ipucu açık:

| Model | WER | Terim doğruluğu | Çeviri süresi (M4 Pro) |
|---|---|---|---|
| **Whisper large-v3 (MLX)** | **7,6%** | **74/77** | ~0,8 sn |
| Whisper large-v3 turbo | 8,3% | 74/77 | ~0,5 sn |
| Whisper large-v3, Türkçe ince ayar | 15,6% | 72/77 | ~0,8 sn |
| Qwen3-ASR 1.7B | 16,9% | 61/77 | ~0,5 sn |

Aynı model whisper.cpp ile eşit doğrulukta (0,9 sn), WhisperKit ile terim ipucu açıkken ~7 sn/kayıt sürdü.

**İngilizce** — macOS'un 5 farklı İngilizce sesiyle okutulan 20 cümle (100 kayıt): WER %0,8, terim 235/235, dil algılama %100. Otomatik dil algılama dikte başına ~50 ms ekler. Ayrıntılar ve test araçları: [`model-test/`](model-test/), [`app/engine/tests/`](app/engine/tests/).

## Mimari

```
dikte.app
├── Swift uygulaması (SwiftUI + AppKit)        menü çubuğu, ⌥ Space paneli, mikrofon, ana ekran,
│                                               karşılama ekranı, settings/history/terms.json
└── Contents/Resources/engine (Python + MLX)   model indirme/yükleme, Silero VAD, dil algılama,
                                                Whisper, terim ipucu ve düzeltmeleri
```

Uygulama açılınca motoru başlatır, kapanınca durdurur. İkisi `127.0.0.1` üzerinden HTTP + WebSocket ile konuşur (her açılışta rastgele bir anahtarla); sözleşme: [`app/engine/api.md`](app/engine/api.md). Mikrofon sesi parça parça motora akar, motor sessizliği algılar ve metni geri yollar. Model, sen konuşurken arka planda yüklenir.

Veriler `~/Library/Application Support/dikte/` altında: `settings.json`, `history.json`, `terms.json`, `models/` (Hugging Face önbellek düzeni), `logs/engine.log`.

## Repo yapısı

| Klasör | İçerik |
|---|---|
| [`app/dikte/`](app/dikte/) | Swift uygulaması (XcodeGen `project.yml`); arayüz çevirileri `i18n/*.json` → String Catalog |
| [`app/engine/`](app/engine/) | Python MLX motoru (`uv` projesi) ve API sözleşmesi |
| [`app/`](app/README.md) | `package.sh` (paketleme), `make-dmg.sh`, `scripts/` (ikon, çeviri, imza), geliştirme notları |
| [`model-test/`](model-test/) | Model karşılaştırma ve test ortamı |
| `dist/` | Paketleme çıktısı: yalnızca `dikte-<sürüm>.dmg` (git'te yok) |

## Geliştirme

Gerekenler: Xcode 27, [uv](https://docs.astral.sh/uv/), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install uv xcodegen`).

```bash
cd app/engine && uv sync                            # motor ortamı
cd app/dikte && xcodegen generate && open dikte.xcodeproj
python3 app/scripts/build-strings.py                # i18n/*.json → Localizable.xcstrings
app/package.sh                                      # → dist/dikte-<sürüm>.dmg
```

Testler, ortam değişkenleri ve paketleme ayrıntıları: [`app/README.md`](app/README.md).

## Bilinen sınırlar

- Dikte dilleri: Türkçe ve İngilizce (Whisper başka dilleri de destekliyor ama uygulamada açık değil).
- Çok kısa, karışık ifadeler ("Deploy et.") İngilizce algılanabilir; TR düğmesiyle düzeltilir.
- Uygulama yerel bir sertifikayla imzalı (notarize edilmemiş); ilk açılışta Gatekeeper uyarısı verir.
