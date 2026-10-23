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
