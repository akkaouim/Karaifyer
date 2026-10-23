# Chord Detectors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Karaifyer's analysis detect chords with Jiang 2019 (default), BTC, consonance-ACE or madmom, chosen in Réglages, and carry their richer chords (7ths, sus, slash) through the grid, the editor, the video and iReal.

**Architecture:**
- **Tool projects.** Two new uv tool projects:
  - `karaoke/tools/chords_dl` for Jiang + BTC;
  - `karaoke/tools/chords_ace` for consonance-ACE.
- **Shared fetch helper.** `karaoke/tools/chords_fetch.py` downloads each upstream repo at a pinned commit into
  `~/.cache/karaoke/chords/`, checks the model's sha256 and applies asserted compatibility patches.
- **Wrappers.** Each wrapper writes the existing `{segments, key}` JSON.
- **The `chords` step** picks the engine from `KARAOKE_ACCORDS`, which the app sets from its Réglages menu. It takes
  the key from madmom, and falls back to the full mix when the harmonic stem is silent.
- **The label converter** turns Harte labels into chart symbols, renaming slash chords to root position when the notes
  match (A/F# → F#m7).

**Tech Stack:**
- **Python 3.11 + pytest:** `uv --directory karaoke run pytest -q`.
- **uv tool projects.**
- **Swift 6 / SwiftPM** (Command Line Tools only, Swift Testing):
  `swift test --package-path karaifyer -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.

**Spec:** `docs/superpowers/specs/2026-10-23-chord-detectors-design.md`

## Global Constraints

- **Engines and labels:**
  - `jiang` → « Jiang 2019 (recommandé) », the default when unset or unknown;
  - `btc` → « BTC »;
  - `ace` → « consonance-ACE »;
  - `madmom` → « madmom (ancien) ».
- **Settings:** env var `KARAOKE_ACCORDS`; UserDefaults key `chordEngine`.
- **Pinned sources:**

  | Engine | Repo | Commit | Model file | sha256 |
  |---|---|---|---|---|
  | jiang | `music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition` | `481f4ce703f8822b99f4037e9104ba1760e21ea3` | `cache_data/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s0.best.sdict` | `921b42d5d1cf9ce1c0c0e45a74d409b8066e0acec46058ef74e24ee0fb540761` |
  | btc | `jayg996/BTC-ISMIR19` | `2682317be668032e6e4b269ded36adaa2ad57df0` | `test/btc_model_large_voca.pt` | `1673d23f8f9a55ae7f9e8b80a51da616debb22675b8d8b67ea6ce0ef37b0ab51` |
  | ace | `andreamust/consonance-ACE` | `d17633aea4e68e616e735d09df97b97ae3428e71` | `ACE/checkpoints/conformer_decomposed_smooth.ckpt` | `6ab1a314366fefb3d09e351ae7cb7f826a9e0718e94e7ff164df844ba7bcd954` |
- **Cache:** `~/.cache/karaoke/chords/<engine>-<commit[:7]>/`, overridable with `KARAOKE_CHORDS_CACHE`. A `.ready`
  file marks a finished install.
- **Silent harmonic stem:** RMS below −45 dBFS → run on `input.wav`, and record `entree: "mix"` (otherwise `"harmonie"`).
- **Key:** always from madmom's CNN key model (the existing `chords` tool's `key`).
- **New chart suffixes:** dim7, m9, maj9, 7sus4, mM7, 11, 13, added to the existing
  m, maj7, m7b5, m7, m6, 7, 6, 9, dim, aug, sus2, sus4, add9.
- **Unchanged:** SysRec (root `Sources/`, `Tests/`, `Package.swift`) is never touched.

## Review Focus

1. **An upstream download that is interrupted or corrupt** (partial tarball, wrong sha): no `.ready` file is written,
   the half-extracted folder is removed, the step fails with a clear French message, and the next run retries. Covered
   by `test_fetch_rejects_bad_checksum_and_retries` (Task 3).
2. **Switching engine between runs:** the step key changes, so the chord step re-runs. A song with
   `accords/<id>.txt` keeps its corrected chords, so nothing downstream changes. Covered by
   `test_engine_in_step_key` and `test_correction_wins_over_any_engine` (Task 5).
3. **An engine that outputs nothing** (BTC on a damaged recording): the step returns empty bars without crashing, and
   the report says so (`erreur`). Covered by `test_empty_engine_output_is_a_soft_failure` (Task 5).
4. **Every label any engine can output** (Harte qualities with extensions, degrees after `/`, `X`, `N`) converts to a
   symbol that the Python and Swift grids both accept. Covered by `test_symbol_is_always_a_valid_chart_symbol`
   (Task 1) and `acceptsTheNewSymbols` (Task 2).
5. **The app's env** carries the engine even when the setting was never set, so the default reaches the CLI. Covered
   by `engineFromSettings` (Task 6).

---

### Task 1: Harte → chart symbols, slash renaming, richer vocabulary (Python)

**Files:**
- Modify: `karaoke/src/karaoke/chords.py` (`symbol`, `SYMBOL`)
- Modify: `karaoke/src/karaoke/ireal.py` (`QUALITY`, the regex in `chord`)
- Test: `karaoke/tests/test_chords.py`, `karaoke/tests/test_ireal.py`

**Interfaces:**
- Produces:
  - `chords.symbol(label: str) -> str`, which accepts any Harte label (`C#:min7`, `A:maj/3`, `G:sus4(b7)`, `N`,
    `X`);
  - `chords.SYMBOL` with the new suffixes;
  - `ireal.QUALITY` covering every suffix.

