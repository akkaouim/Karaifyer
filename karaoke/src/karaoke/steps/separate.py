"""Step `separate` — Demucs htdemucs_6s stem separation.

Inputs:  travail/<id>/input.wav.
Outputs: travail/<id>/stems/{vocals,drums,bass,guitar,piano,other}.wav (float32);
         result {stems, device}. Device from env KARAOKE_DEVICE (default mps).
"""
from __future__ import annotations
import os
import shutil

from karaoke.manifest import STEMS
from karaoke.runner import Step
from karaoke.tools import run_tool
from karaoke.workspace import Workspace


def _run(ws: Workspace, upstream: dict) -> dict:
    device = os.environ.get("KARAOKE_DEVICE", "mps")
    tmp = ws.work / "demucs_tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    run_tool("separate", ["demucs", "-n", "htdemucs_6s", "-d", device, "--float32", "-o", str(tmp),
                          "--filename", "{stem}.{ext}", str(ws.work / "input.wav")])
    ws.stems.mkdir(parents=True, exist_ok=True)
    for stem in STEMS:
        shutil.move(str(tmp / "htdemucs_6s" / f"{stem}.wav"), ws.stems / f"{stem}.wav")
    shutil.rmtree(tmp, ignore_errors=True)
    return {"stems": list(STEMS), "device": device}


SEPARATE = Step(name="separate", deps=("ingest",), key=lambda ws: "htdemucs_6s", run=_run,
                artifacts=lambda ws: [ws.stems / f"{s}.wav" for s in STEMS])
