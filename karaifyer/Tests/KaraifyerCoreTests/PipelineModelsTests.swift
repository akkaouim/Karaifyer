import Foundation
import Testing
@testable import KaraifyerCore

struct PipelineModelsTests {
    let etat = """
    [{"id":"005","titre":"Danser","artiste":"Loïc Nottet","album":"","fichier":"/x.flac","retirer":["guitar"],
      "langue":"fr","partie":"Apéro","decompte_mesures":2,"statut":"ok",
      "steps":[{"name":"ingest","status":"a_jour","seconds":3.2,"error":""},
               {"name":"video","status":"echec","seconds":null,"error":"video : echec boom"}],
      "paths":{"dossier":"/d","video":"/d/paroles.mp4","set":"/s.als","accords":"/d/accords.txt","lrc":"/d/paroles.lrc",
               "audio":"/w/input.wav","lrc_corrige":"/p/005.lrc","accords_corrige":"/a/005.txt"},
      "pad_s":2.5,"beats_per_bar":4,"key":"C# minor","bars":[{"start":0.0,"chords":[[0,"C#m"],[2,"A"]]}]}]
    """

    @Test func decodesEtat() throws {
        let s = try #require(try SongState.decodeList(Data(etat.utf8)).first)
        #expect(s.id == "005" && s.retirer == ["guitar"] && s.padS == 2.5 && s.beatsPerBar == 4)
        #expect(s.steps[1].status == "echec" && s.steps[0].seconds == 3.2)
        #expect(s.paths.lrcCorrige == "/p/005.lrc")
        #expect(s.bars[0].chords == [ChordAt(beat: 0, label: "C#m"), ChordAt(beat: 2, label: "A")])
    }

    @Test func decodesNullsForUnprocessedSong() throws {
        let raw = etat.replacingOccurrences(of: "\"pad_s\":2.5,\"beats_per_bar\":4,\"key\":\"C# minor\"",
                                            with: "\"pad_s\":null,\"beats_per_bar\":null,\"key\":null")
        let s = try #require(try SongState.decodeList(Data(raw.utf8)).first)
        #expect(s.padS == nil && s.key == nil)
    }

    @Test func decodesBPM() throws {
        let raw = etat.replacingOccurrences(of: "\"pad_s\":2.5,", with: "\"pad_s\":2.5,\"bpm\":100.4,")
        #expect(try SongState.decodeList(Data(raw.utf8))[0].bpm == 100.4)
        #expect(try SongState.decodeList(Data(etat.utf8))[0].bpm == nil)
    }

    @Test func parsesEvents() {
        #expect(PipelineEvent.parse(#"{"event":"song_start","id":"005"}"#) == .songStart(id: "005"))
        #expect(PipelineEvent.parse(#"{"event":"step_end","id":"005","step":"beats","status":"fait","seconds":4.5,"error":""}"#)
                == .stepEnd(id: "005", step: "beats", status: "fait", seconds: 4.5, error: ""))
        #expect(PipelineEvent.parse(#"{"event":"log","id":"005","line":"début beats"}"#) == .log(id: "005", line: "début beats"))
        #expect(PipelineEvent.parse(#"{"event":"song_end","id":"005","statut":"alerte"}"#) == .songEnd(id: "005", statut: "alerte"))
        #expect(PipelineEvent.parse("Traceback (most recent call last):") == nil)
    }
}
