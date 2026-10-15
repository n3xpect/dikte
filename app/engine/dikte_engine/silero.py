"""Silero VAD v6 on MLX (16 kHz streaming only).

Adapted from mlx-audio (`mlx_audio/vad/models/silero_vad`, MIT License, © Prince Canuma)
so the engine doesn't need the whole mlx-audio package. Weights: assets/silero_vad
(see SOURCE.md). Usage: `model = load(WEIGHTS_DIR)`, `state = model.initial_state()`,
`prob, state = model.feed(chunk_512, state)`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, fields
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np


@dataclass
class BranchConfig:
    sample_rate: int = 16000
    filter_length: int = 256
    hop_length: int = 128
    pad: int = 64
    cutoff: int = 129
    context_size: int = 64
    chunk_size: int = 512

    @classmethod
    def from_dict(cls, d: dict) -> BranchConfig:
        names = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in d.items() if k in names})


@dataclass
class State:
    lstm: mx.array | None
    context: mx.array


def _reflect_pad_right(x: mx.array, pad: int) -> mx.array:
    indices = mx.arange(x.shape[-1] - 2, x.shape[-1] - pad - 2, -1)
    return mx.concatenate([x, mx.take(x, indices, axis=-1)], axis=-1)


class Branch(nn.Module):
    def __init__(self, c: BranchConfig):
        super().__init__()
        self.config = c
        self.stft_conv = nn.Conv1d(1, c.cutoff * 2, kernel_size=c.filter_length,
                                   stride=c.hop_length, padding=0, bias=False)
        self.conv1 = nn.Conv1d(c.cutoff, 128, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(128, 64, kernel_size=3, stride=2, padding=1)
        self.conv3 = nn.Conv1d(64, 64, kernel_size=3, stride=2, padding=1)
        self.conv4 = nn.Conv1d(64, 128, kernel_size=3, padding=1)
        self.lstm = nn.LSTM(128, 128)
        self.final_conv = nn.Conv1d(128, 1, kernel_size=1)

    def __call__(self, x: mx.array, state: mx.array | None) -> tuple[mx.array, mx.array]:
        hidden, cell = (None, None) if state is None else (state[0], state[1])
        x = self.stft_conv(_reflect_pad_right(x, self.config.pad)[..., None])
        real, imag = x[..., : self.config.cutoff], x[..., self.config.cutoff :]
        x = mx.sqrt(real * real + imag * imag)
        for conv in (self.conv1, self.conv2, self.conv3, self.conv4):
            x = nn.relu(conv(x))
        hidden_seq, cell_seq = self.lstm(x, hidden=hidden, cell=cell)
        new_state = mx.stack([hidden_seq[:, -1, :], cell_seq[:, -1, :]], axis=0)
        x = mx.sigmoid(self.final_conv(nn.relu(hidden_seq)))
        return mx.mean(mx.squeeze(x, axis=-1), axis=1, keepdims=True), new_state


class SileroVAD(nn.Module):
    def __init__(self, branch_16k: BranchConfig):
        super().__init__()
        self.vad_16k = Branch(branch_16k)

    @property
    def chunk_size(self) -> int:
        return self.vad_16k.config.chunk_size

    def initial_state(self) -> State:
        return State(None, mx.zeros((1, self.vad_16k.config.context_size), dtype=mx.float32))

    def feed(self, chunk: np.ndarray, state: State) -> tuple[float, State]:
        """One 512-sample float32 chunk at 16 kHz → (speech probability, new state)."""
        c = self.vad_16k.config
        x = mx.array(np.asarray(chunk, dtype=np.float32).reshape(1, -1))
        if x.shape[-1] != c.chunk_size:
            raise ValueError(f"expected {c.chunk_size} samples, got {x.shape[-1]}")
        prob, lstm = self.vad_16k(mx.concatenate([state.context, x], axis=-1), state.lstm)
        return prob.item(), State(lstm, x[:, -c.context_size :])


def load(weights_dir: Path) -> SileroVAD:
    config = json.loads((weights_dir / "config.json").read_text())
    model = SileroVAD(BranchConfig.from_dict(config.get("branch_16k", {})))
    weights = {k: v for k, v in mx.load(str(weights_dir / "model.safetensors")).items()
               if k.startswith("vad_16k.")}
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    model.eval()
    return model
