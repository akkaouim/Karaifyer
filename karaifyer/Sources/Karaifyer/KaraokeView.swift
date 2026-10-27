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
    var removal: [RemovalItem]?           // « Retirer du manifeste… » sheet, with its three choices
    var removeAnalyse = true
    var removeCorrections = true
    var removeAudio = false
    var outputRenameShown = false
}

struct KaraokeView: View {
    @Bindable var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let ui = KaraokeUI.shared

    var body: some View {
        VStack(spacing: 0) {
            if let b = model.banner { bannerView(b) }
            if !model.outputRenames.isEmpty {
                HStack {
                    Image(systemName: "folder.badge.gearshape").foregroundStyle(.blue)
                    Text("Les dossiers de sortie peuvent prendre le nom « Titre - Artiste » (\(model.outputRenames.count) dossiers).")
                    Spacer()
                    Button("Renommer…") { ui.outputRenameShown = true }.disabled(model.locked)
                }
                .padding(8)
                .background(Color.blue.opacity(0.08))
            }
            if !model.locked, case let missing = model.missingRecordings, !missing.isEmpty {
                HStack {
                    Image(systemName: "questionmark.folder").foregroundStyle(.orange)
                    Text("\(missing.count) enregistrement(s) introuvable(s) : " + missing.prefix(3).map { "\($0.id) \($0.titre)" }.joined(separator: ", ")
                         + (missing.count > 3 ? "…" : ""))
                        .lineLimit(1)
                    Spacer()
                    Button("Retrouver…") { findRecordings() }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
            toolbar.padding(8)
            if model.locked {
                Label("Analyse en cours : modifications désactivées jusqu'à la fin ou l'arrêt", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 4)
            }
            ScrollViewReader { proxy in
                table.onChange(of: model.retirerCollapsed) {
                    // the rebuilt table starts at the top: bring the selected song back into view
                    guard let id = model.displayedSongs.first(where: { model.selection.contains($0.id) })?.id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(id, anchor: .leading) }   // left edge kept
                }
            }
            footer
        }
        .task { await model.refresh(); await model.checkOutputRenames() }
        .onChange(of: model.locked) { _, locked in if !locked { Task { await model.checkOutputRenames() } } }
        .sheet(isPresented: Bindable(ui).outputRenameShown) { outputRenameSheet }
        .sheet(isPresented: Binding(get: { ui.removal != nil }, set: { if !$0 { ui.removal = nil } })) {
            if let items = ui.removal { removalSheet(items) }
        }
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
            Menu {
                Button("Changer de dossier karaoké…") { KaraokeHome.choose() }
                Button("Afficher dans le Finder") { open(model.pipeline.karaokeHome) }
                let others = KaraokeHome.recents.filter { $0 != model.pipeline.karaokeHome }
                if !others.isEmpty {
                    Divider()
                    Section("Récents") {
                        ForEach(others, id: \.self) { p in Button(p) { KaraokeHome.switchTo(p) } }
                    }
                }
            } label: {
                Label(KaraokeFolder.displayName(model.pipeline.karaokeHome), systemImage: "externaldrive")
            }
            .fixedSize()
            .disabled(model.locked)
            .help("Dossier karaoké : \(model.pipeline.karaokeHome)")
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
            Group {
                TableColumn("", value: \.reanalysisSort) { s in markCell(s) }.width(22)
                TableColumn("") { s in quickActions(s) }.width(48)
                TableColumn("id", value: \.id) { s in Text(s.id).monospacedDigit() }.width(36)
                TableColumn("Titre", value: \.titre) { s in titleCell(s) }
                TableColumn("Artiste", value: \.artiste) { s in artistCell(s) }
                TableColumn(model.retirerCollapsed ? "Retirer ▸" : "Retirer (joué en live) ▾", value: \.retirerHeader) { s in
                    retirerCell(s)
                }
                .width(Self.retirerWidth(folded: model.retirerCollapsed))
                TableColumn("Langue", value: \.langue) { s in langueCell(s) }.width(Self.headerFit("Langue", content: 64))
            }
            Group {
                TableColumn("BPM", value: \.bpmSort) { s in bpmCell(s) }.width(Self.headerFit("BPM", content: 36))
                TableColumn("Tonalité", value: \.keyShort) { s in keyCell(s) }.width(Self.headerFit("Tonalité", content: 40))
                TableColumn("Vérifié", value: \.verifiedSort) { s in verifiedCell(s) }.width(Self.headerFit("Vérifié", content: 30))
                TableColumn("Corrigé", value: \.correctionsSort) { s in correctionsCell(s) }.width(Self.headerFit("Corrigé", content: 40))
                TableColumn("Statut", value: \.statutRank) { s in statutCell(s) }.width(min: 220, ideal: 360)
                TableColumn("Étapes", value: \.stepsDone) { s in stepsCell(s) }.width(130)
            }
        }
        // SwiftUI lays table columns out once: folding « Retirer » rebuilds the table, then shows the selected song again
        .id(model.retirerCollapsed)
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
                    Divider()
                    Button(ids.count > 1 ? "Retirer \(ids.count) morceaux du manifeste…" : "Retirer du manifeste…") {
                        askRemoval(model.songs.map(\.id).filter(ids.contains))
                    }
                }
                .disabled(model.locked)
            }
        }
    }

    var outputRenameSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Renommer les dossiers de sortie").font(.headline)
            Text("Les dossiers de sortie et les sets Ableton prennent le nom « Titre - Artiste ». Les sets sont refaits "
                 + "(quelques secondes par morceau) ; rien d'autre n'est réanalysé. Les anciens sets vont à la Corbeille. "
                 + "Une copie du manifeste est gardée.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Fermez d'abord les sets ouverts dans Ableton Live.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.outputRenames, id: \.self) { r in
                        Text("\(r["ancien"] ?? "")  →  \(r["nouveau"] ?? "")").font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            HStack {
                Spacer()
                Button("Plus tard", role: .cancel) { ui.outputRenameShown = false }.keyboardShortcut(.cancelAction)
                Button("Renommer") {
                    ui.outputRenameShown = false
                    Task { await model.renameOutputs() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.locked)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    func findRecordings() {
        pickFolder { url in
            Task {
                guard let found = await model.findRecordings(in: url, apply: false) else { return }
                let a = NSAlert()
                if found.isEmpty {
                    a.messageText = "Aucun enregistrement retrouvé dans ce dossier"
                    a.runModal()
                    return
                }
                a.messageText = "Mettre à jour \(found.count) ligne(s) du manifeste ?"
                a.informativeText = found.map { "\($0["id"] ?? "") \($0["titre"] ?? "") → \(URL(fileURLWithPath: $0["nouveau"] ?? "").lastPathComponent)" }
                    .joined(separator: "\n") + "\n\nUne copie du manifeste est gardée."
                a.addButton(withTitle: "Mettre à jour")
                a.addButton(withTitle: "Annuler").keyEquivalent = "\u{1b}"
                if a.runModal() == .alertFirstButtonReturn { _ = await model.findRecordings(in: url, apply: true) }
            }
        }
    }

    func askRemoval(_ ids: [String]) {
        Task {
            guard let items = await model.planRemoval(ids: ids) else { return }
            ui.removeAnalyse = true
            ui.removeCorrections = true
            ui.removeAudio = false
            ui.removal = items
        }
    }

    func removalSheet(_ items: [RemovalItem]) -> some View {
        let size = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        let shared = items.filter(\.audio.partage)
        return VStack(alignment: .leading, spacing: 12) {
            Text(items.count > 1 ? "Retirer \(items.count) morceaux du manifeste ?" : "Retirer ce morceau du manifeste ?")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.id) { it in
                        Text("\(it.id)  \(it.titre) — \(it.artiste)").monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            Text("La ligne est retirée du manifeste (une copie est gardée : manifeste.avant-retrait-….csv). "
                 + "Le rapport, les pages iReal et l'index des grilles sont refaits sans ce morceau.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Mettre aussi à la Corbeille :").bold()
            Toggle("Fichiers d'analyse (travail, sortie, set Ableton) — \(size(RemovalItem.total(items, \.analyse)))",
                   isOn: Bindable(ui).removeAnalyse)
            Toggle("Corrections (paroles, accords, mesures) — \(size(RemovalItem.total(items, \.corrections)))",
                   isOn: Bindable(ui).removeCorrections)
                .disabled(RemovalItem.total(items, \.corrections) == 0)
            Toggle("Enregistrement audio — \(size(RemovalItem.audioTotal(items)))", isOn: Bindable(ui).removeAudio)
                .disabled(!RemovalItem.audioOffered(items))
            if !shared.isEmpty {
                Text("Enregistrement gardé (utilisé par un autre morceau du manifeste) : "
                     + shared.map { $0.id }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Rien n'est effacé : tout peut être récupéré dans la Corbeille du Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { ui.removal = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Retirer", role: .destructive) {
                    let choice = RemovalChoice(ids: items.map(\.id), analyse: ui.removeAnalyse,
                                               corrections: ui.removeCorrections,
                                               audio: ui.removeAudio && RemovalItem.audioOffered(items))
                    ui.removal = nil
                    for id in choice.ids { dismissWindow(id: "editor", value: id) }
                    Task { await model.remove(choice) }
                }
                .disabled(model.locked)
            }
        }
        .padding(20)
        .frame(width: 520)
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

    func markCell(_ s: SongState) -> some View {
        MarkView(mark: model.marks[s.id], paused: model.runState == .paused, reanalyse: s.needsReanalysis)
    }

    func titleCell(_ s: SongState) -> some View {
        CommitField(value: s.titre, enabled: !model.locked) { commit(s, "titre", $0) }
    }

    func artistCell(_ s: SongState) -> some View {
        CommitField(value: s.artiste, enabled: !model.locked) { commit(s, "artiste", $0) }
    }

    /// Unfolded: each checkbox with its label. Folded (click the header): the checkboxes alone, named on hover.
    func retirerCell(_ s: SongState) -> some View {
        let folded = model.retirerCollapsed
        return HStack(spacing: folded ? 2 : 6) {
            ForEach(RETIRER, id: \.0) { stem, label in
                Toggle(folded ? "" : label, isOn: Binding(get: { current(s).retirer.contains(stem) }, set: { on in
                    commit(s, "retirer", Retirer.toggled(current(s).retirer, stem, on: on, order: RETIRER.map(\.0)))
                }))
                .toggleStyle(.checkbox).font(.caption)
                .help(label)
                .disabled(model.locked)
            }
        }
    }

    func langueCell(_ s: SongState) -> some View {
        Picker("", selection: Binding(get: { s.langue }, set: { commit(s, "langue", $0) })) {
            ForEach(Array(Set(LANGUES + [s.langue])).sorted(), id: \.self) { Text($0) }
        }
        .labelsHidden()
        .disabled(model.locked)
    }

    func statutCell(_ s: SongState) -> some View {
        HStack(spacing: 6) {
            statutText(s)
            Text((s.alertes ?? []).joined(separator: " · ")).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .help(Help.statut(s.statut, alertes: s.alertes ?? []))
    }

    func stepsCell(_ s: SongState) -> some View {
        HStack(spacing: 3) {
            ForEach(s.steps, id: \.name) { st in
                Circle()
                    .fill(color(step: st, running: model.currentID == s.id && model.currentStep == st.name))
                    .frame(width: 9, height: 9)
                    .help(Help.step(st))
            }
        }
    }

    /// ✏️ opens Corriger, ▶️ loads the song in the Lecteur and plays it — on analysed songs only.
    @ViewBuilder func quickActions(_ s: SongState) -> some View {
        if s.stepsDone > 0 {
            HStack(spacing: 2) {
                Button("✏️") { openWindow(id: "editor", value: s.id) }
                    .help("Corriger paroles et accords")
                    .disabled(model.locked)
                Button("▶️") {
                    PlayerModel.shared.openInPlayer(s.id)
                    if !PlayerModel.shared.isPlaying { PlayerModel.shared.togglePlay() }
                }
                .help("Écouter dans le Lecteur")
                .disabled(!PlayerModel.shared.missing(for: s).isEmpty)
            }
            .buttonStyle(.borderless)
        }
    }

    func correctionsCell(_ s: SongState) -> some View {
        HStack(spacing: 2) {
            if s.musicEdited { Text("♬") }
            if s.lyricsEdited { Text("🎤") }
        }
        .frame(maxWidth: .infinity)
        .help(s.correctionsHelp)
    }

    func statutText(_ s: SongState) -> some View {
        Text(s.isVerified ? "vérifié" : statutLabel(s.statut)).bold()
            .foregroundStyle(s.isVerified ? Color.green : color(statut: s.statut))
    }

    func bpmCell(_ s: SongState) -> some View {
        Text(s.bpmRounded.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    func keyCell(_ s: SongState) -> some View {
        Text(s.keyShort).foregroundStyle(.secondary).help(s.key ?? "")
    }

    func verifiedCell(_ s: SongState) -> some View {
        let help = s.isVerified
            ? "Vérifié le \(s.verifie ?? "") — cliquer pour retirer ; retiré aussi si une analyse change paroles, accords, mix ou vidéo"
            : "Marquer comme vérifié"
        return Button {
            commit(s, "verifie", s.isVerified ? "" : Self.today)
        } label: {
            Image(systemName: s.isVerified ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(s.isVerified ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(model.locked)
        .help(help)
        .frame(maxWidth: .infinity)
    }

    /// Fixed width showing the whole header (in the table header's own font, with room for the sort arrow), never
    /// narrower than the cells need.
    /// « Retirer » sized to what it shows: the five labelled checkboxes, or folded the bare checkboxes (or its
    /// header, if wider).
    static func retirerWidth(folded: Bool) -> CGFloat {
        let box: CGFloat = 18
        if folded { return headerFit("Retirer ▸", content: CGFloat(RETIRER.count) * (box + 2) + 12) }
        let caption = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let labels = RETIRER.map { ceil(($0.1 as NSString).size(withAttributes: [.font: caption]).width) }
        return labels.reduce(0) { $0 + box + 4 + $1 } + CGFloat(RETIRER.count - 1) * 6 + 16
    }

    static func headerFit(_ title: String, content: CGFloat) -> CGFloat {
        let font = NSTableHeaderCell().font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return max(content, text + 30)        // cell insets (~16) + sort arrow (~14)
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

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
    var alignment: NSTextAlignment = .natural
    let onCommit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: value)
        f.isBordered = false
        f.drawsBackground = false
        f.alignment = alignment
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
    var reanalyse = false
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
        case nil:
            if reanalyse {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    .help("À réanalyser : des corrections ou des réglages ont changé — « Analyser » les applique")
            } else {
                Color.clear
            }
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
