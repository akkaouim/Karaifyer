import Foundation

/// Michel's bar-grid fix, the file mesures/<id>.json (karaoke/barfix.py reads it).
public struct BarFix: Codable, Equatable, Sendable {
    public var signature: String?
    public var swing: Bool
    public var pins: [Double]
    public init(signature: String?, swing: Bool, pins: [Double]) { self.signature = signature; self.swing = swing; self.pins = pins }
    public static let empty = BarFix(signature: nil, swing: false, pins: [])
    public var isEmpty: Bool { signature == nil && !swing && pins.isEmpty }
    public static func decode(_ data: Data?) -> BarFix {
        guard let data, let f = try? JSONDecoder().decode(BarFix.self, from: data) else { return .empty }
        return BarFix(signature: BarGrid.menu.contains(f.signature ?? "") ? f.signature : nil, swing: f.swing, pins: f.pins)
    }
    public func encoded() -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}

/// The bar-line rule of karaoke/barfix.py, on beat indices (see that module's docstring).
public enum BarGrid {
    public static let menu = ["2/4", "3/4", "4/4", "6/8", "12/8"]
    static let counts = ["2/4": 2, "3/4": 3, "4/4": 4, "6/8": 2, "12/8": 4]

    public static func beatsInBar(signature: String?, detected: Int, bpm: Double) -> Int {
        guard let s = signature, let n = counts[s] else { return detected }
        return s.hasSuffix("/8") && bpm > 120 ? n * 3 : n
    }

    public static func nearest(_ beats: [Double], _ t: Double) -> Int {
        beats.indices.min { abs(beats[$0] - t) < abs(beats[$1] - t) } ?? 0
    }

    public static func lines(beats: [Double], detected: [Double], fix: BarFix, detectedBPB: Int, bpm: Double) -> (lines: [Int], bpb: Int) {
        let n = beatsInBar(signature: fix.signature, detected: detectedBPB, bpm: bpm)
        let det = Array(Set(detected.map { nearest(beats, $0) })).sorted()
        guard !beats.isEmpty else { return (det, n) }
        var anchors = Array(Set(fix.pins.map { nearest(beats, $0) })).sorted()
        if fix.signature != nil, let first = det.first, anchors.first.map({ $0 >= first + n }) ?? true {
            anchors = Array(Set(anchors + [first])).sorted()
        }
        guard let a0 = anchors.first else { return (det, n) }
        var out = det.filter { $0 < a0 }
        for (k, a) in anchors.enumerated() {
            let end = k + 1 < anchors.count ? anchors[k + 1] : beats.count
            out += Array(stride(from: a, to: end, by: max(n, 1)))
        }
        return (out, n)
    }

    public static func starts(_ lines: [Int]) -> [Int] { lines.first == 0 ? lines : [0] + lines }

    static func pinIndex(_ fix: BarFix, beats: [Double], line: Int) -> Int? {
        fix.pins.firstIndex { nearest(beats, $0) == line }
    }

    public static func hasPin(_ fix: BarFix, beats: [Double], line: Int) -> Bool { pinIndex(fix, beats: beats, line: line) != nil }

    public static func moved(_ fix: BarFix, beats: [Double], line: Int, by delta: Int) -> BarFix {
        let to = line + delta
        guard beats.indices.contains(line), to >= 1, to < beats.count else { return fix }
        var f = fix
        if let i = pinIndex(fix, beats: beats, line: line) { f.pins.remove(at: i) }
        f.pins = Array(Set(f.pins + [beats[to]])).sorted()
        return f
    }

    public static func pinned(_ fix: BarFix, beats: [Double], line: Int) -> BarFix {
        guard beats.indices.contains(line), !hasPin(fix, beats: beats, line: line) else { return fix }
        var f = fix; f.pins = (f.pins + [beats[line]]).sorted(); return f
    }

    public static func unpinned(_ fix: BarFix, beats: [Double], line: Int) -> BarFix {
        var f = fix; f.pins.removeAll { nearest(beats, $0) == line }; return f
    }

    /// Chords re-cut beat by beat into new bars; nil when a cell doesn't parse.
    public static func recut(cells: [String], from old: [Int], oldBPB: Int, to new: [Int], newBPB: Int, beatCount: Int) -> [String]? {
        var labels: [String?] = []
        var cur: String? = nil
        for (k, start) in old.enumerated() where k < cells.count {
            let len = (k + 1 < old.count ? old[k + 1] : beatCount) - start
            guard case .success(let ch) = ChordGrid.parseCell(cells[k], beatsPerBar: oldBPB) else { return nil }
            let marks = Dictionary(ch.map { ($0.beat, $0.label) }, uniquingKeysWith: { a, _ in a })
            for i in 0..<max(len, 0) { cur = marks[i] ?? cur; labels.append(cur) }
        }
        while labels.count < beatCount { labels.append(cur) }
        return new.enumerated().map { k, start in
            let end = min(k + 1 < new.count ? new[k + 1] : beatCount, labels.count)
            var chords: [ChordAt] = []
            var prev: String?? = .none
            for j in start..<max(start, end) {
                let l = labels[j] ?? "N.C."
                if prev == .none || prev! != l { chords.append(ChordAt(beat: j - start, label: l)) }
                prev = .some(l)
            }
            return chords.isEmpty ? "N.C." : ChordGrid.cellText(chords, beatsPerBar: newBPB)
        }
    }

    public static func beatInBar(index: Int?, starts: [Int], beatCount: Int) -> (beat: Int, of: Int)? {
        guard let i = index, let k = starts.lastIndex(where: { $0 <= i }) else { return nil }
        let end = k + 1 < starts.count ? starts[k + 1] : beatCount
        return (i - starts[k] + 1, end - starts[k])
    }
}
