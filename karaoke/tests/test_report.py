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


def test_load_reports_only_current_manifest_folders(cfg):
    from karaoke.report import load_reports
    from karaoke.workspace import Workspace
    keep = Workspace(cfg, song(id="001"))
    stale = cfg.sortie / "001_ancien-nom_titre"
    other = cfg.sortie / "099_retire_du-manifeste"
    for d in (keep.out, stale, other):
        d.mkdir(parents=True)
        (d / "rapport.json").write_text(json.dumps({"id": d.name[:3], "risque": 0}), encoding="utf-8")
    assert [r["id"] for r in load_reports(cfg.sortie, [keep.out])] == ["001"]


def test_word_rate_alert():
    res = dict(BASE)
    res["check"] = ok({"rate": 1.0, "drift_ms": 8.0, "word_rate": 0.8})
    r = song_report(song(), res)
    assert any("mots" in a and "80" in a for a in r["alertes"]) and r["risque"] > 0
    assert r["paroles"]["taux_mots"] == 0.8


def test_tempo_alert_says_how_much_of_the_song_is_out_of_tempo():
    res = {**BASE, "package": {"status": "fait", "result": {"bpm": 120, "variation_pct": 50.7,
                                                             "steady_share": 0.75, "stable": False}}}
    r = song_report(song(), res)
    assert "tempo instable (25 % du morceau hors tempo)" in r["alertes"]
    assert r["tempo"]["steady_share"] == 0.75


def test_drift_none_means_no_click_alert():
    res = {**BASE, "check": {"status": "fait", "result": {**BASE["check"]["result"], "drift_ms": None}}}
    assert not any("clic" in a for a in song_report(song(), res)["alertes"])


def test_package_passes_the_steady_share():
    import pathlib
    src = pathlib.Path(__file__).parents[1] / "src/karaoke/steps/package.py"
    from karaoke.steps.package import PACKAGE
    assert '"steady_share": stats["steady_share"]' in src.read_text() and PACKAGE.version == "6"


def test_lyrics_alert_only_when_sung_words_are_off():
    # line times now follow the sung words: the line-rate measure no longer raises an alert
    good_words = {**BASE, "check": ok({"rate": 0.3, "word_rate": 0.97, "drift_ms": 8.0})}
    assert song_report(song(), good_words)["alertes"] == []
    bad_words = {**BASE, "check": ok({"rate": 0.95, "word_rate": 0.82, "drift_ms": 8.0})}
    assert "paroles à vérifier : 82 % des mots calés (±0,5 s)" in song_report(song(), bad_words)["alertes"]



def test_transcribed_lyrics_are_flagged_for_proofreading():
    res = {**BASE, "lyrics": ok({"source": "transcription", "lines": [{}] * 10})}
    r = song_report(song(), res)
    assert "paroles transcrites automatiquement : à relire" in r["alertes"] and r["statut"] == "alerte"


def test_report_names_the_chord_engine_and_flags_an_empty_chart():
    from karaoke.report import song_report
    from test_manifest import song
    ok = {"status": "fait", "result": {"source": "detection", "moteur": "Jiang 2019", "entree": "harmonie", "bars": [1]}}
    r = song_report(song(), {"chords": ok})
    assert r["accords"] == {"source": "detection", "moteur": "Jiang 2019", "entree": "harmonie"}
    empty = {"status": "fait", "result": {"moteur": "BTC", "bars": [], "erreur": "aucun accord détecté"}}
    assert "chords : BTC — aucun accord détecté (grille vide)" in song_report(song(), {"chords": empty})["alertes"]
