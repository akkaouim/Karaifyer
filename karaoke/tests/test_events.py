import json
from karaoke.runner import Step, run_song
from karaoke.workspace import Workspace
from test_manifest import song


def test_run_song_emits_step_events_and_logs(cfg):
    ws = Workspace(cfg, song())
    a = Step(name="a", deps=(), key=lambda ws: "k", run=lambda ws, up: {"x": 1})
    b = Step(name="b", deps=("a",), key=lambda ws: "k", run=lambda ws, up: 1 / 0)
    events = []
    ws.on_log = lambda line: events.append({"event": "log", "line": line})
    run_song(ws, [a, b], on_event=events.append)
    kinds = [(e["event"], e.get("step"), e.get("status")) for e in events if e["event"] != "log"]
    assert kinds == [("step_start", "a", None), ("step_end", "a", "fait"),
                     ("step_start", "b", None), ("step_end", "b", "echec")]
    end_b = [e for e in events if e.get("step") == "b" and e["event"] == "step_end"][0]
    assert "ZeroDivisionError" in end_b["error"] and end_b["id"] == "001" and end_b["seconds"] >= 0
    assert any(e["event"] == "log" and "début a" in e["line"] for e in events)


def test_skipped_steps_also_reported(cfg):
    ws = Workspace(cfg, song())
    a = Step(name="a", deps=(), key=lambda ws: "k", run=lambda ws, up: {"x": 1})
    run_song(ws, [a])
    events = []
    run_song(ws, [a], on_event=events.append)
    assert [(e["event"], e["status"]) for e in events if e["event"] == "step_end"] == [("step_end", "saute")]


def test_traiter_json_prints_one_json_object_per_line(cfg, monkeypatch, capsys):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.manifest import write_manifest
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song()])
    monkeypatch.setattr(cli, "STEPS", [Step(name="a", deps=(), key=lambda ws: "k", run=lambda ws, up: {})])
    r = CliRunner().invoke(cli.app, ["traiter", "--ids", "001", "--json"])
    assert r.exit_code == 0, r.output
    objs = [json.loads(l) for l in r.output.splitlines() if l.strip()]
    assert objs[0] == {"event": "song_start", "id": "001"}
    assert objs[-1]["event"] == "song_end" and objs[-1]["statut"] == "ok"
    assert {"event", "id", "step", "status", "seconds", "error"} <= set(
        next(o for o in objs if o["event"] == "step_end"))
