# dikte engine API (v1)

The engine is a Python (MLX) process bundled inside `dikte.app`. The app starts it, talks to it
over HTTP + WebSocket on `127.0.0.1`, and stops it. The engine owns everything ML: model
catalog/download/delete, loading/unloading, VAD endpointing, transcription, term prompt + fixes.
The app owns UI, microphone capture, and the JSON files (settings/history/terms).

## Process lifecycle

```
<python> -m dikte_engine --data-dir "~/Library/Application Support/dikte" --port 0
```

- Env `DIKTE_TOKEN`: random secret chosen by the app. Every request must send it:
  HTTP header `Authorization: Bearer <token>`, WebSocket query `?token=<token>`. Otherwise 401.
- `--port 0` picks a free port. When ready, the engine prints exactly one line to **stdout**:
  `{"event":"ready","port":53123,"version":"1"}` — the app reads it to learn the port.
  All logging goes to stderr.
- The app keeps the engine's **stdin** open. When stdin reaches EOF (app quit/crashed) the engine
  exits. SIGTERM also exits cleanly. (`--ignore-stdin` disables the EOF exit for manual runs.)
- Models live in `<data-dir>/models/` (Hugging Face cache layout). Engine-owned state lives in
  `<data-dir>/engine/` (`custom_models.json`, `sizes.json` = cached HF file sizes so offline
  listing works).

## Data types

```jsonc
// ModelInfo
{
  "id": "large-v3",                   // catalog key, or "hf:<org>/<repo>" for custom models
  "label": "Whisper large-v3",
  "repo": "mlx-community/whisper-large-v3-mlx",
  "kind": "mlx-whisper",              // only "mlx-whisper" (Qwen3-ASR removed in 0.1.1)
  "custom": false,
  "recommended": true,
  "note": "WER 7,9% · terim 96% · ~0,8 sn",   // short note in ui_language, may be ""
  "size_bytes": 3084000000,           // total download size (from HF; null if unknown yet)
  "downloaded_bytes": 3084000000,     // bytes already on disk
  "ram_bytes": 3700000000,            // estimated RAM when loaded
  "state": "loaded",                  // see below
  "progress": null,                   // 0..1 while downloading, else null
  "error": null                       // last error message (in ui_language), else null
}
```

`state` — exactly one of:

| state            | meaning                                            |
|------------------|----------------------------------------------------|
| `not_downloaded` | nothing (or only a partial download) on disk       |
| `downloading`    | download in progress (`progress` set)              |
| `paused`         | download stopped (disk guard / cancel / error); resumable |
| `on_disk`        | fully downloaded, not in RAM                       |
| `loading`        | being loaded into RAM                              |
| `loaded`         | in RAM, ready (at most one model at a time)        |

`paused` is kept in memory only: after an engine restart a partial download shows as
`not_downloaded` with `downloaded_bytes > 0`. Either way `POST …/download` resumes it (HTTP Range,
partial bytes are kept; LFS files are SHA-256 verified when complete).
`size_bytes` is `null` until the engine has fetched the file list from HF once (done in the
background at startup; a snapshot follows).

```jsonc
// SystemInfo
{
  "disk_free_bytes": 415000000000,    // strictly free space on the models volume (no purgeable)
  "min_free_bytes": 10737418240,      // from config
  "ram_total_bytes": 25769803776,
  "ram_available_bytes": 14000000000,
  "idle_unload_s": 300,
  "idle_unload_at": 1760550000.0,     // unix time the loaded model will be unloaded, or null
  "selected_model": "large-v3"
}
```

## HTTP

All bodies JSON. Errors: `{"error": "<code>", "message": "<text in ui_language>", ...details}`.
Common: 401 `unauthorized`, 400 `invalid_json`, 404 `unknown_model` (bad `{id}`),
503 `network_error` (an operation that needs Hugging Face could not reach it).

