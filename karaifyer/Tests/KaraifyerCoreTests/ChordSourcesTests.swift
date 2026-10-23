import Foundation
import Testing
@testable import KaraifyerCore

struct ChordSourcesTests {
    @Test func progressionSectionsInFrench() {
        let s = ProgressionText.sections("<intro_1> E G D A <verse_1> D A <chorus_1> E Bmin D/Fs <bridge_1> Fsmin7 <weird_2> C ")
        #expect(s.map(\.title) == ["Intro 1", "Couplet 1", "Refrain 1", "Pont 1", "Weird 2"])
        #expect(s.map(\.chords) == ["E G D A", "D A", "E Bm D/F#", "F#m7", "C"])
    }

    @Test func mergeResultSummary() throws {
        let r = try JSONDecoder().decode(MergeResult.self, from: Data(#"{"cells":["Am"],"flagged":[0],"placed":42,"repeated":18,"vocab":3,"source":"collé"}"#.utf8))
        #expect(r.summary == "42 accords placés sur les paroles, 18 complétés par répétition, 1 mesure à vérifier")
    }

    @Test func susChordsStaySus() {
        #expect(ProgressionText.sections("<verse_1> Dsus4 Fs/As Asus2 Csmin ").first?.chords == "Dsus4 F#/A# Asus2 C#m")
    }

    @Test func progressionAsPlainText() {
        #expect(ProgressionText.plain("<verse_1> Fmin Ab <chorus_1> Db") == "Couplet 1 : Fm Ab\nRefrain 1 : Db")
    }

    @Test func chartTextFromVoir() throws {
        let c = try JSONDecoder().decode(ChartText.self, from: Data(#"{"source":"patadata","texte":"[Couplet]\nFm","original":"[Couplet]\nEm","transposition":1}"#.utf8))
        #expect(c.transposition == 1 && c.shift == "transposée de +1 demi-ton dans la tonalité du morceau")
        #expect(ChartText(source: "x", texte: "a", original: "a", transposition: 0).shift == "dans sa tonalité d'origine")
    }
}
