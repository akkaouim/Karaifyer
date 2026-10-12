# Ableton set and XR18 routing: decisions (2026-10-12)

Input for the Ableton plan. Agreed with Michel; they amend the « Intégration Ableton » section of the spec (`cahier-des-charges.md`).

## Software

- Ableton Live **12.4.6**, edition assumed **Suite** (to be confirmed by Michel). Suite includes Max for Live and its « CC Control » device, needed to move XR18 faders over MIDI.

## XR18 addressing plan (from Michel)

| XR18 channel | Source | Origin |
|---|---|---|
| 01 | Mic 1 | live |
| 02 | Mic 2 | live |
| 03 | Mic 3 | live |
| 04 | Acoustic guitar (Pierre or Michel) | live |
| 05–06 | Keyboard, stereo (Michel) | live |
| 07 | Electric guitar (Pierre) | live |
| 08 | Cajon (Pierre) | live |
| 09 | *(free; was the accompaniment)* | |
| 10 | Click | Ableton (USB) |
| 11 | Guide vocal = **lead vocals** only (in-ears) | Ableton (USB) |
| 12 | Guitar stem, mono | Ableton (USB) |
| 13 | Bass stem, mono | Ableton (USB) |
| 14 | Piano stem, mono | Ableton (USB) |
| 15 | Drums stem, **mono** (changed 2026-10-13) | Ableton (USB) |
| 16 | **Backing vocals** (« Chœurs »), mono (changed 2026-10-13) | Ableton (USB) |
| 17–18 | **Accompaniment, stereo** (aux pair; was « reserved ») | Ableton (USB) |

The click (10) and guide vocal (11) go to the musicians' monitor sends only, never to the front of house (spec).

## Changes of 2026-10-13

- **Drums are mono**, on channel 15 only. The separated drums are nearly mono anyway (Danser L/R correlation 0.99), and this frees channel 16.
- **Vocals are split into lead and backing** by a second model (karaoke Mel-Band RoFormer) applied to the Demucs vocal stem:
  - the lead goes to the guide vocal (11, in-ears only);
  - the backing vocals go to channel 16, « Chœurs », at normal level in the room.
- **Template edits by Michel:** Batterie output → 15 (mono); new audio track « Chœurs » → output 16 (mono). On the XR18, channels 15 and 16 are unlinked, mono, source USB.

## Parts: extracted, not removed

- Guitar, bass, piano and drums **always** play on their own XR18 channels (12–15), and the backing vocals on 16.
- The **accompaniment** (17–18) is what's left: the `other` stem (strings, brass, synths…), without vocals.
- The manifest's `retirer` column no longer removes anything. It lists the parts Michel and Pierre play live on that song, and those **start at zero** (fader down). The other parts start at their normal level. Michel decides during the show whether to bring a live part up.
- Ableton faders drive the XR18 channel faders over MIDI (XR18 « USB Rx » MIDI enabled in X Air: Setup → Mixer → MIDI Config). Faders are sent to their per-song defaults when a song starts, so the console's EQ, effects and monitor sends follow the fader.

## Pipeline consequences (to implement in the Ableton plan)

- `package`: the accompaniment becomes vocals- and part-free (`other` only). The routed parts come from the configuration (guitar, bass, piano, drums), not from `retirer`.
- `rapport.json` / set generation: per-song default fader levels: 0 for `retirer` parts, nominal for the others.
- Mono channels 12–14: Ableton sums the stereo stems to the mono output, or the pipeline writes mono files. Decide in the plan.
