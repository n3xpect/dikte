"""Test helpers: synthetic speech, WAV reading, engine subprocess + API/dictation clients."""

from __future__ import annotations

import asyncio
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import traceback
import wave
from collections.abc import Callable
from pathlib import Path
from typing import Any

import aiohttp
import numpy as np

ENGINE_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE_ROOT))

STT_ROOT = ENGINE_ROOT.parent.parent
MODEL_TEST = STT_ROOT / "model-test"
SHARED_MODELS = MODEL_TEST / "models"  # large-v3 already downloaded here (do not re-download)
SR = 16_000
_rng = np.random.default_rng(0)
TMP = Path(tempfile.mkdtemp(prefix="dikte_test_"))


# --------------------------------------------------------------------------- audio

def load_wav(path: str | Path) -> np.ndarray:
    """16-bit PCM WAV (mono, 16 kHz) as float32."""
    with wave.open(str(path), "rb") as w:
        assert w.getsampwidth() == 2 and w.getframerate() == SR, path
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
        return x.reshape(-1, w.getnchannels()).mean(axis=1).astype(np.float32)


def tts(text: str) -> np.ndarray:
    """Turkish speech via macOS `say -v Yelda` + ffmpeg (16 kHz mono)."""
    name = f"tts_{abs(hash(text))}"
    aiff, wav = TMP / f"{name}.aiff", TMP / f"{name}.wav"
    subprocess.run(["say", "-v", "Yelda", "-o", str(aiff), text], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", str(SR),
                    "-ac", "1", "-sample_fmt", "s16", str(wav)], check=True)
    return load_wav(wav)


def noise(seconds: float, level: float = 0.002) -> np.ndarray:
    return (_rng.standard_normal(int(seconds * SR)) * level).astype(np.float32)


# --------------------------------------------------------------------------- engine process

def make_data_dir(link_models: bool = True) -> Path:
    d = Path(tempfile.mkdtemp(prefix="dikte_data_"))
    if link_models:
        (d / "models").symlink_to(SHARED_MODELS)
    return d


class EngineProc:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self.token = secrets.token_hex(16)
        self.log_path = data_dir / "engine.log"
        self.proc: asyncio.subprocess.Process | None = None
        self.port = 0
        self.http: aiohttp.ClientSession | None = None

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def ws_url(self, path: str, token: str | None = None) -> str:
        return f"ws://127.0.0.1:{self.port}{path}?token={token or self.token}"

    async def start(self, timeout: float = 120) -> float:
        t0 = time.perf_counter()
        self._log = open(self.log_path, "wb")
        self.proc = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "dikte_engine", "--data-dir", str(self.data_dir), "--port", "0",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=self._log,
            cwd=ENGINE_ROOT, env={**os.environ, "DIKTE_TOKEN": self.token})
        assert self.proc.stdout is not None
        line = await asyncio.wait_for(self.proc.stdout.readline(), timeout)
        ready = json.loads(line)
        assert ready["event"] == "ready" and ready["version"] == "1", ready
        self.port = ready["port"]
        self.http = aiohttp.ClientSession()
        return time.perf_counter() - t0

    async def req(self, method: str, path: str, body: Any = None, auth: bool = True,
                  timeout: float = 60) -> tuple[int, Any]:
        assert self.http is not None
        headers = {"Authorization": f"Bearer {self.token}"} if auth else {}
        async with self.http.request(method, self.base + path, json=body, headers=headers,
                                     timeout=aiohttp.ClientTimeout(total=timeout)) as r:
            text = await r.text()
            try:
                return r.status, json.loads(text)
            except json.JSONDecodeError:
                return r.status, text

    async def models(self) -> dict[str, dict]:
        status, body = await self.req("GET", "/models")
        assert status == 200, (status, body)
        return {m["id"]: m for m in body["models"]}

    async def stop(self, timeout: float = 15) -> int:
        """Close stdin (the app quitting) and wait for the engine to exit."""
        if self.http:
            await self.http.close()
        assert self.proc is not None and self.proc.stdin is not None
        self.proc.stdin.close()
        try:
            return await asyncio.wait_for(self.proc.wait(), timeout)
        finally:
            if self.proc.returncode is None:
                self.proc.kill()
            self._log.close()

    def log_tail(self, n: int = 40) -> str:
        return "\n".join(self.log_path.read_text(errors="replace").splitlines()[-n:])


