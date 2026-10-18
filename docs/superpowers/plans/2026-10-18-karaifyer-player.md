# Karaifyer Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a « Lecteur » tab to Karaifyer with the following:
- a searchable list of analysed songs, with deliberate loading;
- the lyrics video (double-click for full screen);
- an 8-track mixer plus master, each track with a gain fader, mute and solo;
- transport, a position bar and a bar-snapped loop;
- tempo in BPM and pitch in semitones;
- each song's settings remembered;
- mix export in a chosen format and quality.

**Architecture:**
- **Audio:** an `AVAudioEngine` graph (8 player nodes → per-track mixers → submix → `AVAudioUnitTimePitch` → main mixer), in **KaraifyerCore** so offline rendering can be unit-tested on generated audio.
- **Video:** a silent `AVPlayer` slaved to the engine's song position.
- **Logic:** all mixing, tempo, pitch, loop, export-argument and persistence logic is pure and tested in Core.
- **Export:** the engine in offline manual-rendering mode writes a 24-bit WAV, then **ffmpeg** encodes it.

**Tech Stack:**
- Swift 6 / SwiftPM, Command Line Tools only (no Xcode, no `@State`).
- AVFoundation (`AVAudioEngine`, `AVAudioUnitTimePitch`, `AVPlayer`, `AVPlayerView`) and SwiftUI.
- Swift Testing; ffmpeg.
- Python + pytest for the one pipeline change.

**Spec:** `docs/superpowers/specs/2026-10-18-karaifyer-player-design.md`

## Global Constraints

- **Branch** `player`; SysRec's files (`Sources/`, `Tests/`, `Package.swift`, `build-app.sh`, `Resources/`) stay untouched.
- **Swift tests:** `.superpowers/sdd/2026-10-13-karaifyer/swtest` (it wraps `swift test --package-path karaifyer -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`). Recreate it with that content if the workspace was pruned.
- **Python tests:** `uv --directory karaoke run pytest -q`.
- **No `@State`:** UI state lives in `@Observable` models (as KaraokeUI and EditorModel do).
- **UI text in French.** Track names, in mixer order: Clic, Guide voix, Guitare, Basse, Piano, Batterie, Accompagnement, Back Vocals.
- **Track files** (in the song folder, `SongState.paths.dossier`): `clic.flac`, `guide_voix.flac`, `guitare.flac`, `basse.flac`, `piano.flac`, `batterie.flac`, `accompagnement.flac`, `back_vocals.flac`, plus `paroles.mp4`. All are 44.1 kHz, same length, starting at the same instant (the package step guarantees this).
- **ffmpeg** is found through `Pipeline.searchPath` (it is already required).

## Review Focus

1. **A seek, loop or tempo change while playing must keep all 8 tracks sample-aligned.** Every node is rescheduled from the same frame, and position and video follow. Test: `PlayerEngineTests.seekKeepsTracksAligned`.
2. **The loop wraps without a gap and the position wraps with it.** Test: `LoopMathTests.positionWrapsInsideLoop`.
3. **A muted or non-soloed track is silent in both playback and export.** Test: `PlayerEngineTests.offlineRenderHonoursMute`.
4. **Exported length = song length / rate.** Test: `PlayerEngineTests.offlineRenderLengthFollowsRate`.
5. **A corrupt or missing saved mix falls back to the show defaults, never a crash.** Test: `PlayerMixTests.corruptSavedMixFallsBack`.

---

## File Structure

**Python:** `karaoke/src/karaoke/state.py` (add `bpm`); `karaoke/tests/test_state.py`.

**Swift Core** (`karaifyer/Sources/KaraifyerCore/`)
- `PipelineModels.swift`: add `SongState.bpm`.
- `PlayerMix.swift`: tracks, fader↔dB↔gain, effective gains, defaults from `retirer`, `PlayerSettings` persistence, readiness, search.
- `PlayerTiming.swift`: BPM↔rate, pitch, loop snapping, `LoopMath` position wrap.
- `ExportOptions.swift`: export kinds, formats, qualities, ffmpeg arguments, file names, persistence.
- `PlayerEngine.swift`: the `AVAudioEngine` graph, scheduling, position and offline rendering.

**Swift app** (`karaifyer/Sources/Karaifyer/`)
- `PlayerModel.swift`: video slaving, transport, loop, tempo, pitch, settings, Space key.
- `PlayerView.swift`: the tab UI and the full-screen video window.
- `PlayerExport.swift`: the export sheet, the WAV render and the ffmpeg encode with progress and cancel.
- `KaraifyerApp.swift`: the third tab.
- `Screenshots.swift`: a player screenshot.

**Tests** (`karaifyer/Tests/KaraifyerCoreTests/`): `PlayerMixTests.swift`, `PlayerTimingTests.swift`, `ExportOptionsTests.swift`, `PlayerEngineTests.swift`.

**Docs:** `docs/guide/GUIDE.md` (Lecteur section and screenshot), `docs/karaoke/karaifyer-validation.md`, `karaifyer/README.md`.

---

### Task 1: The pipeline exposes each song's BPM

**Files:**
- Modify: `karaoke/src/karaoke/state.py`
- Modify: `karaifyer/Sources/KaraifyerCore/PipelineModels.swift`
- Test: `karaoke/tests/test_state.py`, `karaifyer/Tests/KaraifyerCoreTests/PipelineModelsTests.swift`

**Interfaces:**
- Produces: `etat` key `"bpm"` (float or null), the package step's `bpm`, which is the median-interval tempo after the beat cleanup.
- Produces: `SongState.bpm: Double?`.

- [ ] **Step 1: Failing tests**

```python
# append to karaoke/tests/test_state.py
def test_song_state_includes_the_typical_bpm(cfg):
    s = song()
    ws = Workspace(cfg, s)
    ws.write_marker("package", {"result": {"pad_s": 1.0, "bpm": 100.4}})
    assert song_state(cfg, s, steps({}))["bpm"] == 100.4
    assert song_state(cfg, song(id="002"), steps({}))["bpm"] is None
```

```swift
// append to PipelineModelsTests (inside the struct)
    @Test func decodesBPM() throws {
        let raw = etat.replacingOccurrences(of: "\"pad_s\":2.5,", with: "\"pad_s\":2.5,\"bpm\":100.4,")
        #expect(try SongState.decodeList(Data(raw.utf8))[0].bpm == 100.4)
        #expect(try SongState.decodeList(Data(etat.utf8))[0].bpm == nil)
    }
```

- [ ] **Step 2: Run them, they fail**

Run: `uv --directory karaoke run pytest tests/test_state.py -q` and `.superpowers/sdd/2026-10-13-karaifyer/swtest --filter PipelineModels`
Expected: the Python test fails with a `KeyError: 'bpm'`, and the Swift test fails to compile because `bpm` isn't a member.

- [ ] **Step 3: Implement**

In `state.py`, in the returned dict, next to `"pad_s": pkg.get("pad_s")`, add `"bpm": pkg.get("bpm"),`.

In `PipelineModels.swift`, in `SongState`, add `public var bpm: Double?` after `padS`.

- [ ] **Step 4: Run all tests**

Run: `uv --directory karaoke run pytest -q` and `.superpowers/sdd/2026-10-13-karaifyer/swtest`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/state.py karaoke/tests/test_state.py karaifyer/Sources/KaraifyerCore/PipelineModels.swift karaifyer/Tests/KaraifyerCoreTests/PipelineModelsTests.swift
git commit -m "etat exposes each song's typical BPM (for the player's tempo control)"
```

---

### Task 2: PlayerMix (tracks, gains, mute/solo, defaults, persistence, readiness, search)

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/PlayerMix.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/PlayerMixTests.swift`

**Interfaces:**
- Produces:

