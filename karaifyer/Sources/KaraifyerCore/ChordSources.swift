import Foundation

/// Chordonomicon's raw progression (`<verse_1> D A Bmin …`) as French sections in the grid's notation.
public enum ProgressionText {
    static let names = ["intro": "Intro", "verse": "Couplet", "chorus": "Refrain", "prechorus": "Pré-refrain",
                        "pre-chorus": "Pré-refrain", "bridge": "Pont", "outro": "Outro", "solo": "Solo",
                        "instrumental": "Instrumental", "interlude": "Interlude"]

    public static func symbol(_ t: String) -> String {
        var s = t.replacingOccurrences(of: "min", with: "m")
        // Chordonomicon's sharp is « s » right after a root (Fs, D/Fs) — never the « s » of « sus »
        s = s.replacingOccurrences(of: #"(?<=^[A-G])s(?!us)|(?<=/[A-G])s(?!us)"#, with: "#", options: .regularExpression)
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

extension ProgressionText {
    /// The sections as lines of text (« Couplet 1 : Fm Ab »).
    public static func plain(_ raw: String) -> String {
        sections(raw).map { "\($0.title) : \($0.chords)" }.joined(separator: "\n")
    }
}

/// `karaoke grilles voir --json`: an open chart as text, in the song's key and as written.
public struct ChartText: Decodable, Equatable, Sendable {
    public var source, texte, original: String
    public var transposition: Int
    public init(source: String, texte: String, original: String, transposition: Int) {
        self.source = source; self.texte = texte; self.original = original; self.transposition = transposition
    }
    public var shift: String {
        guard transposition != 0 else { return "dans sa tonalité d'origine" }
        let n = abs(transposition)
        return "transposée de \(transposition > 0 ? "+" : "−")\(n) demi-ton\(n > 1 ? "s" : "") dans la tonalité du morceau"
    }
}
