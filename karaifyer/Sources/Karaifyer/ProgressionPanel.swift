import AppKit
import KaraifyerCore
import SwiftUI

/// Chordonomicon's whole progression for a song, in a floating panel that stays above the Corriger window until
/// Michel closes it or closes that window.
@MainActor enum ProgressionPanel {
    private static var panels: [String: NSPanel] = [:]

    static func show(id: String, title: String, raw: String) {
        if let p = panels[id] {
            p.makeKeyAndOrderFront(nil)
            return
        }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.title = "Progression — \(title)"
        p.contentView = NSHostingView(rootView: ProgressionView(sections: ProgressionText.sections(raw)))
        p.center()
        p.makeKeyAndOrderFront(nil)
        panels[id] = p
    }

    static func close(id: String) {
        panels[id]?.close()
        panels[id] = nil
    }
}

struct ProgressionView: View {
    let sections: [(title: String, chords: String)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sections.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sections[i].title).bold().frame(width: 110, alignment: .leading)
                        Text(sections[i].chords).font(.system(.body, design: .monospaced))
                    }
                }
            }
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
