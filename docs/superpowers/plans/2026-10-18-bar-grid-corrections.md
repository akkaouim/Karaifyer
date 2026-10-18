# Bar Grid Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Michel fix where beat 1 falls and the time signature in the « Corriger » window, hear it with an optional click, and have the fix survive every re-analysis.

**Architecture:**
- **Fix file.** A small fix file `mesures/<id>.json` (signature, swing, pinned bar lines as times) is applied by the
  `beats` step after `grid.regularize`. Every consumer (chords, click track, video, iReal) gets the fixed bar lines
  through the existing data flow.
- **The same rule in two languages.** The rule lives in `karaoke/barfix.py` and is mirrored in Swift
  (`KaraifyerCore/BarGrid.swift`), so the editor redraws immediately. Both are tested on the same cases.
- **Editor click.** The editor's click is a second `AVAudioPlayer` playing an in-memory WAV rendered by
  `KaraifyerCore/ClickTrack.swift`.

**Tech Stack:**
- **Python 3.11:** pytest, run with `uv --directory karaoke run pytest -q`.
- **Swift 6 / SwiftPM, Command Line Tools only:** Swift Testing, run with `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
  from `karaifyer/`. SwiftUI without `@State`: UI state lives in `@Observable` models.

**Spec:** `docs/superpowers/specs/2026-10-18-bar-grid-corrections-design.md`

## Global Constraints

- **Time signature menu:** 2/4, 3/4, 4/4, 6/8, 12/8, plus a « Swing » checkbox.
- **Beats per bar:**
  - x/4 → x.
  - 6/8 → 2 and 12/8 → 4 when the detected tempo is ≤ 120 BPM; ×3 (6 and 12) above 120 BPM.
  - No signature → the detected value.
- **Pins:** stored as seconds in input time, snapped to the nearest beat.
- **Bar lines:**
  - Before the first anchor, the cleaned bar lines stay as they are.
  - From each anchor to the next (or the end), there's a line every N beats.
  - With a signature, the first cleaned bar line is an implicit anchor, unless a pin lies before
    `first line + N beats`.
- **File:** `mesures/<id>.json` = `{"signature": "12/8"|null, "swing": bool, "pins": [seconds]}`, deleted when
  there's neither a signature, nor swing, nor pins.
- **Re-runs:**
  - The `beats` step key stays `"beat_this-final0"` for a song without a fix file, so unfixed songs don't re-run.
  - With a fix file, the key adds `|` + the file's sha1.
  - When the raw `travail/<id>/beats.json` exists, the beat detection tool isn't re-run.
- **iReal:**
  - Signature codes: 2/4 `T24`, 3/4 `T34`, 4/4 `T44`, 6/8 `T68`, 12/8 `T12`.
  - Style: Waltz for 3 beats or 3/4 or 6/8; Slow Rock for 12/8; Medium Swing for 4/4 with swing; Pop otherwise.
- **Editor click:** the « Clic » checkbox and its volume are remembered for all songs (UserDefaults
  `editorClickOn`, `editorClickVolume`, default off and 0.7). It uses the same click sound as `grid.render_click`
  (1600 Hz accent, 1000 Hz otherwise, 25 ms, 6 ms decay).
- **UI copy (French):**
  - « Clic »;
  - « La mesure commence un temps plus tôt »;
  - « La mesure commence un temps plus tard »;
  - « Le temps 1 est ici »;
  - « Retirer le repère »;
  - « Swing »;
  - « Détectée (N/4) ».
- **SysRec** (root `Sources/`, `Tests/`, `Package.swift`) is never touched.

## Review Focus

1. **A song analysed before this change** (its beats result has no `downbeats_detectees`): `etat` must still give a
   grid. The editor opens, and its grid controls work from `downbeats`. Covered by
   `test_state_grid_falls_back_for_old_results` (Task 2).
2. **A grid change on a song that already has `accords/<id>.txt`:** after re-analysis, the chords step must find as
   many cells as bars, or it raises. Covered by `test_correction_follows_fixed_bar_lines` (Task 2) and
   `recutKeepsChordsOnTheirBeats` (Task 3); the editor rewrites the chart whenever the grid changed and a chart
   exists (Task 5).
3. **Pins that snap to the same beat, lie outside the song, or are duplicated:** deduped, with no crash. Covered by
   `test_pins_dedupe_and_clamp` (Task 1) and `pinsDedupeAndClamp` (Task 3).
4. **Undo across a grid change** restores the cells and the fix together. Task 5 puts `fix` and `gridDirty` in the
   snapshot; checked manually (checklist row 33).
5. **The click stays aligned** after a seek, pause/resume, and a grid change during playback. Task 5 restarts the
   click player from the main player's time on each of these; checked manually (checklist row 32).

---

### Task 1: Python fix rule (`barfix.py`) and the `mesures/` folder

**Files:**
- Create: `karaoke/src/karaoke/barfix.py`
- Modify: `karaoke/src/karaoke/config.py` (add `mesures`, create it in `ensure_dirs`)
- Test: `karaoke/tests/test_barfix.py`
- Modify: `docs/superpowers/specs/2026-10-18-bar-grid-corrections-design.md` (add the implicit-anchor
  clarification from Global Constraints)

**Interfaces:**
- Produces:
  - `barfix.load(path: Path) -> dict` (keys signature, swing, pins);
  - `barfix.beats_in_bar(signature: str | None, detected: int, bpm: float) -> int`;
  - `barfix.apply_fix(beats: list[float], downbeats: list[float], fix: dict, detected_bpb: int, bpm: float) -> tuple[list[float], int]`;
  - `barfix.EMPTY`;
  - `Config.mesures -> Path`.

- [ ] **Step 1: Write the failing tests**

```python
# karaoke/tests/test_barfix.py
import json
from karaoke.barfix import EMPTY, apply_fix, beats_in_bar, load

BEATS = [0.5 * i for i in range(32)]
DOWN = BEATS[::4]


def fix(**kw):
    return {**EMPTY, **kw}


def test_no_fix_keeps_the_detection():
    assert apply_fix(BEATS, DOWN, EMPTY, 4, 100.0) == (DOWN, 4)


def test_a_pin_restarts_the_count_from_there():
    lines, n = apply_fix(BEATS, DOWN, fix(pins=[9.1]), 4, 100.0)     # snaps to beat 18 (9.0)
    assert n == 4 and lines == [0.0, 2.0, 4.0, 6.0, 8.0, 9.0, 11.0, 13.0, 15.0]


def test_signature_regroups_from_the_first_line():
    lines, n = apply_fix(BEATS, DOWN, fix(signature="3/4"), 4, 100.0)
    assert n == 3 and lines == BEATS[::3]


def test_compound_meters_follow_the_tempo():
    assert beats_in_bar("6/8", 4, 100.0) == 2 and beats_in_bar("6/8", 4, 140.0) == 6
    assert beats_in_bar("12/8", 4, 120.0) == 4 and beats_in_bar("12/8", 4, 121.0) == 12
    assert beats_in_bar(None, 3, 100.0) == 3 and beats_in_bar("2/4", 4, 100.0) == 2