| method & path                    | body / result |
|----------------------------------|---------------|
| `GET /health`                    | `{"status":"ok","version":"1"}` |
| `GET /models`                    | `{"models":[ModelInfo], "system":SystemInfo}` |
| `PUT /config`                    | partial `Config` (below) → `{"ok":true}`; applies immediately. 400 `invalid_config` (unknown field, wrong type/range/value, unknown `selected_model`); nothing is applied then |
| `GET /terms/default`             | `{"terms":[{"term","accept","fix"}]}` — built-in default term list (the app seeds `terms.json` from it) |
| `POST /models/{id}/download`     | 202 `{"ok":true}` (also resumes `paused`); **507** `insufficient_disk` with `needed_bytes`, `free_bytes`, `min_free_bytes`; 409 `already_downloading` / `already_downloaded` |
| `POST /models/{id}/cancel`       | stop a running download → `{"ok":true}`, state `paused` (partial files kept); 409 `not_downloading` |
| `DELETE /models/{id}`            | delete files (also stops a running download and discards partial files). 409 `model_loaded` if loaded/loading — unload first |
| `POST /models/{id}/load`         | 202 (also if already loaded/loading); **507** `insufficient_ram` with `needed_bytes`, `available_bytes`; 409 `not_downloaded`. Unloads any other model first. A failure during the load shows up as `ModelInfo.error` |
| `POST /unload`                   | unload whatever is loaded → `{"ok":true}` |
| `POST /retranscribe`             | see [below](#post-retranscribe) |
| `POST /models/custom`            | `{"repo":"org/name"}` (a `https://huggingface.co/org/name` URL is accepted too) → validates on HF (exists, kind detectable) → 201 `ModelInfo`; 200 `ModelInfo` if it is already a custom model; 409 `already_exists` (+`id`) if it is a built-in model; 422 `invalid_repo` (bad format) / `unsupported_model`; 404 `repo_not_found` |
| `DELETE /models/custom/{id}`     | remove a custom entry (and its files) → `{"ok":true}`; 400 `not_custom`; 409 `model_loaded`. If it was `selected_model`, that becomes `null` |

`{id}` is URL-path-encoded (custom ids contain `/` → use `hf:org%2Fname`).

```jsonc
// Config (all fields optional on PUT)
{
  "selected_model": "large-v3",
  "idle_unload_s": 300,
  "min_free_bytes": 10737418240,
  "silence_s": 3.0,
  "max_duration_s": 120,              // 1–1200 (the app offers whole minutes, 1–20)
  "language": "auto",                 // "auto" (Turkish or English, detected) | "tr" | "en"
  "ui_language": "tr",                // "tr" | "en": language of every `message` the engine sends
  "terms": [ { "term": "branch", "accept": ["branch"], "fix": ["brenç"] } ]
}
```

Config defaults (until the app sends its own): `selected_model "large-v3"`, `idle_unload_s 300`,
`min_free_bytes 10 GiB`, `silence_s 3.0`, `max_duration_s 120`, `language "tr"`, `ui_language "tr"`,
`terms` = `GET /terms/default`.

Disk rule (download): `disk_free - (size - downloaded) >= min_free`, re-checked every ~200 MB while
downloading; if violated the download stops → `paused`, `error` = message (in ui_language). Bytes still to
come from other running downloads count as part of `size - downloaded`.
RAM rule (load): `ram_available >= ram_bytes` (ram_bytes ≈ 1.2 × weights), else 507. When another
model is loaded, its `ram_bytes` counts as available (it is unloaded first).
Idle unload: the loaded model is unloaded `idle_unload_s` after the last dictation/load
(0 = never). Any dictation resets the timer; it never fires during a dictation or a load.

## WebSocket `/events?token=…`

Server → client only. On connect it sends one full snapshot, then a new snapshot on every change
(state, config, errors: immediately; download progress: throttled to ≤4/s):

```json
{"type":"snapshot","models":[ModelInfo],"system":SystemInfo}
```

## WebSocket `/dictate?token=…` — one connection per dictation

Client → server:
1. Text: `{"type":"start"}` — uses `selected_model`, config terms/silence/max_duration.
   If the model is not loaded the engine starts loading it **immediately** (recording continues).
2. Binary frames: raw **PCM float32 little-endian, mono, 16 kHz**, any frame size.
3. Text: `{"type":"finish"}` (Enter / ⌥Space) or `{"type":"cancel"}` (Esc) at any time.

Server → client (text JSON):

| message | when |
|---------|------|
| `{"type":"model","state":"loading"}` / `{"type":"model","state":"ready"}` | model state relevant to this dictation (sent right after start: `ready` if already loaded) |
| `{"type":"speech_start"}` | VAD detected speech |
| `{"type":"end","reason":"silence"\|"finish"\|"max_duration"\|"no_speech"\|"cancel"}` | recording ended; stop sending audio |
| `{"type":"transcribing"}` | transcription started (after model ready) |
| `{"type":"result","raw_text":"…","text":"…","fixes":[["brenç","branch"]],"audio_s":5.2,"transcribe_s":0.8,"model":"large-v3","language":"tr","dictation_id":"7f3c…"}` | done; `text` = raw_text after term fixes (fixes are applied to Turkish results only). `language` = language used (`tr`/`en`). `dictation_id` (random, 16 hex chars) identifies the audio for `POST /retranscribe`. Server closes the socket after this |
| `{"type":"error","code":"…","message":"…"}` | `model_not_downloaded`, `insufficient_ram`, `no_model_selected`, `load_failed`, `busy` (another dictation is running; sent right on connect), `bad_request` (first message is not `start`), `internal`. `message` is in ui_language. Server closes the socket after an error |

`no_speech`: nothing detected within 15 s → no transcription, socket closes. `finish` before any
speech was detected also ends with reason `no_speech`. `cancel` → no transcription. A `cancel` or
a disconnect after `end` (while waiting for the model / transcribing) closes the socket without a
result. If the model fails to load while recording, `error` is sent at once and the socket closes.
One dictation at a time. VAD: Silero, speech ≥ 0.5, silence < 0.35, end after `silence_s` of silence
following speech; audio is trimmed with 300 ms pre-roll / 200 ms post-roll before transcription.

## Languages (v2)

- `language: "auto"` → Whisper's language probabilities are computed once per dictation, on the
  first 30 s of audio, and only `tr` vs `en` are compared (no other language can be chosen). The
  encoder output of that window is reused for the transcription (auto costs ~30–60 ms over a
  forced language). `"tr"` / `"en"` force the language. Forcing a language on speech in the other
  one usually gives a translation (Whisper behaviour), which is what `/retranscribe` relies on.
- The term prompt is language-specific (same term list, Turkish or English lead-in sentence).
- Term `fix` replacements are applied only to Turkish results (they are Turkish spellings);
  `fixes` is `[]` for `en`.
- `ui_language` selects the language of all human-readable texts: every `message` (HTTP and WS
  errors), `ModelInfo.error` and `ModelInfo.note`. Error `code`s are unchanged. Stored errors
  (`ModelInfo.error`) switch language too when `ui_language` changes (a snapshot follows).
  Texts live in `dikte_engine/messages.py` (key → {tr, en}); technical `detail` fields stay English.

## `POST /retranscribe`

Body `{"dictation_id": "…", "language": "tr" | "en"}` → 200 with the same object as the `/dictate`
`result` message (minus `type`, same `dictation_id`), transcribed again from the kept audio in the
given language with the **selected** model and the current terms.
The engine keeps the trimmed audio of the **last** dictation that produced a `result` only, for 10
minutes from that result (retranscribing does not extend it; a cancelled dictation does not replace
it). Errors: 400 `bad_request` (body not as above), 404 `dictation_expired` (unknown/expired/replaced
id), 409 `busy` while a dictation is running, 409 `no_model_selected`. `model_not_loaded` is never
returned — the selected model is loaded if needed (same rules/errors as `/models/{id}/load`:
409 `not_downloaded`, 507 `insufficient_ram`, 500 `load_failed`); the request waits for the load.
Resets the idle-unload timer (the model is not idle-unloaded while it runs).
