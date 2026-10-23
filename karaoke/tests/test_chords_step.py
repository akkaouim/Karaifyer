import json
from pathlib import Path
import numpy as np


def setup(cfg, monkeypatch, outputs, engine=None, silent=False):
    from karaoke.steps import chords as CH
    from karaoke.workspace import Workspace
    from test_manifest import song
    if engine:
        monkeypatch.setenv("KARAOKE_ACCORDS", engine)
    else:
        monkeypatch.delenv("KARAOKE_ACCORDS", raising=False)
    ws = Workspace(cfg, song())
    ws.work.mkdir(parents=True, exist_ok=True)
    ws.stems.mkdir(parents=True, exist_ok=True)
    sr, n = 44100, 44100 * 4
    tone = np.zeros(n) if silent else 0.3 * np.sin(np.arange(n) / sr * 2 * np.pi * 220)
    from karaoke import audio
    for s in ("bass", "guitar", "piano", "other"):
        audio.write_wav(ws.stems / f"{s}.wav", tone.astype(np.float32), sr)
    audio.write_wav(ws.work / "input.wav", (0.3 * np.sin(np.arange(n) / sr * 2 * np.pi * 220)).astype(np.float32), sr)
    calls = []
    def fake(tool, args, **kw):
        calls.append((tool, Path(args[1]).name, Path(args[2]).name))
        Path(args[3]).write_text(json.dumps(outputs[tool]))
    monkeypatch.setattr(CH, "run_tool", fake)
    beats = [0.5 * i for i in range(8)]
    up = {"ingest": {"duration_s": 4.0}, "separate": {}, "beats": {"beats": beats, "downbeats": beats[::4]}}
    return CH, ws, up, calls


MADMOM = {"segments": [[0, 4, "C:maj"]], "key": "C major"}
DL = {"segments": [[0, 2, "A:maj/6"], [2, 4, "G:7"]], "key": None}


def test_default_engine_is_jiang_and_key_comes_from_madmom(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords_dl": DL, "chords": MADMOM})
    r = CH.CHORDS.run(ws, up)
    assert ("chords_dl", "jiang_tool.py", "harmonie.wav") in calls and r["key"] == "C major"
    assert r["moteur"] == "Jiang 2019" and r["entree"] == "harmonie"
    assert [c for b in r["bars"] for _, c in b["chords"]] == ["F#m7", "G7"]
    assert "accords : Jiang 2019 (harmonie)" in (ws.work / "journal.log").read_text()


def test_engine_in_step_key(cfg, monkeypatch):
    CH, ws, up, _ = setup(cfg, monkeypatch, {}, engine="btc")
    k_btc = CH.CHORDS.key(ws)
    monkeypatch.setenv("KARAOKE_ACCORDS", "ace")
    assert k_btc.startswith("btc|") and CH.CHORDS.key(ws).startswith("ace|")
    monkeypatch.setenv("KARAOKE_ACCORDS", "nonsense")
    assert CH.CHORDS.key(ws).startswith("jiang|")


def test_madmom_engine_runs_one_tool(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords": MADMOM}, engine="madmom")
    r = CH.CHORDS.run(ws, up)
    assert [c[0] for c in calls] == ["chords"] and r["moteur"] == "madmom"


def test_silent_harmonic_stem_falls_back_to_the_mix(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords_dl": DL, "chords": MADMOM}, engine="btc", silent=True)
    r = CH.CHORDS.run(ws, up)
    assert ("chords_dl", "btc_tool.py", "input.wav") in calls and r["entree"] == "mix"


def test_empty_engine_output_is_a_soft_failure(cfg, monkeypatch):
    CH, ws, up, _ = setup(cfg, monkeypatch, {"chords_dl": {"segments": [], "key": None}, "chords": MADMOM}, engine="btc")
    r = CH.CHORDS.run(ws, up)
    assert r["bars"] == [] and "aucun accord" in r["erreur"] and r["moteur"] == "BTC"


def test_correction_wins_over_any_engine(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords_dl": DL, "chords": MADMOM}, engine="ace")
    cfg.accords.mkdir(parents=True, exist_ok=True)
    (cfg.accords / f"{ws.song.id}.txt").write_text("Tonalité : C major · 4/4\n\n| C | G |\n", encoding="utf-8")
    r = CH.CHORDS.run(ws, up)
    assert calls == [] and r["source"] == "correction"
