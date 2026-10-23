"""Human chord charts (pasted tabs, ChordPro, patadata .sg, Chordonomicon) parsed and merged with the detection.

Merge rules (Michel): chart and detection agree on root and bass → chart chord; they differ → chart chord over the
detected bass, bar flagged; detection silent → chart chord. Beats the chart doesn't place keep the detection, with the
chart's chord of the same root when it has one."""
from __future__ import annotations
import re
from dataclasses import dataclass, field

from karaoke.chords import SYMBOL

_ROOT = r"[A-G](?:#|b|s|&)?"
_TOKEN = re.compile(rf"^({_ROOT})((?:min|maj|m|M|dim|aug|sus|add|\+|[0-9b#()])*)(?:/({_ROOT}))?$")
SECTION = re.compile(r"^\s*\[([^\]]+)\]\s*$|^\s*(intro|couplet|refrain|verse|chorus|bridge|pont|outro|solo)\b[^:]*:?\s*$",
                     re.I)


def _root(r: str) -> str:
    return r[0] + {"s": "#", "&": "b"}.get(r[1:], r[1:])


def normalise(sym: str) -> str | None:
    m = _TOKEN.match(sym.strip())
    if not m:
        return None
    q = m.group(2)
    q = {"min": "m", "min7": "m7", "min6": "m6", "min9": "m9", "maj": "", "M7": "maj7", "sus": "sus4", "+": "aug",
         "minmaj7": "mM7", "m7-5": "m7b5", "min7b5": "m7b5", "7sus": "7sus4"}.get(q, q)
    out = _root(m.group(1)) + q + (f"/{_root(m.group(3))}" if m.group(3) else "")
    return out if SYMBOL.match(out) else None


@dataclass
class ChartLine:
    section: str | None
    text: str
    chords: list[tuple[int, str]] = field(default_factory=list)


@dataclass
class Chart:
    lines: list[ChartLine]
    capo: int = 0


def _chord_line(line: str) -> list[tuple[int, str]] | None:
    """A line made only of chord symbols (and bar marks / labels like « Intro: »): their columns, else None."""
    body = re.sub(r"^\s*[A-Za-zéÉ ]+\s*:", lambda m: " " * len(m.group(0)), line) if ":" in line else line
    toks = [(m.start(), m.group(0)) for m in re.finditer(r"\S+", body)]
    toks = [(i, t) for i, t in toks if t not in ("|", "||", "-", "x2", "x3", "x4", "(x2)")]
    syms = [(i, normalise(t)) for i, t in toks]
    return [(i, s) for i, s in syms] if toks and all(s for _, s in syms) else None


def parse(text: str) -> Chart:
    m = re.search(r"\\capo\{(\d+)\}|\bcapo\b\D{0,3}(\d+)", text, re.I)
    capo = int(m.group(1) or m.group(2)) if m else 0
    if "<" in text and re.search(r"<[a-z_]+_\d+>", text):                       # Chordonomicon
        lines = []
        for sec, body in re.findall(r"<([a-z_]+_\d+)>([^<]*)", text):
            syms = [normalise(t) for t in body.split()]
            lines.append(ChartLine(sec, "", [(i, s) for i, s in enumerate(syms) if s]))
        return Chart(lines, capo)
    inline = re.compile(r"\\?\[([^\]]+)\]")
    out, section, pending = [], None, None
    for raw in text.splitlines():
        line = raw.rstrip()
        if re.match(r"^\s*(\{.*\}|\\(capo|selectlanguage|songcolumns|beginsong|cover|gtab|endsong|end\{|emph).*)$", line) \
                or re.match(r"^\s*capo\b", line, re.I):
            continue
        if m := re.match(r"^\s*\\begin\{(\w+)\}", line):
            section = m.group(1)
            continue
        if m := SECTION.match(line):
            section = (m.group(1) or m.group(2)).strip()
            continue
        if inline.search(line) and not _chord_line(line):                     # ChordPro / patadata
            text_out, chords, pos = "", [], 0
            for m in inline.finditer(line.strip()):
                text_out += line.strip()[pos:m.start()]
                if s := normalise(m.group(1)):
                    chords.append((len(text_out), s))
                pos = m.end()
            text_out += line.strip()[pos:]
            out.append(ChartLine(section, re.sub(r"\\\w+\{([^}]*)\}", r"\1", text_out).strip(), chords))
            continue
        if not line.strip():
            if pending:
                out.append(ChartLine(section, "", pending))
                pending = None
            continue
        if (cl := _chord_line(line)) is not None:
            if pending:
                out.append(ChartLine(section, "", pending))
            pending = cl
            continue
        out.append(ChartLine(section, line.strip(), [(min(i, len(line.strip())), s) for i, s in (pending or [])]))
        pending = None
    if pending:
        out.append(ChartLine(section, "", pending))
    return Chart(out, capo)
