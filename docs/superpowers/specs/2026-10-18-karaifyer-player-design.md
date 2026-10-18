# Karaifyer Player tab (design)

Agreed with Michel on 2026-10-18. It is a third tab in Karaifyer, after Karaoké. Revised the same day: Michel
added **position scrubbing, looping, tempo (in BPM) and pitch change**. Pitch change needs an audio engine, so
the architecture moved from a single AVPlayer to AVAudioEngine, with the video following it.

## Purpose

The tab is used both for **rehearsing at home** and for **checking the analysis**:
- Rehearsing: play along with his live parts muted, and follow the lyrics and chords video, without Ableton or the XR18.
- Checking: solo each separated track to judge the separation, the click and the guide vocal before the show.

**Success:** Michel picks any analysed song, sees the lyrics video and hears the mix. He adjusts each track live and finds his mix again the next time he opens that song. Nothing goes to the XR18; the overall mix plays on the Mac's current audio output.

## Decisions

| Topic | Decision |
|---|---|
| Audio engine | **`AVAudioEngine`**: 8 `AVAudioPlayerNode`s (one per track file) → per-track `AVAudioMixerNode` (gain) → a submix → **`AVAudioUnitTimePitch`** (tempo `rate` + `pitch` in cents) → main mixer (master) → output. |
| Video | A **silent `AVPlayer`** on `paroles.mp4`, in an `AVPlayerView`, slaved to the audio. It plays at the same rate as the audio. Every 0.5 s its time is compared with the audio position, and it is re-seeked if they differ by more than 40 ms. On play, seek and loop, both are re-anchored together. |
| Output | The system's current audio output (`AVAudioEngine`'s default output, following the device selected in macOS). No XR18 routing, no device selection in the app. |
| Initial levels | First time: **like the show**: parts in `retirer` at zero, everything else at 0 dB (click and guide vocal included). Afterwards: **the last mix Michel left for that song**. |
| Tempo | Shown and set in **BPM**: the song's **typical tempo**, i.e. the median beat interval measured by the pipeline after the beat cleanup (robust to free intros and final slowdowns; for drifting songs, their typical tempo). Rate = target BPM / song BPM, with pitch preserved. Range: from 0.5 × to 1.5 × the song's BPM. |
| Pitch | −6…+6 semitones, tempo preserved. |
| Export | « Exporter le mix… »: **Vidéo + master** (`.mp4`, H.264) or **Master seul** (AAC, MP3, WAV or FLAC), with a **format and quality chosen by Michel** and remembered. The whole song, rendered exactly as heard (faders, mutes, solos, master, tempo, pitch): offline to a 24-bit WAV, then encoded with **ffmpeg** (already required). |
| Out of scope | Waveforms, transposed chord names in the video (the video keeps the original chords; a reminder is shown when transposed), exporting only the loop. |

## 1. Layout

**Left column (narrow)**
- A search field. It filters on title, artist or id, case-insensitively and ignoring accents (« ble » matches « blés »).
- The list of songs: `id · Titre — Artiste`, in manifest order.
  - **Ready** songs are selectable: their `paroles.mp4` and all 8 `.flac` files exist in the song folder.
  - Songs that are not ready are greyed out and not selectable; hovering one says what is missing.
- **Loading is deliberate**, so a loaded song (and its mix, loop and tempo) is never replaced by accident:
  - a single click only **selects** a song (highlighted) and changes nothing in the player;
  - **double-click** a ready song, or select it and click **« Charger »** (or press Return), to load it. This
    replaces the song already loaded and stops its playback;
  - the **loaded** song is marked with ▶︎ in the list, distinct from the selection;
  - searching or scrolling never affects the loaded song.

**Top right: the video**
- `paroles.mp4`, as large as the area allows, in an `AVPlayerView` with no built-in controls.
- **Double-click** toggles full screen. **Escape** also leaves full screen.
- With no song loaded, the area says « Choisir un morceau dans la liste ».

**Bottom right: transport and mixer (smaller than the video)**
- **Position bar** (under the video):
  - a slider over the song's length; dragging it seeks video and audio together;
  - the loop zone is highlighted on it when a loop is set.
- **Transport:**
  - ⏮ goes back to the start (seek to 0, keeping the play/pause state);
  - ▶︎/⏸ plays or pauses;
  - the time shows as `m:ss / m:ss`, in song time (unaffected by tempo).
- **Loop:**
  - « Début de boucle » and « Fin de boucle » set the loop's start and end at the current position, **snapped to
    the nearest bar line** of the song's analysis (`bars[].start`; if there are no bars, to the nearest 0.1 s);
  - a « Boucle » toggle switches it on or off, and « Effacer » removes it;
  - the end must come after the start; when it doesn't, the two are swapped;
  - while the loop is on, reaching its end jumps back to its start with no audible gap (the loop segment is
    scheduled in advance).
