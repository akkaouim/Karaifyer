"""Pure helpers for chord charts: madmom labels → chart symbols, beat quantisation, bars, text chart."""
from __future__ import annotations
import re

FLATS = {"A#": "Bb", "C#": "C#", "D#": "Eb", "F#": "F#", "G#": "Ab"}   # usual chart spelling

PC = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
NAME = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
# Harte quality → (chart suffix, intervals above the root)
HARTE = {"maj": ("", (0, 4, 7)), "min": ("m", (0, 3, 7)), "7": ("7", (0, 4, 7, 10)), "maj7": ("maj7", (0, 4, 7, 11)),
         "min7": ("m7", (0, 3, 7, 10)), "hdim7": ("m7b5", (0, 3, 6, 10)), "dim": ("dim", (0, 3, 6)),
         "dim7": ("dim7", (0, 3, 6, 9)), "aug": ("aug", (0, 4, 8)), "maj6": ("6", (0, 4, 7, 9)),
         "min6": ("m6", (0, 3, 7, 9)), "9": ("9", (0, 4, 7, 10, 2)), "maj9": ("maj9", (0, 4, 7, 11, 2)),
         "min9": ("m9", (0, 3, 7, 10, 2)), "sus2": ("sus2", (0, 2, 7)), "sus4": ("sus4", (0, 5, 7)),
         "sus4(b7)": ("7sus4", (0, 5, 7, 10)), "7sus4": ("7sus4", (0, 5, 7, 10)), "minmaj7": ("mM7", (0, 3, 7, 11)),
         "11": ("11", (0, 4, 7, 10, 2, 5)), "13": ("13", (0, 4, 7, 10, 2, 9)), "add9": ("add9", (0, 4, 7, 2))}
DEGREE = {"1": 0, "b2": 1, "2": 2, "b3": 3, "3": 4, "4": 5, "#4": 6, "b5": 6, "5": 7, "#5": 8, "b6": 8, "6": 9,
          "bb7": 9, "b7": 10, "7": 11, "9": 2, "b9": 1, "11": 5, "#11": 6, "13": 9, "b13": 8}
ROOT_POSITION = ("m7", "7", "maj7", "m7b5", "6", "m6", "m9", "9")   # tried, in order, for a slash chord


def _pc(note: str) -> int:
    return (PC[note[0]] + sum({"#": 1, "b": -1}.get(c, 0) for c in note[1:])) % 12


LETTERS = "CDEFGAB"
LETTER_STEP = {0: 0, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3, 7: 4, 8: 5, 9: 5, 10: 6, 11: 6}   # interval → letters up


def _bass_name(root: str, pc: int) -> str:
    """A bass note spelled from its interval above the chord's root (E's 3rd is G#, never Ab)."""
    letter = LETTERS[(LETTERS.index(root[0]) + LETTER_STEP[(pc - _pc(root)) % 12]) % 7]
    acc = (pc - PC[letter] + 6) % 12 - 6
    return letter + {0: "", 1: "#", -1: "b"}[acc] if acc in (-1, 0, 1) else NAME[pc]


def symbol(label: str) -> str:
    """Harte label (any engine: `C#:min7`, `A:maj/3`, `G:sus4(b7)`, `N`) → chart symbol (`C#m7`, `A/C#`, `G7sus4`).
    A slash chord whose notes form a chord rooted on its bass is named by it (A/F# → F#m7, Michel's convention);
    unknown qualities fall back to their maj/min triad. Karaifyer's ChordGrid accepts the same symbols."""
    m = re.match(r"^([A-G][#b]?)(?::([^/]*))?(?:/(.+))?$", label.strip())
    if not m:
        return "N.C."
    root = _pc(m.group(1))
    q = m.group(2) or "maj"
    if q not in HARTE:
        q = q.split("(")[0]
    suffix, iv = HARTE.get(q, ("m", HARTE["min"][1]) if q.startswith("min") else ("", HARTE["maj"][1]))
    name = NAME[root] + suffix
    b = m.group(3)
    if not b:
        return name
    bass = (root + DEGREE[b]) % 12 if b in DEGREE else _pc(b) if b[0] in PC else root
    if bass == root:
        return name
    notes = {(root + i) % 12 for i in iv} | {bass}
    for suf in ROOT_POSITION:
        cand = next(v for v in HARTE.values() if v[0] == suf)
        if {(bass + i) % 12 for i in cand[1]} == notes:
            return NAME[bass] + suf
    return f"{name}/{_bass_name(NAME[root], bass)}"


SYMBOL = re.compile(r"^(N\.C\.|[A-G][#b]?(maj9|maj7|mM7|m7b5|m9|m7|m6|7sus4|dim7|dim|aug|sus2|sus4|add9|11|13|9|7|6|m)?"
                    r"(/[A-G][#b]?)?)$")



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
        main, _, bass = s.partition("/")
        root = main[:2] if len(main) > 1 and main[1] in "#b" else main[:1]
        new_root = table.get(root, root) if s != "N.C." else root
        main = new_root + main[len(root):]
        out.append(f"{main}/{_bass_name(new_root, _pc(bass))}" if bass and new_root[:1] in PC else main)
    return out




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
