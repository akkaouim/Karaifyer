import AppKit
import KaraifyerCore
import SwiftUI
import UniformTypeIdentifiers

let STEP_NAMES = ["ingest", "separate", "beats", "vocals_split", "chords", "package", "lyrics", "check", "video", "set"]
let RETIRER = [("guitar", "Guit."), ("bass", "Basse"), ("piano", "Piano"), ("drums", "Batt."), ("other", "Autres")]
let LANGUES = ["fr", "en", "es", "it", "de", "pt"]

/// UI-only state kept outside the views (no @State without Xcode).
@Observable final class KaraokeUI {
    static let shared = KaraokeUI()
    var alert: String?
    var terminalShown = true
}

struct KaraokeView: View {
    @Bindable var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow
    let ui = KaraokeUI.shared

    var body: some View {
        VStack(spacing: 0) {
            if let b = model.banner { bannerView(b) }
            toolbar.padding(8)
            table
            footer
        }
        .task { await model.refresh() }
        .alert(ui.alert ?? "", isPresented: Binding(get: { ui.alert != nil }, set: { if !$0 { ui.alert = nil } })) {}
    }

    func bannerView(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
            Spacer()
            if !model.pipeline.manifestExists && model.pipeline.problems().isEmpty {
                Button("Créer le manifeste depuis un dossier SysRec…") {
                    pickFolder { url in Task { await model.createManifest(from: url) } }
                }
            }
            Button("Réessayer") { Task { await model.refresh() } }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    var toolbar: some View {
        HStack {
            Button("Ajouter des morceaux…", systemImage: "plus") {
                pickFiles { urls in Task { await model.add(files: urls) } }
            }
            .disabled(!model.pipeline.problems().isEmpty)
            Divider().frame(height: 18)
            Button(model.selection.isEmpty ? "Analyser tout" : "Analyser la sélection", systemImage: "play.fill") {
                endEditing()
                model.analyse(ids: Array(model.selection))
            }
            .disabled(model.banner != nil || model.songs.isEmpty)
            switch model.runState {
            case .running: Button("Pause", systemImage: "pause.fill") { model.pause() }
            case .paused: Button("Reprendre", systemImage: "playpause.fill") { model.resume() }
            default: EmptyView()
            }
            if model.runState == .running || model.runState == .paused {
                Button(model.stopAfterCurrentRequested ? "Arrêt après ce morceau…" : "Arrêter après ce morceau") {
                    model.stopAfterCurrent()
                }
                .disabled(model.stopAfterCurrentRequested)
                Button("Arrêter maintenant", systemImage: "stop.fill") { model.stopNow() }
            }
            Spacer()
            Button("Rapport") { open(model.pipeline.karaokeHome + "/rapport.html") }
            Button("iReal Pro") {
                let dir = model.pipeline.karaokeHome + "/ireal"
                let pages = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".html") }
                open(pages.count == 1 ? dir + "/" + pages[0] : dir)
            }
            Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .labelStyle(.iconOnly)
        }
    }

    var table: some View {
        Table(model.songs, selection: $model.selection) {
            TableColumn("id") { s in Text(s.id).monospacedDigit() }.width(36)
            TableColumn("Titre") { s in CommitField(value: s.titre) { commit(s, "titre", $0) } }
            TableColumn("Artiste") { s in CommitField(value: s.artiste) { commit(s, "artiste", $0) } }
            TableColumn("Retirer (joué en live)") { s in
                HStack(spacing: 6) {
                    ForEach(RETIRER, id: \.0) { stem, label in
                        Toggle(label, isOn: Binding(get: { current(s).retirer.contains(stem) }, set: { on in
                            commit(s, "retirer", Retirer.toggled(current(s).retirer, stem, on: on, order: RETIRER.map(\.0)))
                        }))
                        .toggleStyle(.checkbox).font(.caption)
                    }
                }
            }.width(min: 300)
            TableColumn("Langue") { s in
                Picker("", selection: Binding(get: { s.langue }, set: { commit(s, "langue", $0) })) {
                    ForEach(Array(Set(LANGUES + [s.langue])).sorted(), id: \.self) { Text($0) }
                }
                .labelsHidden()
            }.width(64)
            TableColumn("Partie") { s in CommitField(value: s.partie) { commit(s, "partie", $0) } }.width(110)
            TableColumn("Statut") { s in Text(s.statut).foregroundStyle(color(statut: s.statut)) }.width(70)
            TableColumn("Étapes") { s in
                HStack(spacing: 3) {
                    ForEach(s.steps, id: \.name) { st in
                        Circle()
                            .fill(color(step: st, running: model.currentID == s.id && model.currentStep == st.name))
                            .frame(width: 9, height: 9)
                            .help("\(st.name) : \(st.status)" + ((st.error ?? "").isEmpty ? "" : "\n\(st.error!)"))
                    }
                }
            }.width(130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let s = model.songs.first(where: { $0.id == id }) {
                Button("Ouvrir le dossier") { open(s.paths.dossier) }
                Button("Ouvrir la vidéo") { open(s.paths.video) }
                Button("Ouvrir le set Ableton") { open(s.paths.set) }
                Button("Ouvrir la grille d'accords") { open(s.paths.accords) }
                Button("Voir le journal") { open(model.pipeline.karaokeHome + "/travail/\(s.id)/journal.log") }
                Divider()
                Button("Corriger paroles et accords…") { openWindow(id: "editor", value: s.id) }
                Button("Refaire le morceau") { model.analyse(ids: Array(ids), forced: "ingest") }
                Menu("Refaire une étape") {
                    ForEach(STEP_NAMES, id: \.self) { st in Button(st) { model.analyse(ids: Array(ids), forced: st) } }
                }
            }
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.runState != .idle {
                ProgressView(value: model.progress)
                Text(model.statusLine).font(.caption).monospacedDigit()
            }
            DisclosureGroup("Terminal", isExpanded: Bindable(ui).terminalShown) {
                TerminalView(lines: model.log).frame(minHeight: 160, idealHeight: 200)
                HStack {
                    Spacer()
                    Button("Copier") { copy(model.log.joined(separator: "\n")) }
                }
            }
        }
        .padding(8)
    }

    /// The row as it is now (a quick second click must not build on a stale snapshot).
    func current(_ s: SongState) -> SongState { model.songs.first { $0.id == s.id } ?? s }

    func commit(_ s: SongState, _ field: String, _ value: String) {
        Task { if let err = await model.set(id: s.id, field: field, value: value) { KaraokeUI.shared.alert = err } }
    }
}

