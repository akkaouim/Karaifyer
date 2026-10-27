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

    // Gate A #3: a failed tag read (ffprobe missing) must be retried, not cached as « no id » forever
    @Test func failedReadsAreNotCached() {
        var idx = RecordingIndex()
        var ok = false
        let read = { (_: String) -> RecordingIndex.Entry? in ok ? .init(size: 0, mtime: 0, trackID: "T", title: "", artist: "") : nil }
        _ = idx.refresh(listing: [("a.flac", 1, 1)], read: read)
        #expect(idx.entries["a.flac"] == nil)
        ok = true
        _ = idx.refresh(listing: [("a.flac", 1, 1)], read: read)
        #expect(idx.file(for: "T") == "a.flac")
    }

    // Gate A: a leftover « .partial-…flac » must never make a row « done »
    @Test func hiddenFilesAreNotIndexed() {
        var idx = RecordingIndex()
        _ = idx.refresh(listing: [(".partial-X.flac", 1, 1)]) { _ in .init(size: 0, mtime: 0, trackID: "T", title: "", artist: "") }
        #expect(idx.file(for: "T") == nil)
    }

    // Gate A: « X.mp3 » of another track must not be overwritten when « X.flac » is free
    @Test func newNameIsFreeForEveryExtension() {
        let existing: [String: String?] = ["Danser - Loïc Nottet.mp3": "OTHER"]
        #expect(RecordingNaming.uniqueBase(base: "Danser - Loïc Nottet", trackID: "ME", exts: ["flac", "mp3"], existing: existing)
                == "Danser - Loïc Nottet (2)")
        #expect(RecordingNaming.uniqueBase(base: "Danser - Loïc Nottet", trackID: "OTHER", exts: ["flac", "mp3"], existing: existing)
                == "Danser - Loïc Nottet")
    }

    // Gate A #6: a copy to another disk keeps the modification date to the nanosecond (the analysis keys on it)
    @Test func copyKeepsTheExactModificationDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("a.flac"), dst = dir.appendingPathComponent("b.flac")
        try Data(repeating: 7, count: 1000).write(to: src)
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 408_564_648), timespec(tv_sec: 1_700_000_000, tv_nsec: 408_564_648)]
        #expect(utimensat(AT_FDCWD, src.path, &times, 0) == 0)
        try SafeMove.copy(from: src, to: dst)
        var a = stat(), b = stat()
        stat(src.path, &a); stat(dst.path, &b)
        #expect(a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec)
        #expect(a.st_size == b.st_size)
    }
}
