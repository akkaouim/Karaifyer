# How SysRec works

> This document describes the recorder as built in SysRec (now deprecated). Karaifyer's
> « Enregistrement » tab is the same code plus capture-fault detection; see `karaifyer/README.md`.

This document is for whoever changes the code later. It describes the
design, the findings behind each decision (most came from testing on the
target Mac, 2026-10-12), and the diagnostic tools. For using the app, see the
[README](../README.md).

## Where the recording happens

```
Spotify: download + cache, then decode to PCM 44.1 kHz, apply app volume
   │
   ▼   Core Audio (coreaudiod)
   ├─ rate conversion to the device rate if it differs (44.1 → 48 kHz on the XR18)
   ├─ channel mapping (onto channels 17+18 of the XR18)
   ◄── process tap: copies Spotify's stream only
   ├─ mix with other apps
   ▼
USB → interface → analog → speakers      (nothing past the tap affects the file)
```

A Core Audio **process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+)
captures one app's output before it is mixed with other apps. That is the
earliest point available without injecting code into Spotify or using an
unofficial client that decrypts the streams; we rule both out. Mixer faders,
speaker volume and the macOS volume don't affect the file. Spotify's own
settings (quality, normalization, crossfade, app volume) do.

## Code map

| File | Role |
|---|---|
| `Sources/SysRecCore/CSV.swift` | RFC 4180 CSV reader (quoted commas in the sheet). |
| `Sources/SysRecCore/TrackList.swift` | Finds the header row, maps columns by name, extracts track IDs, marks duplicates; file naming rules. |
| `Sources/SysRecCore/TrimMath.swift` | Start detection, duration-based trim range, `DropoutScanner` (glitch detection). Pure and unit-tested. |
| `Sources/SysRec/SystemAudioTap.swift` | Tap + private aggregate device + IOProc; writes each track to a temporary Float32 CAF. |
| `Sources/SysRec/SpotifyController.swift` | Spotify through AppleScript: play, pause (verified), seek, volume, poll, restart. |
| `Sources/SysRec/QueueModel.swift` | Batch state machine, retries, logging, silent mode, sleep prevention. |
| `Sources/SysRec/PostProcess.swift` | Glitch scan, trim and encode FLAC with ffmpeg, tags and cover art, MP3, duplicate copies. |
| `Sources/SysRec/AudioCapturePermission.swift` | Checks and requests the System Audio Recording permission (private TCC calls; there's no public API). |
| `Sources/SysRec/SysRecApp.swift` | Menu bar, queue window, launch flags, diagnostics. |

## One row, step by step

1. **Pre-buffer.** Set Spotify's volume to 0, `play track`, and wait until
   the track has played smoothly for 1.5 s. Then pause, seek to 0 and set the
   volume back to 100. Uncached tracks often stalled in their first second
   (repeated audio or ~200 ms of zeros); playing from cache avoids it. In
   testing this also stopped Spotify from ignoring the next `play track`.
2. **Arm.** Start a new segment file, then `play` (resume). The capture
   begins before the audio does.
3. **Confirm start.** Poll until the expected track is playing at under 2 s.
   A different ID with a matching title is accepted (Spotify relinks tracks
   to other releases per market). If Spotify plays something else, re-issue
   play, and eventually restart Spotify.
4. **Monitor** at 150 ms, then 25 ms during the last 2.5 s. The track has
   ended when, near its end, the track ID changes, playback stops, or there
   is no current track (−1728). A backwards jump in position means Spotify
   restarted the track, so the take is redone. A pause by hand mid-track stops
   the batch and puts the row back to pending, because the take now has a
   gap.
5. **Let the tail play out** (0.7 s if Spotify advanced, 1.5 s if it stopped),
   then pause and drain for 300 ms. Spotify reports the end once it has
   finished *decoding*; pausing at once cut about 150 ms off songs that end
   abruptly.
6. **Finalize.** The start is the **first non-zero sample**: while Spotify
   is paused the tap delivers exact zeros. An earlier −70 dBFS threshold cut
   quiet intros. The length is **exactly Spotify's reported duration**, which
   removes any bleed from the next track. Then the glitch scan, FLAC encode
   (24-bit, compression 8) with tags and cover art, and the optional MP3.

### Retries

| Cause | What happens |
|---|---|
| Glitch (dropout) | Redo, up to 2 times; the last take is kept with a warning. |
| Same gap at the same place in two takes | Accepted as silence in the master (±10 ms position, ±5 ms or 10% length). |
| Take shorter than the duration, or timestamp gaps | Redo once. |
| Spotify ignores or reverts `play track` | Restart Spotify, rebuild the tap, redo. |
| Ad | Redo. |
| Permission, timeout, or AppleScript error | Stop the batch (every row would fail the same way). |

Each row is attempted at most 6 times in total.

## Glitch detection

A **dropout** is a run of exact digital zeros on all channels, between
1.3 ms and 500 ms long, with audio before it and loud audio (above −60 dBFS)
returning within 500 ms. Real music essentially never contains this; stalls
and missed IO cycles do. Seen in testing: 512-frame (10.7 ms), 930-frame
and 14 ms gaps. A resume that starts with a few very quiet samples still
counts, which was needed to catch the start-of-track stall. Run the scanner
on any file with `--scan-glitches` (see Diagnostics).

Mid-track dropouts happened about once per 3–4 minutes of audio, on both the
XR18 and BlackHole, so the USB interface is not the cause. The 4096-frame IO
buffer didn't eliminate them. The source (Spotify or the tap) is still
unknown. The retries keep them out of the files at the cost of time.

## Core Audio lessons (all measured)

- **A stereo mixdown on a multichannel device scales the level down.** On
  the 18-channel XR18 a `stereoMixdownOfProcesses` tap cost −19 dB (1/9).
  For devices with more than 2 channels we tap the device stream unmixed
  (`CATapDescription(processes:deviceUID:stream:)`) and keep the
  `kAudioDevicePropertyPreferredChannelsForStereo` pair (17+18 on the XR18).
- **The aggregate's input list starts with the device's own inputs.** The tap
  is the *last* buffer (interleaved) or the last N buffers (planar).
- **Copy samples on the IO thread.** An IOProc created with a dispatch queue
  ran after Core Audio had reused the buffers, which dropped or duplicated
  512-frame chunks. Two takes of the same track then matched at only
  0.85–0.9 correlation; after the fix, 1.000. The IOProc now uses a `nil`
  queue and copies the stereo pair; file writes happen on a serial queue.
- **`kAudioTapPropertyFormat` always reports 48 kHz**, even for `afplay` on a
  96 kHz device. Use the aggregate's `kAudioDevicePropertyNominalSampleRate`
  instead. Trusting the tap labelled 44.1 kHz captures as 48 kHz (9% fast).
- **Drift compensation is off**: the tap and its main device share a clock.
- **Notifications that the default output changed arrive asynchronously.**
  The listener compares against the device the tap was built on, so SysRec's
  own switch in silent mode doesn't stop the batch.
- **More than 2 channels needs an explicit layout**
  (`kAudioChannelLayoutTag_DiscreteInOrder | N`), or `AVAudioFormat` returns
  nil.

## Spotify (desktop 1.3.x) quirks

- After a track ends and autoplay starts, the next `play track` may be
  ignored, or applied and then reverted about a second later to where the old
  track would have been. A restart clears it; pre-buffering mostly avoids it.
- After days of uptime, the player stops answering AppleScript (−1712) while
  `get version` still works. SysRec wraps every script in a 10 s timeout and
  probes `player state` at startup.
- `st` is a reserved word in AppleScript (as in "1st"); naming a variable
  `st` breaks compilation.
- A single `pause` is sometimes ignored. `pause()` repeats until the player
  reports it isn't playing.
- The catalogue is 44.1 kHz (CD standard; Lossless is 24-bit/44.1 kHz).
  48 kHz holds no more audible information; converting just adds a step.

## Silent mode (BlackHole)

Off by default. It switches the system output to BlackHole at 44.1 kHz for
the batch, so there's no rate conversion, and restores the previous output
(and rate) when the batch ends or the app quits. All Mac audio is muted
meanwhile. Changing the output by hand stops the batch.

## Diagnostics

```sh
APP=SysRec.app/Contents/MacOS/SysRec
$APP --scan-glitches file1.flac file2.flac   # dropout positions and lengths
open -n SysRec.app --args --probe-tap com.spotify.client /tmp/probe.txt   # tap format for a bundle prefix or pid
open -n SysRec.app --args --list l.csv --output /tmp/out [--silent] --start --quit-when-done
```

`--output` and `--silent` apply to that launch only; they don't change the
saved settings. **Test with tracks Spotify hasn't cached**: cached tracks
hide the start-of-track stalls.

Comparing two takes of the same track is the strongest test. After aligning
them with cross-correlation they should match at 1.000 correlation in every
1-second window; jumps in the alignment show dropped or repeated audio. The
tests run on 2026-10-12 used numpy for this.

## Signing and permissions

macOS ties the System Audio Recording and Automation permissions to the code
signature. An ad-hoc signature changes on every build, so the prompt comes
back after each rebuild (and an unattended run waits on it). `build-app.sh`
signs with a self-signed "SysRec Local Signing" certificate when one is in
the login keychain. To create it on a new Mac:

```sh
cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = SysRec Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "SysRec Local Signing" -out cert.p12 -passout pass:tmp
security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
rm key.pem cert.p12   # the private key now lives only in the keychain
```

It doesn't need to be trusted: `codesign` accepts it, and the designated
requirement (identifier + certificate hash) stays the same across builds.

## Toolchain notes (Command Line Tools, no Xcode)

- SwiftUI's `@State` is a macro in this SDK, and its plugin ships only with
  Xcode. The model is a shared `@Observable` singleton instead.
- Swift Testing needs
  `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.

## Known limitations

- Mid-track dropouts still happen (cause unknown); retries absorb them.
- On a free Spotify account, ads cause retries.
- The batch plays in real time, about 5–6 hours for 85 tracks.
- Recording Spotify streams is against Spotify's terms of use. This
  repository is private and the tool is for personal use.
