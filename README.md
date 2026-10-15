# Dikte

Mac için yerel çalışan Türkçe dikte uygulaması. **⌥ Space**'e bas, konuş; metin düzenlenebilir bir panelde çıkar, **Shift+Enter** ile panoya kopyalanır. Ses Mac'ten dışarı çıkmaz: konuşma, Apple Silicon üzerinde [MLX](https://github.com/ml-explore/mlx) ile çalışan **Whisper large-v3** modeliyle yazıya çevrilir.

Türkçe cümle içindeki İngilizce yazılım terimleri (branch, commit, deploy, session, socket…) için özel olarak ayarlandı: düzenlenebilir bir **terim listesi** hem modele ipucu olarak verilir hem de yaygın yanlış yazımları otomatik düzeltir. Panelde bir terimi düzelttiğinde Dikte bunu terim listesine eklemeyi önerir.

## Kurulum

1. [Releases](https://github.com/n3xpect/dikte/releases) sayfasından `dikte-<sürüm>.dmg`'yi indir.
2. DMG'yi aç, `dikte.app`'i **Uygulamalar**'a sürükle.
3. İlk açılış: uygulama Apple onaylı bir sertifikayla imzalı değil. "Geliştirici doğrulanamadı" uyarısı çıkarsa **Sistem Ayarları › Gizlilik ve Güvenlik › Yine de Aç**.
4. Menü çubuğundaki 🎙 simgesinden **Dikte'yi aç › Modeller** sekmesinde **Whisper large-v3**'ü indir (~3 GB).
5. İlk ⌥ Space'te mikrofon iznini ver.

**Gereksinimler:** Apple Silicon Mac, macOS 15+, ~4 GB boş RAM, model indirildikten sonra en az 10 GB boş disk.

## Kullanım

| Tuş | Ne yapar |
|---|---|
| **⌥ Space** | Dikteyi başlat (kayıt sırasında tekrar basınca bitirir) |
| 3 sn sessizlik / **Enter** | Kaydı bitir ve yazıya çevir |
| **Esc** | Kayıt sırasında vazgeç; metin ekranında paneli kapat |
| **Enter** (metin ekranında) | Yeni satır |
| **Shift+Enter** | Metni panoya kopyala ve paneli kapat |

Menü çubuğundaki simge durumu gösterir: yeşil nokta model bellekte, turuncu yükleniyor, kırmızı motor çalışmıyor. Ana ekranda üç sekme var:

- **Ayarlar** — sessizlik süresi, mikrofon, kısayol, terim listesi, açılışta başlat, ses efektleri, modelin boşta kalma süresi (5 dk sonra bellekten boşaltılır), geçmiş sınırı, en az boş disk alanı.
- **Modeller** — Whisper large-v3 (önerilen), large-v3 turbo ve Hugging Face'ten elle eklenen MLX Whisper modelleri. Bellekteki model yeşil gösterilir. İndirme sonrası diskte 10 GB'tan az yer kalacaksa indirme başlamaz; RAM yetmiyorsa model yüklenmez.
- **Geçmiş** — tüm dikteler (ham ve düzeltilmiş metin, aradaki fark), arama, kopyalama, silme.

## Neden Whisper large-v3?

Kendi sesimle okunmuş 33 cümlede (çoğu İngilizce yazılım terimli Türkçe dikte) ölçüldü, terim ipucu açık:

| Model | WER | Terim doğruluğu | Çeviri süresi (M4 Pro) |
|---|---|---|---|
| **Whisper large-v3 (MLX)** | **7,6–7,9%** | **74/77** | ~0,8 sn |
| Whisper large-v3 turbo | 8,3% | 74/77 | ~0,5 sn |
| Whisper large-v3, Türkçe ince ayar | 15,6% | 72/77 | ~0,8 sn |
| Qwen3-ASR 1.7B | 16,9% | 61/77 | ~0,5 sn |

Aynı model whisper.cpp ile eşit doğrulukta (0,9 sn), WhisperKit ile terim ipucu açıkken ~7 sn/kayıt sürdü. Ayrıntılar ve test aracı: [`model-test/`](model-test/).

## Mimari

```
dikte.app
├── Swift uygulaması (SwiftUI + AppKit)        menü çubuğu, ⌥ Space paneli, mikrofon, ana ekran,
│                                               settings/history/terms.json
└── Contents/Resources/engine (Python + MLX)   model indirme/yükleme, Silero VAD, Whisper,
                                                terim ipucu ve düzeltmeleri
```

Uygulama açılınca motoru başlatır, kapanınca durdurur. İkisi `127.0.0.1` üzerinden HTTP + WebSocket ile konuşur (her açılışta rastgele bir anahtarla); sözleşme: [`app/engine/api.md`](app/engine/api.md). Mikrofon sesi parça parça motora akar, motor sessizliği algılar ve metni geri yollar. Model, sen konuşurken arka planda yüklenir.

Veriler `~/Library/Application Support/dikte/` altında: `settings.json`, `history.json`, `terms.json`, `models/` (Hugging Face önbellek düzeni), `logs/engine.log`.

## Repo yapısı

| Klasör | İçerik |
|---|---|
| [`app/dikte/`](app/dikte/) | Swift uygulaması (XcodeGen `project.yml`) |
| [`app/engine/`](app/engine/) | Python MLX motoru (`uv` projesi) ve API sözleşmesi |
| [`app/`](app/README.md) | `package.sh` (paketleme), `make-dmg.sh`, geliştirme notları |
| [`model-test/`](model-test/) | Model karşılaştırma ve test ortamı |
| `dist/` | Paketleme çıktısı: yalnızca `dikte-<sürüm>.dmg` (git'te yok) |

## Geliştirme

Gerekenler: Xcode 27, [uv](https://docs.astral.sh/uv/), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install uv xcodegen`).

```bash
cd app/engine && uv sync                            # motor ortamı
cd app/dikte && xcodegen generate && open dikte.xcodeproj
app/package.sh                                      # → dist/dikte-<sürüm>.dmg
```

Testler, ortam değişkenleri ve paketleme ayrıntıları: [`app/README.md`](app/README.md).

## Bilinen sınırlar

- Yalnızca Türkçe dikte.
- Uygulama yerel bir sertifikayla imzalı (notarize edilmemiş); ilk açılışta Gatekeeper uyarısı verir.
