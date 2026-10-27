import json
from pathlib import Path
from karaoke import retirer as R
from karaoke.manifest import read_manifest, write_manifest
from karaoke.workspace import Workspace
from test_manifest import song


def setup(cfg, tmp_path):
    audio = tmp_path / "audio"
    audio.mkdir()
    a, b = audio / "05 - Danser.flac", audio / "11 - Speed.flac"
    a.write_bytes(b"x" * 100); b.write_bytes(b"y" * 50)
    songs = [song(id="005", titre="Danser", fichier=a), song(id="050", titre="Danser", fichier=a),
             song(id="011", titre="Speed", fichier=b)]
    write_manifest(cfg.manifest, songs)
    for s in songs:
        ws = Workspace(cfg, s)
        ws.work.mkdir(parents=True, exist_ok=True); (ws.work / "input.wav").write_bytes(b"w" * 1000)
        ws.out.mkdir(parents=True, exist_ok=True); (ws.out / "paroles.mp4").write_bytes(b"v" * 300)
    for d in (cfg.paroles, cfg.accords, cfg.mesures, cfg.sets / "a"):
        d.mkdir(parents=True, exist_ok=True)
    (cfg.paroles / "011.lrc").write_text("[00:01.00]x"); (cfg.accords / "011.txt").write_text("| C |")
    (cfg.mesures / "011.json").write_text("{}")
    (cfg.sets / "a" / f"{Workspace(cfg, songs[2]).out.name}.als").write_bytes(b"als")
    g = cfg.home / "grilles" / "progressions"
    g.mkdir(parents=True)
    (g / "011.txt").write_text("<verse_1> C"); (g / "011.original.txt").write_text("<verse_1> C")
    (cfg.home / "grilles" / "correspondances.json").write_text(json.dumps({"005": {}, "050": {}, "011": {"chordonomicon": True}}))
    return songs, a, b


def test_plan_lists_files_sizes_and_shared_recordings(cfg, tmp_path):
    songs, a, b = setup(cfg, tmp_path)
    p = {x["id"]: x for x in R.plan(cfg, ["005", "011"])}
    assert p["011"]["analyse"]["taille"] >= 1000 + 300 + 3 and len(p["011"]["corrections"]["fichiers"]) == 3
    assert p["011"]["audio"]["partage"] is False and p["011"]["audio"]["fichier"] == str(b)
    assert p["005"]["audio"]["partage"] is True                       # 050 keeps using the same recording


def test_removal_trashes_what_was_chosen_and_keeps_the_rest_consistent(cfg, tmp_path):
    songs, a, b = setup(cfg, tmp_path)
    trashed = []
    r = R.retirer(cfg, ["005", "011"], analyse=True, corrections=True, audio=True, trash=lambda ps: trashed.extend(ps))
    assert [s.id for s in read_manifest(cfg.manifest)] == ["050"]
    assert Path(r["sauvegarde"]).exists() and "005" in Path(r["sauvegarde"]).read_text()
    t = {Path(p).name for p in trashed}
    assert "011.lrc" in t and "011.txt" in t and "011.json" in t and b.name in t
    assert a.name not in t                                            # shared with 050: never trashed
    assert Workspace(cfg, songs[0]).work.name in t and Workspace(cfg, songs[2]).out.name in t
    assert any(n.endswith(".als") for n in t)
    assert not (cfg.home / "grilles" / "progressions" / "011.txt").exists()
    assert set(json.loads((cfg.home / "grilles" / "correspondances.json").read_text())) == {"050"}
    assert (cfg.home / "rapport.html").exists()


def test_corrections_and_recording_kept_when_unchecked(cfg, tmp_path):
    songs, a, b = setup(cfg, tmp_path)
    trashed = []
    R.retirer(cfg, ["011"], analyse=True, corrections=False, audio=False, trash=lambda ps: trashed.extend(ps))
    names = {Path(p).name for p in trashed}
    assert "011.lrc" not in names and b.name not in names and (cfg.paroles / "011.lrc").exists()


