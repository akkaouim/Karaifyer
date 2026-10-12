import subprocess
from pathlib import Path
import pytest
from karaoke.manifest import (Song, read_manifest, write_manifest, songs_from_sysrec,
                              ManifestError, COLUMNS)
from conftest import write_wav, tone


def song(**kw):
    base = dict(id="001", titre="Je suis un homme", artiste="Zazie", album="Zen", duree_ref_s=249.47,
                isrc="", fichier=Path("/x/01.flac"), retirer=("guitar",), decompte_mesures=2,
                langue="fr", partie="A")
    base.update(kw)
    return Song(**base)


def test_roundtrip(tmp_path):
    p = tmp_path / "m.csv"
    s = [song(), song(id="003", titre="À ma place", artiste="Zazie/Axel Bauer", retirer=("guitar", "bass"))]
    write_manifest(p, s)
    assert p.read_text(encoding="utf-8").splitlines()[0] == ",".join(COLUMNS)
    assert read_manifest(p) == s


def test_unknown_stem_rejected(tmp_path):
    p = tmp_path / "m.csv"
    write_manifest(p, [song()])
    p.write_text(p.read_text(encoding="utf-8").replace("guitar", "guitare"), encoding="utf-8")
    with pytest.raises(ManifestError, match="guitare"):
        read_manifest(p)


def test_bad_id_and_duplicate(tmp_path):
    p = tmp_path / "m.csv"
    write_manifest(p, [song(id="7"), song(id="002"), song(id="002")])
    with pytest.raises(ManifestError) as e:
        read_manifest(p)
    msg = str(e.value)
    assert "3 chiffres" in msg and "doublon" in msg


def test_vocals_cannot_be_kept(tmp_path):
    # vocals are always removed; listing them in retirer is harmless but normalised away
    p = tmp_path / "m.csv"
    write_manifest(p, [song(retirer=("vocals", "bass"))])
    assert read_manifest(p)[0].retirer == ("bass",)


def test_from_sysrec_tags(tmp_path):
    wav = write_wav(tmp_path / "a.wav", tone(3.0))
    flac = tmp_path / "audio" / "14 - Ma liberté de penser - Florent Pagny.flac"
    flac.parent.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-metadata", "title=Ma liberté de penser",
                    "-metadata", "artist=Florent Pagny", "-metadata", "album=Ailleurs Land",
                    "-metadata", "track=14", str(flac)], check=True)
    [s] = songs_from_sysrec(flac.parent)
    assert (s.id, s.titre, s.artiste, s.album) == ("014", "Ma liberté de penser", "Florent Pagny", "Ailleurs Land")
    assert abs(s.duree_ref_s - 3.0) < 0.05
    assert s.fichier == flac and s.decompte_mesures == 2 and s.retirer == ()


def test_cli_manifeste_builds_and_refuses_overwrite(tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke.cli import app
    wav = write_wav(tmp_path / "a.wav", tone(2.0))
    audio_dir = tmp_path / "audio"
    audio_dir.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-metadata", "title=Speed",
                    "-metadata", "artist=Zazie", "-metadata", "track=11", str(audio_dir / "11.flac")], check=True)
    monkeypatch.setenv("KARAOKE_HOME", str(tmp_path / "home"))
    runner = CliRunner()
    r = runner.invoke(app, ["manifeste", "--audio", str(audio_dir)])
    assert r.exit_code == 0, r.output
    assert read_manifest(tmp_path / "home" / "manifeste.csv")[0].id == "011"
    r2 = runner.invoke(app, ["manifeste", "--audio", str(audio_dir)])
    assert r2.exit_code != 0 and "existe déjà" in r2.output


def test_text_is_nfc_normalised(tmp_path):
    # Spotify/macOS metadata can be decomposed (NFD): "Loïc" = "Loi" + U+0308. LRCLIB only matches NFC.
    import unicodedata
    nfd = unicodedata.normalize("NFD", "Loïc Nottet")
    assert nfd != "Loïc Nottet"
    p = tmp_path / "m.csv"
    write_manifest(p, [song(artiste=nfd, titre=unicodedata.normalize("NFD", "Les blés d’or"))])
    s = read_manifest(p)[0]
    assert s.artiste == "Loïc Nottet" and s.titre == "Les blés d’or"
    wav = write_wav(tmp_path / "a.wav", tone(1.0))
    flac = tmp_path / "audio" / "05.flac"
    flac.parent.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-metadata", f"artist={nfd}",
                    "-metadata", "title=Danser", "-metadata", "track=5", str(flac)], check=True)
    assert songs_from_sysrec(flac.parent)[0].artiste == "Loïc Nottet"


def test_group_by_partie_keeps_order_and_unassigned():
    from karaoke.manifest import group_by_partie
    songs = [song(id="001", partie="B"), song(id="002", partie="A"), song(id="003", partie="B"), song(id="004", partie="")]
    g = group_by_partie(songs)
    assert list(g) == ["B", "A", "sans-partie"]
    assert [s.id for s in g["B"]] == ["001", "003"]
