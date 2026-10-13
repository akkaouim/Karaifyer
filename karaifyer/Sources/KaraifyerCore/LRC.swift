import Foundation

public struct LyricLine: Equatable, Identifiable, Sendable {
    public let id: UUID           // stable identity for the editor (rows re-sort)
    public var time: Double       // show time, seconds
    public var text: String
    public init(time: Double, text: String) { self.id = UUID(); self.time = time; self.text = text }
    public static func == (a: LyricLine, b: LyricLine) -> Bool { a.time == b.time && a.text == b.text }
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
    public mutating func stamp(_ id: UUID, at t: Double) { edit(id) { $0.time = Self.round(t) } }
    public mutating func setTime(_ id: UUID, _ s: String) {
        guard let t = LRC.parseTimecode(s) else { return }
        edit(id) { $0.time = t }
    }
    public mutating func delete(_ id: UUID) { lines.removeAll { $0.id == id } }
    @discardableResult public mutating func add(at t: Double) -> UUID {
        let l = LyricLine(time: Self.round(t), text: "")
        lines.append(l)
        lines.sort { $0.time < $1.time }
        return l.id
    }
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

    /// Lines in current show time: a file saved with `decalage` d holds show times for pad d, so
    /// t − d + pad (pad_s can change, e.g. a new count-in); no tag = recording (input) time + pad.
    public static func showTimeLines(_ text: String, pad: Double) -> [LyricLine] {
        let (l, dec) = parse(text)
        return l.map { LyricLine(time: (($0.time - (dec ?? 0) + pad) * 100).rounded() / 100, text: $0.text) }
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
