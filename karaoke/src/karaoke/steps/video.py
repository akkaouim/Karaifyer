"""Step `video` — synced lyrics file and lyrics video on the output timeline.

Inputs:  package result {pad_s, total_s}; beats result {beats}; lyrics result {lines[].words[].syllables};
         check result {lines[].end}; chords result {changes, bars} (above each line; 4-bar row in instrumentals); manifest row.
Outputs: sortie/<dossier>/paroles.lrc (line times + pad_s), paroles.mp4 (1920x1080, no audio,
         exactly total_s long); result {duration_s, states}.
"""
from __future__ import annotations
import json
import os
import subprocess
from dataclasses import replace
from pathlib import Path

from karaoke import lrc
from karaoke.runner import Step
from karaoke.video.render import render_video
from karaoke.video.timeline import TimedLine, build_states, line_chords, with_chart
from karaoke.workspace import Workspace


LINE_LEAD_S = 0.5   # a line appears this long before its first word is sung (Michel: a consistent warning)
# Karaifyer's renderer (one Swift renderer for the live Lecteur, its export and this step): the app passes it in
# KARAOKE_RENDERER; a built checkout has it here. Without it, the Python renderer (old layout, no animation).
DEFAULT_RENDERER = Path(__file__).resolve().parents[4] / "karaifyer" / ".build" / "release" / "karaifyer-render"


def layout() -> str:
    """« grille » (bar grid above, lyrics only below — the default) or « paroles » (chords over the lyrics)."""
    v = os.environ.get("KARAOKE_VIDEO_LAYOUT", "grille")
    return v if v in ("grille", "paroles") else "grille"


def renderer() -> Path | None:
    for p in (os.environ.get("KARAOKE_RENDERER"), str(DEFAULT_RENDERER)):
        if p and Path(p).is_file() and os.access(p, os.X_OK):
            return Path(p)
    return None


def scene(ws: Workspace, states, beats: list[float], chords: dict, pad: float, total: float) -> dict:
    """The video as data for the Swift renderer (sortie/<dossier>/video.json), all times in show time."""
    src = chords.get("bars", [])
    starts = [b["start"] + pad for b in src]
    bars = []
    for k, b in enumerate(src):
        s, e = starts[k], starts[k + 1] if k + 1 < len(starts) else total
        bars.append({"start": round(s, 3), "beats": max(1, sum(1 for t in beats if s - 1e-3 <= t < e - 1e-3)),
                     "chords": [[i, c] for i, c in b["chords"]]})
    st = [{"start": round(x.start, 3), "end": round(x.end, 3), "kind": x.kind, "current": x.current, "next": x.next,
           "countdown": x.countdown, "lit": x.lit, "chords": [list(c) for c in x.chords], "chart": list(x.chart),
           "chart_pos": x.chart_pos, "next_chords": [list(c) for c in x.next_chords]} for x in states]
    return {"version": 1, "layout": layout(), "titre": ws.song.titre, "artiste": ws.song.artiste,
            "key": chords.get("key"), "pad_s": pad, "total_s": total, "beats": [round(b, 3) for b in beats],
            "bars": bars, "states": st}


def _timed_line(line: dict, end: float, pad: float) -> TimedLine:
    """Line in output time, each syllable mapped to the number of characters it lights up."""
    text = " ".join(line["text"].split())
    syllables, offset = [], 0
    for word in line.get("words", []):
        idx = text.find(word["text"], offset)
        offset = idx if idx >= 0 else offset
        done = 0
        for syl in word["syllables"]:
            done += len(syl["text"])
            syllables.append((syl["start"] + pad, offset + done))
        offset += len(word["text"]) + 1
    if not syllables:                     # no word timing: light the whole line at its start
        syllables = [(line["t"] + pad, len(text))]
    word_ends = [w["end"] for w in line.get("words", []) if w.get("end") is not None]
    if word_ends:   # the last word is precise; vocal activity runs on with backing vocals and reverb
        end = min(end, max(word_ends))
    return TimedLine(line["t"] + pad, end + pad, text, syllables)


def _run(ws: Workspace, upstream: dict) -> dict:
    pad, total = upstream["package"]["pad_s"], upstream["package"]["total_s"]
    lines = upstream["lyrics"]["lines"]
    ends = {round(l["t"], 3): l["end"] for l in upstream["check"]["lines"]}
    timed = [_timed_line(l, ends.get(round(l["t"], 3), l["t"] + 3.0), pad) for l in lines]
    changes = [{"t": c["t"] + pad, "label": c["label"]} for c in upstream.get("chords", {}).get("changes", [])]
    timed = [replace(t, chords=tuple(line_chords(t, changes))) for t in timed]
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "paroles.lrc").write_text(lrc.format([lrc.Line(round(t.start, 3), t.text) for t in timed],
                                                   decalage=pad), encoding="utf-8")
    beats = [b + pad for b in upstream["beats"]["beats"]]
    states = build_states(timed, pad, total, ws.song.titre, ws.song.artiste, beats, lead_s=LINE_LEAD_S)
    chords = upstream.get("chords", {})
    bars = [(b["start"] + pad, " ".join(c for _, c in b["chords"])) for b in chords.get("bars", [])]
    states = with_chart(states, bars, 4)
    sc = scene(ws, states, beats, chords, pad, total)
    (ws.out / "video.json").write_text(json.dumps(sc, ensure_ascii=False), encoding="utf-8")
    r = renderer()
    if r:
        subprocess.run([str(r), str(ws.out / "video.json"), str(ws.out / "paroles.mp4")], check=True,
                       capture_output=True)
    else:
        ws.log("rendu vidéo : moteur Python (sans animation)")
        render_video(states, ws.out / "paroles.mp4", ws.work / "frames")
    return {"duration_s": total, "states": len(states)}


VIDEO = Step(name="video", deps=("package", "beats", "lyrics", "check", "chords"),
             key=lambda ws: f"{ws.song.titre}|{ws.song.artiste}|{layout()}|{'swift' if renderer() else 'python'}", run=_run,
             artifacts=lambda ws: [ws.out / "paroles.lrc", ws.out / "paroles.mp4", ws.out / "video.json"],
             version="9")   # 6: line ends at last word, chord row from a 1-bar gap, preview chords; 7: lines appear 0.5 s ahead; 8: N.C. shown; 9: scene video.json, Swift renderer (grid + lyrics, neon)
