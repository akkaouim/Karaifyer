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

struct CorrectionsTests {
    func song(steps: String, corrections: String) throws -> SongState {
        let json = """
        [{"id":"011","titre":"Speed","artiste":"Zazie","album":"","fichier":"/x.flac","retirer":[],"langue":"fr","partie":"",
          "decompte_mesures":2,"statut":"ok","steps":[\(steps)],"corrections":\(corrections),
          "paths":{"dossier":"/d","video":"/v","set":"/s","accords":"/a","lrc":"/l","audio":"/w","lrc_corrige":"/p","accords_corrige":"/c"},
          "pad_s":null,"bpm":null,"beats_per_bar":4,"key":null,"bars":[]}]
        """
        return try #require(try SongState.decodeList(Data(json.utf8)).first)
    }
    let fresh = #"{"name":"chords","status":"a_jour","seconds":1,"error":""},{"name":"video","status":"a_jour","seconds":1,"error":""}"#
    let stale = #"{"name":"chords","status":"perime","seconds":1,"error":""},{"name":"video","status":"a_jour","seconds":1,"error":""}"#
    let never = #"{"name":"chords","status":"absent","seconds":null,"error":""},{"name":"video","status":"absent","seconds":null,"error":""}"#

    @Test func marksForChordsOrBarsAndForLyrics() throws {
        let s = try song(steps: fresh, corrections: #"{"paroles":"2026-10-26","accords":null,"mesures":"2026-10-27"}"#)
        #expect(s.musicEdited && s.lyricsEdited && s.correctionsSort == 2)
        #expect(s.correctionsHelp == "Paroles corrigées le 2026-10-26 · mesures corrigées le 2026-10-27")
        let none = try song(steps: fresh, corrections: #"{"paroles":null,"accords":null,"mesures":null}"#)
        #expect(!none.musicEdited && !none.lyricsEdited && none.correctionsSort == 0)
    }

    @Test func olderStateWithoutCorrectionsDecodes() throws {
        let s = try song(steps: fresh, corrections: "null")
        #expect(!s.musicEdited && !s.lyricsEdited)
    }

    @Test func staleStepsOfAnAnalysedSongMeanReanalyse() throws {
        #expect(try song(steps: stale, corrections: "null").needsReanalysis)
        #expect(!(try song(steps: fresh, corrections: "null").needsReanalysis))
        #expect(!(try song(steps: never, corrections: "null").needsReanalysis))          // never analysed: not « re- »
        #expect(try song(steps: stale, corrections: "null").reanalysisSort == 1)
        let allStale = #"{"name":"chords","status":"perime","seconds":1,"error":""},{"name":"video","status":"perime","seconds":1,"error":""}"#
        #expect(try song(steps: allStale, corrections: "null").needsReanalysis)       // a new take: everything out of date
    }

    @Test func searchingCorrigeListsCorrectedSongs() throws {
        let a = try song(steps: fresh, corrections: #"{"paroles":"2026-10-26","accords":null,"mesures":null}"#)
        let b = try song(steps: fresh, corrections: "null")
        #expect(SongList.filtered([a, b], query: "corrigé").count == 1)
        #expect(SongList.filtered([a, b], query: "Corrige").count == 1)
    }
}