```swift
public enum PlayerTrack: String, CaseIterable, Codable, Sendable {
    case clic, guideVoix, guitare, basse, piano, batterie, accompagnement, backVocals
    public var file: String          // "clic.flac", "guide_voix.flac", …
    public var label: String         // "Clic", "Guide voix", …
    public var retirerStem: String?  // guitare→"guitar", basse→"bass", piano→"piano", batterie→"drums", accompagnement→"other"
}
public enum Fader {
    public static func db(_ position: Double) -> Double?        // nil = −∞ (position 0)
    public static func position(db: Double?) -> Double
    public static func gain(_ position: Double) -> Float          // linear amplitude
    public static func label(_ position: Double) -> String        // "−∞", "−12 dB", "0 dB", "+3 dB"
    public static let unity: Double                               // position of 0 dB (60/66)
}
public struct PlayerSettings: Codable, Equatable, Sendable {
    public var faders: [PlayerTrack: Double]; public var mutes: Set<PlayerTrack>; public var solos: Set<PlayerTrack>
    public var master: Double; public var targetBPM: Double?; public var semitones: Int
    public var loopStart: Double?; public var loopEnd: Double?     // song seconds
    public static func defaults(retirer: [String]) -> PlayerSettings
    public func effectiveGains() -> [PlayerTrack: Float]          // master not included
    public var masterGain: Float
    public func encoded() -> Data
    public static func decode(_ data: Data?, retirer: [String]) -> PlayerSettings   // fallback = defaults
}
public enum PlayerLibrary {
    public static func missingFiles(in folder: String, exists: (String) -> Bool) -> [String]  // [] = ready
    public static func matches(_ query: String, id: String, titre: String, artiste: String) -> Bool
}
```

- [ ] **Step 1: Failing tests**

```swift
// karaifyer/Tests/KaraifyerCoreTests/PlayerMixTests.swift
import Foundation
import Testing
@testable import KaraifyerCore

struct PlayerMixTests {
    @Test func faderScale() {
        #expect(Fader.db(0) == nil && Fader.label(0) == "−∞")
        #expect(abs(Fader.db(1)! - 6) < 1e-9 && abs(Fader.db(Fader.unity)!) < 1e-9)
        #expect(abs(Fader.position(db: -12) - Fader.unity * 48 / 60) < 1e-9)
        #expect(Fader.label(Fader.position(db: -12)) == "−12 dB" && Fader.label(Fader.unity) == "0 dB")
        #expect(Fader.gain(0) == 0 && abs(Fader.gain(Fader.unity) - 1) < 1e-6)
        #expect(abs(Fader.gain(1) - Float(pow(10, 6.0 / 20))) < 1e-4)
    }

    @Test func showDefaultsFromRetirer() {
        let s = PlayerSettings.defaults(retirer: ["guitar", "other"])
        #expect(s.faders[.guitare] == 0 && s.faders[.accompagnement] == 0)
        #expect(s.faders[.clic] == Fader.unity && s.faders[.basse] == Fader.unity && s.master == Fader.unity)
        #expect(s.mutes.isEmpty && s.solos.isEmpty && s.targetBPM == nil && s.semitones == 0 && s.loopStart == nil)
    }

    @Test func muteAndSoloRules() {
        var s = PlayerSettings.defaults(retirer: [])
        s.solos = [.guitare, .basse]
        s.mutes = [.basse]                                   // muted wins over solo
        let g = s.effectiveGains()
        #expect(g[.guitare] == 1 && g[.basse] == 0 && g[.clic] == 0 && g[.piano] == 0)
        s.solos = []
        #expect(s.effectiveGains()[.clic] == 1 && s.effectiveGains()[.basse] == 0)
    }

    @Test func persistenceRoundTrip() {
        var s = PlayerSettings.defaults(retirer: ["piano"])
        s.targetBPM = 92; s.semitones = -2; s.loopStart = 30; s.loopEnd = 45; s.solos = [.clic]
        #expect(PlayerSettings.decode(s.encoded(), retirer: []) == s)
    }

    @Test func corruptSavedMixFallsBack() {
        #expect(PlayerSettings.decode(Data("nope".utf8), retirer: ["drums"]) == .defaults(retirer: ["drums"]))
        #expect(PlayerSettings.decode(nil, retirer: []) == .defaults(retirer: []))
    }

    @Test func readinessListsMissingFiles() {
        let present: Set<String> = Set(PlayerTrack.allCases.map { "/s/" + $0.file }).subtracting(["/s/piano.flac"])
        #expect(PlayerLibrary.missingFiles(in: "/s", exists: { present.contains($0) }) == ["piano.flac", "paroles.mp4"])
    }

    @Test func searchIgnoresAccentsAndCase() {
        #expect(PlayerLibrary.matches("ble", id: "041", titre: "La chanson des blés d'or", artiste: "F. Thibeault"))
        #expect(PlayerLibrary.matches("ZAZIE", id: "011", titre: "Speed", artiste: "Zazie"))
        #expect(PlayerLibrary.matches("041", id: "041", titre: "x", artiste: "y"))
        #expect(PlayerLibrary.matches("", id: "1", titre: "x", artiste: "y"))
        #expect(!PlayerLibrary.matches("brassens", id: "011", titre: "Speed", artiste: "Zazie"))
    }
}
```

- [ ] **Step 2: Run, it fails**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest --filter PlayerMix`
Expected: compile error, `cannot find 'Fader' in scope`.

- [ ] **Step 3: Implement**

```swift
// karaifyer/Sources/KaraifyerCore/PlayerMix.swift
import Foundation

/// The player's 8 tracks, in mixer order, with their files and their `retirer` stem.
public enum PlayerTrack: String, CaseIterable, Codable, Sendable {
    case clic, guideVoix, guitare, basse, piano, batterie, accompagnement, backVocals

    public var file: String {
        switch self {
        case .guideVoix: "guide_voix.flac"
        case .backVocals: "back_vocals.flac"
        default: rawValue + ".flac"
        }
    }
    public var label: String {
        switch self {
        case .clic: "Clic"; case .guideVoix: "Guide voix"; case .guitare: "Guitare"; case .basse: "Basse"
        case .piano: "Piano"; case .batterie: "Batterie"; case .accompagnement: "Accompagnement"
        case .backVocals: "Back Vocals"
        }
    }
    public var retirerStem: String? {
        switch self {
        case .guitare: "guitar"; case .basse: "bass"; case .piano: "piano"; case .batterie: "drums"
        case .accompagnement: "other"; default: nil
        }
    }
}

/// Fader travel 0…1: 0 = −∞, then −60…+6 dB linear in dB (0 dB at 60/66 ≈ 0.91, like a desk).
public enum Fader {
    static let minDB = -60.0, maxDB = 6.0
    public static let unity = -minDB / (maxDB - minDB)

    public static func db(_ position: Double) -> Double? {
        position <= 0 ? nil : minDB + (maxDB - minDB) * min(1, position)
    }
    public static func position(db: Double?) -> Double {
        guard let db else { return 0 }
        return max(0, min(1, (db - minDB) / (maxDB - minDB)))
    }
    public static func gain(_ position: Double) -> Float {
        guard let d = db(position) else { return 0 }
        return Float(pow(10, d / 20))
    }
    public static func label(_ position: Double) -> String {
        guard let d = db(position) else { return "−∞" }
        let r = Int(d.rounded())
        return r == 0 ? "0 dB" : (r > 0 ? "+\(r) dB" : "−\(-r) dB")
    }
}

/// One song's player state, saved per song (UserDefaults key `playerMix.<id>`).
public struct PlayerSettings: Codable, Equatable, Sendable {
    public var faders: [PlayerTrack: Double]
    public var mutes: Set<PlayerTrack>
    public var solos: Set<PlayerTrack>
    public var master: Double
    public var targetBPM: Double?
    public var semitones: Int
    public var loopStart: Double?
    public var loopEnd: Double?

    /// Like the show: parts played live (`retirer`) at zero, everything else at 0 dB.
    public static func defaults(retirer: [String]) -> PlayerSettings {
        var f: [PlayerTrack: Double] = [:]
        for t in PlayerTrack.allCases { f[t] = t.retirerStem.map { retirer.contains($0) } == true ? 0 : Fader.unity }
        return PlayerSettings(faders: f, mutes: [], solos: [], master: Fader.unity, targetBPM: nil, semitones: 0,
                              loopStart: nil, loopEnd: nil)
    }

    /// Mute wins; with any solo, only soloed (unmuted) tracks sound.
    public func effectiveGains() -> [PlayerTrack: Float] {
        var g: [PlayerTrack: Float] = [:]
        for t in PlayerTrack.allCases {
            g[t] = mutes.contains(t) || (!solos.isEmpty && !solos.contains(t)) ? 0 : Fader.gain(faders[t] ?? Fader.unity)
        }
        return g
    }
    public var masterGain: Float { Fader.gain(master) }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data?, retirer: [String]) -> PlayerSettings {
        guard let data, let s = try? JSONDecoder().decode(PlayerSettings.self, from: data) else { return defaults(retirer: retirer) }
        return s
    }
}

