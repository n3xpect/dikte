"""End-to-end: engine subprocess on a temp data dir whose models/ links to model-test/models
(large-v3 already there). Downloads only whisper-tiny (~75 MB), then deletes it.
Run: uv run python tests/test_integration.py"""

import asyncio
import json
import re
import signal
import time
from urllib.parse import quote

import aiohttp
import numpy as np
import psutil
from common import (
    MODEL_TEST,
    SR,
    EngineProc,
    Events,
    dictate,
    load_wav,
    make_data_dir,
    model_of,
    noise,
    tts,
)

import dikte_engine.terms as T

TINY = "mlx-community/whisper-tiny-mlx"
TINY_ID = "hf:" + TINY
TINY_PATH = quote(TINY_ID, safe=":")  # hf:mlx-community%2Fwhisper-tiny-mlx
REC = MODEL_TEST / "recordings" / "20261015-190001_dev03.wav"
STEPS: list = []
REPORT: dict = {}


def step(fn):
    STEPS.append(fn)
    return fn


def rss_mb(eng: EngineProc) -> float:
    assert eng.proc is not None
    return psutil.Process(eng.proc.pid).memory_info().rss / 1e6


@step
async def auth(eng: EngineProc, ev: Events):
    assert (await eng.req("GET", "/health", auth=False))[0] == 401
    eng_tok = eng.token
    eng.token = "wrong"
    assert (await eng.req("GET", "/models"))[0] == 401
    try:
        await eng.http.ws_connect(eng.ws_url("/events"))
        raise AssertionError("ws without valid token accepted")
    except aiohttp.WSServerHandshakeError as e:
        assert e.status == 401
    eng.token = eng_tok
    assert await eng.req("GET", "/health") == (200, {"status": "ok", "version": "1"})


@step
async def models_and_config(eng: EngineProc, ev: Events):
    # sizes of not-yet-downloaded models are fetched from HF in the background at startup
    await ev.wait_for(lambda s: all(m["size_bytes"] for m in s["models"]), 30)
    st, body = await eng.req("GET", "/models")
    assert st == 200 and set(body) == {"models", "system"}
    m = {x["id"]: x for x in body["models"]}
    assert list(m) == ["large-v3", "turbo", "qwen3-1.7b"], list(m)
    assert m["large-v3"]["state"] == "on_disk" and m["large-v3"]["recommended"]
    assert m["large-v3"]["downloaded_bytes"] >= 3_083_520_416
    assert m["turbo"]["state"] == m["qwen3-1.7b"]["state"] == "not_downloaded"
    assert m["turbo"]["size_bytes"] and m["turbo"]["downloaded_bytes"] == 0
    for x in m.values():
        assert x["ram_bytes"] > x["size_bytes"] * 0.9 and x["progress"] is None
    sysinfo = body["system"]
    assert sysinfo["disk_free_bytes"] > 0 and sysinfo["ram_total_bytes"] > 8e9
    assert sysinfo["idle_unload_at"] is None

    st, d = await eng.req("GET", "/terms/default")
    assert st == 200 and len(d["terms"]) == len(T.load_default_terms())
    assert (await eng.req("PUT", "/config", {"selected_model": "nope"}))[0] == 400
    assert (await eng.req("PUT", "/config", {"silence_s": "x"}))[0] == 400
    assert (await eng.req("PUT", "/config", {"bogus": 1}))[0] == 400
    assert (await eng.req("PUT", "/config", {"terms": [{"accept": []}]}))[0] == 400
    cfg = {"selected_model": "large-v3", "terms": d["terms"], "silence_s": 3.0,
           "max_duration_s": 120, "language": "tr", "idle_unload_s": 300,
           "min_free_bytes": 10 * 1024**3}
    assert await eng.req("PUT", "/config", cfg) == (200, {"ok": True})
    snap = await ev.wait_for(lambda s: s["system"]["selected_model"] == "large-v3")
    assert snap["system"]["idle_unload_s"] == 300


@step
async def load_large_v3(eng: EngineProc, ev: Events):
    st, body = await eng.req("POST", "/models/turbo/load")
    assert st == 409 and body["error"] == "not_downloaded", body
    rss0 = rss_mb(eng)
    t0, mark = time.perf_counter(), ev.mark()
    assert (await eng.req("POST", "/models/large-v3/load"))[0] == 202
    await ev.wait_for(lambda s: model_of(s, "large-v3")["state"] == "loaded", 120, since=mark)
    REPORT["load_s"] = time.perf_counter() - t0
    assert ev.states("large-v3")[-2:] == ["loading", "loaded"], ev.states("large-v3")
    snap = ev.snaps[-1]
    assert snap["system"]["idle_unload_at"] > time.time() + 200
    assert (await eng.req("POST", "/models/large-v3/load"))[0] == 202  # already loaded: no-op
    st, body = await eng.req("DELETE", "/models/large-v3")
    assert st == 409 and body["error"] == "model_loaded"
    REPORT["rss_mb_before_load"], REPORT["rss_mb_loaded"] = rss0, rss_mb(eng)


