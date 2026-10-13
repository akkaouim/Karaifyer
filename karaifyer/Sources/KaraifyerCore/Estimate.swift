import Foundation

public enum Estimate {
    /// Seconds left: songs left (current included) × mean measured song time (7 min when nothing
    /// is measured yet), minus the time already spent on the current song.
    public static func remaining(songsLeft: Int, currentElapsed: Double, measuredSongSeconds: [Double]) -> Double {
        let per = measuredSongSeconds.isEmpty ? 420 : measuredSongSeconds.reduce(0, +) / Double(measuredSongSeconds.count)
        return max(0, Double(songsLeft) * per - currentElapsed)
    }
}
