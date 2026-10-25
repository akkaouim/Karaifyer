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
            if model.locked {
                Label("Analyse en cours : modifications désactivées jusqu'à la fin ou l'arrêt", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 4)
            }
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
            if !model.pipeline.homeExists && model.pipeline.uvPath != nil {
                Button("Créer le dossier karaoké ici") { Task { await model.createWorkspace(at: model.pipeline.karaokeHome) } }
                Button("Choisir un autre emplacement…") {
                    pickFolder { url in Task { await model.createWorkspace(at: url.appendingPathComponent("Karaoke").path) } }
                }
            }
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
            .disabled(!model.pipeline.problems().isEmpty || model.locked)
            Divider().frame(height: 18)
            Button(model.selection.isEmpty ? "Analyser tout" : "Analyser la sélection", systemImage: "play.fill") {
                endEditing()
                model.analyse(ids: Array(model.selection))
            }
            .disabled(model.banner != nil || model.songs.isEmpty || model.locked)
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
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Rechercher (titre, artiste, id, Set List)", text: $model.query)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                if !model.query.isEmpty {
                    Button("Effacer", systemImage: "xmark.circle.fill") { model.query = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Picker("Vidéo :", selection: $model.videoLayout) {
                Text("Grille + paroles").tag("grille")
                Text("Accords sur les paroles").tag("paroles")
            }
            .fixedSize()
            .help("Disposition des vidéos rendues par l'analyse (paroles.mp4, sets Ableton) ; en changer refait les vidéos à la prochaine analyse")
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
        Table(model.displayedSongs, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("") { s in MarkView(mark: model.marks[s.id], paused: model.runState == .paused) }.width(22)
            TableColumn("id", value: \.id) { s in Text(s.id).monospacedDigit() }.width(36)
            TableColumn("Titre", value: \.titre) { s in CommitField(value: s.titre, enabled: !model.locked) { commit(s, "titre", $0) } }
            TableColumn("Artiste", value: \.artiste) { s in CommitField(value: s.artiste, enabled: !model.locked) { commit(s, "artiste", $0) } }
            TableColumn("Retirer (joué en live)") { s in
                HStack(spacing: 6) {
                    ForEach(RETIRER, id: \.0) { stem, label in
                        Toggle(label, isOn: Binding(get: { current(s).retirer.contains(stem) }, set: { on in
                            commit(s, "retirer", Retirer.toggled(current(s).retirer, stem, on: on, order: RETIRER.map(\.0)))
                        }))
                        .toggleStyle(.checkbox).font(.caption)
                        .disabled(model.locked)
                    }
                }
            }.width(min: 300)
            TableColumn("Langue", value: \.langue) { s in
                Picker("", selection: Binding(get: { s.langue }, set: { commit(s, "langue", $0) })) {
                    ForEach(Array(Set(LANGUES + [s.langue])).sorted(), id: \.self) { Text($0) }
                }
                .labelsHidden()
                .disabled(model.locked)
            }.width(64)
            TableColumn("Statut", value: \.statutRank) { s in
                HStack(spacing: 6) {
                    Text(statutLabel(s.statut)).bold().foregroundStyle(color(statut: s.statut))
                    Text((s.alertes ?? []).joined(separator: " · ")).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .help(Help.statut(s.statut, alertes: s.alertes ?? []))
            }.width(min: 220, ideal: 360)
            TableColumn("Étapes", value: \.stepsDone) { s in
                HStack(spacing: 3) {
                    ForEach(s.steps, id: \.name) { st in
                        Circle()
                            .fill(color(step: st, running: model.currentID == s.id && model.currentStep == st.name))
                            .frame(width: 9, height: 9)
                            .help(Help.step(st))
                    }
                }
            }.width(130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let s = model.songs.first(where: { $0.id == id }) {
                Button("Ouvrir le dossier") { open(s.paths.dossier) }
                Button("Ouvrir la vidéo") { open(s.paths.video) }
                Button("Ouvrir dans le Lecteur") { PlayerModel.shared.openInPlayer(s.id) }
                    .disabled(!PlayerModel.shared.missing(for: s).isEmpty)
                Button("Ouvrir le set Ableton") { open(s.paths.set) }
                Button("Ouvrir la grille d'accords") { open(s.paths.accords) }
                Button("Voir le journal") { open(model.pipeline.karaokeHome + "/travail/\(s.id)/journal.log") }
                Divider()
                Group {
                    Button("Corriger paroles et accords…") { openWindow(id: "editor", value: s.id) }
                    Button("Changer de Set List… (actuelle : \(s.partie.isEmpty ? "aucune" : s.partie))") {
                        if let p = askText("Set List pour « \(s.titre) »", value: s.partie) { commit(s, "partie", p) }
                    }
                    Button("Refaire le morceau") { model.analyse(ids: Array(ids), forced: "ingest") }
                    Button("Refaire la détection des temps") { model.redetectBeats(ids: Array(ids)) }
                        .help("Oublie la détection enregistrée et la refait ; les corrections de mesure sont gardées")
                    Menu("Refaire une étape") {
                        ForEach(STEP_NAMES, id: \.self) { st in Button(st) { model.analyse(ids: Array(ids), forced: st) } }
                    }
                }
                .disabled(model.locked)
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
    var enabled = true
    /// Give up keyboard focus after a commit, so later changes from buttons show (a focused field ignores
    /// outside updates) and Space goes back to the player. Off in tables, where focus must stay for the arrows.
    var resignOnCommit = false
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
        f.isEditable = enabled
        f.textColor = enabled ? .labelColor : .secondaryLabelColor
        context.coordinator.onCommit = onCommit
        context.coordinator.original = value
        context.coordinator.resignOnCommit = resignOnCommit
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, original: value) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var original: String
        var resignOnCommit = false
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
            if f.stringValue != before { commit(f.stringValue) }
            // Return (not Tab, which moves to the next field) hands the keyboard back
            let movement = n.userInfo?["NSTextMovement"] as? Int
            guard resignOnCommit, movement == NSTextMovement.return.rawValue else { return }
            DispatchQueue.main.async {
                if f.currentEditor() != nil { f.window?.makeFirstResponder(nil) }
                f.stringValue = self.original          // the committed value as the model kept it (clamped)
            }
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

/// Marker column: spinner = being processed, clock = waiting, check/cross = finished in this run.
struct MarkView: View {
    let mark: RunMark?
    let paused: Bool
    var body: some View {
        switch mark {
        case .running?:
            if paused {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange).help("En pause")
            } else {
                ProgressView().controlSize(.small).help("En cours d'analyse")
            }
        case .queued?: Image(systemName: "clock").foregroundStyle(.secondary).help("En attente dans cette analyse")
        case .done(let statut)?:
            Image(systemName: statut == "echec" ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(color(statut: statut)).help("Terminé dans cette analyse : \(statut)")
        case .failed?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Arrêté sur une erreur (voir le terminal)")
        case .stopped?: Image(systemName: "stop.circle.fill").foregroundStyle(.orange).help("Arrêté pendant l'analyse : sera repris à la prochaine")
        case nil: Color.clear
        }
    }
}

func statutLabel(_ statut: String) -> String {
    switch statut {
    case "ok": "ok"
    case "alerte": "à vérifier"
    case "echec": "échec"
    case "a_reessayer": "à réessayer"
    default: "—"
    }
}

/// A small text prompt (no SwiftUI @State available): returns nil when cancelled.
func askText(_ message: String, value: String) -> String? {
    let a = NSAlert()
    a.messageText = message
    let field = NSTextField(string: value)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    a.accessoryView = field
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Annuler")
    a.window.initialFirstResponder = field
    return a.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil
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
    if step.warned { return .orange }
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
