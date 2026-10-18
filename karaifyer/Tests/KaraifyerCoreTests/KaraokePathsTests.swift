import Testing
@testable import KaraifyerCore

struct KaraokePathsTests {
    // Michel's brother: nothing may depend on Michel's disk or folder layout
    @Test func homeDefaultsToKaraokeInTheUserFolder() {
        #expect(KaraokePaths.home(saved: nil, legacyExists: false, userHome: "/Users/frere") == "/Users/frere/Karaoke")
        #expect(KaraokePaths.home(saved: nil, legacyExists: true, userHome: "/Users/m") == KaraokePaths.legacyHome)
        #expect(KaraokePaths.home(saved: "/Volumes/X/k", legacyExists: true, userHome: "/Users/m") == "/Volumes/X/k")
    }

    @Test func projectComesFromWhereTheAppWasBuilt() {
        #expect(KaraokePaths.project(saved: nil, bundled: "/Users/frere/code/Karaifyer/karaoke", userHome: "/Users/frere")
                == "/Users/frere/code/Karaifyer/karaoke")
        #expect(KaraokePaths.project(saved: "/x/karaoke", bundled: "/y/karaoke", userHome: "/u") == "/x/karaoke")
        #expect(KaraokePaths.project(saved: nil, bundled: nil, userHome: "/u") == "/u/Documents/mp3-pipeline/karaoke")
    }
}
