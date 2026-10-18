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


def test_beats_step_applies_the_fix_file_and_reuses_the_raw_detection(cfg, monkeypatch):
    from karaoke.steps import beats as B
    from karaoke.workspace import Workspace
    from test_manifest import song
    full = [round(0.5 * i, 4) for i in range(32)]
    calls = []
    def fake(tool, args, **kw):
        calls.append(tool)
        Path(args[3]).write_text(json.dumps({"beats": full, "downbeats": full[::4]}))
    monkeypatch.setattr(B, "run_tool", fake)
    s = song()
    ws = Workspace(cfg, s)
    ws.work.mkdir(parents=True, exist_ok=True)
    assert B.BEATS.key(ws) == "beat_this-final0"                        # no fix file: unchanged key
    B.BEATS.run(ws, {"ingest": {"duration_s": 16.0}})
    cfg.mesures.mkdir(parents=True, exist_ok=True)
    (cfg.mesures / f"{s.id}.json").write_text(json.dumps({"signature": "3/4", "swing": True, "pins": []}))
    assert B.BEATS.key(ws).startswith("beat_this-final0|")
    r = B.BEATS.run(ws, {"ingest": {"duration_s": 16.0}})
    assert calls == ["beats"]                                            # raw beats.json reused
    assert r["downbeats"] == full[::3] and r["beats_per_bar"] == 3 and r["signature"] == "3/4" and r["swing"]
    assert r["downbeats_detectees"] == full[::4] and r["beats_per_bar_detecte"] == 4 and r["bpm"] == 120.0
