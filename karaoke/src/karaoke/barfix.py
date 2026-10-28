"""Michel's bar-grid fix (mesures/<id>.json): time signature, swing, pinned and locked bar lines.

Applied by the `beats` step after grid.regularize; Karaifyer's BarGrid implements the same rule.
- beats per bar: x/4 → x; 6/8 → 2 and 12/8 → 4 at ≤ 120 BPM (beats = dotted quarters), ×3 above (eighths);
- pins (seconds) snap to the nearest beat; from each anchor a bar line every N beats until the next pin or lock;
- locks (seconds) also snap: a fixed bar line followed by the detected ones until the next pin or lock, so locking
  a bar never moves one (a pin on the same beat wins);
- with a signature, the first detected bar line is an implicit anchor unless a pin lies before it + N beats.
"""
from __future__ import annotations
import json
from pathlib import Path

SIGNATURES = {"2/4": 2, "3/4": 3, "4/4": 4, "6/8": 2, "12/8": 4}
EIGHTHS_BPM = 120.0
EMPTY = {"signature": None, "swing": False, "pins": [], "locks": []}


def load(path: Path) -> dict:
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return dict(EMPTY)
    sig = d.get("signature")
    return {"signature": sig if sig in SIGNATURES else None, "swing": bool(d.get("swing", False)),
            "pins": _seconds(d.get("pins")), "locks": _seconds(d.get("locks"))}


def _seconds(v) -> list[float]:
    return [float(t) for t in v if isinstance(t, (int, float))] if isinstance(v, list) else []


def on_beat(beats: list[float], downbeats: list[float]) -> list[float]:
    """Detected bar lines that sit on a beat (regularize can keep one whose beat it dropped); the others are
    ignored, as chords.bars_from already ignored them, so Python and Karaifyer count the same bars."""
    on = {round(b, 3) for b in beats}
    return [d for d in downbeats if round(d, 3) in on]


def beats_in_bar(signature: str | None, detected: int, bpm: float) -> int:
    if signature not in SIGNATURES:
        return detected
    n = SIGNATURES[signature]
    return n * 3 if signature.endswith("/8") and bpm > EIGHTHS_BPM else n


def _nearest(beats: list[float], t: float) -> int:
    return min(range(len(beats)), key=lambda i: abs(beats[i] - t))


def apply_fix(beats: list[float], downbeats: list[float], fix: dict, detected_bpb: int,
              bpm: float) -> tuple[list[float], int]:
    n = beats_in_bar(fix.get("signature"), detected_bpb, bpm)
    if not beats:
        return list(downbeats), n
    anchors = sorted({_nearest(beats, t) for t in fix.get("pins", [])})
    if fix.get("signature") and downbeats:
        first = _nearest(beats, downbeats[0])
        if not anchors or anchors[0] >= first + n:
            anchors = sorted(set(anchors) | {first})
    locks = sorted({_nearest(beats, t) for t in fix.get("locks", [])} - set(anchors))
    events = sorted([(a, True) for a in anchors] + [(l, False) for l in locks])
    if not events:
        return list(downbeats), n
    out = [d for d in downbeats if d < beats[events[0][0]] - 1e-6]
    for k, (a, counted) in enumerate(events):
        end = events[k + 1][0] if k + 1 < len(events) else len(beats)
        if counted:
            out += [beats[i] for i in range(a, end, n)]
        else:
            stop = beats[end] - 1e-6 if end < len(beats) else float("inf")
            out += [beats[a]] + [d for d in downbeats if beats[a] + 1e-6 < d < stop]
    return out, n