public enum PlayerLibrary {
    /// Files missing for the song to be playable ([] = ready): the 8 tracks, then the video.
    public static func missingFiles(in folder: String, exists: (String) -> Bool) -> [String] {
        (PlayerTrack.allCases.map(\.file) + ["paroles.mp4"]).filter { !exists(folder + "/" + $0) }
    }
    public static func matches(_ query: String, id: String, titre: String, artiste: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return [id, titre, artiste].contains { fold($0).contains(fold(q)) }
    }
}
```

**Codable note:** a dictionary keyed by an enum encodes as an array of key/value pairs, which round-trips fine. That's enough for this test.

- [ ] **Step 4: Run, all pass**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/PlayerMix.swift karaifyer/Tests/KaraifyerCoreTests/PlayerMixTests.swift
git commit -m "karaifyer core: player tracks, faders, mute/solo, show defaults, saved settings, readiness, search"
```

---

### Task 3: PlayerTiming (BPM ↔ rate, pitch, loop snapping, loop position)

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/PlayerTiming.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/PlayerTimingTests.swift`

**Interfaces:**
- Produces:

```swift
public enum Tempo {
    public static func clamp(_ bpm: Double, song: Double) -> Double      // within [0.5, 1.5] × song, rounded to 1 BPM
    public static func rate(target: Double?, song: Double?) -> Float     // 1 when either is nil
}
public enum Pitch {
    public static func clamp(_ semitones: Int) -> Int                    // −6…+6
    public static func cents(_ semitones: Int) -> Float                  // ×100
}
public enum LoopMath {
    public static func snap(_ t: Double, bars: [Double]) -> Double        // nearest bar start; no bars → nearest 0.1 s
    public static func ordered(_ a: Double, _ b: Double) -> (Double, Double)
    /// Song time after `elapsed` seconds of song time played from `start`, wrapping inside the loop
    public static func position(start: Double, elapsed: Double, loop: (Double, Double)?) -> Double
}
```

- [ ] **Step 1: Failing tests**

```swift
// karaifyer/Tests/KaraifyerCoreTests/PlayerTimingTests.swift
import Testing
@testable import KaraifyerCore

struct PlayerTimingTests {
    @Test func bpmToRate() {
        #expect(Tempo.rate(target: 90, song: 100) == 0.9)
        #expect(Tempo.rate(target: nil, song: 100) == 1 && Tempo.rate(target: 90, song: nil) == 1)
        #expect(Tempo.clamp(30, song: 100) == 50 && Tempo.clamp(200, song: 100) == 150 && Tempo.clamp(92.4, song: 100) == 92)
    }

    @Test func pitch() {
        #expect(Pitch.clamp(9) == 6 && Pitch.clamp(-9) == -6 && Pitch.cents(-2) == -200)
    }

    @Test func loopSnapsToBars() {
        let bars = [0.0, 2.4, 4.8, 7.2]
        #expect(LoopMath.snap(3.3, bars: bars) == 2.4 && LoopMath.snap(4.0, bars: bars) == 4.8)
        #expect(LoopMath.snap(3.34, bars: []) == 3.3)
        #expect(LoopMath.ordered(7.2, 2.4) == (2.4, 7.2))
    }

    @Test func positionWrapsInsideLoop() {
        #expect(LoopMath.position(start: 10, elapsed: 5, loop: nil) == 15)
        #expect(LoopMath.position(start: 10, elapsed: 5, loop: (12, 14)) == 13)       // 10→14 (4 s), then 1 s into the loop
        #expect(LoopMath.position(start: 13, elapsed: 0.5, loop: (12, 14)) == 13.5)
        #expect(LoopMath.position(start: 13, elapsed: 7, loop: (12, 14)) == 12)   // 13→14 (1 s), then 6 s = 3 loops → 12
    }
}
```

- [ ] **Step 2: Run, it fails**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest --filter PlayerTiming`
Expected: compile error, `cannot find 'Tempo' in scope`.

- [ ] **Step 3: Implement**

```swift
// karaifyer/Sources/KaraifyerCore/PlayerTiming.swift
import Foundation

public enum Tempo {
    public static func clamp(_ bpm: Double, song: Double) -> Double {
        min(max(bpm, song * 0.5), song * 1.5).rounded()
    }
    public static func rate(target: Double?, song: Double?) -> Float {
        guard let target, let song, song > 0 else { return 1 }
        return Float(target / song)
    }
}

public enum Pitch {
    public static func clamp(_ semitones: Int) -> Int { min(6, max(-6, semitones)) }
    public static func cents(_ semitones: Int) -> Float { Float(semitones * 100) }
}

public enum LoopMath {
    public static func snap(_ t: Double, bars: [Double]) -> Double {
        guard let best = bars.min(by: { abs($0 - t) < abs($1 - t) }) else { return (t * 10).rounded() / 10 }
        return best
    }
    public static func ordered(_ a: Double, _ b: Double) -> (Double, Double) { a <= b ? (a, b) : (b, a) }

    public static func position(start: Double, elapsed: Double, loop: (Double, Double)?) -> Double {
        guard let (a, b) = loop, b > a, start < b else { return start + elapsed }
        let toEnd = b - start
        if elapsed < toEnd { return start + elapsed }
        return a + (elapsed - toEnd).truncatingRemainder(dividingBy: b - a)
    }
}
```

- [ ] **Step 4: Run, all pass**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/PlayerTiming.swift karaifyer/Tests/KaraifyerCoreTests/PlayerTimingTests.swift
git commit -m "karaifyer core: tempo (BPM to rate), pitch, loop snapping and position wrap"
```

---

### Task 4: ExportOptions (formats, qualities, ffmpeg arguments, names, persistence)

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/ExportOptions.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/ExportOptionsTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ExportKind: String, Codable, CaseIterable, Sendable { case videoMaster, masterOnly }
public enum AudioFormat: String, Codable, CaseIterable, Sendable { case aac, mp3, wav, flac
    public var ext: String; public var lossless: Bool }
public struct ExportOptions: Codable, Equatable, Sendable {
    public var kind: ExportKind; public var format: AudioFormat; public var kbps: Int; public var bits: Int
    public var height: Int; public var highQuality: Bool; public var videoKbps: Int
    public static let defaults: ExportOptions
    public var ext: String                                            // "mp4" for video, else format.ext
    /// ffmpeg arguments after `-y`, given the rendered WAV, the song's video, the rate and the output path.
    public func ffmpegArgs(wav: String, video: String, rate: Float, out: String) -> [String]
    public static func fileName(id: String, titre: String, ext: String) -> String
    public static func duration(songSeconds: Double, rate: Float) -> Double
    public func encoded() -> Data; public static func decode(_ data: Data?) -> ExportOptions
}
```

- [ ] **Step 1: Failing tests**

```swift
// karaifyer/Tests/KaraifyerCoreTests/ExportOptionsTests.swift
import Foundation
import Testing
@testable import KaraifyerCore

struct ExportOptionsTests {
    @Test func defaults() {
        let d = ExportOptions.defaults
        #expect(d.kind == .masterOnly && d.format == .aac && d.kbps == 256 && d.bits == 24 && d.height == 1080 && d.highQuality)
        #expect(d.ext == "m4a")
        var v = d; v.kind = .videoMaster
        #expect(v.ext == "mp4")
    }

    @Test func audioArgsPerFormat() {
        var o = ExportOptions.defaults
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.m4a") == ["-i", "m.wav", "-c:a", "aac", "-b:a", "256k", "o.m4a"])
        o.format = .mp3; o.kbps = 320
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.mp3") == ["-i", "m.wav", "-c:a", "libmp3lame", "-b:a", "320k", "o.mp3"])
        o.format = .wav; o.bits = 16
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.wav") == ["-i", "m.wav", "-c:a", "pcm_s16le", "o.wav"])
        o.format = .flac; o.bits = 24
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.flac")
                == ["-i", "m.wav", "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", "o.flac"])
    }

    @Test func videoArgsScaleTimeAndSize() {
        var o = ExportOptions.defaults
        o.kind = .videoMaster; o.height = 720; o.highQuality = false; o.videoKbps = 192
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 0.9, out: "o.mp4") == [
            "-i", "v.mp4", "-i", "m.wav", "-map", "0:v:0", "-map", "1:a:0",
            "-vf", "setpts=PTS/0.9,scale=-2:720", "-c:v", "libx264", "-crf", "23", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", "o.mp4"])
    }

    @Test func namesAndDurations() {
        #expect(ExportOptions.fileName(id: "042", titre: "AC/DC: Back?", ext: "m4a") == "042 AC-DC- Back- – mix.m4a")
        #expect(ExportOptions.duration(songSeconds: 180, rate: 0.9) == 200)
    }

    @Test func rememberedChoices() {
        var o = ExportOptions.defaults; o.format = .flac; o.bits = 16
        #expect(ExportOptions.decode(o.encoded()) == o && ExportOptions.decode(Data("x".utf8)) == .defaults)
    }
}
```

