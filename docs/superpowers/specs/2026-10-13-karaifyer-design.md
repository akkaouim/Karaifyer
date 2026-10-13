# Karaifyer — macOS app for recording and the karaoke pipeline (design)

Agreed with Michel on 2026-10-13. Karaifyer is a new app, built from a copy of SysRec. **SysRec stays as it is.**

## Purpose

One Mac app to prepare the karaoke show:
- record songs from Spotify, as SysRec does;
- add songs from other audio files;
- fill in the manifest;
- run the analysis overnight while watching its progress;
- open the results;
- correct lyrics and chord charts by ear.

**Success:** Michel goes from a list of songs to show folders, Ableton sets, chord charts and iReal Pro links without opening a terminal or a spreadsheet. Every correction he makes survives a re-run.

## Decisions

| Topic | Decision |
|---|---|
| App | New SwiftPM package in `karaifyer/`, product **Karaifyer**, copied from SysRec. SysRec's `Sources/`, `Tests/`, `Package.swift` and `build-app.sh` are not modified. |
| Bundle | `com.akkaouim.karaifyer`, so its macOS permissions (system audio recording, Automation → Spotify) are separate from SysRec's and are asked again. |
| Pipeline | Stays in Python (`karaoke` command, `uv run`). The app calls the command line and reads its JSON output. The command line keeps working without the app. |
| Recording → analysis | Separate. The analysis starts with one click. Songs from outside SysRec can be added; this adds manifest rows. |
| Run unit | One `karaoke traiter --ids <id> --json` process per song, songs in sequence. |
| Editing | Lyrics and chords as text, with a player. Saved corrections override detection permanently. |

## 1. App structure

- `karaifyer/Package.swift` has three targets:
  - `KaraifyerCore`: a library with no UI, holding the pure logic shared with the tests: the CSV and track-list parsing copied from SysRecCore, pipeline JSON decoding, LRC parse/format, chord-grid cell checks, and the run state machine;
  - `Karaifyer`: the app, holding SysRec's recording sources (copied) plus the karaoke UI;
  - `KaraifyerTests`.
- `karaifyer/build-app.sh` builds `Karaifyer.app` the same way SysRec's script does: ad-hoc signed, Command Line Tools only (no Xcode, no `@State`).
- It has a menu-bar icon like SysRec, and one main window with two tabs:
  - **Enregistrement:** SysRec's queue view, unchanged.
  - **Karaoké:** the new part.
- The menu bar shows the recording status and, when the analysis is running, its status (`Analyse 12/120 · 005 Danser`), along with Pause/Resume and both Stop commands.

## 2. The Karaoké tab

**Toolbar**
- **Ajouter des morceaux…**: opens a file picker (FLAC, WAV, MP3, M4A/AAC, AIFF), then runs `karaoke ajouter`.
- **Analyser**: analyses the selected rows, or all rows when nothing is selected.
- **Pause / Reprendre**, **Arrêter après ce morceau**, **Arrêter maintenant**.
- **Rapport**: opens `rapport.html`.
- **iReal Pro**: opens `ireal/<partie>.html`, or the folder when there are several.

**Song table** (one row per manifest row)
- id, titre and artiste (editable).
- **retirer**: five checkboxes, Guitare / Basse / Piano / Batterie / Autres, which map to `guitar`, `bass`, `piano`, `drums` and `other`.
- **langue**: a menu (fr, en, and the others the aligner supports).
- **partie**: editable text.
- **statut**: ok / alerte / échec / à réessayer / —.
- **one dot per pipeline step**:
  - grey = not up to date;
  - blue = running;
  - green = done;
  - orange = blocked;
  - red = failed, with the error on hover.
- Every edit is saved at once through `karaoke modifier`. When an edit changes a step's input (for example `retirer` for `package`), the affected dots turn grey: the next analysis redoes those steps only.

