"""HTTP + WebSocket API (see api.md)."""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import time
from typing import Any

import numpy as np
from aiohttp import WSMsgType, web

from . import VERSION
from .engine import Engine, EngineError
from .messages import Msg, render
from .terms import default_terms_json
from .vad import SR, Endpointer

log = logging.getLogger("dikte.server")
ENGINE = web.AppKey("engine", Engine)


def _json(data: Any, status: int = 200) -> web.Response:
    return web.json_response(data, status=status, dumps=lambda o: json.dumps(o, ensure_ascii=False))


def _error(e: EngineError) -> web.Response:
    return _json(e.body(), e.status)


def make_app(engine: Engine, token: str) -> web.Application:
    @web.middleware
    async def middleware(request: web.Request, handler: Any) -> web.StreamResponse:
        auth = request.headers.get("Authorization", "")
        given = auth[7:] if auth.startswith("Bearer ") else request.query.get("token", "")
        if not hmac.compare_digest(given.encode(), token.encode()):
            return _json({"error": "unauthorized", "message": render("unauthorized")}, 401)
        try:
            return await handler(request)
        except EngineError as e:
            return _error(e)

    app = web.Application(middlewares=[middleware], client_max_size=4 * 1024 * 1024)
    app[ENGINE] = engine
    r = app.router
    r.add_get("/health", health)
    r.add_get("/models", models)
    r.add_put("/config", put_config)
    r.add_get("/terms/default", terms_default)
    r.add_post("/unload", unload)
    r.add_post("/retranscribe", retranscribe)
    r.add_post("/models/custom", add_custom)
    r.add_delete("/models/custom/{id:.+}", remove_custom)  # before the generic DELETE
    r.add_post("/models/{id:.+}/download", download)
    r.add_post("/models/{id:.+}/cancel", cancel)
    r.add_post("/models/{id:.+}/load", load)
    r.add_delete("/models/{id:.+}", delete)
    r.add_get("/events", events)
    r.add_get("/dictate", dictate)
    return app


async def _body(request: web.Request) -> Any:
    try:
        return await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise EngineError(400, "invalid_json")


async def health(request: web.Request) -> web.Response:
    return _json({"status": "ok", "version": VERSION})


async def models(request: web.Request) -> web.Response:
    snap = request.app[ENGINE].snapshot()
    return _json({"models": snap["models"], "system": snap["system"]})


async def put_config(request: web.Request) -> web.Response:
    request.app[ENGINE].update_config(await _body(request))
    return _json({"ok": True})


async def terms_default(request: web.Request) -> web.Response:
    return _json({"terms": default_terms_json()})


async def unload(request: web.Request) -> web.Response:
    await request.app[ENGINE].unload()
    return _json({"ok": True})


async def retranscribe(request: web.Request) -> web.Response:
    return _json(await request.app[ENGINE].retranscribe(await _body(request)))


async def add_custom(request: web.Request) -> web.Response:
    body = await _body(request)
    status, info = await request.app[ENGINE].add_custom(
        body.get("repo") if isinstance(body, dict) else None)
    return _json(info, status)


async def remove_custom(request: web.Request) -> web.Response:
    await request.app[ENGINE].remove_custom(request.match_info["id"])
    return _json({"ok": True})


async def download(request: web.Request) -> web.Response:
    await request.app[ENGINE].start_download(request.match_info["id"])
    return _json({"ok": True}, 202)


async def cancel(request: web.Request) -> web.Response:
    await request.app[ENGINE].cancel_download(request.match_info["id"])
    return _json({"ok": True})


async def load(request: web.Request) -> web.Response:
    request.app[ENGINE].start_load(request.match_info["id"])
    return _json({"ok": True}, 202)


async def delete(request: web.Request) -> web.Response:
    await request.app[ENGINE].delete_model(request.match_info["id"])
    return _json({"ok": True})


async def events(request: web.Request) -> web.WebSocketResponse:
    engine = request.app[ENGINE]
    ws = web.WebSocketResponse(heartbeat=30)
    await ws.prepare(request)

    async def send(snap: dict) -> None:
        await ws.send_str(json.dumps(snap, ensure_ascii=False))

    await send(engine.snapshot())
    engine.listeners.add(send)
    try:
        async for _ in ws:  # server -> client only; just wait for close
            pass
    finally:
        engine.listeners.discard(send)
    return ws


async def dictate(request: web.Request) -> web.WebSocketResponse:
    engine = request.app[ENGINE]
    ws = web.WebSocketResponse(max_msg_size=16 * 1024 * 1024)
    await ws.prepare(request)
    if engine.dictating:
        await _ws_error(ws, EngineError(409, "busy"))
        await ws.close()
        return ws
    engine.dictating = True
    try:
        await Dictation(engine, ws).run()
    except Exception as e:
        log.exception("dictation failed")
        await _ws_error(ws, EngineError(500, "internal", Msg("internal", error=e)))
    finally:
        engine.dictating = False
        engine.touch_idle()
        await ws.close()
    return ws