- [ ] **Step 2: Run, it fails**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest --filter ExportOptions`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
// karaifyer/Sources/KaraifyerCore/ExportOptions.swift
import Foundation

public enum ExportKind: String, Codable, CaseIterable, Sendable { case videoMaster, masterOnly }

public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case aac, mp3, wav, flac
    public var ext: String { self == .aac ? "m4a" : rawValue }
    public var lossless: Bool { self == .wav || self == .flac }
}

/// The export sheet's choices (remembered in UserDefaults `playerExport`) and the ffmpeg command they make.
public struct ExportOptions: Codable, Equatable, Sendable {
    public var kind: ExportKind
    public var format: AudioFormat
    public var kbps: Int          // AAC / MP3
    public var bits: Int          // WAV / FLAC
    public var height: Int        // video: 1080 or 720
    public var highQuality: Bool  // video: CRF 18 vs 23
    public var videoKbps: Int     // video's AAC sound

    public static let defaults = ExportOptions(kind: .masterOnly, format: .aac, kbps: 256, bits: 24,
                                               height: 1080, highQuality: true, videoKbps: 256)

    public var ext: String { kind == .videoMaster ? "mp4" : format.ext }

    public func ffmpegArgs(wav: String, video: String, rate: Float, out: String) -> [String] {
        if kind == .videoMaster {
            let r = String(format: "%g", rate)
            return ["-i", video, "-i", wav, "-map", "0:v:0", "-map", "1:a:0",
                    "-vf", "setpts=PTS/\(r),scale=-2:\(height)", "-c:v", "libx264", "-crf", highQuality ? "18" : "23",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(videoKbps)k", "-shortest", "-movflags", "+faststart", out]
        }
        switch format {
        case .aac: return ["-i", wav, "-c:a", "aac", "-b:a", "\(kbps)k", out]
        case .mp3: return ["-i", wav, "-c:a", "libmp3lame", "-b:a", "\(kbps)k", out]
        case .wav: return ["-i", wav, "-c:a", bits == 16 ? "pcm_s16le" : "pcm_s24le", out]
        case .flac:
            return ["-i", wav, "-c:a", "flac", "-sample_fmt", bits == 16 ? "s16" : "s32"]
                + (bits == 16 ? [] : ["-bits_per_raw_sample", "24"]) + [out]
        }
    }

    public static func fileName(id: String, titre: String, ext: String) -> String {
        let safe = titre.map { "/:?\\*\"<>|".contains($0) ? "-" : $0 }
        return "\(id) \(String(safe)) – mix.\(ext)"
    }

    public static func duration(songSeconds: Double, rate: Float) -> Double { songSeconds / Double(rate) }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data?) -> ExportOptions {
        guard let data, let o = try? JSONDecoder().decode(ExportOptions.self, from: data) else { return .defaults }
        return o
    }
}
```

- [ ] **Step 4: Run, all pass**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/ExportOptions.swift karaifyer/Tests/KaraifyerCoreTests/ExportOptionsTests.swift
git commit -m "karaifyer core: export formats, qualities, ffmpeg arguments, file names, remembered choices"
```

---

### Task 5: PlayerEngine (AVAudioEngine graph, scheduling, position, offline render)

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/PlayerEngine.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/PlayerEngineTests.swift`

**Interfaces:**
- Consumes: `PlayerTrack`, `LoopMath` (Tasks 2–3).
- Produces:

```swift
public final class PlayerEngine: @unchecked Sendable {
    public init(tracks: [URL]) throws                         // 8 files in PlayerTrack order (tests may pass fewer)
    public let sampleRate: Double
    public let length: Double                                  // song seconds
    public private(set) var isPlaying: Bool
    public func setGains(_ gains: [Float]); public func setMaster(_ gain: Float)
    public func setRate(_ rate: Float); public func setPitch(cents: Float)
    public func setLoop(_ loop: (Double, Double)?)             // song seconds; nil = off; reschedules if playing
    public func play(from t: Double? = nil); public func pause()
    public func seek(to t: Double)                             // keeps play/pause state
    public var position: Double                               // song seconds, loop-wrapped
    public func renderOffline(to url: URL, progress: (Double) -> Bool) throws   // 24-bit WAV; false = cancel
}
```

- [ ] **Step 1: Failing tests (generated audio, offline render)**

```swift
// karaifyer/Tests/KaraifyerCoreTests/PlayerEngineTests.swift
import AVFoundation
import Foundation
import Testing
@testable import KaraifyerCore

struct PlayerEngineTests {
    /// A mono 44.1 kHz WAV: a sine of `freq` Hz (or silence when 0), `seconds` long.
    func tone(_ name: String, freq: Double, seconds: Double = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pe-\(name)-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(seconds * 44100)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        for i in 0..<Int(n) { b.floatChannelData![0][i] = freq == 0 ? 0 : Float(0.5 * sin(2 * .pi * freq * Double(i) / 44100)) }
        try f.write(from: b)
        return url
    }

    func rms(_ url: URL) throws -> (Float, AVAudioFramePosition) {
        let f = try AVAudioFile(forReading: url)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        var s: Float = 0
        for c in 0..<Int(b.format.channelCount) { for i in 0..<Int(b.frameLength) { s += b.floatChannelData![c][i] * b.floatChannelData![c][i] } }
        return ((s / Float(Int(b.frameLength) * Int(b.format.channelCount))).squareRoot(), f.length)
    }

    func out() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pe-out-\(UUID().uuidString).wav") }

    @Test func offlineRenderHonoursMute() throws {
        let e = try PlayerEngine(tracks: [try tone("a", freq: 440), try tone("b", freq: 660)])
        e.setGains([1, 0])                                    // second track muted
        let both = try PlayerEngine(tracks: [try tone("a2", freq: 440), try tone("b2", freq: 660)])
        let o1 = out(), o2 = out()
        try e.renderOffline(to: o1) { _ in true }
        try both.renderOffline(to: o2) { _ in true }
        let (r1, _) = try rms(o1), (r2, _) = try rms(o2)
        #expect(r1 > 0.05 && r2 > r1 * 1.3)                    // one tone vs two
    }

    @Test func offlineRenderLengthFollowsRate() throws {
        let e = try PlayerEngine(tracks: [try tone("c", freq: 440, seconds: 2)])
        e.setRate(0.5)
        let o = out()
        try e.renderOffline(to: o) { _ in true }
        let (_, frames) = try rms(o)
        #expect(abs(Double(frames) / 44100 - 4.0) < 0.15)       // 2 s at half speed ≈ 4 s
    }

    @Test func renderCanBeCancelled() throws {
        let e = try PlayerEngine(tracks: [try tone("d", freq: 440, seconds: 2)])
        let o = out()
        #expect(throws: CancellationError.self) { try e.renderOffline(to: o) { p in p < 0.3 } }
        #expect(!FileManager.default.fileExists(atPath: o.path))
    }

    @Test func seekKeepsTracksAligned() throws {
        let e = try PlayerEngine(tracks: [try tone("e", freq: 440), try tone("f", freq: 0)])
        e.seek(to: 1.25)
        #expect(abs(e.position - 1.25) < 0.01 && !e.isPlaying)
        e.setLoop((0.5, 1.0))
        e.seek(to: 0.75)
        #expect(abs(e.position - 0.75) < 0.01)
    }
}
```

- [ ] **Step 2: Run, it fails**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest --filter PlayerEngine`
Expected: compile error, `cannot find 'PlayerEngine' in scope`.

- [ ] **Step 3: Implement**

```swift
// karaifyer/Sources/KaraifyerCore/PlayerEngine.swift
import AVFoundation
import Foundation

/// The player's audio: one AVAudioPlayerNode per track → per-track mixer (gain) → submix → time-pitch
/// (tempo + transposition) → main mixer (master) → output. Seeking, looping and tempo changes reschedule
/// every node from the same frame, so all tracks stay sample-aligned. Also renders offline for export.
public final class PlayerEngine: @unchecked Sendable {
    let engine = AVAudioEngine()
    let files: [AVAudioFile]
    let players: [AVAudioPlayerNode]
    let gains: [AVAudioMixerNode]
    let submix = AVAudioMixerNode()
    let timePitch = AVAudioUnitTimePitch()
    public let sampleRate: Double
    public let length: Double
    public private(set) var isPlaying = false
    private var anchor: Double = 0                 // song time where the current schedule starts
    private var loop: (Double, Double)?
    private var generation = 0                     // invalidates stale loop completions

