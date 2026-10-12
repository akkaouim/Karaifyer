import json
from karaoke.report import song_report, write_global
from test_manifest import song


def ok(result):
    return {"status": "fait", "seconds": 1.0, "result": result, "error": ""}


BASE = {"ingest": ok({"ref_delta_s": 0.1, "duration_alert": False}),
        "separate": ok({}), "beats": ok({}),
        "package": ok({"bpm": 120.0, "variation_pct": 1.0, "stable": True}),
        "lyrics": ok({"source": "lrclib-synchro", "lines": [{}] * 10}),
        "check": ok({"rate": 1.0, "drift_ms": 8.0}), "video": ok({})}


def test_clean_song_is_ok():
    r = song_report(song(), BASE)
    assert r["statut"] == "ok" and r["risque"] == 0 and r["alertes"] == []


def test_risks_add_up():
    res = dict(BASE)
    res["lyrics"] = ok({"source": "aucune", "lines": []})
    res["check"] = ok({"rate": None, "drift_ms": 45.0})
    res["package"] = ok({"bpm": 90.0, "variation_pct": 6.0, "stable": False})
    r = song_report(song(), res)
    assert r["statut"] == "alerte" and r["risque"] == 60 + 20 + 20
    assert any("sans paroles" in a for a in r["alertes"])


def test_failure_and_retry():
    res = dict(BASE)
    res["separate"] = {"status": "echec", "seconds": 0, "result": {}, "error": "boom"}
    res["lyrics"] = {"status": "a_reessayer", "seconds": 0, "result": {}, "error": "offline"}
    r = song_report(song(), res)
    assert r["statut"] == "echec" and r["risque"] >= 140


def test_global_sorted(tmp_path):
    rows = [song_report(song(id="001"), BASE), {**song_report(song(id="002"), BASE), "risque": 50}]
    write_global(rows, tmp_path / "r.csv", tmp_path / "r.html")
    lines = (tmp_path / "r.csv").read_text(encoding="utf-8").splitlines()
    assert lines[1].startswith("002") and "<table" in (tmp_path / "r.html").read_text(encoding="utf-8")


def test_cli_traiter_writes_reports_and_isolates_failures(tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.manifest import write_manifest
    from karaoke.runner import Step
    def boom(ws, up):
        raise RuntimeError("explosion")
    steps = [Step("ingest", (), lambda ws: "", lambda ws, up: {"duration_alert": False, "ref_delta_s": 0.0}),
             Step("separate", ("ingest",), lambda ws: ws.song.id, lambda ws, up: boom(ws, up) if ws.song.id == "001" else {})]
    monkeypatch.setattr(cli, "STEPS", steps)
    monkeypatch.setenv("KARAOKE_HOME", str(tmp_path))
    (tmp_path).mkdir(exist_ok=True)
    write_manifest(tmp_path / "manifeste.csv", [song(id="001"), song(id="002", titre="Speed")])
    r = CliRunner().invoke(cli.app, ["traiter"])
    assert r.exit_code == 0, r.output
    reports = {p.parent.name[:3]: json.loads(p.read_text()) for p in (tmp_path / "sortie").glob("*/rapport.json")}
    assert reports["001"]["statut"] == "echec" and reports["002"]["statut"] == "ok"
    assert (tmp_path / "rapport.csv").read_text(encoding="utf-8").splitlines()[1].startswith("001")
    r2 = CliRunner().invoke(cli.app, ["traiter", "--forcer", "nimporte"])
    assert r2.exit_code != 0 and "étape inconnue" in r2.output


def test_retry_is_not_a_failure():
    res = dict(BASE)
    res["lyrics"] = {"status": "a_reessayer", "seconds": 0, "result": {}, "error": "LRCLIB HTTP 503"}
    res["check"] = {"status": "bloque", "seconds": 0, "result": {}, "error": "dépend de : lyrics"}
    res["video"] = {"status": "bloque", "seconds": 0, "result": {}, "error": "dépend de : lyrics, check"}
    r = song_report(song(), res)
    assert r["statut"] == "a_reessayer" and r["risque"] == 40