def test_an_early_pin_replaces_the_implicit_anchor():
    lines, n = apply_fix(BEATS, DOWN[1:], fix(signature="4/4", pins=[1.5]), 4, 100.0)  # first line 2.0, pin 1.5
    assert lines[:3] == [1.5, 3.5, 5.5]


def test_pins_dedupe_and_clamp():
    lines, _ = apply_fix(BEATS, DOWN, fix(pins=[9.0, 9.1, 8.9, 99.0, -3.0]), 4, 100.0)
    assert lines == sorted(set(lines)) and lines[0] == 0.0 and lines[-1] <= BEATS[-1]


def test_load_missing_and_partial_files(tmp_path):
    assert load(tmp_path / "none.json") == EMPTY
    p = tmp_path / "x.json"
    p.write_text(json.dumps({"pins": [3.0]}))
    assert load(p) == {"signature": None, "swing": False, "pins": [3.0]}
    p.write_text("not json")
    assert load(p) == EMPTY
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv --directory karaoke run pytest -q tests/test_barfix.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'karaoke.barfix'`

- [ ] **Step 3: Implement**

```python
# karaoke/src/karaoke/barfix.py
"""Michel's bar-grid fix (mesures/<id>.json): time signature, swing, pinned bar lines.

Applied by the `beats` step after grid.regularize; Karaifyer's BarGrid implements the same rule.
- beats per bar: x/4 → x; 6/8 → 2 and 12/8 → 4 at ≤ 120 BPM (beats = dotted quarters), ×3 above (eighths);
- pins (seconds) snap to the nearest beat; from each anchor a bar line every N beats until the next one;
- with a signature, the first detected bar line is an implicit anchor unless a pin lies before it + N beats.
"""
from __future__ import annotations
import json
from pathlib import Path

SIGNATURES = {"2/4": 2, "3/4": 3, "4/4": 4, "6/8": 2, "12/8": 4}
EIGHTHS_BPM = 120.0
EMPTY = {"signature": None, "swing": False, "pins": []}


def load(path: Path) -> dict:
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return dict(EMPTY)
    sig = d.get("signature")
    return {"signature": sig if sig in SIGNATURES else None, "swing": bool(d.get("swing", False)),
            "pins": [float(t) for t in d.get("pins", []) if isinstance(t, (int, float))]}


def beats_in_bar(signature: str | None, detected: int, bpm: float) -> int:
    if signature not in SIGNATURES:
        return detected
    n = SIGNATURES[signature]
    return n * 3 if signature.endswith("/8") and bpm > EIGHTHS_BPM else n


def _nearest(beats: list[float], t: float) -> int:
    return min(range(len(beats)), key=lambda i: abs(beats[i] - t))


def apply_fix(beats: list[float], downbeats: list[float], fix: dict, detected_bpb: int,
              bpm: float) -> tuple[list[float], int]:
    n = beats_in_bar(fix.get("signature"), detected_bpb, bpm)
    if not beats:
        return list(downbeats), n
    anchors = sorted({_nearest(beats, t) for t in fix.get("pins", [])})
    if fix.get("signature") and downbeats:
        first = _nearest(beats, downbeats[0])
        if not anchors or anchors[0] >= first + n:
            anchors = sorted(set(anchors) | {first})
    if not anchors:
        return list(downbeats), n
    out = [d for d in downbeats if d < beats[anchors[0]] - 1e-6]
    for k, a in enumerate(anchors):
        end = anchors[k + 1] if k + 1 < len(anchors) else len(beats)
        out += [beats[i] for i in range(a, end, n)]
    return out, n
```

In `config.py`, after the `accords` property:

```python
    @property
    def mesures(self) -> Path:
        """Michel's bar-grid fixes (mesures/<id>.json: signature, swing, pinned bar lines)."""
        return self.home / "mesures"
```

and add `self.mesures` to the tuple in `ensure_dirs`.

- [ ] **Step 4: Run the tests**

Run: `uv --directory karaoke run pytest -q tests/test_barfix.py tests/test_config.py`
Expected: all pass

- [ ] **Step 5: Spec clarification and commit**

In the spec's « The rule » section, replace the sentence about the implicit pin with: « With a signature, the
first cleaned bar line is an implicit pin, unless a pin lies before it + N beats. »

```bash
git add karaoke/src/karaoke/barfix.py karaoke/src/karaoke/config.py karaoke/tests/test_barfix.py docs/superpowers/specs/2026-10-18-bar-grid-corrections-design.md
git commit -m "karaoke: bar-grid fix rule (mesures/<id>.json)"
```

---

### Task 2: Pipeline: `beats` applies the fix; chords, iReal and `etat` follow

**Files:**
- Modify: `karaoke/src/karaoke/steps/beats.py`
- Modify: `karaoke/src/karaoke/steps/chords.py`
- Modify: `karaoke/src/karaoke/ireal.py`
- Modify: `karaoke/src/karaoke/state.py`
- Test: `karaoke/tests/test_beats_step.py`, `karaoke/tests/test_ireal.py`, `karaoke/tests/test_state.py`,
  `karaoke/tests/test_chord_override.py`

**Interfaces:**
- Consumes: Task 1's `barfix.load`, `barfix.apply_fix`, `Config.mesures`.
- Produces:
  - **The beats result:**
    - `beats`, `downbeats` (fixed), `nettoyage`;
    - `downbeats_detectees` (cleaned, before the fix);
    - `beats_per_bar_detecte`;
    - `beats_per_bar` (after the fix);
    - `bpm` (beat-level, `tempo_stats`);
    - `signature` (str | None), `swing` (bool).
  - **The chords result** adds `signature`, `swing`.
  - **`ireal.style_for(beats_per_bar: int, signature: str | None, swing: bool) -> str`** and
    `ireal.signature_code(beats_per_bar: int, signature: str | None) -> str`; `song_url` takes
    `signature: str | None = None`.
  - **`etat` song:**
    - `"grid": {"beats", "downbeats_detectees", "beats_per_bar_detecte", "bpm", "signature", "swing"}` or `null`;
    - `paths.mesures_corrige`.

- [ ] **Step 1: Write the failing tests**

Append to `karaoke/tests/test_beats_step.py`:

```python
def test_beats_step_applies_the_fix_file_and_reuses_the_raw_detection(cfg, monkeypatch):
    from karaoke.steps import beats as B
    from karaoke.workspace import Workspace
    from test_manifest import song
    full = [round(0.5 * i, 4) for i in range(32)]
    calls = []
    def fake(tool, args, **kw):
        calls.append(tool)
        Path(args[3]).write_text(json.dumps({"beats": full, "downbeats": full[::4]}))
    monkeypatch.setattr(B, "run_tool", fake)
    s = song()
    ws = Workspace(cfg, s)
    ws.work.mkdir(parents=True, exist_ok=True)
    assert B.BEATS.key(ws) == "beat_this-final0"                        # no fix file: unchanged key
    B.BEATS.run(ws, {"ingest": {"duration_s": 16.0}})
    cfg.mesures.mkdir(parents=True, exist_ok=True)
    (cfg.mesures / f"{s.id}.json").write_text(json.dumps({"signature": "3/4", "swing": True, "pins": []}))
    assert B.BEATS.key(ws).startswith("beat_this-final0|")
    r = B.BEATS.run(ws, {"ingest": {"duration_s": 16.0}})
    assert calls == ["beats"]                                            # raw beats.json reused
    assert r["downbeats"] == full[::3] and r["beats_per_bar"] == 3 and r["signature"] == "3/4" and r["swing"]
    assert r["downbeats_detectees"] == full[::4] and r["beats_per_bar_detecte"] == 4 and r["bpm"] == 120.0