    public init(tracks: [URL]) throws {
        files = try tracks.map { try AVAudioFile(forReading: $0) }
        guard let first = files.first else { throw CocoaError(.fileReadNoSuchFile) }
        sampleRate = first.processingFormat.sampleRate
        length = files.map { Double($0.length) / $0.processingFormat.sampleRate }.min() ?? 0
        players = files.map { _ in AVAudioPlayerNode() }
        gains = files.map { _ in AVAudioMixerNode() }
        [submix, timePitch].forEach { engine.attach($0) }
        for (i, f) in files.enumerated() {
            engine.attach(players[i]); engine.attach(gains[i])
            engine.connect(players[i], to: gains[i], format: f.processingFormat)
            engine.connect(gains[i], to: submix, format: nil)
        }
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        engine.connect(submix, to: timePitch, format: stereo)
        engine.connect(timePitch, to: engine.mainMixerNode, format: stereo)
        engine.prepare()
    }

    public func setGains(_ g: [Float]) { for (i, m) in gains.enumerated() where i < g.count { m.outputVolume = g[i] } }
    public func setMaster(_ g: Float) { engine.mainMixerNode.outputVolume = g }
    public func setRate(_ r: Float) { let p = position; timePitch.rate = r; if isPlaying { play(from: p) } }
    public func setPitch(cents: Float) { timePitch.pitch = cents }

    public func setLoop(_ l: (Double, Double)?) {
        loop = l.flatMap { $0.1 > $0.0 ? $0 : nil }
        if isPlaying { play(from: position) }
    }

    /// Song time now: the anchor plus song seconds played by the first node (its sample time counts source
    /// frames, i.e. song frames, before the time-pitch unit), wrapped inside the loop.
    public var position: Double {
        guard isPlaying, let nt = players[0].lastRenderTime, let pt = players[0].playerTime(forNodeTime: nt) else { return anchor }
        let elapsed = max(0, Double(pt.sampleTime) / pt.sampleRate)
        return min(length, LoopMath.position(start: anchor, elapsed: elapsed, loop: loop))
    }

    public func play(from t: Double? = nil) {
        let start = min(max(0, t ?? position), length)
        schedule(from: start)
        if !engine.isRunning { try? engine.start() }
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        players.forEach { $0.play(at: when) }
        isPlaying = true
    }

    public func pause() {
        let p = position
        players.forEach { $0.stop() }
        anchor = p
        isPlaying = false
    }

    public func seek(to t: Double) {
        if isPlaying { play(from: t) } else { anchor = min(max(0, t), length); players.forEach { $0.stop() } }
    }

    /// Stop every node and schedule each one from song time `start`: up to the loop end, then the loop
    /// segment again and again (each completion schedules the next pass), or to the end of the song.
    private func schedule(from start: Double) {
        generation += 1
        let gen = generation
        players.forEach { $0.stop() }
        anchor = start
        for (i, f) in files.enumerated() {
            let sr = f.processingFormat.sampleRate
            let from = AVAudioFramePosition(start * sr)
            if let (a, b) = loop, start < b {
                let end = AVAudioFramePosition(b * sr)
                players[i].scheduleSegment(f, startingFrame: from, frameCount: AVAudioFrameCount(max(0, end - from)), at: nil)
                let a0 = AVAudioFramePosition(a * sr), count = AVAudioFrameCount(max(1, end - a0))
                for _ in 0..<4 { scheduleLoopPass(i, from: a0, count: count, gen: gen) }   // 4 passes queued ahead
            } else {
                players[i].scheduleSegment(f, startingFrame: from, frameCount: AVAudioFrameCount(max(0, f.length - from)), at: nil)
            }
        }
    }

    /// One loop pass; when it has been consumed, queue one more (so 4 stay ahead and the wrap never starves).
    private func scheduleLoopPass(_ i: Int, from: AVAudioFramePosition, count: AVAudioFrameCount, gen: Int) {
        players[i].scheduleSegment(files[i], startingFrame: from, frameCount: count, at: nil,
                                   completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self, self.generation == gen, self.isPlaying else { return }
            self.scheduleLoopPass(i, from: from, count: count, gen: gen)
        }
    }

    /// The whole song (no loop) through the same graph, faster than real time, to a 24-bit WAV.
    /// `progress(0…1)` returning false cancels: the partial file is deleted and CancellationError thrown.
    public func renderOffline(to url: URL, progress: (Double) -> Bool) throws {
        let wasPlaying = isPlaying
        pause()
        engine.stop()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        defer { engine.stop(); engine.disableManualRenderingMode(); engine.prepare(); if wasPlaying { play(from: anchor) } }
        let savedLoop = loop
        loop = nil
        schedule(from: 0)
        loop = savedLoop
        try engine.start()
        players.forEach { $0.play() }
        let total = AVAudioFramePosition(length / Double(timePitch.rate) * sampleRate)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buf.frameCapacity), total - done))
            let st = try engine.renderOffline(n, to: buf)
            guard st == .success else { break }
            try file.write(from: buf)
            done += AVAudioFramePosition(buf.frameLength)
            if !progress(Double(done) / Double(total)) {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
        }
        players.forEach { $0.stop() }
        isPlaying = false
    }
}
```

**Executor notes:**
- **Loop scheduling:** 4 loop passes are queued ahead, and each consumed pass queues one more. The completion
  runs off the main thread, but `generation` and `isPlaying` reads are benign races here (a stale completion just
  stops re-queuing). If a stutter is heard at the wrap, raise the number of passes ahead. Ledger it.
- The `position` test only checks the paused state (deterministic). Live position is verified manually in Task 9.
- If `renderOffline`'s rate-length test is off by more than 0.15 s because of the time-pitch unit's latency, keep rendering until the engine returns `.insufficientDataFromInputNode` or the frame count reaches `total + 0.25 s`, then trim to `total`. Ledger it.

- [ ] **Step 4: Run, all pass**

Run: `.superpowers/sdd/2026-10-13-karaifyer/swtest`
Expected: all pass, including the four engine tests.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/PlayerEngine.swift karaifyer/Tests/KaraifyerCoreTests/PlayerEngineTests.swift
git commit -m "karaifyer core: player audio engine (8 tracks, gains, tempo/pitch, loop, aligned seeks, offline render)"
```

---

### Task 6: PlayerModel (video slaving, transport, settings, Space key)

**Files:**
- Create: `karaifyer/Sources/Karaifyer/PlayerModel.swift`

**Interfaces:**
- Consumes: `KaraokeModel.shared.songs`, `PlayerEngine`, `PlayerSettings`, `Tempo`, `Pitch`, `LoopMath`.
- Produces: `@MainActor @Observable final class PlayerModel` (`static let shared`) with:
  - `selectedID`, `loaded: SongState?`, `settings`, `query`, `error`;
  - `isPlaying`, `position`, `length`, `songBPM`;
  - `videoPlayer: AVPlayer`;
  - `load(_ id:)`, `togglePlay()`, `restart()`, `seek(_:)`;
  - `setFader(_:_:)`, `toggleMute(_:)`, `toggleSolo(_:)`, `setMaster(_:)`, `setBPM(_:)`, `setSemitones(_:)`;
  - `markLoopStart()`, `markLoopEnd()`, `toggleLoop()`, `clearLoop()`, `loopOn`;
  - `readySongs`, `filteredSongs`, `missing(for:)`;
  - `installSpaceKey()` / `removeSpaceKey()`.

- [ ] **Step 1: Implement**

