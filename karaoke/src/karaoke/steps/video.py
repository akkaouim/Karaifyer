"""Step `video` — synced lyrics file and lyrics video on the output timeline.

Inputs:  package result {pad_s, total_s}; lyrics result {lines}; check result {lines[].end};
         manifest row (titre, artiste).
Outputs: sortie/<dossier>/paroles.lrc (line times + pad_s), paroles.mp4 (1920x1080, no audio,
         exactly total_s long); result {duration_s, states}.
"""
from __future__ import annotations

from karaoke import lrc
from karaoke.runner import Step
from karaoke.video.render import render_video
from karaoke.video.timeline import build_states
from karaoke.workspace import Workspace


def _run(ws: Workspace, upstream: dict) -> dict:
    pad, total = upstream["package"]["pad_s"], upstream["package"]["total_s"]
    lines = upstream["lyrics"]["lines"]
    ends = {round(l["t"], 3): l["end"] for l in upstream["check"]["lines"]}
    timed = [(l["t"] + pad, ends.get(round(l["t"], 3), l["t"] + 3.0) + pad, l["text"]) for l in lines]
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "paroles.lrc").write_text(lrc.format([lrc.Line(round(s, 3), t) for s, _, t in timed]),
                                        encoding="utf-8")
    states = build_states(timed, pad, total, ws.song.titre, ws.song.artiste)
    render_video(states, ws.out / "paroles.mp4", ws.work / "frames")
    return {"duration_s": total, "states": len(states)}


VIDEO = Step(name="video", deps=("package", "lyrics", "check"),
             key=lambda ws: f"{ws.song.titre}|{ws.song.artiste}", run=_run,
             artifacts=lambda ws: [ws.out / "paroles.lrc", ws.out / "paroles.mp4"])
