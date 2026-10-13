"""Pure display timeline for the lyrics video. Times are output (show) times.

Each line is shown from its start minus `lead_s`, with one state per syllable start (`lit` = number
of characters of the line already sung). When more than `gap_beats` beats of silence precede a line,
the last 4 beats before it show a 4-3-2-1 countdown.
"""
from __future__ import annotations
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class TimedLine:
    start: float
    end: float                            # end of singing (from the vocal activity check)
    text: str                             # whitespace-normalised
    syllables: list[tuple[float, int]]    # (start, characters of `text` lit once it starts)
    chords: tuple = ()                    # ((char offset, label), …) drawn above the line


@dataclass(frozen=True)
class State:
    start: float
    end: float
    kind: str                # titre | ligne | instrumental | fin
    current: str
    next: str
    countdown: int | None
    lit: int = 0
    chords: tuple = ()
    chart: tuple = ()               # instrumental parts: the 4-bar chart row being played
    chart_pos: int | None = None    # index of the current bar in `chart`
    next_chords: tuple = ()         # chords of the next-line preview


def line_chords(line: TimedLine, changes: list[dict]) -> list[tuple[int, str]]:
    """Chord sounding when the line starts (offset 0), then each change during the line placed at
    the first character of the syllable being sung at that moment. N.C. is not shown; when several
    changes fall on one syllable, the last wins."""
    starts, prev = [], 0
    for s, chars in line.syllables:
        starts.append((s, prev + 1 if line.text[prev:prev + 1] == " " else prev))
        prev = chars
    out: dict[int, str] = {}
    before = [c for c in changes if c["t"] <= line.start]
    if before:
        out[0] = before[-1]["label"]
    for c in changes:
        if line.start < c["t"] < line.end:
            off = max([o for s, o in starts if s <= c["t"]], default=0)
            out[off] = c["label"]
    return [(o, l) for o, l in sorted(out.items()) if l != "N.C."]


def _beats_between(beats, a: float, b: float) -> int:
    return sum(1 for t in beats if a < t < b)


def _with_countdown(start, end, kind, current, nxt, beats, n=4, next_chords=()) -> list[State]:
    marks = [b for b in beats if start <= b < end][-n:]
    if len(marks) < n:
        return [State(start, end, kind, current, nxt, None, next_chords=next_chords)]
    out = [State(start, marks[0], kind, current, nxt, None, next_chords=next_chords)] if marks[0] > start else []
    for k, b in enumerate(marks):
        out.append(State(b, marks[k + 1] if k + 1 < n else end, kind, current, nxt, n - k, next_chords=next_chords))
    return out


def _line_states(line: TimedLine, show: float, stop: float, nxt: str, nc: tuple = ()) -> list[State]:
    out, t, lit = [], show, 0
    for start, chars in line.syllables:
        if start <= show:
            lit = chars
            continue
        if start >= stop:
            break
        out.append(State(t, start, "ligne", line.text, nxt, None, lit, line.chords, next_chords=nc))
        t, lit = start, chars
    out.append(State(t, stop, "ligne", line.text, nxt, None, lit, line.chords, next_chords=nc))
    return out


def build_states(lines: list[TimedLine], pad_s: float, total_s: float, titre: str, artiste: str,
                 beats: list[float], lead_s: float = 0.2, gap_beats: int = 8, bar_beats: int = 4) -> list[State]:
    title = f"{titre} — {artiste}"
    if not lines:
        return [State(0.0, total_s, "titre", title, "", None)]
    shows = [max(0.0, l.start - lead_s) for l in lines]
    first = lines[0]
    if _beats_between(beats, pad_s, first.start) > gap_beats:
        states = _with_countdown(0.0, shows[0], "titre", title, first.text, beats)
    else:
        states = [State(0.0, shows[0], "titre", title, first.text, None)]
    for i, line in enumerate(lines):
        nxt = lines[i + 1] if i + 1 < len(lines) else None
        stop = shows[i + 1] if nxt else min(total_s, max(line.end, line.start) + 2.0)
        nc = nxt.chords if nxt else ()
        gap = _beats_between(beats, line.end, nxt.start) if nxt else 0
        sing_end = min(stop, line.end + 0.5)
        if nxt and gap > gap_beats:
            states += _line_states(line, shows[i], sing_end, nxt.text, nc)
            states += _with_countdown(sing_end, stop, "instrumental", "", nxt.text, beats, next_chords=nc)
        elif nxt and gap >= bar_beats and sing_end < stop:
            # A break of a bar or more: show the chord row (instrumental) instead of a finished line.
            states += _line_states(line, shows[i], sing_end, nxt.text, nc)
            states.append(State(sing_end, stop, "instrumental", "", nxt.text, None, next_chords=nc))
        else:
            states += _line_states(line, shows[i], stop, nxt.text if nxt else "", nc)
    if states[-1].end < total_s:
        states.append(State(states[-1].end, total_s, "fin", "", "", None))
    return [s for s in states if s.end - s.start > 1e-6]


CHART_KINDS = ("titre", "instrumental", "fin")


def with_chart(states: list[State], bars: list[tuple[float, str]], per_row: int = 4) -> list[State]:
    """Split the non-sung states (intro, instrumental gaps, outro) at bar starts and attach the chart
    row (bars grouped by `per_row`, as in accords.txt) with the current bar. `bars` = (start, cell)."""
    if not bars:
        return states
    last_len = bars[-1][0] - bars[-2][0] if len(bars) > 1 else 2.0
    edges = [b for b, _ in bars] + [bars[-1][0] + last_len]
    out = []
    for s in states:
        if s.kind not in CHART_KINDS:
            out.append(s)
            continue
        cuts = [s.start] + [e for e in edges if s.start < e < s.end] + [s.end]
        for a, b in zip(cuts, cuts[1:]):
            i = max((k for k in range(len(bars)) if bars[k][0] <= a + 1e-6), default=None)
            if i is None or a >= edges[-1] - 1e-6:
                out.append(replace(s, start=a, end=b))
            else:
                row = i // per_row * per_row
                out.append(replace(s, start=a, end=b, chart=tuple(c for _, c in bars[row:row + per_row]),
                                   chart_pos=i - row))
    return out