```swift
// karaifyer/Sources/Karaifyer/PlayerModel.swift
import AppKit
import AVFoundation
import KaraifyerCore
import Observation

/// The Lecteur tab: one loaded song, its engine, a silent video slaved to the engine, and its saved settings.
@MainActor @Observable
final class PlayerModel {
    static let shared = PlayerModel()
    var query = ""
    var selectedID: String?
    private(set) var loaded: SongState?
    var settings = PlayerSettings.defaults(retirer: [])
    var loopOn = false
    var error: String?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var length: Double = 0
    @ObservationIgnored let videoPlayer = AVPlayer()
    @ObservationIgnored private var engine: PlayerEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyMonitor: Any?

    var songs: [SongState] { KaraokeModel.shared.songs }
    func missing(for s: SongState) -> [String] {
        PlayerLibrary.missingFiles(in: s.paths.dossier, exists: { FileManager.default.fileExists(atPath: $0) })
    }
    var filteredSongs: [SongState] {
        songs.filter { PlayerLibrary.matches(query, id: $0.id, titre: $0.titre, artiste: $0.artiste) }
    }
    var songBPM: Double? { loaded?.bpm }
    var rate: Float { Tempo.rate(target: settings.targetBPM, song: songBPM) }
    var loopRange: (Double, Double)? {
        guard let a = settings.loopStart, let b = settings.loopEnd, b > a else { return nil }
        return (a, b)
    }

    func load(_ id: String) {
        guard let s = songs.first(where: { $0.id == id }), missing(for: s).isEmpty else { return }
        stopEverything()
        do {
            let urls = PlayerTrack.allCases.map { URL(fileURLWithPath: s.paths.dossier + "/" + $0.file) }
            let e = try PlayerEngine(tracks: urls)
            engine = e; loaded = s; length = e.length; position = 0; error = nil
            settings = PlayerSettings.decode(UserDefaults.standard.data(forKey: key(s.id)), retirer: s.retirer)
            loopOn = false
            videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: s.paths.dossier + "/paroles.mp4")))
            videoPlayer.isMuted = true
            applyAll()
        } catch {
            self.error = "Lecture impossible : \(error.localizedDescription)"
        }
    }

    private func key(_ id: String) -> String { "playerMix.\(id)" }
    private func save() { if let s = loaded { UserDefaults.standard.set(settings.encoded(), forKey: key(s.id)) } }

    private func applyAll() {
        guard let e = engine else { return }
        let g = settings.effectiveGains()
        e.setGains(PlayerTrack.allCases.map { g[$0] ?? 0 })
        e.setMaster(settings.masterGain)
        e.setPitch(cents: Pitch.cents(settings.semitones))
        e.setRate(rate)
        e.setLoop(loopOn ? loopRange : nil)
        if isPlaying { videoPlayer.rate = rate }
    }

    func togglePlay() {
        guard let e = engine else { return }
        if isPlaying {
            e.pause(); videoPlayer.pause(); isPlaying = false; stopTimer()
        } else {
            if e.position >= length - 0.05 { e.seek(to: 0) }
            e.play(); isPlaying = true
            resyncVideo(force: true); videoPlayer.rate = rate
            startTimer()
        }
    }
    func restart() { seek(0) }
    func seek(_ t: Double) {
        engine?.seek(to: t); position = engine?.position ?? t; resyncVideo(force: true)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private var ticks = 0
    private func tick() {
        guard let e = engine else { return }
        position = e.position
        ticks += 1
        if ticks % 5 == 0 { resyncVideo(force: false) }          // every 0.5 s
        if !loopOn && position >= length - 0.02 { togglePlay(); seek(0) }
    }

    /// The video follows the audio: re-seek it when it drifts more than 40 ms (or always when forced).
    private func resyncVideo(force: Bool) {
        let target = CMTime(seconds: engine?.position ?? 0, preferredTimescale: 600)
        let drift = abs(videoPlayer.currentTime().seconds - target.seconds)
        if force || drift > 0.04 { videoPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    func stopEverything() {
        engine?.pause(); videoPlayer.pause(); isPlaying = false; stopTimer()
    }

    // MARK: mixer, tempo, pitch, loop (each change applied live and saved)
    func setFader(_ t: PlayerTrack, _ v: Double) { settings.faders[t] = v; applyAll(); save() }
    func toggleMute(_ t: PlayerTrack) { settings.mutes.formSymmetricDifference([t]); applyAll(); save() }
    func toggleSolo(_ t: PlayerTrack) { settings.solos.formSymmetricDifference([t]); applyAll(); save() }
    func setMaster(_ v: Double) { settings.master = v; applyAll(); save() }
    func setBPM(_ bpm: Double?) {
        guard let song = songBPM else { return }
        settings.targetBPM = bpm.map { Tempo.clamp($0, song: song) }
        applyAll(); save()
    }
    func setSemitones(_ n: Int) { settings.semitones = Pitch.clamp(n); applyAll(); save() }
    private var bars: [Double] { loaded?.bars.map(\.start).map { $0 + (loaded?.padS ?? 0) } ?? [] }
    func markLoopStart() { settings.loopStart = LoopMath.snap(position, bars: bars); orderLoop() }
    func markLoopEnd() { settings.loopEnd = LoopMath.snap(position, bars: bars); orderLoop() }
    private func orderLoop() {
        if let a = settings.loopStart, let b = settings.loopEnd { (settings.loopStart, settings.loopEnd) = LoopMath.ordered(a, b) }
        applyAll(); save()
    }
    func toggleLoop() { loopOn.toggle(); applyAll() }
    func clearLoop() { settings.loopStart = nil; settings.loopEnd = nil; loopOn = false; applyAll(); save() }

    // MARK: Space = play/pause everything, except while a text field is being edited
    func installSpaceKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard ev.keyCode == 49, ev.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return ev }
            MainActor.assumeIsolated { self?.togglePlay() }
            return nil
        }
    }
    func removeSpaceKey() { if let m = keyMonitor { NSEvent.removeMonitor(m) }; keyMonitor = nil }

    func exportEngine() -> PlayerEngine? { engine }
}
```

**Executor notes:**
- **Bar times:** `bars[].start` are input-time seconds, while the player's song time includes the count-in `padS` (the package's audio files start with the pad). Hence the `+ padS` in `bars`. Verify on one song that the loop start lands on a bar line by ear, and ledger the check.
- **Overlapping changes:** `setRate` while playing reschedules every node from the current position (PlayerEngine.setRate), and `applyAll` calls it on every change. If that causes audible glitches when moving a fader, call `e.setRate` only when the rate actually changed. Ledger it.

- [ ] **Step 2: Build**

Run: `swift build --package-path karaifyer 2>&1 | grep -E "error" | head`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add karaifyer/Sources/Karaifyer/PlayerModel.swift
git commit -m "karaifyer: player model (engine + slaved video, transport, mixer, tempo, pitch, loop, saved settings, Space)"
```

---

### Task 7: PlayerView (the « Lecteur » tab)

**Files:**
- Create: `karaifyer/Sources/Karaifyer/PlayerView.swift`
- Modify: `karaifyer/Sources/Karaifyer/KaraifyerApp.swift` (add the third tab)

**Interfaces:**
- Consumes: `PlayerModel.shared`, `KaraokeModel.shared`, `CommitField` (KaraokeView.swift), `ExportSheet` (Task 8; add a temporary stub until then).
- Produces: `PlayerView(model:)`; `VideoView` (an `AVPlayerView` wrapper, double-click → full-screen window).

- [ ] **Step 1: Implement**

```swift
// karaifyer/Sources/Karaifyer/PlayerView.swift
import AppKit
import AVKit
import KaraifyerCore
import SwiftUI

struct PlayerView: View {
    @Bindable var model: PlayerModel

    var body: some View {
        HSplitView {
            songList.frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
            VStack(spacing: 6) {
                video
                positionBar
                controls
                mixer.frame(height: 230)
            }
            .padding(8)
            .frame(minWidth: 700)
        }
        .onAppear { model.installSpaceKey(); Task { await KaraokeModel.shared.refresh() } }
        .onDisappear { model.stopEverything(); model.removeSpaceKey() }
        .sheet(isPresented: Bindable(ExportUI.shared).shown) { ExportSheet(player: model) }
    }