- **Tempo:**
  - « Tempo : N BPM » with − / + (1 BPM steps) and a field to type a value;
  - « Original (N) » resets it;
  - the value is clamped to the allowed range.
- **Pitch:**
  - « Hauteur : ±n demi-tons » with − / + and « 0 » to reset;
  - when n ≠ 0, a reminder is shown: « Transposé +n : accords de la vidéo dans la tonalité d'origine ».
- **Mixer**, 9 columns:
  - Track columns, in this order: Clic, Guide voix, Guitare, Basse, Piano, Batterie, Accompagnement, Back Vocals.
  - Each track column has a vertical gain fader from −∞ to +6 dB, with the value shown (« −∞ », « −12 dB », « 0 dB », « +3 dB »).
  - Each track column has an **M** (mute) and an **S** (solo) toggle, lit when active.
  - **Master** has a fader only (same range); it drives the player's overall volume.

**Export**
- An « Exporter le mix… » button opens a sheet: **Vidéo + master** or **Master seul (audio)**, the format and
  quality options below, then a save dialog. The sheet remembers the last choices (`UserDefaults`, key
  `playerExport`).

  | Kind | Format | Quality options (default in bold) |
  |---|---|---|
  | Master seul | **AAC (`.m4a`)** | 128 / 192 / **256** / 320 kbps |
  | Master seul | MP3 (`.mp3`) | 128 / 192 / 256 / 320 kbps (default **256**) |
  | Master seul | WAV (`.wav`) | 16 / **24** bits, 44.1 kHz |
  | Master seul | FLAC (`.flac`) | 16 / **24** bits, 44.1 kHz |
  | Vidéo + master | **MP4 (`.mp4`)**, H.264 | resolution **1080p** / 720p; video quality **Haute** (CRF 18) / Standard (CRF 23); sound AAC 128 / 192 / **256** / 320 kbps |

- The default name is `<id> <Titre> – mix.<ext>`, and the default folder is the song's output folder.
- **What is exported:** the whole song (the loop is ignored), with the current faders, mutes, solos, master,
  tempo and pitch.
- **Rendering:** the engine graph runs in **offline manual-rendering mode** (`AVAudioEngine.enableManualRenderingMode`,
  `.offline`) to a temporary 24-bit 44.1 kHz WAV. With a changed tempo, the audio is shorter or longer accordingly.
- **Encoding (ffmpeg):**
  - AAC: `-c:a aac -b:a <k>`; MP3: `-c:a libmp3lame -b:a <k>`; WAV: `-c:a pcm_s16le|pcm_s24le`;
    FLAC: `-c:a flac -sample_fmt s16|s32`, with `-bits_per_raw_sample 24` for 24 bits;
  - video + master: `paroles.mp4` time-scaled with `setpts=PTS/<rate>`, scaled to the chosen height, and encoded
    `libx264 -crf <18|23> -pix_fmt yuv420p`, plus the rendered audio as AAC, `-shortest`, into `.mp4`.
- **During the export:** playback pauses; a sheet shows a progress bar (rendering, then encoding from ffmpeg's
  `-progress` output) and an « Annuler » button that stops ffmpeg and deletes any partial file. When it's done,
  « Exporté : <nom> » appears, with « Afficher dans le Finder ».
- **Errors** (disk full, unreadable file, ffmpeg missing or failing) are shown in the sheet with ffmpeg's last
  message, and no partial file is left.

**Keyboard:** **Space** plays or pauses everything, except while the search field is being edited (there it types a space).

## 2. Mixing rules

- **Fader position to gain:** the fader runs 0…1. At 0 the gain is −∞ (silent). Above 0, the gain in dB maps linearly from −60 dB to +6 dB, with 0 dB at about 0.91. The value shown is rounded to whole dB.
- **Effective gain of a track:**
  - 0 if the track is muted;
  - otherwise 0 if any track is soloed and this one isn't;
  - otherwise its fader gain.
  - So a muted track stays silent even when soloed.
- **Master:** the main mixer's output volume = master gain (the engine allows gain above 1).
- **Live updates:** every fader, mute or solo change sets the corresponding mixer node's volume at once, without
  interrupting playback.

## 3. Remembering each song's mix

- Per song id, the app saves in its preferences (`UserDefaults`, key `playerMix.<id>`, JSON):
  - the 8 fader positions, the 8 mutes, the 8 solos and the master position;
  - the tempo (target BPM) and the pitch (semitones);
  - the loop's start and end. The loop always reopens switched **off**.
