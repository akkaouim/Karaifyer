import json
from karaoke.runner import Step, inspect_song, run_song
from karaoke.state import song_state
from karaoke.workspace import Workspace
from test_manifest import song


def steps(calls):
    a = Step(name="a", deps=(), key=lambda ws: calls.get("ka", "k"), run=lambda ws, up: {"x": 1})
    b = Step(name="b", deps=("a",), key=lambda ws: "k", run=lambda ws, up: {"y": 2})
    return [a, b]


def test_inspect_song_matches_runner(cfg):
    ws, calls = Workspace(cfg, song()), {}
    assert inspect_song(ws, steps(calls)) == {"a": "absent", "b": "absent"}
    run_song(ws, steps(calls))
    assert inspect_song(ws, steps(calls)) == {"a": "a_jour", "b": "a_jour"}
    calls["ka"] = "changed"                       # a's parameters changed → a and b out of date
    assert inspect_song(ws, steps(calls)) == {"a": "perime", "b": "perime"}


def test_song_state_reports_paths_failures_and_chords(cfg):
    s = song(id="005", titre="Danser", artiste="Loïc Nottet", partie="Apéro")
    ws = Workspace(cfg, s)
    run_song(ws, steps({}))
    ws.write_marker("package", {"result": {"pad_s": 2.5}})
    ws.write_marker("chords", {"result": {"key": "C# minor", "beats_per_bar": 4,
                                          "bars": [{"start": 0.0, "chords": [[0, "C#m"]]}]}})
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "rapport.json").write_text(json.dumps({"statut": "echec", "etapes": {"a": "fait", "b": "echec"},
                                                      "alertes": ["b : echec ValueError: boom"]}))
    st = song_state(cfg, s, steps({"ka": "new"}))
    assert st["statut"] == "echec" and st["retirer"] == ["guitar"] and st["pad_s"] == 2.5
    assert [(x["name"], x["status"]) for x in st["steps"]] == [("a", "perime"), ("b", "echec")]
    assert "boom" in st["steps"][1]["error"]
    assert st["paths"]["video"].endswith("005_loic-nottet_danser/paroles.mp4")
    assert st["paths"]["set"].endswith("sets/apero/005_loic-nottet_danser.als")
    assert st["paths"]["accords_corrige"].endswith("accords/005.txt")
    assert st["paths"]["audio"].endswith("travail/005/input.wav")
    assert st["key"] == "C# minor" and st["bars"][0]["chords"] == [[0, "C#m"]]


def test_etat_cli_prints_json_list(cfg, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.manifest import write_manifest
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song(), song(id="002", titre="B")])
    r = CliRunner().invoke(cli.app, ["etat", "--json"])
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    assert [d["id"] for d in data] == ["001", "002"] and data[0]["statut"] == "—"


def test_song_state_includes_the_report_alerts(cfg):
    # hover help on the Statut column explains why a song is « alerte » / « echec »
    s = song()
    ws = Workspace(cfg, s)
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "rapport.json").write_text(json.dumps({"statut": "alerte", "etapes": {},
                                                      "alertes": ["calage des paroles 82%", "dérive du clic 44 ms"]}))
    assert song_state(cfg, s, steps({}))["alertes"] == ["calage des paroles 82%", "dérive du clic 44 ms"]
    assert song_state(cfg, song(id="002"), steps({}))["alertes"] == []


def test_each_alert_is_attached_to_the_step_it_questions(cfg):
    # Blés d'or: « à vérifier » overall, tempo + lyrics → beats and lyrics dots orange
    from karaoke.steps import STEPS
    s = song()
    ws = Workspace(cfg, s)
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "rapport.json").write_text(json.dumps({"statut": "alerte", "etapes": {}, "alertes": [
        "tempo instable (75 % du morceau hors tempo)", "paroles transcrites automatiquement : à relire",
        "dérive du clic 44 ms", "écart de durée +3.2 s"]}))
    st = {x["name"]: x["alert"] for x in song_state(cfg, s, STEPS)["steps"]}
    assert st["beats"] == "tempo instable (75 % du morceau hors tempo)"
    assert st["lyrics"] == "paroles transcrites automatiquement : à relire"
    assert st["package"] == "dérive du clic 44 ms" and st["ingest"] == "écart de durée +3.2 s"
    assert st["video"] == "" and st["separate"] == ""


def test_song_state_includes_the_typical_bpm(cfg):
    s = song()
    ws = Workspace(cfg, s)
    ws.write_marker("package", {"result": {"pad_s": 1.0, "bpm": 100.4}})
    assert song_state(cfg, s, steps({}))["bpm"] == 100.4
    assert song_state(cfg, song(id="002"), steps({}))["bpm"] is None


def test_state_exposes_the_grid(cfg):
    s = song()
    ws = Workspace(cfg, s)
    ws.write_marker("beats", {"result": {"beats": [0.0, 0.5, 1.0, 1.5, 2.0], "downbeats": [0.0, 1.0],
                                         "downbeats_detectees": [0.0, 2.0], "beats_per_bar_detecte": 4,
                                         "beats_per_bar": 2, "bpm": 120.0, "signature": "2/4", "swing": False}})
    st = song_state(cfg, s, steps({}))
    assert st["grid"] == {"beats": [0.0, 0.5, 1.0, 1.5, 2.0], "downbeats_detectees": [0.0, 2.0],
                          "beats_per_bar_detecte": 4, "bpm": 120.0, "signature": "2/4", "swing": False}
    assert st["paths"]["mesures_corrige"].endswith(f"mesures/{s.id}.json")
    assert song_state(cfg, song(id="002"), steps({}))["grid"] is None


def test_state_grid_falls_back_for_old_results(cfg):
    s = song()
    beats = [0.5 * i for i in range(16)]
    Workspace(cfg, s).write_marker("beats", {"result": {"beats": beats, "downbeats": beats[::4]}})
    g = song_state(cfg, s, steps({}))["grid"]
    assert g["downbeats_detectees"] == beats[::4] and g["beats_per_bar_detecte"] == 4
    assert g["bpm"] == 120.0 and g["signature"] is None and g["swing"] is False


def test_state_grid_drops_off_beat_downbeats_of_old_results(cfg):
    s = song()
    beats = [0.5 * i for i in range(16)]
    Workspace(cfg, s).write_marker("beats", {"result": {"beats": beats, "downbeats": [0.0, 1.7, 2.0, 4.0]}})
    assert song_state(cfg, s, steps({}))["grid"]["downbeats_detectees"] == [0.0, 2.0, 4.0]
