"""Step `beats` — Beat This! beat and downbeat detection.

Inputs:  travail/<id>/input.wav.
Outputs: travail/<id>/beats.json; result {beats: [s], downbeats: [s]} in trimmed-input time.
"""
from __future__ import annotations
import json
import os

from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, run_tool
from karaoke.workspace import Workspace


def _run(ws: Workspace, upstream: dict) -> dict:
    out = ws.work / "beats.json"
    run_tool("beats", ["python", str(TOOLS_DIR / "beats" / "beats_tool.py"), str(ws.work / "input.wav"),
                       str(out), "--device", os.environ.get("KARAOKE_DEVICE", "mps")])
    data = json.loads(out.read_text())
    if len(data["beats"]) < 8:
        raise ValueError(f"trop peu de temps détectés ({len(data['beats'])})")
    return {"beats": data["beats"], "downbeats": data["downbeats"]}


BEATS = Step(name="beats", deps=("ingest",), key=lambda ws: "beat_this-final0", run=_run)
