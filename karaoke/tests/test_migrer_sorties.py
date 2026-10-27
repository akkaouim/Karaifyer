import fcntl
import json
from pathlib import Path
import pytest
from karaoke import migrer_sorties as M
from karaoke.manifest import read_manifest, write_manifest
from karaoke.steps import STEPS
from karaoke.workspace import Workspace
from test_manifest import song


def setup(cfg, tmp_path):
    songs = [song(id="050", titre="Danser", artiste="Loïc Nottet", partie="A", fichier=tmp_path / "a.flac"),
             song(id="041", titre="La chanson des blés d’or", artiste="Fabienne Thibeault", partie="", fichier=tmp_path / "b.flac")]
    write_manifest(cfg.manifest, songs)
    for s in songs:
        ws = Workspace(cfg, s)
        ws.out.mkdir(parents=True)
        (ws.out / "paroles.mp4").write_bytes(b"v")
        ws.write_marker("package", {"key": "k", "result": {"faders": {}}, "output_hash": "h"})
        part = cfg.sets / ("a" if s.partie else "sans-partie")
        part.mkdir(parents=True, exist_ok=True)
        (part / f"{ws.out.name}.als").write_text("old set")
    return songs


def fake_set_run(calls=None):
    """Stands in for the set step: writes sets/<partie>/<dossier>.als and reports it done."""
    def run(ws, steps, only=None, **kw):
        if calls is not None:
            calls.append((ws.song.id, only))
        p = ws.cfg.sets / ("a" if ws.song.partie else "sans-partie") / f"{ws.out.name}.als"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("new set")
        return {"set": {"status": "fait"}}
    return run


def test_plan_lists_renames_and_changes_nothing(cfg, tmp_path):
    setup(cfg, tmp_path)
    p = M.plan(cfg)
    assert [(x["id"], x["ancien"], x["nouveau"]) for x in p] == [
        ("050", "050_loic-nottet_danser", "Danser - Loïc Nottet"),
        ("041", "041_fabienne-thibeault_la-chanson-des-bles-d-or", "La chanson des blés d’or - Fabienne Thibeault")]
    assert (cfg.sortie / "050_loic-nottet_danser").exists() and read_manifest(cfg.manifest)[0].dossier == ""


def test_apply_renames_fills_dossier_trashes_old_sets_and_rebuilds_sets_only(cfg, tmp_path, monkeypatch):
    setup(cfg, tmp_path)
    calls, trashed = [], []
    monkeypatch.setattr(M, "run_song", fake_set_run(calls))
    r = M.appliquer(cfg, trash=lambda ps: trashed.extend(ps))
    assert r["renommes"] == 2 and Path(r["sauvegarde"]).exists() and r["sets"] == 2
    by = {s.id: s for s in read_manifest(cfg.manifest)}
    assert by["050"].dossier == "Danser - Loïc Nottet"
    assert (cfg.sortie / "Danser - Loïc Nottet" / "paroles.mp4").exists() and not (cfg.sortie / "050_loic-nottet_danser").exists()
    assert {Path(p).name for p in trashed} == {"050_loic-nottet_danser.als", "041_fabienne-thibeault_la-chanson-des-bles-d-or.als"}
    assert sorted(calls) == [("041", {"set"}), ("050", {"set"})]


def test_heavy_steps_do_not_depend_on_the_folder_name(cfg, tmp_path):
    # every step key but the set's is the same before and after: renaming re-runs nothing heavy
    s = setup(cfg, tmp_path)[0]
    before = {st.name: st.key(Workspace(cfg, s)) for st in STEPS if st.name != "set"}
    after = {st.name: st.key(Workspace(cfg, s.__class__(**{**s.__dict__, "dossier": "Danser - Loïc Nottet"})))
             for st in STEPS if st.name != "set"}
    assert before == after


def test_second_run_does_nothing_and_makes_no_backup(cfg, tmp_path, monkeypatch):
    setup(cfg, tmp_path)
    monkeypatch.setattr(M, "run_song", fake_set_run())
    gone = lambda ps: [Path(x).unlink() for x in ps]          # as the Trash does
    M.appliquer(cfg, trash=gone)
    assert M.appliquer(cfg, trash=gone) == {"renommes": 0, "sauvegarde": None, "sets": 0, "sets_echec": []}


