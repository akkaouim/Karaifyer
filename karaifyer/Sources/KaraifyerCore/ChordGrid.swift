import Foundation

public struct CellError: Error, Equatable { public let message: String }

/// Chord-grid cells, same syntax as karaoke/chords.py `parse_cell`:
/// `A B` splits the bar evenly; `Am . . F` gives one token per beat, `.` continues the previous chord.
public enum ChordGrid {
    static let symbol = #"^(N\.C\.|[A-G][#b]?(m|maj7|m7b5|m7|m6|7|6|9|dim|aug|sus2|sus4|add9)?(/[A-G][#b]?)?)$"#

    public static func isValidSymbol(_ s: String) -> Bool {
        s.range(of: symbol, options: .regularExpression) != nil
    }

    public static func parseCell(_ cell: String, beatsPerBar: Int) -> Result<[ChordAt], CellError> {
        let toks = cell.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !toks.isEmpty else { return .failure(CellError(message: "mesure vide")) }
        if let bad = toks.first(where: { $0 != "." && !isValidSymbol($0) }) {
            return .failure(CellError(message: "accord non reconnu : \(bad)"))
        }
        if toks.contains(".") {
            guard toks.count == beatsPerBar, toks[0] != "." else {
                return .failure(CellError(message: "\(beatsPerBar) temps attendus, le premier étant un accord"))
            }
            return .success(toks.enumerated().filter { $0.element != "." }.map { ChordAt(beat: $0.offset, label: $0.element) })
        }
        guard toks.count <= beatsPerBar else {
            return .failure(CellError(message: "plus d'accords que de temps (\(beatsPerBar))"))
        }
        return .success(toks.enumerated().map { ChordAt(beat: $0.offset * beatsPerBar / toks.count, label: $0.element) })
    }

    /// Inverse of parseCell: even split → `A B`, otherwise one token per beat.
    public static func cellText(_ chords: [ChordAt], beatsPerBar: Int) -> String {
        let n = max(chords.count, 1)
        if chords.enumerated().allSatisfy({ $0.element.beat == $0.offset * beatsPerBar / n }) {
            return chords.map(\.label).joined(separator: " ")
        }
        var toks = Array(repeating: ".", count: beatsPerBar)
        for c in chords where c.beat < beatsPerBar { toks[c.beat] = c.label }
        return toks.joined(separator: " ")
    }

    /// accords.txt layout (karaoke/steps/chords.py), read back by the pipeline's parse_chart.
    public static func chartText(title: String, artist: String, key: String, bpm: Int?, beatsPerBar: Int,
                                 cells: [String], signature: String? = nil) -> String {
        var head = "\(title) — \(artist)\nTonalité : \(key)"
        if let bpm { head += " · \(bpm) BPM" }
        head += " · \(signature ?? "\(beatsPerBar)/4")\n\n"
        let rows = stride(from: 0, to: cells.count, by: 4).map {
            "| " + cells[$0..<min($0 + 4, cells.count)].joined(separator: " | ") + " |"
        }
        return head + rows.joined(separator: "\n") + "\n"
    }

    /// Bar sounding at input time `t` (nil before the first bar).
    public static func barIndex(at t: Double, bars: [BarInfo]) -> Int? {
        bars.lastIndex { $0.start <= t + 1e-6 }
    }
}
