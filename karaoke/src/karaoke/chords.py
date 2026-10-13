"""Pure helpers for chord charts: madmom labels → chart symbols, beat quantisation, bars, text chart."""
from __future__ import annotations
import re

FLATS = {"A#": "Bb", "C#": "C#", "D#": "Eb", "F#": "F#", "G#": "Ab"}   # usual chart spelling


def symbol(label: str) -> str:
    """madmom label (`C#:min`, `A:maj`, `N`) → chart symbol (`C#m`, `A`, `N.C.`)."""
    if label in ("N", "X", ""):
        return "N.C."
    root, _, quality = label.partition(":")
    root = FLATS.get(root, root)
    return root + ("m" if quality.startswith("min") else "")


def chords_per_beat(segments: list, beats: list[float]) -> list[str]:
    """Chord symbol sounding at the centre of each beat interval."""
    out = []
    for i, b in enumerate(beats):
        nxt = beats[i + 1] if i + 1 < len(beats) else b + (beats[i] - beats[i - 1] if i else 0.5)
        centre = (b + nxt) / 2
        label = next((l for s, e, l in segments if s <= centre < e), "N")
        out.append(symbol(label))
    return out


def merge_blips(labels: list[str]) -> list[str]:
    """A chord lasting a single beat between two identical chords is detection flicker."""
    out = list(labels)
    for i in range(1, len(out) - 1):
        if out[i] != out[i - 1] and out[i - 1] == out[i + 1]:
            out[i] = out[i - 1]
    return out


def bars_from(beats: list[float], downbeats: list[float], labels: list[str], beats_per_bar: int) -> list[dict]:
    """Bars starting at each downbeat (a pickup before the first one becomes its own bar);
    each bar lists [beat_index, symbol] for its first beat and every change inside it."""
    if not beats:
        return []
    down = set(round(d, 3) for d in downbeats)
    starts = [i for i, b in enumerate(beats) if round(b, 3) in down] or list(range(0, len(beats), beats_per_bar))
    if starts[0] != 0:
        starts = [0] + starts
    bars = []
    for k, i0 in enumerate(starts):
        i1 = starts[k + 1] if k + 1 < len(starts) else len(beats)
        chords = []
        for j in range(i0, i1):
            if j == i0 or labels[j] != labels[j - 1]:
                chords.append([j - i0, labels[j]])
        bars.append({"start": beats[i0], "chords": chords})
    return bars


def chart_text(bars: list[dict], beats_per_bar: int, per_line: int = 4) -> str:
    cells = [cell_text(b["chords"], beats_per_bar) for b in bars]
    lines = ["| " + " | ".join(cells[i:i + per_line]) + " |" for i in range(0, len(cells), per_line)]
    return "\n".join(lines)


def changes(beats: list[float], labels: list[str]) -> list[dict]:
    """Chord changes in time: [{t, label}] (first beat included)."""
    return [{"t": b, "label": l} for i, (b, l) in enumerate(zip(beats, labels)) if i == 0 or l != labels[i - 1]]


TO_FLAT = {"C#": "Db", "D#": "Eb", "F#": "Gb", "G#": "Ab", "A#": "Bb"}
TO_SHARP = {v: k for k, v in TO_FLAT.items()}
FLAT_KEYS = {"F major", "Bb major", "Eb major", "Ab major", "Db major", "Gb major",
             "D minor", "G minor", "C minor", "F minor", "Bb minor", "Eb minor"}
SHARP_KEYS = {"E major", "B major", "F# major", "C# major",
              "C# minor", "G# minor", "D# minor", "A# minor"}   # 4+ sharps: A# beats Bb


def spell(symbols: list[str], key: str) -> list[str]:
    """Respell black-key roots to match the key (Db major → Db, not C#); other keys keep the default."""
    table = TO_FLAT if key in FLAT_KEYS else TO_SHARP if key in SHARP_KEYS else {}
    out = []
    for s in symbols:
        root = s[:2] if len(s) > 1 and s[1] in "#b" else s
        out.append(table.get(root, root) + s[len(root):] if root in table else s)
    return out


SYMBOL = re.compile(r"^(N\.C\.|[A-G][#b]?(m|maj7|m7b5|m7|m6|7|6|9|dim|aug|sus2|sus4|add9)?(/[A-G][#b]?)?)$")


def parse_cell(cell: str, beats_per_bar: int) -> list[list]:
    """`A B` = even split; `Am . . F` = one token per beat, `.` continues. Raises ValueError (French).
    Karaifyer's ChordGrid.parseCell implements the same rules."""
    toks = cell.split()
    if not toks:
        raise ValueError("mesure vide")
    bad = [t for t in toks if t != "." and not SYMBOL.match(t)]
    if bad:
        raise ValueError(f"accord non reconnu : {bad[0]}")
    if "." in toks:
        if len(toks) != beats_per_bar or toks[0] == ".":
            raise ValueError(f"« {cell} » : {beats_per_bar} temps attendus, le premier étant un accord")
        return [[i, t] for i, t in enumerate(toks) if t != "."]
    if len(toks) > beats_per_bar:
        raise ValueError(f"« {cell} » : plus d'accords que de temps ({beats_per_bar})")
    return [[k * beats_per_bar // len(toks), t] for k, t in enumerate(toks)]


def cell_text(chords: list, beats_per_bar: int) -> str:
    """Inverse of parse_cell: even split → `A B`, otherwise one token per beat (`Am . . F`)."""
    n = len(chords)
    if all(b == k * beats_per_bar // max(n, 1) for k, (b, _) in enumerate(chords)):
        return " ".join(l for _, l in chords)
    toks = ["."] * beats_per_bar
    for b, l in chords:
        if b < beats_per_bar:
            toks[b] = l
    return " ".join(toks)


def parse_chart(text: str) -> tuple[str | None, list[str]]:
    """Key and bar cells from an accords.txt-style chart."""
    key, cells = None, []
    for line in text.splitlines():
        m = re.match(r"\s*Tonalit[ée]\s*:\s*([^·]+)", line)
        if m:
            key = m.group(1).strip()
        elif line.strip().startswith("|"):
            cells += [c.strip() for c in line.strip().strip("|").split("|")]
    return key, cells


def expand(bars: list[dict], beats_per_bar: int, lengths: list[int] | None = None) -> list[str]:
    """Per-beat labels from bars' [[beat, label]] lists; `lengths` = real beats per bar (pickup)."""
    out = []
    for k, b in enumerate(bars):
        cur, marks = None, {i: l for i, l in b["chords"]}
        for i in range(lengths[k] if lengths else beats_per_bar):
            cur = marks.get(i, cur)
            out.append(cur)
    return out
