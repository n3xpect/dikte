"""Catalog / custom-model validation (real HF calls), disk rule, cache layout, resumable
download (whisper-tiny, ~75 MB, into a temp dir). Run: uv run python tests/test_catalog.py"""

import asyncio
import os
import tempfile
from pathlib import Path

import aiohttp
from common import SHARED_MODELS, make_data_dir, run_tests

from dikte_engine import catalog, store
from dikte_engine import engine as engine_mod
from dikte_engine.catalog import BUILTIN, WHISPER, ModelSpec
from dikte_engine.engine import Engine, EngineError, disk_rule_ok

TINY = "mlx-community/whisper-tiny-mlx"


def test_disk_rule():
    GB = 10**9
    assert disk_rule_ok(free=20 * GB, remaining=3 * GB, min_free=10 * GB)
    assert disk_rule_ok(free=13 * GB, remaining=3 * GB, min_free=10 * GB)  # exactly at the limit
    assert not disk_rule_ok(free=13 * GB - 1, remaining=3 * GB, min_free=10 * GB)
    assert not disk_rule_ok(free=400 * GB, remaining=1 * GB, min_free=10_000 * GB)
    assert disk_rule_ok(free=5 * GB, remaining=0, min_free=5 * GB)


def test_ram_rule():
    async def main():
        eng = Engine(make_data_dir())
        real = engine_mod.psutil.virtual_memory

        class VM:
            available = 2 * 10**9
        engine_mod.psutil.virtual_memory = lambda: VM()
        try:
            eng.start_load("large-v3")
            raise AssertionError("loaded with 2 GB available")
        except EngineError as e:
            assert (e.status, e.code) == (507, "insufficient_ram"), e.body()
            assert e.details == {"needed_bytes": int(3_083_520_416 * 1.2),
                                 "available_bytes": 2 * 10**9}, e.details
        finally:
            engine_mod.psutil.virtual_memory = real
        try:
            eng.start_load("turbo")  # not on disk
            raise AssertionError("turbo is not downloaded")
        except EngineError as e:
            assert (e.status, e.code) == (409, "not_downloaded")

    asyncio.run(main())


def test_builtin_catalog():
    ids = [s.id for s in BUILTIN]
    assert ids == ["large-v3", "turbo"], ids
    assert [s.id for s in BUILTIN if s.recommended] == ["large-v3"]
    assert {s.kind for s in BUILTIN} == {WHISPER}
    assert all(s.note for s in BUILTIN)


def test_repo_validation_and_ids():
    assert catalog.custom_id("org/name") == "hf:org/name"
    for ok in ["mlx-community/whisper-tiny-mlx", "a/b.c_d-e"]:
        assert catalog.valid_repo(ok), ok
    for bad in ["", "noslash", "a/b/c", "../x", "a/..", "a b/c", "/x"]:
        assert not catalog.valid_repo(bad), bad


def test_hf_detect_kind():
    for repo, kind in [(TINY, WHISPER), ("mlx-community/whisper-large-v3-turbo", WHISPER)]:
        rf = catalog.fetch_repo_files(repo)
        assert len(rf.sha) == 40 and rf.total > 0 and rf.weights > 0, rf
        assert catalog.detect_kind(repo, rf) == kind, repo
    rf = catalog.fetch_repo_files("mlx-community/whisper-large-v3-mlx")
    assert rf.weights == 3_083_520_416

    for repo in ["mlx-community/Llama-3.2-1B-Instruct-4bit",  # not ASR
                 "mlx-community/Qwen3-ASR-1.7B-8bit"]:          # ASR, but no longer supported
        rf = catalog.fetch_repo_files(repo)
        try:
            catalog.detect_kind(repo, rf)
            raise AssertionError(f"{repo} accepted as a Whisper model")
        except catalog.UnsupportedModel:
            pass
    try:
        catalog.fetch_repo_files("mlx-community/this-repo-does-not-exist-dikte")
        raise AssertionError("missing repo accepted")
    except catalog.RepoNotFound:
        pass


def test_custom_and_sizes_persistence():
    d = Path(tempfile.mkdtemp())
    specs = [ModelSpec("hf:a/b", "b", "a/b", WHISPER, custom=True),
             ModelSpec("hf:c/d", "d", "c/d", "qwen3-asr", custom=True)]  # old, now unsupported
    catalog.save_custom(d / "custom_models.json", specs)
    assert catalog.load_custom(d / "custom_models.json") == specs[:1]
    assert catalog.load_custom(d / "missing.json") == []

    sizes = catalog.SizesCache(d / "sizes.json")
    rf = catalog.RepoFiles("x" * 40, [catalog.RepoFile("weights.npz", 10, "e" * 64, True)])
    sizes.put("a/b", rf)
    assert catalog.SizesCache(d / "sizes.json").get("a/b") == rf


def test_store_reads_hf_cache():
    s = store.Store(SHARED_MODELS)  # read-only use of the shared cache
    spec = BUILTIN[0]
    path = s.local_path(spec)
    assert path is not None and (path / "config.json").exists(), path
    assert s.downloaded_bytes(spec.repo) >= 3_083_520_416
    assert s.weights_on_disk(spec.repo) == 3_083_520_416
    turbo = BUILTIN[1]  # not downloaded in the shared cache
    assert s.local_path(turbo) is None and s.downloaded_bytes(turbo.repo) == 0


def test_download_pause_resume_delete():
    async def main():
        models = Path(tempfile.mkdtemp()) / "models"
        models.mkdir()
        s = store.Store(models)
        spec = ModelSpec("hf:" + TINY, "tiny", TINY, WHISPER, custom=True)
        rf = catalog.fetch_repo_files(TINY)
        got = [0]

        def on_bytes(n: int) -> None:
            got[0] += n

        def guard() -> None:
            raise store.DiskGuard("stop")

        old = store.GUARD_EVERY
        store.GUARD_EVERY = 20 * 1024 * 1024
        try:
            async with aiohttp.ClientSession() as http:
                try:
                    await s.download(http, TINY, rf, on_bytes, guard)
                    raise AssertionError("guard did not stop the download")
                except store.DiskGuard:
                    pass
                first = got[0]
                partial = s.downloaded_bytes(TINY)
                assert 20e6 <= first < rf.total and partial >= first - 2e6, (first, partial)
                assert list((s.repo_dir(TINY) / "blobs").glob("*.incomplete"))
                assert s.local_path(spec) is None

                got[0] = 0
                await s.download(http, TINY, rf, on_bytes, lambda: None)
                assert got[0] < rf.total - 15e6, ("did not resume", got[0], rf.total)
        finally:
            store.GUARD_EVERY = old
        assert s.local_path(spec) is not None
        assert s.downloaded_bytes(TINY) == rf.total, (s.downloaded_bytes(TINY), rf.total)
        assert not list((s.repo_dir(TINY) / "blobs").glob("*.incomplete"))
        snap = s.snapshot_dir(TINY)
        assert snap is not None and snap.name == rf.sha
        assert os.readlink(snap / "weights.npz").startswith("../../blobs/")

        # huggingface_hub sees it as a complete cached snapshot (offline)
        os.environ["HF_HUB_CACHE"] = str(models)
        from huggingface_hub import snapshot_download

        got = Path(snapshot_download(TINY, cache_dir=models, local_files_only=True))
        assert got.resolve() == snap.resolve(), (got, snap)

        s.delete(TINY)
        assert not s.repo_dir(TINY).exists() and s.downloaded_bytes(TINY) == 0

    asyncio.run(main())


if __name__ == "__main__":
    run_tests(dict(globals()))