    // MARK: list
    var songList: some View {
        VStack(spacing: 4) {
            TextField("Rechercher (titre, artiste, n°)", text: $model.query).textFieldStyle(.roundedBorder)
            List(model.filteredSongs, id: \.id, selection: $model.selectedID) { s in
                let miss = model.missing(for: s)
                HStack {
                    Text(model.loaded?.id == s.id ? "▶︎" : " ").frame(width: 14)
                    Text("\(s.id) · \(s.titre) — \(s.artiste)").lineLimit(1)
                }
                .foregroundStyle(miss.isEmpty ? .primary : .secondary)
                .help(miss.isEmpty ? "Double-clic ou « Charger »" : "Pas prêt : manque " + miss.joined(separator: ", "))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.load(s.id) }
                .simultaneousGesture(TapGesture().onEnded { model.selectedID = s.id })
            }
            .onKeyPress(.return) { if let id = model.selectedID { model.load(id) }; return .handled }
            Button("Charger") { if let id = model.selectedID { model.load(id) } }
                .disabled(model.selectedID == nil || model.selectedID == model.loaded?.id)
                .keyboardShortcut(.defaultAction)
        }
        .padding(8)
    }

    // MARK: video
    var video: some View {
        ZStack {
            Color.black
            if model.loaded != nil { VideoView(player: model.videoPlayer) }
            else { Text("Choisir un morceau dans la liste").foregroundStyle(.secondary) }
            if let e = model.error { Text(e).foregroundStyle(.orange).padding() }
        }
        .frame(minHeight: 260)
    }

    // MARK: position bar (with the loop zone)
    var positionBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if let (a, b) = model.loopRange, model.length > 0 {
                    Rectangle().fill(Color.yellow.opacity(model.loopOn ? 0.35 : 0.15))
                        .frame(width: max(2, g.size.width * (b - a) / model.length), height: 10)
                        .offset(x: g.size.width * a / model.length)
                }
                Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: 0...max(model.length, 1))
            }
        }
        .frame(height: 22)
        .disabled(model.loaded == nil)
    }

    // MARK: transport, loop, tempo, pitch, export
    var controls: some View {
        HStack(spacing: 10) {
            Button("Début", systemImage: "backward.end.fill") { model.restart() }.labelStyle(.iconOnly)
            Button(model.isPlaying ? "Pause" : "Lecture", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                .labelStyle(.iconOnly)
            Text("\(timecode(model.position)) / \(timecode(model.length))").monospacedDigit()
            Divider().frame(height: 18)
            Button("Début de boucle") { model.markLoopStart() }
            Button("Fin de boucle") { model.markLoopEnd() }
            Toggle("Boucle", isOn: Binding(get: { model.loopOn }, set: { _ in model.toggleLoop() })).toggleStyle(.button)
                .disabled(model.loopRange == nil)
            Button("Effacer") { model.clearLoop() }.disabled(model.loopRange == nil)
            Divider().frame(height: 18)
            tempo
            Divider().frame(height: 18)
            pitch
            Spacer()
            Button("Exporter le mix…") { ExportUI.shared.shown = true }
        }
        .disabled(model.loaded == nil)
    }

    var tempo: some View {
        let song = model.songBPM
        let cur = model.settings.targetBPM ?? song ?? 0
        return HStack(spacing: 4) {
            Text("Tempo :")
            Button("−") { model.setBPM(cur - 1) }
            CommitField(value: song == nil ? "—" : String(Int(cur.rounded())), enabled: song != nil) { model.setBPM(Double($0)) }
                .frame(width: 40)
            Button("+") { model.setBPM(cur + 1) }
            Text("BPM")
            Button("Original (\(Int((song ?? 0).rounded())))") { model.setBPM(nil) }
        }
        .disabled(song == nil)
    }

    var pitch: some View {
        let n = model.settings.semitones
        return HStack(spacing: 4) {
            Text("Hauteur :")
            Button("−") { model.setSemitones(n - 1) }
            Text(n == 0 ? "0" : String(format: "%+d", n)).monospacedDigit().frame(width: 28)
            Button("+") { model.setSemitones(n + 1) }
            Button("0") { model.setSemitones(0) }
            if n != 0 {
                Text("Transposé \(String(format: "%+d", n)) : accords de la vidéo dans la tonalité d'origine")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: mixer
    var mixer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(PlayerTrack.allCases, id: \.self) { t in
                channel(t.label, value: model.settings.faders[t] ?? Fader.unity, set: { model.setFader(t, $0) },
                        muted: model.settings.mutes.contains(t), soloed: model.settings.solos.contains(t),
                        mute: { model.toggleMute(t) }, solo: { model.toggleSolo(t) })
            }
            Divider()
            channel("Master", value: model.settings.master, set: { model.setMaster($0) },
                    muted: false, soloed: false, mute: nil, solo: nil)
        }
        .disabled(model.loaded == nil)
    }

    func channel(_ name: String, value: Double, set: @escaping (Double) -> Void, muted: Bool, soloed: Bool,
                 mute: (() -> Void)?, solo: (() -> Void)?) -> some View {
        VStack(spacing: 4) {
            Text(Fader.label(value)).font(.caption2).monospacedDigit()
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
                .rotationEffect(.degrees(-90)).frame(width: 140, height: 24).frame(width: 40, height: 140)
            HStack(spacing: 2) {
                if let mute { Toggle("M", isOn: Binding(get: { muted }, set: { _ in mute() })).toggleStyle(.button).tint(.red) }
                if let solo { Toggle("S", isOn: Binding(get: { soloed }, set: { _ in solo() })).toggleStyle(.button).tint(.yellow) }
            }
            .font(.caption)
            Text(name).font(.caption).lineLimit(1).frame(width: 78)
        }
    }
}

/// The lyrics video. Double-click opens it full screen (on the window's screen); double-click or Escape closes it.
struct VideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = DoubleClickPlayerView()
        v.player = player; v.controlsStyle = .none; v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

final class DoubleClickPlayerView: AVPlayerView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let p = player { FullScreenVideo.toggle(player: p, screen: window?.screen) }
        else { super.mouseDown(with: event) }
    }
}

/// A borderless window covering the screen with its own AVPlayerView on the same AVPlayer (one player, two layers).
@MainActor enum FullScreenVideo {
    static var window: NSWindow?
    static func toggle(player: AVPlayer, screen: NSScreen?) {
        if let w = window { w.orderOut(nil); window = nil; return }
        let frame = (screen ?? NSScreen.main)?.frame ?? .zero
        let w = EscWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .mainMenu + 1; w.backgroundColor = .black; w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let v = DoubleClickPlayerView(frame: frame)
        v.player = player; v.controlsStyle = .none; v.videoGravity = .resizeAspect
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

final class EscWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil); MainActor.assumeIsolated { FullScreenVideo.window = nil } }
}
```

Add the third tab in `KaraifyerApp.swift`, after the Karaoké one:

```swift
                PlayerView(model: PlayerModel.shared)
                    .tabItem { Label("Lecteur", systemImage: "play.rectangle") }
```

Until Task 8, add temporary stubs at the bottom of `PlayerView.swift`:

```swift
@Observable final class ExportUI { static let shared = ExportUI(); var shown = false }
struct ExportSheet: View { let player: PlayerModel; var body: some View { Text("Export") } }
```

**Executor notes:**
- **Song selection:** `List(selection:)` with `onTapGesture(count: 2)` can swallow single-click selection on macOS. If single clicks stop selecting, drop the `simultaneousGesture` and use `.contextMenu(forSelectionType:primaryAction:)`, whose primary action fires on double-click (macOS 13+). Ledger the choice.
- **Fader width:** the rotated `Slider` is the standard no-`@State` way to get a vertical fader. Adjust the frames if the column clips.

- [ ] **Step 2: Build and launch**

Run: `cd karaifyer && ./build-app.sh | tail -1 && open Karaifyer.app`
Expected: there is a « Lecteur » tab. The ready songs are listed, and non-ready ones are greyed out with the reason on hover. Double-clicking or « Charger » loads a song: the video appears and ▶︎ plays the audio. Faders, M and S are heard. Space plays and pauses. Double-click on the video goes full screen; Escape exits.

- [ ] **Step 3: Commit**

```bash
git add karaifyer/Sources/Karaifyer/PlayerView.swift karaifyer/Sources/Karaifyer/KaraifyerApp.swift
git commit -m "karaifyer: Lecteur tab (song list with deliberate loading, video with full screen, position/loop, tempo, pitch, mixer)"
```

---

### Task 8: Mix export (sheet, WAV render, ffmpeg encode, progress, cancel)

**Files:**
- Create: `karaifyer/Sources/Karaifyer/PlayerExport.swift` (remove the Task 7 stubs)

**Interfaces:**
- Consumes: `ExportOptions`, `PlayerEngine.renderOffline`, `SpawnedProcess`, `Pipeline.searchPath`, `PlayerModel`.
- Produces: `ExportUI.shared` (`shown`, `stage`, `progress`, `message`), `ExportSheet(player:)`.

- [ ] **Step 1: Implement**

```swift
// karaifyer/Sources/Karaifyer/PlayerExport.swift
import AppKit
import KaraifyerCore
import Observation
import SwiftUI

@MainActor @Observable final class ExportUI {
    static let shared = ExportUI()
    var shown = false
    var options = ExportOptions.decode(UserDefaults.standard.data(forKey: "playerExport"))
    var running = false
    var progress = 0.0
    var message: String?
    var lastFile: URL?
    @ObservationIgnored var cancelled = false
    @ObservationIgnored var ffmpeg: SpawnedProcess?

