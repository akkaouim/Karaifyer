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
}
