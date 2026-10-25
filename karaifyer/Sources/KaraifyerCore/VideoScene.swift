import Foundation

/// The lyrics video as data (sortie/<dossier>/video.json, written by the pipeline's video step): display states from
/// its tested timeline code, beats and bars, all in show time. One renderer draws it live, for export and for the
/// pipeline (`karaifyer-render`).
public struct VideoScene: Codable, Equatable, Sendable {
    public struct Bar: Codable, Equatable, Sendable {
        public var start: Double
        public var beats: Int
        public var chords: [ChordAt]          // [beat index in the bar, symbol]
    }

    public struct State: Codable, Equatable, Sendable {
        public var start, end: Double
        public var kind: String               // titre | ligne | instrumental | fin
        public var current, next: String
        public var countdown: Int?
        public var lit: Int
        public var chords: [ChordAt]          // [character offset, symbol] above the current line
        public var chart: [String]            // the 4-bar row (chords-over-lyrics layout, instrumentals)
        public var chartPos: Int?
        public var nextChords: [ChordAt]
    }

    public var version: Int
    public var layout: String
    public var titre, artiste: String
    public var key: String?
    public var padS, totalS: Double
    public var beats: [Double]
    public var bars: [Bar]
    public var states: [State]

    public static func load(url: URL) throws -> VideoScene {
        try JSONDecoder.snake.decode(VideoScene.self, from: Data(contentsOf: url))
    }

    /// Beat indices where a bar starts (the beat nearest each bar line): beat 1, for the stronger frame pulse.
    public var downbeatIndices: Set<Int> {
        Set(bars.compactMap { bar in beats.indices.min { abs(beats[$0] - bar.start) < abs(beats[$1] - bar.start) } })
    }
}

extension JSONDecoder {
    public static var snake: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// Everything the renderer needs to know about time `t`: pure functions, so live playback and export agree.
public enum VideoClock {
    public struct Grid: Equatable, Sendable {
        public var rows: [[Int]]              // bar indices: the active row first (always on top), then the next 4
        public var activeBar: Int?
        public var activeBeat: Int?
    }

    public static func state(_ s: VideoScene, at t: Double) -> VideoScene.State? {
        var lo = 0, hi = s.states.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if s.states[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found.map { s.states[$0] } ?? s.states.first
    }

    /// The active row stays on top: when it ends, the row below moves up and the next 4 bars appear underneath.
    public static func grid(_ s: VideoScene, at t: Double) -> Grid? {
        guard !s.bars.isEmpty else { return nil }
        let b = s.bars.lastIndex { $0.start <= t + 1e-6 }
        let row0 = min((b ?? 0) / 4 * 4, (s.bars.count - 1) / 4 * 4)
        let rows = [Array(row0..<min(row0 + 4, s.bars.count)), Array(min(row0 + 4, s.bars.count)..<min(row0 + 8, s.bars.count))]
            .filter { !$0.isEmpty }
        var beat: Int?
        if let b {
            let bar = s.bars[b]
            let n = s.beats.filter { $0 >= bar.start - 1e-3 && $0 <= t + 1e-6 }.count
            beat = max(0, min(bar.beats - 1, n - 1))
        }
        return Grid(rows: rows, activeBar: b, activeBeat: beat)
    }

    /// The title neon breathes (4 s) and flickers briefly once in each 7 s window, at a fixed offset per window.
    public static func titleBrightness(t: Double) -> Double {
        let breath = 0.85 + 0.15 * sin(2 * .pi * t / 4)
        let w = Int(floor(t / 7))
        let h = UInt32(truncatingIfNeeded: w &* 2_654_435_761)
        let offset = Double(h % 6000) / 1000
        let s = Double(w) * 7 + offset
        return (t >= s && t < s + 0.12) ? breath * 0.35 / 0.85 : breath
    }

    /// The frame swells gently on each beat, a little more on beat 1, decaying over about 0.25 s — a subtle pulse
    /// around a steady glow, so it marks the tempo without drawing the eye.
    public static func frameGlow(t: Double, beats: [Double], downbeats: Set<Int>) -> Double {
        guard let i = beats.lastIndex(where: { $0 <= t }) else { return 0.75 }
        let amp = downbeats.contains(i) ? 1.6 : 1.0
        return min(1, 0.75 + 0.12 * amp * exp(-(t - beats[i]) / 0.25))
    }
}

/// Chord symbols moved by semitones for the Lecteur's « Hauteur » (display only), spelled for the new key.
public enum ChordText {
    static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flats = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    static let pcs: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    static func pc(_ note: String) -> Int? {
        guard let first = note.first, let base = pcs[String(first)] else { return nil }
        return (base + note.dropFirst().reduce(0) { $0 + ($1 == "#" ? 1 : $1 == "b" ? -1 : 0) } + 12) % 12
    }

    public static func transpose(_ symbol: String, by n: Int, flats useFlats: Bool) -> String {
        guard n % 12 != 0, symbol != "N.C.",
              let m = symbol.wholeMatch(of: /([A-G][#b]?)([^\/]*)(?:\/([A-G][#b]?))?/),
              let root = pc(String(m.1)) else { return symbol }
        let names = useFlats ? flats : sharps
        var out = names[(root + n % 12 + 12) % 12] + m.2
        if let b = m.3, let bass = pc(String(b)) { out += "/" + names[(bass + n % 12 + 12) % 12] }
        return out
    }

    /// The key after the shift is a flat key (Db Eb F Gb Ab Bb major, or their relative minors).
    public static func prefersFlats(key: String?, shift: Int) -> Bool {
        guard let key, let m = key.wholeMatch(of: /([A-G][#b]?)\s+(major|minor)/), let root = pc(String(m.1)) else {
            return false
        }
        let tonic = (root + (m.2 == "minor" ? 3 : 0) + shift % 12 + 24) % 12
        return [1, 3, 5, 6, 8, 10].contains(tonic)
    }
}