    func remember() { UserDefaults.standard.set(options.encoded(), forKey: "playerExport") }

    func run(player: PlayerModel) {
        guard let s = player.loaded, let engine = player.exportEngine() else { return }
        remember()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportOptions.fileName(id: s.id, titre: s.titre, ext: options.ext)
        panel.directoryURL = URL(fileURLWithPath: s.paths.dossier)
        guard panel.runModal() == .OK, let out = panel.url else { return }
        guard let ff = Pipeline.searchPath.map({ $0 + "/ffmpeg" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            message = "ffmpeg introuvable : brew install ffmpeg"; return
        }
        player.stopEverything()
        running = true; cancelled = false; progress = 0; message = nil; lastFile = nil
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("karaifyer-mix-\(UUID().uuidString).wav")
        let total = ExportOptions.duration(songSeconds: engine.length, rate: player.rate)
        do {   // 1. render (≈ first half of the bar)
            try engine.renderOffline(to: wav) { p in
                MainActor.assumeIsolated { self.progress = p * 0.5 }
                RunLoop.main.run(until: Date())           // keep the sheet responsive
                return !MainActor.assumeIsolated { self.cancelled }
            }
        } catch {
            finish(error: cancelled ? nil : "Rendu impossible : \(error.localizedDescription)", out: out, wav: wav); return
        }
        // 2. encode with ffmpeg (second half), progress from -progress pipe:1 (out_time_us)
        let args = [ff, "-y", "-progress", "pipe:1", "-nostats", "-loglevel", "error"]
            + options.ffmpegArgs(wav: wav.path, video: s.paths.video, rate: player.rate, out: out.path)
        var lastErr = ""
        do {
            ffmpeg = try SpawnedProcess(args: args, env: ["PATH": Pipeline.searchPath.joined(separator: ":")], cwd: NSTemporaryDirectory(),
                onLine: { [weak self] line in
                    if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), total > 0 {
                        self?.progress = 0.5 + 0.5 * min(1, us / 1e6 / total)
                    } else if !line.contains("=") { lastErr = line }
                },
                onExit: { [weak self] code in
                    guard let self else { return }
                    self.finish(error: code == 0 || self.cancelled ? nil : "ffmpeg : \(lastErr)", out: out, wav: wav, ok: code == 0 && !self.cancelled)
                })
        } catch {
            finish(error: "ffmpeg : \(error.localizedDescription)", out: out, wav: wav)
        }
    }

    func cancel() { cancelled = true; ffmpeg?.signal(SIGTERM) }

    private func finish(error: String?, out: URL, wav: URL, ok: Bool = false) {
        try? FileManager.default.removeItem(at: wav)
        if !ok { try? FileManager.default.removeItem(at: out) }
        running = false; ffmpeg = nil
        if ok { lastFile = out; message = "Exporté : \(out.lastPathComponent)" }
        else { message = error ?? "Export annulé" }
    }
}

struct ExportSheet: View {
    let player: PlayerModel
    let ui = ExportUI.shared

    var body: some View {
        @Bindable var ui = ui
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporter le mix").font(.headline)
            Picker("Contenu", selection: $ui.options.kind) {
                Text("Vidéo + master").tag(ExportKind.videoMaster)
                Text("Master seul (audio)").tag(ExportKind.masterOnly)
            }.pickerStyle(.segmented)
            if ui.options.kind == .masterOnly {
                Picker("Format", selection: $ui.options.format) {
                    Text("AAC (.m4a)").tag(AudioFormat.aac); Text("MP3").tag(AudioFormat.mp3)
                    Text("WAV").tag(AudioFormat.wav); Text("FLAC").tag(AudioFormat.flac)
                }
                if ui.options.format.lossless {
                    Picker("Qualité", selection: $ui.options.bits) { Text("16 bits").tag(16); Text("24 bits").tag(24) }
                } else {
                    Picker("Débit", selection: $ui.options.kbps) { ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) } }
                }
            } else {
                Picker("Résolution", selection: $ui.options.height) { Text("1080p").tag(1080); Text("720p").tag(720) }
                Picker("Qualité vidéo", selection: $ui.options.highQuality) { Text("Haute").tag(true); Text("Standard").tag(false) }
                Picker("Son (AAC)", selection: $ui.options.videoKbps) { ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) } }
            }
            Text("Tout le morceau, tel qu'on l'entend (faders, mute/solo, master, tempo, hauteur).")
                .font(.caption).foregroundStyle(.secondary)
            if ui.running { ProgressView(value: ui.progress) }
            if let m = ui.message { Text(m).foregroundStyle(ui.lastFile == nil ? .orange : .green) }
            HStack {
                if let f = ui.lastFile { Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) } }
                Spacer()
                if ui.running { Button("Annuler") { ui.cancel() } }
                else {
                    Button("Fermer") { ui.shown = false; ui.message = nil; ui.lastFile = nil }
                    Button("Exporter…") { ui.run(player: player) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 460)
    }
}
```

**Executor notes:**
- **`@Bindable var ui = ui`** inside `body` is the no-`@State` way to get bindings to an `@Observable` singleton. If the toolchain rejects it in this position, use `Bindable(ExportUI.shared).options.kind` and the like inline, and ledger it.
- **The render runs on the main thread,** pumping the run loop for progress and cancel. A 4-minute song renders in about 10–20 s. If the UI freezes noticeably, move `renderOffline` to a `Task.detached` and hop progress back to the main actor. Ledger it.

- [ ] **Step 2: Build and check**

Run: `cd karaifyer && ./build-app.sh | tail -1 && open Karaifyer.app`
Expected:
- « Exporter le mix… » opens the sheet. The options follow the kind and format, and they are remembered.
- Exporting AAC / MP3 / WAV / FLAC writes playable files; « Vidéo + master » writes an `.mp4`.
- « Annuler » leaves no file.
- Check one export with ffprobe: `ffprobe -v error -show_entries format=duration:stream=codec_name,bit_rate,height <file>`. The codec and bitrate or height should match the chosen options, and the duration should be the song length ÷ rate (for example, about 200 s for a 180 s song exported at 90 %).

- [ ] **Step 3: Commit**

```bash
git add karaifyer/Sources/Karaifyer/PlayerExport.swift karaifyer/Sources/Karaifyer/PlayerView.swift
git commit -m "karaifyer: mix export (video + master or master only; AAC/MP3/WAV/FLAC, MP4 1080p/720p; progress, cancel)"
```

---

### Task 9: Screenshot, guide, checklist, README; full verification

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/Screenshots.swift` (render the player with a song loaded)
- Modify: `docs/guide/GUIDE.md` (a new « Lecteur » section with `images/08-lecteur.png`)
- Modify: `docs/karaoke/karaifyer-validation.md` (rows 24+: the spec's manual checks)
- Modify: `karaifyer/README.md` (the Lecteur feature line)

- [ ] **Step 1: Player screenshot.** In `Screenshots.run`, before the QueueView render, add:

```swift
        let p = PlayerModel.shared
        p.load("042")
        p.seek(31)
        render(PlayerView(model: p), CGSize(width: 1500, height: 900), dir, "08-lecteur.png")
        p.stopEverything()
```

Then run: `karaifyer/.build/debug/Karaifyer --screenshots "$PWD/docs/guide/images"`
Expected: `08-lecteur.png` shows the list, the video frame, the controls and the mixer. If the video area renders black offscreen, keep the image and ledger it (the AVPlayerView layer isn't captured by `cacheDisplay`).

- [ ] **Step 2: Docs.**
  - Add a « Lecteur » section to GUIDE.md, after « Corriger », covering: loading (double-click or « Charger »), the mixer (M/S rules), the position bar, the loop (bar-snapped), tempo in BPM and pitch (with the chord reminder), full screen and Space, the remembered settings, and export (formats table).
  - Add the spec's manual checks to the validation checklist.
  - Add one line to the README.

- [ ] **Step 3: Full verification**

Run:
```bash
uv --directory karaoke run pytest -q 2>&1 | tail -1
.superpowers/sdd/2026-10-13-karaifyer/swtest 2>&1 | grep "Test run with"
git diff --stat main -- Sources Tests Package.swift build-app.sh Resources
```
Expected: both suites pass, and the last command prints nothing.

- [ ] **Step 4: Commit**

```bash
git add karaifyer docs
git commit -m "karaifyer: player screenshot, guide section, checklist and README"
```
