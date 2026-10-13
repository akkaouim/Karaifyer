import pytest
from karaoke.chords import symbol, chords_per_beat, merge_blips, bars_from, chart_text, changes

BEATS = [0.5 * i for i in range(16)]                 # 4 bars of 4/4 at 120 BPM
DOWN = BEATS[::4]


def test_symbol():
    assert symbol("C#:min") == "C#m" and symbol("A:maj") == "A" and symbol("N") == "N.C."
    assert symbol("A#:maj") == "Bb" and symbol("D#:min") == "Ebm"      # flats read better on charts


def test_chords_per_beat_uses_beat_centre():
    segs = [[0.0, 2.1, "C:maj"], [2.1, 4.0, "A:min"], [4.0, 8.0, "F:maj"]]
    labels = chords_per_beat(segs, BEATS)
    assert labels[:4] == ["C", "C", "C", "C"] and labels[4:8] == ["Am"] * 4 and labels[8] == "F"


def test_merge_blips_removes_one_beat_flickers():
    assert merge_blips(["C", "C", "G", "C", "C", "Am", "Am"]) == ["C", "C", "C", "C", "C", "Am", "Am"]


def test_bars_and_chart():
    labels = ["C"] * 4 + ["Am", "Am", "F", "F"] + ["G"] * 4 + ["C"] * 4
    bars = bars_from(BEATS, DOWN, labels, 4)
    assert [b["chords"] for b in bars] == [[[0, "C"]], [[0, "Am"], [2, "F"]], [[0, "G"]], [[0, "C"]]]
    assert chart_text(bars, 4, per_line=4) == "| C | Am F | G | C |"


def test_changes_list():
    labels = ["C", "C", "Am", "Am"]
    assert changes(BEATS[:4], labels) == [{"t": 0.0, "label": "C"}, {"t": 1.0, "label": "Am"}]


def test_step_mixes_harmony_and_writes_chart(cfg, monkeypatch):
    import json
    from pathlib import Path
    from karaoke import audio
    from karaoke.steps import chords as C
    from karaoke.workspace import Workspace
    from conftest import tone
    from test_manifest import song
    ws = Workspace(cfg, song())
    for s in ("bass", "guitar", "piano", "other", "drums"):
        audio.write_wav(ws.stems / f"{s}.wav", tone(8.0))
    seen = {}
    def fake_tool(tool, args, **kw):
        seen.update(tool=tool, args=args, **kw)
        Path(args[-1]).write_text(json.dumps({"key": "C major", "segments": [
            [0.0, 2.0, "C:maj"], [2.0, 3.0, "A:min"], [3.0, 4.0, "F:maj"], [4.0, 8.0, "G:maj"]]}))
    monkeypatch.setattr(C, "run_tool", fake_tool)
    up = {"ingest": {"duration_s": 8.0}, "separate": {}, "beats": {"beats": BEATS, "downbeats": DOWN}}
    r = C.CHORDS.run(ws, up)
    assert seen["tool"] == "chords" and Path(seen["args"][-2]) == ws.work / "harmonie.wav"
    assert (ws.work / "harmonie.wav").exists()
    assert r["key"] == "C major" and r["beats_per_bar"] == 4 and round(r["bpm"]) == 120
    assert [b["chords"] for b in r["bars"]] == [[[0, "C"]], [[0, "Am"], [2, "F"]], [[0, "G"]], [[0, "G"]]]
    assert r["changes"][1] == {"t": 2.0, "label": "Am"}
    text = (ws.out / "accords.txt").read_text()
    assert "| C | Am F | G | G |" in text and "C major" in text
    assert [p.name for p in C.CHORDS.artifacts(ws)] == ["accords.txt"]


def test_spell_follows_key():
    from karaoke.chords import spell
    assert spell(["C#", "Bbm", "Ab", "N.C."], "Db major") == ["Db", "Bbm", "Ab", "N.C."]
    assert spell(["C#m", "Ebm", "G#"], "B major") == ["C#m", "D#m", "G#"]
    assert spell(["C#m", "Bb", "Eb", "F#"], "C major") == ["C#m", "Bb", "Eb", "F#"]   # neutral: default
    assert spell(["F#m", "Gbm"], "Eb minor") == ["Gbm", "Gbm"]


def test_step_spells_chords_in_key(cfg, monkeypatch):
    import json
    from pathlib import Path
    from karaoke import audio
    from karaoke.steps import chords as C
    from karaoke.workspace import Workspace
    from conftest import tone
    from test_manifest import song
    ws = Workspace(cfg, song())
    for s in C.HARMONIC:
        audio.write_wav(ws.stems / f"{s}.wav", tone(8.0))
    monkeypatch.setattr(C, "run_tool", lambda tool, args, **kw: Path(args[-1]).write_text(
        json.dumps({"key": "Db major", "segments": [[0.0, 8.0, "C#:maj"]]})))
    r = C.CHORDS.run(ws, {"ingest": {"duration_s": 8.0}, "separate": {},
                          "beats": {"beats": BEATS, "downbeats": DOWN}})
    assert r["changes"] == [{"t": 0.0, "label": "Db"}] and r["bars"][0]["chords"] == [[0, "Db"]]