```

Append to `karaoke/tests/test_ireal.py`:

```python
def test_signature_codes_and_styles():
    from karaoke.ireal import signature_code, style_for
    assert [signature_code(n, s) for n, s in [(4, None), (3, None), (2, "6/8"), (4, "12/8"), (12, "12/8"), (2, "2/4")]] == \
        ["T44", "T34", "T68", "T12", "T12", "T24"]
    assert style_for(3, None, False) == "Waltz" and style_for(2, "6/8", False) == "Waltz"
    assert style_for(4, "12/8", False) == "Slow Rock" and style_for(4, "4/4", True) == "Medium Swing"
    assert style_for(4, None, False) == "Pop"
    url = unquote(song_url("X", "Y", "Slow Rock", "C major", BARS[:1], 4, 60.0, signature="12/8"))
    assert "[T12" in url
```

Append to `karaoke/tests/test_state.py`:

```python
def test_state_exposes_the_grid(cfg):
    s = song()
    ws = Workspace(cfg, s)
    ws.write_marker("beats", {"result": {"beats": [0.0, 0.5, 1.0, 1.5, 2.0], "downbeats": [0.0, 1.0],
                                         "downbeats_detectees": [0.0, 2.0], "beats_per_bar_detecte": 4,
                                         "beats_per_bar": 2, "bpm": 120.0, "signature": "2/4", "swing": False}})
    st = song_state(cfg, s, steps({}))
    assert st["grid"] == {"beats": [0.0, 0.5, 1.0, 1.5, 2.0], "downbeats_detectees": [0.0, 2.0],
                          "beats_per_bar_detecte": 4, "bpm": 120.0, "signature": "2/4", "swing": False}
    assert st["paths"]["mesures_corrige"].endswith(f"mesures/{s.id}.json")
    assert song_state(cfg, song(id="002"), steps({}))["grid"] is None


def test_state_grid_falls_back_for_old_results(cfg):
    s = song()
    beats = [0.5 * i for i in range(16)]
    Workspace(cfg, s).write_marker("beats", {"result": {"beats": beats, "downbeats": beats[::4]}})
    g = song_state(cfg, s, steps({}))["grid"]
    assert g["downbeats_detectees"] == beats[::4] and g["beats_per_bar_detecte"] == 4
    assert g["bpm"] == 120.0 and g["signature"] is None and g["swing"] is False
```

Append to `karaoke/tests/test_chord_override.py`:

```python
def test_correction_follows_fixed_bar_lines(cfg):
    from karaoke.steps.chords import CHORDS
    from karaoke.workspace import Workspace
    from test_manifest import song
    s = song()
    ws = Workspace(cfg, s)
    cfg.accords.mkdir(parents=True, exist_ok=True)
    beats = [0.5 * i for i in range(12)]
    # fixed lines: a 2-beat bar, then 4 + 4 + 2 → 4 bars
    (cfg.accords / f"{s.id}.txt").write_text("Tonalité : C major · 4/4\n\n| C | F | G | C |\n", encoding="utf-8")
    up = {"ingest": {"duration_s": 6.0}, "separate": {},
          "beats": {"beats": beats, "downbeats": [0.0, 1.0, 3.0, 5.0], "beats_per_bar": 4,
                    "signature": "4/4", "swing": False}}
    r = CHORDS.run(ws, up)
    assert len(r["bars"]) == 4 and r["signature"] == "4/4" and r["swing"] is False
    assert "· 4/4" in (ws.out / "accords.txt").read_text(encoding="utf-8")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv --directory karaoke run pytest -q tests/test_beats_step.py tests/test_ireal.py tests/test_state.py tests/test_chord_override.py`
Expected: FAIL (`AttributeError`/`KeyError` on `beats_per_bar`, `signature_code`, `grid`, `signature`)

- [ ] **Step 3: Implement**

`steps/beats.py`:

```python
from karaoke import barfix
from karaoke.grid import beats_per_bar, regularize, tempo_stats
import hashlib


def _fix_path(ws: Workspace):
    return ws.cfg.mesures / f"{ws.song.id}.json"


def _run(ws: Workspace, upstream: dict) -> dict:
    out = ws.work / "beats.json"
    if not out.exists():           # a fix-only change must not re-run the detection
        run_tool("beats", ["python", str(TOOLS_DIR / "beats" / "beats_tool.py"), str(ws.work / "input.wav"),
                           str(out), "--device", os.environ.get("KARAOKE_DEVICE", "mps")],
                 timeout=tool_timeout("beats", upstream["ingest"]["duration_s"]))
    data = json.loads(out.read_text())
    if len(data["beats"]) < 8:
        raise ValueError(f"trop peu de temps détectés ({len(data['beats'])})")
    beats, detected, info = regularize(data["beats"], data["downbeats"])
    bpb, bpm = beats_per_bar(beats, detected), tempo_stats(beats)["bpm"]
    fix = barfix.load(_fix_path(ws))
    downbeats, n = barfix.apply_fix(beats, detected, fix, bpb, bpm)
    return {"beats": beats, "downbeats": downbeats, "nettoyage": info, "downbeats_detectees": detected,
            "beats_per_bar_detecte": bpb, "beats_per_bar": n, "bpm": bpm,
            "signature": fix["signature"], "swing": fix["swing"]}


def _key(ws: Workspace) -> str:
    p = _fix_path(ws)
    return "beat_this-final0" + (f"|{hashlib.sha1(p.read_bytes()).hexdigest()}" if p.exists() else "")


BEATS = Step(name="beats", deps=("ingest",), key=_key, run=_run,
             version="2")   # 2: grid cleanup (half-tempo gaps, stray beats, bar lines); fix file via the key
```

The existing test's raw `beats.json` is written by the fake tool, so `test_beats_step_cleans_the_detected_grid`
still runs the tool once. Keep `version="2"` so that unfixed songs don't re-run.

`steps/chords.py` `_run`:
- replace `bpb = beats_per_bar(beats, downbeats)` with:

  ```python
  up = upstream["beats"]
  bpb = up.get("beats_per_bar") or beats_per_bar(beats, downbeats)
  signature, swing = up.get("signature"), bool(up.get("swing", False))
  ```
- the `accords.txt` header uses `{signature or f'{bpb}/4'}` in place of `{bpb}/4`;
- the success return adds `"signature": signature, "swing": swing`;
- the early-return error dict adds `"signature": None, "swing": False`.

`ireal.py`:

```python
CODES = {"2/4": "T24", "3/4": "T34", "4/4": "T44", "6/8": "T68", "12/8": "T12"}