**Context menu**
- Ouvrir le dossier / la vidéo / le set Ableton / la grille d'accords.
- Refaire le morceau, which runs with `--forcer ingest`, so every step reruns.
- Refaire une étape ▸, which lists the steps and runs with `--forcer <step>`; the later steps follow by themselves.
- Corriger paroles et accords…

**Bottom of the window**
- **Progress bar:** `Morceau 12/120 · 005 Danser · étape : separate · reste ≈ 9 h 10`.
  - Progress = finished steps / steps to run, across the queued songs.
  - The time left is estimated from the steps' measured durations (`seconds` in the markers); when no measurement exists, from 7 min per song.
- **Terminal pane:** collapsible, monospaced, and auto-scrolling unless the user has scrolled up. It shows the live log of the running analysis, prefixed with the song id, keeps the last 5,000 lines, and has a Copier button.

## 3. Run control

- The app keeps a queue of song ids. For each one it starts `uv run karaoke traiter --ids <id> --json`, with `KARAOKE_HOME` and `KARAOKE_GABARIT` taken from Settings. The process gets its own process group.
- **Pause:** sends `SIGSTOP` to the process group, which freezes uv, Python and the ML tool. **Reprendre:** sends `SIGCONT`. The progress bar shows « En pause ».
- **Arrêter après ce morceau:** the current process finishes, and the queue stops there.
- **Arrêter maintenant:** sends `SIGCONT` (in case it is paused), then `SIGTERM` to the group, then `SIGKILL` after 10 s. The runner already deletes a step's marker before running it, so an interrupted step is redone at the next run.
- **States:** idle → running → paused ↔ running → stopping → idle. This state machine lives in `KaraifyerCore` and is unit-tested.
- **Sleep:** while running, the app holds `PreventUserIdleSystemSleep`, as the recorder already does.
- **Recording conflict:** if a recording batch starts while the analysis runs, the app proposes to pause the analysis. Analysis load caused glitches before, so the default is to pause.

## 4. Correction editor

One window per song, opened from the context menu.

**Player**
- Plays the song's `travail/<id>/input.wav` (the trimmed recording, in input time) with play/pause, a position slider and the current time.
- Times shown in the editor are in show time, the same as `paroles.lrc` (input time + `pad_s`). The editor converts between the two using the song's `pad_s`.

**Lyrics (left)**
- One row per line, `mm:ss.cc │ text`, with both the time and the text editable.
- Clicking a row seeks there. During playback, the line being sung is highlighted.
- **⏱** sets the selected line's time to the playback position.
- Lines can be added, deleted and reordered, and are kept sorted by time.

**Chords (right)**
- The key is shown at the top and is editable (for example `C# minor`).
- Below it, a grid with 4 bars per row. Clicking a bar seeks to its start; the current bar is highlighted during playback.
- Cell syntax:
  - `A B`: the chords split the bar evenly;
  - `Am . . F`: one token per beat, with `.` meaning the previous chord continues. The number of tokens must equal the beats per bar.
  - `N.C.` means no chord.
- Invalid cells are outlined in red, and saving is blocked until they are fixed.
- The grid keeps the detected bar positions. Only the chords change, not the bar timing.

**Enregistrer**
- Writes `$KARAOKE_HOME/paroles/<id>.lrc` (with `[karaoke:decalage=<pad_s>]`) and `$KARAOKE_HOME/accords/<id>.txt`.
- Then runs `traiter --ids <id> --json`. The resume logic redoes lyrics → check → video → set for a lyrics change, chords → video → set for a chords change, and the iReal page.
- **Annuler** closes the window without writing anything. If there are unsaved changes, it asks first.

## 5. Pipeline additions (Python, `karaoke/`)

**`traiter --json`**
- Writes one JSON object per line on stdout:
  - `{"event":"song_start","id"}`
  - `{"event":"step_start","id","step"}`
  - `{"event":"step_end","id","step","status","seconds","error"}`
  - `{"event":"song_end","id","statut"}`
  - `{"event":"log","id","line"}` for each journal line.