/// AppKit text field that commits on Return / focus loss (SwiftUI's TextField needs @State for a draft).
struct CommitField: NSViewRepresentable {
    let value: String
    let onCommit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: value)
        f.isBordered = false
        f.drawsBackground = false
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.currentEditor() == nil { f.stringValue = value }
        context.coordinator.onCommit = onCommit
        context.coordinator.original = value
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, original: value) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var original: String
        init(onCommit: @escaping (String) -> Void, original: String) { self.onCommit = onCommit; self.original = original }
        private var target: ((String) -> Void)?
        private var startValue = ""
        /// Commit to the row where editing began, even if the cell was reused for another row since.
        func controlTextDidBeginEditing(_ n: Notification) {
            target = onCommit
            startValue = original
        }
        func controlTextDidEndEditing(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            let commit = target ?? onCommit
            let before = target == nil ? original : startValue
            target = nil
            guard f.stringValue != before else { return }
            commit(f.stringValue)
        }
    }
}

/// Monospaced log that follows the end unless the user scrolled up.
struct TerminalView: NSViewRepresentable {
    let lines: [String]

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        let atBottom = sv.contentView.bounds.maxY >= tv.bounds.height - 20
        tv.string = lines.joined(separator: "\n")
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }
}

func color(statut: String) -> Color {
    switch statut {
    case "ok": .green
    case "alerte": .orange
    case "echec": .red
    case "a_reessayer": .yellow
    default: .secondary
    }
}

func color(step: StepState, running: Bool) -> Color {
    if running { return .blue }
    switch step.status {
    case "a_jour": return .green
    case "echec": return .red
    case "bloque", "a_reessayer": return .orange
    default: return .gray.opacity(0.4)
    }
}

func open(_ path: String) {
    if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    else { KaraokeUI.shared.alert = "Introuvable : \(path)" }
}

/// End any in-progress text edit so it commits before a button acts (buttons don't take focus).
func endEditing() {
    if let w = NSApp.keyWindow, !w.makeFirstResponder(nil) { w.endEditing(for: nil) }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func pickFiles(_ done: @escaping ([URL]) -> Void) {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = false
    p.allowedContentTypes = [.audio]
    if p.runModal() == .OK { done(p.urls) }
}

func pickFolder(_ done: @escaping (URL) -> Void) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    if p.runModal() == .OK, let u = p.url { done(u) }
}