- [ ] **Step 1: Write the failing tests** (append to `test_chords.py`)

```python
def test_harte_labels_to_chart_symbols():
    from karaoke.chords import symbol
    cases = {"C#:min": "C#m", "A:maj": "A", "N": "N.C.", "X": "N.C.", "G:7": "G7", "F:maj7": "Fmaj7",
             "D:min7": "Dm7", "B:hdim7": "Bm7b5", "E:dim7": "Edim7", "C:aug": "Caug", "A:maj6": "A6",
             "A:min6": "Am6", "D:9": "D9", "C:maj9": "Cmaj9", "A:min9": "Am9", "G:sus4(b7)": "G7sus4",
             "D:sus2": "Dsus2", "E:sus4": "Esus4", "C:minmaj7": "CmM7", "G:11": "G11", "G:13": "G13",
             "A#:min": "Bbm", "C:maj(9)": "C", "C:min(b13)": "Cm", "C:weird": "C", "C:minweird": "Cm",
             "A:maj/3": "A/C#", "C:maj/5": "C/G", "G:7/b7": "G7/F", "D:min/b3": "Dm/F"}
    assert {k: symbol(k) for k in cases} == cases


def test_slash_chord_named_in_root_position_when_the_notes_match():
    from karaoke.chords import symbol
    assert symbol("A:maj/6") == "F#m7"       # A/F#: F# A C# E — Michel's naming
    assert symbol("C:maj/6") == "Am7"
    assert symbol("F:maj/6") == "Dm7"
    assert symbol("A:maj/3") == "A/C#"       # a real inversion stays a slash chord


def test_symbol_is_always_a_valid_chart_symbol():
    import itertools
    from karaoke.chords import SYMBOL, symbol
    quals = ["maj", "min", "7", "maj7", "min7", "hdim7", "dim", "dim7", "aug", "maj6", "min6", "9", "maj9", "min9",
             "sus2", "sus4", "sus4(b7)", "minmaj7", "11", "13", "maj(9)", "min(11)", "1", "5", "foo"]
    basses = ["", "/3", "/b3", "/5", "/b7", "/7", "/2", "/4", "/6", "/F#"]
    for r, q, b in itertools.product(["C", "C#", "Eb", "F#", "Bb"], quals, basses):
        assert SYMBOL.match(symbol(f"{r}:{q}{b}")), f"{r}:{q}{b} → {symbol(f'{r}:{q}{b}')}"
```

Append to `test_ireal.py`:

```python
def test_new_qualities_to_ireal():
    assert [chord(c) for c in ["Edim7", "Am9", "Cmaj9", "G7sus4", "CmM7", "G11", "G13"]] == \
        ["Eo7", "A-9", "C^9", "G7sus", "C-^7", "G11", "G13"]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv --directory karaoke run pytest -q tests/test_chords.py tests/test_ireal.py`
Expected: FAIL (the current `symbol` returns only `C#m`/`A`, and `chord()` passes unknown suffixes through)

- [ ] **Step 3: Implement** (in `chords.py`, replacing `symbol` and `SYMBOL`)

```python
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
    return f"{name}/{NAME[bass]}"


SYMBOL = re.compile(r"^(N\.C\.|[A-G][#b]?(maj9|maj7|mM7|m7b5|m9|m7|m6|7sus4|dim7|dim|aug|sus2|sus4|add9|11|13|9|7|6|m)?"
                    r"(/[A-G][#b]?)?)$")
```

- Remove the old `FLATS` use in `symbol`. `spell()` still respells by key afterwards. `NAME` already uses
  Eb/Ab/Bb, as `FLATS` did.
- In `ireal.py`:
  - add to `QUALITY`: `"dim7": "o7", "m9": "-9", "maj9": "^9", "7sus4": "7sus", "mM7": "-^7", "11": "11",
    "13": "13"`;
  - change the regex in `chord()` to the same suffix alternation as `SYMBOL`, longest first:
    `(maj9|maj7|mM7|m7b5|m9|m7|m6|7sus4|dim7|dim|aug|sus2|sus4|add9|11|13|9|7|6|m)?`.

- [ ] **Step 4: Run the whole Python suite**

