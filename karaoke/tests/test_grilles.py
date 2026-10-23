import io, json, tarfile
from pathlib import Path
import pyarrow as pa, pyarrow.parquet as pq
from karaoke import grilles
from karaoke.manifest import read_manifest, write_manifest
from test_manifest import song


def sheet(tmp_path):
    p = tmp_path / "feuille.csv"
    p.write_text(",,,,Nom ou artiste sûr,,\nproposé par,,Titre,Artiste,KaraFun,Lien Spotify,Lien grilles\n"
                 "X,1,Je suis un homme,Zazie,oui,https://open.spotify.com/track/2YNWgxevUxpjZDgW4i5Aky?si=a,\n"
                 "X,7,Inconnu,Y,oui,https://open.spotify.com/track/0000000000000000000000,\n", encoding="utf-8")
    return p


def test_lier_fills_spotify_from_the_sheet_number(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(fichier=Path("/m/01 - Je suis un homme - Zazie.flac"))])
    assert grilles.lier(cfg, sheet(tmp_path)) == 1
    assert read_manifest(cfg.manifest)[0].spotify == "2YNWgxevUxpjZDgW4i5Aky"


def test_lier_ignores_unmatched_rows(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(fichier=Path("/m/99 - Autre - Z.flac"))])
    assert grilles.lier(cfg, sheet(tmp_path)) == 0 and read_manifest(cfg.manifest)[0].spotify == ""


def test_indexer_finds_both_sources_and_saves_the_progression(cfg):
    g = cfg.home / "grilles"
    (g / "patadata" / "songs" / "zazie").mkdir(parents=True)
    (g / "patadata" / "songs" / "zazie" / "je_suis_un_homme.sg").write_text("\\[Am]la\n")
    pq.write_table(pa.table({"chords": ["<verse_1> Amin F", "<verse_1> C", "<verse_1> D"],
                             "spotify_song_id": ["2YNWgxevUxpjZDgW4i5Aky", "dup", "dup"]}), g / "chordonomicon.parquet")
    write_manifest(cfg.manifest, [song(spotify="2YNWgxevUxpjZDgW4i5Aky"), song(id="002", titre="Autre", spotify="dup")])
    grilles.indexer(cfg)
    idx = json.loads((g / "correspondances.json").read_text())
    assert idx["001"] == {"patadata": "songs/zazie/je_suis_un_homme.sg", "chordonomicon": True}
    assert idx["002"]["chordonomicon"] is False                       # two different rows for one id: unreliable
    assert (g / "progressions" / "001.txt").read_text() == "<verse_1> Amin F"
