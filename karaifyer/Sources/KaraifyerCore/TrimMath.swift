import Foundation

/// Decides which slice of a raw capture is the actual track.
///
/// The capture is armed before Spotify starts playing and stopped a little
/// after the track ends (possibly with a few hundred ms of the next track).
/// While Spotify is paused the tap delivers exact digital zeros, so the start
/// is the first non-zero sample. (An earlier −70 dBFS threshold cut quiet
/// fade-ins.) The length is Spotify's reported duration, exact to the
/// millisecond, so any bleed from the following track is cut off.
public enum TrimMath {
    public static let defaultThreshold: Float = 0 // first non-zero sample

    /// First frame index whose absolute sample value (any channel) exceeds `threshold`.
    /// `samples` is interleaved, `channels` per frame.
    public static func firstLoudFrame(_ samples: UnsafeBufferPointer<Float>, channels: Int,
                                      threshold: Float = defaultThreshold) -> Int? {
        var i = 0
        while i < samples.count {
            if abs(samples[i]) > threshold { return i / channels }
            i += 1
        }
        return nil
    }

    /// Returns (startFrame, frameCount) within a capture of `totalFrames`.
    public static func trimRange(firstLoud: Int, totalFrames: Int, sampleRate: Double,
                                 durationMs: Int, preRollMs: Double = 0) -> (start: Int, count: Int) {
        let preRoll = Int(preRollMs / 1000 * sampleRate)
        let start = max(0, firstLoud - preRoll)
        let wanted = Int((Double(durationMs) / 1000 * sampleRate).rounded())
        return (start, max(0, min(wanted, totalFrames - start)))
    }

    /// Finds playback glitches: runs of exact digital zeros (all channels) at
    /// least `minFrames` long but shorter than `maxFrames`, with audio on both
    /// sides. Real music never contains these; Spotify stalls and dropped IO
    /// cycles do. Returns the start frame of each run. Stateful across chunks.
    public struct DropoutScanner {
        let channels: Int
        let minFrames: Int
        let maxFrames: Int
        var frame = 0
        var zeroRun = 0
        var heardAudio = false
        /// A qualifying zero run that ended on quiet samples; confirmed if loud
        /// audio returns within `maxFrames` (playback resumed after a stall).
        var candidate: (start: Int, end: Int)?
        public private(set) var dropouts: [Int] = []
        /// Length in frames of each entry in `dropouts`.
        public private(set) var dropoutLengths: [Int] = []

        public init(channels: Int, sampleRate: Double, minMs: Double = 1.3, maxMs: Double = 500) {
            self.channels = channels
            self.minFrames = Int(sampleRate * minMs / 1000)
            self.maxFrames = Int(sampleRate * maxMs / 1000)
        }

        /// `samples` interleaved.
        public mutating func feed(_ samples: UnsafeBufferPointer<Float>) {
            var i = 0
            while i + channels <= samples.count {
                var allZero = true
                var loud = false
                for c in 0..<channels {
                    let v = samples[i + c]
                    if v != 0 { allZero = false }
                    if abs(v) > 0.001 { loud = true } // −60 dBFS
                }
                if allZero {
                    zeroRun += 1
                } else {
                    if zeroRun >= minFrames && zeroRun < maxFrames && heardAudio {
                        candidate = (frame - zeroRun, frame)
                    }
                    zeroRun = 0
                    if loud {
                        if let c = candidate {
                            dropouts.append(c.start); dropoutLengths.append(c.end - c.start); candidate = nil
                        }
                        heardAudio = true
                    } else if let c = candidate, frame - c.end > maxFrames {
                        candidate = nil
                    }
                }
                frame += 1
                i += channels
            }
        }
    }
}
