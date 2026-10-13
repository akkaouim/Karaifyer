import Testing
@testable import KaraifyerCore

final class FakeDriver: RunDriver {
    var calls: [String] = []
    func launch(_ job: Job) { calls.append("launch \(job.id)\(job.forced.map { " +\($0)" } ?? "")") }
    func signal(_ s: RunSignal) { calls.append("\(s)") }
}

@MainActor struct RunControllerTests {
    @Test func runsJobsInSequence() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005"), Job(id: "011", forced: "video")])
        #expect(c.state == .running && c.current?.id == "005")
        c.start([Job(id: "005"), Job(id: "012")])        // already-queued ids not duplicated
        c.processExited(); c.processExited(); c.processExited()
        #expect(d.calls == ["launch 005", "launch 011 +video", "launch 012"] && c.state == .idle)
    }

    @Test func pauseResumeNeverTimesOut() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005")]); c.pause()
        #expect(c.state == .paused)
        c.killIfStillStopping()                          // no effect while merely paused (overnight pause)
        c.resume()
        #expect(c.state == .running && d.calls == ["launch 005", "stop", "cont"])
    }

    @Test func stopAfterCurrentFinishesThenIdles() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005"), Job(id: "011")]); c.requestStopAfterCurrent(); c.processExited()
        #expect(c.state == .idle && c.queue.isEmpty && d.calls == ["launch 005"])
    }

    @Test func stopNowFromPausedContinuesThenTerminatesThenKills() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005"), Job(id: "011")]); c.pause(); c.stopNow()
        #expect(c.state == .stopping)
        c.killIfStillStopping()
        c.processExited()
        #expect(d.calls == ["launch 005", "stop", "cont", "term", "kill"] && c.state == .idle && c.queue.isEmpty)
    }

    @Test func estimate() {
        #expect(Estimate.remaining(songsLeft: 3, currentElapsed: 100, measuredSongSeconds: []) == 3 * 420 - 100)
        #expect(Estimate.remaining(songsLeft: 2, currentElapsed: 50, measuredSongSeconds: [300, 500]) == 750)
        #expect(Estimate.remaining(songsLeft: 1, currentElapsed: 9999, measuredSongSeconds: []) == 0)
    }
}
