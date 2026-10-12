"""Pure LRC handling: parse, format, shift; plain-text lyric lines."""
from __future__ import annotations
import re
from dataclasses import dataclass

STAMP = re.compile(r"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]")
SECTION = re.compile(r"^\s*\[[^\]]*\]\s*$")


@dataclass(frozen=True)
class Line:
    t: float
    text: str


def parse(text: str) -> list[Line]:
    out = []
    for raw in text.splitlines():
        stamps = list(STAMP.finditer(raw))
        if not stamps:
            continue
        lyric = raw[stamps[-1].end():].strip()
        if not lyric:
            continue
        for m in stamps:
            frac = m.group(3) or "0"
            t = int(m.group(1)) * 60 + int(m.group(2)) + int(frac) / (10 ** len(frac))
            out.append(Line(round(t, 3), lyric))
    return sorted(out, key=lambda l: l.t)


def format(lines: list[Line]) -> str:
    def stamp(t: float) -> str:
        cs = int(round(t * 100))
        return f"[{cs // 6000:02d}:{(cs // 100) % 60:02d}.{cs % 100:02d}]"
    return "".join(f"{stamp(l.t)}{l.text}\n" for l in lines)


def shift(lines: list[Line], delta: float) -> list[Line]:
    return [Line(max(0.0, round(l.t + delta, 3)), l.text) for l in lines]


def plain_lines(text: str) -> list[str]:
    """Non-empty lines without section markers such as [Refrain]."""
    return [s.strip() for s in text.splitlines() if s.strip() and not SECTION.match(s)]
