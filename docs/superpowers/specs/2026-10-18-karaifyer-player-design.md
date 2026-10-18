# Karaifyer Player tab (design)

Agreed with Michel on 2026-10-18. It is a third tab in Karaifyer, after Karaoké.

## Purpose

The tab is used both for **rehearsing at home** and for **checking the analysis**:
- Rehearsing: play along with his live parts muted, and follow the lyrics and chords video, without Ableton or the XR18.
- Checking: solo each separated track to judge the separation, the click and the guide vocal before the show.

**Success:** Michel picks any analysed song, sees the lyrics video and hears the mix. He adjusts each track live and finds his mix again the next time he opens that song. Nothing goes to the XR18; the overall mix plays on the Mac's current audio output.

## Decisions

| Topic | Decision |
|---|---|
| Playback engine | **One `AVPlayer`** on an `AVMutableComposition` (the song's video track + its 8 audio tracks). Per-track levels come from an `AVMutableAudioMix` updated live. One clock, so video and audio are in sync by construction. |
| Output | The system's current audio output (`AVPlayer` default). No XR18 routing, no device selection. |
| Initial levels | First time: **like the show**: parts in `retirer` at zero, everything else at 0 dB (click and guide vocal included). Afterwards: **the last mix Michel left for that song**. |
| Out of scope | Waveforms, position scrubbing, looping, tempo or pitch change, exporting a mix. |

## 1. Layout

**Left column (narrow)**
- A search field. It filters on title, artist or id, case-insensitively and ignoring accents (« ble » matches « blés »).
- The list of songs: `id · Titre — Artiste`, in manifest order.
  - **Ready** songs are selectable: their `paroles.mp4` and all 8 `.flac` files exist in the song folder.
  - Songs that are not ready are greyed out and not selectable; hovering one says what is missing.
- Clicking a ready song loads it into the player. This replaces any song already loaded and stops playback.

**Top right: the video**
- `paroles.mp4`, as large as the area allows, in an `AVPlayerView` with no built-in controls.
- **Double-click** toggles full screen. **Escape** also leaves full screen.
- With no song loaded, the area says « Choisir un morceau dans la liste ».

**Bottom right: transport and mixer (smaller than the video)**
- **Transport:**
  - ⏮ goes back to the start (seek to 0, keeping the play/pause state);
  - ▶︎/⏸ plays or pauses;
  - the time shows as `m:ss / m:ss`, from the song's start to its total length.
- **Mixer**, 9 columns:
  - Track columns, in this order: Clic, Guide voix, Guitare, Basse, Piano, Batterie, Accompagnement, Back Vocals.
  - Each track column has a vertical gain fader from −∞ to +6 dB, with the value shown (« −∞ », « −12 dB », « 0 dB », « +3 dB »).
  - Each track column has an **M** (mute) and an **S** (solo) toggle, lit when active.
  - **Master** has a fader only (same range); it drives the player's overall volume.

**Keyboard:** **Space** plays or pauses everything, except while the search field is being edited (there it types a space).

## 2. Mixing rules

- **Fader position to gain:** the fader runs 0…1. At 0 the gain is −∞ (silent). Above 0, the gain in dB maps linearly from −60 dB to +6 dB, with 0 dB at about 0.91. The value shown is rounded to whole dB.
- **Effective gain of a track:**
  - 0 if the track is muted;
  - otherwise 0 if any track is soloed and this one isn't;
  - otherwise its fader gain.
  - So a muted track stays silent even when soloed.
- **Master:** player volume = master gain. AVPlayer's volume is capped at 1.0, so above 0 dB the extra gain is applied to every track gain instead.
- **Live updates:** every fader, mute or solo change rebuilds the audio mix and assigns it to the current item. Changes are heard almost immediately and never interrupt playback.

## 3. Remembering each song's mix

- Per song id, the app saves the 8 fader positions, the 8 mutes, the 8 solos and the master position in the app's preferences (`UserDefaults`, key `playerMix.<id>`, JSON).
- A song never opened before starts with the show's defaults:
  - the parts listed in `retirer` (guitar → Guitare, bass → Basse, piano → Piano, drums → Batterie, other → Accompagnement) at 0;
  - every other track and the master at 0 dB;
  - no mute or solo.
- The mix is saved on every change, so nothing is lost if the app quits.

## 4. Behaviour and errors

- **Loading:** the composition is built from the song folder's files. If a file can't be read, or the item fails, the player area shows the error and the song stays selected so Michel can retry.
- **End of song:** playback stops at the end, and the next ▶︎ starts again from the beginning.
- **Leaving the tab** pauses playback.
- **Running alongside the rest:** playback may run during an analysis. The recorder only captures Spotify, so the player is never recorded.
- **Data source:** the list comes from the same `etat --json` state as the Karaoké tab (`KaraokeModel.songs`). It refreshes when the tab appears and after each analysis.

## 5. Units

- `KaraifyerCore/PlayerMix.swift` (pure, tested):
  - the track list and the `retirer` mapping;
  - fader ↔ dB ↔ gain;
  - effective gains with mute and solo;
  - default mix from `retirer`;
  - mix encode and decode for persistence;
  - the readiness check (which files are missing);
  - search matching.
- `Karaifyer/PlayerModel.swift`:
  - `AVPlayer`, composition building, audio-mix updates;
  - play/pause/restart and time observation;
  - loading and saving mixes.
- `Karaifyer/PlayerView.swift`: the tab, the song list with search, `VideoView` (an `AVPlayerView` wrapper with double-click full screen), transport, and mixer columns.
- `KaraifyerApp.swift`: the third tab, « Lecteur ».

## 6. Testing

- **Unit tests (Swift Testing)** cover:
  - fader ↔ dB round-trips and the −∞ and +6 dB ends;
  - effective gains for mute, solo, mute + solo, and several solos;
  - master above 0 dB folding into the track gains;
  - the default mix from `retirer`;
  - persistence round-trip, and a missing or corrupt entry falling back to the defaults;
  - readiness listing the exact missing files;
  - search being accent- and case-insensitive.
- **Manual checks (Michel)**, added to `docs/karaoke/karaifyer-validation.md`:
  - the video and the voice stay in sync for a whole song;
  - solo, mute and fader are heard immediately;
  - the mix is restored after reopening the song and after restarting the app;
  - double-click enters and leaves full screen, and Escape leaves it;
  - Space plays and pauses, but types a space in the search field;
  - ⏮ goes back to the start;
  - output follows the system's selected device.