def signature_code(beats_per_bar: int, signature: str | None) -> str:
    return CODES.get(signature or "", f"T{beats_per_bar}4")


def style_for(beats_per_bar: int, signature: str | None, swing: bool) -> str:
    if signature in ("3/4", "6/8") or (signature is None and beats_per_bar == 3):
        return "Waltz"
    if signature == "12/8":
        return "Slow Rock"
    return "Medium Swing" if swing else "Pop"
```

- `song_url(..., beats_per_bar, bpm, signature: str | None = None)` builds `prog = "[" + signature_code(beats_per_bar, signature) + " |".join(cells) + " Z"`.
- In `write_pages`:
  - `style = style_for(r["beats_per_bar"], r.get("signature"), r.get("swing", False))`;
  - pass `signature=r.get("signature")`.

`state.py` `song_state`:

```python
    bt = (ws.read_marker("beats") or {}).get("result") or {}
    grid = None
    if bt.get("beats"):
        from karaoke.grid import beats_per_bar, tempo_stats
        det = bt.get("downbeats_detectees", bt.get("downbeats", []))
        grid = {"beats": bt["beats"], "downbeats_detectees": det,
                "beats_per_bar_detecte": bt.get("beats_per_bar_detecte") or beats_per_bar(bt["beats"], det),
                "bpm": bt.get("bpm") or tempo_stats(bt["beats"])["bpm"],
                "signature": bt.get("signature"), "swing": bool(bt.get("swing", False))}
```

- add `"grid": grid` to the returned dict;
- add `"mesures_corrige": str(cfg.mesures / f"{s.id}.json")` to `paths`.

- [ ] **Step 4: Run the whole Python suite**

Run: `uv --directory karaoke run pytest -q`
Expected: all pass (≥ 223 + the new tests)

- [ ] **Step 5: Commit**

```bash
git add karaoke/src karaoke/tests
git commit -m "karaoke: beats step applies mesures/<id>.json; signature and swing to chords, iReal and etat"
```

---

### Task 3: Swift rule (`BarGrid`) and the fix file model

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/BarGrid.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/BarGridTests.swift`

**Interfaces:**
- Consumes: `ChordGrid.parseCell`, `ChordGrid.cellText`, `ChordAt`.
- Produces:

```swift
public struct BarFix: Codable, Equatable, Sendable {
    public var signature: String?; public var swing: Bool; public var pins: [Double]
    public static let empty: BarFix
    public var isEmpty: Bool
    public static func decode(_ data: Data?) -> BarFix
    public func encoded() -> Data
}
public enum BarGrid {
    public static let menu: [String]                       // ["2/4", "3/4", "4/4", "6/8", "12/8"]
    public static func beatsInBar(signature: String?, detected: Int, bpm: Double) -> Int
    public static func nearest(_ beats: [Double], _ t: Double) -> Int
    public static func lines(beats: [Double], detected: [Double], fix: BarFix, detectedBPB: Int, bpm: Double) -> (lines: [Int], bpb: Int)
    public static func starts(_ lines: [Int]) -> [Int]      // bar starts as beat indices, 0 prepended (pickup)
    public static func moved(_ fix: BarFix, beats: [Double], line: Int, by delta: Int) -> BarFix
    public static func pinned(_ fix: BarFix, beats: [Double], line: Int) -> BarFix
    public static func unpinned(_ fix: BarFix, beats: [Double], line: Int) -> BarFix
    public static func hasPin(_ fix: BarFix, beats: [Double], line: Int) -> Bool
    public static func recut(cells: [String], from old: [Int], oldBPB: Int, to new: [Int], newBPB: Int, beatCount: Int) -> [String]?
    public static func beatInBar(index: Int?, starts: [Int], beatCount: Int) -> (beat: Int, of: Int)?
}
```

- [ ] **Step 1: Write the failing tests** (the same cases as `test_barfix.py`)

```swift
import Foundation
import Testing
@testable import KaraifyerCore

struct BarGridTests {
    let beats = (0..<32).map { Double($0) * 0.5 }
    var down: [Double] { stride(from: 0, to: 32, by: 4).map { beats[$0] } }

    @Test func noFixKeepsTheDetection() {
        let r = BarGrid.lines(beats: beats, detected: down, fix: .empty, detectedBPB: 4, bpm: 100)
        #expect(r.lines == Array(stride(from: 0, to: 32, by: 4)) && r.bpb == 4)
    }

    @Test func aPinRestartsTheCount() {
        let f = BarFix(signature: nil, swing: false, pins: [9.1])
        #expect(BarGrid.lines(beats: beats, detected: down, fix: f, detectedBPB: 4, bpm: 100).lines == [0, 4, 8, 12, 16, 18, 22, 26, 30])
    }

    @Test func signatureRegroups() {
        let f = BarFix(signature: "3/4", swing: false, pins: [])
        let r = BarGrid.lines(beats: beats, detected: down, fix: f, detectedBPB: 4, bpm: 100)
        #expect(r.bpb == 3 && r.lines == Array(stride(from: 0, to: 32, by: 3)))
    }

    @Test func compoundMeters() {
        #expect(BarGrid.beatsInBar(signature: "6/8", detected: 4, bpm: 100) == 2)
        #expect(BarGrid.beatsInBar(signature: "6/8", detected: 4, bpm: 140) == 6)
        #expect(BarGrid.beatsInBar(signature: "12/8", detected: 4, bpm: 121) == 12)
        #expect(BarGrid.beatsInBar(signature: nil, detected: 3, bpm: 100) == 3)
    }

    @Test func earlyPinReplacesImplicitAnchor() {
        let f = BarFix(signature: "4/4", swing: false, pins: [1.5])
        #expect(BarGrid.lines(beats: beats, detected: Array(down.dropFirst()), fix: f, detectedBPB: 4, bpm: 100).lines.prefix(3) == [3, 7, 11])
    }

    @Test func pinsDedupeAndClamp() {
        let f = BarFix(signature: nil, swing: false, pins: [9.0, 9.1, 8.9, 99, -3])
        let l = BarGrid.lines(beats: beats, detected: down, fix: f, detectedBPB: 4, bpm: 100).lines
        #expect(l == Array(Set(l)).sorted() && l.first == 0 && l.last! < beats.count)
    }

    @Test func moveAndPin() {
        var f = BarGrid.moved(.empty, beats: beats, line: 16, by: 1)
        #expect(f.pins == [8.5])
        f = BarGrid.moved(f, beats: beats, line: 17, by: 1)                 // moves the existing pin
        #expect(f.pins == [9.0] && BarGrid.hasPin(f, beats: beats, line: 18))
        f = BarGrid.pinned(f, beats: beats, line: 4)
        #expect(f.pins == [2.0, 9.0])
        #expect(BarGrid.unpinned(f, beats: beats, line: 18).pins == [2.0])
        #expect(BarGrid.moved(.empty, beats: beats, line: 0, by: -1) == .empty)   // out of range: unchanged
    }

    @Test func recutKeepsChordsOnTheirBeats() {
        // 4 bars of 4 → a pin at beat 6: bars [0,4) [4,6) [6,10) [10,14) [14,16)
        let cells = ["C", "F", "G", "Am"]
        let new = [0, 4, 6, 10, 14]
        let r = BarGrid.recut(cells: cells, from: [0, 4, 8, 12], oldBPB: 4, to: new, newBPB: 4, beatCount: 16)!
        #expect(r.count == new.count)
        #expect(r == ["C", "F", "F . G .", "G . Am .", "Am"])
        #expect(BarGrid.recut(cells: ["C", "H"], from: [0, 4], oldBPB: 4, to: [0], newBPB: 4, beatCount: 8) == nil)
    }

    @Test func beatCounter() {
        #expect(BarGrid.beatInBar(index: 5, starts: [0, 4, 6], beatCount: 10)! == (2, 2))
        #expect(BarGrid.beatInBar(index: 7, starts: [0, 4, 6], beatCount: 10)! == (2, 4))
        #expect(BarGrid.beatInBar(index: nil, starts: [0], beatCount: 10) == nil)
    }

    @Test func fixFileRoundTrip() {
        let f = BarFix(signature: "12/8", swing: true, pins: [3.5])
        #expect(BarFix.decode(f.encoded()) == f)
        #expect(BarFix.decode(Data("nope".utf8)) == .empty && BarFix.decode(nil) == .empty)
        #expect(BarFix.empty.isEmpty && !f.isEmpty)
    }
}
```

