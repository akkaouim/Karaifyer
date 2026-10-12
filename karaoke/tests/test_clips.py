from pathlib import Path
import xml.etree.ElementTree as ET
import pytest
from karaoke.ableton.clips import MediaInfo, audio_clip, video_clip, midi_clip, locator
from karaoke.ableton.als import load_als, track, controller_target_id

FIX = Path(__file__).parent / "fixtures" / "ableton"


def ref_clip(track_name):
    ls = load_als(FIX / "reference.als").getroot().find("LiveSet")
    return track(ls, track_name).find(".//ArrangerAutomation/Events/*")


def v(el, path):
    return el.find(path).get("Value")


def test_audio_clip_reproduces_reference_values():
    ref = ref_clip("Accompagnement")
    info = MediaInfo(Path("/Volumes/Hypermnesia/karaoke/sortie/005_loic-nottet_danser/accompagnement.flac"),
                     "../../sortie/005_loic-nottet_danser/accompagnement.flac", 8876810, 8876810 / 44100,
                     32304640, 1791829791)
    c = audio_clip(info, 0.0, "accompagnement", 9)
    for p in ("CurrentStart", "CurrentEnd", "Loop/LoopEnd", "Loop/OutMarker", "Loop/HiddenLoopEnd",
              "SampleRef/DefaultDuration", "SampleRef/LastModDate"):
        assert float(v(c, p)) == pytest.approx(float(v(ref, p)), abs=1e-6), p   # Live rounds differently (~50 ns)
    for p in ("Name", "IsWarped", "SampleRef/FileRef/Path", "SampleRef/FileRef/RelativePath"):
        assert v(c, p) == v(ref, p), p


def test_audio_clip_at_later_position():
    info = MediaInfo(Path("/x/a.flac"), "../a.flac", 441000, 10.0, 1, 1)
    c = audio_clip(info, 60.0, "a", 1)
    assert (c.get("Time"), v(c, "CurrentStart"), v(c, "CurrentEnd")) == ("120", "120", "140")
    assert v(c, "Loop/LoopEnd") == "10"


def test_video_clip_outmarker_in_seconds():
    info = MediaInfo(Path("/x/p.mp4"), "../p.mp4", 8876448, 201.2364625850340, 2765786, 1)
    c = video_clip(info, 0.0, "paroles")
    assert float(v(c, "Loop/OutMarker")) == pytest.approx(201.236462585034)
    assert float(v(c, "CurrentEnd")) == pytest.approx(402.472925170068)


def test_midi_clip_targets_and_values():
    ls = load_als(FIX / "gabarit.als").getroot().find("LiveSet")
    mt = track(ls, "XR18 faders")
    ids = {cc: controller_target_id(mt, cc) for cc in (11, 12, 13, 14, 15, 16)}
    c = midi_clip(10.0, 0.5, {"guitare": 0, "batterie": 95, "accompagnement": 95}, ids,
                  {"guitare": [11], "batterie": [14, 15], "accompagnement": [16]})   # one part on two CCs still works
    envs = c.findall("Envelopes/Envelopes/ClipEnvelope")
    targets = {e.find("EnvelopeTarget/PointeeId").get("Value"):
               [ev.get("Value") for ev in e.findall("Automation/Events/FloatEvent")] for e in envs}
    assert targets == {ids[11]: ["0", "0"], ids[14]: ["95", "95"], ids[15]: ["95", "95"], ids[16]: ["95", "95"]}
    assert (c.get("Time"), v(c, "CurrentEnd")) == ("20", "21")
    assert [e.get("Id") for e in envs] == ["0", "1", "2", "3"]


def test_locator_escapes_names():
    loc = locator(30.0, "082 Il est cinq heures, Paris s'éveille & <co>", 3)
    assert loc.get("Id") == "3" and v(loc, "Time") == "60"
    assert ET.fromstring(ET.tostring(loc)).find("Name").get("Value") == "082 Il est cinq heures, Paris s'éveille & <co>"
