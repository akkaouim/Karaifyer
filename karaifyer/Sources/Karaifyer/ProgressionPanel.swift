import AppKit
import KaraifyerCore
import SwiftUI

/// A chord chart (Chordonomicon progression, or an open chart from « Visualiser ») in a floating panel that stays above
/// the Corriger window until Michel closes it or closes that window. Shown in the song's key, with « Afficher
/// l'original » when the chart was written in another key.
@MainActor enum ProgressionPanel {
    private static var panels: [String: NSPanel] = [:]

    /// A Chordonomicon progression: section names in a bold column, chords beside them (the raw strings).
    static func showProgression(id: String, title: String, raw: String, original: String?) {
        let text = ProgressionText.plain(raw), orig = original.map(ProgressionText.plain)
        show(id: id, kind: "progression", title: title, text: text, original: orig,
             note: orig != nil && orig != text ? "dans la tonalité du morceau" : nil,
             sections: ProgressionText.sections(raw), originalSections: original.map(ProgressionText.sections))
    }

    static func show(id: String, kind: String, title: String, text: String, original: String?, note: String? = nil,
                     sections: [(title: String, chords: String)]? = nil,
                     originalSections: [(title: String, chords: String)]? = nil) {
        let key = id + "/" + kind
        panels[key]?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.title = title
        let m = ChartPanelModel(text: text, original: original, note: note)
        m.sections = sections
        m.originalSections = originalSections
        p.contentView = NSHostingView(rootView: ChartPanelView(model: m))
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
    var sections: [(title: String, chords: String)]?
    var originalSections: [(title: String, chords: String)]?
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
                if let secs = model.showOriginal ? (model.originalSections ?? model.sections) : model.sections {
                    VStack(alignment: .leading, spacing: 6) {          // progression: bold section column, chords beside
                        ForEach(secs.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(secs[i].title).bold().frame(width: 110, alignment: .leading)
                                Text(secs[i].chords).font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(model.showOriginal ? (model.original ?? model.text) : model.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
    }
}
