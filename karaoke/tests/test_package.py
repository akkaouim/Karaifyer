import csv
import numpy as np
import pytest
import soundfile as sf
from karaoke import audio
from karaoke.steps.package import PACKAGE
from karaoke.workspace import Workspace
from conftest import tone
from test_manifest import song

STEM_NAMES = ["vocals", "drums", "bass", "guitar", "piano", "other"]


def setup(cfg, retirer=("guitar",), decompte=2):
    ws = Workspace(cfg, song(retirer=retirer, decompte_mesures=decompte))
    n = 10 * 44100
    audio.write_wav(ws.work / "input.wav", tone(10.0))
    for i, stem in enumerate(STEM_NAMES):
        audio.write_wav(ws.stems / f"{stem}.wav", tone(10.0, freq=200 + 100 * i, amp=0.1))
    beats = [0.5 + 0.5 * i for i in range(19)]
    up = {"ingest": {"offset_s": 0.0, "duration_s": 10.0}, "separate": {},
          "beats": {"beats": beats, "downbeats": beats[::4]}}
    return ws, up, n


def test_all_files_same_length_and_zero(cfg):
    ws, up, n = setup(cfg)
    r = PACKAGE.run(ws, up)
    pad = int(round(r["pad_s"] * 44100))
    assert r["pad_s"] == pytest.approx(3.5, abs=1e-4)
    files = ["accompagnement.flac", "clic.flac", "guide_voix.flac"] + [f"pistes/{s}.flac" for s in STEM_NAMES]
    for f in files:
        info = sf.info(str(ws.out / f))
        assert info.frames == pad + n and info.samplerate == 44100 and info.subtype == "PCM_24", f
    assert sf.info(str(ws.out / "clic.flac")).channels == 1
    acc, _ = audio.read(ws.out / "accompagnement.flac")
    assert np.abs(acc[:pad - 10]).max() == 0.0                # silent count-in
    assert sorted(p.name for p in PACKAGE.artifacts(ws)) == sorted(
        ["accompagnement.flac", "clic.flac", "guide_voix.flac", "temps.csv"] + [f"{s}.flac" for s in STEM_NAMES])


def test_retirer_changes_accompaniment(cfg):
    ws, up, _ = setup(cfg, retirer=("guitar", "bass"))
    r = PACKAGE.run(ws, up)
    assert r["removed"] == ["bass", "guitar", "vocals"]
    acc, _ = audio.read(ws.out / "accompagnement.flac")
    spec = np.abs(np.fft.rfft(acc[200000:244100, 0]))
    freqs = np.fft.rfftfreq(44100, 1 / 44100)
    def level(f):
        return spec[np.argmin(np.abs(freqs - f))]
    assert level(300) > 100 * level(200)          # drums kept, vocals removed
    assert level(400) < level(300) / 100          # bass removed


def test_temps_csv(cfg):
    ws, up, _ = setup(cfg)
    PACKAGE.run(ws, up)
    rows = list(csv.DictReader(open(ws.out / "temps.csv", encoding="utf-8")))
    assert rows[0] == {"temps_s": "0.000000", "premier_temps": "1", "source": "decompte"}
    assert sum(r["source"] == "decompte" for r in rows) == 8
    first_detected = next(r for r in rows if r["source"] == "detecte")
    assert float(first_detected["temps_s"]) == pytest.approx(4.0, abs=1e-4)


def test_key_depends_on_retirer_and_decompte(cfg):
    a = PACKAGE.key(Workspace(cfg, song(retirer=("bass",), decompte_mesures=2)))
    b = PACKAGE.key(Workspace(cfg, song(retirer=("guitar",), decompte_mesures=2)))
    c = PACKAGE.key(Workspace(cfg, song(retirer=("bass",), decompte_mesures=1)))
    assert len({a, b, c}) == 3
