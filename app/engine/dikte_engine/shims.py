"""Import mlx-whisper without numba and scipy.

mlx-whisper imports `numba` and `scipy.signal` at module level, but only uses them for
word-level timestamps (`word_timestamps=True`), which Dikte doesn't use. Both are left out of
the bundle (~255 MB with llvmlite). `import_mlx_whisper()` puts tiny stand-ins into
`sys.modules` just while mlx-whisper is imported and removes them right after, so other
libraries (e.g. transformers' `find_spec("scipy")` checks) still see the packages as absent.
If the real packages are installed they are used as-is.
"""

from __future__ import annotations

import sys
import threading
import types

_lock = threading.Lock()
_done = False


def _numba_stub() -> types.ModuleType:
    numba = types.ModuleType("numba")

    def jit(*args, **kwargs):
        # Used as @numba.jit(nopython=True): return the function unchanged.
        if len(args) == 1 and callable(args[0]) and not kwargs:
            return args[0]
        return lambda fn: fn

    numba.jit = jit
    numba.njit = jit
    numba.prange = range
    return numba


def _scipy_stubs() -> tuple[types.ModuleType, types.ModuleType]:
    def missing(name: str):
        def fail(*_args, **_kwargs):
            raise RuntimeError(f"scipy pakete dahil değil: scipy.signal.{name} kullanılamaz")
        return fail

    scipy = types.ModuleType("scipy")
    signal = types.ModuleType("scipy.signal")
    signal.__getattr__ = missing  # type: ignore[attr-defined]
    scipy.signal = signal  # type: ignore[attr-defined]
    return scipy, signal


def import_mlx_whisper() -> None:
    """Import mlx_whisper (and the submodules the engine uses) once. Thread-safe."""
    global _done
    if _done:
        return
    with _lock:
        if _done:
            return
        added: list[str] = []
        try:
            import numba  # noqa: F401
        except ImportError:
            sys.modules["numba"] = _numba_stub()
            added.append("numba")
        try:
            import scipy.signal  # noqa: F401
        except ImportError:
            scipy, signal = _scipy_stubs()
            sys.modules["scipy"], sys.modules["scipy.signal"] = scipy, signal
            added += ["scipy", "scipy.signal"]
        try:
            import mlx_whisper  # noqa: F401
            import mlx_whisper.load_models  # noqa: F401
            import mlx_whisper.tokenizer  # noqa: F401
            import mlx_whisper.transcribe  # noqa: F401
        finally:
            for name in added:
                sys.modules.pop(name, None)
        _done = True
