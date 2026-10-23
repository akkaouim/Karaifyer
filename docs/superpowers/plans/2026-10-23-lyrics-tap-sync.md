# Lyrics Tap Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the Corriger window, Michel plays the song (with the show's count-in) and presses Return at the start of each line. Each press is snapped to the start of the voice and becomes that line's time, saved as his lyrics correction.

**Architecture:**
- **KaraifyerCore** gets three pure pieces, all tested:
  - `VocalOnset`: an RMS envelope of `guide_voix.flac` and the onset search around a press;
  - `LyricsSync`: the stamp, cancel and start-from-a-line state machine;
  - `LyricsText.replace`: the replace-the-whole-text merge that keeps times.
- **The app.** `EditorModel` gains a sync mode that drives the editor's existing `AVAudioPlayer` (recording, volume,
  click overlay), plus a count-in player built from the first `pad_s` seconds of `sortie/<dossier>/clic.flac`. Both
  start on one device time. A key monitor handles Return / ↑ / ⌫ / Space / Escape in that window.
- **The view** shows the active line large, and adds a « Remplacer le texte… » sheet.

**Tech Stack:**
- Swift 6 / SwiftPM, Command Line Tools only.
- Swift Testing: `swift test --package-path karaifyer -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
- AVFoundation.
- SwiftUI without `@State`.

**Spec:** `docs/superpowers/specs/2026-10-23-lyrics-tap-sync-design.md`

## Global Constraints

- **Snap window:** 0.4 s before to 0.1 s after the press.
- **Onset:** RMS envelope at a 10 ms hop. Rise ≥ 12 dB above the noise floor (the 20th percentile of the 0.3 s
  before the window), held for 5 frames (50 ms). nil means the raw press is kept.
- **Time base:** show time = input time + `pad_s`. The recording plays from show time `pad_s`; the count-in fills 0 to
  `pad_s`. A stamp is the show time of the press, measured on the recording player's device clock.
- **Starting from a line:** 2 s before the previous line's time, with no count-in.
- **Keys in sync mode:**
  - Return → stamp;
  - ↑ (keyCode 126) or ⌫ (51) → cancel the last stamp;
  - Space → pause/resume;
  - Escape (53) → leave.
- **Editing:** every stamp is one undoable edit (`edit { doc.stamp(...) }`).
- **The click and voice files** are 44.1 kHz mono FLAC.
- **UI copy:**
  - « Synchroniser », « Synchroniser à partir de la ligne sélectionnée »;
  - « Remplacer le texte… », « Valider »;
  - « Analyser le morceau d'abord »;
  - « N lignes synchronisées »;
  - « Entrée : caler la ligne · ↑ : annuler · Espace : pause · Échap : quitter ».
- **Unchanged:** SysRec is never touched.

## Review Focus

1. **A press during the count-in** (before the recording starts): its show time is the count-in time, between 0 and
   `pad_s`. It must not be read as negative or as the recording's time 0. Covered by `showTimeDuringCountIn`
   (Task 2).
2. **Pressing Return more times than there are lines:** nothing happens, no crash, playback continues. Covered by
   `stampPastTheLastLineDoesNothing` (Task 2).
3. **A noisy or empty voice track around a press** (instrumental bridge, breath noise): `VocalOnset` returns nil and
   the raw press is kept, rather than snapping to noise. Covered by `noOnsetInSilenceOrSteadyVoice` (Task 1).
4. **Replacing the text with fewer or reordered lines:** the times of unchanged lines survive, and the new lines get
   increasing times. Covered by `replaceKeepsTimesOfUnchangedLines` (Task 2).
5. **Leaving sync mode** (Escape, the end of the song, the window closing) stops both players and removes the key
   monitor. Covered by the view's lifecycle and the manual checklist row.

---

### Task 1: `VocalOnset` (envelope + onset search)

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/VocalOnset.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/VocalOnsetTests.swift`

**Interfaces:**
- Produces:
  - `VocalOnset.envelope(samples: [Float], sampleRate: Double, hop: Double = 0.01) -> [Float]` (dB per hop);
  - `VocalOnset.find(envelope: [Float], hop: Double = 0.01, near t: Double, before: Double = 0.4, after: Double = 0.1) -> Double?`;
  - `VocalOnset.load(url: URL) throws -> [Float]` (envelope of a file).

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import KaraifyerCore

