# Live lyrics video: bar grid + lyrics layout, neon background, one Swift renderer

## Why

- **The video is made of still images today.** Python draws one PNG per display state (Pillow) and ffmpeg strings
  them together, so nothing can move between two states. An animated background would mean drawing about 5,000
  frames per song in Python.
- **The chord display is confusing.** It shows chords above the syllables, switches to a 4-bar row during
  instrumentals, then switches back mid-bar.
- **The Lecteur plays a pre-rendered MP4.** Changing the transposition there can't change the chords on screen, and
  that change is what helps Michel find a capo position.

## What Michel gets

### The new layout: « Grille + paroles » (the default)

- **A neon frame** fills the picture. It's cyan on a dark brick wall, like the reference image.
- **The song's title and artist** are written in pink neon, breaking the top edge of the frame.
- **Top half, the bar grid:** 2 rows of 4 bars.
  - The **top row is always the active one**. Its 4 cells show the bars being played, each chord at its beat
    position in the bar.
  - A **cursor moves beat by beat** under the chords.
  - When the active row ends, the bottom row moves up and the next 4 bars appear below, so the next 4 bars are always
    visible in advance.
  - The current bar is highlighted.
  - « N.C. » is shown like a chord.
  - Before the first bar (the count-in) the grid shows the first 8 bars, with the count-in beats as dots.
- **Bottom half, the lyrics only:**
  - the current line, lit syllable by syllable;
  - the next line smaller underneath;
  - the existing countdown dots before a line after a long gap;
  - no chords over the syllables.
- **Timing:** the existing rules are kept. A line appears 0.5 s before its first word, and lines end at their last
  word.

### The current layout: « Accords sur les paroles » (option)

It's the current video (chords above the syllables, the 4-bar row during instrumentals, the next line preview),
redrawn by the new renderer, with the same neon background.

### Motion

- **The title neon** breathes slowly (about 4 s per cycle), with an occasional short flicker.
- **The frame** glows a little brighter on each beat and more on beat 1, decaying over about 0.25 s.
- **Reproducible:** the animation is driven by the song's time only, never the clock, so an export and a live
  playback look the same, and a re-render of an unchanged song gives the same file.

### In the Lecteur

- **The video is drawn live,** synced to the audio engine. That covers the window view and full screen
  (double-click / Escape, as today). Tempo changes, seeks and loops follow immediately.
- **Transposition:** the « Hauteur » setting transposes the **chords shown**, spelled for the new key, while the
  audio pitch works as today. Nothing is saved; this is only for finding a capo position.
- **« Disposition » menu:** « Grille + paroles » or « Accords sur les paroles », remembered.
- **Export:** « Exporter le mix… » → « Vidéo + master » now renders the video with this renderer, in the current
  disposition, transposition and tempo, instead of re-timing `paroles.mp4` with ffmpeg. The audio part is unchanged.

### In the Karaoké tab

- A **« Vidéo : Grille + paroles / Accords sur les paroles »** menu in the toolbar chooses the disposition of the
  videos the analysis renders (`paroles.mp4`, used by the Ableton sets). The default is « Grille + paroles ».
- Changing it re-renders the videos at the next analysis. Only the video step and what depends on it re-run.

## How it works

- **The scene:**
  - The pipeline's `video` step keeps computing the display states with its existing, tested timeline code
    (`build_states`, `with_chart`).
  - It writes them to **`sortie/<dossier>/video.json`** (the *scene*), together with:
    - the beats and bar lines in show time;
    - the bars with their chords per beat;
    - the title and artist;
    - `pad_s`, `total_s` and the disposition.
  - Times are in show time, like `paroles.lrc` and the audio files.
- **One renderer, in KaraifyerCore:**
  - `KaraokeRenderer.draw(scene, t, in: CGContext, size, options)` draws the frame at show time `t` with Core
    Graphics and Core Text.
  - Options are the disposition and the transposition.
  - The brick wall is drawn once into a cached image.
  - Fonts are those of today's video: Arial Bold, Arial, and Arial Unicode for ♪ ●.
- **Three uses of the same drawing:**
  - **Lecteur:** an `NSView` redrawn on the display link, at `t` = the engine's position.
  - **Export:** `AVAssetWriter`, H.264, 1920×1080, 25 fps, one `CGContext` frame at a time; then ffmpeg muxes the
    audio as today.
  - **Pipeline:** a new command-line tool, `karaifyer-render scene.json out.mp4`, built with Karaifyer (an extra
    executable target of the Swift package, installed next to the app).
    - The `video` step calls it through `KARAOKE_RENDERER` (set by the app) or the built path.
    - When the tool isn't found (command-line only use, never built), the step falls back to the existing Python
      renderer in the « Accords sur les paroles » layout, without the animation, and says so in the journal.
- **Keys:**
  - The video step key includes the disposition (`KARAOKE_VIDEO_LAYOUT`, set by the app from the Karaoké tab's menu)
    and the renderer version.
  - Version bump: the next analysis re-renders every video once.
- **Transposition:** `ChordText.transpose(symbol, semitones, key)` in KaraifyerCore moves chord symbols, spelled with
  flats in flat keys. It's the same rule as the pipeline's `chord_sources`, with tests on the same cases.

## Out of scope

- Saving a transposition, or changing a song's key (« enregistrer les accords »): a later round.
- Changing the audio key on export (the audio stays in its original key; pitch is a playback setting).
- Other visual themes or colours.
- Live-rendering anywhere other than the Lecteur (the Corriger window keeps its own player, with no video).

## Testing

- **Python:**
  - the scene JSON written by the video step (fields, show-time values, disposition);
  - the step key following `KARAOKE_VIDEO_LAYOUT`;
  - the fallback to the Python renderer when `karaifyer-render` is missing.
- **Swift (KaraifyerCore):**
  - **Grid paging:** which 8 bars are shown and which bar/beat is active at a given `t`, including the count-in,
    the last row and single-bar songs.
  - **The animation functions:** breathing, flicker and beat pulse values are deterministic for a given `t` and peak
    on beat 1.
  - **Chord transposition and spelling.**
  - **Scene decoding.**
  - **Drawing:** a frame drawn into a bitmap context has the expected size and non-empty pixels in the title, grid and
    lyrics areas.
  - **Export:** a 3-second MP4 of the expected duration.
- **`karaifyer-render` on a real song:** song 042's scene gives an MP4 of `total_s` (±1 frame).
- **Manual (Michel's checklist):**
  - the Lecteur shows the live video in sync, in full screen too;
  - « Hauteur » changes the chords shown;
  - « Disposition » switches the layout;
  - the export carries the chosen layout;
  - the Karaoké tab menu changes the rendered `paroles.mp4`.
