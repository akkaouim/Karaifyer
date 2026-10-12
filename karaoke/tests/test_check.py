import numpy as np
import pytest
from karaoke import audio
from karaoke.steps.check import CHECK, vocal_activity
from karaoke.workspace import Workspace
from conftest import tone
from test_manifest import song


def vocals_with_phrases(phrases, total=20.0):
    x = np.zeros((int(total * 44100), 2), np.float32)
    for a, b in phrases:
        x[int(a * 44100):int(b * 44100)] = tone(b - a, amp=0.3)[: int(b * 44100) - int(a * 44100)]
    return x


def test_activity():
    act = vocal_activity(vocals_with_phrases([(1, 2)], total=3), 44100)
    assert act[25] and not act[5] and not act[50]


def test_check_rate_and_ends(cfg):
    ws = Workspace(cfg, song())
    audio.write_wav(ws.stems / "vocals.wav", vocals_with_phrases([(2, 5), (8, 10), (15, 18)]))
    audio.write_wav(ws.stems / "drums.wav", np.zeros((20 * 44100, 2), np.float32))
    lines = [{"t": 2.0, "text": "a", "score": 1}, {"t": 8.0, "text": "b", "score": 1},
             {"t": 12.0, "text": "faux", "score": 1}, {"t": 15.0, "text": "c", "score": 1}]
    up = {"beats": {"beats": [0.5 * i for i in range(40)], "downbeats": []}, "separate": {},
          "lyrics": {"lines": lines, "source": "x"}}
    r = CHECK.run(ws, up)
    assert [l["ok"] for l in r["lines"]] == [True, True, False, True]
    assert r["rate"] == 0.75
    assert r["lines"][0]["end"] == pytest.approx(5.0, abs=0.06)


def test_no_lines(cfg):
    ws = Workspace(cfg, song())
    audio.write_wav(ws.stems / "vocals.wav", np.zeros((44100, 2), np.float32))
    audio.write_wav(ws.stems / "drums.wav", np.zeros((44100, 2), np.float32))
    r = CHECK.run(ws, {"beats": {"beats": [0.5, 1.0], "downbeats": []}, "separate": {},
                       "lyrics": {"lines": [], "source": "aucune"}})
    assert r["rate"] is None and r["lines"] == []
