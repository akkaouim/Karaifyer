import Foundation
import Testing
@testable import KaraifyerCore

struct ClickTrackTests {
    @Test func aClickOnEachBeatAccentLouder() {
        let s = ClickTrack.samples(beats: [0.1, 0.6], accents: [0], duration: 1)
        #expect(s.count == 44100)
        let peak = { (a: Int) in s[a..<(a + 1102)].map(abs).max()! }
        #expect(peak(4410) > 0.8 && peak(26460) > 0.5 && peak(26460) < 0.7)      // 0.9 accent, 0.6 plain
        #expect(s[0..<4400].allSatisfy { $0 == 0 })
    }

    @Test func wavHeaderAndLength() {
        let d = ClickTrack.wav([0, 0.5, -0.5])
        #expect(d.count == 44 + 6 && String(data: d[0..<4], encoding: .ascii) == "RIFF" && String(data: d[8..<12], encoding: .ascii) == "WAVE")
    }
}
