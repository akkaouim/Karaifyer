import Foundation

/// The pipeline's click sound (karaoke/grid.py render_click): 25 ms sine bursts, 6 ms decay,
/// 1600 Hz × 0.9 on bar lines, 1000 Hz × 0.6 on other beats; for the editor's « Clic ».
public enum ClickTrack {
    public static let sampleRate = 44100

    public static func samples(beats: [Double], accents: Set<Int>, duration: Double) -> [Float] {
        let total = max(0, Int(duration * Double(sampleRate)))
        var out = [Float](repeating: 0, count: total)
        let n = Int(0.025 * Double(sampleRate))
        func burst(_ f: Double, _ a: Double) -> [Float] {
            (0..<n).map { i in let t = Double(i) / Double(sampleRate); return Float(a * sin(2 * .pi * f * t) * exp(-t / 0.006)) }
        }
        let hi = burst(1600, 0.9), lo = burst(1000, 0.6)
        for (k, b) in beats.enumerated() {
            let i = Int((b * Double(sampleRate)).rounded())
            guard i >= 0, i < total else { continue }
            let src = accents.contains(k) ? hi : lo
            for j in 0..<min(n, total - i) { out[i + j] = max(-1, min(1, out[i + j] + src[j])) }
        }
        return out
    }

    public static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}
