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
