import numpy as np
import pytest
import soundfile as sf
from karaoke.config import Config

SR = 44100


@pytest.fixture
def cfg(tmp_path):
    c = Config(home=tmp_path / "home")
    c.ensure_dirs()
    return c


def write_wav(path, data, sr=SR):
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.asarray(data, dtype=np.float32), sr, subtype="FLOAT")
    return path


def tone(seconds, freq=440.0, amp=0.5, sr=SR, stereo=True):
    t = np.arange(int(seconds * sr)) / sr
    x = (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    return np.stack([x, x], axis=1) if stereo else x
