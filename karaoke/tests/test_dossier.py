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
    assert "dossier" in COLUMNS and a.dossier == "Danser - Loïc Nottet"
    assert Workspace(cfg, a).out == cfg.sortie / "Danser - Loïc Nottet"
    assert Workspace(cfg, b).out.name == "011_zazie_je-suis-un-homme"          # unmigrated row: unchanged


def test_manifest_without_the_column_still_reads(cfg):
    cfg.manifest.write_text(",".join(c for c in COLUMNS if c not in ("dossier", "verifie")) + "\n" + "005,T,A,,1,,/x.flac,,2,fr,,\n", encoding="utf-8")
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


from karaoke.workspace import renommer_dossier
from karaoke.manifest import set_field


def _outputs(cfg, name, partie="a"):
    (cfg.sortie / name).mkdir(parents=True)
    (cfg.sortie / name / "paroles.mp4").write_bytes(b"v")
    (cfg.sets / partie).mkdir(parents=True, exist_ok=True)
    (cfg.sets / partie / f"{name}.als").write_text("set")


def test_title_edit_renames_folder_and_sets(cfg):
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet")])
    _outputs(cfg, "Danser - Loïc Nottet")
    set_field(cfg.manifest, "050", "titre", "Danse")
    renommer_dossier(cfg, "050")
    s = read_manifest(cfg.manifest)[0]
    assert s.dossier == "Danse - Loïc Nottet"
    assert (cfg.sortie / "Danse - Loïc Nottet" / "paroles.mp4").exists() and not (cfg.sortie / "Danser - Loïc Nottet").exists()
    assert (cfg.sets / "a" / "Danse - Loïc Nottet.als").exists() and not (cfg.sets / "a" / "Danser - Loïc Nottet.als").exists()


def test_title_edit_of_a_never_analysed_song_just_sets_the_name(cfg):
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet")])
    set_field(cfg.manifest, "050", "titre", "Danse")
    renommer_dossier(cfg, "050")
    assert read_manifest(cfg.manifest)[0].dossier == "Danse - Loïc Nottet"


def test_title_edit_onto_another_songs_name_gets_a_suffix(cfg):
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet"),
                                  song(id="060", titre="Danse", artiste="Loïc Nottet", dossier="Danse - Loïc Nottet")])
    _outputs(cfg, "Danser - Loïc Nottet")
    _outputs(cfg, "Danse - Loïc Nottet", partie="b")
    set_field(cfg.manifest, "050", "titre", "Danse")
    renommer_dossier(cfg, "050")
    by = {s.id: s for s in read_manifest(cfg.manifest)}
    assert by["050"].dossier == "Danse - Loïc Nottet (2)" and by["060"].dossier == "Danse - Loïc Nottet"
    assert (cfg.sortie / "Danse - Loïc Nottet (2)").exists() and (cfg.sets / "b" / "Danse - Loïc Nottet.als").exists()


def test_legacy_row_gets_a_named_folder_on_its_first_edit(cfg):
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet")])
    _outputs(cfg, "050_loic-nottet_danser")
    set_field(cfg.manifest, "050", "titre", "Danse")
    renommer_dossier(cfg, "050")
    assert read_manifest(cfg.manifest)[0].dossier == "Danse - Loïc Nottet"
    assert (cfg.sortie / "Danse - Loïc Nottet").exists() and (cfg.sets / "a" / "Danse - Loïc Nottet.als").exists()


def test_cli_modifier_titre_renames(cfg, monkeypatch):
    from typer.testing import CliRunner
    from karaoke.cli import app
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet")])
    _outputs(cfg, "Danser - Loïc Nottet")
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    r = CliRunner().invoke(app, ["modifier", "--id", "050", "--champ", "artiste", "--valeur", "L. Nottet"])
    assert r.exit_code == 0 and (cfg.sortie / "Danser - L. Nottet").exists()


def test_case_only_title_fix_keeps_the_folder_without_suffix(cfg):
    # Gate B #4
    write_manifest(cfg.manifest, [song(id="050", titre="danser", artiste="X", dossier="danser - X")])
    _outputs(cfg, "danser - X")
    set_field(cfg.manifest, "050", "titre", "Danser")
    assert renommer_dossier(cfg, "050") == "Danser - X"
    assert [p.name for p in cfg.sortie.iterdir()] == ["Danser - X"]


def test_unique_dossier_ignores_case():
    assert unique_dossier("Le Petit Bal - B", "003", {"Le petit bal - B": "002"}) == "Le Petit Bal - B (2)"


def test_long_names_fit_the_filesystem():
    assert len(display_name("é" * 300, "à" * 50).encode()) <= 200


def test_title_edit_rebuilds_the_set_with_the_new_folder(cfg, tmp_path, monkeypatch):
    # Gate B #5: the .als holds paths into sortie/<folder>: a renamed copy would open with missing media
    import shutil
    from test_build import make_song, FIX
    monkeypatch.setenv("KARAOKE_GABARIT", str(FIX / "gabarit.als"))
    s = song(id="050", titre="Danser", artiste="Loïc Nottet", partie="A", dossier="Danser - Loïc Nottet")
    write_manifest(cfg.manifest, [s])
    ws = Workspace(cfg, s)
    src = make_song(tmp_path / "src", "050", 3.0)
    shutil.copytree(src.folder, ws.out)
    ws.write_marker("package", {"key": "k", "result": {"faders": src.faders}, "output_hash": "h"})
    (cfg.sets / "a").mkdir(parents=True)
    (cfg.sets / "a" / "Danser - Loïc Nottet.als").write_text("old set")
    set_field(cfg.manifest, "050", "titre", "Danse")
    renommer_dossier(cfg, "050")
    new = cfg.sets / "a" / "Danse - Loïc Nottet.als"
    assert new.exists() and new.read_bytes() != b"old set" and not (cfg.sets / "a" / "Danser - Loïc Nottet.als").exists()


def test_failed_folder_rename_leaves_the_manifest_as_it_was(cfg, monkeypatch):
    from pathlib import Path as P
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="X", dossier="Danser - X")])
    _outputs(cfg, "Danser - X")
    set_field(cfg.manifest, "050", "titre", "Danse")
    real = P.rename
    monkeypatch.setattr(P, "rename", lambda self, t: (_ for _ in ()).throw(OSError("disque débranché")) if self.is_dir() else real(self, t))
    import pytest
    with pytest.raises(OSError):
        renommer_dossier(cfg, "050")
    assert read_manifest(cfg.manifest)[0].dossier == "Danser - X" and (cfg.sortie / "Danser - X").exists()
