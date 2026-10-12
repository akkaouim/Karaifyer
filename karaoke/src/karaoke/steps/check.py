"""Step `check` — lyric calage and click drift.

Inputs:  stems/vocals.wav, stems/drums.wav; lyrics result {lines}; beats result {beats}.
Outputs: result {rate, lines: [{t, ok, end}], drift_ms}.
  ok   : >= 50 % of 50 ms frames in [t, t+0.5 s] have vocal energy.
  end  : end of the last active vocal frame before the next line (t+3 s if none) — used by
         the video to detect instrumental gaps.
  rate : ok / lines (None without lines).  drift_ms: click (detected beats) vs drum onsets.
  word_rate: share of words with vocal activity within ±WORD_TOLERANCE_S of their start (Michel:
         under 0.5 s nobody notices); words_off: the others (time, text), at most 50.
"""
from __future__ import annotations

import numpy as np

from karaoke import audio, grid
from karaoke.runner import Step
from karaoke.workspace import Workspace

HOP_S = 0.05
WORD_TOLERANCE_S = 0.5


def vocal_activity(x: np.ndarray, sr: int, hop_s: float = HOP_S) -> np.ndarray:
    mono = x.mean(axis=1) if x.ndim == 2 else x
    hop = int(hop_s * sr)
    n = len(mono) // hop
    if n == 0:
        return np.zeros(0, bool)
    rms = np.sqrt((mono[: n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    thr = max(-45.0, float(np.percentile(db, 75)) - 20.0)
    return db > thr


def _run(ws: Workspace, upstream: dict) -> dict:
    vx, sr = audio.read(ws.stems / "vocals.wav")
    act = vocal_activity(vx, sr)
    lines = upstream["lyrics"]["lines"]
    out = []
    for i, line in enumerate(lines):
        a, b = int(line["t"] / HOP_S), int((line["t"] + 0.5) / HOP_S)
        win = act[a:b]
        ok = bool(win.size and win.mean() >= 0.5)
        nxt = lines[i + 1]["t"] if i + 1 < len(lines) else len(act) * HOP_S
        idx = np.flatnonzero(act[a:int(nxt / HOP_S)])
        # last vocal activity before the next line starts (what gap detection needs)
        end = (a + idx[-1] + 1) * HOP_S if idx.size else line["t"] + 3.0
        out.append({"t": line["t"], "ok": ok, "end": round(float(end), 3)})
    dx, _ = audio.read(ws.stems / "drums.wav")
    drift = grid.drift_ms(upstream["beats"]["beats"], grid.onsets(dx, sr))
    rate = (sum(l["ok"] for l in out) / len(out)) if out else None
    words = [w for line in lines for w in line.get("words", [])]
    off = []
    for w in words:
        a = max(0, int((w["start"] - WORD_TOLERANCE_S) / HOP_S))
        b = int((w["start"] + WORD_TOLERANCE_S) / HOP_S) + 1
        if not act[a:b].any():
            off.append({"t": w["start"], "text": w["text"]})
    word_rate = (1 - len(off) / len(words)) if words else None
    return {"rate": rate, "lines": out, "drift_ms": drift, "word_rate": word_rate, "words_off": off[:50]}


CHECK = Step(name="check", deps=("beats", "separate", "lyrics"), key=lambda ws: "", run=_run,
             version="2")   # 2: word timing check with ±0.5 s tolerance
