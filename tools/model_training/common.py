"""Shared constants and helpers for the MPL audio-category model pipeline.

The values here form the contract with the Flutter app (lib/ai/model_manifest.dart
and lib/ai/audio_preprocessor.dart). Change them together.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np

# Must match lib/core/models/category.dart (CategoryIds). "needs_review" is a
# workflow outcome and can never be a model label.
APP_CATEGORY_IDS = [
    "quran", "naat", "noha", "hamd", "manqabat", "nasheed",
    "sad", "romantic", "dance", "pop", "rock", "classical",
    "instrumental", "speech", "other",
]

SAMPLE_RATE = 16_000          # YAMNet input rate
WINDOW_SECONDS = 5.0          # context per window fed to the model
WINDOW_SAMPLES = int(SAMPLE_RATE * WINDOW_SECONDS)
WINDOWS_PER_TRACK = 5         # app samples this many windows per track
AUDIO_EXTENSIONS = {".mp3", ".m4a", ".aac", ".flac", ".wav", ".ogg", ".opus", ".aiff", ".aif"}

YAMNET_HANDLE = "https://tfhub.dev/google/yamnet/1"


def plan_windows(duration_s: float, count: int = WINDOWS_PER_TRACK) -> list[float]:
    """Window start offsets (s). Mirrors AudioPreprocessor.planWindows in Dart."""
    if duration_s <= WINDOW_SECONDS or count <= 1:
        return [max(0.0, (duration_s - WINDOW_SECONDS) / 2)]
    span = duration_s - WINDOW_SECONDS
    lo, hi = span * 0.1, span * 0.9
    return [lo + (hi - lo) * i / (count - 1) for i in range(count)]


def fit_length(x: np.ndarray, length: int = WINDOW_SAMPLES) -> np.ndarray:
    """Centre pad/crop. Mirrors AudioPreprocessor.fitLength."""
    if len(x) == length:
        return x
    out = np.zeros(length, dtype=np.float32)
    if len(x) > length:
        start = (len(x) - length) // 2
        out[:] = x[start:start + length]
    else:
        start = (length - len(x)) // 2
        out[start:start + len(x)] = x
    return out


def rms_db(x: np.ndarray) -> float:
    rms = float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0
    return -120.0 if rms <= 1e-6 else 20 * np.log10(rms)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def save_json(path: Path, obj) -> None:
    Path(path).write_text(json.dumps(obj, indent=2, ensure_ascii=False), encoding="utf-8")
