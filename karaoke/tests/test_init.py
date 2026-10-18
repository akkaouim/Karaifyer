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
