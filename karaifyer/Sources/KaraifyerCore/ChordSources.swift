import Foundation

/// Chordonomicon's raw progression (`<verse_1> D A Bmin …`) as French sections in the grid's notation.
public enum ProgressionText {
    static let names = ["intro": "Intro", "verse": "Couplet", "chorus": "Refrain", "prechorus": "Pré-refrain",
                        "pre-chorus": "Pré-refrain", "bridge": "Pont", "outro": "Outro", "solo": "Solo",
                        "instrumental": "Instrumental", "interlude": "Interlude"]

    public static func symbol(_ t: String) -> String {
        var s = t.replacingOccurrences(of: "min", with: "m")
        s = s.replacingOccurrences(of: #"(?<=[A-G])s"#, with: "#", options: .regularExpression)
        return s
    }

    public static func sections(_ raw: String) -> [(title: String, chords: String)] {
        let re = try! NSRegularExpression(pattern: #"<([a-z_-]+?)_(\d+)>([^<]*)"#)
        let ns = raw as NSString
        return re.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { m in
            let kind = ns.substring(with: m.range(at: 1)), n = ns.substring(with: m.range(at: 2))
            let title = (names[kind] ?? kind.prefix(1).uppercased() + kind.dropFirst()) + " " + n
            let chords = ns.substring(with: m.range(at: 3)).split(separator: " ").map { symbol(String($0)) }.joined(separator: " ")
            return (title, chords)
        }
    }
}

/// `karaoke grilles fusionner --json`.
public struct MergeResult: Decodable, Equatable, Sendable {
    public var cells: [String]
    public var flagged: [Int]
    public var placed, repeated, vocab: Int
    public var source: String
    public var summary: String {
        let f = flagged.count
        return "\(placed) accords placés sur les paroles, \(repeated) complétés par répétition, \(f) mesure\(f > 1 ? "s" : "") à vérifier"
    }
}