@step
async def dictate_silence_end_realtime(eng: EngineProc, ev: Events):
    ref = "Bu değişiklikleri commit'leyip main branch'e merge edelim."
    speech = load_wav(REC)
    audio = np.concatenate([noise(0.5), speech, noise(3.5)])
    r = await dictate(eng, audio, chunk_s=0.1, speed=1.0)
    assert r["types"] == ["model", "speech_start", "end", "transcribing", "result"], r["types"]
    assert r["msgs"][0]["state"] == "ready"
    assert r["msgs"][2]["reason"] == "silence"
    res = r["result"]
    assert res["model"] == "large-v3" and set(res) >= {"raw_text", "text", "fixes", "audio_s",
                                                        "transcribe_s"}
    wer, _ = T.wer_cer(res["text"], ref)
    hits, total, _ = T.term_hits(res["text"], ref, T.load_default_terms())
    assert wer <= 0.15 and hits == total, (res["text"], wer, hits, total)
    assert abs(res["audio_s"] - len(speech) / SR) < 1.0, (res["audio_s"], len(speech) / SR)
    REPORT["realtime_end_to_result_s"] = r["t_result"] - r["t_end"]
    REPORT["realtime_text"] = res["text"]


@step
async def dictate_finish_and_fixes(eng: EngineProc, ev: Events):
    speech = tts("Yeni bir brenç açıp oraya komit atalım.")
    audio = np.concatenate([noise(0.5), speech, noise(1.0), noise(10)])
    r = await dictate(eng, audio, speed=4.0, action=("finish", 0.5 + len(speech) / SR + 0.6))
    assert r["types"] == ["model", "speech_start", "end", "transcribing", "result"], r["types"]
    assert r["msgs"][2]["reason"] == "finish"
    res = r["result"]
    T_ = T.load_default_terms()
    # say's Turkish voice pronounces the words as written; fixes must map them back
    assert T.term_hits(res["text"], "Yeni bir branch açıp oraya commit atalım.", T_)[0] >= 1, res
    assert res["text"] == T.apply_fixes(res["raw_text"], T_)[0]
    assert all(isinstance(f, list) and len(f) == 2 for f in res["fixes"])
    REPORT["finish_text"] = (res["raw_text"], res["text"], res["fixes"])


@step
async def dictate_cancel_no_speech_busy(eng: EngineProc, ev: Events):
    speech = tts("Bunu iptal edeceğim, yazılmasın.")
    r = await dictate(eng, np.concatenate([noise(0.3), speech, noise(5)]), speed=4.0,
                      action=("cancel", 0.3 + len(speech) / SR * 0.8))
    assert r["types"] == ["model", "speech_start", "end"], r["types"]
    assert r["msgs"][-1]["reason"] == "cancel" and r["result"] is None

    r = await dictate(eng, noise(17), speed=0)
    assert r["types"] == ["model", "end"] and r["msgs"][-1]["reason"] == "no_speech", r["msgs"]

    r = await dictate(eng, noise(2), speed=0, action=("finish", 1.0))  # finish w/o speech
    assert r["types"] == ["model", "end"] and r["msgs"][-1]["reason"] == "no_speech", r["msgs"]

    # second concurrent dictation -> busy
    first = asyncio.create_task(dictate(eng, np.concatenate([speech, noise(4)]), speed=2.0))
    await asyncio.sleep(0.5)
    r2 = await dictate(eng, noise(1), speed=0)
    assert r2["types"] == ["error"] and r2["msgs"][0]["code"] == "busy", r2["msgs"]
    r1 = await first
    assert r1["types"][-1] == "result", r1["types"]

    # client disconnect mid-recording: engine must recover and accept the next dictation
    ws = await eng.http.ws_connect(eng.ws_url("/dictate"))
    await ws.send_str(json.dumps({"type": "start"}))
    await ws.send_bytes(speech[: SR].astype("<f4").tobytes())
    await ws.close()
    await asyncio.sleep(0.3)
    r = await dictate(eng, noise(1), speed=0, action=("cancel", 0.5))
    assert r["types"] == ["model", "end"], r["types"]


