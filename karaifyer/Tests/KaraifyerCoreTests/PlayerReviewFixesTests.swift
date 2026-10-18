import AVFoundation
import Foundation
import Testing
@testable import KaraifyerCore

struct PlayerReviewFixesTests {
    func tone(seconds: Double = 3) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rf-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(seconds * 44100)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        try f.write(from: b)
        return url
    }

    // review #1: what is heard lags what the nodes have pulled — the position must subtract that lead
    @Test func audiblePositionSubtractsTheLead() {
        #expect(PlayerEngine.songPosition(anchor: 10, elapsed: 2, lead: 0.1, loop: nil, length: 100) == 11.9)
        #expect(PlayerEngine.songPosition(anchor: 10, elapsed: 0.05, lead: 0.1, loop: nil, length: 100) == 10)   // never before the anchor
        #expect(abs(PlayerEngine.songPosition(anchor: 13, elapsed: 1.1, lead: 0.1, loop: (12, 14), length: 100) - 12) < 1e-9)   // 13 + 1.0 → wraps to 12
        #expect(PlayerEngine.songPosition(anchor: 99, elapsed: 5, lead: 0, loop: nil, length: 100) == 100)
    }

    // review #2: the video re-anchors at once on a loop wrap (any backwards jump), not 0.5 s later
    @Test func videoResyncOnWrapOrDrift() {
        #expect(VideoSync.needsResync(previous: 13.9, current: 12.05, video: 13.95))     // wrap
        #expect(VideoSync.needsResync(previous: 20.0, current: 20.1, video: 20.2))       // drift 100 ms
        #expect(!VideoSync.needsResync(previous: 20.0, current: 20.1, video: 20.12))     // in sync
    }

    // review #5: ffmpeg writes next to the target and replaces it only on success
    @Test func partialExportPath() {
        let p = ExportOptions.partialURL(for: URL(fileURLWithPath: "/x/042 Song – mix.m4a"))
        #expect(p.deletingLastPathComponent().path == "/x" && p.lastPathComponent.hasPrefix(".") && p.pathExtension == "m4a")
    }

    // review #13: a tempo change while playing must not reschedule (no dropout)
    @Test func tempoChangeDoesNotReschedule() throws {
        let e = try PlayerEngine(tracks: [try tone()])
        e.setMaster(0)                                   // silent test
        #expect(e.play())
        let n = e.reschedules
        e.setRate(0.8)
        #expect(e.reschedules == n)
        e.pause()
    }

    // review #3: an output-device change restarts playback where it was
    @Test func deviceChangeRestartsPlayback() throws {
        let e = try PlayerEngine(tracks: [try tone()])
        e.setMaster(0)
        #expect(e.play())
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: e.engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(e.restarts == 1 && e.isPlaying)
        e.pause()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: e.engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(e.restarts == 1 && !e.isPlaying)          // paused: nothing restarts
    }
}
