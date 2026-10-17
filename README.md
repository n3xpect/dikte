# Dikte

**English** · [Türkçe](README.tr.md)

A local dictation app for the Mac, in Turkish and English. Press **⌥ Space** and speak; the text appears in an editable panel and **Enter** copies it to the clipboard — or pastes it into an app you pick. Audio never leaves your Mac: speech is transcribed with **Whisper large-v3** running on Apple Silicon via [MLX](https://github.com/ml-explore/mlx).

The spoken language is detected on every dictation (Turkish or English); if it's detected wrongly, the **TR/EN** button in the panel (⌘L) transcribes the same recording again in the other language. The interface is available in English and Turkish.

It is tuned for English software terms inside Turkish sentences (branch, commit, deploy, session, socket…): an editable **term list** is given to the model as a hint and also fixes common misspellings automatically. When you correct a term in the panel, Dikte offers to add the correction to the term list.

## Installation

1. Download `dikte-<version>.dmg` from [Releases](https://github.com/n3xpect/dikte/releases).
2. Open the DMG and drag `dikte.app` into **Applications**.
3. The app isn't signed with an Apple-issued certificate. If macOS says the developer can't be verified, go to **System Settings › Privacy & Security › Open Anyway**.
4. On first launch a welcome flow sets things up in four steps: interface and dictation language, downloading **Whisper large-v3** (~3 GB), permissions (microphone; Accessibility for pasting into apps), and the shortcut. Everything can be changed later.

**Requirements:** Apple Silicon Mac, macOS 15+, ~4 GB free RAM, at least 10 GB of free disk space left after the model download.

## Usage

| Key | What it does |
|---|---|
| **⌥ Space** | Start dictating (press again while recording to finish); also **Start dictation** in the menu bar menu |
| 3 s of silence / **Enter** | Stop recording and transcribe |
| **Esc** | Cancel while recording; close the panel when editing |
| **Enter** (while editing) | Send the text to the default target (clipboard unless you choose an app) and close the panel |
| **Shift+Enter** | New line |
| **⌘1–9** / **↓** | Send to another target in the panel's list / pick one with the arrow keys (**⌥↑ / ⌥↓** moves it) |
| **⌘L** / TR-EN button | Transcribe the same recording in the other language |

Prefer Enter for new lines? **Text delivery › Send with** swaps the two: Shift+Enter sends, Enter adds a new line.

By default the text is **sent automatically** after a short countdown shown in the panel (30 s by default; right away, 3 s, 30 s, 1, 3 or 5 min — right away sends without showing the text; turn it off or change the wait with ⏱ in the panel or in **Text delivery › Send automatically**). Any key or click stops the countdown, Esc too; Enter sends right away.

Recording stops by itself after the silence duration or at the longest recording length (2 min by default, up to 20 min); the panel shows the time as `00:42 / 02:00`.

The menu bar icon shows the state: green dot = model in memory, orange = loading, red = engine not running. The main window has these pages:

- **Settings** — launch at login, dictation shortcut (click and press a new one; ⓧ removes it, then dictation starts from the menu bar), interface language (English / Türkçe, switches instantly), dictation language (Automatic / Turkish / English), history limit.
- **Recording** — microphone, silence duration, longest recording (1–20 min), sound effects.
- **Text delivery** — your targets (apps, **Last used app** and Copy to clipboard) in your order: drag them by ≡ here or in the panel; the top one is the default (Enter), the ones below get ⌘1, ⌘2…. Also the send key, how many other running apps the panel lists, restoring the clipboard after pasting. **Last used app** (add it with **Add…**) pastes into whichever app was in front when you started dictating; if there was none, the text is copied to the clipboard. Tick **Also send in the app** on an app's row to make Dikte press Return right after pasting, so that app sends the text (chat apps, for example).
- **Permissions** — microphone and Accessibility status, with a button to grant each.
- **Models** — Whisper large-v3 (recommended), large-v3 turbo, and MLX Whisper models added manually from Hugging Face. The model in memory is shown in green. Idle unload time (1–10 min, 5 by default: the model is unloaded from memory that long after the last dictation) and minimum free disk space (5–20 GB, 10 GB by default) are sliders here: a download won't start if less than that would remain on disk; a model won't load if there isn't enough RAM.
- **Terimler** (Terms, Turkish interface only) — the term list: accepted spellings and auto-corrected misspellings per term; search, add, edit, delete. With the English interface the tab is hidden; the terms still apply to every dictation.
- **History** — every dictation (language, final text; when it was corrected, also the raw text and the diff), search, copy, delete.
- **About** (bottom of the sidebar) — version, links, model, engine, data folder.

The TR/EN button is meant to fix a wrongly detected language: switching a correctly detected recording to the other language translates it.

## Why Whisper large-v3?

**Turkish** — 33 sentences read in my own voice (mostly Turkish dictation full of English software terms), term hints on:

| Model | WER | Term accuracy | Transcription time (M4 Pro) |
|---|---|---|---|
| **Whisper large-v3 (MLX)** | **7.6%** | **74/77** | ~0.8 s |
| Whisper large-v3 turbo | 8.3% | 74/77 | ~0.5 s |
| Whisper large-v3, Turkish fine-tune | 15.6% | 72/77 | ~0.8 s |
| Qwen3-ASR 1.7B | 16.9% | 61/77 | ~0.5 s |

The same model was equally accurate with whisper.cpp (0.9 s); WhisperKit took ~7 s per recording with term hints on.

**English** — 20 sentences read by 5 different macOS English voices (100 recordings): WER 0.8%, terms 235/235, language detection 100%. Automatic language detection adds ~50 ms per dictation. Details and test tools: [`model-test/`](model-test/), [`app/engine/tests/`](app/engine/tests/).

## Architecture

```
dikte.app
├── Swift app (SwiftUI + AppKit)               menu bar, ⌥ Space panel, microphone, main window,
│                                               welcome flow, settings/history/terms.json
└── Contents/Resources/engine (Python + MLX)   model download/loading, Silero VAD, language
                                                detection, Whisper, term hints and corrections
```

The app starts the engine on launch and stops it on quit. They talk over HTTP + WebSocket on `127.0.0.1` (with a random key per launch); contract: [`app/engine/api.md`](app/engine/api.md). Microphone audio streams to the engine in chunks; the engine detects the end of speech and sends the text back. The model loads in the background while you speak.

Data lives in `~/Library/Application Support/dikte/`: `settings.json`, `history.json`, `terms.json`, `models/` (Hugging Face cache layout), `logs/engine.log`.

## Repository layout

| Folder | Contents |
|---|---|
| [`app/dikte/`](app/dikte/) | Swift app (XcodeGen `project.yml`); UI translations `i18n/*.json` → String Catalog |
| [`app/engine/`](app/engine/) | Python MLX engine (`uv` project) and API contract |
| [`app/`](app/README.md) | `package.sh` (packaging), `make-dmg.sh`, `scripts/` (icon, strings, signing), development notes |
| [`model-test/`](model-test/) | Model comparison and test bench |
| `dist/` | Packaging output: only `dikte-<version>.dmg` (not in git) |

## Development

Requirements: Xcode 27, [uv](https://docs.astral.sh/uv/), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install uv xcodegen`).

```bash
cd app/engine && uv sync                            # engine environment
cd app/dikte && xcodegen generate && open dikte.xcodeproj
python3 app/scripts/build-strings.py                # i18n/*.json → Localizable.xcstrings
app/package.sh                                      # → dist/dikte-<version>.dmg
```

Tests, environment variables and packaging details: [`app/README.md`](app/README.md) (Turkish).

## Known limitations

- Dictation languages: Turkish and English (Whisper supports more, but they aren't enabled in the app).
- Very short, mixed phrases ("Deploy et.") may be detected as English; fix them with the TR button.
- The app is signed with a local certificate (not notarized), so Gatekeeper warns on first launch.
