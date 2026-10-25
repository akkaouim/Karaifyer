import Foundation
import Testing
@testable import KaraifyerCore

struct VideoSceneTests {
    func scene(bars n: Int) -> VideoScene {
        let bars = (0..<n).map { VideoScene.Bar(start: 4.0 + Double($0) * 2, beats: 4, chords: [ChordAt(beat: 0, label: "C")]) }
        let beats = (0..<(n * 4 + 8)).map { Double($0) * 0.5 }
        return VideoScene(version: 1, layout: "grille", titre: "T", artiste: "A", key: "C major", padS: 4, totalS: 4 + Double(n) * 2,
                          beats: beats, bars: bars, states: [VideoScene.State(start: 0, end: 100, kind: "ligne", current: "la", next: "",
                          countdown: nil, lit: 0, chords: [], chart: [], chartPos: nil, nextChords: [])])
    }

    @Test func pagingKeepsTheActiveRowOnTop() {
        let s = scene(bars: 10)
        #expect(VideoClock.grid(s, at: 4.1)!.rows == [[0, 1, 2, 3], [4, 5, 6, 7]])
        let g = VideoClock.grid(s, at: 12.6)!                        // bar 4 (starts 12.0), beat 2
        #expect(g.rows == [[4, 5, 6, 7], [8, 9]] && g.activeBar == 4 && g.activeBeat == 1)
    }

    @Test func pagingEdges() {
        let s = scene(bars: 10)
        #expect(VideoClock.grid(s, at: 1.0)!.activeBar == nil)          // count-in: first 8 bars, none active
        #expect(VideoClock.grid(s, at: 999)!.rows.first == [8, 9])       // past the end: last row
        #expect(VideoClock.grid(scene(bars: 1), at: 4.5)!.rows == [[0]])
    }

    @Test func gridWithoutBars() {
        #expect(VideoClock.grid(scene(bars: 0), at: 5) == nil)
    }

    @Test func animationIsDeterministicAndPeaksOnBeatOne() {
        #expect(VideoClock.titleBrightness(t: 12.34) == VideoClock.titleBrightness(t: 12.34))
        let beats = [0.0, 0.5, 1.0, 1.5, 2.0]
        let down = VideoClock.frameGlow(t: 2.01, beats: beats, downbeats: [4])
        let other = VideoClock.frameGlow(t: 1.51, beats: beats, downbeats: [4])
        #expect(down > other && other > VideoClock.frameGlow(t: 1.95, beats: beats, downbeats: [4]))
    }

    @Test func chordTransposition() {
        #expect(ChordText.transpose("Em", by: 1, flats: true) == "Fm")
        #expect(ChordText.transpose("D/F#", by: 1, flats: true) == "Eb/G")
        #expect(ChordText.transpose("Asus4", by: 2, flats: false) == "Bsus4")
        #expect(ChordText.transpose("N.C.", by: 3, flats: false) == "N.C.")
        #expect(ChordText.prefersFlats(key: "C major", shift: -2) == true)    // Bb major
        #expect(ChordText.prefersFlats(key: "C major", shift: 2) == false)    // D major
    }

    @Test func decodesTheSceneJSON() throws {
        let json = #"{"version":1,"layout":"grille","titre":"T","artiste":"A","key":null,"pad_s":4.8,"total_s":10,"beats":[0.4],"bars":[{"start":4.8,"beats":4,"chords":[[0,"Fm"]]}],"states":[{"start":0,"end":4,"kind":"titre","current":"T","next":"","countdown":null,"lit":0,"chords":[[3,"Am"]],"chart":["Am"],"chart_pos":0,"next_chords":[]}]}"#
        let s = try JSONDecoder.snake.decode(VideoScene.self, from: Data(json.utf8))
        #expect(s.padS == 4.8 && s.bars[0].chords[0].label == "Fm" && s.states[0].chords[0].label == "Am" && s.states[0].chartPos == 0)
    }

    @Test func beatPulseIsSubtle() {
        let beats = [0.0, 0.5, 1.0, 1.5, 2.0]
        let peak = VideoClock.frameGlow(t: 2.0, beats: beats, downbeats: [4])
        let rest = VideoClock.frameGlow(t: 1.95, beats: beats, downbeats: [4])
        #expect(peak - rest < 0.3 && rest >= 0.7)                    // a gentle swell, never a flash
    }

    @Test func unusualChordNamesAreTransposedToo() {
        #expect(ChordText.transpose("C6/9", by: 2, flats: false) == "D6/9")          // « /9 » is not a bass note
        #expect(ChordText.transpose("C7(#9)", by: 2, flats: false) == "D7(#9)")
        #expect(ChordText.transpose("Cmaj7#11/E", by: 2, flats: false) == "Dmaj7#11/F#")
        #expect(ChordText.transpose("H7", by: 1, flats: false) == "C7")              // German H = B
        #expect(ChordText.transpose("Bbsus2/4", by: 2, flats: false) == "Csus2/4")
        #expect(ChordText.transpose("la", by: 2, flats: false) == "la")               // not a chord: unchanged
    }
}
