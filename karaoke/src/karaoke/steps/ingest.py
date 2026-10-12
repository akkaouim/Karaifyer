"""Step `ingest` — input check and normalisation.

Inputs:  manifest row (fichier, duree_ref_s).
Outputs: travail/<id>/input.wav (44.1 kHz stereo float32, leading silence removed);
         result {file_duration_s, ref_delta_s, duration_alert, offset_s, duration_s}.
         offset_s = seconds removed from the start (original time = t_in + offset_s).
"""
from __future__ import annotations

import numpy as np

from karaoke import audio
from karaoke.runner import Step
from karaoke.workspace import Workspace

DURATION_ALERT_S = 2.0
PREROLL_S = 0.010


def first_sound_frame(x: np.ndarray, threshold_db: float = -60.0) -> int | None:
    thr = 10 ** (threshold_db / 20)
    idx = np.flatnonzero(np.max(np.abs(x), axis=1) > thr)
    return int(idx[0]) if idx.size else None


def _key(ws: Workspace) -> str:
    p = ws.song.fichier
    st = p.stat() if p.exists() else None
    return f"{p}|{st.st_size if st else 0}|{st.st_mtime_ns if st else 0}|{ws.song.duree_ref_s}"


def _run(ws: Workspace, upstream: dict) -> dict:
    src = ws.song.fichier
    if not src.exists():
        raise FileNotFoundError(f"fichier d'entrée absent : {src}")
    file_dur = audio.probe_duration(src)
    full = ws.work / "input_full.wav"
    audio.convert_to_wav(src, full)
    x, sr = audio.read(full)
    first = first_sound_frame(x)
    start = max(0, (first or 0) - int(PREROLL_S * sr))
    trimmed = x[start:]
    audio.write_wav(ws.work / "input.wav", trimmed, sr)
    full.unlink()
    delta = file_dur - ws.song.duree_ref_s if ws.song.duree_ref_s else 0.0
    return {"file_duration_s": file_dur, "ref_delta_s": delta,
            "duration_alert": bool(ws.song.duree_ref_s and abs(delta) > DURATION_ALERT_S),
            "offset_s": start / sr, "duration_s": len(trimmed) / sr}


INGEST = Step(name="ingest", deps=(), key=_key, run=_run,
              artifacts=lambda ws: [ws.work / "input.wav"])
