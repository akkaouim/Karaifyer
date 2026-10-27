import json
import unicodedata
from pathlib import Path
import numpy as np
import soundfile as sf
from mutagen.flac import FLAC
from karaoke import relocaliser as RL
from karaoke.manifest import read_manifest, write_manifest
from test_manifest import song


def flac(path: Path, spotify: str = "", title="", artist="") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.zeros((4410, 2), dtype=np.float32), 44100, format="FLAC")
    f = FLAC(path)
    if spotify: f["SPOTIFY_URI"] = f"spotify:track:{spotify}"
    if title: f["title"] = title
    if artist: f["artist"] = artist
    f.save()
    return path


def test_moves_update_every_row_using_the_file_with_a_backup(cfg, tmp_path):
    old = flac(tmp_path / "rec" / "05 - Danser - Loïc Nottet.flac")
    nfd = Path(unicodedata.normalize("NFD", str(old)))
    write_manifest(cfg.manifest, [song(id="005", fichier=old), song(id="050", fichier=nfd),
                                  song(id="011", fichier=tmp_path / "other.flac")])
    new = tmp_path / "rec2" / "Danser - Loïc Nottet.flac"
    new.parent.mkdir(); old.rename(new)
    r = RL.relocaliser(cfg, {str(old): str(new)})
    assert r["modifies"] == ["005", "050"] and Path(r["sauvegarde"]).exists()
    by = {s.id: s for s in read_manifest(cfg.manifest)}
    assert by["005"].fichier == new and by["050"].fichier == new and by["011"].fichier == tmp_path / "other.flac"


def test_no_matching_row_changes_nothing_and_makes_no_backup(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(id="011", fichier=tmp_path / "x.flac")])
    assert RL.relocaliser(cfg, {"/a.flac": "/b.flac"}) == {"modifies": [], "sauvegarde": None}


def test_retrouver_by_spotify_id_then_by_name(cfg, tmp_path):
    d = tmp_path / "Nouveau"
    flac(d / "Danser - Loïc Nottet.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")
    flac(d / "Speed - Zazie.flac")
    write_manifest(cfg.manifest, [
        song(id="050", titre="Danser", artiste="Loïc Nottet", fichier=tmp_path / "gone/05 - Danser.flac",
             spotify="2j7g2ug1llC7e5F1Qzxw57"),
        song(id="056", titre="Speed", artiste="Zazie", fichier=tmp_path / "gone/56 - Speed - Zazie.flac"),
        song(id="099", titre="Absent", artiste="X", fichier=tmp_path / "gone/99.flac")])
    found = RL.retrouver(cfg, d, appliquer=False)
    assert {(f["id"], f["par"]) for f in found} == {("050", "spotify"), ("056", "nom")}
    assert read_manifest(cfg.manifest)[0].fichier == tmp_path / "gone/05 - Danser.flac"     # plan only
    RL.retrouver(cfg, d, appliquer=True)
    assert read_manifest(cfg.manifest)[0].fichier == d / "Danser - Loïc Nottet.flac"


def test_retrouver_ignores_rows_whose_file_exists(cfg, tmp_path):
    here = flac(tmp_path / "a.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")
    flac(tmp_path / "d" / "copy.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")
    write_manifest(cfg.manifest, [song(id="050", fichier=here, spotify="2j7g2ug1llC7e5F1Qzxw57")])
    assert RL.retrouver(cfg, tmp_path / "d", appliquer=False) == []


def test_cli_relocaliser_reads_moves_on_stdin(cfg, tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke.cli import app
    old = flac(tmp_path / "a.flac")
    write_manifest(cfg.manifest, [song(id="005", fichier=old)])
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    r = CliRunner().invoke(app, ["relocaliser", "--json"], input=json.dumps({str(old): str(tmp_path / "b.flac")}))
    assert r.exit_code == 0 and json.loads(r.stdout)["modifies"] == ["005"]


def test_cli_retrouver_plan_and_apply(cfg, tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke.cli import app
    d = tmp_path / "N"
    flac(d / "Danser - Loïc Nottet.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")
    write_manifest(cfg.manifest, [song(id="050", fichier=tmp_path / "gone.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")])
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    r = CliRunner().invoke(app, ["retrouver", "--dossier", str(d), "--plan", "--json"])
    assert r.exit_code == 0 and json.loads(r.stdout)[0]["id"] == "050"
    assert read_manifest(cfg.manifest)[0].fichier == tmp_path / "gone.flac"
    r = CliRunner().invoke(app, ["retrouver", "--dossier", str(d), "--json"])
    assert r.exit_code == 0 and read_manifest(cfg.manifest)[0].fichier == d / "Danser - Loïc Nottet.flac"


def test_moved_song_keeps_its_analysis(cfg, tmp_path):
    import hashlib
    from karaoke.runner import inspect_song
    from karaoke.steps import STEPS, ingest
    from karaoke.workspace import Workspace
    old = flac(tmp_path / "rec" / "05 - Danser.flac")
    s = song(id="005", fichier=old)
    write_manifest(cfg.manifest, [s])
    ws = Workspace(cfg, s)
    (ws.work / "input.wav").write_bytes(b"w")
    st = old.stat()
    legacy = hashlib.sha1("|".join(["ingest", ingest.INGEST.version,
                                    f"{old}|{st.st_size}|{st.st_mtime_ns}|{s.duree_ref_s}"]).encode()).hexdigest()
    ws.write_marker("ingest", {"key": legacy, "result": {}, "output_hash": "h"})
    new = tmp_path / "rec2" / "Danser.flac"
    new.parent.mkdir(); old.rename(new)
    RL.relocaliser(cfg, {str(old): str(new)})
    assert inspect_song(Workspace(cfg, read_manifest(cfg.manifest)[0]), STEPS)["ingest"] == "a_jour"
