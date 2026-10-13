import Foundation

/// What the last (or current) run did to each song, for the marker column. Songs outside the run
/// have no mark. Kept after the run ends; cleared when a new run begins.
public enum RunMark: Equatable, Sendable {
    case queued, running, stopped, failed
    case done(statut: String)
}

public struct RunMarks: Sendable {
    private var marks: [String: RunMark] = [:]
    public init() {}

    public subscript(id: String) -> RunMark? { marks[id] }

    /// A new run: forget the previous run's marks.
    public mutating func begin(_ ids: [String]) { marks = [:]; add(ids) }
    /// Songs appended to the run in progress.
    public mutating func add(_ ids: [String]) { for id in ids where marks[id] != .running { marks[id] = .queued } }
    public mutating func running(_ id: String) { marks[id] = .running }
    public mutating func songEnded(_ id: String, statut: String) { marks[id] = .done(statut: statut) }
    /// A process that dies without song_end (crash, kill) is a failure; after song_end, nothing changes.
    public mutating func processExited(_ id: String, code: Int32) {
        if marks[id] == .running { marks[id] = code == 0 ? .done(statut: "ok") : .failed }
    }
    /// Songs that ended « à réessayer » (online service unreachable), in id order: retried once at the end.
    public func retryCandidates() -> [String] {
        marks.filter { $0.value == .done(statut: "a_reessayer") }.map(\.key).sorted()
    }

    /// « Arrêter maintenant »: the running song is marked stopped, songs still waiting are unmarked.
    public mutating func stopped() {
        for (id, m) in marks {
            if m == .running { marks[id] = .stopped } else if m == .queued { marks[id] = nil }
        }
    }
}
