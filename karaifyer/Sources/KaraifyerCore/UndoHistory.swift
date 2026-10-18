/// Snapshot undo/redo: `record(before)` saves the state an edit is about to change; `undo(from: current)`
/// returns the state to go back to (and keeps `current` for redo). A new edit clears the redo side.
public struct UndoHistory<State> {
    private var past: [State] = []
    private var future: [State] = []
    let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public mutating func record(_ before: State) {
        past.append(before)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    public mutating func undo(from current: State) -> State? {
        guard let s = past.popLast() else { return nil }
        future.append(current)
        return s
    }

    public mutating func redo(from current: State) -> State? {
        guard let s = future.popLast() else { return nil }
        past.append(current)
        return s
    }
}
