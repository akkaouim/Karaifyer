import Testing
@testable import KaraifyerCore

struct UndoHistoryTests {
    @Test func undoThenRedoWalksBackAndForth() {
        var h = UndoHistory<Int>()
        #expect(!h.canUndo && !h.canRedo)
        h.record(1)                 // state was 1, now 2
        h.record(2)                 // state was 2, now 3
        #expect(h.undo(from: 3) == 2)
        #expect(h.undo(from: 2) == 1)
        #expect(h.undo(from: 1) == nil)
        #expect(h.redo(from: 1) == 2)
        #expect(h.redo(from: 2) == 3)
        #expect(h.redo(from: 3) == nil)
    }

    @Test func aNewEditClearsRedo() {
        var h = UndoHistory<Int>()
        h.record(1)
        _ = h.undo(from: 2)
        #expect(h.canRedo)
        h.record(1)
        #expect(!h.canRedo && h.canUndo)
    }

    @Test func historyIsCapped() {
        var h = UndoHistory<Int>(limit: 3)
        for i in 0..<10 { h.record(i) }
        #expect(h.undo(from: 10) == 9 && h.undo(from: 9) == 8 && h.undo(from: 8) == 7)
        #expect(h.undo(from: 7) == nil)
    }
}
