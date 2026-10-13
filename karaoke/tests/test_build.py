from pathlib import Path
import subprocess
import numpy as np
import pytest
from karaoke import audio
from karaoke.ableton.als import load_als, track, arranger_events
from karaoke.ableton.build import SongEntry, SetError, build_set

FIX = Path(__file__).parent / "fixtures" / "ableton"
FILES = ["accompagnement", "clic", "guide_voix", "guitare", "basse", "piano", "batterie", "back_vocals"]


def make_song(root: Path, sid: str, seconds: float) -> SongEntry:
    folder = root / "sortie" / f"{sid}_x"
    for f in FILES:
        audio.write_flac(folder / f"{f}.flac", np.zeros((int(seconds * 44100), 2 if f == "accompagnement" else 1), np.float32))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=black:s=320x180:d={seconds}",
                    "-c:v", "libx264", str(folder / "paroles.mp4")], check=True)
    return SongEntry(sid, f"Titre {sid} & co", folder,
                     {"guitare": 0, "basse": 95, "piano": 95, "batterie": 95, "back_vocals": 95, "accompagnement": 95})


def test_two_songs_layout(tmp_path):
    songs = [make_song(tmp_path, "001", 10.0), make_song(tmp_path, "002", 6.0)]
    out = tmp_path / "sets" / "A.als"
    r = build_set(FIX / "gabarit.als", songs, out)
    ls = load_als(out).getroot().find("LiveSet")
    acc = arranger_events(track(ls, "Accompagnement"))
    # each song: one silent bar (2 s) first, then the song; song 2 at (2 + 10 + 4 + 2) s × 2 beats
    assert [c.get("Time") for c in acc] == ["4", "36"]
    assert [l.find("Name").get("Value") for l in ls.findall("Locators/Locators/Locator")] == [
        "001 Titre 001 & co", "002 Titre 002 & co"]
    assert len(arranger_events(track(ls, "Back Vocals"))) == 2
    assert len(arranger_events(track(ls, "Vidéo"))) == 2 and len(arranger_events(track(ls, "XR18 faders"))) == 2
    assert r["songs"] == 2 and r["duration_s"] == pytest.approx(24.0, abs=0.1)
    path = acc[1].find("SampleRef/FileRef/RelativePath").get("Value")
    assert path == "../sortie/002_x/accompagnement.flac"


def test_template_untouched_and_rebuild_is_clean(tmp_path):
    before = (FIX / "gabarit.als").read_bytes()
    songs = [make_song(tmp_path, "001", 4.0)]
    out = tmp_path / "sets" / "A.als"
    build_set(FIX / "gabarit.als", songs, out)
    build_set(FIX / "gabarit.als", songs, out)
    ls = load_als(out).getroot().find("LiveSet")
    assert len(arranger_events(track(ls, "Accompagnement"))) == 1
    assert (FIX / "gabarit.als").read_bytes() == before


def test_missing_file_is_refused(tmp_path):
    s = make_song(tmp_path, "001", 4.0)
    (s.folder / "guitare.flac").unlink()
    with pytest.raises(SetError, match="001.*guitare.flac"):
        build_set(FIX / "gabarit.als", [s], tmp_path / "sets" / "A.als")


def test_clip_ids_unique_per_track(tmp_path):
    # Review focus 5: Live numbers the clips of an arrangement list; duplicates must not appear
    songs = [make_song(tmp_path, f"00{i}", 2.0) for i in range(1, 4)]
    out = tmp_path / "sets" / "A.als"
    build_set(FIX / "gabarit.als", songs, out)
    ls = load_als(out).getroot().find("LiveSet")
    for name in ("Accompagnement", "Vidéo", "XR18 faders", "Back Vocals"):
        assert [c.get("Id") for c in arranger_events(track(ls, name))] == ["0", "1", "2"], name


