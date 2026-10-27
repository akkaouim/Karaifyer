import Testing
@testable import KaraifyerCore

struct RecordingMigrationTests {
    let e = { (id: String?, t: String, a: String) in RecordingIndex.Entry(size: 1, mtime: 1, trackID: id, title: t, artist: a) }

    @Test func oldLayoutMovesTheOutputFolderIntoTheListFolder() {
        let has = { (p: String) in p == "/Users/m/Music/SysRec/Karaoké - Feuille 1" }
        #expect(RecordingMigration.outputFolder(savedRoot: "/Users/m/Music/SysRec", listName: "Karaoké - Feuille 1",
                                                dirHasRecordings: has) == "/Users/m/Music/SysRec/Karaoké - Feuille 1")
        #expect(RecordingMigration.outputFolder(savedRoot: "/Users/m/Music/SysRec/Karaoké - Feuille 1", listName: "X",
                                                dirHasRecordings: has) == nil)
        #expect(RecordingMigration.outputFolder(savedRoot: "/r", listName: nil, dirHasRecordings: has) == nil)
    }

    @Test func numberedFilesAreRenamedFromTheirTags() {
        let p = RecordingMigration.renames(entries: [
            "05 - Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet"),
            "05 - Danser - Loïc Nottet.mp3": e("AAA", "Danser", "Loïc Nottet"),
            "03 - À ma place - Zazie & Axel Bauer.flac": e("BBB", "À ma place", "Zazie/Axel Bauer"),
        ], others: ["sysrec-log.txt"])
        #expect(Set(p.renames.map { "\($0.from)→\($0.to)" }) == [
            "05 - Danser - Loïc Nottet.flac→Danser - Loïc Nottet.flac",
            "05 - Danser - Loïc Nottet.mp3→Danser - Loïc Nottet.mp3",
            "03 - À ma place - Zazie & Axel Bauer.flac→À ma place - Zazie & Axel Bauer.flac"])
        #expect(p.duplicates.isEmpty)
    }

    @Test func asdFollowsItsMp3() {
        let p = RecordingMigration.renames(entries: ["39 - La petite église - Jean Lumière.mp3": e("C", "La petite église", "Jean Lumière")],
                                           others: ["39 - La petite église - Jean Lumière.mp3.asd"])
        #expect(p.renames.contains { $0.from == "39 - La petite église - Jean Lumière.mp3.asd" && $0.to == "La petite église - Jean Lumière.mp3.asd" })
    }

    // rows 14 and 80 of the sheet: one track recorded once, copied under a second number
    @Test func secondCopyOfATrackGetsASuffixAndIsListed() {
        let p = RecordingMigration.renames(entries: [
            "14 - Lili - Aaron.flac": e("L", "Lili", "Aaron"), "80 - Lili - Aaron.flac": e("L", "Lili", "Aaron")], others: [])
        #expect(Set(p.renames.map(\.to)) == ["Lili - Aaron.flac", "Lili - Aaron (2).flac"])
        #expect(p.duplicates == ["Lili - Aaron (2).flac"])
    }

    @Test func neverRenamesOntoAnExistingNameNorTouchesUnnumberedFiles() {
        let p = RecordingMigration.renames(entries: [
            "Danser - Loïc Nottet.flac": e("X", "Danser", "Loïc Nottet"),        // already new-style, another song
            "05 - Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet")], others: [])
        #expect(p.renames.map(\.to) == ["Danser - Loïc Nottet (2).flac"])
    }

    // drive unplugged half-way: files already renamed are unnumbered, the rest are still numbered
    @Test func rerunAfterInterruptionFinishesWithoutDoubleRenaming() {
        let p = RecordingMigration.renames(entries: [
            "Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet"),
            "06 - La lettre - Renan Luce.flac": e("BBB", "La lettre", "Renan Luce")], others: [])
        #expect(p.renames == [.init(from: "06 - La lettre - Renan Luce.flac", to: "La lettre - Renan Luce.flac")])
    }

    @Test func moveIsOfferedOnlyToAnotherFolderNotInsideTheCurrentOne() {
        #expect(FolderChoice.moveOffered(current: "/a/b", new: "/a/c"))
        #expect(!FolderChoice.moveOffered(current: "/a/b", new: "/a/b/"))
        #expect(!FolderChoice.moveOffered(current: "/a/b", new: "/a/b/sub"))
        #expect(FolderChoice.moveOffered(current: "/a/b/sub", new: "/a/b"))
        #expect(FolderChoice.moveOffered(current: "/a/b", new: "/a/bc"))
    }

    @Test func safeMoveSkipsNamesTakenAtTheDestination() {
        let r = SafeMove.plan(files: ["A.flac", "B.flac"], destinationNames: ["B.flac"])
        #expect(r.move == ["A.flac"] && r.skipped == ["B.flac"])
    }
}
