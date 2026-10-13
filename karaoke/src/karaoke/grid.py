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


REGULAR_SHARE = 0.85


def regularize(beats: Sequence[float], downbeats: Sequence[float]) -> tuple[list[float], list[float], dict]:
    """Clean a detected beat grid where the music is regular (Beat This! errors seen in Michel's run):
    - a gap of ≈2 or ≈3 beats is filled (half/third tempo in quiet parts: the click skipped beats);
    - a beat less than 0.6 beat after another is dropped (stray detection);
    - bar lines are rebuilt every N beats on the phase most detected bar lines agree on, when they all
      sit on that phase or half a bar from it (« beat 3 » taken for a new bar).
    Longer gaps (real stops), gradual tempo changes and genuinely shifting bar lines are kept as is."""
    b = [float(x) for x in beats]
    info = {"added": 0, "removed": 0, "bars_regularized": False}
    if len(b) < 8:
        return b, list(downbeats), info
    m = float(np.median(np.diff(b)))
    # Only for regular music: nearly every gap is 1, 2 or 3 beats (or a stray). Measured on Michel's
    # songs: regular ones 94–100 %, the drifting Speed 49 %, the free-tempo Blés d'or 58 %.
    r = np.diff(b) / m
    on_grid = np.mean([x < 0.6 or min(abs(x - k) / k for k in (1, 2, 3)) < 0.12 for x in r])
    if on_grid < REGULAR_SHARE:
        return b, list(downbeats), info
    dn0 = sorted(downbeats)
    # Beats per bar from bar DURATION: a half-tempo bar holds 2 detected beats but lasts a full bar.
    bpb0 = (int(min(7, max(2, round(float(np.median(np.diff(dn0))) / m)))) if len(dn0) >= 2
            else beats_per_bar(b, downbeats))

    def short_bar(x: float) -> bool:
        """The detected bar holding x has fewer beats than a bar: beats were skipped there. (A slower
        section with full bars has real beats — Speed.) Outside any bar (intro/outro): allowed."""
        k = int(np.searchsorted(dn0, x + 1e-3)) - 1
        if k < 0 or k + 1 >= len(dn0):
            return True
        return sum(1 for t in beats if dn0[k] - 1e-3 <= t < dn0[k + 1] - 1e-3) < bpb0

    i = 0                                       # stray beats
    while i < len(b) - 1:
        if b[i + 1] - b[i] < 0.6 * m:
            def err(j):                         # dropping j merges its two intervals: that one should be a beat
                prev = b[j - 1] if j > 0 else b[j] - m
                nxt = b[j + 1] if j + 1 < len(b) else b[j] + m
                return abs((nxt - prev) - m)
            drop = i + 1 if err(i + 1) <= err(i) else i
            del b[drop]
            info["removed"] += 1
        else:
            i += 1
    out = [b[0]]                                # skipped beats
    for x, y in zip(b, b[1:]):
        q = (y - x) / m
        k = round(q)
        if k in (2, 3) and abs(q - k) < 0.15 * k and short_bar(x):
            out += [x + (y - x) * j / k for j in range(1, k)]
            info["added"] += k - 1
        out.append(y)
    b = out
    down = sorted(downbeats)
    # Bar lines, stretch by stretch: a badly tracked passage (e.g. locked at 3/4 tempo) can shift the
    # detected bar lines after it, so each regular stretch votes on its own phase.
    gaps_ok = [abs((y - x) / m - 1) <= 0.15 for x, y in zip(b, b[1:])]
    stretches, s = [], 0
    for j, ok in enumerate(gaps_ok):
        if not ok:
            stretches.append((s, j))
            s = j + 1
    stretches.append((s, len(b) - 1))
    tol = 0.35 * m
    kept = list(down)
    rebuilt: list[float] = []
    for s, e in stretches:
        inside = [d for d in down if b[s] - tol <= d <= b[e] + tol]
        if e - s < 8 or len(inside) < 3:
            continue
        idx = [s + int(np.argmin([abs(x - d) for x in b[s:e + 1]])) for d in inside]
        best = None
        for n in (4, 3):
            counts = np.bincount([j % n for j in idx], minlength=n)
            p = int(np.argmax(counts))
            ok_phases = {p, (p + n // 2) % n} if n % 2 == 0 else {p}
            on = sum(1 for j in idx if j % n in ok_phases) / len(idx)
            share = counts[p] / len(idx)
            if share >= 0.5 and on >= 0.9 and (best is None or share > best[0]):
                best = (share, n, p)
        if best:
            _, n, p = best
            kept = [d for d in kept if d not in inside]
            rebuilt += [b[j] for j in range(s, e + 1) if j % n == p]
    new = sorted(set(kept) | set(rebuilt))
    if new != down:
        down, info["bars_regularized"] = new, True
    return b, down, info


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
