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
