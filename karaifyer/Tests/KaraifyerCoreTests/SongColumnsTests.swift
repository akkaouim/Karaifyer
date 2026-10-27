import Foundation
import Testing
@testable import KaraifyerCore

struct SongColumnsTests {
    @Test func keysAreShortened() {
        #expect(KeyName.short("C# minor") == "C#m")
        #expect(KeyName.short("Eb major") == "Eb")
        #expect(KeyName.short(nil) == "")
        #expect(KeyName.short("weird") == "weird")
    }

    let etat = """
    [{"id":"005","titre":"Danser","artiste":"L","album":"","fichier":"/x.flac","retirer":[],"langue":"fr","partie":"",
      "decompte_mesures":2,"statut":"alerte","verifie":"2026-10-27","steps":[],
      "paths":{"dossier":"/d","video":"/v","set":"/s","accords":"/a","lrc":"/l","audio":"/w","lrc_corrige":"/p","accords_corrige":"/c"},
      "pad_s":null,"bpm":119.6,"beats_per_bar":4,"key":"C# minor","bars":[]}]
    """

    @Test func verifiedDecodesAndSorts() throws {
        let s = try #require(try SongState.decodeList(Data(etat.utf8)).first)
        #expect(s.verifie == "2026-10-27" && s.isVerified && s.bpmRounded == 120 && s.keyShort == "C#m")
        let none = try #require(try SongState.decodeList(Data(etat.replacingOccurrences(of: "\"verifie\":\"2026-10-27\",", with: "")
            .replacingOccurrences(of: "\"bpm\":119.6", with: "\"bpm\":null").utf8)).first)
        #expect(!none.isVerified && none.bpmRounded == nil && none.bpmSort < s.bpmSort && none.verifiedSort < s.verifiedSort)
    }
}
