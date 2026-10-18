import Foundation
import Testing
@testable import KaraifyerCore

struct BarGridTests {
    let beats = (0..<32).map { Double($0) * 0.5 }
    var down: [Double] { stride(from: 0, to: 32, by: 4).map { beats[$0] } }

    @Test func noFixKeepsTheDetection() {
        let r = BarGrid.lines(beats: beats, detected: down, fix: .empty, detectedBPB: 4, bpm: 100)
        #expect(r.lines == Array(stride(from: 0, to: 32, by: 4)) && r.bpb == 4)
    }

    @Test func aPinRestartsTheCount() {
        let f = BarFix(signature: nil, swing: false, pins: [9.1])
        #expect(BarGrid.lines(beats: beats, detected: down, fix: f, detectedBPB: 4, bpm: 100).lines == [0, 4, 8, 12, 16, 18, 22, 26, 30])
    }

    @Test func signatureRegroups() {
        let f = BarFix(signature: "3/4", swing: false, pins: [])
        let r = BarGrid.lines(beats: beats, detected: down, fix: f, detectedBPB: 4, bpm: 100)
        #expect(r.bpb == 3 && r.lines == Array(stride(from: 0, to: 32, by: 3)))
    }

    @Test func compoundMeters() {
        #expect(BarGrid.beatsInBar(signature: "6/8", detected: 4, bpm: 100) == 2)
        #expect(BarGrid.beatsInBar(signature: "6/8", detected: 4, bpm: 140) == 6)
        #expect(BarGrid.beatsInBar(signature: "12/8", detected: 4, bpm: 121) == 12)
        #expect(BarGrid.beatsInBar(signature: nil, detected: 3, bpm: 100) == 3)
    }

    @Test func earlyPinReplacesImplicitAnchor() {
        let f = BarFix(signature: "4/4", swing: false, pins: [1.5])
        #expect(BarGrid.lines(beats: beats, detected: Array(down.dropFirst()), fix: f, detectedBPB: 4, bpm: 100).lines.prefix(3) == [3, 7, 11])
    }

    @Test func pinsDedupeAndClamp() {
        let f = BarFix(signature: nil, swing: false, pins: [9.0, 9.1, 8.9, 99, -3])
        let l = BarGrid.lines(beats: beats, detected: down, fix: f, detectedBPB: 4, bpm: 100).lines
        #expect(l == Array(Set(l)).sorted() && l.first == 0 && l.last! < beats.count)
    }

    @Test func moveAndPin() {
        var f = BarGrid.moved(.empty, beats: beats, line: 16, by: 1)
        #expect(f.pins == [8.5])
        f = BarGrid.moved(f, beats: beats, line: 17, by: 1)                 // moves the existing pin
        #expect(f.pins == [9.0] && BarGrid.hasPin(f, beats: beats, line: 18))
        f = BarGrid.pinned(f, beats: beats, line: 4)
        #expect(f.pins == [2.0, 9.0])
        #expect(BarGrid.unpinned(f, beats: beats, line: 18).pins == [2.0])
        #expect(BarGrid.moved(.empty, beats: beats, line: 0, by: -1) == .empty)   // out of range: unchanged
    }

    @Test func recutKeepsChordsOnTheirBeats() {
        // 4 bars of 4 → a pin at beat 6: bars [0,4) [4,6) [6,10) [10,14) [14,16)
        let cells = ["C", "F", "G", "Am"]
        let new = [0, 4, 6, 10, 14]
        let r = BarGrid.recut(cells: cells, from: [0, 4, 8, 12], oldBPB: 4, to: new, newBPB: 4, beatCount: 16)!
        #expect(r.count == new.count)
        #expect(r == ["C", "F", "F G", "G Am", "Am"])
        #expect(BarGrid.recut(cells: ["C", "H"], from: [0, 4], oldBPB: 4, to: [0], newBPB: 4, beatCount: 8) == nil)
    }

    @Test func beatCounter() {
        #expect(BarGrid.beatInBar(index: 5, starts: [0, 4, 6], beatCount: 10)! == (2, 2))
        #expect(BarGrid.beatInBar(index: 7, starts: [0, 4, 6], beatCount: 10)! == (2, 4))
        #expect(BarGrid.beatInBar(index: nil, starts: [0], beatCount: 10) == nil)
    }

    @Test func fixFileRoundTrip() {
        let f = BarFix(signature: "12/8", swing: true, pins: [3.5])
        #expect(BarFix.decode(f.encoded()) == f)
        #expect(BarFix.decode(Data("nope".utf8)) == .empty && BarFix.decode(nil) == .empty)
        #expect(BarFix.empty.isEmpty && !f.isEmpty)
    }

    @Test func offBeatDetectedLinesAreIgnoredLikeThePipeline() {
        let r = BarGrid.lines(beats: beats, detected: [0, 1.7, 2, 4], fix: .empty, detectedBPB: 4, bpm: 100)
        #expect(r.lines == [0, 4, 8])
    }

    @Test func gridMatchesTheSongsBarsByPosition() {
        #expect(BarGrid.matches(starts: [0, 4, 8], beats: beats, bars: [0, 2, 4.0004]))
        #expect(!BarGrid.matches(starts: [0, 4, 8], beats: beats, bars: [0, 2.5, 4]))     // same count, moved line
        #expect(!BarGrid.matches(starts: [0, 4], beats: beats, bars: [0, 2, 4]))
    }
}
