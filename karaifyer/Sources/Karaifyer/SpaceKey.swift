import AppKit

/// Space as play/pause: a plain Space press (no ⌘⌥⌃, not a key repeat) while no text field of that window
/// is being edited — otherwise the Space goes to the text as usual.
@MainActor enum SpaceKey {
    static func isFree(_ ev: NSEvent) -> Bool {
        ev.keyCode == 49 && !ev.isARepeat && ev.modifierFlags.intersection([.command, .option, .control]).isEmpty
            && !(ev.window?.firstResponder is NSText)
    }

    /// A local key monitor calling `action` on a free Space in the windows `accepts` picks.
    static func monitor(accepts: @escaping @MainActor (NSWindow?) -> Bool, action: @escaping @MainActor () -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            nonisolated(unsafe) let e = ev                  // local monitors run on the main thread
            let handled = MainActor.assumeIsolated {
                guard isFree(e), accepts(e.window) else { return false }
                action()
                return true
            }
            return handled ? nil : ev
        }
    }
}
