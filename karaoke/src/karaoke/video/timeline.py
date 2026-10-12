"""Pure display timeline for the lyrics video. Times are output (show) times."""
from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class State:
    start: float
    end: float
    kind: str              # titre | ligne | instrumental | fin
    current: str
    next: str
    countdown: int | None


def _wait(start: float, end: float, kind: str, current: str, nxt: str, countdown_s: float,
          with_countdown: bool) -> list[State]:
    if end <= start:
        return []
    if not with_countdown or end - start <= countdown_s:
        return [State(start, end, kind, current, nxt, None)]
    cd_start = end - countdown_s
    out = [State(start, cd_start, kind, current, nxt, None)]
    n = int(round(countdown_s))
    for k in range(n):
        out.append(State(cd_start + k, cd_start + k + 1 if k < n - 1 else end, kind, current, nxt, n - k))
    return out


def build_states(lines, pad_s, total_s, titre, artiste, lead_s=0.2, gap_s=8.0, countdown_s=3.0) -> list[State]:
    """lines: [(start_out, end_out, text)]. Contiguous states covering [0, total_s]."""
    title = f"{titre} — {artiste}"
    if not lines:
        return [State(0.0, total_s, "titre", title, "", None)]
    shows = [max(0.0, s - lead_s) for s, _, _ in lines]
    first = shows[0]
    states = _wait(0.0, first, "titre", title, lines[0][2], countdown_s, first - pad_s > gap_s)
    for i, (start, end, text) in enumerate(lines):
        nxt = lines[i + 1][2] if i + 1 < len(lines) else ""
        show = shows[i]
        stop = shows[i + 1] if i + 1 < len(lines) else min(total_s, max(end, start) + 2.0)
        if i + 1 < len(lines) and lines[i + 1][0] - end > gap_s:
            sing_end = min(stop, end + 0.5)
            states.append(State(show, sing_end, "ligne", text, nxt, None))
            states += _wait(sing_end, stop, "instrumental", "", nxt, countdown_s, True)
        else:
            states.append(State(show, stop, "ligne", text, nxt, None))
    if states[-1].end < total_s:
        states.append(State(states[-1].end, total_s, "fin", "", "", None))
    return [s for s in states if s.end - s.start > 1e-6]
