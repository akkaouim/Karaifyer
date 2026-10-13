import Testing
@testable import KaraifyerCore

struct LRCTests {
    @Test func roundTripMatchesPythonFormat() {
        let text = "[karaoke:decalage=2.000]\n[00:03.00]Un\n[01:05.30]Deux mots\n"
        let (lines, dec) = LRC.parse(text)
        #expect(dec == 2.0)
        #expect(lines == [LyricLine(time: 3.0, text: "Un"), LyricLine(time: 65.3, text: "Deux mots")])
        #expect(LRC.format(lines, decalage: 2.0) == text)
    }

    @Test func parseIgnoresOtherTagsAndSortsByTime() {
        let (lines, dec) = LRC.parse("[ar:Zazie]\n[00:10.00]B\n[00:02.50]A\n\n")
        #expect(dec == nil && lines.map(\.text) == ["A", "B"])
    }

    @Test func timecodes() {
        #expect(LRC.timecode(65.3) == "01:05.30")
        #expect(LRC.parseTimecode("1:05.3") == 65.3)
        #expect(LRC.parseTimecode("01:05.30") == 65.3)
        #expect(LRC.parseTimecode("abc") == nil)
    }
}
