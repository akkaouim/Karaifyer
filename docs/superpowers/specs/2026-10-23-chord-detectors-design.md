# Chord detectors: BTC, Jiang 2019 and consonance-ACE, chosen in Réglages

Part 1 of the chord-correction work. Part 2, a separate spec that follows, covers tabs (paste and import), the open
datasets (Chordonomicon, patadata), and merging them with the detection.

## Why

- **The current detector is limited.** madmom DeepChroma only knows major and minor (25 classes).
- **What Michel sees:**
  - major/minor mix-ups;
  - the bass taken as the root;
  - none of 7, maj7, m7, 9, sus2, sus4, dim, aug or 6.
- **The test.** The three most credible offline models were tested on Karaifyer's songs:
  - BTC, Park 2019, 170 classes;
  - Jiang 2019, chord structure decomposition, inversions in its dictionary;
  - consonance-ACE, Poltronieri 2025, root, bass and notes predicted separately.

  Results are in « Evidence » below. No model wins everywhere, so Michel wants all three available and a setting to
  choose which one the analysis uses.

## What Michel gets

- **A « Détecteur d'accords » menu in Réglages (⌘,):**
  - **Jiang 2019 (recommandé)**, the default;
  - BTC;
  - consonance-ACE;
  - madmom (ancien).

  The choice is remembered. It applies to every analysis started afterwards, from the Karaoké tab (Analyser, Refaire le
  morceau, Refaire une étape) and from the command line.
- **What changing the detector does:**
  - The next analysis re-runs the `chords` step of every song, about 10 s per song, then what depends on it (video,
    report).
  - Songs with Michel's own chord correction (`accords/<id>.txt`) keep it, so nothing after the chord step changes for
    them.
  - Bar fixes (`mesures/<id>.json`) are kept.
