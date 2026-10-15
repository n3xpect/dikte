"""Engine state: config, catalog, downloads, the resident model, idle unload, change events."""

from __future__ import annotations

import asyncio
import logging
import secrets
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import aiohttp
import numpy as np
import psutil

from . import asr, catalog, messages
from .asr import LANGUAGES
from .catalog import BUILTIN, ModelSpec, RepoFiles
from .messages import UI_LANGUAGES, LocalizedError, Msg
from .store import DiskGuard, Store
from .terms import Term, apply_fixes, build_whisper_prompt, default_terms_json, parse_terms

log = logging.getLogger("dikte.engine")
GB = 1024**3
RAM_FACTOR = 1.2
KEEP_AUDIO_S = 600  # audio of the last dictation is kept this long for /retranscribe


class EngineError(LocalizedError):
    """API error; the message defaults to the one keyed by `code`."""

    def __init__(self, status: int, code: str, msg: Msg | None = None, **details: Any):
        super().__init__(msg or Msg(code))
        self.status, self.code, self.details = status, code, details

    @property
    def message(self) -> str:
        return str(self.msg)

    def body(self) -> dict[str, Any]:
        return {"error": self.code, "message": self.message, **self.details}


@dataclass
class Config:
    selected_model: str | None = "large-v3"
    idle_unload_s: float = 300
    min_free_bytes: int = 10 * GB
    silence_s: float = 3.0
    max_duration_s: float = 120
    language: str = "tr"
    ui_language: str = "tr"
    terms_raw: list[dict] = field(default_factory=default_terms_json)

    def public(self) -> dict[str, Any]:
        return {"selected_model": self.selected_model, "idle_unload_s": self.idle_unload_s,
                "min_free_bytes": self.min_free_bytes, "silence_s": self.silence_s,
                "max_duration_s": self.max_duration_s, "language": self.language,
                "ui_language": self.ui_language, "terms": self.terms_raw}


@dataclass
class Download:
    total: int
    done: int  # bytes on disk for this repo
    task: asyncio.Task | None = None
    running: bool = True


@dataclass
class Kept:
    """Trimmed audio of the last dictation (for /retranscribe)."""
    id: str
    audio: np.ndarray
    expire: asyncio.TimerHandle


def disk_rule_ok(free: int, remaining: int, min_free: int) -> bool:
    """api.md disk rule: what is still to download must leave at least min_free free."""
    return free - remaining >= min_free


def _num(body: dict, key: str, lo: float, hi: float) -> float:
    v = body[key]
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi:
        raise ValueError(f"{key} must be a number in [{lo}, {hi}]")
    return v


def _choice(body: dict, key: str, allowed: tuple[str, ...]) -> str:
    if body[key] not in allowed:
        raise ValueError(f"{key} must be one of {', '.join(allowed)}")
    return body[key]


