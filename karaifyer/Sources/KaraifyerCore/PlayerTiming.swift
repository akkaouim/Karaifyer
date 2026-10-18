import Foundation

/// Tempo in BPM: the song's typical BPM is the reference; the playback rate is target / song.
public enum Tempo {
    public static func clamp(_ bpm: Double, song: Double) -> Double {
        min(max(bpm, song * 0.5), song * 1.5).rounded()
    }

    public static func rate(target: Double?, song: Double?) -> Float {
        guard let target, let song, song > 0 else { return 1 }
        return Float(target / song)
    }
}

/// Transposition in semitones (tempo unchanged).
public enum Pitch {
    public static func clamp(_ semitones: Int) -> Int { min(6, max(-6, semitones)) }
    public static func cents(_ semitones: Int) -> Float { Float(semitones * 100) }
}

/// Loop points snap to the analysis' bar lines; positions wrap inside the loop.
public enum LoopMath {
    public static func snap(_ t: Double, bars: [Double]) -> Double {
        guard let best = bars.min(by: { abs($0 - t) < abs($1 - t) }) else { return (t * 10).rounded() / 10 }
        return best
    }

    public static func ordered(_ a: Double, _ b: Double) -> (Double, Double) { a <= b ? (a, b) : (b, a) }

    /// Song time after `elapsed` seconds of song time played from `start`, wrapping inside the loop.
    public static func position(start: Double, elapsed: Double, loop: (Double, Double)?) -> Double {
        guard let (a, b) = loop, b > a, start < b else { return start + elapsed }
        let toEnd = b - start
        if elapsed < toEnd { return start + elapsed }
        return a + (elapsed - toEnd).truncatingRemainder(dividingBy: b - a)
    }
}

/// When the slaved video must be re-seeked: at once on any backwards jump of the audio (a loop wrap),
/// otherwise when it drifts more than 40 ms.
public enum VideoSync {
    public static func needsResync(previous: Double, current: Double, video: Double) -> Bool {
        current < previous - 0.05 || abs(video - current) > 0.04
    }
}
