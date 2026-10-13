"""Step `chords` — chord chart from the harmonic stems (madmom DeepChroma), quantised to the beat grid.

Inputs:  travail/<id>/stems/{bass,guitar,piano,other}.wav; beats result {beats, downbeats}.
Outputs: travail/<id>/harmonie.wav (mono sum of those stems: no vocals, no drums);
         sortie/<dossier>/accords.txt (4 bars per line);
         result {key, bpm, beats_per_bar, bars: [{start, chords: [[beat_index, label]]}],
         changes: [{t, label}]}, times in trimmed-input time.
"""
from __future__ import annotations
import json

import numpy as np

from karaoke import audio
from karaoke.chords import bars_from, changes, chart_text, chords_per_beat, merge_blips
from karaoke.grid import beats_per_bar, tempo_stats
from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, run_tool, tool_timeout
from karaoke.workspace import Workspace

HARMONIC = ("bass", "guitar", "piano", "other")


def _run(ws: Workspace, upstream: dict) -> dict:
    mix, sr = None, audio.SR
    for s in HARMONIC:
        x, sr = audio.read(ws.stems / f"{s}.wav")
        x = x.astype(np.float32).reshape(len(x), -1).mean(axis=1)
        mix = x if mix is None else mix[:len(x)] + x[:len(mix)]
    harm, out = ws.work / "harmonie.wav", ws.work / "chords.json"
    audio.write_wav(harm, mix / len(HARMONIC), sr)
    run_tool("chords", ["python", str(TOOLS_DIR / "chords" / "chords_tool.py"), str(harm), str(out)],
             timeout=tool_timeout("chords", upstream["ingest"]["duration_s"]))
    data = json.loads(out.read_text())
    beats, downbeats = upstream["beats"]["beats"], upstream["beats"]["downbeats"]
    bpb = beats_per_bar(beats, downbeats)
    labels = merge_blips(chords_per_beat(data["segments"], beats))
    bars = bars_from(beats, downbeats, labels, bpb)
    bpm = tempo_stats(beats)["bpm"]
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "accords.txt").write_text(
        f"{ws.song.titre} — {ws.song.artiste}\nTonalité : {data['key']} · {bpm:.0f} BPM · {bpb}/4\n\n"
        + chart_text(bars, bpb) + "\n", encoding="utf-8")
    return {"key": data["key"], "bpm": bpm, "beats_per_bar": bpb, "bars": bars, "changes": changes(beats, labels)}


CHORDS = Step(name="chords", deps=("ingest", "separate", "beats"), key=lambda ws: "madmom-deepchroma-v1",
              run=_run, artifacts=lambda ws: [ws.out / "accords.txt"])
