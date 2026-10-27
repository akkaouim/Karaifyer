import Foundation
import Testing
@testable import KaraifyerCore

struct RecordingFolderTests {
    @Test func namesAreTitleThenArtist() {
        #expect(RecordingNaming.base(title: "À ma place", artist: "Zazie/Axel Bauer") == "À ma place - Zazie & Axel Bauer")
        #expect(RecordingNaming.base(title: "Intro", artist: "") == "Intro")
    }

    @Test func clashWithAnotherSongGetsASuffix() {
        let existing: [String: String?] = ["Danser - Loïc Nottet.flac": "AAA", "Danser - Loïc Nottet (2).flac": "BBB"]
        #expect(RecordingNaming.unique(base: "Danser - Loïc Nottet", trackID: "AAA", ext: "flac", existing: existing)
                == "Danser - Loïc Nottet.flac")                                   // same song keeps its name
        #expect(RecordingNaming.unique(base: "Danser - Loïc Nottet", trackID: "CCC", ext: "flac", existing: existing)
                == "Danser - Loïc Nottet (3).flac")
        #expect(RecordingNaming.unique(base: "Speed - Zazie", trackID: "X", ext: "mp3", existing: existing)
                == "Speed - Zazie.mp3")
    }

    @Test func indexRereadsOnlyNewOrChangedFiles() {
        var idx = RecordingIndex()
        var reads: [String] = []
        let read = { (n: String) -> RecordingIndex.Entry in
            reads.append(n); return .init(size: 0, mtime: 0, trackID: "id-\(n)", title: "", artist: "")
        }
        let first = idx.refresh(listing: [("a.flac", 10, 1), ("b.flac", 20, 2)], read: read)
        #expect(first && reads == ["a.flac", "b.flac"])
        reads = []
        let again = idx.refresh(listing: [("a.flac", 10, 1), ("b.flac", 20, 2)], read: read)
        #expect(!again && reads.isEmpty)
        let changed = idx.refresh(listing: [("a.flac", 11, 1)], read: read)       // a changed, b gone
        #expect(changed)
        #expect(reads == ["a.flac"] && idx.entries["b.flac"] == nil)
        #expect(idx.entries["a.flac"]?.size == 11)
    }

    @Test func fileForATrackPrefersTheRequestedExtension() {
        var idx = RecordingIndex()
        _ = idx.refresh(listing: [("S.mp3", 1, 1), ("S.flac", 1, 1)]) { _ in .init(size: 0, mtime: 0, trackID: "T", title: "", artist: "") }
        #expect(idx.file(for: "T") == "S.flac" && idx.file(for: "T", ext: "mp3") == "S.mp3" && idx.file(for: "U") == nil)
    }

    @Test func indexRoundTripsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var idx = RecordingIndex()
        _ = idx.refresh(listing: [("a.flac", 1, 1)]) { _ in .init(size: 0, mtime: 0, trackID: "T", title: "t", artist: "a") }
        idx.save(dir: dir)
        #expect(RecordingIndex.load(dir: dir).file(for: "T") == "a.flac")
        #expect(RecordingIndex.load(dir: dir.appendingPathComponent("none")).entries.isEmpty)
    }
}
