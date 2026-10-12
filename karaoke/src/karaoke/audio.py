"""Audio I/O helpers: ffprobe/ffmpeg for decoding, soundfile for WAV/FLAC."""
from __future__ import annotations
import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 44100


def probe_duration(path: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", str(path)], capture_output=True, text=True, check=True)
    return float(out.stdout.strip())


def convert_to_wav(src: Path, dst: Path) -> None:
    """Any audio → 44.1 kHz stereo float32 WAV."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-map", "0:a:0", "-ac", "2",
                    "-ar", str(SR), "-c:a", "pcm_f32le", str(dst)], check=True)


def read(path: Path) -> tuple[np.ndarray, int]:
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    return x, sr


def write_wav(path: Path, data: np.ndarray, sr: int = SR) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.asarray(data, np.float32), sr, subtype="FLOAT")


def write_flac(path: Path, data: np.ndarray, sr: int = SR) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.clip(np.asarray(data, np.float32), -1.0, 1.0), sr, format="FLAC", subtype="PCM_24")