The `recut` expectation, beat by beat: the labels are C×4 F×4 G×4 Am×4. The new bars are:
- [0,4) → C
- [4,6) → F F → « F »
- [6,10) → F F G G → « F . G . »
- [10,14) → G G Am Am → « G . Am . »
- [14,16) → Am

`cellText` gives « F . G . » rather than « F G »: the split is even, so `cellText` would actually return « F G ».
Correct the expectation to « F G » and « G Am » when you run it. The rule under test is `ChordGrid.cellText`'s, not
a new one.

- [ ] **Step 2: Run to verify they fail**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter BarGrid`
Expected: FAIL with `cannot find 'BarGrid' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Michel's bar-grid fix, the file mesures/<id>.json (karaoke/barfix.py reads it).
public struct BarFix: Codable, Equatable, Sendable {
    public var signature: String?
    public var swing: Bool
    public var pins: [Double]
    public init(signature: String?, swing: Bool, pins: [Double]) { self.signature = signature; self.swing = swing; self.pins = pins }
    public static let empty = BarFix(signature: nil, swing: false, pins: [])
    public var isEmpty: Bool { signature == nil && !swing && pins.isEmpty }
    public static func decode(_ data: Data?) -> BarFix {
        guard let data, let f = try? JSONDecoder().decode(BarFix.self, from: data) else { return .empty }
        return BarFix(signature: BarGrid.menu.contains(f.signature ?? "") ? f.signature : nil, swing: f.swing, pins: f.pins)
    }
    public func encoded() -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}

/// The bar-line rule of karaoke/barfix.py, on beat indices (see that module's docstring).
public enum BarGrid {
    public static let menu = ["2/4", "3/4", "4/4", "6/8", "12/8"]
    static let counts = ["2/4": 2, "3/4": 3, "4/4": 4, "6/8": 2, "12/8": 4]

    public static func beatsInBar(signature: String?, detected: Int, bpm: Double) -> Int {
        guard let s = signature, let n = counts[s] else { return detected }
        return s.hasSuffix("/8") && bpm > 120 ? n * 3 : n
    }

    public static func nearest(_ beats: [Double], _ t: Double) -> Int {
        beats.indices.min { abs(beats[$0] - t) < abs(beats[$1] - t) } ?? 0
    }

    public static func lines(beats: [Double], detected: [Double], fix: BarFix, detectedBPB: Int, bpm: Double) -> (lines: [Int], bpb: Int) {
        let n = beatsInBar(signature: fix.signature, detected: detectedBPB, bpm: bpm)
        let det = Array(Set(detected.map { nearest(beats, $0) })).sorted()
        guard !beats.isEmpty else { return (det, n) }
        var anchors = Array(Set(fix.pins.map { nearest(beats, $0) })).sorted()
        if fix.signature != nil, let first = det.first, anchors.first.map({ $0 >= first + n }) ?? true {
            anchors = Array(Set(anchors + [first])).sorted()
        }
        guard let a0 = anchors.first else { return (det, n) }
        var out = det.filter { $0 < a0 }
        for (k, a) in anchors.enumerated() {
            let end = k + 1 < anchors.count ? anchors[k + 1] : beats.count
            out += Array(stride(from: a, to: end, by: max(n, 1)))
        }
        return (out, n)
    }

    public static func starts(_ lines: [Int]) -> [Int] { lines.first == 0 ? lines : [0] + lines }

    static func pinIndex(_ fix: BarFix, beats: [Double], line: Int) -> Int? {
        fix.pins.firstIndex { nearest(beats, $0) == line }
    }

    public static func hasPin(_ fix: BarFix, beats: [Double], line: Int) -> Bool { pinIndex(fix, beats: beats, line: line) != nil }

    public static func moved(_ fix: BarFix, beats: [Double], line: Int, by delta: Int) -> BarFix {
        let to = line + delta
        guard beats.indices.contains(line), to >= 1, to < beats.count else { return fix }
        var f = fix
        if let i = pinIndex(fix, beats: beats, line: line) { f.pins.remove(at: i) }
        f.pins = Array(Set(f.pins + [beats[to]])).sorted()
        return f
    }

    public static func pinned(_ fix: BarFix, beats: [Double], line: Int) -> BarFix {
        guard beats.indices.contains(line), !hasPin(fix, beats: beats, line: line) else { return fix }
        var f = fix; f.pins = (f.pins + [beats[line]]).sorted(); return f
    }

    public static func unpinned(_ fix: BarFix, beats: [Double], line: Int) -> BarFix {
        var f = fix; f.pins.removeAll { nearest(beats, $0) == line }; return f
    }

    /// Chords re-cut beat by beat into new bars; nil when a cell doesn't parse.
    public static func recut(cells: [String], from old: [Int], oldBPB: Int, to new: [Int], newBPB: Int, beatCount: Int) -> [String]? {
        var labels: [String?] = []
        var cur: String? = nil
        for (k, start) in old.enumerated() where k < cells.count {
            let len = (k + 1 < old.count ? old[k + 1] : beatCount) - start
            guard case .success(let ch) = ChordGrid.parseCell(cells[k], beatsPerBar: oldBPB) else { return nil }
            let marks = Dictionary(ch.map { ($0.beat, $0.label) }, uniquingKeysWith: { a, _ in a })
            for i in 0..<max(len, 0) { cur = marks[i] ?? cur; labels.append(cur) }
        }
        while labels.count < beatCount { labels.append(cur) }
        return new.enumerated().map { k, start in
            let end = min(k + 1 < new.count ? new[k + 1] : beatCount, labels.count)
            var chords: [ChordAt] = []
            var prev: String?? = .none
            for j in start..<max(start, end) {
                let l = labels[j] ?? "N.C."
                if prev == .none || prev! != l { chords.append(ChordAt(beat: j - start, label: l)) }
                prev = .some(l)
            }
            return chords.isEmpty ? "N.C." : ChordGrid.cellText(chords, beatsPerBar: newBPB)
        }
    }

