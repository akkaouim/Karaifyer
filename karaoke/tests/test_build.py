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
    assert [c.get("Time") for c in acc] == ["0", "28"]            # song 2 at (10 s + 4 s gap) × 2 beats
    assert [l.find("Name").get("Value") for l in ls.findall("Locators/Locators/Locator")] == [
        "001 Titre 001 & co", "002 Titre 002 & co"]
    assert len(arranger_events(track(ls, "Back Vocals"))) == 2
    assert len(arranger_events(track(ls, "Vidéo"))) == 2 and len(arranger_events(track(ls, "XR18 faders"))) == 2
    assert r["songs"] == 2 and r["duration_s"] == pytest.approx(20.0, abs=0.1)
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
    assert sorted(p.name for p in cfg.sets.glob("*.als")) == ["apero.als", "diner.als"]
    ls = load_als(cfg.sets / "apero.als").getroot().find("LiveSet")
    assert [l.find("Name").get("Value")[:3] for l in ls.findall("Locators/Locators/Locator")] == ["001", "003"]


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
