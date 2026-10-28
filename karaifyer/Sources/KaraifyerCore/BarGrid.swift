import Foundation

/// Michel's bar-grid fix, the file mesures/<id>.json (karaoke/barfix.py reads it).
public struct BarFix: Codable, Equatable, Sendable {
    public var signature: String?
    public var swing: Bool
    public var pins: [Double]
    /// Bar lines locked where they are: the detected bar lines follow them, not a recount (files before locks have none).
    public var locks: [Double]
    public init(signature: String?, swing: Bool, pins: [Double], locks: [Double] = []) {
        self.signature = signature; self.swing = swing; self.pins = pins; self.locks = locks
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(signature: try c.decodeIfPresent(String.self, forKey: .signature), swing: try c.decodeIfPresent(Bool.self, forKey: .swing) ?? false,
                  pins: try c.decodeIfPresent([Double].self, forKey: .pins) ?? [], locks: try c.decodeIfPresent([Double].self, forKey: .locks) ?? [])
    }
    public static let empty = BarFix(signature: nil, swing: false, pins: [])
    public var isEmpty: Bool { signature == nil && !swing && pins.isEmpty && locks.isEmpty }
    public static func decode(_ data: Data?) -> BarFix {
        guard let data, let f = try? JSONDecoder().decode(BarFix.self, from: data) else { return .empty }
        return BarFix(signature: BarGrid.menu.contains(f.signature ?? "") ? f.signature : nil, swing: f.swing, pins: f.pins, locks: f.locks)
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
        let det = onBeat(beats, detected)
        let ev = events(beats: beats, det: det, fix: fix, n: n)
        guard let a0 = ev.first?.at else { return (det, n) }
        var out = det.filter { $0 < a0 }
        for (k, e) in ev.enumerated() {
            let end = k + 1 < ev.count ? ev[k + 1].at : beats.count
            out += e.counted ? Array(stride(from: e.at, to: end, by: max(n, 1))) : [e.at] + det.filter { $0 > e.at && $0 < end }
        }
        return (out, n)
    }

    /// Only detected lines that sit on a beat (to 1 ms, like barfix.on_beat / chords.bars_from), as beat indices.
    static func onBeat(_ beats: [Double], _ detected: [Double]) -> [Int] {
        let index = Dictionary(beats.enumerated().map { (Int(($0.element * 1000).rounded()), $0.offset) }, uniquingKeysWith: { a, _ in a })
        return Array(Set(detected.compactMap { index[Int(($0 * 1000).rounded())] })).sorted()
    }

    /// Where the grid changes rule: anchors (pins, the signature's implicit first line) start a count every N beats;
    /// locks keep the detected lines. A pin and a lock on the same beat count as the pin.
    static func events(beats: [Double], det: [Int], fix: BarFix, n: Int) -> [(at: Int, counted: Bool)] {
        guard !beats.isEmpty else { return [] }
        var anchors = Set(fix.pins.map { nearest(beats, $0) })
        if fix.signature != nil, let first = det.first, anchors.min().map({ $0 >= first + n }) ?? true { anchors.insert(first) }
        let locks = Set(fix.locks.map { nearest(beats, $0) }).subtracting(anchors)
        return (anchors.map { ($0, true) } + locks.map { ($0, false) }).sorted { $0.0 < $1.0 }
    }

    /// The grid as the editor computes it is the song's grid (same bar positions, 1 ms): else etat is stale.
    public static func matches(starts: [Int], beats: [Double], bars: [Double]) -> Bool {
        starts.count == bars.count && zip(starts, bars).allSatisfy { beats.indices.contains($0) && abs(beats[$0] - $1) < 0.001 }
    }

    public static func starts(_ lines: [Int]) -> [Int] { lines.first == 0 ? lines : [0] + lines }

    public static func hasPin(_ fix: BarFix, beats: [Double], line: Int) -> Bool {
        (fix.pins + fix.locks).contains { nearest(beats, $0) == line }
    }

    /// Moving a bar line pins it at its new beat (dropping any pin or lock it had): the bars after it are recounted.
    public static func moved(_ fix: BarFix, beats: [Double], line: Int, by delta: Int) -> BarFix {
        let to = line + delta
        guard beats.indices.contains(line), to >= 1, to < beats.count else { return fix }
        var f = unpinned(fix, beats: beats, line: line)
        f.pins = Array(Set(f.pins + [beats[to]])).sorted()
        return f
    }

    /// Locking a bar never moves one: in a stretch counted every N beats it becomes a pin (on that count already),
    /// elsewhere a lock (the detected lines go on after it).
    public static func locked(_ fix: BarFix, beats: [Double], detected: [Double], detectedBPB: Int, bpm: Double, line: Int) -> BarFix {
        guard beats.indices.contains(line), !hasPin(fix, beats: beats, line: line) else { return fix }
        let n = beatsInBar(signature: fix.signature, detected: detectedBPB, bpm: bpm)
        let counted = events(beats: beats, det: onBeat(beats, detected), fix: fix, n: n).last { $0.at <= line }?.counted ?? false
        var f = fix
        if counted { f.pins = (f.pins + [beats[line]]).sorted() } else { f.locks = (f.locks + [beats[line]]).sorted() }
        return f
    }

    public static func unpinned(_ fix: BarFix, beats: [Double], line: Int) -> BarFix {
        var f = fix
        f.pins.removeAll { nearest(beats, $0) == line }
        f.locks.removeAll { nearest(beats, $0) == line }
        return f
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