Run: `uv --directory karaoke run pytest -q`
Expected: all pass. If an existing test expected `FLATS` spelling from `symbol` (e.g. `A#:min` → `Bbm`), it still
holds.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/chords.py karaoke/src/karaoke/ireal.py karaoke/tests/test_chords.py karaoke/tests/test_ireal.py
git commit -m "karaoke: Harte labels to chart symbols (7ths, sus, slash → root position), richer vocabulary"
```

---

### Task 2: Swift grid accepts the new symbols

**Files:**
- Modify: `karaifyer/Sources/KaraifyerCore/ChordGrid.swift` (`symbol` regex)
- Test: `karaifyer/Tests/KaraifyerCoreTests/ChordGridTests.swift`

**Interfaces:**
- Produces: `ChordGrid.isValidSymbol`, which accepts the same symbols as Python's `SYMBOL`.

- [ ] **Step 1: Failing test** (inside `ChordGridTests`)

```swift
    @Test func acceptsTheNewSymbols() {
        for s in ["Edim7", "Am9", "Cmaj9", "G7sus4", "CmM7", "G11", "G13", "F#m7", "A/C#", "Bbm7b5", "N.C."] {
            #expect(ChordGrid.isValidSymbol(s), "\(s)")
        }
        #expect(!ChordGrid.isValidSymbol("H7") && !ChordGrid.isValidSymbol("Cmaj13"))
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: the Swift test command with `--filter acceptsTheNewSymbols`
Expected: FAIL on `Edim7`

- [ ] **Step 3: Implement**

```swift
    static let symbol = #"^(N\.C\.|[A-G][#b]?(maj9|maj7|mM7|m7b5|m9|m7|m6|7sus4|dim7|dim|aug|sus2|sus4|add9|11|13|9|7|6|m)?(/[A-G][#b]?)?)$"#
```

Update the help line in `EditorView.chords` to mention the new symbols: « ex. Cmaj7 Dm7 G7 Am/G Gsus4 Edim7 ».

- [ ] **Step 4: Run the whole Swift suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources karaifyer/Tests
git commit -m "karaifyer: chord grid accepts dim7, m9, maj9, 7sus4, mM7, 11, 13"
```

---

### Task 3: Fetch helper (pinned upstream code + models, asserted patches)

**Files:**
- Create: `karaoke/tools/chords_fetch.py`
- Test: `karaoke/tests/test_chords_fetch.py`

**Interfaces:**
- Produces:
  - `chords_fetch.SOURCES`;
  - `chords_fetch.ensure(engine: str, download=None, log=print) -> Path` (the repo folder; installs if needed);
  - `chords_fetch.lab_to_segments(text: str) -> list[list]`;
  - `chords_fetch.write_result(path, segments, key=None)`.

- [ ] **Step 1: Failing tests**

```python
# karaoke/tests/test_chords_fetch.py
import hashlib, io, json, sys, tarfile
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import chords_fetch as F


def tarball(files: dict) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name, data in files.items():
            info = tarfile.TarInfo(f"repo-abc/{name}")
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def test_lab_to_segments():
    assert F.lab_to_segments("0.0 1.5 C:maj\n1.5\t3.0\tA:min7\n\n") == [[0.0, 1.5, "C:maj"], [1.5, 3.0, "A:min7"]]


def test_fetch_installs_patches_and_reuses(tmp_path, monkeypatch):
    model = b"weights"
    src = {"repo": "x/y", "commit": "abc1234def", "model": "m.pt", "sha256": hashlib.sha256(model).hexdigest(),
           "patches": [("code.py", "np.int(", "int("), ("cfg.py", "yaml.load(f)", "yaml.safe_load(f)")]}
    monkeypatch.setitem(F.SOURCES, "fake", src)
    monkeypatch.setenv("KARAOKE_CHORDS_CACHE", str(tmp_path))
    calls = []
    def dl(url):
        calls.append(url)
        return tarball({"m.pt": model, "code.py": b"x = np.int(3)\n", "cfg.py": b"c = yaml.load(f)\n"})
    d = F.ensure("fake", download=dl, log=lambda *a: None)
    assert d == tmp_path / "fake-abc1234" and (d / ".ready").exists()
    assert (d / "code.py").read_text() == "x = int(3)\n" and (d / "cfg.py").read_text() == "c = yaml.safe_load(f)\n"
    assert calls == ["https://codeload.github.com/x/y/tar.gz/abc1234def"]
    F.ensure("fake", download=dl, log=lambda *a: None)
    assert len(calls) == 1                                      # installed once


def test_fetch_rejects_bad_checksum_and_retries(tmp_path, monkeypatch):
    src = {"repo": "x/y", "commit": "abc1234def", "model": "m.pt", "sha256": "0" * 64, "patches": []}
    monkeypatch.setitem(F.SOURCES, "fake", src)
    monkeypatch.setenv("KARAOKE_CHORDS_CACHE", str(tmp_path))
    with pytest.raises(RuntimeError, match="somme de contrôle"):
        F.ensure("fake", download=lambda u: tarball({"m.pt": b"corrupt"}), log=lambda *a: None)
    assert not (tmp_path / "fake-abc1234").exists() and not list(tmp_path.glob("*.tmp"))


def test_fetch_fails_clearly_when_a_patch_no_longer_applies(tmp_path, monkeypatch):
    model = b"w"
    src = {"repo": "x/y", "commit": "abc1234def", "model": "m.pt", "sha256": hashlib.sha256(model).hexdigest(),
           "patches": [("code.py", "np.int(", "int(")]}
    monkeypatch.setitem(F.SOURCES, "fake", src)
    monkeypatch.setenv("KARAOKE_CHORDS_CACHE", str(tmp_path))
    with pytest.raises(RuntimeError, match="code.py"):
        F.ensure("fake", download=lambda u: tarball({"m.pt": model, "code.py": b"nothing here\n"}), log=lambda *a: None)


def test_write_result(tmp_path):
    F.write_result(tmp_path / "o.json", [[0.0, 1.0, "C:maj"]])
    assert json.loads((tmp_path / "o.json").read_text()) == {"segments": [[0.0, 1.0, "C:maj"]], "key": None}
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv --directory karaoke run pytest -q tests/test_chords_fetch.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'chords_fetch'`

- [ ] **Step 3: Implement**

```python
# karaoke/tools/chords_fetch.py
"""Upstream chord-recognition code + model at a pinned commit, fetched once into ~/.cache/karaoke/chords/.

No third-party code lives in the repository: each engine's repo is downloaded as a tarball, its model file is checked
against a sha256, and the few compatibility edits it needs (2019 code vs today's numpy/PyYAML/torch) are applied —
each edit asserts its target exists, so a changed upstream fails clearly. Used by chords_dl/ and chords_ace/ wrappers.
"""
from __future__ import annotations
import hashlib, io, json, os, re, shutil, tarfile, urllib.request
from pathlib import Path

NP_ALIASES = (r"np\.int([^0-9_a-z])", r"int\1"), (r"np\.float([^0-9_a-z])", r"float\1"), (r"np\.bool([^_a-z])", r"bool\1")
SOURCES = {
    "jiang": {"repo": "music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition",
              "commit": "481f4ce703f8822b99f4037e9104ba1760e21ea3",
              "model": "cache_data/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s0.best.sdict",
              "sha256": "921b42d5d1cf9ce1c0c0e45a74d409b8066e0acec46058ef74e24ee0fb540761",
              "patches": [(f, "re", NP_ALIASES) for f in ("extractors/beat_preprocess.py", "extractors/xhmm_decoder.py",
                                                         "extractors/xhmm_ismir.py", "results_ismir2017.py")]},
    "btc": {"repo": "jayg996/BTC-ISMIR19", "commit": "2682317be668032e6e4b269ded36adaa2ad57df0",
            "model": "test/btc_model_large_voca.pt",
            "sha256": "1673d23f8f9a55ae7f9e8b80a51da616debb22675b8d8b67ea6ce0ef37b0ab51",
            "patches": [("utils/hparams.py", "yaml.load(f)", "yaml.safe_load(f)"),
                        ("test.py", "torch.load(model_file)", "torch.load(model_file, map_location='cpu', weights_only=False)"),
                        ("utils/chords.py", "re", NP_ALIASES), ("utils/transformer_modules.py", "re", NP_ALIASES)]},
    "ace": {"repo": "andreamust/consonance-ACE", "commit": "d17633aea4e68e616e735d09df97b97ae3428e71",
            "model": "ACE/checkpoints/conformer_decomposed_smooth.ckpt",
            "sha256": "6ab1a314366fefb3d09e351ae7cb7f826a9e0718e94e7ff164df844ba7bcd954", "patches": []},
}


def _cache() -> Path:
    return Path(os.environ.get("KARAOKE_CHORDS_CACHE", Path.home() / ".cache" / "karaoke" / "chords"))


def _download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def _patch(root: Path, rel: str, old, new) -> None:
    p = root / rel
    text = p.read_text(encoding="utf-8") if p.exists() else ""
    if old == "re":                                   # regex list (numpy aliases): at least one must apply
        out = text
        for pat, rep in new:
            out = re.sub(pat, rep, out)
        if out == text:
            raise RuntimeError(f"correctif introuvable dans {rel} (code amont modifié ?)")
    else:
        if old not in text:
            raise RuntimeError(f"correctif introuvable dans {rel} : « {old} » (code amont modifié ?)")
        out = text.replace(old, new)
    p.write_text(out, encoding="utf-8")


def ensure(engine: str, download=None, log=print) -> Path:
    s = SOURCES[engine]
    dest = _cache() / f"{engine}-{s['commit'][:7]}"
    if (dest / ".ready").exists():
        return dest
    log(f"installation du détecteur {engine} (une seule fois) …")
    tmp = dest.with_name(dest.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    try:
        data = (download or _download)(f"https://codeload.github.com/{s['repo']}/tar.gz/{s['commit']}")
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
            for m in t.getmembers():
                parts = Path(m.name).parts[1:]               # strip the top-level « repo-<sha> » folder
                if not parts or ".." in parts:
                    continue
                m.name = str(Path(*parts))
                t.extract(m, tmp)
        model = tmp / s["model"]
        if not model.exists() or hashlib.sha256(model.read_bytes()).hexdigest() != s["sha256"]:
            raise RuntimeError(f"détecteur {engine} : somme de contrôle du modèle incorrecte (téléchargement abîmé ?)")
        for rel, old, new in s["patches"]:
            _patch(tmp, rel, old, new)
        (tmp / ".ready").write_text(s["commit"])
        shutil.rmtree(dest, ignore_errors=True)
        tmp.rename(dest)
        return dest
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def lab_to_segments(text: str) -> list[list]:
    out = []
    for line in text.splitlines():
        p = line.split()
        if len(p) >= 3:
            out.append([float(p[0]), float(p[1]), p[2]])
    return out


def write_result(path, segments: list, key: str | None = None) -> None:
    Path(path).write_text(json.dumps({"segments": segments, "key": key}))
```

- [ ] **Step 4: Run the tests**, then the whole suite. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/tools/chords_fetch.py karaoke/tests/test_chords_fetch.py
git commit -m "karaoke: chord engine fetch helper (pinned commit, checked model, asserted patches)"
```

---

### Task 4: The two tool projects and three wrappers

**Files:**
- Create: `karaoke/tools/chords_dl/pyproject.toml`, `karaoke/tools/chords_dl/jiang_tool.py`,
  `karaoke/tools/chords_dl/btc_tool.py`
- Create: `karaoke/tools/chords_ace/pyproject.toml`, `karaoke/tools/chords_ace/ace_tool.py`
- Test: `karaoke/tests/test_models_slow.py` (one slow test per engine)

**Interfaces:**
- Consumes: Task 3's `chords_fetch.ensure`, `lab_to_segments`, `write_result`.
- Produces: `python <engine>_tool.py in.wav out.json`, run through `run_tool("chords_dl" | "chords_ace", …)`,
  writes `{segments, key: null}`.

- [ ] **Step 1: The slow tests first** (append to `test_models_slow.py`)

```python
@pytest.mark.slow
@pytest.mark.skipif(not SAMPLE.is_file(), reason="set KARAOKE_SAMPLE to a real song file")
@pytest.mark.parametrize("project,script", [("chords_dl", "jiang_tool.py"), ("chords_dl", "btc_tool.py"),
                                            ("chords_ace", "ace_tool.py")])
def test_chord_engine_on_a_real_clip(tmp_path, project, script):
    import json, subprocess
    from karaoke.chords import SYMBOL, symbol
    from karaoke.tools import TOOLS_DIR, run_tool
    clip = tmp_path / "clip.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "30", "-t", "20", "-i", str(SAMPLE), str(clip)], check=True)
    run_tool(project, ["python", str(TOOLS_DIR / project / script), str(clip), str(tmp_path / "o.json")], timeout=3600)
    segs = json.loads((tmp_path / "o.json").read_text())["segments"]
    assert segs and all(SYMBOL.match(symbol(l)) for _, _, l in segs)
```

- [ ] **Step 2: Run to verify they fail**

Run: `KARAOKE_SAMPLE="$HOME/Music/SysRec/Karaoké - Feuille 1/05 - Danser - Loïc Nottet.flac" uv --directory karaoke run pytest -q -m slow -k chord_engine`
Expected: FAIL (the tool projects don't exist)

- [ ] **Step 3: Implement**

`chords_dl/pyproject.toml`:

```toml
[project]
name = "karaoke-chords-dl"
version = "0.1.0"
requires-python = "==3.11.*"
# Jiang 2019 + BTC (2019 code): numpy < 2; versions as verified in the spike (torch 2.14, librosa 0.11).
dependencies = ["torch", "numpy<2", "librosa", "mir_eval", "pretty_midi", "h5py", "pumpp", "jams", "scikit-learn",
                "pyyaml", "pandas", "pyrubberband", "matplotlib", "joblib", "pydub"]
```

`chords_ace/pyproject.toml`:

```toml
[project]
name = "karaoke-chords-ace"
version = "0.1.0"
requires-python = "==3.11.*"
dependencies = ["torch==2.6.0", "torchaudio==2.6.0", "librosa==0.11.0", "gin-config==0.5.0", "lightning==2.5.1",
                "harte-library==0.4.5", "mir_eval==0.8.2", "jams==0.3.5", "pumpp==0.6.0", "scikit-learn",
                "beat_this @ git+https://github.com/CPJKU/beat_this"]
```

`chords_dl/jiang_tool.py`:

```python
"""jiang_tool.py in.wav out.json — Jiang et al. 2019 large-vocabulary chords (submission dictionary)."""
import subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from chords_fetch import ensure, lab_to_segments, write_result

src, out = sys.argv[1], sys.argv[2]
repo = ensure("jiang", log=lambda m: print(m, file=sys.stderr))
with tempfile.TemporaryDirectory() as d:
    lab = Path(d) / "out.lab"
    subprocess.run([sys.executable, "chord_recognition.py", str(Path(src).resolve()), str(lab)], cwd=repo, check=True)
    write_result(out, lab_to_segments(lab.read_text()))
```

`chords_dl/btc_tool.py`:

```python
"""btc_tool.py in.wav out.json — BTC (Park et al. 2019), large vocabulary (170 classes)."""
import subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from chords_fetch import ensure, lab_to_segments, write_result

src, out = sys.argv[1], sys.argv[2]
repo = ensure("btc", log=lambda m: print(m, file=sys.stderr))
with tempfile.TemporaryDirectory() as d:
    (Path(d) / "song.wav").symlink_to(Path(src).resolve())     # test.py reads a folder
    subprocess.run([sys.executable, "test.py", "--voca", "True", "--audio_dir", d, "--save_dir", d], cwd=repo, check=True)
    lab = Path(d) / "song.lab"
    write_result(out, lab_to_segments(lab.read_text()) if lab.exists() else [])
```

`chords_ace/ace_tool.py`:

```python
"""ace_tool.py in.wav out.json — consonance-ACE (Poltronieri et al. 2025), decomposed root/bass/notes."""
import subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from chords_fetch import ensure, lab_to_segments, write_result

src, out = sys.argv[1], sys.argv[2]
repo = ensure("ace", log=lambda m: print(m, file=sys.stderr))
with tempfile.TemporaryDirectory() as d:
    lab = Path(d) / "out.lab"
    subprocess.run([sys.executable, "-m", "ACE.inference", "--audio", str(Path(src).resolve()), "--out", str(lab),
                    "--chord-min-duration", "0.5"], cwd=repo, check=True)
    write_result(out, lab_to_segments(lab.read_text()))
```

- [ ] **Step 4: Run the slow tests.** They install the environments and models on first run, which takes minutes.

Run: the Step 2 command
Expected: 3 passed. Then run the default suite (`uv --directory karaoke run pytest -q`): all pass, slow ones deselected.

- [ ] **Step 5: Commit** (with `uv.lock` files generated by the first run)

```bash
git add karaoke/tools/chords_dl karaoke/tools/chords_ace karaoke/tests/test_models_slow.py
git commit -m "karaoke: chord engine tool projects — Jiang 2019 + BTC (chords_dl), consonance-ACE (chords_ace)"
```

---

### Task 5: The `chords` step picks the engine

**Files:**
- Modify: `karaoke/src/karaoke/steps/chords.py`
- Modify: `karaoke/src/karaoke/tools.py` (`_TIMEOUTS["chords_engine"] = (1800.0, 2.0)`: first use installs)
- Test: `karaoke/tests/test_chords.py` (step tests; or a new `test_chords_step.py`)

**Interfaces:**
- Consumes: Task 1's `symbol`; Task 4's tool projects.
- Produces:
  - `steps.chords.ENGINES`;
  - `steps.chords.engine() -> str`;
  - the result adds `moteur` (label) and `entree` (`"harmonie"` | `"mix"`);
  - the journal line « accords : <label> (<entrée>) ».

- [ ] **Step 1: Failing tests** (new file `karaoke/tests/test_chords_step.py`)

```python
import json
from pathlib import Path
import numpy as np


def setup(cfg, monkeypatch, outputs, engine=None, silent=False):
    from karaoke.steps import chords as CH
    from karaoke.workspace import Workspace
    from test_manifest import song
    if engine:
        monkeypatch.setenv("KARAOKE_ACCORDS", engine)
    else:
        monkeypatch.delenv("KARAOKE_ACCORDS", raising=False)
    ws = Workspace(cfg, song())
    ws.work.mkdir(parents=True, exist_ok=True)
    ws.stems.mkdir(parents=True, exist_ok=True)
    sr, n = 44100, 44100 * 4
    tone = np.zeros(n) if silent else 0.3 * np.sin(np.arange(n) / sr * 2 * np.pi * 220)
    from karaoke import audio
    for s in ("bass", "guitar", "piano", "other"):
        audio.write_wav(ws.stems / f"{s}.wav", tone.astype(np.float32), sr)
    audio.write_wav(ws.work / "input.wav", (0.3 * np.sin(np.arange(n) / sr * 2 * np.pi * 220)).astype(np.float32), sr)
    calls = []
    def fake(tool, args, **kw):
        calls.append((tool, Path(args[1]).name, Path(args[2]).name))
        Path(args[3]).write_text(json.dumps(outputs[tool]))
    monkeypatch.setattr(CH, "run_tool", fake)
    beats = [0.5 * i for i in range(8)]
    up = {"ingest": {"duration_s": 4.0}, "separate": {}, "beats": {"beats": beats, "downbeats": beats[::4]}}
    return CH, ws, up, calls


MADMOM = {"segments": [[0, 4, "C:maj"]], "key": "C major"}
DL = {"segments": [[0, 2, "A:maj/6"], [2, 4, "G:7"]], "key": None}


def test_default_engine_is_jiang_and_key_comes_from_madmom(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords_dl": DL, "chords": MADMOM})
    r = CH.CHORDS.run(ws, up)
    assert ("chords_dl", "jiang_tool.py", "harmonie.wav") in calls and r["key"] == "C major"
    assert r["moteur"] == "Jiang 2019" and r["entree"] == "harmonie"
    assert [c for b in r["bars"] for _, c in b["chords"]] == ["F#m7", "G7"]
    assert "accords : Jiang 2019 (harmonie)" in (ws.work / "journal.log").read_text()


def test_engine_in_step_key(cfg, monkeypatch):
    CH, ws, up, _ = setup(cfg, monkeypatch, {}, engine="btc")
    k_btc = CH.CHORDS.key(ws)
    monkeypatch.setenv("KARAOKE_ACCORDS", "ace")
    assert k_btc.startswith("btc|") and CH.CHORDS.key(ws).startswith("ace|")
    monkeypatch.setenv("KARAOKE_ACCORDS", "nonsense")
    assert CH.CHORDS.key(ws).startswith("jiang|")


def test_madmom_engine_runs_one_tool(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords": MADMOM}, engine="madmom")
    r = CH.CHORDS.run(ws, up)
    assert [c[0] for c in calls] == ["chords"] and r["moteur"] == "madmom"


def test_silent_harmonic_stem_falls_back_to_the_mix(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords_dl": DL, "chords": MADMOM}, engine="btc", silent=True)
    r = CH.CHORDS.run(ws, up)
    assert ("chords_dl", "btc_tool.py", "input.wav") in calls and r["entree"] == "mix"


def test_empty_engine_output_is_a_soft_failure(cfg, monkeypatch):
    CH, ws, up, _ = setup(cfg, monkeypatch, {"chords_dl": {"segments": [], "key": None}, "chords": MADMOM}, engine="btc")
    r = CH.CHORDS.run(ws, up)
    assert r["bars"] == [] and "aucun accord" in r["erreur"] and r["moteur"] == "BTC"


def test_correction_wins_over_any_engine(cfg, monkeypatch):
    CH, ws, up, calls = setup(cfg, monkeypatch, {"chords_dl": DL, "chords": MADMOM}, engine="ace")
    cfg.accords.mkdir(parents=True, exist_ok=True)
    (cfg.accords / f"{ws.song.id}.txt").write_text("Tonalité : C major · 4/4\n\n| C | G |\n", encoding="utf-8")
    r = CH.CHORDS.run(ws, up)
    assert calls == [] and r["source"] == "correction"
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv --directory karaoke run pytest -q tests/test_chords_step.py`
Expected: FAIL (no `moteur`; only the madmom tool is called)

- [ ] **Step 3: Implement** (`steps/chords.py`)

```python
import os

ENGINES = {"jiang": ("chords_dl", "jiang_tool.py", "Jiang 2019"), "btc": ("chords_dl", "btc_tool.py", "BTC"),
           "ace": ("chords_ace", "ace_tool.py", "consonance-ACE"), "madmom": ("chords", "chords_tool.py", "madmom")}
SILENT_DBFS = -45.0


def engine() -> str:
    e = os.environ.get("KARAOKE_ACCORDS", "jiang")
    return e if e in ENGINES else "jiang"


def _detect(ws, wav, duration) -> tuple[list, str]:
    """(segments from the chosen engine, key from madmom's CNN key model)."""
    project, script, _ = ENGINES[engine()]
    out = ws.work / "chords.json"
    t = "chords" if project == "chords" else "chords_engine"
    run_tool(project, ["python", str(TOOLS_DIR / project / script), str(wav), str(out)], timeout=tool_timeout(t, duration))
    data = json.loads(out.read_text())
    if project == "chords":
        return data["segments"], data["key"]
    kout = ws.work / "chords_madmom.json"
    run_tool("chords", ["python", str(TOOLS_DIR / "chords" / "chords_tool.py"), str(wav), str(kout)],
             timeout=tool_timeout("chords", duration))
    return data["segments"], json.loads(kout.read_text())["key"]
```

In `_run`'s detection branch:
- After writing `harm`, pick the input:

  ```python
  rms = float(np.sqrt(np.mean(np.square(mix / len(HARMONIC))))) if len(mix) else 0.0
  silent = rms <= 0 or 20 * np.log10(rms) < SILENT_DBFS
  wav, entree = (ws.work / "input.wav", "mix") if silent else (harm, "harmonie")
  ```
- Call `segments, key = _detect(ws, wav, upstream["ingest"]["duration_s"])` inside the existing `try`.
- When `segments` is empty, return the existing soft-failure dict with `"erreur": "aucun accord détecté"`.
- Keep `labels = spell(merge_blips(chords_per_beat(segments, beats)), key)`. `chords_per_beat` already calls
  `symbol`.
- Add `"moteur": ENGINES[engine()][2], "entree": entree` to the success dict, and `"moteur"` to the soft-failure dicts.
- Before returning, call `ws.log(f"accords : {ENGINES[engine()][2]} ({entree})")`.

`_key` becomes:

```python
def _key(ws: Workspace) -> str:
    p = ws.cfg.accords / f"{ws.song.id}.txt"
    return f"{engine()}|spell-by-key|v2|" + (hashlib.sha1(p.read_bytes()).hexdigest() if p.exists() else "-")
```

Bump `CHORDS` `version` by one, with the comment « moteur au choix (KARAOKE_ACCORDS), vocabulaire étendu ».

- [ ] **Step 4: Run the whole Python suite.** Expected: all pass. Adjust any existing test that pinned the old key
  string or version, and ledger it.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src karaoke/tests
git commit -m "karaoke: chords step uses the chosen engine (KARAOKE_ACCORDS), madmom key, full-mix fallback"
```

---

### Task 6: Réglages menu and the env var

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/ChordEngine.swift`
- Modify: `karaifyer/Sources/Karaifyer/Pipeline.swift` (`env`)
- Modify: `karaifyer/Sources/Karaifyer/SettingsView.swift` (menu row)
- Test: `karaifyer/Tests/KaraifyerCoreTests/ChordEngineTests.swift`

**Interfaces:**
- Produces: `ChordEngine: String, CaseIterable` with cases `jiang`, `btc`, `ace`, `madmom`, `label`, and
  `ChordEngine.from(saved: String?) -> ChordEngine`.

- [ ] **Step 1: Failing test**

```swift
import Testing
@testable import KaraifyerCore

struct ChordEngineTests {
    @Test func engineFromSettings() {
        #expect(ChordEngine.from(saved: nil) == .jiang && ChordEngine.from(saved: "nope") == .jiang)
        #expect(ChordEngine.from(saved: "btc") == .btc && ChordEngine.from(saved: "madmom") == .madmom)
        #expect(ChordEngine.allCases.map(\.rawValue) == ["jiang", "btc", "ace", "madmom"])
        #expect(ChordEngine.jiang.label == "Jiang 2019 (recommandé)" && ChordEngine.madmom.label == "madmom (ancien)")
    }
}
```

- [ ] **Step 2: Run it** (`--filter engineFromSettings`). Expected: FAIL, `cannot find 'ChordEngine'`.

- [ ] **Step 3: Implement**

```swift
/// The chord detector the analysis uses (karaoke/steps/chords.py ENGINES), passed as KARAOKE_ACCORDS.
public enum ChordEngine: String, CaseIterable, Sendable {
    case jiang, btc, ace, madmom
    public var label: String {
        switch self {
        case .jiang: "Jiang 2019 (recommandé)"
        case .btc: "BTC"
        case .ace: "consonance-ACE"
        case .madmom: "madmom (ancien)"
        }
    }
    public static func from(saved: String?) -> ChordEngine { saved.flatMap(ChordEngine.init(rawValue:)) ?? .jiang }
}
```

- `Pipeline.env`: add `e["KARAOKE_ACCORDS"] = ChordEngine.from(saved: UserDefaults.standard.string(forKey: "chordEngine")).rawValue`.
- `SettingsView`, after the three folder rows:

```swift
            HStack {
                Text("Détecteur d'accords").frame(width: 170, alignment: .leading)
                Picker("", selection: Binding(get: { ChordEngine.from(saved: UserDefaults.standard.string(forKey: "chordEngine")) },
                                              set: { store.set("chordEngine", $0.rawValue) })) {
                    ForEach(ChordEngine.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 260)
                Spacer()
            }
            Text("S'applique aux analyses suivantes ; changer de détecteur refait l'étape des accords (≈ 10 s par morceau). La première utilisation installe le détecteur (connexion requise une fois).")
                .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 4: Swift suite, build and install**

Run: the Swift suite, then `cd karaifyer && ./build-app.sh --install`
Expected: all pass; `Installed ~/Applications/Karaifyer.app`

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources karaifyer/Tests
git commit -m "karaifyer: « Détecteur d'accords » in Réglages (KARAOKE_ACCORDS)"
```

---

### Task 7: Real run, docs, checklist

**Files:**
- Modify: `docs/guide/GUIDE.md` (Réglages section; the chords section's description of detection)
- Modify: `docs/karaoke/karaifyer-validation.md` (new rows)
- Modify: `karaifyer/README.md`, `karaoke/README.md` (detector line)

- [ ] **Step 1: Real end-to-end run on Danser.** With the network on, run
  `KARAOKE_ACCORDS=jiang uv --directory karaoke run karaoke traiter --ids 005 --forcer chords`.
  - **Expected:** the step status is `fait`. The journal has « installation du détecteur jiang » (first time) and
    « accords : Jiang 2019 (harmonie) ».
  - Song 005 has a correction file (`accords/005.txt`). To see the detector's own output, run the same command on a
    song without one, e.g. 042, and check `etat --json` bars for 7th or slash symbols where the engine produced them.
- [ ] **Step 2: Offline check.** Disconnect isn't possible from a tool call. Instead, run song 042 a second time with
  `HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 KARAOKE_ACCORDS=jiang … --forcer chords`.
  Expected: `fait`, because the cache and the uv environment are reused.
- [ ] **Step 3: Docs.**
  - **Guide, Réglages:** « Détecteur d'accords : Jiang 2019 (recommandé), BTC, consonance-ACE ou madmom (ancien).
    S'applique aux analyses suivantes ; changer refait l'étape des accords. Première utilisation : installation (une
    connexion requise une fois). » Then one line on what each is good at, from the spec's « Choice ».
  - **Checklist rows:**
    - « Réglages: switch the chord detector, analyse a song without a chord correction; the journal names the
      detector and the grid shows 7th/sus/slash chords where heard »;
    - « Danser analysed with Jiang: F#m7 where Michel had written A/F# ».
- [ ] **Step 4: Commit**

```bash
git add docs karaifyer/README.md karaoke/README.md
git commit -m "docs: chord detectors (Réglages, guide, checklist)"
```
