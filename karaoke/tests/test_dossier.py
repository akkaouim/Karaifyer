from karaoke.manifest import read_manifest, write_manifest, songs_from_files, COLUMNS
from karaoke.workspace import Workspace, display_name, unique_dossier
from test_manifest import song
import numpy as np
import soundfile as sf


def audio_file(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.zeros((441, 2), dtype=np.float32), 44100, format="FLAC")
    return path


def test_display_name_matches_the_recorder():
    assert display_name("À ma place", "Zazie/Axel Bauer") == "À ma place - Zazie & Axel Bauer"
    assert display_name("Dis: quand?", "(Barbara)") == "Dis - quand - Barbara"


def test_unique_dossier_suffixes_other_songs_only():
    taken = {"Danser - Loïc Nottet": "050"}
    assert unique_dossier("Danser - Loïc Nottet", "050", taken) == "Danser - Loïc Nottet"
    assert unique_dossier("Danser - Loïc Nottet", "200", taken) == "Danser - Loïc Nottet (2)"


def test_dossier_column_round_trips_and_defaults_to_legacy(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet"),
                                  song(id="011")])
    a, b = read_manifest(cfg.manifest)
    assert COLUMNS[-1] == "dossier" and a.dossier == "Danser - Loïc Nottet"
    assert Workspace(cfg, a).out == cfg.sortie / "Danser - Loïc Nottet"
    assert Workspace(cfg, b).out.name == "011_zazie_je-suis-un-homme"          # unmigrated row: unchanged


def test_manifest_without_the_column_still_reads(cfg):
    cfg.manifest.write_text(",".join(COLUMNS[:-1]) + "\n" + "005,T,A,,1,,/x.flac,,2,fr,,\n", encoding="utf-8")
    assert read_manifest(cfg.manifest)[0].dossier == ""


def test_added_songs_get_a_unique_readable_folder(cfg, tmp_path):
    existing = [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet")]
    f = audio_file(tmp_path / "x.flac")
    added, _ = songs_from_files([f], existing)
    assert added[0].dossier == display_name(added[0].titre, added[0].artiste)


def test_two_added_songs_with_the_same_name_get_distinct_folders(cfg, tmp_path):
    a = audio_file(tmp_path / "a" / "Danser.flac"); b = audio_file(tmp_path / "b" / "Danser.flac")
    added, _ = songs_from_files([a, b], [])
    assert added[0].dossier != added[1].dossier