struct VocalOnsetTests {
    /// 44.1 kHz: silence (very low noise) then a 440 Hz tone starting at `start`.
    func signal(start: Double, total: Double = 3) -> [Float] {
        (0..<Int(total * 44100)).map { i in
            let t = Double(i) / 44100
            return t < start ? Float.random(in: -0.0005...0.0005) : Float(0.3 * sin(2 * .pi * 440 * t))
        }
    }

    @Test func onsetFoundBeforeALatePress() {
        let env = VocalOnset.envelope(samples: signal(start: 1.20), sampleRate: 44100)
        let t = VocalOnset.find(envelope: env, near: 1.42)!            // pressed 0.22 s late
        #expect(abs(t - 1.20) < 0.02)
    }

    @Test func noOnsetInSilenceOrSteadyVoice() {
        let silent = VocalOnset.envelope(samples: [Float](repeating: 0, count: 3 * 44100), sampleRate: 44100)
        #expect(VocalOnset.find(envelope: silent, near: 1.5) == nil)
        let steady = VocalOnset.envelope(samples: signal(start: 0.0), sampleRate: 44100)
        #expect(VocalOnset.find(envelope: steady, near: 1.5) == nil)    // already singing: no rise in the window
    }

    @Test func windowBoundsAreRespected() {
        let env = VocalOnset.envelope(samples: signal(start: 1.0), sampleRate: 44100)
        #expect(VocalOnset.find(envelope: env, near: 1.6) == nil)       // onset 0.6 s before: outside the window
        #expect(VocalOnset.find(envelope: env, near: 0.95) != nil)      // onset 0.05 s after: inside
    }
}
```

- [ ] **Step 2: Run to verify they fail** (`--filter VocalOnset`). Expected: `cannot find 'VocalOnset'`.

- [ ] **Step 3: Implement**

```swift
import AVFoundation
import Foundation

/// Where the voice starts near a key press: Michel taps each lyric line a little late; the tap is moved onto the
/// first sung sound in `guide_voix.flac` (rise ≥ 12 dB over the noise floor, held 50 ms) within −0.4 / +0.1 s.
public enum VocalOnset {
    public static func envelope(samples: [Float], sampleRate: Double, hop: Double = 0.01) -> [Float] {
        let n = max(1, Int(sampleRate * hop))
        return stride(from: 0, to: samples.count, by: n).map { i in
            let s = samples[i..<min(i + n, samples.count)]
            let rms = sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(max(s.count, 1)))
            return 20 * log10(max(rms, 1e-6))
        }
    }

    public static func find(envelope e: [Float], hop: Double = 0.01, near t: Double,
                            before: Double = 0.4, after: Double = 0.1) -> Double? {
        let a = max(0, Int((t - before) / hop)), b = min(e.count, Int((t + after) / hop) + 1)
        guard a < b else { return nil }
        let pre = e[max(0, a - 30)..<max(a, 1)].sorted()
        let floor = pre.isEmpty ? e[a] : pre[min(pre.count - 1, pre.count / 5)]
        let hold = 5
        var i = a
        while i < b {
            if e[i] >= floor + 12, i + hold <= e.count, e[i..<(i + hold)].allSatisfy({ $0 >= floor + 12 }) {
                return Double(i) * hop
            }
            i += 1
        }
        return nil
    }

    public static func load(url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: f.processingFormat.sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let ch = buf.floatChannelData![0]
        _ = fmt
        return envelope(samples: Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))),
                        sampleRate: f.processingFormat.sampleRate)
    }
}
```

`steady`: the floor is measured just before the window, while already singing, so no 12 dB rise occurs and the result
is nil. `windowBoundsAreRespected` checks that a rise outside [t−0.4, t+0.1] is ignored.

- [ ] **Step 4: Run the whole Swift suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/VocalOnset.swift karaifyer/Tests/KaraifyerCoreTests/VocalOnsetTests.swift
git commit -m "karaifyer: vocal onset search for lyric tap sync"
```

---