class Events:
    """Collects /events snapshots in the background."""

    def __init__(self, eng: EngineProc):
        self.eng = eng
        self.snaps: list[dict] = []
        self._task: asyncio.Task | None = None
        self._cond = asyncio.Condition()

    async def __aenter__(self) -> Events:
        assert self.eng.http is not None
        self.ws = await self.eng.http.ws_connect(self.eng.ws_url("/events"))
        self._task = asyncio.create_task(self._run())
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.ws.close()
        if self._task:
            self._task.cancel()

    async def _run(self) -> None:
        async for msg in self.ws:
            snap = json.loads(msg.data)
            snap["t"] = time.perf_counter()
            async with self._cond:
                self.snaps.append(snap)
                self._cond.notify_all()

    def mark(self) -> int:
        return len(self.snaps)

    async def wait_for(self, pred: Callable[[dict], bool], timeout: float = 60,
                       since: int = 0) -> dict:
        """First snapshot at index >= since matching pred."""
        async def _wait() -> dict:
            i = since
            async with self._cond:
                while True:
                    while i < len(self.snaps):
                        if pred(self.snaps[i]):
                            return self.snaps[i]
                        i += 1
                    await self._cond.wait()
        return await asyncio.wait_for(_wait(), timeout)

    def states(self, model_id: str) -> list[str]:
        out: list[str] = []
        for s in self.snaps:
            st = model_of(s, model_id).get("state")
            if st and not out or out[-1] != st:
                out.append(st)
        return out


def model_of(snap: dict, model_id: str) -> dict:
    return next((m for m in snap["models"] if m["id"] == model_id), {})


async def dictate(eng: EngineProc, audio: np.ndarray, *, chunk_s: float = 0.1,
                  speed: float = 1.0, action: tuple[str, float] | None = None,
                  start: bool = True) -> dict[str, Any]:
    """Stream `audio` to /dictate in chunk_s frames at `speed`x real time (0 = no pacing).
    action=("finish"|"cancel", at_seconds_of_audio) sends that message mid-stream.
    Returns {"msgs": [...], "result": {...}|None, "t_end": s, "t_result": s}."""
    assert eng.http is not None
    ws = await eng.http.ws_connect(eng.ws_url("/dictate"), max_msg_size=0)
    msgs: list[dict] = []
    times: dict[str, float] = {}
    ended = asyncio.Event()

    async def sender() -> None:
        if start:
            await ws.send_str(json.dumps({"type": "start"}))
        n = int(chunk_s * SR)
        t0 = time.perf_counter()
        for i in range(0, len(audio), n):
            if ended.is_set() or ws.closed:
                return
            if action and i / SR >= action[1]:
                await ws.send_str(json.dumps({"type": action[0]}))
                return
            await ws.send_bytes(audio[i:i + n].astype("<f4").tobytes())
            if speed > 0:
                delay = t0 + (i + n) / SR / speed - time.perf_counter()
                if delay > 0:
                    await asyncio.sleep(delay)
            else:
                await asyncio.sleep(0)
        if action:
            await ws.send_str(json.dumps({"type": action[0]}))

    send_task = asyncio.create_task(sender())
    try:
        async for msg in ws:
            if msg.type != aiohttp.WSMsgType.TEXT:
                break
            m = json.loads(msg.data)
            m["t"] = time.perf_counter()
            msgs.append(m)
            if m["type"] == "end":
                ended.set()
                times["t_end"] = m["t"]
            elif m["type"] == "result":
                times["t_result"] = m["t"]
    finally:
        send_task.cancel()
        await ws.close()
    result = next((m for m in msgs if m["type"] == "result"), None)
    return {"msgs": msgs, "types": [m["type"] for m in msgs], "result": result, **times}


# --------------------------------------------------------------------------- tiny runner

def run_tests(tests: dict[str, Callable[[], Any]]) -> None:
    """Run test_* functions (sync or async) in order; exit 1 on any failure."""
    failed = 0
    for name, fn in tests.items():
        if not name.startswith("test_"):
            continue
        t0 = time.perf_counter()
        try:
            res = fn()
            if asyncio.iscoroutine(res):
                asyncio.run(res)
            print(f"PASS {name} ({time.perf_counter() - t0:.1f}s)", flush=True)
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {type(e).__name__}: {e}", flush=True)
            traceback.print_exc()
    total = sum(1 for n in tests if n.startswith("test_"))
    print(f"{total - failed}/{total} passed")
    sys.exit(1 if failed else 0)