class Engine:
    def __init__(self, data_dir: Path):
        self.models_dir = data_dir / "models"
        self.engine_dir = data_dir / "engine"
        self.models_dir.mkdir(parents=True, exist_ok=True)
        self.engine_dir.mkdir(parents=True, exist_ok=True)
        self.store = Store(self.models_dir)
        self.sizes = catalog.SizesCache(self.engine_dir / "sizes.json")
        self.custom_path = self.engine_dir / "custom_models.json"
        self.custom: list[ModelSpec] = catalog.load_custom(self.custom_path)

        self.config = Config()
        self.terms: list[Term] = parse_terms(self.config.terms_raw)
        self.prompts = self._build_prompts()

        # MLX must stay on one thread; VAD gets its own so it never waits behind a transcription.
        self.ml = ThreadPoolExecutor(1, thread_name_prefix="mlx")
        self.vad = ThreadPoolExecutor(1, thread_name_prefix="vad")

        self.backend: asr.Backend | None = None
        self.loading_id: str | None = None
        self._load_tasks: dict[str, asyncio.Task[asr.Backend]] = {}
        self._model_lock = asyncio.Lock()
        self.downloads: dict[str, Download] = {}
        self.errors: dict[str, Msg] = {}
        self.dictating = False
        self.retranscribing = 0
        self.kept: Kept | None = None
        self.idle_at: float | None = None
        self._idle_handle: asyncio.TimerHandle | None = None

        self.listeners: set[Callable[[dict], Any]] = set()
        self._changed = asyncio.Event()
        self._state_changed = False
        self.http: aiohttp.ClientSession | None = None
        self._bg: set[asyncio.Task] = set()

    # ------------------------------------------------------------------ lifecycle

    async def start(self) -> None:
        self.http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(
            total=None, sock_connect=30, sock_read=60))
        self.spawn(self._broadcaster())
        self.spawn(self._refresh_sizes())
        from .vad import load_vad

        self.spawn(asyncio.get_running_loop().run_in_executor(self.vad, load_vad))

    async def close(self) -> None:
        for d in self.downloads.values():
            if d.task:
                d.task.cancel()
        if self.http:
            await self.http.close()

    def spawn(self, aw: Any) -> asyncio.Future:
        t = asyncio.ensure_future(aw)
        self._bg.add(t)
        t.add_done_callback(self._bg.discard)
        return t

    async def _refresh_sizes(self) -> None:
        """Fetch exact sizes for models we have none for (offline: silently keep going)."""
        for spec in self.specs():
            if self.sizes.get(spec.repo) is None:
                try:
                    await self.repo_files(spec)
                except EngineError as e:
                    log.info("sizes for %s unavailable: %s", spec.repo, e.message)
                    return

    # ------------------------------------------------------------------ catalog & snapshot

    def specs(self) -> list[ModelSpec]:
        return BUILTIN + self.custom

    def spec(self, model_id: str) -> ModelSpec:
        for s in self.specs():
            if s.id == model_id:
                return s
        raise EngineError(404, "unknown_model", Msg("unknown_model", id=model_id))

    async def repo_files(self, spec: ModelSpec) -> RepoFiles:
        try:
            rf = await asyncio.get_running_loop().run_in_executor(
                None, catalog.fetch_repo_files, spec.repo)
        except catalog.RepoNotFound:
            raise EngineError(404, "repo_not_found", Msg("repo_not_found", repo=spec.repo))
        except catalog.NetworkError as e:
            raise EngineError(503, "network_error", detail=str(e))
        self.sizes.put(spec.repo, rf)
        self.notify()
        return rf

    def model_state(self, spec: ModelSpec) -> str:
        if self.backend is not None and self.backend.spec.id == spec.id:
            return "loaded"
        if self.loading_id == spec.id:
            return "loading"
        d = self.downloads.get(spec.id)
        if d is not None:
            return "downloading" if d.running else "paused"
        return "on_disk" if self.store.local_path(spec) else "not_downloaded"

    def ram_bytes(self, spec: ModelSpec) -> int | None:
        rf = self.sizes.get(spec.repo)
        weights = (rf.weights if rf else 0) or self.store.weights_on_disk(spec.repo) \
            or spec.est_weights_bytes
        return int(weights * RAM_FACTOR) if weights else None

    def model_info(self, spec: ModelSpec) -> dict[str, Any]:
        state = self.model_state(spec)
        d = self.downloads.get(spec.id)
        rf = self.sizes.get(spec.repo)
        downloaded = d.done if d is not None else self.store.downloaded_bytes(spec.repo)
        size = rf.total if rf else (downloaded if state in ("on_disk", "loaded", "loading") else None)
        progress = None
        if state == "downloading" and d is not None and d.total:
            progress = min(1.0, d.done / d.total)
        error = self.errors.get(spec.id)
        return {"id": spec.id, "label": spec.label, "repo": spec.repo, "kind": spec.kind,
                "custom": spec.custom, "recommended": spec.recommended,
                "note": messages.render(spec.note) if spec.note else "",
                "size_bytes": size, "downloaded_bytes": downloaded,
                "ram_bytes": self.ram_bytes(spec), "state": state, "progress": progress,
                "error": str(error) if error else None}

    def system_info(self) -> dict[str, Any]:
        vm = psutil.virtual_memory()
        return {"disk_free_bytes": self.store.disk_free(),
                "min_free_bytes": self.config.min_free_bytes,
                "ram_total_bytes": vm.total, "ram_available_bytes": vm.available,
                "idle_unload_s": self.config.idle_unload_s, "idle_unload_at": self.idle_at,
                "selected_model": self.config.selected_model}

    def snapshot(self) -> dict[str, Any]:
        return {"type": "snapshot", "models": [self.model_info(s) for s in self.specs()],
                "system": self.system_info()}

    # ------------------------------------------------------------------ events

    def notify(self, progress: bool = False) -> None:
        if not progress:
            self._state_changed = True
        self._changed.set()

    async def _broadcaster(self) -> None:
        last = 0.0
        while True:
            await self._changed.wait()
            wait = 0.25 - (time.monotonic() - last)
            if not self._state_changed and wait > 0:
                await asyncio.sleep(wait)  # progress-only: at most 4 snapshots/s
            self._changed.clear()
            self._state_changed = False
            last = time.monotonic()
            if self.listeners:
                snap = self.snapshot()
                for send in list(self.listeners):
                    try:
                        await send(snap)
                    except Exception:
                        self.listeners.discard(send)

    # ------------------------------------------------------------------ config

    def update_config(self, body: Any) -> None:
        if not isinstance(body, dict):
            raise EngineError(400, "invalid_config",
                              Msg("invalid_config", detail="expected a JSON object"))
        c = self.config
        new: dict[str, Any] = {}
        try:
            unknown = set(body) - set(c.public())
            if unknown:
                raise ValueError(f"unknown field(s): {', '.join(sorted(unknown))}")
            if "selected_model" in body:
                v = body["selected_model"]
                if v is not None:
                    self.spec(str(v))
                new["selected_model"] = v
            if "idle_unload_s" in body:
                new["idle_unload_s"] = _num(body, "idle_unload_s", 0, 7 * 86400)
            if "min_free_bytes" in body:
                new["min_free_bytes"] = int(_num(body, "min_free_bytes", 0, 1 << 60))
            if "silence_s" in body:
                new["silence_s"] = _num(body, "silence_s", 0.3, 60)
            if "max_duration_s" in body:
                new["max_duration_s"] = _num(body, "max_duration_s", 1, 3600)
            if "language" in body:
                new["language"] = _choice(body, "language", ("auto", *LANGUAGES))
            if "ui_language" in body:
                new["ui_language"] = _choice(body, "ui_language", UI_LANGUAGES)
            if "terms" in body:
                terms = parse_terms(body["terms"])
                new["terms_raw"] = [{"term": t.term, "accept": t.accept, "fix": t.fix}
                                    for t in terms]
        except (ValueError, TypeError) as e:
            raise EngineError(400, "invalid_config", Msg("invalid_config", detail=str(e)))
        except EngineError as e:
            raise EngineError(400, "invalid_config", e.msg)
        for k, v in new.items():
            setattr(c, k, v)
        if "ui_language" in new:
            messages.set_language(c.ui_language)
        if "terms_raw" in new:
            self.terms = parse_terms(c.terms_raw)
            self.prompts = self._build_prompts()
        if "idle_unload_s" in new:
            self.touch_idle()
        self.notify()

    def _build_prompts(self) -> dict[str, str]:
        return {lang: build_whisper_prompt(self.terms, lang) for lang in LANGUAGES}

    # ------------------------------------------------------------------ transcription

    async def transcribe(self, backend: asr.Backend, audio: np.ndarray,
                         language: str) -> dict[str, Any]:
        """Result fields of api.md (minus type / dictation_id). Fixes only for Turkish."""
        terms, prompts = self.terms, self.prompts
        tr = await asyncio.get_running_loop().run_in_executor(
            self.ml, lambda: backend.transcribe(audio, language=language, prompts=prompts))
        text, fixes = apply_fixes(tr.text, terms) if tr.language == "tr" else (tr.text, [])
        return {"raw_text": tr.text, "text": text, "fixes": [list(f) for f in fixes],
                "audio_s": round(len(audio) / asr.SR, 3), "transcribe_s": round(tr.seconds, 3),
                "model": backend.spec.id, "language": tr.language}

    def keep(self, audio: np.ndarray) -> str:
        """Keep the last dictation's audio for KEEP_AUDIO_S; returns its dictation_id."""
        if self.kept is not None:
            self.kept.expire.cancel()
        did = secrets.token_hex(8)
        expire = asyncio.get_running_loop().call_later(KEEP_AUDIO_S, self._drop_kept, did)
        self.kept = Kept(did, audio, expire)
        return did

    def _drop_kept(self, did: str) -> None:
        if self.kept is not None and self.kept.id == did:
            self.kept = None

    async def retranscribe(self, body: Any) -> dict[str, Any]:
        if (not isinstance(body, dict) or not isinstance(body.get("dictation_id"), str)
                or body.get("language") not in LANGUAGES):
            raise EngineError(400, "bad_request", Msg(
                "bad_request", detail='expected {"dictation_id": "…", "language": "tr" | "en"}'))
        if self.dictating:
            raise EngineError(409, "busy")
        kept = self.kept
        if kept is None or kept.id != body["dictation_id"]:
            raise EngineError(404, "dictation_expired")
        model_id = self.config.selected_model
        if model_id is None:
            raise EngineError(409, "no_model_selected")
        self.retranscribing += 1
        try:
            backend = await self.start_load(model_id)
            result = await self.transcribe(backend, kept.audio, body["language"])
        finally:
            self.retranscribing -= 1
            self.touch_idle()
        log.info("retranscribe %s as %s: %.2fs", kept.id, result["language"],
                 result["transcribe_s"])
        return {**result, "dictation_id": kept.id}

    # ------------------------------------------------------------------ load / unload

    def start_load(self, model_id: str) -> asyncio.Task[asr.Backend]:
        """Check the model can be loaded (raises EngineError), then load it in the background.
        Returns the (shared) load task; awaiting it yields the backend."""
        spec = self.spec(model_id)
        if self.backend is not None and self.backend.spec.id == model_id:
            fut: asyncio.Future = asyncio.get_running_loop().create_future()
            fut.set_result(self.backend)
            return fut  # type: ignore[return-value]
        if model_id in self._load_tasks:
            return self._load_tasks[model_id]
        if model_id in self.downloads or self.store.local_path(spec) is None:
            raise EngineError(409, "not_downloaded", Msg("not_downloaded", label=spec.label))
        needed = self.ram_bytes(spec) or 0
        available = psutil.virtual_memory().available
        if self.backend is not None:  # it is unloaded first
            available += self.ram_bytes(self.backend.spec) or 0
        if available < needed:
            raise EngineError(507, "insufficient_ram",
                              Msg("insufficient_ram", label=spec.label, needed_gb=needed,
                                  available_gb=available),
                              needed_bytes=needed, available_bytes=available)
        task = asyncio.create_task(self._load(spec))
        self._load_tasks[model_id] = task
        task.add_done_callback(lambda t: self._load_tasks.pop(model_id, None))
        task.add_done_callback(lambda t: t.cancelled() or t.exception())  # mark retrieved
        return task

    async def _load(self, spec: ModelSpec) -> asr.Backend:
        loop = asyncio.get_running_loop()
        async with self._model_lock:
            if self.backend is not None and self.backend.spec.id == spec.id:
                return self.backend
            self.loading_id = spec.id
            self.errors.pop(spec.id, None)
            self.notify()
            try:
                if self.backend is not None:
                    old, self.backend = self.backend, None
                    self.touch_idle()
                    await loop.run_in_executor(self.ml, asr.unload, old)
                path = self.store.local_path(spec)
                if path is None:
                    raise EngineError(409, "not_downloaded", Msg("not_downloaded",
                                                                 label=spec.label))
                self.backend = await loop.run_in_executor(self.ml, asr.load, spec, path)
                return self.backend
            except EngineError as e:
                self.errors[spec.id] = e.msg
                raise
            except Exception as e:
                log.exception("load failed: %s", spec.id)
                self.errors[spec.id] = Msg("load_failed", error=e)
                raise EngineError(500, "load_failed", self.errors[spec.id]) from e
            finally:
                self.loading_id = None
                self.touch_idle()
                self.notify()

    async def unload(self) -> None:
        async with self._model_lock:
            if self.backend is not None:
                old, self.backend = self.backend, None
                self.touch_idle()  # clears idle_unload_at and notifies
                await asyncio.get_running_loop().run_in_executor(self.ml, asr.unload, old)

    def touch_idle(self) -> None:
        """(Re)start the idle-unload timer; called after loads and dictations."""
        if self._idle_handle is not None:
            self._idle_handle.cancel()
            self._idle_handle = None
        s = self.config.idle_unload_s
        if self.backend is not None and s > 0:
            self.idle_at = time.time() + s
            self._idle_handle = asyncio.get_running_loop().call_later(s, self._idle_fire)
        else:
            self.idle_at = None
        self.notify()

    def _idle_fire(self) -> None:
        self._idle_handle = None
        if self.dictating or self.retranscribing or self._model_lock.locked():
            self.touch_idle()
            return
        log.info("idle unload")
        self.spawn(self.unload())

    # ------------------------------------------------------------------ downloads

    def _remaining(self, exclude: str | None = None) -> int:
        return sum(max(0, d.total - d.done) for k, d in self.downloads.items()
                   if d.running and k != exclude)

    async def start_download(self, model_id: str) -> None:
        spec = self.spec(model_id)
        state = self.model_state(spec)
        if state == "downloading":
            raise EngineError(409, "already_downloading",
                              Msg("already_downloading", label=spec.label))
        if state in ("on_disk", "loaded", "loading"):
            raise EngineError(409, "already_downloaded", Msg("already_downloaded", label=spec.label))
        rf = await self.repo_files(spec)
        if model_id in self.downloads and self.downloads[model_id].running:
            raise EngineError(409, "already_downloading",
                              Msg("already_downloading", label=spec.label))
        done = self.store.downloaded_bytes(spec.repo)
        needed = max(0, rf.total - done)
        free = self.store.disk_free()
        if not disk_rule_ok(free, needed + self._remaining(exclude=model_id),
                            self.config.min_free_bytes):
            raise EngineError(507, "insufficient_disk",
                              Msg("insufficient_disk", min_free_gb=self.config.min_free_bytes),
                              needed_bytes=needed, free_bytes=free,
                              min_free_bytes=self.config.min_free_bytes)
        d = Download(total=rf.total, done=done)
        self.downloads[model_id] = d
        self.errors.pop(model_id, None)
        d.task = asyncio.create_task(self._run_download(spec, rf, d))
        self.notify()

    async def _run_download(self, spec: ModelSpec, rf: RepoFiles, d: Download) -> None:
        def on_bytes(n: int) -> None:
            d.done += n
            self.notify(progress=True)

        def guard() -> None:
            if not disk_rule_ok(self.store.disk_free(), self._remaining(),
                                self.config.min_free_bytes):
                raise DiskGuard()

        log.info("download start: %s (%d/%d bytes on disk)", spec.repo, d.done, d.total)
        assert self.http is not None
        try:
            await self.store.download(self.http, spec.repo, rf, on_bytes, guard)
            self.downloads.pop(spec.id, None)
        except asyncio.CancelledError:
            d.running = False
            log.info("download paused: %s", spec.repo)
        except DiskGuard:
            d.running = False
            self.errors[spec.id] = Msg("download_paused_disk",
                                       min_free_gb=self.config.min_free_bytes)
            log.warning("download stopped by disk guard: %s", spec.repo)
        except Exception as e:
            d.running = False
            self.errors[spec.id] = Msg("download_failed", error=e)
            log.warning("download failed: %s: %s", spec.repo, e)
        finally:
            if d.running is False:
                d.done = self.store.downloaded_bytes(spec.repo)
            self.notify()

    async def cancel_download(self, model_id: str) -> None:
        spec = self.spec(model_id)
        d = self.downloads.get(model_id)
        if d is None or not d.running or d.task is None:
            raise EngineError(409, "not_downloading", Msg("not_downloading", label=spec.label))
        d.task.cancel()
        await asyncio.gather(d.task, return_exceptions=True)

    async def delete_model(self, model_id: str) -> None:
        spec = self.spec(model_id)
        if self.model_state(spec) in ("loaded", "loading") or model_id in self._load_tasks:
            raise EngineError(409, "model_loaded", Msg("model_loaded", label=spec.label))
        d = self.downloads.pop(model_id, None)
        if d is not None and d.task is not None:
            d.task.cancel()
            await asyncio.gather(d.task, return_exceptions=True)
        await asyncio.get_running_loop().run_in_executor(None, self.store.delete, spec.repo)
        self.errors.pop(model_id, None)
        self.notify()
        log.info("deleted %s", spec.repo)

    # ------------------------------------------------------------------ custom models

    async def add_custom(self, repo: Any) -> tuple[int, dict[str, Any]]:
        repo = str(repo or "").strip().removeprefix("https://huggingface.co/").strip("/")
        if not catalog.valid_repo(repo):
            raise EngineError(422, "invalid_repo")
        for s in self.specs():
            if s.repo.lower() == repo.lower():
                if s.custom:
                    return 200, self.model_info(s)
                raise EngineError(409, "already_exists", Msg("already_exists", label=s.label),
                                  id=s.id)
        probe = ModelSpec(catalog.custom_id(repo), repo.split("/")[-1], repo, "", custom=True)
        rf = await self.repo_files(probe)
        try:
            kind = await asyncio.get_running_loop().run_in_executor(
                None, catalog.detect_kind, repo, rf)
        except catalog.UnsupportedModel as e:
            raise EngineError(422, "unsupported_model", detail=str(e))
        except catalog.NetworkError as e:
            raise EngineError(503, "network_error", detail=str(e))
        spec = ModelSpec(probe.id, probe.label, repo, kind, custom=True)
        self.custom.append(spec)
        catalog.save_custom(self.custom_path, self.custom)
        self.notify()
        log.info("custom model added: %s (%s)", repo, kind)
        return 201, self.model_info(spec)

    async def remove_custom(self, model_id: str) -> None:
        spec = self.spec(model_id)
        if not spec.custom:
            raise EngineError(400, "not_custom", Msg("not_custom", label=spec.label))
        await self.delete_model(model_id)
        self.custom = [s for s in self.custom if s.id != model_id]
        catalog.save_custom(self.custom_path, self.custom)
        if self.config.selected_model == model_id:
            self.config.selected_model = None
        self.notify()
