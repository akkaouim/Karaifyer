# Chord Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring human chord charts into Karaifyer:
- a tab Michel pastes, applied immediately in Corriger;
- patadata / Chordonomicon charts, suggested in Corriger;
- Chordonomicon's whole progression, shown in a floating panel.

Each chart is merged with the audio detection by Michel's rules.

**Architecture:**
- **Python:**
  - `karaoke/chord_sources.py` parses every chart format and merges a chart with the song's detection (beats, bars,
    detected per-beat chords from `travail/<id>/chords.json`, word times from the lyrics result). The output is grid
    cells plus flagged bars.
  - `karaoke/grilles.py` downloads the datasets into `$KARAOKE_HOME/grilles/`, links Spotify ids from the recording
    sheet into a new optional manifest column, and precomputes `correspondances.json` and `progressions/<id>.txt`.
  - New CLI group: `karaoke grilles telecharger | lier | fusionner`.
  - `etat --json` exposes `progression` and `grille_proposee`.
- **Swift:**
  - KaraifyerCore gets the progression formatter and the merge-result model.
  - The app calls `grilles fusionner` from Corriger (import sheet, banner) and shows the progression panel.

**Tech Stack:**
- **Python:** 3.11, pytest (`uv --directory karaoke run pytest -q`), pyarrow (new dependency, to read the parquet).
- **Swift:** Swift 6 / SwiftPM, Swift Testing (`swift test --package-path karaifyer -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`).
- **UI state:** SwiftUI without `@State`; state lives in `@Observable` models.

**Spec:** `docs/superpowers/specs/2026-10-23-chord-sources-design.md`

## Global Constraints

- **Merge rules (Michel):**
  - chart chord on a beat with the **same root and bass** as the detection → the chart's chord;
  - **different root or bass** → the chart's chord + `/` + the detected bass (then the existing root-position rename,
    A/F# → F#m7), and the bar is **flagged**;
  - detection N.C. → the chart's chord, no flag;
  - beats not covered by placement or repetition → the vocabulary rule (detected chord → the chart's most frequent
    chord with the same root).
- **Repetition threshold:** 70 % of bars with the same detected root.
- **Bar count:** the merge always returns exactly one cell per existing bar.
- **Detection source:** `travail/<id>/chords.json` segments, from the last detection run. If missing, there's no
  detection: the chart wins everywhere and nothing is flagged.
- **Datasets:**
  - Chordonomicon parquet: `https://huggingface.co/datasets/ailsntua/Chordonomicon/resolve/refs%2Fconvert%2Fparquet/default/train/0000.parquet`,
    91,936,927 bytes, sha256 `64a925d6953371a2a6fd137ada353aae3e3bbbb817fe7c225a6bfb68474602a0`. Its
    `spotify_song_id` is the string `"None"` when absent.
  - patadata: `patacrep/patadata@9722bfc68c9bb68bbc751d1ad3a953be9eb1ea2b`, tarball from `codeload.github.com`, `.sg`
    files only.
- **Files under `$KARAOKE_HOME/grilles/`:** `chordonomicon.parquet`, `patadata/songs/<artist>/<title>.sg`,
  `correspondances.json`, `progressions/<id>.txt`.
- **Manifest:** a new optional last column `spotify` (track id). Older manifests without it still read.
- **Section names in French:**
  intro → Intro, verse → Couplet, chorus → Refrain, prechorus/pre-chorus → Pré-refrain, bridge → Pont, outro → Outro,
  solo → Solo, instrumental → Instrumental, interlude → Interlude; anything else is capitalised as is.
- **UI copy:**
  - « Rechercher la grille… », « Importer une grille… », « Appliquer », « Ignorer »;
  - « Grille trouvée dans <source> : appliquer ? »;
  - « Afficher la progression d'accords »;
  - « grille et audio diffèrent : à vérifier à l'oreille »;
  - « Grilles ouvertes », « Télécharger ».
- **Unchanged:** SysRec (root `Sources/`, `Tests/`, `Package.swift`) is never touched.

## Review Focus

1. **A chart in another key or with a capo:** the transposition must bring it onto the detection before any rule
   applies, otherwise every bar is flagged. Covered by `test_transposition_follows_the_detection` (Task 2).
2. **A tab whose lyrics differ from the song's** (another version, extra lines): placement matches lines in order
   with skips, and unmatched chart lines don't shift the rest. Covered by `test_placement_skips_unmatched_lines`
   (Task 2).
3. **A song with no detection file or no lyric words:** the merge still returns one cell per bar (vocabulary and chart
   order only) without crashing. Covered by `test_merge_without_detection_or_words` (Task 2).
4. **The manifest written by an older Karaifyer** (no `spotify` column), and a sheet whose numbers don't match any
   file: they read fine, nothing is linked, and there's no error. Covered by `test_manifest_without_spotify_column`
   and `test_lier_ignores_unmatched_rows` (Task 3).
