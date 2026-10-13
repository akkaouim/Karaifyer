"""Step `beats` — Beat This! beat and downbeat detection.

Inputs:  travail/<id>/input.wav.
Outputs: travail/<id>/beats.json (raw detection); result {beats: [s], downbeats: [s], nettoyage} in
         trimmed-input time, after grid.regularize (skipped beats filled, strays dropped, bar lines rebuilt).
"""
from __future__ import annotations
import json
import os

from karaoke.grid import regularize
from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, run_tool, tool_timeout
from karaoke.workspace import Workspace


def _run(ws: Workspace, upstream: dict) -> dict:
    out = ws.work / "beats.json"
    run_tool("beats", ["python", str(TOOLS_DIR / "beats" / "beats_tool.py"), str(ws.work / "input.wav"),
                       str(out), "--device", os.environ.get("KARAOKE_DEVICE", "mps")],
             timeout=tool_timeout("beats", upstream["ingest"]["duration_s"]))
    data = json.loads(out.read_text())
    if len(data["beats"]) < 8:
        raise ValueError(f"trop peu de temps détectés ({len(data['beats'])})")
    beats, downbeats, info = regularize(data["beats"], data["downbeats"])
    return {"beats": beats, "downbeats": downbeats, "nettoyage": info}


BEATS = Step(name="beats", deps=("ingest",), key=lambda ws: "beat_this-final0", run=_run,
             version="2")   # 2: grid cleanup (half-tempo gaps, stray beats, bar lines)
