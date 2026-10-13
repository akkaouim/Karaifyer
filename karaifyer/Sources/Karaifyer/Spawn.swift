import Foundation

/// A child process in its own process group (so SIGSTOP/SIGCONT/SIGTERM reach uv, Python and the
/// ML tool it starts), with stdout+stderr streamed line by line on the main queue.
final class SpawnedProcess {
    private(set) var pid: pid_t = 0
    private let onLine: (String) -> Void
    private let onExit: (Int32) -> Void
    private var buffer = Data()

    init(args: [String], env: [String: String], cwd: String,
         onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) throws {
        self.onLine = onLine
        self.onExit = onExit
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        posix_spawn_file_actions_addclose(&fa, fds[0])
        posix_spawn_file_actions_addclose(&fa, fds[1])
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fa)
            posix_spawnattr_destroy(&attr)
        }
        let rc = posix_spawn(&pid, args[0], &fa, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT)
        }
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        reader.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        let p = pid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(p, &status, 0)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
            // Let the last output lines drain before reporting the exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.onExit(code) }
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            onLine(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if chunk.isEmpty, !buffer.isEmpty {
            onLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }

    /// Signal the whole process group.
    func signal(_ sig: Int32) {
        if pid > 0 { kill(-pid, sig) }
    }
}