5. **Applying a merge in Corriger** is one undoable step. Undo also clears the orange marks. Covered manually (row
   in the checklist) plus `test` coverage of the result model (Task 4).

---

### Task 1: Chart parsing (all formats) — `chord_sources.parse`

**Files:**
- Create: `karaoke/src/karaoke/chord_sources.py`
- Test: `karaoke/tests/test_chord_sources.py`

**Interfaces:**
- Produces:
  - `Chart` (dataclass): `lines: list[ChartLine]`, `capo: int`.
  - `ChartLine`: `section: str | None`, `text: str` (lyric text, empty for chord-only lines), `chords: list[tuple[int, str]]`
    (character offset in `text`, chart symbol).
  - `parse(text: str) -> Chart`, which auto-detects ChordPro `[C]`, patadata `\[C]`, Chordonomicon `<verse_1> C Amin`
    or chords-above-lyrics.
  - `normalise(sym: str) -> str | None`, which turns any chart spelling into a grid symbol, or None when it isn't a
    chord.

- [ ] **Step 1: Failing tests**

```python
# karaoke/tests/test_chord_sources.py
from karaoke.chord_sources import normalise, parse


def test_normalise_spellings():
    assert [normalise(s) for s in ["Amin", "Fs", "Fsmin7", "D/Fs", "B&", "Em7", "Bbmaj7", "Gsus", "H", "Refrain"]] == \
        ["Am", "F#", "F#m7", "D/F#", "Bb", "Em7", "Bbmaj7", "Gsus4", None, None]


def test_chords_above_lyrics_with_column_offsets():
    c = parse("[Verse 1]\nAm        F\nOn vous souhaite tout le bonheur\n   G    Am\nEt que quelqu'un\n")
    assert [(l.section, l.text, l.chords) for l in c.lines] == [
        ("Verse 1", "On vous souhaite tout le bonheur", [(0, "Am"), (10, "F")]),
        ("Verse 1", "Et que quelqu'un", [(3, "G"), (8, "Am")])]


def test_chordpro_and_patadata_inline():
    a = parse("{title: X}\n[Am]On vous sou[F]haite\n")
    b = parse("\\capo{2}\n\\begin{chorus}\n  \\[Am]On vous sou\\[F]haite\n\\end{chorus}\n")
    assert a.lines[0].text == "On vous souhaite" and a.lines[0].chords == [(0, "Am"), (11, "F")]
    assert b.capo == 2 and b.lines[0].section == "chorus" and b.lines[0].chords == [(0, "Am"), (11, "F")]


def test_chordonomicon_progression():
    c = parse("<intro_1> E G <verse_1> D A Bmin <chorus_1> E Fs/As")
    assert [(l.section, l.text, [s for _, s in l.chords]) for l in c.lines] == [
        ("intro_1", "", ["E", "G"]), ("verse_1", "", ["D", "A", "Bm"]), ("chorus_1", "", ["E", "F#/A#"])]


def test_chord_only_lines_and_capo_in_a_tab():
    c = parse("Capo 3\nIntro: Am F C G\n\nAm\nla la\n")
    assert c.capo == 3 and c.lines[0].text == "" and [s for _, s in c.lines[0].chords] == ["Am", "F", "C", "G"]
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv --directory karaoke run pytest -q tests/test_chord_sources.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'karaoke.chord_sources'`

- [ ] **Step 3: Implement**

```python
# karaoke/src/karaoke/chord_sources.py
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
    capo = int(m.group(1)) if (m := re.search(r"\\capo\{(\d+)\}|capo\s*:?\s*(\d+)", text, re.I) and
                               re.search(r"(\d+)", re.search(r"\\capo\{(\d+)\}|capo\s*:?\s*(\d+)", text, re.I).group(0))) else 0
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
```

The capo regex above is convoluted. Simplify it while keeping the behaviour the tests pin:
`m = re.search(r"\\capo\{(\d+)\}|\bcapo\b\D{0,3}(\d+)", text, re.I)` and `capo = int(m.group(1) or m.group(2)) if m else 0`.
Simplifying a helper the tests cover is not a deviation; a change of behaviour would need a ledger ruling.

- [ ] **Step 4: Run the tests and the whole suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/chord_sources.py karaoke/tests/test_chord_sources.py
git commit -m "karaoke: chord chart parsing (tabs, ChordPro, patadata, Chordonomicon)"
```

---

### Task 2: The merge — `chord_sources.merge`

**Files:**
- Modify: `karaoke/src/karaoke/chord_sources.py`
- Test: `karaoke/tests/test_chord_sources.py`

**Interfaces:**
- Consumes: Task 1's `Chart`, `ChartLine`, `normalise`; `chords.symbol`, `cell_text`, `_pc`, `NAME`, `HARTE`.
- Produces:

```python
@dataclass
class MergeResult:
    cells: list[str]          # one per bar
    flagged: list[int]        # bar indices
    placed: int; repeated: int; vocab: int   # counts for the summary line

