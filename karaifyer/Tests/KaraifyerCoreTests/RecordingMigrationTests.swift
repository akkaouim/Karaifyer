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

    // the real layout: the recorder points at a CSV subfolder; the recordings' home is the folder above it
    @Test func targetIsTheTopRecordingsFolder() {
        let numbered: Set<String> = ["/M/SysRec/Karaoké - Feuille 1", "/M/SysRec/Karaoké - Feuille 1/Karaoké - Copie de Feuille 1"]
        #expect(RecordingMigration.target(start: "/M/SysRec/Karaoké - Feuille 1/Karaoké - Copie de Feuille 1",
                                          hasNumbered: { numbered.contains($0) }) == "/M/SysRec/Karaoké - Feuille 1")
        #expect(RecordingMigration.target(start: "/M/SysRec/Karaoké - Feuille 1", hasNumbered: { numbered.contains($0) })
                == "/M/SysRec/Karaoké - Feuille 1")
    }

    // « Karaoké - Copie de Feuille 1 » holds songs of another CSV: they join the main folder; « old takes » only
    // holds songs already there: left alone
    @Test func subfoldersWithNewSongsAreBroughtInOthersAreLeftAlone() {
        let main = ["05 - Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet")]
        let subs = ["Karaoké - Copie de Feuille 1": ["088 - Lemon tree - Fool’s garden.flac": e("LT", "Lemon tree", "Fool’s garden"),
                                                     "088 - Lemon tree - Fool’s garden.mp3": e("LT", "Lemon tree", "Fool’s garden")],
                    "old takes": ["01 - Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet")]]
        let incoming = RecordingMigration.incoming(main: main, subfolders: subs)
        #expect(Set(incoming.keys) == ["Karaoké - Copie de Feuille 1/088 - Lemon tree - Fool’s garden.flac",
                                       "Karaoké - Copie de Feuille 1/088 - Lemon tree - Fool’s garden.mp3"])
        let p = RecordingMigration.renames(entries: main, others: [], incoming: incoming)
        #expect(Set(p.renames.map { "\($0.from)→\($0.to)" }) == [
            "05 - Danser - Loïc Nottet.flac→Danser - Loïc Nottet.flac",
            "Karaoké - Copie de Feuille 1/088 - Lemon tree - Fool’s garden.flac→Lemon tree - Fool’s garden.flac",
            "Karaoké - Copie de Feuille 1/088 - Lemon tree - Fool’s garden.mp3→Lemon tree - Fool’s garden.mp3"])
    }

    @Test func aTrackInTwoSubfoldersIsBroughtOnce() {
        let subs = ["a": ["1 - X - Y.flac": e("T", "X", "Y")], "b": ["2 - X - Y.flac": e("T", "X", "Y")]]
        #expect(RecordingMigration.incoming(main: [:], subfolders: subs).keys.sorted() == ["a/1 - X - Y.flac"])
    }

    // the recorder's old default: ~/Music/SysRec, recordings in its « Karaoké - Feuille 1 » subfolder
    @Test func aFolderWithoutRecordingsDescendsIntoTheFullestSubfolder() {
        let counts = ["/M/SysRec/Karaoké - Feuille 1": 85, "/M/SysRec/Vide": 0, "/M/SysRec/Autre": 3]
        #expect(RecordingMigration.descend(start: "/M/SysRec", ownCount: 0, subfolderCounts: counts) == "/M/SysRec/Karaoké - Feuille 1")
        #expect(RecordingMigration.descend(start: "/M/SysRec/Karaoké - Feuille 1", ownCount: 85, subfolderCounts: [:])
                == "/M/SysRec/Karaoké - Feuille 1")
        #expect(RecordingMigration.descend(start: "/M/Nouveau", ownCount: 0, subfolderCounts: ["/M/Nouveau/x": 0]) == "/M/Nouveau")
    }

    // the old name came from Michel's sheet (« Serge Regiani »); Spotify's tag says Georges Moustaki: the sheet wins
    @Test func theNewNameIsTheOldOneWithoutItsNumber() {
        let p = RecordingMigration.renames(entries: ["47 - Ma liberté - Serge Regiani.flac": e("M", "Ma liberté", "Georges Moustaki")],
                                           others: [])
        #expect(p.renames.map(\.to) == ["Ma liberté - Serge Regiani.flac"])
    }

    // Gate A #1: stopped after « 14 » was renamed, before « 80 » (same track): the re-plan must not stall on it
    @Test func rerunAfterInterruptionWithADuplicateGivesTheSecondCopyASuffix() {
        let p = RecordingMigration.renames(entries: [
            "Ma liberté de penser - Florent Pagny.flac": e("P", "Ma liberté de penser", "Florent Pagny"),
            "80 - Ma liberté de penser - Florent Pagny.flac": e("P", "Ma liberté de penser", "Florent Pagny")], others: [])
        #expect(p.renames == [.init(from: "80 - Ma liberté de penser - Florent Pagny.flac", to: "Ma liberté de penser - Florent Pagny (2).flac")])
        #expect(p.duplicates == ["Ma liberté de penser - Florent Pagny (2).flac"])
    }

    // Gate A: the FLAC was brought in, the MP3 not yet: the MP3 still comes
    @Test func incomingMatchesPerTrackAndExtension() {
        let main = ["Lemon tree - Fool’s garden.flac": e("LT", "Lemon tree", "Fool’s garden")]
        let subs = ["Copie": ["088 - Lemon tree - Fool’s garden.mp3": e("LT", "Lemon tree", "Fool’s garden")]]
        #expect(Array(RecordingMigration.incoming(main: main, subfolders: subs).keys) == ["Copie/088 - Lemon tree - Fool’s garden.mp3"])
    }
}
