import Foundation

public enum RunState: Equatable, Sendable { case idle, running, paused, stopping }
public enum RunSignal: Equatable, Sendable { case stop, cont, term, kill }

public struct Job: Equatable, Sendable {
    public var id: String
    public var forced: String?
    public init(id: String, forced: String? = nil) { self.id = id; self.forced = forced }
}

public protocol RunDriver: AnyObject {
    func launch(_ job: Job)          // start `traiter --ids job.id [--forcer job.forced] --json`
    func signal(_ s: RunSignal)      // to the running process group
}

/// One pipeline process per song, in sequence. Pause/resume = SIGSTOP/SIGCONT on the process
/// group; stop now = SIGCONT + SIGTERM, then SIGKILL if it is still alive after 10 s.
/// A paused job never times out (Michel may pause overnight).
@MainActor public final class RunController {
    public private(set) var state: RunState = .idle
    public private(set) var current: Job?
    public private(set) var queue: [Job] = []
    public private(set) var stopAfterCurrent = false
    public var onChange: (() -> Void)?
    private let driver: RunDriver

    public init(driver: RunDriver) { self.driver = driver }

    public func start(_ jobs: [Job]) {
        let busy = Set(queue.map(\.id) + [current?.id].compactMap { $0 })
        queue += jobs.filter { !busy.contains($0.id) }
        if state == .idle { stopAfterCurrent = false; launchNext() }
        onChange?()
    }

    public func pause() {
        guard state == .running else { return }
        driver.signal(.stop)
        state = .paused
        onChange?()
    }

    public func resume() {
        guard state == .paused else { return }
        driver.signal(.cont)
        state = .running
        onChange?()
    }

    public func requestStopAfterCurrent() {
        stopAfterCurrent = true
        onChange?()
    }

    public func stopNow() {
        guard state == .running || state == .paused else { return }
        if state == .paused { driver.signal(.cont) }
        driver.signal(.term)
        queue.removeAll()
        state = .stopping
        onChange?()
    }

    public func killIfStillStopping() {
        if state == .stopping { driver.signal(.kill) }
    }

    public func processExited() {
        current = nil
        if state == .stopping || stopAfterCurrent {
            queue.removeAll()
            state = .idle
            stopAfterCurrent = false
        } else {
            launchNext()
        }
        onChange?()
    }

    private func launchNext() {
        guard !queue.isEmpty else { state = .idle; return }
        let job = queue.removeFirst()
        current = job
        state = .running
        driver.launch(job)
    }
}