- It works through a callback in `run_song`. The human-readable output is unchanged without `--json`.

**`etat --json`**
- Prints one object per manifest row with:
  - the manifest fields;
  - `statut`;
  - `steps: [{name, status: a_jour|perime|echec|bloque|absent, seconds, error}]`;
  - `paths: {dossier, video, set, accords, lrc, audio}`;
  - `pad_s`, `beats_per_bar`, `bars: [{start, chords}]` and `key` from the markers.
- It computes up-to-date-ness the way the runner does (key + artifacts), without running anything. The app reads this command and nothing else.

**`ajouter <fichiers…>`**
- For each file: reads the title, artist, album and duration with ffprobe (falling back to the file name for the title), gives it the next free 3-digit id (max + 1), and appends a manifest row with `fichier` set to the absolute path and the other columns empty.
- Prints the added rows as JSON.
- A file already in the manifest (same absolute path) is reported and skipped.

**`modifier --id <id> --champ <name> --valeur <v>`**
- Edits one manifest cell (titre, artiste, retirer, langue, partie, decompte_mesures), using the same checks as `read_manifest`.
- Exits non-zero with a French message if the value is invalid. The CSV is written atomically.

**Chord corrections**
- When `$KARAOKE_HOME/accords/<id>.txt` exists, the `chords` step reads it instead of running madmom.
- File format: the same layout as `sortie/.../accords.txt`, with title line, `Tonalité : <key> · …` line and 4-bar rows, plus the per-beat `.` syntax.
- The bar count must equal the detected bar count, otherwise the step fails with a clear message.
- The file's content hash is part of the step key.
- `sortie/<dossier>/accords.txt`, the iReal link and the video then use the corrected chords.

**Lyrics corrections**
- These already exist (`paroles/<id>.lrc` with the decalage tag), and the editor writes that format. No change is needed.

## 6. Errors and settings

- **Settings window:**
  - the karaoke folder (default `/Volumes/Hypermnesia/karaoke`);
  - the Ableton template (default `<folder>/gabarit/gabarit Project/gabarit.als`);
  - the `karaoke` project path (default: the repo's `karaoke/`, found next to the app or chosen once).
- **Banner** with Analyser disabled when:
  - the folder isn't reachable (disk not mounted);
  - `uv` isn't found (the app looks in `/opt/homebrew/bin`, `~/.local/bin` and `/usr/local/bin`, because GUI apps don't get the shell PATH);
  - `manifeste.csv` doesn't exist. In that case the banner offers « Créer le manifeste depuis un dossier SysRec… », which runs `karaoke manifeste --audio`.
- **Step failures:** the dot turns red, the error appears on hover, and the context menu offers « Voir le journal » (`travail/<id>/journal.log`).
- **Exit codes:** a non-zero exit from a `traiter` process marks the song as failed in the table. The queue moves on to the next song.

## 7. Testing

- **Python:** every addition is written test-first with pytest:
  - the JSON event sequence;
  - `etat`'s up-to-date-ness against the runner;
  - `ajouter`'s id allocation, duplicate skipping and tag fallback;
  - `modifier`'s validation and atomic write;
  - the chord override (grid parse with `.`, bar-count mismatch, key change → rerun).
- **Swift (`KaraifyerTests`, Swift Testing):**
  - JSON event and `etat` decoding;
  - LRC parse/format round-trip, including the decalage tag;
  - show-time / input-time conversion;
  - chord-cell validation;
  - the run state machine (pause/resume/stop transitions and the signals sent, with a fake process).
- **Manual checklist for Michel:**
  - install and grant permissions;
  - record 2 songs;
  - add an outside file;
  - edit the manifest;
  - run, pause, resume, stop after the song, stop now, resume;
  - correct a lyric line and a chord and check the video and the iReal page;
  - check that SysRec still opens and records as before.

## Out of scope

- A visual waveform editor.
- Editing syllable timing directly.
- Running the analysis during recording.
- Sharing between machines.
