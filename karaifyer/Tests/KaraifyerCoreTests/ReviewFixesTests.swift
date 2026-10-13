import Testing
@testable import KaraifyerCore

@MainActor struct ReviewFixesTests {
    // review #2: the analysis paused for a recording resumes when the recording ends
    @Test func pausedForRecordingResumesWhenRecordingEnds() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005")]); c.pauseForRecording()
        #expect(c.state == .paused)
        c.recordingEnded()
        #expect(c.state == .running && d.calls == ["launch 005", "stop", "cont"])
    }

    @Test func manualPauseIsNotUndoneByRecordingEnd() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005")]); c.pause(); c.recordingEnded()
        #expect(c.state == .paused)
        c.pauseForRecording()                 // already paused by Michel: stays his pause
        c.recordingEnded()
        #expect(c.state == .paused)
    }

    // review #5: edits address a line by identity, not by its current row
    @Test func lyricEditsFollowTheLineAcrossResorts() {
        var doc = LyricsDoc(lines: [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b"), LyricLine(time: 30, text: "c")])
        let b = doc.lines[1].id, c = doc.lines[2].id
        doc.stamp(c, at: 5)                   // c moves to the top
        doc.setText(b, "B")                   // still edits b, wherever it is now
        #expect(doc.lines.map(\.text) == ["c", "a", "B"])
        doc.delete(b)
        doc.setText(b, "ghost")               // late commit for a deleted line: ignored, no crash
        doc.setTime(c, "00:40.00")
        #expect(doc.lines.map(\.text) == ["a", "c"] && doc.lines[1].time == 40)
        let n = doc.add(at: 12.345)
        #expect(doc.lines.map(\.id).contains(n) && doc.lines[1].time == 12.35)
    }

    // review #7: a corrected LRC saved at another pad must be converted, not taken as-is
    @Test func loadConvertsWithTheFilesOwnDecalage() {
        let text = "[karaoke:decalage=4.210]\n[00:14.21]Un\n"
        #expect(LRC.showTimeLines(text, pad: 2.10).map(\.time) == [12.10])
        #expect(LRC.showTimeLines("[00:10.00]Un\n", pad: 2.10).map(\.time) == [12.10])   // no tag = input time
    }

    // review #9: toggles compute from the current value, in a stable order
    @Test func retirerToggle() {
        let order = ["guitar", "bass", "piano", "drums", "other"]
        #expect(Retirer.toggled(["guitar"], "bass", on: true, order: order) == "guitar;bass")
        #expect(Retirer.toggled(["bass", "guitar"], "guitar", on: false, order: order) == "bass")
        #expect(Retirer.toggled([], "other", on: true, order: order) == "other")
    }
}