    public static func beatInBar(index: Int?, starts: [Int], beatCount: Int) -> (beat: Int, of: Int)? {
        guard let i = index, let k = starts.lastIndex(where: { $0 <= i }) else { return nil }
        let end = k + 1 < starts.count ? starts[k + 1] : beatCount
        return (i - starts[k] + 1, end - starts[k])
    }
}
```

`ChordAt` needs a public memberwise `init(beat:label:)`. If it has none, add
`public init(beat: Int, label: String)` to `PipelineModels.swift`.

- [ ] **Step 4: Run the whole Swift suite**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
Expected: all pass (73 + the BarGrid tests)

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/BarGrid.swift karaifyer/Tests/KaraifyerCoreTests/BarGridTests.swift karaifyer/Sources/KaraifyerCore/PipelineModels.swift
git commit -m "karaifyer: BarGrid — the bar-line fix rule, re-cutting chords, beat counter"
```

---

### Task 4: Click track rendering and the grid in the song model

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/ClickTrack.swift`
- Modify: `karaifyer/Sources/KaraifyerCore/PipelineModels.swift` (`GridInfo`, `SongState.grid`,
  `SongPaths.mesuresCorrige`)
- Modify: `karaifyer/Sources/KaraifyerCore/ChordGrid.swift` (`chartText` takes `signature: String? = nil`)
- Test: `karaifyer/Tests/KaraifyerCoreTests/ClickTrackTests.swift`,
  `karaifyer/Tests/KaraifyerCoreTests/PipelineModelsTests.swift`

**Interfaces:**
- Produces:
  - `ClickTrack.sampleRate = 44100`;
  - `ClickTrack.samples(beats: [Double], accents: Set<Int>, duration: Double) -> [Float]`;
  - `ClickTrack.wav(_ samples: [Float]) -> Data` (16-bit mono PCM);
  - `GridInfo {beats, downbeatsDetectees, beatsPerBarDetecte, bpm, signature, swing}`;
  - `SongState.grid: GridInfo?`;
  - `SongPaths.mesuresCorrige: String?` (optional, so older `etat` output still decodes).

- [ ] **Step 1: Write the failing tests**

```swift
// ClickTrackTests.swift
import Foundation
import Testing
@testable import KaraifyerCore

struct ClickTrackTests {
    @Test func aClickOnEachBeatAccentLouder() {
        let s = ClickTrack.samples(beats: [0.1, 0.6], accents: [0], duration: 1)
        #expect(s.count == 44100)
        let peak = { (a: Int) in s[a..<(a + 1102)].map(abs).max()! }
        #expect(peak(4410) > 0.8 && peak(26460) > 0.5 && peak(26460) < 0.7)      // 0.9 accent, 0.6 plain
        #expect(s[0..<4400].allSatisfy { $0 == 0 })
    }

    @Test func wavHeaderAndLength() {
        let d = ClickTrack.wav([0, 0.5, -0.5])
        #expect(d.count == 44 + 6 && String(data: d[0..<4], encoding: .ascii) == "RIFF" && String(data: d[8..<12], encoding: .ascii) == "WAVE")
    }
}
```

Append to `PipelineModelsTests.swift`:

```swift
@Test func decodesTheGrid() throws {
    let json = #"[{"id":"001","titre":"T","artiste":"A","album":"","fichier":"f","langue":"fr","partie":"","statut":"ok","retirer":[],"decompte_mesures":1,"steps":[],"paths":{"dossier":"d","video":"v","set":"s","accords":"a","lrc":"l","audio":"au","lrc_corrige":"lc","accords_corrige":"ac","mesures_corrige":"mc"},"bars":[],"grid":{"beats":[0,0.5],"downbeats_detectees":[0],"beats_per_bar_detecte":4,"bpm":120,"signature":"3/4","swing":true}}]"#
    let s = try SongState.decodeList(Data(json.utf8))[0]
    #expect(s.grid?.beats == [0, 0.5] && s.grid?.signature == "3/4" && s.grid?.swing == true && s.paths.mesuresCorrige == "mc")
}
```

If the existing tests decode JSON without `grid` or `mesures_corrige`, they must keep passing: both fields are
optional.

- [ ] **Step 2: Run to verify they fail**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter "ClickTrack|decodesTheGrid"`
Expected: FAIL (`cannot find 'ClickTrack'`, `no member 'grid'`)

- [ ] **Step 3: Implement**

```swift
// ClickTrack.swift
import Foundation

/// The pipeline's click sound (karaoke/grid.py render_click): 25 ms sine bursts, 6 ms decay,
/// 1600 Hz × 0.9 on bar lines, 1000 Hz × 0.6 on other beats; for the editor's « Clic ».
public enum ClickTrack {
    public static let sampleRate = 44100

    public static func samples(beats: [Double], accents: Set<Int>, duration: Double) -> [Float] {
        let total = max(0, Int(duration * Double(sampleRate)))
        var out = [Float](repeating: 0, count: total)
        let n = Int(0.025 * Double(sampleRate))
        func burst(_ f: Double, _ a: Double) -> [Float] {
            (0..<n).map { i in let t = Double(i) / Double(sampleRate); return Float(a * sin(2 * .pi * f * t) * exp(-t / 0.006)) }
        }
        let hi = burst(1600, 0.9), lo = burst(1000, 0.6)
        for (k, b) in beats.enumerated() {
            let i = Int((b * Double(sampleRate)).rounded())
            guard i >= 0, i < total else { continue }
            let src = accents.contains(k) ? hi : lo
            for j in 0..<min(n, total - i) { out[i + j] = max(-1, min(1, out[i + j] + src[j])) }
        }
        return out
    }

    public static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}
```

`PipelineModels.swift`:
- add the struct

  ```swift
  public struct GridInfo: Codable, Equatable, Sendable {
      public var beats: [Double]
      public var downbeatsDetectees: [Double]
      public var beatsPerBarDetecte: Int
      public var bpm: Double
      public var signature: String?
      public var swing: Bool
  }
  ```
- add `public var grid: GridInfo?` to `SongState`;
- add `public var mesuresCorrige: String?` to `SongPaths` (change the `var dossier, …` line to keep the existing
  ones and add this optional one).

`ChordGrid.chartText`: add a parameter `signature: String? = nil` and write
`head += " · \(signature ?? "\(beatsPerBar)/4")\n\n"`.

