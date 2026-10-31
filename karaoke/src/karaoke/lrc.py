"""Pure LRC handling: parse, format, shift; plain-text lyric lines."""
from __future__ import annotations
import re
from dataclasses import dataclass

# Tag written into the show-time paroles.lrc: seconds to subtract to get back to the
# trimmed input's timeline. A supplied file carrying it is read in show time.
DECALAGE = re.compile(r"\[karaoke:decalage=([0-9.]+)\]")
STAMP = re.compile(r"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]")
SECTION = re.compile(r"^\s*\[[^\]]*\]\s*$")
# Written by the app's « Remplacer le texte »: indices (file order, from 0, every timed line) of the lines
# whose time is only a guess, to be aligned on the voice.
A_CALER = re.compile(r"\[karaoke:a_caler=([0-9,]*)\]")


@dataclass(frozen=True)
class Line:
    t: float
    text: str


def parse(text: str) -> list[Line]:
    return [l for l, _ in parse_marked(text)]


def parse_marked(text: str) -> list[tuple[Line, bool]]:
    """Lines with their « à caler » mark (A_CALER), sorted by time."""
    m = A_CALER.search(text)
    marked = {int(x) for x in m.group(1).split(",") if x} if m else set()
    out, n = [], -1
    for raw in text.splitlines():
        stamps = list(STAMP.finditer(raw))
        if not stamps:
            continue
        n += 1
        lyric = raw[stamps[-1].end():].strip()
        if not lyric:
            continue
        for st in stamps:
            frac = st.group(3) or "0"
            t = int(st.group(1)) * 60 + int(st.group(2)) + int(frac) / (10 ** len(frac))
            out.append((Line(round(t, 3), lyric), n in marked))
    return sorted(out, key=lambda x: x[0].t)


def show_offset(text: str) -> float | None:
    m = DECALAGE.search(text)
    return float(m.group(1)) if m else None


def format(lines: list[Line], decalage: float | None = None) -> str:
    def stamp(t: float) -> str:
        cs = int(round(t * 100))
        return f"[{cs // 6000:02d}:{(cs // 100) % 60:02d}.{cs % 100:02d}]"
    head = f"[karaoke:decalage={decalage:.3f}]\n" if decalage is not None else ""
    return head + "".join(f"{stamp(l.t)}{l.text}\n" for l in lines)


def shift(lines: list[Line], delta: float) -> list[Line]:
    return [Line(max(0.0, round(l.t + delta, 3)), l.text) for l in lines]


def plain_lines(text: str) -> list[str]:
    """Non-empty lines without section markers such as [Refrain]."""
    return [s.strip() for s in text.splitlines() if s.strip() and not SECTION.match(s)]
