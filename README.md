# SysRec

Menu-bar app that records a list of Spotify tracks, one lossless file per row.
For each row it arms a Core Audio process tap on Spotify only (system sounds
and other apps are excluded), plays the track through Spotify's AppleScript
interface, stops when the track ends, and writes a trimmed, tagged FLAC (plus
an optional 320 kbps MP3).

For the design, the measurements behind it and the diagnostic tools, see
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Build & run

Requires macOS 26, the Xcode Command Line Tools, and `brew install ffmpeg`.

```sh
./build-app.sh            # → ./SysRec.app
./build-app.sh --install  # also copies to ~/Applications
open SysRec.app
```

On first use, macOS asks for two permissions. Allow both:
- **Automation → Spotify**, so SysRec can play tracks and read the position.
- **System Audio Recording**, under Privacy & Security → Screen & System Audio
  Recording. If you denied it, the batch stops with "No audio captured".

`build-app.sh` signs with the self-signed "SysRec Local Signing" certificate
from your login keychain, so permissions survive rebuilds. If the certificate
is missing, it falls back to an ad-hoc signature and macOS asks again after
every rebuild. To create the certificate on a new Mac, see
[Signing and permissions](docs/HOW-IT-WORKS.md#signing-and-permissions).

## Spotify settings for best fidelity

- Audio quality: **Lossless** (or Very high)
- **Normalize volume: off**
- **Crossfade: off**. Overlapping tracks can't be split cleanly.
- Use a Premium account. On a free account, ads trigger retries.

SysRec turns off shuffle and repeat and sets Spotify's app volume to 100 when
a batch starts. By default it also switches the output device to 44.1 kHz
(Spotify's native rate) for the batch and restores the previous rate when it
finishes.

## Input list

A CSV export of the sheet. Columns are found by their header text, so they can be in any order:
`Lien Spotify` (any header containing "spotify"), `Titre`, `Artiste`,
`proposé par`, plus the unlabeled number column. Rows without a track link are
ignored. A plain text file with one Spotify link per line also works.

Output goes to `~/Music/SysRec/<list name>/NN - Titre - Artiste.flac`, with
title, artist, album and cover art taken from Spotify. `sysrec-log.txt` in the
same folder records each row's sample rate, lead-in trim and peak level.
The batch resumes where it stopped, because rows whose file already exists are
skipped. When the same track appears twice, it is recorded once and copied.

## Reading the log

`sysrec-log.txt` has one line per event:

- `… 0 gaps`: the row's file is done and clean.
- `Playback glitch at …s (N ms gap) — retrying`: a dropout was caught and the
  row is being recorded again.
- `… is in the track itself (identical in two takes)`: a real silence in the
  song; the file is kept.
- `WARNING: …` on a finished row, or `✗` in the Status column: worth a look.

## How a row is cut

Before each take, SysRec plays the first 1.5 s of the track at volume 0, then
rewinds and records from the cache. Uncached tracks often stall in their
first second, and playing the track this way also avoids Spotify ignoring the
next `play track`.

The recording starts before playback. While Spotify is paused, the tap
delivers exact digital zeros, so the file starts at the first non-zero sample,
and quiet fade-ins are kept. The length is exactly Spotify's reported
duration, so anything after the end (the next track starting before SysRec
pauses it) is cut off. If you pause Spotify mid-track, the take has a gap: the
batch stops and that row is redone on the next Start.

## Things SysRec handles for you

These all came up while testing on this Mac:

- **Multichannel interfaces.** A tap's stereo *mixdown* folds every device
  channel into two, which cost 19 dB on the 18-channel Behringer. On devices
  with more than 2 channels, SysRec taps the device stream unmixed and keeps
  the device's stereo pair (Audio MIDI Setup → Configure Speakers), so the
  file holds exactly the samples Spotify sent.
- **Spotify ignoring `play track`.** After a track ends and autoplay takes
  over, Spotify sometimes ignores the next play command or reverts to the
  previous track a second later. SysRec notices, restarts Spotify (about 5 s),
  rebuilds the tap and retries the row.
- **A stuck Spotify.** If Spotify has been open for days, its player may stop
  answering scripted commands. SysRec times out after 10 s and tells you to
  restart Spotify.
- **Short takes.** If a file comes out shorter than Spotify's reported
  duration, SysRec records that row once more. SysRec lets each track's tail
  play out before pausing, because Spotify reports the end before its last
  buffered audio has played.
- **Dropouts vs. real silence.** A short run of exact digital zeros inside
  the music means a glitch, and the take is redone. If the same gap shows up
  at the same spot in two takes, it's silence in the master and the take is
  kept.

## Silent recording (optional, off by default)

"Silent recording via BlackHole" switches the Mac's output to BlackHole at
44.1 kHz for the batch, so files are Spotify's 44.1 kHz stream with no
sample-rate conversion. Everything on the Mac goes silent meanwhile, calls
included, and the previous output comes back when the batch ends. Don't
change the output by hand during a batch. The tap always *reports* 48 kHz;
SysRec uses the device's real rate.

## Unattended runs

```sh
open -n SysRec.app --args --list list.csv --output /tmp/out --start --quit-when-done [--silent]
```

`--output` and `--silent` apply to that launch only and don't change your
saved settings.

## Tests

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```
(The extra flag is needed because the Command Line Tools don't put the Swift Testing macro plugin on the default path.)