### Task 2: `LyricsSync` state machine and `LyricsText.replace`

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/LyricsSync.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/LyricsSyncTests.swift`

**Interfaces:**
- Produces:
  - `LyricsSync` (struct): `init(count: Int, startAt: Int = 0)`; `active: Int?`;
    `mutating stamp(oldTime: Double) -> Int?` (returns the line index stamped and records the old time for cancel);
    `mutating cancel() -> (index: Int, time: Double)?`; `progress: (done: Int, total: Int)`.
  - `LyricsSync.showTime(countInPlaying: Bool, countInTime: Double, recordingTime: Double, pad: Double) -> Double`.
  - `LyricsSync.startTime(from line: Int, times: [Double]) -> Double`: show time to start playback, 2 s before the
    previous line, 0 for line 0.
  - `LyricsText.replace(old: [(time: Double, text: String)], with text: String) -> (lines: [(time: Double, text: String)], firstChanged: Int?)`.

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import KaraifyerCore

struct LyricsSyncTests {
    @Test func stampMovesOnAndCancelRestores() {
        var s = LyricsSync(count: 3)
        #expect(s.active == 0 && s.stamp(oldTime: 5) == 0 && s.active == 1)
        #expect(s.stamp(oldTime: 9) == 1 && s.progress == (2, 3))
        #expect(s.cancel()! == (1, 9) && s.active == 1)
        #expect(s.cancel()! == (0, 5) && s.active == 0 && s.cancel() == nil)
    }

    @Test func stampPastTheLastLineDoesNothing() {
        var s = LyricsSync(count: 1)
        #expect(s.stamp(oldTime: 1) == 0 && s.active == nil && s.stamp(oldTime: 2) == nil)
    }

    @Test func startFromALine() {
        #expect(LyricsSync(count: 5, startAt: 3).active == 3)
        #expect(LyricsSync.startTime(from: 3, times: [10, 20, 30, 40, 50]) == 28)
        #expect(LyricsSync.startTime(from: 0, times: [10, 20]) == 0)
        #expect(LyricsSync.startTime(from: 1, times: [1, 20]) == 0)       // never before the start
    }

    @Test func showTimeDuringCountIn() {
        #expect(LyricsSync.showTime(countInPlaying: true, countInTime: 1.2, recordingTime: 0, pad: 4.8) == 1.2)
        #expect(LyricsSync.showTime(countInPlaying: false, countInTime: 4.8, recordingTime: 2.0, pad: 4.8) == 6.8)
    }

    @Test func replaceKeepsTimesOfUnchangedLines() {
        let old = [(time: 10.0, text: "un"), (time: 20.0, text: "deux"), (time: 30.0, text: "trois")]
        let r = LyricsText.replace(old: old, with: "un\nnouveau\ndeux\ntrois\nfin\n")
        #expect(r.lines.map(\.text) == ["un", "nouveau", "deux", "trois", "fin"])
        #expect(r.lines.map(\.time) == [10, 15, 20, 30, 32])
        #expect(r.firstChanged == 1)
        let fewer = LyricsText.replace(old: old, with: "trois\nun")
        #expect(fewer.lines.map(\.time) == fewer.lines.map(\.time).sorted())  // times stay increasing
    }
}
```

- [ ] **Step 2: Run to verify they fail.** Expected: `cannot find 'LyricsSync'`.

- [ ] **Step 3: Implement**