def test_unknown_id_is_an_error(cfg, tmp_path):
    import pytest
    setup(cfg, tmp_path)
    with pytest.raises(ValueError, match="999"):
        R.retirer(cfg, ["999"], trash=lambda ps: None)


def test_ireal_page_of_a_part_left_without_charts_is_removed(cfg, tmp_path):
    setup(cfg, tmp_path)
    page = cfg.home / "ireal" / "a.html"
    page.parent.mkdir(); page.write_text("old")
    R.retirer(cfg, ["005", "050", "011"], trash=lambda ps: None)
    assert not page.exists() and read_manifest(cfg.manifest) == []


def test_cli_plan_and_removal_as_json(cfg, tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke.cli import app
    setup(cfg, tmp_path)
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    trashed = []
    monkeypatch.setattr(R, "system_trash", lambda ps: trashed.extend(ps))
    r = CliRunner().invoke(app, ["retirer", "--ids", "011", "--plan", "--json"])
    assert r.exit_code == 0 and json.loads(r.stdout)[0]["id"] == "011" and len(read_manifest(cfg.manifest)) == 3
    r = CliRunner().invoke(app, ["retirer", "--ids", "011", "--corrections", "--json"])
    assert r.exit_code == 0 and json.loads(r.stdout)["retires"] == ["011"]
    assert {Path(p).name for p in trashed} >= {"011.lrc"} and len(read_manifest(cfg.manifest)) == 2
    r = CliRunner().invoke(app, ["retirer", "--ids", "999", "--json"])
    assert r.exit_code != 0 and "999" in r.output


def test_shared_recording_spelled_in_another_unicode_form_is_still_shared(cfg, tmp_path):
    import unicodedata
    audio = tmp_path / "audio"
    audio.mkdir()
    f = audio / unicodedata.normalize("NFC", "05 - Loïc.flac")
    f.write_bytes(b"x")
    other = Path(unicodedata.normalize("NFD", str(f)))
    assert str(other) != str(f)
    write_manifest(cfg.manifest, [song(id="005", fichier=f), song(id="050", fichier=other)])
    assert R.plan(cfg, ["005"])[0]["audio"]["partage"] is True
    trashed = []
    R.retirer(cfg, ["005"], audio=True, trash=lambda ps: trashed.extend(ps))
    assert trashed == [] or all(Path(p).name != f.name for p in trashed)


def test_recording_of_two_removed_rows_is_counted_and_trashed_once(cfg, tmp_path):
    songs, a, b = setup(cfg, tmp_path)
    p = R.plan(cfg, ["005", "050"])
    assert sum(x["audio"]["taille"] for x in p) == 100 and not any(x["audio"]["partage"] for x in p)
    trashed = []
    R.retirer(cfg, ["005", "050"], audio=True, trash=lambda ps: trashed.extend(ps))
    assert [Path(t).name for t in trashed].count(a.name) == 1


def test_removal_finds_outputs_by_dossier_and_legacy_names(cfg, tmp_path):
    a = tmp_path / "a.flac"; a.write_bytes(b"x")
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet", fichier=a,
                                       dossier="Danser - Loïc Nottet")])
    new = cfg.sortie / "Danser - Loïc Nottet"; new.mkdir(parents=True)
    legacy = cfg.sortie / "050_loic-nottet_danser"; legacy.mkdir()
    (cfg.sets / "a").mkdir(parents=True)
    s1 = cfg.sets / "a" / "Danser - Loïc Nottet.als"; s1.write_text("x")
    s2 = cfg.sets / "a" / "050_loic-nottet_danser.als"; s2.write_text("x")
    other = cfg.sets / "a" / "Danser - Loïc Nottet (2).als"; other.write_text("x")
    trashed = []
    R.retirer(cfg, ["050"], analyse=True, trash=lambda ps: trashed.extend(ps))
    names = {Path(p).name for p in trashed}
    assert {"Danser - Loïc Nottet", "050_loic-nottet_danser", "Danser - Loïc Nottet.als", "050_loic-nottet_danser.als"} <= names
    assert "Danser - Loïc Nottet (2).als" not in names
