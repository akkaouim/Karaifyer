from pathlib import Path
from karaoke.config import Config

def test_home_from_env(monkeypatch, tmp_path):
    monkeypatch.setenv("KARAOKE_HOME", str(tmp_path))
    c = Config.load()
    assert c.home == tmp_path
    assert c.manifest == tmp_path / "manifeste.csv"
    assert c.travail == tmp_path / "travail"
    assert c.sortie == tmp_path / "sortie"
    assert c.paroles == tmp_path / "paroles"

def test_default_home(monkeypatch):
    monkeypatch.delenv("KARAOKE_HOME", raising=False)
    assert Config.load().home == Path("/Volumes/Hypermnesia/karaoke")

def test_ensure_dirs(tmp_path):
    c = Config(home=tmp_path)
    c.ensure_dirs()
    for d in (c.travail, c.sortie, c.paroles):
        assert d.is_dir()
