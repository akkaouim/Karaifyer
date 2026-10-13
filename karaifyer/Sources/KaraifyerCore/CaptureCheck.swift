import Foundation

/// Tells a broken capture from real silences in a song. Row 19 (Brassens) had 43 ms of digital silence
/// every 85 ms — half of every 4096-frame IO buffer empty — identical in every take, so the old
/// « same gap in two takes = part of the master » rule kept a file missing half its audio.
public enum CaptureCheck {
    public static let maxGaps = 30          // real masters: a handful of silences at most
    public static let maxSilentShare = 0.05 // or 5 % of the song

    public static func isFault(gaps: [(at: Double, ms: Double)], durationS: Double) -> Bool {
        let total = gaps.reduce(0) { $0 + $1.ms } / 1000
        return gaps.count >= maxGaps || (durationS > 0 && total / durationS >= maxSilentShare)
    }

    /// One log line instead of one per silence.
    public static func summary(_ gaps: [(at: Double, ms: Double)]) -> String {
        guard let first = gaps.first else { return "aucun silence" }
        if gaps.count == 1 { return String(format: "1 silence (%.0f ms) à %.2fs", first.ms, first.at) }
        let mean = gaps.reduce(0) { $0 + $1.ms } / Double(gaps.count)
        let spacing = (gaps[gaps.count - 1].at - first.at) / Double(gaps.count - 1) * 1000
        return String(format: "%d silences (%.0f ms en moyenne, toutes les %.0f ms)", gaps.count, mean, spacing)
    }
}