```swift
/// Tap sync over the lyric lines: Return stamps the active line and moves on; ↑/⌫ gives the last stamped line its
/// previous time back and makes it active again.
public struct LyricsSync: Sendable {
    public let count: Int
    public private(set) var active: Int?
    private var history: [(Int, Double)] = []
    private let start: Int

    public init(count: Int, startAt: Int = 0) {
        self.count = count
        start = min(max(0, startAt), count)
        active = start < count ? start : nil
    }

    public mutating func stamp(oldTime: Double) -> Int? {
        guard let a = active else { return nil }
        history.append((a, oldTime))
        active = a + 1 < count ? a + 1 : nil
        return a
    }

    public mutating func cancel() -> (index: Int, time: Double)? {
        guard let (i, t) = history.popLast() else { return nil }
        active = i
        return (i, t)
    }

    public var progress: (done: Int, total: Int) { ((active ?? count) - start + 0, count - start) == (0, 0) ? (0, 0) : (history.count, count - start) }

    public static func showTime(countInPlaying: Bool, countInTime: Double, recordingTime: Double, pad: Double) -> Double {
        countInPlaying ? countInTime : pad + recordingTime
    }

    public static func startTime(from line: Int, times: [Double]) -> Double {
        line <= 0 || line > times.count ? 0 : max(0, times[line - 1] - 2)
    }
}

/// « Remplacer le texte… »: new lines matched to the old ones in order (longest common subsequence of texts) keep
/// their time; the others are interpolated between neighbours (2 s steps after the last).
public enum LyricsText {
    public static func replace(old: [(time: Double, text: String)], with text: String)
        -> (lines: [(time: Double, text: String)], firstChanged: Int?) {
        let new = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let a = old.map(\.text), n = new.count, m = a.count
        var L = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                L[i][j] = new[i] == a[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            }
        }
        var times = [Double?](repeating: nil, count: n)
        var i = 0, j = 0
        while i < n && j < m {
            if new[i] == a[j] { times[i] = old[j].time; i += 1; j += 1 }
            else if L[i + 1][j] >= L[i][j + 1] { i += 1 } else { j += 1 }
        }
        let first = times.firstIndex { $0 == nil }
        var k = 0
        while k < n {
            guard times[k] == nil else { k += 1; continue }
            var e = k
            while e < n && times[e] == nil { e += 1 }
            let lo = k > 0 ? times[k - 1]! : 0
            let hi = e < n ? times[e]! : lo + 2 * Double(e - k + 1)
            for x in k..<e { times[x] = lo + (hi - lo) * Double(x - k + 1) / Double(e - k + 1) }
            k = e
        }
        for x in 1..<max(n, 1) where times[x]! < times[x - 1]! { times[x] = times[x - 1]! + 0.01 }
        return (zip(times, new).map { ($0!, $1) }, first)
    }
}
```

The `progress` expression above is muddled. Implement it plainly as `(history.count, count - start)`. The test pins
`(2, 3)` after two stamps from line 0. The interpolation after the last old line is `lo + 2·steps`, which gives
30 → 32 for « fin ».

- [ ] **Step 4: Run the whole Swift suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/LyricsSync.swift karaifyer/Tests/KaraifyerCoreTests/LyricsSyncTests.swift
git commit -m "karaifyer: lyric tap-sync state machine and replace-text merge"
```

---

### Task 3: Sync mode in the Corriger window

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/EditorModel.swift`
- Modify: `karaifyer/Sources/Karaifyer/EditorView.swift`

**Interfaces:**
- Consumes: Tasks 1–2; `ClickTrack.wav` for the count-in data (add `sampleRate:` with default 44100 if needed).
- Produces (UI):
  - `EditorModel.syncing: Bool`, `sync: LyricsSync?`, `syncMessage: String?`;
  - `startSync(fromSelected: Bool)`, `syncStamp()`, `syncCancel()`, `syncTogglePause()`, `stopSync(done:)`;
  - `replaceText(_:)`; `syncAvailable: Bool`.

