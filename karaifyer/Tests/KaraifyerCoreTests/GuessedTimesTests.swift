import Testing
@testable import KaraifyerCore

/// Lines placed by « Remplacer le texte » are « à caler »: the analysis aligns them on the voice.
struct GuessedTimesTests {
    @Test func replaceMarksPlacedLinesOnly() {
        let old = [LyricLine(time: 10, text: "un"), LyricLine(time: 20, text: "deux")]
        let r = LyricsText.replace(old: old, with: "un\nnouveau\ndeux\nfin")
        #expect(r.lines.map(\.guessed) == [false, true, false, true])
    }

    @Test func replaceKeepsTheMarkOfKeptGuessedLines() {
        let old = [LyricLine(time: 10, text: "un", guessed: true), LyricLine(time: 20, text: "deux")]
        let r = LyricsText.replace(old: old, with: "un\ndeux")
        #expect(r.lines.map(\.guessed) == [true, false])
    }

    @Test func formatAndParseCarryTheMark() {
        let lines = [LyricLine(time: 3, text: "Un"), LyricLine(time: 5, text: "Deux", guessed: true),
                     LyricLine(time: 7, text: "", guessed: true), LyricLine(time: 9, text: "Trois")]
        let text = LRC.format(lines, decalage: 2.0)
        #expect(text == "[karaoke:decalage=2.000]\n[karaoke:a_caler=1,2]\n[00:03.00]Un\n[00:05.00]Deux\n[00:07.00]\n[00:09.00]Trois\n")
        #expect(LRC.parse(text).lines.map(\.guessed) == [false, true, true, false])
        #expect(LRC.showTimeLines(text, pad: 2.0).map(\.guessed) == [false, true, true, false])
        #expect(!LRC.format([LyricLine(time: 3, text: "Un")], decalage: 2.0).contains("a_caler"))
    }

    @Test func timingByHandClearsTheMark() {
        var doc = LyricsDoc(lines: [LyricLine(time: 10, text: "a", guessed: true), LyricLine(time: 20, text: "b", guessed: true),
                                    LyricLine(time: 30, text: "c", guessed: true), LyricLine(time: 40, text: "d", guessed: true)])
        let ids = doc.lines.map(\.id)
        doc.stamp(ids[0], at: 11)
        doc.shift(ids[1], by: 0.5)
        doc.setTime(ids[2], "00:31.00")
        doc.setText(ids[3], "D")
        #expect(doc.lines.map(\.guessed) == [false, false, false, true])
        doc.stamp(ids[0], at: 10, guessed: true)    // a cancelled sync stamp puts the mark back
        #expect(doc.lines[0].guessed)
    }

    @Test func analysedTimesFillGuessedLines() {
        let mine = [LyricLine(time: 10, text: "Un"), LyricLine(time: 12, text: "Deux", guessed: true),
                    LyricLine(time: 14, text: "Trois", guessed: true)]
        let analysed = [LyricLine(time: 10.2, text: "Un"), LyricLine(time: 17.5, text: "Deux"), LyricLine(time: 21, text: "Trois")]
        let filled = LRC.fillGuessed(mine, from: analysed)
        #expect(filled.map(\.time) == [10, 17.5, 21])          // hand-timed lines keep their own time
        #expect(filled.map(\.guessed) == [false, false, false])
        #expect(filled.map(\.id) == mine.map(\.id))
    }

    @Test func analysisOfAnotherTextFillsNothing() {
        let mine = [LyricLine(time: 10, text: "Un"), LyricLine(time: 12, text: "Deux", guessed: true)]
        let old = [LyricLine(time: 10, text: "Un"), LyricLine(time: 17, text: "Autre")]
        #expect(LRC.fillGuessed(mine, from: old) == mine)
        #expect(LRC.fillGuessed(mine, from: [LyricLine(time: 10, text: "Un")]) == mine)
    }
}
