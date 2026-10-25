import Foundation
import Testing
@testable import KaraifyerCore

struct SongListTests {
    func song(_ id: String, _ titre: String, _ artiste: String, partie: String = "", statut: String = "ok",
              steps: [String] = ["a_jour"]) -> SongState {
        SongState(id: id, titre: titre, artiste: artiste, album: "", fichier: "", langue: "fr", partie: partie,
                  statut: statut, alertes: nil, retirer: [], decompteMesures: 2,
                  steps: steps.enumerated().map { StepState(name: "s\($0.offset)", status: $0.element, seconds: nil, error: nil) },
                  paths: SongPaths(dossier: "", video: "", set: "", accords: "", lrc: "", audio: "", lrcCorrige: "",
                                   accordsCorrige: ""),
                  padS: nil, bpm: nil, beatsPerBar: nil, key: nil, bars: [])
    }

    @Test func searchMatchesTitleArtistIdAndSetListIgnoringAccents() {
        let songs = [song("005", "Danser", "Loïc Nottet", partie: "Apéro"), song("042", "Tout le bonheur", "Sinsémilia")]
        #expect(SongList.filtered(songs, query: "loic").map(\.id) == ["005"])
        #expect(SongList.filtered(songs, query: "apero").map(\.id) == ["005"])
        #expect(SongList.filtered(songs, query: "042").map(\.id) == ["042"])
        #expect(SongList.filtered(songs, query: "  ").count == 2)
    }

    @Test func statusSortsBySeverityAndStepsByProgress() {
        #expect(["ok", "echec", "—", "alerte", "a_reessayer"].sorted { SongState.rank(statut: $0) < SongState.rank(statut: $1) }
                == ["echec", "a_reessayer", "alerte", "ok", "—"])
        let s = song("1", "a", "b", steps: ["a_jour", "a_jour", "perime"])
        #expect(s.stepsDone == 2 && s.statutRank == SongState.rank(statut: "ok"))
    }
}
