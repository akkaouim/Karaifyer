import json
from karaoke.barfix import EMPTY, apply_fix, beats_in_bar, load

BEATS = [0.5 * i for i in range(32)]
DOWN = BEATS[::4]


def fix(**kw):
    return {**EMPTY, **kw}


def test_no_fix_keeps_the_detection():
    assert apply_fix(BEATS, DOWN, EMPTY, 4, 100.0) == (DOWN, 4)


def test_a_pin_restarts_the_count_from_there():
    lines, n = apply_fix(BEATS, DOWN, fix(pins=[9.1]), 4, 100.0)     # snaps to beat 18 (9.0)
    assert n == 4 and lines == [0.0, 2.0, 4.0, 6.0, 8.0, 9.0, 11.0, 13.0, 15.0]


def test_signature_regroups_from_the_first_line():
    lines, n = apply_fix(BEATS, DOWN, fix(signature="3/4"), 4, 100.0)
    assert n == 3 and lines == BEATS[::3]


def test_compound_meters_follow_the_tempo():
    assert beats_in_bar("6/8", 4, 100.0) == 2 and beats_in_bar("6/8", 4, 140.0) == 6
    assert beats_in_bar("12/8", 4, 120.0) == 4 and beats_in_bar("12/8", 4, 121.0) == 12
    assert beats_in_bar(None, 3, 100.0) == 3 and beats_in_bar("2/4", 4, 100.0) == 2


def test_an_early_pin_replaces_the_implicit_anchor():
    lines, n = apply_fix(BEATS, DOWN[1:], fix(signature="4/4", pins=[1.5]), 4, 100.0)  # first line 2.0, pin 1.5
    assert lines[:3] == [1.5, 3.5, 5.5]


def test_pins_dedupe_and_clamp():
    lines, _ = apply_fix(BEATS, DOWN, fix(pins=[9.0, 9.1, 8.9, 99.0, -3.0]), 4, 100.0)
    assert lines == sorted(set(lines)) and lines[0] == 0.0 and lines[-1] <= BEATS[-1]


def test_load_missing_and_partial_files(tmp_path):
    assert load(tmp_path / "none.json") == EMPTY
    p = tmp_path / "x.json"
    p.write_text(json.dumps({"pins": [3.0]}))
    assert load(p) == {"signature": None, "swing": False, "pins": [3.0], "locks": []}
    p.write_text("not json")
    assert load(p) == EMPTY


IRREGULAR = [BEATS[i] for i in (0, 4, 8, 13, 14, 18, 22, 26)]   # a 5-beat bar then a 1-beat bar


def test_a_lock_alone_changes_nothing():
    lines, n = apply_fix(BEATS, IRREGULAR, fix(locks=[BEATS[13]]), 4, 100.0)
    assert n == 4 and lines == IRREGULAR


def test_a_moved_bar_recounts_only_until_the_next_lock():
    lines, _ = apply_fix(BEATS, IRREGULAR, fix(pins=[BEATS[2]], locks=[BEATS[14]]), 4, 100.0)
    assert lines == [BEATS[i] for i in (0, 2, 6, 10, 14, 18, 22, 26)]


def test_a_pin_and_a_lock_on_the_same_beat_count_as_the_pin():
    lines, _ = apply_fix(BEATS, IRREGULAR, fix(pins=[BEATS[13]], locks=[BEATS[13]]), 4, 100.0)
    assert lines == [BEATS[i] for i in (0, 4, 8, 13, 17, 21, 25, 29)]


def test_load_reads_locks_and_defaults_them():
    import tempfile, pathlib
    p = pathlib.Path(tempfile.mkdtemp()) / "x.json"
    p.write_text(json.dumps({"pins": [3.0], "locks": [6.5, "x"]}))
    assert load(p)["locks"] == [6.5]
    p.write_text(json.dumps({"pins": [3.0]}))
    assert load(p)["locks"] == []
