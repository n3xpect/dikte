"""Download STT models into ./models.

    uv run download.py                  # default models
    uv run download.py turbo qwen3-0.6b # specific models
    uv run download.py --all            # every model
    uv run download.py --list           # show models and download status
"""

import config  # noqa: F401  (must come first: sets HF_HUB_CACHE)

import argparse
import sys

from backends import MODELS, is_downloaded


def show_list() -> None:
    print(f"{'key':<12} {'repo':<52} {'size':>8}  {'default':<7}  downloaded")
    for s in MODELS.values():
        print(f"{s.key:<12} {s.repo:<52} {s.size_gb:>5.2f} GB  "
              f"{'yes' if s.default else '':<7}  {'yes' if is_downloaded(s.key) else 'no'}")
    print(f"\ncache: {config.MODELS_DIR}")


def download(keys: list[str]) -> int:
    from huggingface_hub import snapshot_download

    failed = []
    for key in keys:
        spec = MODELS[key]
        if is_downloaded(key):
            print(f"[skip] {key}: already downloaded ({spec.repo})")
            continue
        print(f"[get ] {key}: {spec.repo} (~{spec.size_gb:.2f} GB)")
        try:
            snapshot_download(spec.repo)
        except Exception as e:  # keep going with the remaining models
            print(f"[fail] {key}: {e}", file=sys.stderr)
            failed.append(key)
            continue
        print(f"[ ok ] {key}" if is_downloaded(key) else f"[warn] {key}: files incomplete")
    return 1 if failed else 0


def main() -> int:
    p = argparse.ArgumentParser(description="Download STT models into ./models")
    p.add_argument("keys", nargs="*", help=f"model keys: {', '.join(MODELS)}")
    p.add_argument("--all", action="store_true", help="download every model")
    p.add_argument("--list", action="store_true", help="list models and status")
    args = p.parse_args()

    if args.list:
        show_list()
        return 0
    unknown = [k for k in args.keys if k not in MODELS]
    if unknown:
        p.error(f"unknown model(s): {', '.join(unknown)}. Known: {', '.join(MODELS)}")
    if args.all:
        keys = list(MODELS)
    elif args.keys:
        keys = args.keys
    else:
        keys = [k for k, s in MODELS.items() if s.default]
    return download(keys)


if __name__ == "__main__":
    sys.exit(main())
