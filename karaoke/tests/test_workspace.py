from karaoke.workspace import slug, Workspace
from test_manifest import song


def test_slug():
    assert slug("À ma place") == "a-ma-place"
    assert slug("Zazie/Axel Bauer") == "zazie-axel-bauer"
    assert slug("Dis, quand reviendras-tu ?") == "dis-quand-reviendras-tu"
    assert slug("Les copains d’abord") == "les-copains-d-abord"
    assert slug("") == "sans-titre"
    assert len(slug("x" * 100)) == 40


def test_paths(cfg):
    ws = Workspace(cfg, song(id="003", titre="À ma place", artiste="Zazie/Axel Bauer"))
    assert ws.work == cfg.travail / "003"
    assert ws.out == cfg.sortie / "003_zazie-axel-bauer_a-ma-place"
    assert ws.stems == ws.work / "stems"


def test_markers_and_log(cfg):
    ws = Workspace(cfg, song())
    assert ws.read_marker("ingest") is None
    ws.write_marker("ingest", {"key": "k1", "result": {"offset_s": 0.1}})
    assert ws.read_marker("ingest")["result"]["offset_s"] == 0.1
    ws.log("bonjour")
    assert "bonjour" in (ws.work / "journal.log").read_text(encoding="utf-8")
