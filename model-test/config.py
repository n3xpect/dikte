"""Shared constants. Import this before any Hugging Face / MLX module so the
model cache points at ./models."""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MODELS_DIR = ROOT / "models"
RECORDINGS_DIR = ROOT / "recordings"
RESULTS_CSV = ROOT / "results.csv"
TERMS_YAML = ROOT / "terms.yaml"
SENTENCES_YAML = ROOT / "test_sentences.yaml"

os.environ.setdefault("HF_HUB_CACHE", str(MODELS_DIR))
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

SAMPLE_RATE = 16_000
CHUNK = 512  # samples per VAD frame (32 ms at 16 kHz), required by Silero VAD

LANGUAGE = "tr"