- **Richer chords everywhere** (grid, Corriger, video, iReal):
  - 7, maj7, m7, m7b5, dim, dim7, aug, 6, m6, 9, sus2, sus4 and slash chords, whatever the chosen detector outputs;
  - a slash chord whose notes form a known chord on its bass note is named by that chord (Michel's convention, A/F# →
    **F#m7**).
- **The first analysis with a new detector:**
  - It downloads that detector's code and model once (12–55 MB plus the Python libraries) and needs internet that one
    time, like the other models already used.
  - After that it works offline.
  - The terminal shows « installation du détecteur … ».
- **The report and the song's journal name the detector used**, e.g. « accords : BTC ».

## Evidence (spike, 2026-10-22/23)

- **Input:** each detector ran on the same vocal-free harmonic stem the pipeline already builds (`harmonie.wav`).
- **Songs:** 16.

### Danser (Loïc Nottet)

- **Reference:** Michel's corrected chart, beat by beat, with his two confirmations: « C# » → C#m, A/F# = F#m7.
- **Scoring:** exact = same notes and same bass.

| Detector | root | maj/min | exact |
|---|---|---|---|
| **Jiang 2019** | **94 %** | **94 %** | 79 % |
| **BTC** | **94 %** | 93 % | **80 %** |
| madmom (current) | 88 % | 82 % | 70 % |
| consonance-ACE | 80 % | 74 % | 58 % |

### 15 songs with a patadata chart

- **Repertoire:** 13 French, 2 English.
- **Scoring:** these charts have no timing. Each figure is the share of the song's time spent on a chord the chart uses:
  same root / same maj-min chord / same notes. Charts written with a capo or in another key are transposed, with one
  transposition per song, the same for every detector.

| Detector | root | maj/min | exact |
|---|---|---|---|
| **Jiang 2019** | **94 %** | **91 %** | 83 % |
| **BTC** | 93 % | 90 % | 82 % |
| madmom (current) | 94 % | 89 % | **84 %** |
| consonance-ACE | 93 % | 88 % | 78 % |

These are the means over 13 songs. The two a cappella songs (Don't Worry Be Happy, Le lion est mort ce soir) are left out:
their harmonic stem is almost silent, so madmom and Jiang find nothing, BTC finds nothing usable, and only ACE invents
chords from the residue. madmom's « exact » is flattered here, because the charts are mostly plain triads, the only
thing madmom outputs.

**Choice:**
- **Default: Jiang 2019.** It's tied with BTC on Danser and slightly ahead on the charts' maj/min. It's the only one
  with inversions, 9, 11 and 13 in its dictionary.
- **BTC** is the close second. On the full mix (vocals included) it was clearly ahead: Danser exact 86 % vs 80 % for
  Jiang.
- **consonance-ACE** is last on this repertoire, but the only one that copes with damaged or near-empty audio.

**Caveats:**
- These charts are community-made and often simplified (no 7ths, no key change).
- An « exact » score below « maj/min » can mean that the detector heard a 7th the chart leaves out.
- On the recording with the capture fault (Les copains d'abord, half silence), BTC and Jiang output nothing. Only
  consonance-ACE gives a grid. That recording will be re-recorded.

## How it works

- **Tool projects:**
  - **madmom:** keeps `karaoke/tools/chords`.
  - **BTC + Jiang:** one new uv tool project, `karaoke/tools/chords_dl`. They share numpy 1.26, torch and librosa.
  - **consonance-ACE:** `karaoke/tools/chords_ace`, with numpy 2, torch 2.6, lightning and Beat This! from git.
- **Wrapper:** each project has `<engine>_tool.py in.wav out.json` writing the existing format
  `{segments: [[start, end, label]], key}`. Labels are Harte (`C#:min7`, `A:maj/3`, `N`).
- **Key:** the key always comes from madmom's CNN key model. It's run by the existing tool when the engine isn't
  madmom (≈1 s).
- **Third-party code is not copied into the repository:**
  - On first use, the wrapper fetches the upstream repository at a **pinned commit** into
    `~/.cache/karaoke/chords/<engine>-<commit>/`:
    - BTC: `jayg996/BTC-ISMIR19@2682317`;
    - Jiang: `music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition@481f4ce`;
    - ACE: `andreamust/consonance-ACE@d17633a`.
  - It checks the model files' sha256, then applies the few compatibility edits each needs:
    - BTC: `yaml.safe_load`, `torch.load(map_location="cpu", weights_only=False)`, the removed numpy aliases;
    - Jiang: the numpy aliases;
    - ACE: none.
  - Each edit asserts that its target text exists, so a changed upstream file fails clearly instead of silently.
  - All three are MIT-licensed. BTC's weights may be non-commercial, which is fine for private use.
- **The `chords` step:**
  - It reads the engine from `KARAOKE_ACCORDS` (`jiang` | `btc` | `ace` | `madmom`; unset → `jiang`) and runs that
    engine's tool on `harmonie.wav`.
  - When `harmonie.wav` is nearly silent (RMS below −45 dBFS, as in a cappella songs), it runs the tool on
    `input.wav` (the full mix) instead and records `entree: "mix"`.
  - The step key starts with the engine name, so switching engines re-runs the step.
  - The result records `moteur`.
  - Its timeout follows the existing `tool_timeout` scheme, with a longer base the first time (installation).
- **Labels to chart symbols:** `karaoke.chords.symbol` becomes a full Harte converter:
  - qualities to chart suffixes (maj → "", min → m, min7 → m7, hdim7 → m7b5, maj6 → 6, min6 → m6, sus4(b7) → 7sus4,
    …);
  - degrees after `/` to the bass note's name;
  - a slash chord whose notes plus bass form a chord rooted on the bass in the vocabulary is renamed to that chord
    (A/F# → F#m7, C/A → Am7);
  - an unknown quality falls back to its maj/min triad.
- **The chord vocabulary** (`SYMBOL` in Python, `ChordGrid.symbol` in Swift, iReal's `QUALITY`) gains dim7, m9,
  maj9, 7sus4, mM7, 11 and 13, so every converted label is valid in the grid, the Corriger window and iReal.
- **The app:**
  - Réglages gets the menu, saved in UserDefaults `chordEngine`.
  - `Pipeline.env` sets `KARAOKE_ACCORDS`.
  - Nothing else in the app changes.

## Out of scope (Part 2 or later)

- **Tab paste and import, the datasets, and merging them with the detection.** That's Part 2.
- **Using the separated bass stem to restore inversions** that a detector misses, for example with BTC, which has no
  inversions.
- **Running several detectors at once and voting.**
- **A per-song detector choice.** The setting applies to the whole run.

## Testing

- **Python, fast:**
  - the Harte → symbol converter, including slash → root-position renaming and fallback;
  - the step key and dispatch per engine (`run_tool` faked);
  - the full-mix fallback for a silent harmonic stem;
  - the madmom key merge;
  - the vocabulary additions in `parse_cell`, iReal and `etat`.
- **Python, slow** (`test_models_slow.py` pattern, deselected by default): each engine on a 20 s clip produces at least
  one segment and valid labels.
- **Swift:**
  - `ChordGrid` accepts the new symbols;
  - the settings value reaches `Pipeline.env`.
- **Manual (Michel's checklist):**
  - switch the detector in Réglages and analyse Danser;
  - the grid shows F#m7 where Michel corrected A/F#;
  - the journal names the detector;
  - with the network off after the first install, a second song still analyses.
