import Foundation

/// Tap sync over the lyric lines, followed by identity: Return stamps the active line and moves on; ↑/⌫ gives the
/// last stamped line its previous time back. Lines added or deleted while paused are taken into account
/// (`reconcile`), and the sync order stays the order the lines had when sync started (stamps re-sort the doc).
public struct LyricsSync<ID: Hashable & Sendable>: Sendable {
    public private(set) var ids: [ID]
    private var activePos: Int?
    private var history: [(ID, Double)] = []
    private var startID: ID?

    public init(ids: [ID], startAt: Int = 0) {
        self.ids = ids
        let s = min(max(0, startAt), ids.count)
        activePos = s < ids.count ? s : nil
        startID = s < ids.count ? ids[s] : nil
    }

    /// The next line to stamp (Entrée).
    public var active: ID? { activePos.map { ids[$0] } }
    /// The line being sung: the last one stamped (nil before the first Entrée — the screen stays blank).
    public var current: ID? { history.last?.0 }

    public mutating func stamp(oldTime: Double) -> ID? {
        guard let p = activePos else { return nil }
        history.append((ids[p], oldTime))
        activePos = p + 1 < ids.count ? p + 1 : nil
        return ids[p]
    }

    public mutating func cancel() -> (index: ID, time: Double)? {
        guard let (id, t) = history.popLast(), let p = ids.firstIndex(of: id) else { return nil }
        activePos = p
        return (id, t)
    }

    public var progress: (done: Int, total: Int) {
        (history.count, ids.count - (startID.flatMap { ids.firstIndex(of: $0) } ?? 0))
    }

    /// The doc's lines now (in doc order): deleted ones leave the sync, added ones join where they sit, the others
    /// keep their sync order; the active line stays, or becomes the next surviving one.
    public mutating func reconcile(_ current: [ID]) {
        let now = Set(current), old = Set(ids)
        let wasActive = activePos.map { ids[$0] }
        let nextSurvivor = activePos.flatMap { p in ids[p...].first(where: { now.contains($0) }) }
        var out = ids.filter { now.contains($0) }
        for (k, id) in current.enumerated() where !old.contains(id) {
            let before = current[..<k].last(where: { out.contains($0) })
            out.insert(id, at: before.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        history.removeAll { !now.contains($0.0) }
        if let s = startID, !now.contains(s) { startID = out.first }
        ids = out
        if let a = wasActive, now.contains(a) {
            activePos = ids.firstIndex(of: a)
        } else if let n = nextSurvivor {
            activePos = ids.firstIndex(of: n)
        } else if wasActive != nil {
            activePos = nil
        }
    }
}

extension LyricsSync where ID == Int {
    public init(count: Int, startAt: Int = 0) { self.init(ids: Array(0..<count), startAt: startAt) }
}

/// Times for the sync mode, in show time (input time + pad).
public enum SyncTime {
    public static func showTime(countInPlaying: Bool, countInTime: Double, recordingTime: Double, pad: Double) -> Double {
        countInPlaying ? countInTime : pad + recordingTime
    }

    public static func startTime(from line: Int, times: [Double]) -> Double {
        line <= 0 || line > times.count ? 0 : max(0, times[line - 1] - 2)
    }

    /// A stamp never lands before the previous line (a late press snapped back, or a raw press): lines stay in order.
    public static func clamp(_ t: Double, after previous: Double?) -> Double {
        guard let previous, t <= previous else { return t }
        return ((previous + 0.01) * 100).rounded() / 100
    }
}

/// « Remplacer le texte… »: new lines matched to the old ones in order (longest common subsequence of texts) keep
/// their time; the others are interpolated between neighbours (2 s steps after the last).
public enum LyricsText {
    public static func replace(old: [(time: Double, text: String)], with text: String)
        -> (lines: [(time: Double, text: String)], firstChanged: Int?) {
        let new = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let a = old.map(\.text), n = new.count, m = a.count
        var L = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                L[i][j] = new[i] == a[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            }
        }
        var times = [Double?](repeating: nil, count: n)
        var i = 0, j = 0
        while i < n && j < m {
            if new[i] == a[j] { times[i] = old[j].time; i += 1; j += 1 }
            else if L[i + 1][j] >= L[i][j + 1] { i += 1 } else { j += 1 }
        }
        let first = times.firstIndex { $0 == nil }
        var k = 0
        while k < n {
            guard times[k] == nil else { k += 1; continue }
            var e = k
            while e < n && times[e] == nil { e += 1 }
            let lo = k > 0 ? times[k - 1]! : 0
            let hi = e < n ? times[e]! : lo + 2 * Double(e - k + 1)
            for x in k..<e { times[x] = lo + (hi - lo) * Double(x - k + 1) / Double(e - k + 1) }
            k = e
        }
        for x in 1..<max(n, 1) where times[x]! < times[x - 1]! { times[x] = times[x - 1]! + 0.01 }
        return (zip(times, new).map { ($0!, $1) }, first)
    }
}
