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
