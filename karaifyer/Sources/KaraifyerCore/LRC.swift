import Foundation

public struct LyricLine: Equatable, Sendable {
    public var time: Double       // show time, seconds
    public var text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}

/// The pipeline's LRC dialect: `[karaoke:decalage=x.xxx]` + `[mm:ss.cc]text` lines (karaoke/lrc.py).
public enum LRC {
    public static func parse(_ text: String) -> (lines: [LyricLine], decalage: Double?) {
        var lines: [LyricLine] = []
        var dec: Double?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let r = raw.range(of: #"^\[karaoke:decalage=([0-9.]+)\]"#, options: .regularExpression) {
                dec = Double(raw[r].dropFirst("[karaoke:decalage=".count).dropLast())
                continue
            }
            guard let r = raw.range(of: #"^\[\d+:\d+(\.\d+)?\]"#, options: .regularExpression),
                  let t = parseTimecode(String(raw[r].dropFirst().dropLast())) else { continue }
            lines.append(LyricLine(time: t, text: String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
        return (lines.sorted { $0.time < $1.time }, dec)
    }

    public static func format(_ lines: [LyricLine], decalage: Double) -> String {
        "[karaoke:decalage=\(String(format: "%.3f", decalage))]\n"
            + lines.map { "[\(timecode($0.time))]\($0.text)\n" }.joined()
    }

    public static func timecode(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    public static func parseTimecode(_ s: String) -> Double? {
        let p = s.split(separator: ":")
        guard p.count == 2, let m = Double(p[0]), let sec = Double(p[1]) else { return nil }
        return ((m * 60 + sec) * 100).rounded() / 100
    }
}