- [ ] **Step 4: Run the whole Swift suite**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore karaifyer/Tests/KaraifyerCoreTests
git commit -m "karaifyer: click track rendering; grid and mesures path in the song model"
```

---

### Task 5: The « Corriger » window: grid fixes, signature, click, beat counter

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/EditorModel.swift`
- Modify: `karaifyer/Sources/Karaifyer/EditorView.swift`

**Interfaces:**
- Consumes:
  - `BarFix`, `BarGrid` (Task 3);
  - `ClickTrack`, `GridInfo`, `SongPaths.mesuresCorrige`, `ChordGrid.chartText(…, signature:)` (Task 4).
- Produces (UI only):
  - **Grid:** `EditorModel.fix`, `gridAvailable`, `starts`, `bpb`, `beatCounter`, `gridDirty`;
  - **Actions:** `moveBar(_:by:)`, `pinBar(_:)`, `unpinBar(_:)`, `hasPin(_:)`, `setSignature(_:)`, `setSwing(_:)`;
  - **Click:** `clickOn`, `clickVolume`.

- [ ] **Step 1: The model**

In `EditorModel`:

1. **State:**

```swift
    var fix = BarFix.empty
    var gridDirty = false
    var gridAvailable: Bool { song.grid != nil }
    private var detectedLines: (lines: [Int], bpb: Int) {
        guard let g = song.grid else { return ([], song.beatsPerBar ?? 4) }
        return BarGrid.lines(beats: g.beats, detected: g.downbeatsDetectees, fix: fix, detectedBPB: g.beatsPerBarDetecte, bpm: g.bpm)
    }
    var starts: [Int] { BarGrid.starts(detectedLines.lines) }
    var beats: [Double] { song.grid?.beats ?? [] }
    func barStart(_ i: Int) -> Double { gridAvailable ? beats[starts[i]] : song.bars[i].start }
```

   - Replace `var bpb: Int { song.beatsPerBar ?? 4 }` with
     `var bpb: Int { gridAvailable ? detectedLines.bpb : (song.beatsPerBar ?? 4) }`.
   - `dirty` becomes `lyricsDirty || chordsDirty || gridDirty`.
   - In `init`, after loading `cells`, read the fix:
     `fix = BarFix.decode(song.paths.mesuresCorrige.flatMap { FileManager.default.contents(atPath: $0) })`.

2. **Current bar, seek, beat counter.**
   - `currentBar`: `gridAvailable ? starts.lastIndex { beats[$0] <= position + 1e-6 } : ChordGrid.barIndex(at: position, bars: song.bars)`.
   - `seekBar(_ i:)`: `seek(input: barStart(i))`.
   - Add the beat counter:

     ```swift
     var beatCounter: (beat: Int, of: Int)? {
         BarGrid.beatInBar(index: beats.lastIndex { $0 <= position + 1e-6 }, starts: starts, beatCount: beats.count)
     }
     ```

3. **Grid edits** (undoable; the cells are re-cut):

```swift
    private func changeFix(_ new: BarFix) {
        guard gridAvailable, new != fix, cellErrors.isEmpty else { return }
        edit {
            let oldStarts = starts, oldBPB = bpb
            fix = new
            if let c = BarGrid.recut(cells: cells, from: oldStarts, oldBPB: oldBPB, to: starts, newBPB: bpb, beatCount: beats.count) { cells = c }
            gridDirty = true
        }
        rebuildClick()
    }
    func moveBar(_ i: Int, by d: Int) { changeFix(BarGrid.moved(fix, beats: beats, line: starts[i], by: d)) }
    func pinBar(_ i: Int) { changeFix(BarGrid.pinned(fix, beats: beats, line: starts[i])) }
    func unpinBar(_ i: Int) { changeFix(BarGrid.unpinned(fix, beats: beats, line: starts[i])) }
    func hasPin(_ i: Int) -> Bool { gridAvailable && BarGrid.hasPin(fix, beats: beats, line: starts[i]) }
    func setSignature(_ s: String?) { var f = fix; f.signature = s; changeFix(f) }
    func setSwing(_ on: Bool) { var f = fix; f.swing = on; changeFix(f) }
```

4. **Undo.**
   - Add `fix: BarFix` and `gridDirty: Bool` to `Snapshot`, to its getter and to its setter.
   - In `edit`, also record when `before.fix != fix`.
   - In `undo()` and `redo()`, call `rebuildClick()` after restoring.

5. **Click:**

```swift
    var clickOn: Bool = UserDefaults.standard.bool(forKey: "editorClickOn") {
        didSet { UserDefaults.standard.set(clickOn, forKey: "editorClickOn"); applyClickVolume() }
    }
    var clickVolume: Float = UserDefaults.standard.object(forKey: "editorClickVolume") as? Float ?? 0.7 {
        didSet { UserDefaults.standard.set(clickVolume, forKey: "editorClickVolume"); applyClickVolume() }
    }
    @ObservationIgnored private var clickPlayer: AVAudioPlayer?
    private func applyClickVolume() { clickPlayer?.volume = clickOn ? clickVolume : 0 }

    /// Re-render the click from the grid as it stands in the window; keeps it running in step with the recording.
    func rebuildClick() {
        guard gridAvailable, let p = player else { return }
        let lines = Set(detectedLines.lines)
        let accents = Set(beats.indices.filter { lines.contains($0) })
        let data = ClickTrack.wav(ClickTrack.samples(beats: beats, accents: accents, duration: p.duration))
        clickPlayer?.stop()
        clickPlayer = try? AVAudioPlayer(data: data)
        clickPlayer?.prepareToPlay()
        applyClickVolume()
        if playing { startClick() }
    }
    private func startClick() {
        guard let p = player, let c = clickPlayer else { return }
        let at = p.deviceCurrentTime + 0.05
        c.currentTime = p.currentTime + 0.05
        c.play(atTime: at)
    }
```

   - **Lifecycle:** call `rebuildClick()` at the end of `init`.
   - **Play:** in `play()`, right after `p.play()`, call `startClick()`.
   - **Pause:** in `pause()`, call `clickPlayer?.pause()`.
   - **Seek:** in `seek(input:)`, after setting the main player's time, call `clickPlayer?.currentTime = <the same time>`,
     and when `playing`, `clickPlayer?.stop(); startClick()`.

   Read the current `play`/`pause`/`seek` bodies first, and keep their existing lines.

6. **Save** (in `save()`, before `lyricsDirty = false`):

```swift
        if gridDirty, let p = song.paths.mesuresCorrige {
            if fix.isEmpty { try? fm.removeItem(atPath: p) } else { try ensureDir(p); try fix.encoded().write(to: URL(fileURLWithPath: p)) }
        }
        let chartExists = fm.fileExists(atPath: song.paths.accordsCorrige)
        if chordsDirty || (gridDirty && chartExists) {
            try ensureDir(song.paths.accordsCorrige)
            try ChordGrid.chartText(title: song.titre, artist: song.artiste, key: key, bpm: nil, beatsPerBar: bpb,
                                    cells: cells, signature: fix.signature)
                .write(toFile: song.paths.accordsCorrige, atomically: true, encoding: .utf8)
        }
```

   This replaces the existing `if chordsDirty { … }` block. Set `gridDirty = false` together with the other two
   flags.