def test_interrupted_run_is_finished_by_the_next_one(cfg, tmp_path, monkeypatch):
    # manifest written, the drive gone before the folders were renamed
    setup(cfg, tmp_path)
    songs = read_manifest(cfg.manifest)
    from dataclasses import replace
    write_manifest(cfg.manifest, [replace(songs[0], dossier="Danser - Loïc Nottet"), songs[1]])
    monkeypatch.setattr(M, "run_song", fake_set_run())
    r = M.appliquer(cfg, trash=lambda ps: None)
    assert r["renommes"] == 2
    assert (cfg.sortie / "Danser - Loïc Nottet").exists() and not (cfg.sortie / "050_loic-nottet_danser").exists()


def test_refused_while_a_song_is_being_analysed(cfg, tmp_path, monkeypatch):
    s = setup(cfg, tmp_path)[0]
    lock = open(Workspace(cfg, s).work / ".lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        with pytest.raises(ValueError, match="analyse"):
            M.appliquer(cfg, trash=lambda ps: None)
        assert (cfg.sortie / "050_loic-nottet_danser").exists()
    finally:
        lock.close()


def test_cli_plan_json(cfg, tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke.cli import app
    setup(cfg, tmp_path)
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    r = CliRunner().invoke(app, ["migrer-sorties", "--plan", "--json"])
    assert r.exit_code == 0 and len(json.loads(r.stdout)) == 2


def test_traiter_adopts_the_legacy_folder_of_a_named_row(cfg, tmp_path):
    # Gate B #1: manifest written, drive gone before the rename: the analysis must not start from nothing
    from dataclasses import replace
    s = setup(cfg, tmp_path)[0]
    named = replace(s, dossier="Danser - Loïc Nottet")
    ws = Workspace(cfg, named)
    ws.adopt_previous_folder()
    assert (cfg.sortie / "Danser - Loïc Nottet" / "paroles.mp4").exists() and not (cfg.sortie / "050_loic-nottet_danser").exists()


def test_interrupted_run_rebuilds_sets_of_rows_already_renamed(cfg, tmp_path, monkeypatch):
    # Gate B #2: folder renamed and manifest written, sets not rebuilt yet
    from dataclasses import replace
    songs = setup(cfg, tmp_path)
    write_manifest(cfg.manifest, [replace(songs[0], dossier="Danser - Loïc Nottet"), songs[1]])
    (cfg.sortie / "050_loic-nottet_danser").rename(cfg.sortie / "Danser - Loïc Nottet")
    calls, trashed = [], []
    monkeypatch.setattr(M, "run_song", lambda ws, steps, only=None, **kw: calls.append(ws.song.id) or {"set": {"status": "fait"}})
    M.appliquer(cfg, trash=lambda ps: trashed.extend(ps))
    assert "050" in calls and "050_loic-nottet_danser.als" in {Path(p).name for p in trashed}


def test_case_only_different_titles_get_distinct_folders(cfg, tmp_path, monkeypatch):
    # Gate B #3: the drive is case-insensitive
    write_manifest(cfg.manifest, [song(id="002", titre="Le petit bal", artiste="B", fichier=tmp_path / "a.flac"),
                                  song(id="003", titre="Le Petit Bal", artiste="B", fichier=tmp_path / "b.flac")])
    for sid, t in (("002", "le-petit-bal"), ("003", "le-petit-bal")):
        (cfg.sortie / f"{sid}_b_{t}").mkdir(parents=True)
    targets = [x["nouveau"] for x in M.plan(cfg)]
    assert len({t.casefold() for t in targets}) == 2


def test_apply_reports_sets_that_failed_to_rebuild(cfg, tmp_path, monkeypatch):
    setup(cfg, tmp_path)
    monkeypatch.setattr(M, "run_song", lambda ws, steps, only=None, **kw:
                        {"set": {"status": "fait" if ws.song.id == "050" else "echec"}})
    r = M.appliquer(cfg, trash=lambda ps: None)
    assert r["sets"] == 1 and r["sets_echec"] == ["041"]
