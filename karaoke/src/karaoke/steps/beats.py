"""Step `beats` — Beat This! beat and downbeat detection.

Inputs:  travail/<id>/input.wav.
Outputs: travail/<id>/beats.json (raw detection); result {beats: [s], downbeats: [s], nettoyage} in
         trimmed-input time, after grid.regularize (skipped beats filled, strays dropped, bar lines rebuilt),
         then Michel's mesures/<id>.json (barfix: signature, swing, pinned bar lines). Also
         downbeats_detectees / beats_per_bar_detecte (before the fix), beats_per_bar, bpm, signature, swing.
"""
from __future__ import annotations
import hashlib
import json
import os

from karaoke import barfix
from karaoke.grid import beats_per_bar, regularize, tempo_stats
from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, run_tool, tool_timeout
from karaoke.workspace import Workspace


def _fix_path(ws: Workspace):
    return ws.cfg.mesures / f"{ws.song.id}.json"


def _run(ws: Workspace, upstream: dict) -> dict:
    out, seen = ws.work / "beats.json", ws.work / "beats.source.json"
    # A fix-only change must not re-run the detection; new audio (new mp3, new trim) must.
    src = ws.work / "input.wav"
    stamp = json.dumps([src.stat().st_size, src.stat().st_mtime_ns] if src.exists() else None)
    if not (out.exists() and seen.exists() and seen.read_text() == stamp):
        run_tool("beats", ["python", str(TOOLS_DIR / "beats" / "beats_tool.py"), str(ws.work / "input.wav"),
                           str(out), "--device", os.environ.get("KARAOKE_DEVICE", "mps")],
                 timeout=tool_timeout("beats", upstream["ingest"]["duration_s"]))
        seen.write_text(stamp)
    data = json.loads(out.read_text())
    if len(data["beats"]) < 8:
        raise ValueError(f"trop peu de temps détectés ({len(data['beats'])})")
    beats, detected, info = regularize(data["beats"], data["downbeats"])
    detected = barfix.on_beat(beats, detected)
    bpb, bpm = beats_per_bar(beats, detected), tempo_stats(beats)["bpm"]
    fix = barfix.load(_fix_path(ws))
    downbeats, n = barfix.apply_fix(beats, detected, fix, bpb, bpm)
    return {"beats": beats, "downbeats": downbeats, "nettoyage": info, "downbeats_detectees": detected,
            "beats_per_bar_detecte": bpb, "beats_per_bar": n, "bpm": bpm,
            "signature": fix["signature"], "swing": fix["swing"]}


def _key(ws: Workspace) -> str:
    """Unchanged for a song without a fix file, so unfixed songs never re-run."""
    p = _fix_path(ws)
    return "beat_this-final0" + (f"|{hashlib.sha1(p.read_bytes()).hexdigest()}" if p.exists() else "")


BEATS = Step(name="beats", deps=("ingest",), key=_key, run=_run,
             version="2")   # 2: grid cleanup (half-tempo gaps, stray beats, bar lines); fix file via the key
