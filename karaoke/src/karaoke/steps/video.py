"""Step `video` — synced lyrics file and lyrics video on the output timeline.

Inputs:  package result {pad_s, total_s}; beats result {beats}; lyrics result {lines[].words[].syllables};
         check result {lines[].end}; chords result {changes, bars} (above each line; 4-bar row in instrumentals); manifest row.
Outputs: sortie/<dossier>/paroles.lrc (line times + pad_s), paroles.mp4 (1920x1080, no audio,
         exactly total_s long); result {duration_s, states}.
"""
from __future__ import annotations
from dataclasses import replace

from karaoke import lrc
from karaoke.runner import Step
from karaoke.video.render import render_video
from karaoke.video.timeline import TimedLine, build_states, line_chords, with_chart
from karaoke.workspace import Workspace


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
    states = build_states(timed, pad, total, ws.song.titre, ws.song.artiste, beats)
    chords = upstream.get("chords", {})
    bars = [(b["start"] + pad, " ".join(c for _, c in b["chords"])) for b in chords.get("bars", [])]
    states = with_chart(states, bars, 4)
    render_video(states, ws.out / "paroles.mp4", ws.work / "frames")
    return {"duration_s": total, "states": len(states)}


VIDEO = Step(name="video", deps=("package", "beats", "lyrics", "check", "chords"),
             key=lambda ws: f"{ws.song.titre}|{ws.song.artiste}", run=_run,
             artifacts=lambda ws: [ws.out / "paroles.lrc", ws.out / "paroles.mp4"],
             version="5")   # 3: syllable colouring, 4-3-2-1 countdown; 4: chords above the line; 5: chart row in instrumentals