- A song never opened before starts with the show's defaults:
  - the parts listed in `retirer` (guitar → Guitare, bass → Basse, piano → Piano, drums → Batterie, other → Accompagnement) at 0;
  - every other track and the master at 0 dB;
  - no mute or solo, original tempo, pitch 0, no loop.
- The mix is saved on every change, so nothing is lost if the app quits.

## 4. Behaviour and errors

- **Loading:** the composition is built from the song folder's files. If a file can't be read, or the item fails, the player area shows the error and the song stays selected so Michel can retry.
- **End of song:** playback stops at the end (unless looping), and the next ▶︎ starts again from the beginning.
- **Seeking and looping:** every player node is stopped and rescheduled from the target frame, so all tracks stay
  sample-aligned. The video is then re-anchored to the same song time.
- **Leaving the tab** pauses playback.
- **Running alongside the rest:** playback may run during an analysis. The recorder only captures Spotify, so the player is never recorded.
- **Data source:** the list comes from the same `etat --json` state as the Karaoké tab (`KaraokeModel.songs`). It
  refreshes when the tab appears and after each analysis.
- **Pipeline change:** `etat --json` gains each song's **`bpm`**, its typical (median) tempo (from the package step's result; null when not yet
  analysed). A song without a BPM shows the tempo control disabled at 100 %.

## 5. Units

- `KaraifyerCore/PlayerMix.swift` (pure, tested):
  - the track list and the `retirer` mapping;
  - fader ↔ dB ↔ gain;
  - effective gains with mute and solo;
  - default mix from `retirer`;
  - mix encode and decode for persistence;
  - the readiness check (which files are missing);
  - search matching;
  - tempo: BPM ↔ rate and clamping; pitch: semitones ↔ cents and clamping;
  - loop: bar snapping, start/end ordering, the position after a loop wrap;
  - export: default file names, the exported duration for a given tempo (song length / rate), and the ffmpeg
    arguments built for each format and quality (`ExportOptions` → arguments).
- `Karaifyer/PlayerEngine.swift`: the `AVAudioEngine` graph, scheduling from a frame (play, seek, loop), the
  current song-time position, rate and pitch.
- `Karaifyer/PlayerModel.swift`:
  - the silent video `AVPlayer` and its re-anchoring to the engine;
  - play/pause/restart/seek, loop handling, tempo and pitch;
  - loading and saving each song's settings.
- `Karaifyer/PlayerExport.swift`: offline rendering to a temporary WAV, the ffmpeg encode for each format,
  progress and cancellation.
- `Karaifyer/PlayerView.swift`: the tab, the song list with search, `VideoView` (an `AVPlayerView` wrapper with double-click full screen), transport, and mixer columns.
- `KaraifyerApp.swift`: the third tab, « Lecteur ».

## 6. Testing

- **Unit tests (Swift Testing)** cover:
  - fader ↔ dB round-trips and the −∞ and +6 dB ends;
  - effective gains for mute, solo, mute + solo, and several solos;
  - master above 0 dB folding into the track gains;
  - the default mix from `retirer`;
  - BPM ↔ rate, both ends of the range, and a song without a BPM;
  - pitch clamping; loop snapping to the nearest bar line, swapped start/end, and no bars;
  - export file names (accents, « / » in titles) and the duration at a given tempo;
  - the ffmpeg arguments for every format/quality combination, and the remembered choices round-trip;
  - persistence round-trip, and a missing or corrupt entry falling back to the defaults;
  - readiness listing the exact missing files;
  - search being accent- and case-insensitive.
- **Manual checks (Michel)**, added to `docs/karaoke/karaifyer-validation.md`:
  - the video and the voice stay in sync for a whole song;
  - solo, mute and fader are heard immediately;
  - the mix is restored after reopening the song and after restarting the app;
  - double-click enters and leaves full screen, and Escape leaves it;
  - Space plays and pauses, but types a space in the search field;
  - a single click only selects; double-click, « Charger » or Return loads; the loaded song shows ▶︎;
  - ⏮ goes back to the start;
  - dragging the position bar jumps video and audio together;
  - a bar-snapped loop repeats with no gap, and « Boucle » / « Effacer » work;
  - changing the BPM changes the speed without changing the pitch, and video and click stay in sync with the audio;
  - transposing changes the pitch without changing the tempo, and the reminder appears;
  - export « Master seul » in each format (AAC, MP3, WAV, FLAC) gives a file that sounds like the player's mix
    (including a muted part, a changed tempo and a transposition), at the chosen quality;
  - export « Vidéo + master » gives an `.mp4` at the chosen resolution whose lyrics stay in sync at a changed
    tempo; « Annuler » leaves no file; the sheet reopens with the last choices;
  - output follows the system's selected device.
