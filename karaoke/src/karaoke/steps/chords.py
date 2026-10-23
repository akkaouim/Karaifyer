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
import os

import numpy as np

from karaoke import audio
from karaoke.chords import (bars_from, changes, chart_text, chords_per_beat, expand, merge_blips, parse_cell,
                             parse_chart, spell)
from karaoke.grid import beats_per_bar, tempo_stats
from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, ToolError, run_tool, tool_timeout
from karaoke.workspace import Workspace

HARMONIC = ("bass", "guitar", "piano", "other")
# Chord detector, chosen in Karaifyer's Réglages (KARAOKE_ACCORDS): tool project, wrapper script, label.
ENGINES = {"jiang": ("chords_dl", "jiang_tool.py", "Jiang 2019"), "btc": ("chords_dl", "btc_tool.py", "BTC"),
           "ace": ("chords_ace", "ace_tool.py", "consonance-ACE"), "madmom": ("chords", "chords_tool.py", "madmom")}
SILENT_DBFS = -45.0     # a harmonic stem quieter than this (a cappella song): listen to the full mix instead


def engine() -> str:
    e = os.environ.get("KARAOKE_ACCORDS", "jiang")
    return e if e in ENGINES else "jiang"


def _detect(ws: Workspace, wav, duration: float) -> tuple[list, str]:
    """(segments from the chosen engine, key from madmom's CNN key model)."""
    project, script, _ = ENGINES[engine()]
    out = ws.work / "chords.json"
    t = "chords" if project == "chords" else "chords_engine"
    run_tool(project, ["python", str(TOOLS_DIR / project / script), str(wav), str(out)], timeout=tool_timeout(t, duration))
    data = json.loads(out.read_text())
    if project == "chords":
        return data["segments"], data["key"]
    kout = ws.work / "chords_madmom.json"
    run_tool("chords", ["python", str(TOOLS_DIR / "chords" / "chords_tool.py"), str(wav), str(kout)],
             timeout=tool_timeout("chords", duration))
    return data["segments"], json.loads(kout.read_text())["key"]


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
        source, entree = "correction", None
    else:
        mix, sr = None, audio.SR
        for s in HARMONIC:
            x, sr = audio.read(ws.stems / f"{s}.wav")
            x = x.astype(np.float32).reshape(len(x), -1).mean(axis=1)
            mix = x if mix is None else mix[:len(x)] + x[:len(mix)]
        harm = ws.work / "harmonie.wav"
        h = mix / len(HARMONIC)
        audio.write_wav(harm, h, sr)
        rms = float(np.sqrt(np.mean(np.square(h)))) if len(h) else 0.0
        silent = rms <= 0 or 20 * np.log10(rms) < SILENT_DBFS
        wav, entree = (ws.work / "input.wav", "mix") if silent else (harm, "harmonie")
        label = ENGINES[engine()][2]
        failed = {"key": None, "bpm": 0.0, "beats_per_bar": 4, "bars": [], "changes": [], "source": "detection",
                  "signature": None, "swing": False, "moteur": label, "entree": entree}
        try:
            segments, key = _detect(ws, wav, upstream["ingest"]["duration_s"])
        except (ToolError, OSError, ValueError, KeyError) as e:
            # The chart is a draft: never block the video or the set. No accords.txt → retried next run.
            return {**failed, "erreur": str(e)[-300:]}
        if not segments:
            return {**failed, "erreur": "aucun accord détecté"}
        ws.log(f"accords : {label} ({entree})")
        labels = spell(merge_blips(chords_per_beat(segments, beats)), key)
        bars = bars_from(beats, downbeats, labels, bpb)
        source = "detection"
    bpm = tempo_stats(beats)["bpm"]
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "accords.txt").write_text(
        f"{ws.song.titre} — {ws.song.artiste}\nTonalité : {key} · {bpm:.0f} BPM · {signature or f'{bpb}/4'}\n\n"
        + chart_text(bars, bpb) + "\n", encoding="utf-8")
    return {"key": key, "bpm": bpm, "beats_per_bar": bpb, "bars": bars, "changes": changes(beats, labels),
            "source": source, "signature": signature, "swing": swing, "moteur": ENGINES[engine()][2],
            "entree": entree}


def _key(ws: Workspace) -> str:
    p = ws.cfg.accords / f"{ws.song.id}.txt"
    return f"{engine()}|spell-by-key|v2|" + (hashlib.sha1(p.read_bytes()).hexdigest() if p.exists() else "-")


CHORDS = Step(name="chords", deps=("ingest", "separate", "beats"), key=_key, run=_run,
              artifacts=lambda ws: [ws.out / "accords.txt"],
              version="3")   # 2: corrected charts (accords/<id>.txt), per-beat cells; 3: moteur au choix (KARAOKE_ACCORDS), vocabulaire étendu
