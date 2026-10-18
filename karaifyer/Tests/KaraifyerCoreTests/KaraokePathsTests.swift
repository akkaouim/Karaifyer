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

struct ProjectFolderTests {
    // Michel's brother chose the repo folder (…/Karaifyer) instead of …/Karaifyer/karaoke in Settings
    @Test func repoFolderIsAcceptedForThePipeline() {
        let has: (String) -> Bool = { $0 == "/u/Code/Karaifyer/karaoke" }
        #expect(KaraokePaths.pipelineFolder("/u/Code/Karaifyer", hasPyproject: has) == "/u/Code/Karaifyer/karaoke")
        #expect(KaraokePaths.pipelineFolder("/u/Code/Karaifyer/karaoke", hasPyproject: has) == "/u/Code/Karaifyer/karaoke")
        #expect(KaraokePaths.pipelineFolder("/elsewhere", hasPyproject: has) == "/elsewhere")      // left as is: banner explains
    }

    @Test func beatDetectionFilesToForgetForARedetection() {
        #expect(KaraokePaths.beatDetection(home: "/k", id: "005") == ["/k/travail/005/beats.json", "/k/travail/005/beats.source.json"])
    }
}
