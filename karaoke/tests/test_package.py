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
    audio.write_wav(ws.stems / "lead.wav", tone(10.0, freq=800, amp=0.1))
    audio.write_wav(ws.stems / "backing.wav", tone(10.0, freq=900, amp=0.1))
    beats = [0.5 + 0.5 * i for i in range(19)]
    up = {"ingest": {"offset_s": 0.0, "duration_s": 10.0}, "separate": {}, "vocals_split": {},
          "beats": {"beats": beats, "downbeats": beats[::4]}}
    return ws, up, n


def test_all_files_same_length_and_zero(cfg):
    ws, up, n = setup(cfg)
    r = PACKAGE.run(ws, up)
    pad = int(round(r["pad_s"] * 44100))
    assert r["pad_s"] == pytest.approx(3.5, abs=1e-4)
    files = (["accompagnement.flac", "clic.flac", "guide_voix.flac", "guitare.flac", "basse.flac", "piano.flac",
              "batterie.flac", "back_vocals.flac"] + [f"pistes/{s}.flac" for s in STEM_NAMES])
    for f in files:
        info = sf.info(str(ws.out / f))
        assert info.frames == pad + n and info.samplerate == 44100 and info.subtype == "PCM_24", f
    assert sf.info(str(ws.out / "clic.flac")).channels == 1
    acc, _ = audio.read(ws.out / "accompagnement.flac")
    assert np.abs(acc[:pad - 10]).max() == 0.0                # silent count-in
    assert sorted(p.name for p in PACKAGE.artifacts(ws)) == sorted(
        ["accompagnement.flac", "clic.flac", "guide_voix.flac", "temps.csv", "guitare.flac", "basse.flac",
         "piano.flac", "batterie.flac", "back_vocals.flac"] + [f"{s}.flac" for s in STEM_NAMES])


def test_accompaniment_excludes_all_routed_parts(cfg):
    ws, up, _ = setup(cfg, retirer=("guitar",))
    r = PACKAGE.run(ws, up)
    acc, _ = audio.read(ws.out / "accompagnement.flac")
    spec = np.abs(np.fft.rfft(acc[200000:244100, 0]))
    freqs = np.fft.rfftfreq(44100, 1 / 44100)
    def level(f):
        return spec[np.argmin(np.abs(freqs - f))]
    # stems: vocals 200, drums 300, bass 400, guitar 500, piano 600, other 700 Hz
    assert level(700) > 100 * max(level(200), level(300), level(400), level(500), level(600))
    for f in ("guitare", "basse", "piano", "batterie", "guide_voix", "back_vocals"):
        assert sf.info(str(ws.out / f"{f}.flac")).channels == 1, f
    assert r["faders"] == {"guitare": 0, "basse": 95, "piano": 95, "batterie": 95, "back_vocals": 95,
                           "accompagnement": 95}
    assert r["live"] == ["guitare"]


def test_guide_is_lead_and_back_vocals_is_backing(cfg):
    ws, up, _ = setup(cfg)
    PACKAGE.run(ws, up)
    def peak_freq(f):
        x, _ = audio.read(ws.out / f)
        spec = np.abs(np.fft.rfft(x[200000:244100, 0]))
        return np.fft.rfftfreq(44100, 1 / 44100)[np.argmax(spec)]
    assert peak_freq("guide_voix.flac") == pytest.approx(800, abs=2)
    assert peak_freq("back_vocals.flac") == pytest.approx(900, abs=2)


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


def test_retirer_other_starts_accompaniment_at_zero(cfg):
    # review #1: Michel plays keys live; synths/strings sit in `other` → accompaniment fader down
    ws, up, _ = setup(cfg, retirer=("guitar", "other"))
    r = PACKAGE.run(ws, up)
    assert r["faders"]["accompagnement"] == 0 and r["faders"]["guitare"] == 0
    assert r["live"] == ["guitare", "accompagnement"]
