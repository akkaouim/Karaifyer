import Foundation

/// Tap sync over the lyric lines: Return stamps the active line and moves on; ↑/⌫ gives the last stamped line its
/// previous time back and makes it active again.
public struct LyricsSync: Sendable {
    public let count: Int
    public private(set) var active: Int?
    private var history: [(Int, Double)] = []
    private let start: Int

    public init(count: Int, startAt: Int = 0) {
        self.count = count
        start = min(max(0, startAt), count)
        active = start < count ? start : nil
    }

    public mutating func stamp(oldTime: Double) -> Int? {
        guard let a = active else { return nil }
        history.append((a, oldTime))
        active = a + 1 < count ? a + 1 : nil
        return a
    }

    public mutating func cancel() -> (index: Int, time: Double)? {
        guard let (i, t) = history.popLast() else { return nil }
        active = i
        return (i, t)
    }

    public var progress: (done: Int, total: Int) { (history.count, count - start) }

    public static func showTime(countInPlaying: Bool, countInTime: Double, recordingTime: Double, pad: Double) -> Double {
        countInPlaying ? countInTime : pad + recordingTime
    }

    public static func startTime(from line: Int, times: [Double]) -> Double {
        line <= 0 || line > times.count ? 0 : max(0, times[line - 1] - 2)
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
