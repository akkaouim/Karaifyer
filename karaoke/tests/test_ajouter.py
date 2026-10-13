import json
from pathlib import Path
import soundfile as sf
from karaoke.manifest import next_id, read_manifest, songs_from_files, write_manifest
from conftest import tone
from test_manifest import song


def flac(path: Path, title=None, artist=None) -> Path:
    sf.write(str(path), tone(1.0), 44100, format="FLAC")
    if title:
        from mutagen.flac import FLAC
        f = FLAC(path); f["title"] = title; f["artist"] = artist or ""; f.save()
    return path


def test_next_id():
    assert next_id([]) == "001"
    assert next_id([song(id="007"), song(id="041")]) == "042"


def test_songs_from_files_reads_tags_falls_back_to_name_and_skips_duplicates(tmp_path):
    a = flac(tmp_path / "a.flac", "Danser", "Loïc Nottet")
    b = flac(tmp_path / "Ma chanson - live.flac")
    existing = [song(id="041", fichier=a)]
    added, skipped = songs_from_files([a, b, tmp_path / "absent.flac"], existing)
    assert [(s.id, s.titre, s.artiste) for s in added] == [("042", "Ma chanson - live", "")]
    assert abs(added[0].duree_ref_s - 1.0) < 0.05 and added[0].fichier == b.resolve()
    assert len(skipped) == 2 and "déjà" in skipped[0] and "introuvable" in skipped[1]


def test_ajouter_cli_appends_rows(cfg, tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song(id="005")])
    r = CliRunner().invoke(cli.app, ["ajouter", str(flac(tmp_path / "x.flac", "Speed", "Zazie"))])
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ajoutes"] == [{"id": "006", "titre": "Speed", "artiste": "Zazie"}]
    assert [s.id for s in read_manifest(cfg.manifest)] == ["005", "006"]