@step
async def dictate_while_unloaded_and_idle_unload(eng: EngineProc, ev: Events):
    mark = ev.mark()
    assert await eng.req("POST", "/unload") == (200, {"ok": True})
    await ev.wait_for(lambda s: model_of(s, "large-v3")["state"] == "on_disk", since=mark)
    await asyncio.sleep(1.0)
    REPORT["rss_mb_after_unload"] = rss_mb(eng)

    speech = tts("Model yüklenirken konuşmaya başladım.")
    r = await dictate(eng, np.concatenate([noise(0.3), speech, noise(3.5)]), speed=1.0)
    t = r["types"]
    assert t[0] == "model" and r["msgs"][0]["state"] == "loading", r["msgs"]
    assert ["model", "ready"] == [t[t.index("model", 1)], r["msgs"][t.index("model", 1)]["state"]]
    assert t[-3:] == ["end", "transcribing", "result"] and "speech_start" in t, t
    REPORT["cold_dictation_end_to_result_s"] = r["t_result"] - r["t_end"]

    mark = ev.mark()
    assert await eng.req("PUT", "/config", {"idle_unload_s": 3}) == (200, {"ok": True})
    snap = await ev.wait_for(lambda s: s["system"]["idle_unload_s"] == 3, since=mark)
    at = snap["system"]["idle_unload_at"]
    assert at is not None and at - time.time() < 3.5, at - time.time()
    t0 = time.perf_counter()
    snap = await ev.wait_for(lambda s: model_of(s, "large-v3")["state"] == "on_disk", 10,
                             since=mark)
    REPORT["idle_unload_after_s"] = time.perf_counter() - t0
    assert snap["system"]["idle_unload_at"] is None
    assert await eng.req("PUT", "/config", {"idle_unload_s": 300}) == (200, {"ok": True})


@step
async def download_rules_and_custom_model(eng: EngineProc, ev: Events):
    st, body = await eng.req("POST", "/models/large-v3/download")
    assert st == 409 and body["error"] == "already_downloaded", body
    assert await eng.req("PUT", "/config", {"min_free_bytes": 10 * 10**12}) == (200, {"ok": True})
    st, body = await eng.req("POST", "/models/turbo/download")
    assert st == 507 and body["error"] == "insufficient_disk", body
    assert body["needed_bytes"] > 1.5e9 and body["min_free_bytes"] == 10 * 10**12
    assert body["free_bytes"] > 0 and body["message"]
    assert (await eng.models())["turbo"]["state"] == "not_downloaded"

    for repo, code, err in [("not a repo", 422, "invalid_repo"),
                            ("mlx-community/does-not-exist-dikte-xyz", 404, "repo_not_found"),
                            ("mlx-community/Llama-3.2-1B-Instruct-4bit", 422,
                             "unsupported_model"),
                            ("mlx-community/whisper-large-v3-mlx", 409, "already_exists")]:
        st, body = await eng.req("POST", "/models/custom", {"repo": repo})
        assert (st, body.get("error")) == (code, err), (repo, st, body)
    st, info = await eng.req("POST", "/models/custom", {"repo": TINY})
    assert st == 201 and info["id"] == TINY_ID and info["kind"] == "mlx-whisper", info
    assert info["custom"] and info["size_bytes"] > 70e6 and info["state"] == "not_downloaded"
    assert (await eng.req("POST", "/models/custom", {"repo": TINY}))[0] == 200
    assert json.loads((eng.data_dir / "engine" / "custom_models.json").read_text())["models"]

    # disk guard for the custom model too, then a real download with a cancel/resume
    st, _ = await eng.req("POST", f"/models/{TINY_PATH}/download")
    assert st == 507
    await eng.req("PUT", "/config", {"min_free_bytes": 10 * 1024**3})
    assert (await eng.req("POST", f"/models/{TINY_PATH}/download"))[0] == 202
    await ev.wait_for(lambda s: (model_of(s, TINY_ID).get("progress") or 0) > 0.05, 60)
    assert (await eng.req("POST", f"/models/{TINY_PATH}/download"))[0] == 409
    assert await eng.req("POST", f"/models/{TINY_PATH}/cancel") == (200, {"ok": True})
    m = (await eng.models())[TINY_ID]
    assert m["state"] == "paused" and 0 < m["downloaded_bytes"] < m["size_bytes"], m
    paused_at = m["downloaded_bytes"]
    n0 = len(ev.snaps)
    assert (await eng.req("POST", f"/models/{TINY_PATH}/download"))[0] == 202
    await ev.wait_for(lambda s: model_of(s, TINY_ID)["state"] == "on_disk", 120, since=n0)
    progress = [model_of(s, TINY_ID)["progress"] for s in ev.snaps[n0:]]
    progress = [p for p in progress if p is not None]
    assert progress and progress[0] >= paused_at / m["size_bytes"] - 0.01, (progress[:3], paused_at)
    gaps = [b["t"] - a["t"] for a, b in zip(ev.snaps[n0:], ev.snaps[n0 + 1:])]
    REPORT["events_min_gap_s_during_download"] = min(gaps) if gaps else None
    m = (await eng.models())[TINY_ID]
    assert m["downloaded_bytes"] == m["size_bytes"], m

    # use it, then clean up
    await eng.req("PUT", "/config", {"selected_model": TINY_ID})
    r = await dictate(eng, np.concatenate([noise(0.3), tts("Merhaba dünya."), noise(3.5)]),
                      speed=0)
    assert r["types"][-1] == "result" and r["result"]["model"] == TINY_ID, r["msgs"]
    assert r["msgs"][0]["state"] == "loading"  # large-v3 was unloaded by the idle timer
    st, body = await eng.req("DELETE", f"/models/{TINY_PATH}")
    assert st == 409 and body["error"] == "model_loaded"
    await eng.req("POST", "/unload")
    assert await eng.req("DELETE", f"/models/{TINY_PATH}") == (200, {"ok": True})
    m = (await eng.models())[TINY_ID]
    assert m["state"] == "not_downloaded" and m["downloaded_bytes"] == 0, m
    assert await eng.req("DELETE", f"/models/custom/{TINY_PATH}") == (200, {"ok": True})
    ms = await eng.models()
    assert TINY_ID not in ms and ms["large-v3"]["state"] == "on_disk"
    assert not (MODEL_TEST / "models" / "models--mlx-community--whisper-tiny-mlx").exists()
    st, _ = await eng.req("GET", "/models")
    assert (await eng.req("PUT", "/config", {"selected_model": "large-v3"}))[0] == 200


