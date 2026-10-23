import AVFoundation
import Foundation

/// Where the voice starts near a key press: Michel taps each lyric line a little late; the tap is moved onto the
/// first sung sound in `guide_voix.flac` (rise ≥ 12 dB over the noise floor, held 50 ms) within −0.4 / +0.1 s.
public enum VocalOnset {
    public static func envelope(samples: [Float], sampleRate: Double, hop: Double = 0.01) -> [Float] {
        let n = max(1, Int(sampleRate * hop))
        return stride(from: 0, to: samples.count, by: n).map { i in
            let s = samples[i..<min(i + n, samples.count)]
            let rms = sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(max(s.count, 1)))
            return 20 * log10(max(rms, 1e-6))
        }
    }

    /// The first frame in [t − before, t + after] where the voice rises ≥ 12 dB above the quietest level of the
    /// previous 100 ms and stays there 50 ms; nil when there's no such rise (already singing, silence, noise).
    public static func find(envelope e: [Float], hop: Double = 0.01, near t: Double,
                            before: Double = 0.4, after: Double = 0.1) -> Double? {
        let a = max(1, Int((t - before) / hop)), b = min(e.count, Int((t + after) / hop) + 1)
        guard a < b else { return nil }
        let look = 10, hold = 5
        for i in a..<b {
            let floor = e[max(0, i - look)..<i].min() ?? e[i]
            if i + hold <= e.count, e[i..<(i + hold)].allSatisfy({ $0 >= floor + 12 }) {
                return Double(i) * hop
            }
        }
        return nil
    }

    public static func load(url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: f.processingFormat.sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let ch = buf.floatChannelData![0]
        _ = fmt
        return envelope(samples: Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))),
                        sampleRate: f.processingFormat.sampleRate)
    }
}
