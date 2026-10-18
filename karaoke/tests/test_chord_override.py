import pytest
from karaoke.chords import cell_text, expand, parse_cell, parse_chart

BEATS = [0.5 * i for i in range(16)]
DOWN = BEATS[::4]


def test_parse_cell_even_and_per_beat():
    assert parse_cell("A", 4) == [[0, "A"]]
    assert parse_cell("A B", 4) == [[0, "A"], [2, "B"]]
    assert parse_cell("Am . . F", 4) == [[0, "Am"], [3, "F"]]
    assert parse_cell("C G Am", 3) == [[0, "C"], [1, "G"], [2, "Am"]]
    assert parse_cell("Cmaj7 F#m7b5/E", 4) == [[0, "Cmaj7"], [2, "F#m7b5/E"]]
    assert parse_cell("N.C.", 4) == [[0, "N.C."]]
    for bad in ["", "H", "A . B", ". A . .", "A B C D E"]:
        with pytest.raises(ValueError):
            parse_cell(bad, 4)


def test_cell_text_is_inverse_of_parse_cell():
    for c in ["A", "A B", "Am . . F", "C . . G", "N.C."]:
        assert cell_text(parse_cell(c, 4), 4) == c
    assert cell_text(parse_cell("C . G .", 4), 4) == "C G"     # same split, canonical form


def test_parse_chart_and_expand():
    text = "Danser — Loïc Nottet\nTonalité : C# minor · 100 BPM · 4/4\n\n| C#m | A | A . . B |\n| N.C. |\n"
    key, cells = parse_chart(text)
    assert key == "C# minor" and cells == ["C#m", "A", "A . . B", "N.C."]
    bars = [{"chords": parse_cell(c, 4)} for c in cells[:2]]
    assert expand(bars, 4) == ["C#m"] * 4 + ["A"] * 4


def _stems(ws, C):
    from karaoke import audio
    from conftest import tone
    for s in C.HARMONIC:
        audio.write_wav(ws.stems / f"{s}.wav", tone(8.0))


def test_step_uses_correction_without_madmom(cfg, monkeypatch):
    from karaoke.steps import chords as C
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    _stems(ws, C)
    monkeypatch.setattr(C, "run_tool", lambda *a, **k: pytest.fail("madmom must not run"))
    (cfg.accords / "001.txt").write_text("x\nTonalité : D major · 120 BPM · 4/4\n\n| D | G A | Bm . . G | D |\n")
    up = {"ingest": {"duration_s": 8.0}, "separate": {}, "beats": {"beats": BEATS, "downbeats": DOWN}}
    r = C.CHORDS.run(ws, up)
    assert r["key"] == "D major" and r["source"] == "correction"
    assert [b["chords"] for b in r["bars"]] == [[[0, "D"]], [[0, "G"], [2, "A"]], [[0, "Bm"], [3, "G"]], [[0, "D"]]]
    assert r["changes"][1] == {"t": 2.0, "label": "G"}
    assert "| D | G A | Bm . . G | D |" in (ws.out / "accords.txt").read_text()


def test_step_correction_with_pickup_bar(cfg):
    from karaoke.steps import chords as C
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    _stems(ws, C)
    beats = [0.5 * i for i in range(10)]          # 2-beat pickup, then 2 bars of 4
    (cfg.accords / "001.txt").write_text("| N.C. | C | G |\n")
    up = {"ingest": {"duration_s": 8.0}, "separate": {}, "beats": {"beats": beats, "downbeats": [1.0, 3.0]}}
    r = C.CHORDS.run(ws, up)
    assert r["changes"] == [{"t": 0.0, "label": "N.C."}, {"t": 1.0, "label": "C"}, {"t": 3.0, "label": "G"}]


def test_step_refuses_bar_count_mismatch(cfg):
    from karaoke.steps import chords as C
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    _stems(ws, C)
    (cfg.accords / "001.txt").write_text("| D | G |\n")
    up = {"ingest": {"duration_s": 8.0}, "separate": {}, "beats": {"beats": BEATS, "downbeats": DOWN}}
    with pytest.raises(ValueError, match="2 mesures.*4"):
        C.CHORDS.run(ws, up)


def test_key_follows_correction_file(cfg):
    from karaoke.steps.chords import CHORDS
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    k0 = CHORDS.key(ws)
    (cfg.accords / "001.txt").write_text("| D |\n")
    k1 = CHORDS.key(ws)
    (cfg.accords / "001.txt").write_text("| E |\n")
    assert len({k0, k1, CHORDS.key(ws)}) == 3


def test_correction_follows_fixed_bar_lines(cfg):
    from karaoke.steps.chords import CHORDS
    from karaoke.workspace import Workspace
    from test_manifest import song
    s = song()
    ws = Workspace(cfg, s)
    cfg.accords.mkdir(parents=True, exist_ok=True)
    beats = [0.5 * i for i in range(12)]
    # fixed lines: a 2-beat bar, then 4 + 4 + 2 → 4 bars
    (cfg.accords / f"{s.id}.txt").write_text("Tonalité : C major · 4/4\n\n| C | F | G | C |\n", encoding="utf-8")
    up = {"ingest": {"duration_s": 6.0}, "separate": {},
          "beats": {"beats": beats, "downbeats": [0.0, 1.0, 3.0, 5.0], "beats_per_bar": 4,
                    "signature": "4/4", "swing": False}}
    r = CHORDS.run(ws, up)
    assert len(r["bars"]) == 4 and r["signature"] == "4/4" and r["swing"] is False
    assert "· 4/4" in (ws.out / "accords.txt").read_text(encoding="utf-8")
