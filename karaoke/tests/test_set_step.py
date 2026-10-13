import shutil
from pathlib import Path
from karaoke.ableton.als import load_als
from karaoke.steps.set_ableton import SET_ABLETON
from karaoke.workspace import Workspace
from test_build import make_song, FIX
from test_manifest import song


def test_set_step_writes_the_song_set(cfg, tmp_path, monkeypatch):
    monkeypatch.setenv("KARAOKE_GABARIT", str(FIX / "gabarit.als"))
    s = song(id="005", titre="Danser", artiste="Loïc Nottet", partie="Apéro")
    ws = Workspace(cfg, s)
    src = make_song(tmp_path / "src", "005", 3.0)
    shutil.copytree(src.folder, ws.out)
    r = SET_ABLETON.run(ws, {"package": {"faders": src.faders}, "video": {}})
    out = cfg.sets / "apero" / f"{ws.out.name}.als"
    assert Path(r["set"]) == out and out.exists() and r["warnings"] == []
    ls = load_als(out).getroot().find("LiveSet")
    assert [l.find("Name").get("Value") for l in ls.findall("Locators/Locators/Locator")] == ["005 Danser"]
    assert SET_ABLETON.artifacts(ws) == [out]


def test_set_step_key_follows_template(cfg, tmp_path, monkeypatch):
    tpl = tmp_path / "g.als"
    shutil.copy(FIX / "gabarit.als", tpl)
    monkeypatch.setenv("KARAOKE_GABARIT", str(tpl))
    ws = Workspace(cfg, song())
    k1 = SET_ABLETON.key(ws)
    import os, time
    os.utime(tpl, (time.time() + 10, time.time() + 10))
    assert SET_ABLETON.key(ws) != k1


def test_set_step_removes_stale_sets_of_the_same_song(cfg, tmp_path, monkeypatch):
    # review #3: moving a song to another partie (or renaming it) must not leave the old set behind
    monkeypatch.setenv("KARAOKE_GABARIT", str(FIX / "gabarit.als"))
    s = song(id="005", titre="Danser", artiste="Loïc Nottet", partie="Dessert")
    ws = Workspace(cfg, s)
    src = make_song(tmp_path / "src", "005", 3.0)
    shutil.copytree(src.folder, ws.out)
    stale = [cfg.sets / "apero" / f"{ws.out.name}.als", cfg.sets / "dessert" / "005_loic-nottet_danse.als"]
    other = cfg.sets / "apero" / "0050_x_y.als"
    for p in stale + [other]:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("old")
    SET_ABLETON.run(ws, {"package": {"faders": src.faders}, "video": {}})
    assert not any(p.exists() for p in stale) and other.exists()
    assert (cfg.sets / "dessert" / f"{ws.out.name}.als").exists()