def merge(chart: Chart, beats: list[float], bar_starts: list[int], beats_per_bar: int,
          detected: list[str], words: list[list[tuple[str, float]]], lines_text: list[str]) -> MergeResult
```

- `detected`: one chart symbol per beat ("N.C." allowed).
- `words`: per song lyric line, `(word, start)`.
- `lines_text`: the song's lyric lines.

- [ ] **Step 1: Failing tests** (append)

```python
from karaoke.chord_sources import Chart, ChartLine, merge

BEATS = [0.5 * i for i in range(16)]
BARS = [0, 4, 8, 12]


def words_at(*lines):            # (text, [start of each word])
    return [list(zip(t.split(), ts)) for t, ts in lines], [t for t, _ in lines]


def test_chart_type_wins_on_same_root():
    w, lt = words_at(("la la", [0.0, 1.0]))
    det = ["C#"] * 8 + ["A"] * 8
    r = merge(Chart([ChartLine(None, "la la", [(0, "C#m")])]), BEATS, BARS, 4, det, w, lt)
    assert r.cells[:2] == ["C#m", "C#m"] and r.flagged == []


def test_different_root_takes_the_detected_bass_and_flags():
    w, lt = words_at(("la la", [0.0, 2.0]))
    det = ["F#m"] * 16
    r = merge(Chart([ChartLine(None, "la la", [(0, "A")])]), BEATS, BARS, 4, det, w, lt)
    assert r.cells[0] == "F#m7" and 0 in r.flagged          # A over F# → F#m7 (Michel's naming)


def test_chorus_repeated_by_text_and_vocabulary_elsewhere():
    w, lt = words_at(("refrain ici", [0.0, 1.0]), ("couplet", [2.0]), ("refrain ici", [6.0, 7.0]))
    det = ["Am"] * 4 + ["C"] * 4 + ["Am"] * 4 + ["G"] * 4
    chart = Chart([ChartLine("chorus", "refrain ici", [(0, "Am7")]), ChartLine("verse", "couplet", [(0, "Cmaj7")])])
    r = merge(chart, BEATS, BARS, 4, det, w, lt)
    assert r.cells[0] == "Am7" and r.cells[1] == "Cmaj7" and r.cells[3].startswith("Am7") and r.repeated >= 1


def test_transposition_follows_the_detection():
    w, lt = words_at(("la", [0.0]))
    det = ["E"] * 16
    r = merge(Chart([ChartLine(None, "la", [(0, "C")])], capo=4), BEATS, BARS, 4, det, w, lt)
    assert r.cells[0] == "E" and r.flagged == []


def test_placement_skips_unmatched_lines():
    w, lt = words_at(("premier vers", [0.0, 0.5]), ("second vers", [4.0, 4.5]))
    chart = Chart([ChartLine(None, "premier vers", [(0, "Am")]), ChartLine(None, "une ligne en trop", [(0, "D")]),
                   ChartLine(None, "second vers", [(0, "G")])])
    r = merge(chart, BEATS, BARS, 4, ["N.C."] * 16, w, lt)
    assert r.cells[0] == "Am" and r.cells[2] == "G" and "D" not in "".join(r.cells)


def test_merge_without_detection_or_words():
    r = merge(Chart([ChartLine("verse_1", "", [(0, "Am"), (1, "F")])]), BEATS, BARS, 4, [], [], [])
    assert len(r.cells) == 4 and all(r.cells)
```

- [ ] **Step 2: Run to verify they fail.** Expected: `ImportError: cannot import name 'merge'`.

- [ ] **Step 3: Implement** (append to `chord_sources.py`)

```python
from difflib import SequenceMatcher
from karaoke.chords import NAME, _pc, cell_text, symbol

_SYM = re.compile(r"^([A-G][#b]?)([^/]*)(?:/([A-G][#b]?))?$")


def _parts(sym: str):
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


def _norm_text(s: str) -> str:
    import unicodedata
    s = unicodedata.normalize("NFKD", s.lower())
    return re.sub(r"[^a-z0-9 ]+", "", "".join(c for c in s if not unicodedata.combining(c))).strip()


@dataclass
class MergeResult:
    cells: list[str]
    flagged: list[int]
    placed: int = 0
    repeated: int = 0
    vocab: int = 0


def _over_bass(chart_sym: str, bass_pc: int) -> str:
    """Chart chord over the detected bass, renamed to root position when the notes match (A/F# → F#m7)."""
    r, _, q = _parts(chart_sym)
    harte = next((k for k, (suf, _) in __import__("karaoke.chords", fromlist=["HARTE"]).HARTE.items() if suf == q), "maj")
    return symbol(f"{NAME[r]}:{harte}/{NAME[bass_pc]}")


