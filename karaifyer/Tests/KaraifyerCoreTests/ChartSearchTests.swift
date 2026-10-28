import Foundation
import Testing
@testable import KaraifyerCore

struct ChartSearchTests {
    @Test func oneSearchPagePerSite() {
        #expect(ChartSearch.allCases.map(\.label) == ["Ultimate Guitar", "La Boîte à chansons"])
        #expect(ChartSearch.ultimateGuitar.url(titre: "Danser", artiste: "Loïc Nottet")?.absoluteString
                == "https://www.ultimate-guitar.com/search.php?search_type=title&value=Danser%20Lo%C3%AFc%20Nottet")
        #expect(ChartSearch.boiteAChansons.url(titre: "Tous les mêmes", artiste: "Stromae")?.absoluteString
                == "https://www.boiteachansons.net/recherche?q=Tous%20les%20m%C3%AAmes%20Stromae")
    }

    @Test func queryCharactersAreEscaped() {
        let u = ChartSearch.ultimateGuitar.url(titre: "Rock & Roll?", artiste: "A#B")!.absoluteString
        #expect(u.hasSuffix("value=Rock%20%26%20Roll%3F%20A%23B"))
    }
}
