# model-test

Türkçe (İngilizce yazılım terimli) dikte için STT model testi. Her şey yerelde, MLX ile çalışır.

## Kullanım

```bash
uv run listen.py                    # large-v3 ile serbest dikte (seçilen model)
uv run listen.py --model turbo      # başka model: turbo | large-v3 | tr-ft | qwen3-1.7b
uv run listen.py --compare          # her kaydı indirilmiş tüm modellerle çevir
uv run listen.py --compare --script # test_sentences.yaml cümlelerini oku, WER + terim skoru al
uv run listen.py --no-prompt        # terim ipucunu kapat (karşılaştırma için)
```

Konuşmayı bitirmek için **3 sn sus** (süre `--silence` ile değişir).

Uygulama içi tuşlar: `Enter` konuş · `r` son kaydı tekrar çevir · `m` model seç · `c` karşılaştırma aç/kapa · `p` prompt aç/kapa · `n`/`b` sonraki/önceki cümle (script modu) · `q` çık.

Kayıtlar `recordings/`, sonuçlar `results.csv` içine yazılır.

## Dosyalar

| Dosya | İçerik |
|---|---|
| `listen.py` | Etkileşimli test uygulaması |
| `audio.py` | Mikrofon, Silero VAD, sessizlikle bitiş algılama |
| `backends.py` / `download.py` | Model kaydı (mlx-whisper, mlx-audio), indirme: `uv run download.py --list` |
| `terms.yaml` / `terms.py` | Terim kütüphanesi: Whisper prompt'u, Qwen hotwords, otomatik düzeltme, skor |
| `test_sentences.yaml` | Script modunda okunacak 33 cümle |
| `tests/` | `uv run python tests/test_{audio,terms,backends,e2e}.py` |

Modeller `models/` altında (HF cache, ~9.6 GB).
