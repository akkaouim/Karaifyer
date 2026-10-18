"""Step `chords` — chord chart from the harmonic stems (madmom DeepChroma), quantised to the beat grid.

Inputs:  travail/<id>/stems/{bass,guitar,piano,other}.wav; beats result {beats, downbeats}.
Outputs: travail/<id>/harmonie.wav (mono sum of those stems: no vocals, no drums);
         sortie/<dossier>/accords.txt (4 bars per line);
         result {key, bpm, beats_per_bar, bars: [{start, chords: [[beat_index, label]]}],
         changes: [{t, label}]}, times in trimmed-input time.
"""
from __future__ import annotations
import hashlib
import json

import numpy as np

from karaoke import audio
from karaoke.chords import (bars_from, changes, chart_text, chords_per_beat, expand, merge_blips, parse_cell,
                             parse_chart, spell)
from karaoke.grid import beats_per_bar, tempo_stats
from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, ToolError, run_tool, tool_timeout
from karaoke.workspace import Workspace

HARMONIC = ("bass", "guitar", "piano", "other")


def _correction(ws: Workspace, beats: list[float], downbeats: list[float], bpb: int):
    """Michel's accords/<id>.txt: chords replaced bar by bar, bar timing kept from the detection."""
    p = ws.cfg.accords / f"{ws.song.id}.txt"
    key, cells = parse_chart(p.read_text(encoding="utf-8"))
    grid = bars_from(beats, downbeats, ["N.C."] * len(beats), bpb)
    if len(cells) != len(grid):
        raise ValueError(f"accords/{ws.song.id}.txt : {len(cells)} mesures, la détection en a {len(grid)}")
    starts = [beats.index(g["start"]) for g in grid] + [len(beats)]
    bars = [{"start": g["start"], "chords": parse_cell(c, bpb)} for g, c in zip(grid, cells)]
    labels = expand(bars, bpb, [b - a for a, b in zip(starts, starts[1:])])
    return key or "C major", bars, labels


def _run(ws: Workspace, upstream: dict) -> dict:
    beats, downbeats = upstream["beats"]["beats"], upstream["beats"]["downbeats"]
    up = upstream["beats"]
    bpb = up.get("beats_per_bar") or beats_per_bar(beats, downbeats)
    signature, swing = up.get("signature"), bool(up.get("swing", False))
    (ws.out / "accords.txt").unlink(missing_ok=True)
    if (ws.cfg.accords / f"{ws.song.id}.txt").exists():
        key, bars, labels = _correction(ws, beats, downbeats, bpb)
        source = "correction"
    else:
        mix, sr = None, audio.SR
        for s in HARMONIC:
            x, sr = audio.read(ws.stems / f"{s}.wav")
            x = x.astype(np.float32).reshape(len(x), -1).mean(axis=1)
            mix = x if mix is None else mix[:len(x)] + x[:len(mix)]
        harm, out = ws.work / "harmonie.wav", ws.work / "chords.json"
        audio.write_wav(harm, mix / len(HARMONIC), sr)
        try:
            run_tool("chords", ["python", str(TOOLS_DIR / "chords" / "chords_tool.py"), str(harm), str(out)],
                     timeout=tool_timeout("chords", upstream["ingest"]["duration_s"]))
            data = json.loads(out.read_text())
        except (ToolError, OSError, ValueError) as e:
            # The chart is a draft: never block the video or the set. No accords.txt → retried next run.
            return {"key": None, "bpm": 0.0, "beats_per_bar": 4, "bars": [], "changes": [],
                    "source": "detection", "erreur": str(e)[-300:], "signature": None, "swing": False}
        key = data["key"]
        labels = spell(merge_blips(chords_per_beat(data["segments"], beats)), key)
        bars = bars_from(beats, downbeats, labels, bpb)
        source = "detection"
    bpm = tempo_stats(beats)["bpm"]
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "accords.txt").write_text(
        f"{ws.song.titre} — {ws.song.artiste}\nTonalité : {key} · {bpm:.0f} BPM · {signature or f'{bpb}/4'}\n\n"
        + chart_text(bars, bpb) + "\n", encoding="utf-8")
    return {"key": key, "bpm": bpm, "beats_per_bar": bpb, "bars": bars, "changes": changes(beats, labels),
            "source": source, "signature": signature, "swing": swing}


def _key(ws: Workspace) -> str:
    p = ws.cfg.accords / f"{ws.song.id}.txt"
    return "madmom-deepchroma-v1|spell-by-key|" + (hashlib.sha1(p.read_bytes()).hexdigest() if p.exists() else "-")


CHORDS = Step(name="chords", deps=("ingest", "separate", "beats"), key=_key, run=_run,
              artifacts=lambda ws: [ws.out / "accords.txt"],
              version="2")   # 2: corrected charts (accords/<id>.txt), per-beat cells