- [ ] **Step 2: The view**

In `EditorView`:

1. **`playerBar`.**
   - After the time text, add the beat counter:

     ```swift
     if let b = model.beatCounter {
         Text("\(b.beat)/\(b.of)").monospacedDigit().frame(width: 36).foregroundStyle(b.beat == 1 ? .primary : .secondary)
     }
     ```
   - Before the volume `Divider`, add the click controls:

     ```swift
     Toggle("Clic", isOn: $model.clickOn).toggleStyle(.checkbox).disabled(!model.gridAvailable)
     Slider(value: Binding(get: { Double(model.clickVolume) }, set: { model.clickVolume = Float($0) }), in: 0...1)
         .frame(width: 80).disabled(!model.clickOn).help("Volume du clic")
     ```
2. **`chords` header.** Replace `Text("\(model.bpb)/4")` with:

```swift
                Picker("", selection: Binding(get: { model.fix.signature ?? "" },
                                              set: { model.setSignature($0.isEmpty ? nil : $0) })) {
                    Text("Détectée (\(model.song.grid?.beatsPerBarDetecte ?? model.bpb)/4)").tag("")
                    ForEach(BarGrid.menu, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 130).disabled(!model.gridAvailable)
                Toggle("Swing", isOn: Binding(get: { model.fix.swing }, set: { model.setSwing($0) }))
                    .toggleStyle(.checkbox).disabled(!model.gridAvailable)
```

3. **Bar number row of each cell.** Replace the number `Text` with an `HStack` holding:
   - the number;
   - `Image(systemName: "pin.fill").font(.caption2)` when `model.hasPin(i)`;
   - `Spacer()`;
   - the bar's beat count in the top right corner (Michel's request):

     ```swift
     if let n = model.beatCount(i) {
         Text("\(n) t.").font(.caption2).monospacedDigit()
             .foregroundStyle(n == model.bpb ? Color.secondary : Color.orange)
             .help("\(n) temps dans cette mesure")
     }
     ```

   In the model, add `func beatCount(_ i: Int) -> Int? { guard gridAvailable, i < starts.count else { return nil }; return (i + 1 < starts.count ? starts[i + 1] : beats.count) - starts[i] }`.
   A bar with an unusual length (a short bar, a pickup, a bar before a pin) is orange.

   Attach a context menu to that row (the text field below keeps its own menu):

```swift
                            .contextMenu {
                                Button("La mesure commence un temps plus tôt") { endEditing(); model.moveBar(i, by: -1) }
                                Button("La mesure commence un temps plus tard") { endEditing(); model.moveBar(i, by: 1) }
                                if model.hasPin(i) {
                                    Button("Retirer le repère") { endEditing(); model.unpinBar(i) }
                                } else {
                                    Button("Le temps 1 est ici") { endEditing(); model.pinBar(i) }
                                }
                            }
                            .disabled(!model.gridAvailable)
```

   Update the cell's `.help` default to: « Clic sur le numéro : aller à la mesure · clic droit : corriger le
   temps 1 ».
4. **The grid's column count** stays 4.

- [ ] **Step 3: Build, run the suites, install**

Run:
- `cd karaifyer && swift build 2>&1 | grep -E "error|warning: .*Editor"`, expecting no output;
- the Swift suite, all passing;
- `./build-app.sh --install`, expecting `Installed ~/Applications/Karaifyer.app`.

- [ ] **Step 4: Check against real data**

- Run `uv --directory karaoke run karaoke etat --json`, and confirm that song 005 has a non-null `grid` with
  about 319 beats and `paths.mesures_corrige` set.
- Then run `Karaifyer --screenshots <scratch dir>`, and check that `03-editeur.png` shows the signature menu,
  « Swing », « Clic » and the beat counter (the agent can't click the UI).

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/Karaifyer
git commit -m "karaifyer editor: fix beat 1 (right-click a bar), time signature + swing, click overlay with its own volume, beat counter"
```

---

### Task 6: Docs and checklist

**Files:**
- Modify: `docs/guide/GUIDE.md` (the editor section)
- Modify: `docs/karaoke/karaifyer-validation.md` (rows 32–35)
- Modify: `karaifyer/README.md` (the Karaoké editor bullet)
- Regenerate: `docs/guide/images/03-editeur.png` (`Karaifyer --screenshots`)

- [ ] **Step 1: Guide**, under the editor's bullets after « Aller à une ligne », add:

```markdown
- **Clic :** la case « Clic » ajoute un clic sur chaque temps (plus aigu sur le temps 1), avec son propre volume ;
  le compteur « 1/4 » montre le temps en cours. Il suit la grille telle qu'elle est dans la fenêtre.
- **Temps 1 décalé :** clic droit sur le numéro d'une mesure :
  - « La mesure commence un temps plus tôt / plus tard » déplace cette barre de mesure et recompte la suite à partir
    d'elle ;
  - « Le temps 1 est ici » épingle une barre (📌) pour qu'une correction plus loin ne la déplace pas ; épingler la
    mesure qui suit une mesure courte la garde ;
  - les accords suivent leurs temps.
- **Mesure :** le menu à côté de la tonalité choisit 2/4, 3/4, 4/4, 6/8 ou 12/8 ; « Swing » marque un jeu ternaire
  (style iReal).
- Ces corrections sont enregistrées dans `mesures/<id>.json` et reprises à chaque analyse : grille, vidéo, clic du
  Lecteur et iReal suivent.
```

- [ ] **Step 2: Checklist rows**, appended after row 31 with the same table layout:

```markdown
| 31 bis | Corriger : each bar cell shows its beat count top right (« 4 t. »), orange when it differs from the time signature; it updates at once after a bar fix | |
| 32 | Corriger : « Clic » on, the click follows the music after a seek, pause/resume and a bar fix during playback; its volume is separate and remembered | |
| 33 | Corriger : Danser — right-click bar 50 « un temps plus tard » ×2, the click's accent falls on beat 1 again to the end; ⌘Z undoes both, chords follow | |
| 34 | Corriger : a waltz set to 3/4 shows 3-beat cells; after « Enregistrer », the video's chord rows and the Lecteur's click accent every 3 beats | |
| 35 | iReal : a song set to 12/8 imports as 12/8 Slow Rock; 4/4 + Swing as Medium Swing | |
```

- [ ] **Step 3: README.** Change the editor bullet to: « un éditeur de paroles et d'accords avec lecture, clic,
  correction du temps 1 et de la mesure. »

- [ ] **Step 4: Screenshot, then commit**

- Run `karaifyer/Karaifyer.app/Contents/MacOS/Karaifyer --screenshots docs/guide/images`. Check that only the
  intended images changed: `git status`, and restore the others with `git checkout` if their changes are noise.

```bash
git add docs karaifyer/README.md
git commit -m "docs: bar-grid corrections, click and time signature in the guide and checklist"
```
