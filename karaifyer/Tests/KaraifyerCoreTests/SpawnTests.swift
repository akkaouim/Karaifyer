import Foundation
import Testing
@testable import KaraifyerCore

@MainActor struct SpawnTests {
    /// Michel's test: every `traiter` exited with code 1 and printed nothing — the output pipe was
    /// closed as soon as the process was launched.
    @Test func streamsOutputAfterLaunchAndReportsExitCode() async throws {
        var lines: [String] = []
        var proc: SpawnedProcess?
        let code: Int32 = await withCheckedContinuation { cont in
            proc = try? SpawnedProcess(
                args: ["/bin/sh", "-c", "sleep 0.3; echo one; echo two >&2; sleep 0.3; echo three; exit 3"],
                env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp",
                onLine: { lines.append($0) }, onExit: { cont.resume(returning: $0) })
        }
        #expect(proc != nil)
        #expect(lines == ["one", "two", "three"] && code == 3)
    }
}
