import numpy as np
import pytest
from karaoke import audio
from karaoke.steps.ingest import INGEST, first_sound_frame
from karaoke.workspace import Workspace
from conftest import write_wav, tone, SR
from test_manifest import song


def test_first_sound_frame():
    x = np.zeros((SR, 2), np.float32)
    x[22050:] = 0.1
    assert first_sound_frame(x) == 22050
    assert first_sound_frame(np.zeros((100, 2), np.float32)) is None


def test_ingest_trims_and_converts(cfg, tmp_path):
    sig = np.concatenate([np.zeros((int(0.5 * 48000), 2), np.float32), tone(4.0, sr=48000)])
    src = write_wav(tmp_path / "in48k.wav", sig, sr=48000)
    ws = Workspace(cfg, song(fichier=src, duree_ref_s=4.5))
    r = INGEST.run(ws, {})
    x, sr = audio.read(ws.work / "input.wav")
    assert sr == 44100 and x.shape[1] == 2
    assert abs(r["offset_s"] - 0.49) < 0.02            # 0.5 s silence minus 10 ms pre-roll
    assert abs(r["duration_s"] - 4.01) < 0.03
    assert abs(r["ref_delta_s"]) < 0.05 and r["duration_alert"] is False
    assert INGEST.artifacts(ws) == [ws.work / "input.wav"]


def test_duration_alert(cfg, tmp_path):
    src = write_wav(tmp_path / "a.wav", tone(4.0))
    r = INGEST.run(Workspace(cfg, song(fichier=src, duree_ref_s=10.0)), {})
    assert r["duration_alert"] is True and r["ref_delta_s"] == pytest.approx(-6.0, abs=0.05)


def test_missing_file(cfg, tmp_path):
    with pytest.raises(FileNotFoundError):
        INGEST.run(Workspace(cfg, song(fichier=tmp_path / "absent.flac")), {})