async def _send(ws: web.WebSocketResponse, msg: dict) -> None:
    if not ws.closed:
        try:
            await ws.send_str(json.dumps(msg, ensure_ascii=False))
        except ConnectionError:
            pass


async def _ws_error(ws: web.WebSocketResponse, e: EngineError) -> None:
    await _send(ws, {"type": "error", "code": e.code, "message": e.message})


class Dictation:
    def __init__(self, engine: Engine, ws: web.WebSocketResponse):
        self.engine = engine
        self.ws = ws
        self.loop = asyncio.get_running_loop()
        self.load_error: EngineError | None = None
        self.recording = True

    async def error(self, e: EngineError) -> None:
        await _ws_error(self.ws, e)

    async def run(self) -> None:
        engine, ws = self.engine, self.ws
        try:
            msg = await ws.receive(timeout=30)
        except TimeoutError:
            return
        if msg.type != WSMsgType.TEXT or _type(msg.data) != "start":
            await self.error(EngineError(400, "bad_request", Msg("start_expected")))
            return

        cfg = engine.config
        model_id = cfg.selected_model
        if model_id is None:
            await self.error(EngineError(409, "no_model_selected"))
            return
        try:
            load_task = engine.start_load(model_id)
        except EngineError as e:
            code = "model_not_downloaded" if e.code == "not_downloaded" else e.code
            await self.error(EngineError(e.status, code, e.msg))
            return
        ready = load_task.done()
        await _send(ws, {"type": "model", "state": "ready" if ready else "loading"})
        watcher = asyncio.ensure_future(self._watch_load(load_task, announce=not ready))

        try:
            ep = await self.loop.run_in_executor(engine.vad, lambda: Endpointer(
                silence_s=cfg.silence_s, max_duration_s=cfg.max_duration_s))
            reason = await self._record(ep)
            self.recording = False
            if reason is None or self.load_error:  # client went away / load failed
                return
            t_end = time.perf_counter()
            await _send(ws, {"type": "end", "reason": reason})
            audio = ep.audio()
            if reason in ("cancel", "no_speech") or len(audio) == 0:
                return

            # Keep reading so a late cancel / disconnect aborts the result.
            aborted = asyncio.ensure_future(self._wait_abort())
            done, _ = await asyncio.wait({load_task, aborted}, return_when=asyncio.FIRST_COMPLETED)
            if aborted in done:
                return
            try:
                backend = load_task.result()
            except EngineError as e:
                await self.error(e)
                return
            await _send(ws, {"type": "transcribing"})
            result = await engine.transcribe(backend, audio, cfg.language)
            if aborted.done():
                return
            aborted.cancel()
            log.info("dictation: %.1fs audio, %s, %.2fs transcribe, %.2fs end->result",
                     len(audio) / SR, result["language"], result["transcribe_s"],
                     time.perf_counter() - t_end)
            await _send(ws, {"type": "result", **result, "dictation_id": engine.keep(audio)})
        finally:
            watcher.cancel()

    async def _watch_load(self, task: asyncio.Future, announce: bool) -> None:
        try:
            await asyncio.shield(task)
        except EngineError as e:
            if self.recording:  # afterwards run() reports it
                self.load_error = e
                await self.error(e)
                await self.ws.close()  # ends the receive loop in _record
            return
        if announce:
            await _send(self.ws, {"type": "model", "state": "ready"})

    async def _record(self, ep: Endpointer) -> str | None:
        """Feed audio to the endpointer until it or the client ends the recording."""
        async for msg in self.ws:
            if msg.type == WSMsgType.BINARY:
                data = msg.data
                if len(data) % 4:
                    data = data[: len(data) // 4 * 4]
                pcm = np.frombuffer(data, dtype="<f4")
                evs = await self.loop.run_in_executor(self.engine.vad, ep.feed, pcm)
                for ev in evs:
                    if ev == "speech_start":
                        await _send(self.ws, {"type": "speech_start"})
                if ep.end_reason is not None:
                    return ep.end_reason
            elif msg.type == WSMsgType.TEXT:
                t = _type(msg.data)
                if t in ("finish", "cancel"):
                    return ep.stop(t)
            else:
                break
        return None if self.load_error or self.ws.closed else ep.stop("cancel")

    async def _wait_abort(self) -> None:
        """Return when the client cancels or disconnects (other messages are ignored)."""
        async for msg in self.ws:
            if msg.type == WSMsgType.TEXT and _type(msg.data) == "cancel":
                return
        return


def _type(data: str) -> str | None:
    try:
        obj = json.loads(data)
    except json.JSONDecodeError:
        return None
    return obj.get("type") if isinstance(obj, dict) else None
