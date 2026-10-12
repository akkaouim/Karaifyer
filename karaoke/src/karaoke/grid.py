"""Pure beat-grid maths: meter, tempo stability, count-in, click synthesis, drift. Times in seconds."""
from __future__ import annotations
import math
from dataclasses import dataclass
from typing import Sequence

import numpy as np

STABLE_PCT = 3.0


def beats_per_bar(beats: Sequence[float], downbeats: Sequence[float]) -> int:
    if len(downbeats) < 2:
        return 4
    b = np.asarray(beats)
    counts = [int(np.sum((b >= d0 - 1e-3) & (b < d1 - 1e-3))) for d0, d1 in zip(downbeats, downbeats[1:])]
    return int(min(7, max(2, round(float(np.median(counts))))))


TEMPO_WINDOW = 16   # beats; averaging over a span cancels Beat This!'s ±1 frame (20 ms) jitter


def tempo_stats(beats: Sequence[float]) -> dict:
    b = np.asarray(beats, float)
    ibi = np.diff(b)
    med = float(np.median(ibi))
    w = min(TEMPO_WINDOW, len(b) - 1)
    local = (b[w:] - b[:-w]) / w          # mean interval over each w-beat span
    local_bpm = 60.0 / local
    var = float((np.percentile(local_bpm, 95) - np.percentile(local_bpm, 5)) / np.median(local_bpm) * 100)
    return {"bpm": 60.0 / med, "variation_pct": var, "stable": var <= STABLE_PCT}


@dataclass(frozen=True)
class CountIn:
    pad_s: float          # silence prepended so the first count-in click lands at >= 0
    period_s: float       # beat period used for the count-in
    beats_per_bar: int
    times_in: list[float]  # count-in click times in trimmed-input time (may be negative)
    accents: list[bool]


def countin_plan(beats, downbeats, n_bars: int, sr: int = 44100) -> CountIn:
    """Count-in of n_bars placed just before the FIRST DETECTED BEAT (so the music never
    starts under it), continuing the bar phase given by the first downbeat (accents on 1)."""
    b = np.asarray(beats, float)
    first = float(b[0])
    period = float(np.median(np.diff(b[:9]))) if len(b) > 2 else 0.5
    bpb = beats_per_bar(beats, downbeats)
    anchor = float(downbeats[0]) if len(downbeats) else first
    # bar position of the first beat: how many beats it lies before the first downbeat
    m = int(round((anchor - first) / period)) if anchor > first else 0
    n = max(0, n_bars) * bpb
    times = [first - j * period for j in range(n, 0, -1)]
    accents = [(m + j) % bpb == 0 for j in range(n, 0, -1)]
    earliest = min(times) if times else 0.0
    pad = math.ceil(max(0.0, -earliest) * sr) / sr
    return CountIn(pad_s=pad, period_s=period, beats_per_bar=bpb, times_in=times, accents=accents)


def click_events(plan: CountIn, beats, downbeats) -> list[tuple[float, bool]]:
    """Output-time click events: the count-in, then every detected beat (accent on downbeats)."""
    down = {round(d, 4) for d in downbeats}
    ev = [(t + plan.pad_s, a) for t, a in zip(plan.times_in, plan.accents)]
    ev += [(t + plan.pad_s, round(t, 4) in down) for t in beats]
    return sorted(ev)


def render_click(events, total_frames: int, sr: int = 44100) -> np.ndarray:
    out = np.zeros(total_frames, np.float32)
    n = int(0.025 * sr)
    t = np.arange(n) / sr
    env = np.exp(-t / 0.006)
    hi = (0.9 * np.sin(2 * np.pi * 1600 * t) * env).astype(np.float32)
    lo = (0.6 * np.sin(2 * np.pi * 1000 * t) * env).astype(np.float32)
    for when, accent in events:
        i = int(round(when * sr))
        if 0 <= i < total_frames:
            src = hi if accent else lo
            m = min(n, total_frames - i)
            out[i:i + m] += src[:m]
    return np.clip(out, -1, 1)


def onsets(x: np.ndarray, sr: int, hop: int = 256, frame: int = 1024) -> np.ndarray:
    """Spectral-flux onset times of a (mono or stereo) signal."""
    x = x.mean(axis=1) if x.ndim == 2 else x
    if len(x) < frame:
        return np.array([])
    win = np.hanning(frame)
    frames = np.lib.stride_tricks.sliding_window_view(x, frame)[::hop] * win
    mag = np.abs(np.fft.rfft(frames, axis=1))
    flux = np.maximum(0, np.diff(np.log1p(mag), axis=0)).sum(axis=1)
    flux = np.concatenate([[0], flux])
    thr = np.median(flux) + 2.0 * np.std(flux)
    peaks = [i for i in range(1, len(flux) - 1)
             if flux[i] > thr and flux[i] >= flux[i - 1] and flux[i] > flux[i + 1]]
    return (np.array(peaks) * hop + frame // 2) / sr


def drift_ms(beats, onset_times, window_s: float = 10.0, max_dist: float = 0.07) -> float:
    """Worst 10-second-window median |beat - nearest onset|, in ms (0 if nothing matched)."""
    on = np.sort(np.asarray(onset_times, float))
    if on.size == 0:
        return 0.0
    rows = []
    for t in beats:
        j = np.searchsorted(on, t)
        cands = on[max(0, j - 1):j + 1]
        d = cands[np.argmin(np.abs(cands - t))] - t
        if abs(d) <= max_dist:
            rows.append((t, abs(d)))
    if not rows:
        return 0.0
    arr = np.array(rows)
    windows = np.floor(arr[:, 0] / window_s)
    return float(max(np.median(arr[windows == w, 1]) for w in np.unique(windows)) * 1000)
