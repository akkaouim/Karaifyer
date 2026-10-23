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
    sym = sym.strip().strip("()*")
    if sym.upper() in ("N.C.", "NC", "N.C"):
        return "N.C."
    if sym[:1] == "H":                                     # German notation: H = B
        sym = "B" + sym[1:]
    sym = sym.replace("no3d", "")
    m = _TOKEN.match(sym)
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


REPEAT_MARK = re.compile(r"^\(?[x×]?\d+[x×]?\)?$|^[|/:-]+$", re.I)


def _chord_line(line: str) -> list[tuple[int, str]] | None:
    """A line of chord symbols (bar marks, repeat marks like « (2x) » and labels like « Intro: » allowed; one odd token
    in five tolerated): their columns, else None."""
    body = re.sub(r"^\s*[A-Za-zéÉ ]+\s*:", lambda m: " " * len(m.group(0)), line) if ":" in line else line
    toks = [(m.start(), m.group(0)) for m in re.finditer(r"\S+", body)]
    toks = [(i, t) for i, t in toks if not REPEAT_MARK.match(t)]
    syms = [(i, normalise(t)) for i, t in toks]
    good = [(i, s) for i, s in syms if s]
    return good if good and len(good) >= 0.8 * len(syms) else None


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
    for raw in text.expandtabs(8).splitlines():
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
            clean = re.sub(r"\\(?!\[)\w+\*?(\{([^}]*)\})?", r"\2", line).replace("{", "").replace("}", "").strip()
            text_out, chords, pos = "", [], 0
            for m in inline.finditer(clean):
                text_out += clean[pos:m.start()]
                if s := normalise(m.group(1)):
                    chords.append((len(text_out), s))
                pos = m.end()
            text_out += clean[pos:]
            lead = len(text_out) - len(text_out.lstrip())
            out.append(ChartLine(section, text_out.strip(), [(max(0, o - lead), s) for o, s in chords]))
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
        indent = len(line) - len(line.lstrip())             # chord columns are relative to the lyric's first letter
        out.append(ChartLine(section, line.strip(), [(max(0, i - indent), s) for i, s in (pending or [])]))
        pending = None
    if pending:
        out.append(ChartLine(section, "", pending))
    return Chart(out, capo)


# ---------------------------------------------------------------------------------------------------------------
# Merge a chart with the detection

import unicodedata
from collections import Counter
from difflib import SequenceMatcher

from karaoke.chords import HARTE, NAME, _pc, cell_text, symbol

_SYM = re.compile(r"^([A-G][#b]?)([^/]*)(?:/([A-G][#b]?))?$")
_HARTE_OF = {}
for _name, (_suf, _iv) in HARTE.items():
    _HARTE_OF.setdefault(_suf, _name)
SECTION_GAP_S = 4.0      # a pause this long between two sung lines starts a new section
REPEAT_SHARE = 0.7       # an empty section copies an earlier one whose bars have the same detected roots this often
MIN_KEY_EVIDENCE = 3     # distinct chart roots needed before transposing beyond the capo


def _parts(sym: str | None):
    m = _SYM.match(sym or "")
    if not m or sym == "N.C.":
        return None
    root = _pc(m.group(1))
    return root, (_pc(m.group(3)) if m.group(3) else root), m.group(2)


def _transpose(sym: str, k: int) -> str:
    p = _parts(sym)
    if not p or not k:
        return sym
    r, b, q = p
    return NAME[(r + k) % 12] + q + (f"/{NAME[(b + k) % 12]}" if b != r else "")


def _norm_char(c: str) -> str:
    base = next((x for x in unicodedata.normalize("NFKD", c) if not unicodedata.combining(x)), " ")
    return base.lower() if base.isalnum() else " "


def _norm_text(s: str) -> str:
    """Lower case, no accents, punctuation as spaces — one character per character, so chart columns still apply."""
    return "".join(_norm_char(c) for c in s)


def _over_bass(chart_sym: str, bass_pc: int) -> str:
    """The chart's chord over the detected bass, renamed to root position when the notes match (A/F# → F#m7)."""
    r, _, q = _parts(chart_sym)
    return symbol(f"{NAME[r]}:{_HARTE_OF.get(q, 'maj')}/{NAME[bass_pc]}")


