import AppKit
import KaraifyerCore
import SwiftUI

/// A chord chart (Chordonomicon progression, or an open chart from « Visualiser ») in a floating panel that stays above
/// the Corriger window until Michel closes it or closes that window. Shown in the song's key, with « Afficher
/// l'original » when the chart was written in another key.
@MainActor enum ProgressionPanel {
    private static var panels: [String: NSPanel] = [:]

    static func show(id: String, kind: String, title: String, text: String, original: String?, note: String? = nil) {
        let key = id + "/" + kind
        panels[key]?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.title = title
        p.contentView = NSHostingView(rootView: ChartPanelView(model: ChartPanelModel(text: text, original: original, note: note)))
        p.center()
        p.makeKeyAndOrderFront(nil)
        panels[key] = p
    }

    static func close(id: String) {
        for (k, p) in panels where k.hasPrefix(id + "/") { p.close(); panels[k] = nil }
    }
}

@MainActor @Observable final class ChartPanelModel {
    let text: String
    let original: String?
    let note: String?
    var showOriginal = false
    init(text: String, original: String?, note: String?) { self.text = text; self.original = original; self.note = note }
    var canToggle: Bool { original != nil && original != text }
}

struct ChartPanelView: View {
    @Bindable var model: ChartPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let n = model.note { Text(model.showOriginal ? "telle qu'écrite" : n).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.canToggle {
                    Button(model.showOriginal ? "Afficher dans la tonalité du morceau" : "Afficher l'original") {
                        model.showOriginal.toggle()
                    }
                }
            }
            ScrollView {
                Text(model.showOriginal ? (model.original ?? model.text) : model.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}
