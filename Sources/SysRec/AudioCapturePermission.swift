import Foundation

/// "System Audio Recording" permission (TCC service kTCCServiceAudioCapture).
///
/// There is no public API to query or request it, and a process tap created
/// without it silently delivers zeros. Like other tap-based recorders, we call
/// TCC.framework's preflight/request functions directly, resolved at runtime
/// so a missing symbol degrades to "unknown" instead of crashing.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var status: Status {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. Returns whether access is granted.
    static func request() async -> Bool {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return false }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        return await withCheckedContinuation { cont in
            fn(service, nil) { granted in cont.resume(returning: granted) }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspaceOpen(url)
        }
    }
}

import AppKit
private func NSWorkspaceOpen(_ url: URL) { NSWorkspace.shared.open(url) }
