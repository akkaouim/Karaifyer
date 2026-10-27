import Foundation
import Testing
@testable import KaraifyerCore

struct RemovalTests {
    let plan = """
    [{"id":"005","titre":"Danser","artiste":"Loïc Nottet",
      "analyse":{"fichiers":["/h/travail/005"],"taille":2000000},
      "corrections":{"fichiers":[],"taille":0},
      "audio":{"fichiers":["/a/05.flac"],"taille":30000000,"fichier":"/a/05.flac","partage":true}},
     {"id":"011","titre":"Speed","artiste":"X",
      "analyse":{"fichiers":["/h/travail/011","/h/sortie/011_x_speed"],"taille":5000000},
      "corrections":{"fichiers":["/h/paroles/011.lrc"],"taille":1200},
      "audio":{"fichiers":["/a/11.flac"],"taille":40000000,"fichier":"/a/11.flac","partage":false}}]
    """

    @Test func decodesThePlan() throws {
        let items = try RemovalItem.decodeList(Data(plan.utf8))
        #expect(items.map(\.id) == ["005", "011"])
        #expect(items[0].audio.partage && !items[1].audio.partage)
        #expect(items[1].corrections.fichiers == ["/h/paroles/011.lrc"])
    }

    @Test func totalsOnlyCountRecordingsThatCanGo() throws {
        let items = try RemovalItem.decodeList(Data(plan.utf8))
        #expect(RemovalItem.total(items, \.analyse) == 7_000_000)
        #expect(RemovalItem.total(items, \.corrections) == 1200)
        #expect(RemovalItem.audioTotal(items) == 40_000_000)       // 005's recording is shared: never trashed
        #expect(RemovalItem.audioOffered(items))
        #expect(!RemovalItem.audioOffered([items[0]]))
    }

    @Test func commandArguments() {
        #expect(RemovalChoice(ids: ["005", "011"], analyse: true, corrections: false, audio: true).arguments
                == ["retirer", "--ids", "005,011", "--analyse", "--audio", "--json"])
        #expect(RemovalChoice(ids: ["1"], analyse: false, corrections: false, audio: false).arguments
                == ["retirer", "--ids", "1", "--json"])
    }

    @Test func perSongSettingsKeys() {
        #expect(RemovalChoice.defaultsKeys(id: "011") == ["playerMix.011", "chordSuggestionIgnored.011"])
    }
}
