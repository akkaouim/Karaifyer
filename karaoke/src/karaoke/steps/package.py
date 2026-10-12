"""Step `package` — the audio deliverables, all on one timeline.

Inputs:  manifest row (retirer, decompte_mesures); travail/<id>/input.wav; stems/*.wav;
         beats result {beats, downbeats}.
Outputs: sortie/<dossier>/accompagnement.flac (stereo, all stems except vocals and `retirer`),
         clic.flac (mono, count-in + detected beats), guide_voix.flac (mono vocals),
         pistes/<stem>.flac (6, stereo), temps.csv (temps_s, premier_temps, source).
         Every audio file starts at the same zero and has exactly the same length:
         pad (silent count-in) + input.
         result {pad_s, total_s, beats_per_bar, bpm, variation_pct, stable, removed, gain_db}.
"""
from __future__ import annotations
import csv

import numpy as np

from karaoke import audio, grid
from karaoke.manifest import STEMS
from karaoke.runner import Step
from karaoke.workspace import Workspace


def _pad(x: np.ndarray, pad: int, total: int) -> np.ndarray:
    out = np.zeros((total,) + x.shape[1:], np.float32)
    n = min(len(x), total - pad)
    out[pad:pad + n] = x[:n]
    return out


def _key(ws: Workspace) -> str:
    return f"retirer={';'.join(sorted(ws.song.retirer))}|decompte={ws.song.decompte_mesures}"


def _artifacts(ws: Workspace):
    return ([ws.out / f for f in ("accompagnement.flac", "clic.flac", "guide_voix.flac", "temps.csv")]
            + [ws.out / "pistes" / f"{s}.flac" for s in STEMS])


def _run(ws: Workspace, upstream: dict) -> dict:
    beats, downbeats = upstream["beats"]["beats"], upstream["beats"]["downbeats"]
    x, sr = audio.read(ws.work / "input.wav")
    plan = grid.countin_plan(beats, downbeats, ws.song.decompte_mesures, sr)
    pad = int(round(plan.pad_s * sr))
    total = pad + len(x)
    stats = grid.tempo_stats(beats)
    removed = sorted({"vocals", *ws.song.retirer})
    stems = {s: audio.read(ws.stems / f"{s}.wav")[0] for s in STEMS}

    kept = [stems[s] for s in STEMS if s not in removed]
    acc = np.sum(kept, axis=0) if kept else np.zeros_like(x)
    peak = float(np.abs(acc).max()) if acc.size else 0.0
    gain = 0.999 / peak if peak > 0.999 else 1.0
    out = ws.out
    (out / "pistes").mkdir(parents=True, exist_ok=True)
    audio.write_flac(out / "accompagnement.flac", _pad(acc * gain, pad, total), sr)
    audio.write_flac(out / "guide_voix.flac", _pad(stems["vocals"].mean(axis=1), pad, total), sr)
    for s in STEMS:
        audio.write_flac(out / "pistes" / f"{s}.flac", _pad(stems[s], pad, total), sr)
    events = grid.click_events(plan, beats, downbeats)
    audio.write_flac(out / "clic.flac", grid.render_click(events, total, sr), sr)

    n_count = len(plan.times_in)
    with open(out / "temps.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["temps_s", "premier_temps", "source"])
        for i, (t, accent) in enumerate(events):
            w.writerow([f"{t:.6f}", int(accent), "decompte" if i < n_count else "detecte"])
    return {"pad_s": pad / sr, "total_s": total / sr, "beats_per_bar": plan.beats_per_bar,
            "bpm": stats["bpm"], "variation_pct": stats["variation_pct"], "stable": stats["stable"],
            "removed": removed, "gain_db": float(20 * np.log10(gain))}


PACKAGE = Step(name="package", deps=("ingest", "separate", "beats"), key=_key, run=_run, artifacts=_artifacts,
               version="2")   # 2: tempo variation measured over 16-beat spans
