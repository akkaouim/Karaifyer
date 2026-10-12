from pathlib import Path
import gzip
import pytest
from karaoke.ableton.als import (load_als, save_als, track, arranger_events, snippet,
                                 controller_target_id, TRACKS)

FIX = Path(__file__).parent / "fixtures" / "ableton"


def test_load_and_tracks():
    ls = load_als(FIX / "gabarit.als").getroot().find("LiveSet")
    # tracks are found by name; Michel may order them as he likes
    names = {t.find("Name/EffectiveName").get("Value") for t in ls.find("Tracks")}
    assert set(TRACKS.values()) <= names and "Auto stop" in names     # Michel's template (2026-10-13)
    assert len(arranger_events(track(ls, "Accompagnement"))) == 0
    assert arranger_events(track(ls, "XR18 faders")).tag == "Events"
    with pytest.raises(KeyError, match="Accompagnement"):
        track(ls, "Inconnue")


def test_controller_ids_match_reference():
    # Michel's reference clip drew CC 11 and CC 16: its PointeeIds must be ControllerTargets.13 / .18
    ls = load_als(FIX / "reference.als").getroot().find("LiveSet")
    mt = track(ls, "XR18 faders")
    clip_ids = [e.get("Value") for e in mt.iter("PointeeId")][-2:]
    assert clip_ids == [controller_target_id(mt, 11), controller_target_id(mt, 16)]


def test_save_roundtrip(tmp_path):
    tree = load_als(FIX / "gabarit.als")
    save_als(tree, tmp_path / "x.als")
    raw = gzip.open(tmp_path / "x.als").read()
    assert raw.startswith(b'<?xml version="1.0" encoding="UTF-8"?>')
    root = load_als(tmp_path / "x.als").getroot()
    assert root.get("Creator") == "Ableton Live 12.4.6" and root.get("MinorVersion") == "12.0_12402"


def test_snippets_are_fresh_copies():
    a, b = snippet("audioclip"), snippet("audioclip")
    a.set("Time", "99")
    assert b.get("Time") == "0" and snippet("midiclip").tag == "MidiClip" and snippet("locator").tag == "Locator"
