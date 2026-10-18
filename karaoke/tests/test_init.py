import json
from pathlib import Path


def test_init_creates_the_whole_tree_with_template_and_manifest(tmp_path, monkeypatch):
    # Michel's brother: the tool must not depend on Michel's disk (Hypermnesia)
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.config import Config
    from karaoke.manifest import read_manifest
    home = tmp_path / "Karaoke"
    r = CliRunner().invoke(cli.app, ["init", "--home", str(home)])
    assert r.exit_code == 0, r.output
    for d in ["paroles", "accords", "travail", "sortie", "sets"]:
        assert (home / d).is_dir(), d
    cfg = Config(home=home)
    assert cfg.manifest.exists() and read_manifest(cfg.manifest) == []
    assert (home / "gabarit" / "gabarit Project" / "gabarit.als").stat().st_size > 1000
    assert json.loads(r.output)["home"] == str(home)


def test_init_never_overwrites(tmp_path):
    from typer.testing import CliRunner
    from karaoke import cli
    home = tmp_path / "K"
    CliRunner().invoke(cli.app, ["init", "--home", str(home)])
    (home / "manifeste.csv").write_text("mine")
    tpl = home / "gabarit" / "gabarit Project" / "gabarit.als"
    tpl.write_bytes(b"my template")
    r = CliRunner().invoke(cli.app, ["init", "--home", str(home)])
    assert r.exit_code == 0 and (home / "manifeste.csv").read_text() == "mine" and tpl.read_bytes() == b"my template"


def test_default_home_is_not_michels_disk(monkeypatch):
    from karaoke.config import Config
    monkeypatch.delenv("KARAOKE_HOME", raising=False)
    monkeypatch.setattr("karaoke.config.LEGACY_HOME", Path("/nonexistent/legacy"))
    assert Config.load().home == Path.home() / "Karaoke"


def test_traiter_on_a_brand_new_mac_sets_up_and_explains(tmp_path, monkeypatch):
    # Michel's brother ran « karaoke traiter » first thing: no folder, no manifest
    from typer.testing import CliRunner
    from karaoke import cli
    home = tmp_path / "Karaoke"
    monkeypatch.setenv("KARAOKE_HOME", str(home))
    r = CliRunner().invoke(cli.app, ["traiter"])
    assert r.exit_code == 0, (r.output, r.exception)
    assert (home / "manifeste.csv").exists() and (home / "gabarit" / "gabarit Project" / "gabarit.als").exists()
    assert "Aucun morceau" in r.output and "karaoke ajouter" in r.output


def test_every_command_works_on_a_fresh_folder(tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    monkeypatch.setenv("KARAOKE_HOME", str(tmp_path / "K"))
    for args in (["etat", "--json"], ["rapport"], ["sets"]):
        r = CliRunner().invoke(cli.app, args)
        assert r.exit_code == 0, (args, r.output, r.exception)


def test_manifeste_from_recordings_works_on_a_fresh_or_just_initialised_folder(tmp_path, monkeypatch):
    import subprocess
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.manifest import read_manifest
    rec = tmp_path / "rec"; rec.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=d=1", "-metadata", "title=Speed",
                    "-metadata", "artist=Zazie", "-metadata", "track=11", str(rec / "11 - Speed - Zazie.flac")], check=True)
    home = tmp_path / "K"
    monkeypatch.setenv("KARAOKE_HOME", str(home))
    CliRunner().invoke(cli.app, ["init"])                                  # empty manifest exists now
    r = CliRunner().invoke(cli.app, ["manifeste", "--audio", str(rec)])
    assert r.exit_code == 0, r.output
    assert [s.titre for s in read_manifest(home / "manifeste.csv")] == ["Speed"]
    assert (home / "gabarit" / "gabarit Project" / "gabarit.als").exists()