- [ ] **Step 1: Model.**
  - **Availability:** `syncAvailable` is true when `song.padS != nil` and both `paths.dossier + "/clic.flac"` and
    `"/guide_voix.flac"` exist.
  - **`startSync(fromSelected:)`:**
    - stop the regular playback;
    - load the voice envelope once (`VocalOnset.load`) and keep it;
    - `startLine` is the selected line's index when `fromSelected`, else 0; build `LyricsSync(count:startAt:)`;
    - **from line 0:** build the count-in `AVAudioPlayer` from the first `pad_s` seconds of `clic.flac`, read with
      `AVAudioFile` and wrapped with `ClickTrack.wav`. Let `t0 = player.deviceCurrentTime + 0.1`. The count-in plays
      at `t0`, and the recording, from `currentTime = 0`, at `t0 + pad_s`; the click overlay starts the same way.
    - **from a line:** seek the recording to `LyricsSync.startTime(...) - pad_s` (input time) and play now, with no
      count-in;
    - install a local key monitor accepting only this window (title match, like `SpaceKey`) and only when no text
      field is being edited. It handles Return → `syncStamp`, ↑/⌫ → `syncCancel`, Space → `syncTogglePause`,
      Escape → `stopSync(done: false)`, and swallows those keys;
    - set `syncing = true`.
  - **`showNow`:** `LyricsSync.showTime(countInPlaying: countIn?.isPlaying == true, countInTime: countIn?.currentTime ?? 0, recordingTime: player.currentTime, pad: pad)`.
  - **`syncStamp()`:**
    - `guard let i = sync.active`;
    - `let press = showNow`;
    - `let t = VocalOnset.find(envelope: env, near: press) ?? press`;
    - `edit { doc.stamp(lines[i].id, at: t); lyricsDirty = true }`, then `_ = sync.stamp(oldTime: oldTime)`.

    The doc re-sorts by time, so stamp by id.
  - **`syncCancel()`:** `if let (i, old) = sync.cancel() { edit { doc.stamp(id_i, at: old) } }`. Remember line ids at
    sync start, because indices can move after re-sorting; stamp by the remembered id.
  - **`syncTogglePause()`:** pause or resume the count-in, the recording and the click together (resume with
    `play(atTime:)` aligned as in `startClick`).
  - **The timer:** when the recording reaches its end, call `stopSync(done: true)`.
  - **`stopSync(done:)`:** stop all players and remove the monitor. Set `syncing = false` and
    `syncMessage = done ? "\(n) lignes synchronisées" : nil`.
  - **Teardown:** `removeSpaceKey()` (window closing) also calls `stopSync(done: false)`.
  - **`replaceText(_ text: String)`:** apply `LyricsText.replace` in one `edit`: rebuild `doc` from the new lines,
    `lyricsDirty = true`. If `syncing`, rebuild `sync` starting at `firstChanged`.
  - **While `syncing`**, the regular Space monitor must not fire; the sync monitor handles Space. Install the sync
    monitor first and swallow the event.
- [ ] **Step 2: View.**
  - **Lyrics header:** « Synchroniser » (a menu with « Synchroniser » and « Synchroniser à partir de la ligne
    sélectionnée »), disabled with help « Analyser le morceau d'abord » when `!syncAvailable`. Next to it,
    « Remplacer le texte… » opens a sheet with a `TextEditor` prefilled with `lines.map(\.text).joined("\n")`, plus
    « Valider » (`replaceText`) and « Annuler ».
  - **While `syncing`**, a panel above the lyrics list shows:
    - the previous line (secondary);
    - **the active line in `.title` weight**;
    - the next line (secondary);
    - « \(done) / \(total) »;
    - the key help line « Entrée : caler la ligne · ↑ : annuler · Espace : pause · Échap : quitter »;
    - a « Quitter » button.
  - The lyrics list highlights the active sync line.
  - `syncMessage` shows as a caption after the end.
- [ ] **Step 3: Build and install**, then run the Swift suite. Expected: all pass, `Installed`.
- [ ] **Step 4: Smoke check against real files.** Run `Karaifyer --screenshots` and confirm the editor screenshot
  still renders. A sync session needs a person pressing keys, so it goes to the checklist.
- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/Karaifyer
git commit -m "karaifyer editor: lyric tap sync (count-in, Return to stamp, snap to the voice) and replace-text"
```

---

### Task 4: Docs and checklist

**Files:**
- Modify: `docs/guide/GUIDE.md` (Corriger section: « Synchroniser les paroles »)
- Modify: `docs/karaoke/karaifyer-validation.md`
- Modify: `karaifyer/README.md`

- [ ] **Step 1: Guide**, a subsection describing:
  - the count-in;
  - Return / ↑ / Space / Escape;
  - snapping to the voice;
  - starting from a line;
  - pausing to edit;
  - « Remplacer le texte… »;
  - saving, which becomes the lyrics correction, wins over LRCLIB and re-renders the video.
- [ ] **Step 2: Checklist rows:**
  - sync a whole song; cancel with ↑; pause, fix a word, resume; replace the whole text;
  - after saving, the video's lines appear on the voice;
  - Escape and closing the window stop the sound.
- [ ] **Step 3: Commit**

```bash
git add docs karaifyer/README.md
git commit -m "docs: lyric tap sync"
```
