import Foundation

public struct LyricLine: Equatable, Identifiable, Sendable {
    public let id: UUID           // stable identity for the editor (rows re-sort)
    public var time: Double       // show time, seconds
    public var text: String
    public var guessed: Bool      // « à caler »: placed by « Remplacer le texte », aligned on the voice at the analysis
    public init(time: Double, text: String, guessed: Bool = false) {
        self.id = UUID(); self.time = time; self.text = text; self.guessed = guessed
    }
    public static func == (a: LyricLine, b: LyricLine) -> Bool { a.time == b.time && a.text == b.text && a.guessed == b.guessed }
}

/// The editor's lyrics, edited by line identity so a commit lands on the line where editing
/// began even after re-sorting; a late commit for a deleted line is ignored.
public struct LyricsDoc: Sendable {
    public private(set) var lines: [LyricLine]
    public init(lines: [LyricLine]) { self.lines = lines.sorted { $0.time < $1.time } }

    private static func round(_ t: Double) -> Double { (max(0, t) * 100).rounded() / 100 }
    private mutating func edit(_ id: UUID, _ f: (inout LyricLine) -> Void) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        f(&lines[i])
        lines.sort { $0.time < $1.time }
    }

    public mutating func setText(_ id: UUID, _ text: String) { edit(id) { $0.text = text } }
    /// Timing a line by hand clears its « à caler » mark; `guessed` puts it back (a cancelled sync stamp).
    public mutating func stamp(_ id: UUID, at t: Double, guessed: Bool = false) {
        edit(id) { $0.time = Self.round(t); $0.guessed = guessed }
    }
    public mutating func setTime(_ id: UUID, _ s: String) {
        guard let t = LRC.parseTimecode(s) else { return }
        edit(id) { $0.time = t; $0.guessed = false }
    }
    /// ↺ / ↻ in Corriger: the line starts `seconds` earlier or later, never before 0.
    public mutating func shift(_ id: UUID, by seconds: Double) {
        edit(id) { $0.time = Self.round($0.time + seconds); $0.guessed = false }
    }
    public mutating func delete(_ id: UUID) { lines.removeAll { $0.id == id } }
    @discardableResult public mutating func add(at t: Double) -> UUID {
        let l = LyricLine(time: Self.round(t), text: "")
        lines.append(l)
        lines.sort { $0.time < $1.time }
        return l.id
    }
}

/// The pipeline's LRC dialect: `[karaoke:decalage=x.xxx]` + `[mm:ss.cc]text` lines (karaoke/lrc.py), and
/// `[karaoke:a_caler=i,j]`: indices (in file order, from 0) of the timed lines whose time is only a guess.
public enum LRC {
    public static func parse(_ text: String) -> (lines: [LyricLine], decalage: Double?) {
        var lines: [LyricLine] = []
        var dec: Double?
        var guessed = Set<Int>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let r = raw.range(of: #"^\[karaoke:decalage=([0-9.]+)\]"#, options: .regularExpression) {
                dec = Double(raw[r].dropFirst("[karaoke:decalage=".count).dropLast())
                continue
            }
            if let r = raw.range(of: #"^\[karaoke:a_caler=[0-9,]*\]"#, options: .regularExpression) {
                guessed = Set(raw[r].dropFirst("[karaoke:a_caler=".count).dropLast().split(separator: ",").compactMap { Int($0) })
                continue
            }
            guard let r = raw.range(of: #"^\[\d+:\d+(\.\d+)?\]"#, options: .regularExpression),
                  let t = parseTimecode(String(raw[r].dropFirst().dropLast())) else { continue }
            lines.append(LyricLine(time: t, text: String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
        for i in guessed where lines.indices.contains(i) { lines[i].guessed = true }
        return (lines.sorted { $0.time < $1.time }, dec)
    }

    /// After an analysis: the « à caler » lines take the analysed times, when the analysis ran on this very text.
    public static func fillGuessed(_ lines: [LyricLine], from analysed: [LyricLine]) -> [LyricLine] {
        guard lines.contains(where: \.guessed), lines.map(\.text) == analysed.map(\.text) else { return lines }
        return zip(lines, analysed).map { mine, a in
            guard mine.guessed else { return mine }
            var l = mine
            l.time = a.time
            l.guessed = false
            return l
        }
    }

    /// Lines in current show time: a file saved with `decalage` d holds show times for pad d, so
    /// t − d + pad (pad_s can change, e.g. a new count-in); no tag = recording (input) time + pad.
    public static func showTimeLines(_ text: String, pad: Double) -> [LyricLine] {
        let (l, dec) = parse(text)
        return l.map { LyricLine(time: (($0.time - (dec ?? 0) + pad) * 100).rounded() / 100, text: $0.text, guessed: $0.guessed) }
    }

    public static func format(_ lines: [LyricLine], decalage: Double) -> String {
        let guessed = lines.indices.filter { lines[$0].guessed }.map(String.init)
        return "[karaoke:decalage=\(String(format: "%.3f", decalage))]\n"
            + (guessed.isEmpty ? "" : "[karaoke:a_caler=\(guessed.joined(separator: ","))]\n")
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