@dataclass
class MergeResult:
    cells: list[str]
    flagged: list[int]
    placed: int = 0
    repeated: int = 0
    vocab: int = 0


def merge(chart: Chart, beats: list[float], bar_starts: list[int], beats_per_bar: int,
          detected: list[str], words: list[list[tuple[str, float]]], lines_text: list[str]) -> MergeResult:
    n = len(beats)
    det = (list(detected) + ["N.C."] * n)[:n]
    det_parts = [_parts(d) for d in det]
    det_roots = [p[0] for p in det_parts if p]

    # 1. transposition: the capo, then (with enough key evidence) the offset that best fits the detected roots
    syms = [s for l in chart.lines for _, s in l.chords]
    k = chart.capo % 12
    chart_roots = {(_parts(s)[0] + k) % 12 for s in syms if _parts(s)}
    if det_roots and len(chart_roots) >= MIN_KEY_EVIDENCE:
        fit = lambda t: (sum((r - t) % 12 in chart_roots for r in det_roots), -min(t, 12 - t))
        k = (k + max(range(12), key=fit)) % 12
    lines = [ChartLine(l.section, l.text, [(o, _transpose(s, k)) for o, s in l.chords]) for l in chart.lines]
    syms = [s for l in lines for _, s in l.chords]

    out: list[str | None] = [None] * n
    put_at: set[int] = set()
    flagged_beats: set[int] = set()
    beat_at = (lambda t: min(range(n), key=lambda i: abs(beats[i] - t))) if n else (lambda t: 0)

    def put(i: int, sym: str) -> None:
        put_at.add(i)
        d = det_parts[i]
        if d is None or _parts(sym) is None:         # nothing heard, or the chart says N.C.
            out[i] = sym
            return
        cr, cb, _ = _parts(sym)
        if (cr, cb) == (d[0], d[1]):
            out[i] = sym
        else:
            out[i] = _over_bass(sym, d[1])
            flagged_beats.add(i)

    def place_line(chords, text, line_words) -> int:
        if not line_words:
            return 0
        norm, starts, pos = _norm_text(text), [], 0
        for w, t in line_words:
            key = _norm_text(w).strip()
            i = norm.find(key, pos) if key else -1
            i = pos if i < 0 else i
            starts.append((i, t))
            pos = i + len(key)
        end = len(text.rstrip())
        after = 0
        for off, sym in chords:
            if off >= end and off > 0:               # written past the end of the lyric: after its last word
                after += 1
                put(min(n - 1, beat_at(starts[-1][1]) + 2 * after), sym)
                continue
            put(nearby(beat_at(max([t for o, t in starts if o <= off], default=starts[0][1])), sym), sym)
        return len(chords)

    def nearby(i: int, sym: str) -> int:
        """A chord written on a word sung just before the change the audio makes lands on that change (the other way
        round, the vocabulary rule already gives the heard beat the chart's chord)."""
        want = _parts(sym)
        if want is None or (det_parts[i] and det_parts[i][:2] == want[:2]):
            return i
        for j in (i + 1,):
            if 0 <= j < n and j not in put_at and det_parts[j] and det_parts[j][:2] == want[:2]:
                return j
        return i

    # 2. placement on the words: chart lines matched to song lines in order, skips allowed
    placed = repeated = 0
    by_text: dict[str, list[tuple[int, str]]] = {}
    used: set[int] = set()
    j = 0
    for cl in lines:
        if not cl.text or not cl.chords:
            continue
        by_text.setdefault(_norm_text(cl.text), cl.chords)
        best, best_r = None, 0.6
        for s in range(j, min(len(lines_text), j + 6)):
            r = SequenceMatcher(None, _norm_text(cl.text), _norm_text(lines_text[s])).ratio()
            if r > best_r:
                best, best_r = s, r
        if best is not None:
            j = best + 1
            used.add(best)
            placed += place_line(cl.chords, cl.text, words[best] if best < len(words) else [])

    # 3a. repetition by text (a repeated chorus)
    for s, txt in enumerate(lines_text):
        if s not in used and s < len(words) and _norm_text(txt) in by_text:
            repeated += place_line(by_text[_norm_text(txt)], txt, words[s])
            used.add(s)

    def fill() -> None:
        """A placed chord lasts while the detected root stays the one heard where it was placed."""
        cur, root = None, None
        for i in range(n):
            if i in put_at:
                cur, root = out[i], (det_parts[i][0] if det_parts[i] else None)
            elif cur is not None and out[i] is None:
                if (det_parts[i][0] if det_parts[i] else None) == root:
                    out[i] = cur
                else:
                    cur = None

    fill()

    # 3b. repetition by detected roots: an empty section copies an earlier section with the same roots, bar by bar
    def bar_of(i: int) -> int:
        return max(b for b, s0 in enumerate(bar_starts) if s0 <= i) if bar_starts else 0

    def bar_root(b: int):
        e = bar_starts[b + 1] if b + 1 < len(bar_starts) else n
        roots = [det_parts[i][0] for i in range(bar_starts[b], e) if det_parts[i]]
        return Counter(roots).most_common(1)[0][0] if roots else None

    sections, cur_sec, last_end = [], [], None
    for s, lw in enumerate(words):
        if not lw:
            continue
        if cur_sec and lw[0][1] - last_end >= SECTION_GAP_S:
            sections.append(cur_sec)
            cur_sec = []
        cur_sec.append(s)
        last_end = lw[-1][1]
    if cur_sec:
        sections.append(cur_sec)
    if bar_starts and sections:
        first_bar = [bar_of(beat_at(words[sec[0]][0][1])) for sec in sections] + [len(bar_starts)]
        spans = [list(range(first_bar[x], first_bar[x + 1])) for x in range(len(sections))]
        for x, span in enumerate(spans):
            if any(out[i] is not None for b in span for i in range(bar_starts[b], (bar_starts[b + 1] if b + 1 < len(bar_starts) else n))):
                continue
            for src in reversed(spans[:x]):
                pairs = [(bar_root(a), bar_root(b)) for a, b in zip(src, span)]
                known = [(a, b) for a, b in pairs if a is not None]
                if not known or sum(a == b for a, b in known) / len(known) < REPEAT_SHARE:
                    continue
                for a, b in zip(src, span):
                    a0, b0 = bar_starts[a], bar_starts[b]
                    a1 = bar_starts[a + 1] if a + 1 < len(bar_starts) else n
                    copied = False
                    for off in range(a1 - a0):
                        v = out[a0 + off] if a0 + off < n else None
                        if v and v != "N.C." and b0 + off < n and (off == 0 or v != out[a0 + off - 1]):
                            put(b0 + off, v)
                            copied = True
                    repeated += copied
                break
        fill()

    # 4. vocabulary: what's left keeps the detection, with the chart's most frequent chord of the same root
    by_root: dict[int, str] = {}
    for s, _ in Counter(x for x in syms if _parts(x)).most_common():
        by_root.setdefault(_parts(s)[0], s)
    vocab = 0
    for i in range(n):
        if out[i] is None:
            d = det_parts[i]
            if d and d[0] in by_root:
                out[i], vocab = by_root[d[0]], vocab + 1
            else:
                out[i] = det[i] or "N.C."
    if not det_roots and not put_at and syms:          # nothing heard, nothing placed: the chart's order
        out = [syms[min(len(syms) - 1, i * len(syms) // max(1, n))] for i in range(n)]

    cells, flagged = [], []
    for b, s0 in enumerate(bar_starts):
        e = bar_starts[b + 1] if b + 1 < len(bar_starts) else n
        chords, prev = [], None
        for i in range(s0, e):
            if out[i] != prev:
                chords.append([i - s0, out[i]])
                prev = out[i]
        cells.append(cell_text(chords, beats_per_bar) if chords else "N.C.")
        if any(i in flagged_beats for i in range(s0, e)):
            flagged.append(b)
    return MergeResult(cells, flagged, placed, repeated, vocab)
