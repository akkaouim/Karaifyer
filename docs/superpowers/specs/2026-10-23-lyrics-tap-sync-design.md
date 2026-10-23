# Lyrics tap sync

## Why

- **LRCLIB timings are often off.** They come from another version of the song, and lines appear late or early.
- **Fixing them today is slow.** It means stamping lines one by one (⏱) in the Corriger window.
- **What Michel wants:** play the song once, press a key at the start of each line, and get the timings, with the
  song's real count-in so he can anticipate the first line.

## What Michel gets

A **« Synchroniser »** button in the Corriger window's lyrics column opens the sync mode, in the same window.

### Sync mode

- **The song plays exactly as in the Corriger window's player:** the recording (`travail/<id>/input.wav`) at the
  window's volume, with the « Clic » overlay if it's on.
- **The count-in:** the 4 count-in clicks are played first. They are the first `pad_s` seconds of the song's click
  track (`sortie/<dossier>/clic.flac`), the same count-in as the show. The recording starts right after them.
- **What's on screen:**
  - the lyrics list, with the **active line** (the next one to stamp) highlighted in a large font;
  - the line before and the line after;
  - a progress count, « 12 / 38 ».
- **Keys:**
  - **Return** stamps the active line at the current playback time, then the next line becomes active.
  - **↑ or ⌫** cancels the last stamp (that line gets its previous time back and is active again).
  - **Space** pauses or resumes.
  - **Escape** leaves sync mode and keeps what has been stamped.
  - Every stamp is also a normal edit: ⌘Z undoes it after leaving the mode, and the window is marked modified.
- **Snapping:**
  - Each stamp is moved onto the start of the voice: the onset found in `guide_voix.flac` between 0.4 s before and
    0.1 s after the key press (a key press is typically 0.15–0.25 s late).
  - If no onset is found in that window, the raw press time is kept.
  - The video keeps showing each line 0.5 s before its time, as today.
- **The end:** after the last line is stamped, playback continues to the end of the song, then the mode closes and
  shows « 38 lignes synchronisées ».
- **Starting from a line:** « Synchroniser à partir de la ligne sélectionnée » starts 2 s before the previous line's
  time, so a single passage can be redone without replaying everything.

### Editing while paused

- When paused, the lyrics list is editable as it is today: fix a word, add a line (+ Ligne), delete a line.
- **« Remplacer le texte… »** opens a sheet with all lines as text, one per line. ⌘A then ⌘V replaces everything.
- **On « Valider »:**
  - Lines whose text matches an old line, in order, keep its time.
  - New lines get times interpolated between their neighbours.
  - The active line becomes the first new or changed line, ready to stamp.

### Saving

- « Enregistrer » writes `paroles/<id>.lrc`, Michel's lyrics correction, as today. The pipeline already gives it
  priority over LRCLIB (source « fichier-lrc »).
- The re-analysis aligns the words inside each line, as it already does for corrected files, and re-renders the
  video.

## How it works

- **Time base.** Show time = input time + `pad_s`. That's the time base of the video, the LRC and the editor's lyric
  lines. The count-in occupies show time 0 to `pad_s`, and the recording plays from `pad_s`. A stamp is the show time
  of the key press: `pad_s` plus the recording player's current time, or, during the count-in, the count-in player's
  time.
- **Players.**
  - The editor's existing `AVAudioPlayer` plays the recording, and its click overlay keeps working.
  - A second `AVAudioPlayer` plays the count-in extracted from `clic.flac`.
  - Both are started with `play(atTime:)` on the same device time, the recording delayed by `pad_s`, as the editor
    already does for the click overlay.
  - Starting from a line seeks the recording; the count-in is only played when starting from the beginning.
- **Onset detection.** `VocalOnset` in KaraifyerCore:
  - It works on an RMS envelope of `guide_voix.flac` (10 ms hop), computed when the mode opens.
  - An onset is the first frame in the search window where the envelope rises above the window's noise floor plus
    12 dB and stays there for 50 ms. It returns nil when there's none.
- **Missing files.** A song without `clic.flac` or `guide_voix.flac` (not analysed yet) shows the button disabled,
  with the help text « Analyser le morceau d'abord ».

## Out of scope

- Word-by-word or syllable-by-syllable tapping. The pipeline aligns words inside each line.
- Tapping chord changes.
- Tempo or pitch change during sync.

## Testing

- **Swift (KaraifyerCore):**
  - `VocalOnset`: an onset found in the window, nil in silence or when the voice is steady across the window, and the
    window bounds respected;
  - the sync state machine (`LyricsSync`): stamp → next, cancel → previous time restored, stamping past the last line
    does nothing, starting from a line;
  - the replace-text merge: unchanged lines keep their times, new lines are interpolated, the active line is the first
    changed one.
- **Manual (Michel's checklist):**
  - sync a whole song with Return;
  - cancel a stamp with ↑;
  - pause, fix a word, resume;
  - replace the whole text;
  - save, and check that the video's lines appear on the voice.