def test_cli_sets_writes_one_set_per_partie(tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.config import Config
    from karaoke.manifest import write_manifest
    from karaoke.workspace import Workspace
    from test_manifest import song
    import shutil
    home = tmp_path / "home"
    monkeypatch.setenv("KARAOKE_HOME", str(home))
    monkeypatch.setenv("KARAOKE_GABARIT", str(FIX / "gabarit.als"))
    cfg = Config.load()
    cfg.ensure_dirs()
    songs = [song(id="001", partie="Apéro"), song(id="002", partie="Dîner"), song(id="003", partie="Apéro")]
    write_manifest(cfg.manifest, songs)
    for s in songs:
        ws = Workspace(cfg, s)
        src = make_song(tmp_path / "src" / s.id, s.id, 4.0)
        shutil.copytree(src.folder, ws.out)
        ws.write_marker("package", {"key": "k", "output_hash": "h", "seconds": 1,
                                    "result": {"faders": src.faders, "pad_s": 0.0, "total_s": 4.0}})
    r = CliRunner().invoke(cli.app, ["sets"])
    assert r.exit_code == 0, r.output
    # Michel: one set per song, grouped in a folder per part of the evening
    names = sorted(str(p.relative_to(cfg.sets)) for p in cfg.sets.rglob("*.als"))
    assert names == ["apero/001_zazie_je-suis-un-homme.als", "apero/003_zazie_je-suis-un-homme.als",
                     "diner/002_zazie_je-suis-un-homme.als"]
    ls = load_als(cfg.sets / "apero" / "003_zazie_je-suis-un-homme.als").getroot().find("LiveSet")
    assert [l.find("Name").get("Value")[:3] for l in ls.findall("Locators/Locators/Locator")] == ["003"]


def test_cli_sets_refuses_unprocessed_song(tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.config import Config
    from karaoke.manifest import write_manifest
    from test_manifest import song
    monkeypatch.setenv("KARAOKE_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("KARAOKE_GABARIT", str(FIX / "gabarit.als"))
    cfg = Config.load()
    cfg.ensure_dirs()
    write_manifest(cfg.manifest, [song(id="001", partie="A")])
    r = CliRunner().invoke(cli.app, ["sets"])
    assert r.exit_code == 1 and "pas encore traité" in r.output


def template_with_auto_stop(tmp_path) -> Path:
    """Michel's template already has the « Auto stop » MIDI track (since 2026-10-13)."""
    return FIX / "gabarit.als"


def template_without_auto_stop(tmp_path) -> Path:
    from karaoke.ableton.als import save_als
    tree = load_als(FIX / "gabarit.als")
    tracks = tree.getroot().find("LiveSet/Tracks")
    tracks.remove(track(tree.getroot().find("LiveSet"), "Auto stop"))
    out = tmp_path / "gabarit_sans_auto_stop.als"
    save_als(tree, out)
    return out


def test_auto_stop_clip_at_song_end(tmp_path):
    from karaoke.ableton.als import controller_target_id
    s = make_song(tmp_path, "001", 10.0)
    out = tmp_path / "sets" / "001.als"
    r = build_set(template_with_auto_stop(tmp_path), [s], out)
    ls = load_als(out).getroot().find("LiveSet")
    stop_track = track(ls, "Auto stop")
    [clip] = list(arranger_events(stop_track))
    assert clip.get("Time") == "25"                                     # (2 s lead-in + 10 s + 0.5 s) × 2 beats
    [env] = clip.findall("Envelopes/Envelopes/ClipEnvelope")
    assert env.find("EnvelopeTarget/PointeeId").get("Value") == controller_target_id(stop_track, 119)
    assert [e.get("Value") for e in env.findall("Automation/Events/FloatEvent")] == ["127", "127"]
    assert r["warnings"] == []


def test_missing_auto_stop_track_only_warns(tmp_path):
    r = build_set(template_without_auto_stop(tmp_path), [make_song(tmp_path, "001", 4.0)], tmp_path / "sets" / "001.als")
    assert any("Auto stop" in w for w in r["warnings"])


def test_cli_apprendre_stop_sends_cc119_on_iac(monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    seen = {}
    def fake_tool(tool, args, **kw):
        seen.update(tool=tool, args=args)
    monkeypatch.setattr(cli, "run_tool", fake_tool)
    r = CliRunner().invoke(cli.app, ["apprendre-stop"])
    assert r.exit_code == 0, r.output
    assert seen["tool"] == "midi" and "--cc" in seen["args"] and seen["args"][seen["args"].index("--cc") + 1] == "119"
    assert "Stop" in r.output


def test_generated_set_starts_at_zero_and_keeps_stop_mapping(tmp_path):
    # Michel saved the template with the playhead at beat 103: generated sets must open at 0.
    out = tmp_path / "sets" / "001.als"
    r = build_set(FIX / "gabarit.als", [make_song(tmp_path, "001", 4.0)], out)
    ls = load_als(out).getroot().find("LiveSet")
    assert ls.find("Transport/CurrentTime").get("Value") == "0"
    assert ls.find("Transport/StopKeyMidi/NoteOrController").get("Value") == "119"
    assert r["warnings"] == []                                     # the template now has « Auto stop »


def test_set_opens_on_bar_one_not_at_the_template_selection(tmp_path):
    # Michel's template stores an arrangement selection at beat 84: Live opened every set there
    out = tmp_path / "sets" / "001.als"
    build_set(FIX / "gabarit.als", [make_song(tmp_path, "001", 4.0)], out)
    ls = load_als(out).getroot().find("LiveSet")
    assert ls.find("TimeSelection/AnchorTime").get("Value") == "0"
    assert ls.find("TimeSelection/OtherTime").get("Value") == "0"
    assert ls.find("Transport/CurrentTime").get("Value") == "0"


def test_faders_in_a_silent_first_bar_song_and_locator_on_bar_two(tmp_path):
    # Play from bar 1: faders, then the click; back to the locator (bar 2): click again, faders not resent
    out = tmp_path / "sets" / "001.als"
    build_set(FIX / "gabarit.als", [make_song(tmp_path, "001", 6.0)], out)
    ls = load_als(out).getroot().find("LiveSet")
    [fader] = arranger_events(track(ls, "XR18 faders"))
    assert float(fader.get("Time")) == 0 and float(fader.find("CurrentEnd").get("Value")) <= 4
    for name in ["Accompagnement", "Clic", "Guide Voix", "Vidéo"]:
        assert [c.get("Time") for c in arranger_events(track(ls, name))] == ["4"], name
    [loc] = ls.findall("Locators/Locators/Locator")
    assert loc.find("Time").get("Value") == "4"
