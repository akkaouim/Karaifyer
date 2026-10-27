import Testing
@testable import KaraifyerCore

struct KaraokeFolderTests {
    let manifests: Set<String> = ["/Volumes/H/karaoke/manifeste.csv", "/Users/m/Soiree/manifeste.csv"]
    var has: (String) -> Bool { { manifests.contains($0) } }

    @Test func aKaraokeFolderIsTakenAsIs() {
        #expect(KaraokeFolder.suggestion(for: "/Volumes/H/karaoke", subfolders: [], hasFile: has) == nil)
    }

    // picking the drive instead of the karaoke folder inside it
    @Test func parentOfOneKaraokeFolderSuggestsIt() {
        #expect(KaraokeFolder.suggestion(for: "/Volumes/H", subfolders: ["Photos", "karaoke"], hasFile: has)
                == "/Volumes/H/karaoke")
    }

    @Test func emptyFolderHasNoSuggestion() {
        #expect(KaraokeFolder.suggestion(for: "/Users/m/Nouveau", subfolders: ["a"], hasFile: has) == nil)
    }

    @Test func severalCandidatesGiveNoSuggestion() {
        let both: (String) -> Bool = { $0.hasSuffix("/manifeste.csv") }
        #expect(KaraokeFolder.suggestion(for: "/x", subfolders: ["a", "b"], hasFile: both) == nil)
    }

    @Test func recentsMostRecentFirstWithoutDuplicatesKeepingFive() {
        var r = ["/a", "/b", "/c", "/d", "/e"]
        r = KaraokeFolder.recents(r, adding: "/c")
        #expect(r == ["/c", "/a", "/b", "/d", "/e"])
        r = KaraokeFolder.recents(r, adding: "/f")
        #expect(r == ["/f", "/c", "/a", "/b", "/d"])
        #expect(KaraokeFolder.recents(["/a/"], adding: "/a") == ["/a"])          // trailing slash is the same folder
    }

    @Test func shortNameForTheToolbar() {
        #expect(KaraokeFolder.displayName("/Volumes/Hypermnesia/karaoke") == "Hypermnesia › karaoke")
        #expect(KaraokeFolder.displayName("/Users/m/Karaoke") == "m › Karaoke")
    }
}
