"""python -m dikte_engine --data-dir DIR [--port 0]   (token in env DIKTE_TOKEN)"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
import threading
from pathlib import Path


def main() -> None:
    p = argparse.ArgumentParser(prog="dikte_engine")
    p.add_argument("--data-dir", required=True, type=Path)
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--ignore-stdin", action="store_true",
                   help="do not exit on stdin EOF (manual runs)")
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname).1s %(name)s: %(message)s",
                        datefmt="%H:%M:%S")
    for noisy in ("aiohttp.access", "httpx", "httpx2", "huggingface_hub"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    token = os.environ.get("DIKTE_TOKEN", "")
    if not token:
        sys.exit("DIKTE_TOKEN is not set")
    data_dir = args.data_dir.expanduser().absolute()
    # Must be set before any Hugging Face / MLX import.
    os.environ["HF_HUB_CACHE"] = str(data_dir / "models")
    os.environ["HF_XET_CACHE"] = str(data_dir / "engine" / "xet")
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    asyncio.run(serve(data_dir, args.host, args.port, token, not args.ignore_stdin))
    # Skip interpreter teardown: executor threads may still be inside MLX/torch calls.
    sys.stderr.flush()
    os._exit(0)


async def serve(data_dir: Path, host: str, port: int, token: str, watch_stdin: bool) -> None:
    from aiohttp import web

    from . import VERSION
    from .engine import Engine
    from .server import make_app

    log = logging.getLogger("dikte")
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    engine = Engine(data_dir)
    runner = web.AppRunner(make_app(engine, token), access_log=None, handle_signals=False,
                           shutdown_timeout=1.0)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    await site.start()
    await engine.start()
    bound = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    sys.stdout.write(json.dumps({"event": "ready", "port": bound, "version": VERSION}) + "\n")
    sys.stdout.flush()
    log.info("listening on %s:%d, data %s", host, bound, data_dir)

    if watch_stdin:
        threading.Thread(target=_wait_stdin_eof, args=(loop, stop), daemon=True).start()
    await stop.wait()
    log.info("shutting down")
    await engine.close()
    await runner.cleanup()


def _wait_stdin_eof(loop: asyncio.AbstractEventLoop, stop: asyncio.Event) -> None:
    try:
        while sys.stdin.buffer.read(4096):
            pass
    except OSError:
        pass
    log = logging.getLogger("dikte")
    log.info("stdin closed")
    loop.call_soon_threadsafe(stop.set)


if __name__ == "__main__":
    main()
