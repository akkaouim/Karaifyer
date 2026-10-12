"""Step `package` — the audio deliverables, all on one timeline, laid out for the XR18 plan.

Inputs:  manifest row (retirer, decompte_mesures); travail/<id>/input.wav; stems/*.wav (Demucs);
         stems/lead.wav, stems/backing.wav (vocals_split); beats result {beats, downbeats}.
Outputs: sortie/<dossier>/
           accompagnement.flac  stereo, every stem except vocals/guitar/bass/piano/drums (XR18 17-18)
           guide_voix.flac      mono lead vocals (11, in-ears)     back_vocals.flac  mono backing vocals (16)
           guitare/basse/piano/batterie.flac  mono parts (12-15)  clic.flac  mono click (10)
           pistes/<stem>.flac   the 6 Demucs stems, stereo (backup)
           temps.csv            temps_s, premier_temps, source
         Every audio file starts at the same zero and has exactly the same length: pad + input.
         result {pad_s, total_s, beats_per_bar, bpm, variation_pct, stable, gain_db, live, faders}:
         faders = XR18 fader CC per part (0 for parts in `retirer`, 0 dB for the rest).
"""
from __future__ import annotations
import csv

import numpy as np

from karaoke import audio, grid
from karaoke.manifest import STEMS
from karaoke.runner import Step
from karaoke.workspace import Workspace
from karaoke.xair import xair_cc

# Parts that get their own XR18 channel (docs/karaoke/ableton-xr18-decisions.md); the accompaniment
# is whatever is left. File stem -> Demucs stem, all written mono.
CHANNEL_FILES = {"guitare": "guitar", "basse": "bass", "piano": "piano", "batterie": "drums"}
ROUTED = {"vocals", *CHANNEL_FILES.values()}


def _pad(x: np.ndarray, pad: int, total: int) -> np.ndarray:
    out = np.zeros((total,) + x.shape[1:], np.float32)
    n = min(len(x), total - pad)
    out[pad:pad + n] = x[:n]
    return out


def _key(ws: Workspace) -> str:
    return f"retirer={';'.join(sorted(ws.song.retirer))}|decompte={ws.song.decompte_mesures}"


def _artifacts(ws: Workspace):
    return ([ws.out / f for f in ("accompagnement.flac", "clic.flac", "guide_voix.flac", "back_vocals.flac",
                                  "temps.csv")]
            + [ws.out / f"{n}.flac" for n in CHANNEL_FILES]
            + [ws.out / "pistes" / f"{s}.flac" for s in STEMS])


def _run(ws: Workspace, upstream: dict) -> dict:
    beats, downbeats = upstream["beats"]["beats"], upstream["beats"]["downbeats"]
    x, sr = audio.read(ws.work / "input.wav")
    plan = grid.countin_plan(beats, downbeats, ws.song.decompte_mesures, sr)
    pad = int(round(plan.pad_s * sr))
    total = pad + len(x)
    stats = grid.tempo_stats(beats)
    stems = {s: audio.read(ws.stems / f"{s}.wav")[0] for s in STEMS}

    kept = [stems[s] for s in STEMS if s not in ROUTED]
    acc = np.sum(kept, axis=0) if kept else np.zeros_like(x)
    peak = float(np.abs(acc).max()) if acc.size else 0.0
    gain = 0.999 / peak if peak > 0.999 else 1.0
    out = ws.out
    (out / "pistes").mkdir(parents=True, exist_ok=True)
    audio.write_flac(out / "accompagnement.flac", _pad(acc * gain, pad, total), sr)
    lead, _ = audio.read(ws.stems / "lead.wav")
    backing, _ = audio.read(ws.stems / "backing.wav")
    audio.write_flac(out / "guide_voix.flac", _pad(lead.mean(axis=1), pad, total), sr)
    audio.write_flac(out / "back_vocals.flac", _pad(backing.mean(axis=1), pad, total), sr)
    for name, stem in CHANNEL_FILES.items():
        audio.write_flac(out / f"{name}.flac", _pad(stems[stem].mean(axis=1), pad, total), sr)
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
            "gain_db": float(20 * np.log10(gain)),
            "live": [n for n, stem in CHANNEL_FILES.items() if stem in ws.song.retirer],
            # XR18 fader defaults: parts played live start at zero, everything else at 0 dB
            "faders": {**{n: (0 if stem in ws.song.retirer else xair_cc(0.0)) for n, stem in CHANNEL_FILES.items()},
                       "back_vocals": xair_cc(0.0), "accompagnement": xair_cc(0.0)}}


PACKAGE = Step(name="package", deps=("ingest", "separate", "beats", "vocals_split"), key=_key, run=_run,
               artifacts=_artifacts,
               version="4")   # 4: XR18 channel files, accompaniment = other, fader defaults
