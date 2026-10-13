"""Pure helpers for chord charts: madmom labels → chart symbols, beat quantisation, bars, text chart."""
from __future__ import annotations

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
    cells = [" ".join(c for _, c in b["chords"]) for b in bars]
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
