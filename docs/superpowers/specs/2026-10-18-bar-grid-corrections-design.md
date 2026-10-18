# Bar grid corrections: beat 1, time signature, click in « Corriger »

## Why

In *Danser* (005), from bar 50 (2:03.6) on, beat 1 of the chord grid is two beats away from the music. The beat
detection itself is right (steady 100 BPM). The raw detection even saw a 2-beat bar at 2:03.6. The clean-up
(`grid.regularize`) then put every bar line on a single phase, which is right for a detection error but wrong for a real
short bar. On top of that, the time signature is never wrong in a way Michel can fix: « 4/4 » is shown but can't
be changed, a 12/8 or swing feel isn't represented at all, and *Don't Worry Be Happy*, *Le Temps des cerises* and
*La petite église* came out in 2.

Goal: in the « Corriger » window, Michel hears where beat 1 is (a click), fixes it in one or two clicks, sets the
time signature, and the fix survives every re-analysis and reaches the chord grid, the video, the click track and
iReal.

## What Michel gets

### In the « Corriger » window

- **Click overlay:**
  - A « Clic » checkbox and a volume slider of its own, next to the volume slider in the playback bar.
  - When checked, a click plays over the recording on every beat, louder and higher on beat 1, following the grid
    as it currently stands in the window (fixes included, before saving).
  - The on/off state and the volume are remembered for all songs.
- **Beat counter:** « 1 2 3 4 » in the playback bar, with the current beat lit, from the same grid.
- **Time signature:** the « 4/4 » label next to the key becomes a menu: 2/4, 3/4, 4/4, 6/8, 12/8.
  - Next to it, a « Swing » checkbox.
  - Changing the menu regroups the beats into bars of the new length from the first bar line (or from each « beat
    1 » point, below), and the grid redraws at once.
- **Fixing beat 1:** a right-click on a bar cell offers:
  - « La mesure commence un temps plus tôt » / « … un temps plus tard »: this bar line moves by one beat. The
    previous bar gets one beat longer or shorter, and every bar after it follows, counting from the new position.
  - « Le temps 1 est ici »: pins this bar line where it is, so a later fix doesn't move it. A short bar is kept by
    pinning the bar after it.
  - « Retirer le repère » on a bar that carries one. A cell with a pin shows a small marker.
- **Chords follow their beats:** when the grid changes, the chords already in the cells (detected or typed) are
  re-cut beat by beat into the new bars. A chord stays on the same music, so fixes made before or after correcting
  chords don't undo each other.
- All of this goes through ⌘Z / ⇧⌘Z like the other edits, marks the window as modified, and is written by
  « Enregistrer ».

### In the pipeline

- **The beat grid fix file:**
  - « Enregistrer » writes `mesures/<id>.json` next to `accords/` and `paroles/`, in the karaoke folder.
  - The `beats` step applies it after the clean-up, so the chord grid, the video's chord rows, the click track
    (« Clic » in the Lecteur and in the Ableton set) and iReal all get the fixed bars.
  - The file's content is part of the `beats` step key, so changing it re-runs what depends on it. The beat
    detection itself isn't re-run: the raw `travail/<id>/beats.json` is reused when it exists.
- **Time signature:**
  - `accords.txt` writes the real signature (« 3/4 », « 12/8 ») instead of « N/4 ».
  - iReal gets `T24`, `T34`, `T44`, `T68` or `T12`.
  - iReal style: Waltz for 3/4 and 6/8, Slow Rock for 12/8, Medium Swing for 4/4 with swing, Pop otherwise.

## The rule (the same in Python and Swift)

Inputs: the cleaned beat times; the cleaned bar lines; the fix (signature or none, pinned bar lines).

- **Beats per bar** (in detected beats):
  - x/4: x.
  - 6/8 and 12/8: 2 and 4 when the detected tempo is at most 120 BPM (beats are dotted quarters); 6 and 12 above
    that (beats are eighths).
  - No signature: the detected value (unchanged).
- **Pins** are stored as times (seconds, input time) and snapped to the nearest beat, so a slightly different
  detection after a re-run keeps them.
- **Bar lines:**
  - Before the first pin, the cleaned bar lines stay as they are. With a signature, the first cleaned bar line
    is an implicit pin, unless a pin lies before it + N beats.
  - From each pin to the next one (or the end), there's a bar line every N beats starting at the pin.
  - The last bar before a pin can be shorter or longer than N.
- « Un temps plus tôt / plus tard » on a bar moves (or adds) the pin on that bar's line by one beat.

## The file

`mesures/<id>.json`:

```json
{"signature": "12/8", "swing": false, "pins": [123.58, 187.84]}
```

- `signature` may be `null` (keep the detection).
- When there's neither a signature nor pins, the file is deleted on save.

## Click in the editor

- **Playback:**
  - The editor keeps its `AVAudioPlayer` for the recording.
  - A second `AVAudioPlayer` plays a click track rendered in memory (mono 44.1 kHz, the same short clicks as the
    pipeline's « Clic »).
  - Both start together through `play(atTime:)` on the same device time, and a seek moves both.
- **Re-rendering:** the click track is rendered again (a few ms) whenever the grid changes.
- **Beat counter:** the beat counter and the click read the same beat list.

## Data the app needs

`karaoke etat --json` adds per song:
- `beats`: all beat times, input time;
- `signature` and `swing`, from the fix file (or null / false).

`bars` already exists.

## Out of scope

- **Halving or doubling the detected tempo** (*Don't Worry Be Happy* counted at 136 instead of 68). The signature
  menu can at least group it right (4/4 → 4 beats); a tempo fix would be a separate feature.
- **Swing subdivisions in the click** (the click stays on the beats).
- **The Ableton set's time signature** (its clips are unwarped at 120 BPM; nothing there reads the grid).
- **The other windows:** the Karaoké table and the Lecteur aren't changed, apart from what they get from the
  re-analysis.

## Testing

- **Python:**
  - the rule (pins, signature, tempo threshold for x/8, snapping);
  - the `beats` step reading the file and reusing the raw detection;
  - `accords.txt` and iReal signatures and styles;
  - `etat` exposing beats and signature.
- **Swift (KaraifyerCore):**
  - the same rule on the same cases;
  - re-cutting chord cells into a new grid;
  - « plus tôt / plus tard » and pins;
  - the click track rendering (a click on each beat, accents on bar lines);
  - the fix file round-trip;
  - undo across grid changes.
- **Manual (Michel's checklist):**
  - Danser: click on, hear the shift at bar 50, fix it, save, and check the video and the Lecteur's click.
  - A 3/4 song set to 3/4 shows 3-beat cells.
  - A 12/8 song in iReal.
