import AppKit
import Foundation

struct SpotifySnapshot: Equatable {
    enum State: String { case playing, paused, stopped }
    var state: State
    var positionSec: Double
    var trackURI: String   // "spotify:track:…" (or "spotify:ad:…" during ads)
    var durationMs: Int
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int
    var artworkURL: String
    var volume: Int
}

struct SpotifyError: Error, LocalizedError {
    let message: String
    let code: Int
    var errorDescription: String? {
        switch code {
        case -1743:
            return "Karaifyer isn't allowed to control Spotify. Enable it in System Settings → Privacy & Security → Automation."
        case -1712:
            return "Spotify isn't responding to playback commands. Quit and reopen Spotify, start any track once, then try again."
        default:
            return "Spotify: \(message) (\(code))"
        }
    }
}

/// Drives Spotify.app through its AppleScript dictionary. All scripts run on a
/// single private serial queue (NSAppleScript is not safe to use concurrently).
final class SpotifyController {
    static let bundleID = "com.spotify.client"
    private let queue = DispatchQueue(label: "sysrec.spotify")

    private lazy var pollScript = NSAppleScript(source: Self.withTimeout("""
        tell application id "com.spotify.client"
            set s to player state
            if s is playing then
                set stateText to "playing"
            else if s is paused then
                set stateText to "paused"
            else
                set stateText to "stopped"
            end if
            set t to current track
            return {stateText, player position, id of t, duration of t, name of t, artist of t, album of t, track number of t, artwork url of t, sound volume}
        end tell
        """))!

    /// Apple events default to a 2-minute timeout; a wedged Spotify should fail fast.
    static func withTimeout(_ body: String, seconds: Int = 10) -> String {
        "with timeout of \(seconds) seconds\n\(body)\nend timeout"
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Launches Spotify (in the background) if needed and waits for it to answer.
    func ensureRunning() async throws {
        if !isRunning {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
                throw SpotifyError(message: "Spotify.app is not installed", code: 0)
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
        for _ in 0..<40 {
            if (try? await run("tell application id \"com.spotify.client\" to get version")) != nil { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        // `version` is answered by the app shell; the player itself can still be
        // wedged (seen after Spotify ran for days). Probe a player property.
        try await run("tell application id \"com.spotify.client\" to get player state")
    }

    /// Quits and relaunches Spotify. Clears a stale session in which Spotify
    /// ignores `play track` or reverts to the previous track a second later.
    func restart() async throws {
        _ = try? await run("tell application id \"com.spotify.client\" to quit")
        for _ in 0..<30 where isRunning { try await Task.sleep(for: .milliseconds(500)) }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) { app.forceTerminate() }
        try await Task.sleep(for: .seconds(1))
        try await ensureRunning()
    }

    /// Puts the player in a predictable state for recording: no shuffle/repeat, full app volume.
    func prepareForRecording() async throws {
        try await run("""
            tell application id "com.spotify.client"
                pause
                set shuffling to false
                set repeating to false
                set sound volume to 100
            end tell
            """)
    }

    func play(uri: String) async throws {
        try await run("tell application id \"com.spotify.client\" to play track \"\(uri)\"")
    }

    /// Resumes the current track where it is (unlike `play track`, which reloads it).
    func resume() async throws {
        try await run("tell application id \"com.spotify.client\" to play")
    }

    func seek(to seconds: Double) async throws {
        try await run("tell application id \"com.spotify.client\" to set player position to \(seconds)")
    }

    func setVolume(_ v: Int) async throws {
        try await run("tell application id \"com.spotify.client\" to set sound volume to \(v)")
    }

    /// Spotify occasionally ignores a lone `pause`; repeat until it reports paused.
    func pause() async throws {
        for _ in 0..<5 {
            try await run("tell application id \"com.spotify.client\" to pause")
            try await Task.sleep(for: .milliseconds(150))
            let state = try await run("""
                tell application id "com.spotify.client"
                    if player state is playing then return "playing"
                    return "other"
                end tell
                """)
            if state.stringValue != "playing" { return }
        }
    }

    func poll() async throws -> SpotifySnapshot {
        let d = try await execute(pollScript)
        func s(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func n(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        return SpotifySnapshot(
            state: SpotifySnapshot.State(rawValue: s(1)) ?? .stopped,
            positionSec: n(2),
            trackURI: s(3),
            durationMs: Int(n(4)),
            title: s(5), artist: s(6), album: s(7),
            trackNumber: Int(n(8)),
            artworkURL: s(9),
            volume: Int(n(10))
        )
    }

    // MARK: - Script execution

    @discardableResult
    private func run(_ source: String) async throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: Self.withTimeout(source)) else {
            throw SpotifyError(message: "couldn't compile script", code: 0)
        }
        return try await execute(script)
    }

    private func execute(_ script: NSAppleScript) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                var err: NSDictionary?
                let result = script.executeAndReturnError(&err)
                if let err {
                    cont.resume(throwing: SpotifyError(
                        message: err[NSAppleScript.errorMessage] as? String ?? "AppleScript error",
                        code: err[NSAppleScript.errorNumber] as? Int ?? -1))
                } else {
                    cont.resume(returning: result)
                }
            }
        }
    }
}
