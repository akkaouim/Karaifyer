import json
from pathlib import Path


def test_beats_step_cleans_the_detected_grid(cfg, monkeypatch):
    from karaoke.steps import beats as B
    from karaoke.workspace import Workspace
    from test_manifest import song
    full = [round(1.0 + 0.42 * i, 4) for i in range(64)]
    detected = full[:16] + full[16:48:2] + full[48:]          # half tempo in the middle (044)
    def fake(tool, args, **kw):
        Path(args[3]).write_text(json.dumps({"beats": detected, "downbeats": full[::4]}))
    monkeypatch.setattr(B, "run_tool", fake)
    ws = Workspace(cfg, song())
    ws.work.mkdir(parents=True, exist_ok=True)
    r = B.BEATS.run(ws, {"ingest": {"duration_s": 30.0}})
    assert len(r["beats"]) == 64 and r["downbeats"] == full[::4]
    assert r["nettoyage"] == {"added": 16, "removed": 0, "bars_regularized": False}
    assert B.BEATS.version == "2"