@step
async def dictation_errors(eng: EngineProc, ev: Events):
    await eng.req("PUT", "/config", {"selected_model": "turbo"})
    r = await dictate(eng, noise(1), speed=0)
    assert r["types"] == ["error"] and r["msgs"][0]["code"] == "model_not_downloaded", r["msgs"]
    await eng.req("PUT", "/config", {"selected_model": None})
    r = await dictate(eng, noise(1), speed=0)
    assert r["types"] == ["error"] and r["msgs"][0]["code"] == "no_model_selected", r["msgs"]
    await eng.req("PUT", "/config", {"selected_model": "large-v3"})


async def sigterm_exit() -> float:
    eng = EngineProc(make_data_dir())
    await eng.start()
    assert eng.proc is not None
    t0 = time.perf_counter()
    eng.proc.send_signal(signal.SIGTERM)
    code = await asyncio.wait_for(eng.proc.wait(), 15)
    await eng.http.close()
    assert code == 0, code
    return time.perf_counter() - t0


async def main() -> int:
    eng = EngineProc(make_data_dir())
    REPORT["startup_s"] = await eng.start()
    failed = 0
    try:
        async with Events(eng) as ev:
            for fn in STEPS:
                t0 = time.perf_counter()
                try:
                    await fn(eng, ev)
                    print(f"PASS {fn.__name__} ({time.perf_counter() - t0:.1f}s)", flush=True)
                except Exception as e:
                    failed += 1
                    import traceback

                    print(f"FAIL {fn.__name__}: {type(e).__name__}: {e}", flush=True)
                    traceback.print_exc()
    finally:
        t0 = time.perf_counter()
        code = await eng.stop()
        print(f"{'PASS' if code == 0 else 'FAIL'} stdin_eof_exit (code {code}, "
              f"{time.perf_counter() - t0:.1f}s)")
        failed += code != 0
        log = eng.log_path.read_text()
        REPORT["mlx_memory_log"] = re.findall(r"(?:loaded|unloaded) .*GB", log)
        if failed:
            print("--- engine log tail ---\n" + eng.log_tail())
    try:
        print(f"PASS sigterm_exit ({await sigterm_exit():.1f}s)")
    except Exception as e:
        failed += 1
        print(f"FAIL sigterm_exit: {e}")
    print("\nreport:")
    for k, v in REPORT.items():
        print(f"  {k}: {v if not isinstance(v, float) else round(v, 3)}")
    print(f"{len(STEPS) + 2 - failed}/{len(STEPS) + 2} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