def merge(chart, beats, bar_starts, beats_per_bar, detected, words, lines_text) -> MergeResult:
    n = len(beats)
    det = list(detected) + ["N.C."] * max(0, n - len(detected))
    # 1. transposition: capo, then the offset that best matches the detected roots
    chart_syms = [s for l in chart.lines for _, s in l.chords]
    det_roots = [p[0] for p in map(_parts, det) if p]
    def score(k):
        roots = {(_parts(s)[0] + k) % 12 for s in chart_syms if _parts(s)}
        return sum(r in roots for r in det_roots), -min(k, 12 - k)
    k = (chart.capo + max(range(12), key=lambda t: score((chart.capo + t) % 12))) % 12 if det_roots else chart.capo % 12
    lines = [ChartLine(l.section, l.text, [(o, _transpose(s, k)) for o, s in l.chords]) for l in chart.lines]
    out: list[str | None] = [None] * n
    flagged_beats: set[int] = set()
    beat_at = lambda t: min(range(n), key=lambda i: abs(beats[i] - t)) if n else 0
    placed = repeated = vocab = 0

    def put(i: int, sym: str) -> None:
        nonlocal_parts = _parts(det[i])
        if nonlocal_parts is None:
            out[i] = sym
            return
        dr, db, _ = nonlocal_parts
        cr, cb, _ = _parts(sym)
        if cr == dr and cb == db:
            out[i] = sym
        else:
            out[i] = _over_bass(sym, db)
            flagged_beats.add(i)

    # 2. placement on the words: chart lines matched to song lines in order (skips allowed)
    by_text: dict[str, list[tuple[int, str]]] = {}
    j = 0
    used_song = set()
    for cl in lines:
        if not cl.text or not cl.chords:
            continue
        by_text.setdefault(_norm_text(cl.text), cl.chords)
        best, best_r = None, 0.6
        for s in range(j, min(len(lines_text), j + 6)):
            r = SequenceMatcher(None, _norm_text(cl.text), _norm_text(lines_text[s])).ratio()
            if r > best_r:
                best, best_r = s, r
        if best is None:
            continue
        j = best + 1
        used_song.add(best)
        placed += _place_line(cl.chords, cl.text, words[best] if best < len(words) else [], beat_at, put)
    # 3a. repetition by text (a repeated chorus)
    for s, txt in enumerate(lines_text):
        if s in used_song or _norm_text(txt) not in by_text or s >= len(words):
            continue
        repeated += _place_line(by_text[_norm_text(txt)], txt, words[s], beat_at, put)
    # fill forward from each placed chord until the next one
    cur = None
    for i in range(n):
        cur = out[i] if out[i] is not None else cur
        if out[i] is None and cur is not None and _section_continues(i, out, det):
            out[i] = cur
    # 4. vocabulary for the rest (and the whole song for charts without lyrics)
    vocab_map: dict[int, str] = {}
    for s in chart_syms and [_transpose(x, k) for x in chart_syms]:
        r = _parts(s)[0]
        vocab_map.setdefault(r, s)
    for i in range(n):
        if out[i] is None:
            p = _parts(det[i])
            out[i] = vocab_map.get(p[0], det[i]) if p else (det[i] if det[i] else "N.C.")
            vocab += p is not None and p[0] in vocab_map
    if not det_roots and all(o == "N.C." for o in out) and chart_syms:   # no detection at all: chart order
        seq = [_transpose(x, k) for x in chart_syms]
        out = [seq[min(len(seq) - 1, i * len(seq) // max(1, n))] for i in range(n)]
    cells, flagged = [], []
    for b, s in enumerate(bar_starts):
        e = bar_starts[b + 1] if b + 1 < len(bar_starts) else n
        chords, prev = [], None
        for i in range(s, e):
            if out[i] != prev:
                chords.append([i - s, out[i]])
                prev = out[i]
        cells.append(cell_text(chords, beats_per_bar) if chords else "N.C.")
        if any(i in flagged_beats for i in range(s, e)):
            flagged.append(b)
    return MergeResult(cells, flagged, placed, repeated, vocab)


def _place_line(chords, text, line_words, beat_at, put) -> int:
    """Chart chords at character offsets → the word at that offset → its start → that beat."""
    if not line_words:
        return 0
    starts, pos = [], 0
    for w, t in line_words:                     # character offset of each word in the chart line's text
        i = _norm_text(text).find(_norm_text(w), pos)
        starts.append((max(i, pos), t))
        pos = max(i, pos) + len(_norm_text(w))
    for off, sym in chords:
        t = max([t for o, t in starts if o <= off], default=starts[0][1])
        put(beat_at(t), sym)
    return len(chords)


def _section_continues(i, out, det) -> bool:
    """Fill a placed chord forward while the music continues (stop at an N.C. in the detection)."""
    return det[i] != "N.C."
```

Notes for the implementer:
- `_over_bass` must find the Harte quality for the chart suffix. Build a reverse map
  `{suffix: harte_name}` from `chords.HARTE` once at import, instead of the inline `__import__`.
- `vocab_map`: the line `for s in chart_syms and [...]` is a terse guard. Write it as
  `for s in [_transpose(x, k) for x in chart_syms]:` and pick the **most frequent** chart chord per root,
  `Counter`-based, as the spec says. Then the test of the vocabulary rule holds.
- **3b, verse repetition by detected roots, is not in this code block yet.** Implement it after 3a:
  - group the song lines into sections (consecutive lines whose gap is < 4 s);
  - for each section with no placed chord, find the earlier placed section whose per-bar detected roots match at least
    70 %;
  - copy its chords bar by bar, as `put()` calls on the first beat of each bar;
  - count them in `repeated`;
  - add a test `test_verse_repeated_by_detected_roots`: two 2-bar sections with the same detected roots, chords only in
    the first, and the second gets them.

Writing these is part of this task; they are not deviations.

- [ ] **Step 4: Run the tests and the whole suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/chord_sources.py karaoke/tests/test_chord_sources.py
git commit -m "karaoke: merge a chord chart with the detection (placement, repetition, vocabulary, flags)"
```

---

### Task 3: Datasets, Spotify links, CLI and `etat`

**Files:**
- Create: `karaoke/src/karaoke/grilles.py`
- Modify: `karaoke/src/karaoke/manifest.py` (optional `spotify` column)
- Modify: `karaoke/src/karaoke/cli.py` (`grilles` sub-commands)
- Modify: `karaoke/src/karaoke/state.py` (`progression`, `grille_proposee`)
- Modify: `karaoke/pyproject.toml` (add `pyarrow`)
- Test: `karaoke/tests/test_grilles.py`, `karaoke/tests/test_manifest.py`, `karaoke/tests/test_state.py`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `grilles.telecharger(cfg, download=None)`;
  - `grilles.lier(cfg, feuille: Path) -> int`, the number of songs linked;
  - `grilles.indexer(cfg)`, which writes `correspondances.json` (`{id: {"patadata": rel_path | None, "chordonomicon": bool}}`)
    and `progressions/<id>.txt`;
  - `grilles.fusionner(cfg, song, texte: str | None, source: str | None) -> dict`
    (`{cells, flagged, placed, repeated, vocab, source}`);
  - CLI `karaoke grilles telecharger | lier --feuille P | fusionner --id X [--source S] --json` (with `--texte -`
    reading stdin);
  - `etat` song fields `progression` (str | null) and `grille_proposee` ("patadata" | "chordonomicon" | null).

- [ ] **Step 1: Failing tests** (`test_grilles.py`, plus additions to `test_manifest.py` and `test_state.py`)

```python
# karaoke/tests/test_grilles.py
import io, json, tarfile
from pathlib import Path
import pyarrow as pa, pyarrow.parquet as pq
from karaoke import grilles
from karaoke.manifest import read_manifest, write_manifest
from test_manifest import song


def sheet(tmp_path):
    p = tmp_path / "feuille.csv"
    p.write_text(",,,,Nom ou artiste sûr,,\nproposé par,,Titre,Artiste,KaraFun,Lien Spotify,Lien grilles\n"
                 "X,1,Je suis un homme,Zazie,oui,https://open.spotify.com/track/2YNWgxevUxpjZDgW4i5Aky?si=a,\n"
                 "X,7,Inconnu,Y,oui,https://open.spotify.com/track/0000000000000000000000,\n", encoding="utf-8")
    return p


def test_lier_fills_spotify_from_the_sheet_number(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(fichier=Path("/m/01 - Je suis un homme - Zazie.flac"))])
    assert grilles.lier(cfg, sheet(tmp_path)) == 1
    assert read_manifest(cfg.manifest)[0].spotify == "2YNWgxevUxpjZDgW4i5Aky"


def test_lier_ignores_unmatched_rows(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(fichier=Path("/m/99 - Autre - Z.flac"))])
    assert grilles.lier(cfg, sheet(tmp_path)) == 0 and read_manifest(cfg.manifest)[0].spotify == ""


def test_indexer_finds_both_sources_and_saves_the_progression(cfg):
    g = cfg.home / "grilles"
    (g / "patadata" / "songs" / "zazie").mkdir(parents=True)
    (g / "patadata" / "songs" / "zazie" / "je_suis_un_homme.sg").write_text("\\[Am]la\n")
    pq.write_table(pa.table({"chords": ["<verse_1> Amin F", "<verse_1> C", "<verse_1> D"],
                             "spotify_song_id": ["2YNWgxevUxpjZDgW4i5Aky", "dup", "dup"]}), g / "chordonomicon.parquet")
    write_manifest(cfg.manifest, [song(spotify="2YNWgxevUxpjZDgW4i5Aky"), song(id="002", titre="Autre", spotify="dup")])
    grilles.indexer(cfg)
    idx = json.loads((g / "correspondances.json").read_text())
    assert idx["001"] == {"patadata": "songs/zazie/je_suis_un_homme.sg", "chordonomicon": True}
    assert idx["002"]["chordonomicon"] is False                       # two different rows for one id: unreliable
    assert (g / "progressions" / "001.txt").read_text() == "<verse_1> Amin F"
```

Append to `test_manifest.py`:

```python
def test_manifest_without_spotify_column(tmp_path):
    p = tmp_path / "m.csv"
    p.write_text("id,titre,artiste,album,duree_ref_s,isrc,fichier,retirer,decompte_mesures,langue,partie\n"
                 "001,T,A,,1,,/x.flac,,2,fr,\n", encoding="utf-8")
    from karaoke.manifest import read_manifest
    assert read_manifest(p)[0].spotify == ""
```

Append to `test_state.py`:

```python
def test_state_exposes_progression_and_suggestion(cfg):
    s = song()
    g = cfg.home / "grilles"
    (g / "progressions").mkdir(parents=True)
    (g / "progressions" / "001.txt").write_text("<verse_1> Amin F")
    (g / "correspondances.json").write_text(json.dumps({"001": {"patadata": "songs/x/y.sg", "chordonomicon": True}}))
    st = song_state(cfg, s, steps({}))
    assert st["progression"] == "<verse_1> Amin F" and st["grille_proposee"] == "patadata"
    assert song_state(cfg, song(id="002"), steps({}))["grille_proposee"] is None
```

- [ ] **Step 2: Run to verify they fail.** Run: `uv --directory karaoke run pytest -q tests/test_grilles.py
  tests/test_manifest.py tests/test_state.py`. Expected: FAIL (no `grilles` module, no `spotify` field, no
  `progression` key). Add `pyarrow` to the main project's dependencies first (`uv --directory karaoke add pyarrow`) so
  the import is not the failure.

- [ ] **Step 3: Implement**
  - **`manifest.py`:**
    - add `"spotify"` at the end of `COLUMNS`;
    - add `spotify: str = ""` as the last `Song` field;
    - in the row reader, `spotify=(row.get("spotify") or "").strip()`;
    - in `write_manifest`, add `s.spotify` at the end of each row.
  - **`grilles.py`:**
    - `telecharger`: the parquet (stream to `.tmp`, check size and sha256, rename) and the patadata tarball (keep
      only `songs/**/*.sg`, same pinned-commit and atomic `.tmp` pattern as `tools/chords_fetch.py`); then calls
      `indexer`.
    - `lier`:
      - Read the sheet with `csv`. A row's number is its first cell that is an integer; its Spotify id comes from
        `open.spotify.com/(intl-[a-z]+/)?track/([A-Za-z0-9]{22})`.
      - Each manifest song's number is the leading digits of its `fichier` basename, `^(\d+)\s*-`.
      - Set `spotify` where the numbers match, write the manifest, call `indexer` if the datasets exist, and return the
        count.
    - `indexer`:
      - **patadata:** match the slug of `artiste` against artist folders, then the slug of `titre` against file stems.
        Exact slug match first, then « the title slug is contained in the stem » with the same artist.
      - **Chordonomicon:** filter the parquet on the manifest's Spotify ids with pyarrow (`pc.is_in`). An id with
        several distinct `chords` values is unreliable (`False`).
      - Write `correspondances.json` and `progressions/<id>.txt`, the raw `chords` string with its trailing space
        stripped.
    - `fusionner`:
      - **Chart:** the pasted `texte` if given, else the patadata `.sg` or the Chordonomicon progression from
        `correspondances.json`.
      - **Detection:** `ws.work / "chords.json"` segments through `chords_per_beat` over the beats result.
      - **Bars:** from the chords marker's `bars`, mapped to beat indices.
      - **Words:** from the lyrics marker's `lines[].words` (`text`, `start`); `lines_text` from `lines[].text`.
      - Then `merge(...)`. Return `{"cells", "flagged", "placed", "repeated", "vocab", "source"}`.
  - **`cli.py`:** a `grilles` Typer sub-app with the three commands. `fusionner --json` prints the dict as JSON;
    `--texte -` reads stdin.
  - **`state.py`:**
    - `progression`: the content of `grilles/progressions/<id>.txt` or None;
    - `grille_proposee`: "patadata" if the index has a patadata path, else "chordonomicon" if True, else None.

- [ ] **Step 4: Run the whole Python suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/
git commit -m "karaoke: open chord datasets (download, Spotify links, index, progressions) and grilles CLI"
```

---

### Task 4: KaraifyerCore — progression formatting and the merge result

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/ChordSources.swift`
- Modify: `karaifyer/Sources/KaraifyerCore/PipelineModels.swift` (`SongState.progression`, `grillePropose`)
- Test: `karaifyer/Tests/KaraifyerCoreTests/ChordSourcesTests.swift`

**Interfaces:**
- Produces:
  - `ProgressionText.sections(_ raw: String) -> [(title: String, chords: String)]`;
  - `MergeResult: Decodable` (`cells`, `flagged`, `placed`, `repeated`, `vocab`, `source`), with `summary: String`;
  - `SongState.progression: String?`, `SongState.grilleProposee: String?`.

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import KaraifyerCore

struct ChordSourcesTests {
    @Test func progressionSectionsInFrench() {
        let s = ProgressionText.sections("<intro_1> E G D A <verse_1> D A <chorus_1> E Bmin D/Fs <bridge_1> Fsmin7 <weird_2> C ")
        #expect(s.map(\.title) == ["Intro 1", "Couplet 1", "Refrain 1", "Pont 1", "Weird 2"])
        #expect(s.map(\.chords) == ["E G D A", "D A", "E Bm D/F#", "F#m7", "C"])
    }

    @Test func mergeResultSummary() throws {
        let r = try JSONDecoder().decode(MergeResult.self, from: Data(#"{"cells":["Am"],"flagged":[0],"placed":42,"repeated":18,"vocab":3,"source":"collé"}"#.utf8))
        #expect(r.summary == "42 accords placés sur les paroles, 18 complétés par répétition, 1 mesure à vérifier")
    }
}
```

- [ ] **Step 2: Run to verify it fails.** Expected: `cannot find 'ProgressionText'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Chordonomicon's raw progression (`<verse_1> D A Bmin …`) as French sections in the grid's notation.
public enum ProgressionText {
    static let names = ["intro": "Intro", "verse": "Couplet", "chorus": "Refrain", "prechorus": "Pré-refrain",
                        "pre-chorus": "Pré-refrain", "bridge": "Pont", "outro": "Outro", "solo": "Solo",
                        "instrumental": "Instrumental", "interlude": "Interlude"]

    public static func symbol(_ t: String) -> String {
        var s = t.replacingOccurrences(of: "min", with: "m")
        s = s.replacingOccurrences(of: #"(?<=[A-G])s"#, with: "#", options: .regularExpression)
        return s
    }

    public static func sections(_ raw: String) -> [(title: String, chords: String)] {
        let re = try! NSRegularExpression(pattern: #"<([a-z_-]+?)_(\d+)>([^<]*)"#)
        let ns = raw as NSString
        return re.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { m in
            let kind = ns.substring(with: m.range(at: 1)), n = ns.substring(with: m.range(at: 2))
            let title = (names[kind] ?? kind.prefix(1).uppercased() + kind.dropFirst()) + " " + n
            let chords = ns.substring(with: m.range(at: 3)).split(separator: " ").map { symbol(String($0)) }.joined(separator: " ")
            return (title, chords)
        }
    }
}

/// `karaoke grilles fusionner --json`.
public struct MergeResult: Decodable, Equatable, Sendable {
    public var cells: [String]
    public var flagged: [Int]
    public var placed, repeated, vocab: Int
    public var source: String
    public var summary: String {
        let f = flagged.count
        return "\(placed) accords placés sur les paroles, \(repeated) complétés par répétition, \(f) mesure\(f > 1 ? "s" : "") à vérifier"
    }
}
```

In `SongState`, add `public var progression: String?` and `public var grilleProposee: String?`. They decode from
`progression` and `grille_proposee` via `convertFromSnakeCase`.

- [ ] **Step 4: Run the whole Swift suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore karaifyer/Tests/KaraifyerCoreTests
git commit -m "karaifyer: progression formatting and merge result model"
```

---

### Task 5: Corriger — search, import, banner, progression panel

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/EditorModel.swift`
- Modify: `karaifyer/Sources/Karaifyer/EditorView.swift`
- Create: `karaifyer/Sources/Karaifyer/ProgressionPanel.swift`

**Interfaces:**
- Consumes: Task 3's CLI, Task 4's `MergeResult`, `ProgressionText`, `SongState.progression`/`grilleProposee`.
- Produces (UI): `EditorModel.flagged: Set<Int>`, `applyMerge(_:)`, `runMerge(texte:source:)`,
  `suggestionIgnored`.

- [ ] **Step 1: Model.**
  - `flagged: Set<Int>` is part of `Snapshot`, so undo restores and clears it.
  - `applyMerge(_ r: MergeResult)`:
    - in one `edit { }`, set `cells = r.cells` (only when `r.cells.count == cells.count`; otherwise show an error)
      and `flagged = Set(r.flagged)`, and set `chordsDirty = true`;
    - set `mergeSummary = r.summary`.
  - `runMerge(texte: String?, source: String?) async`:
    - runs `Pipeline().args(["grilles", "fusionner", "--id", song.id, "--json"] + (source.map { ["--source", $0] } ?? []) + (texte != nil ? ["--texte", "-"] : []))`
      with `Pipeline().env` through `Process`, writing `texte` to stdin and decoding stdout as `MergeResult`;
    - on failure, sets `loadError` to the last stderr line.
  - Editing a cell by hand removes that bar from `flagged`.
  - `suggestionIgnored`: UserDefaults bool `chordSuggestionIgnored.<id>`.
- [ ] **Step 2: View.**
  - Under the chords header, a row with:
    - « Rechercher la grille… », which opens two URLs:
      `https://www.ultimate-guitar.com/search.php?search_type=title&value=<titre artiste>` and
      `https://www.boiteachansons.net/recherche?q=<titre artiste>` (percent-encoded);
    - « Importer une grille… », which opens a sheet: a `TextEditor` bound to a draft, « Ouvrir un fichier… »
      (NSOpenPanel for txt/cho/chopro/sg), « Appliquer » (`runMerge(texte:)`, then close) and « Annuler »;
    - « Afficher la progression d'accords », disabled when `song.progression == nil`.
  - **Banner**, when `song.grilleProposee != nil && !suggestionIgnored`: « Grille trouvée dans \(source) :
    appliquer ? » with « Appliquer » (`runMerge(texte: nil, source:)`) and « Ignorer ».
  - **Flagged cells:** an orange stroke, with help « grille et audio diffèrent : à vérifier à l'oreille ». The red
    error stroke wins when both apply.
  - **Summary:** `mergeSummary` as a caption under the help line.
- [ ] **Step 3: Progression panel** (`ProgressionPanel.swift`):
  - A `@MainActor enum ProgressionPanel` with `static func show(title:raw:)` and `static func close()`.
  - It creates (or brings forward) a floating `NSPanel` (`.utilityWindow`, `.titled`, `.closable`, `.resizable`;
    `isFloatingPanel = true`; `hidesOnDeactivate = false`; `level = .floating`), titled « Progression — \(title) ».
  - Its content is an `NSHostingView` listing `ProgressionText.sections` as « Title : chords », one per row,
    monospaced, selectable.
  - The panel is per song: a dictionary keyed by song id.
  - `EditorView.onDisappear` calls `ProgressionPanel.close(id:)`.
- [ ] **Step 4: Build and install**, then a manual smoke run on song 042. Run
  `uv --directory karaoke run karaoke grilles fusionner --id 042 --texte - --json < chart.txt` with a small
  chords-above-lyrics chart. Expected: JSON with one cell per bar.
- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/Karaifyer
git commit -m "karaifyer editor: search and import a chord chart, dataset suggestion banner, progression panel, orange checks"
```

---

### Task 6: Réglages download, real data, docs

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/SettingsView.swift` (« Grilles ouvertes » row)
- Modify: `karaifyer/Sources/Karaifyer/KaraokeModel.swift` (run `grilles telecharger`, then `grilles lier --feuille <lastList>`)
- Modify: `docs/guide/GUIDE.md`, `docs/karaoke/karaifyer-validation.md`, `karaoke/README.md`, `karaifyer/README.md`

- [ ] **Step 1: Réglages row.**
  - It shows « Grilles ouvertes », the date of `grilles/correspondances.json` (or « pas encore téléchargées ») and a
    « Télécharger » button.
  - The button runs `grilles telecharger`, then `grilles lier --feuille <UserDefaults lastList>` when that file
    exists, then `KaraokeModel.refresh()`.
  - Progress text shows « téléchargement… » / « N morceaux reliés ».
  - One caption gives the licences: « Chordonomicon (CC BY-NC 4.0, d'après Ultimate Guitar) et patadata (sans
    licence déclarée) : usage privé. »
- [ ] **Step 2: Real data.**
  - Run `uv --directory karaoke run karaoke grilles telecharger`, then
    `karaoke grilles lier --feuille "<the sheet in UserDefaults lastList>"`.
  - Expected: `correspondances.json` lists patadata for 042 (Tout le bonheur du monde) and other matches; at least 30
    songs get a progression. These figures come from the spike's coverage check.
  - Then run `karaoke grilles fusionner --id 005 --texte - --json` with a chords-above-lyrics version of Michel's
    Danser chart. Expected: F#m7 where he wrote A/F#, C#m (not C#), one cell per bar.
- [ ] **Step 3: Docs.**
  - **Guide:** a « Grilles d'accords » subsection in the Corriger section (search, import, banner, panel, orange
    marks, the merge rules in Michel's words) and a Réglages line.
  - **Checklist rows:** paste a tab and listen to the orange bars; accept/ignore a suggestion; the panel stays above
    and closes with the window; download in Réglages.
- [ ] **Step 4: Commit**

```bash
git add karaifyer docs karaoke/README.md
git commit -m "karaifyer: download open chord charts from Réglages; docs"
```
