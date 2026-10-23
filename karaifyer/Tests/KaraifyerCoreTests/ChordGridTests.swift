import Testing
@testable import KaraifyerCore

struct ChordGridTests {
    func ok(_ c: String, _ bpb: Int = 4) -> [ChordAt]? { try? ChordGrid.parseCell(c, beatsPerBar: bpb).get() }

    @Test func sameSemanticsAsPython() {
        #expect(ok("A") == [ChordAt(beat: 0, label: "A")])
        #expect(ok("A B") == [ChordAt(beat: 0, label: "A"), ChordAt(beat: 2, label: "B")])
        #expect(ok("Am . . F") == [ChordAt(beat: 0, label: "Am"), ChordAt(beat: 3, label: "F")])
        #expect(ok("C G Am", 3) == [ChordAt(beat: 0, label: "C"), ChordAt(beat: 1, label: "G"), ChordAt(beat: 2, label: "Am")])
        #expect(ok("Cmaj7 F#m7b5/E") != nil && ok("N.C.") != nil)
        for bad in ["", "H", "A . B", ". A . .", "A B C D E"] { #expect(ok(bad) == nil) }
    }

    @Test func cellTextIsInverse() {
        for c in ["A", "A B", "Am . . F", "C . . G", "N.C."] {
            #expect(ChordGrid.cellText(ok(c)!, beatsPerBar: 4) == c)
        }
        #expect(ChordGrid.cellText(ok("C . G .")!, beatsPerBar: 4) == "C G")   // same split, canonical form
    }

    @Test func chartTextParsesBackLikeAccordsTxt() {
        let t = ChordGrid.chartText(title: "Danser", artist: "Loïc Nottet", key: "C# minor", bpm: 100, beatsPerBar: 4,
                                    cells: ["C#m", "A", "A", "A B", "C#m"])
        #expect(t == "Danser — Loïc Nottet\nTonalité : C# minor · 100 BPM · 4/4\n\n| C#m | A | A | A B |\n| C#m |\n")
    }

    @Test func barIndex() {
        let bars = [BarInfo(start: 0, chords: []), BarInfo(start: 2, chords: []), BarInfo(start: 4, chords: [])]
        #expect(ChordGrid.barIndex(at: -1, bars: bars) == nil)
        #expect(ChordGrid.barIndex(at: 2.5, bars: bars) == 1)
        #expect(ChordGrid.barIndex(at: 99, bars: bars) == 2)
    }

    @Test func acceptsTheNewSymbols() {
        for s in ["Edim7", "Am9", "Cmaj9", "G7sus4", "CmM7", "G11", "G13", "F#m7", "A/C#", "Bbm7b5", "N.C."] {
            #expect(ChordGrid.isValidSymbol(s), "\(s)")
        }
        #expect(!ChordGrid.isValidSymbol("H7") && !ChordGrid.isValidSymbol("Cmaj13"))
    }
}
