import AppKit
import KaraifyerCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let e = model.loadError { Text(e).foregroundStyle(.orange).padding(6) }
            playerBar.padding(8)
            HSplitView {
                lyrics.frame(minWidth: 420)
                chords.frame(minWidth: 420)
            }
            HStack {
                Button("Annuler la modification", systemImage: "arrow.uturn.backward") { endEditing(); model.undo() }
                    .labelStyle(.iconOnly).disabled(!model.canUndo).help("Annuler la modification (⌘Z)")
                Button("Rétablir", systemImage: "arrow.uturn.forward") { endEditing(); model.redo() }
                    .labelStyle(.iconOnly).disabled(!model.canRedo).help("Rétablir (⇧⌘Z)")
                Text("Enregistrer réanalyse le morceau (vidéo, set, iReal).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { endEditing(); closeAsking() }
                Button("Enregistrer") {
                    endEditing()          // commit the field being typed in first
                    guard model.dirty else { return }
                    do { try model.save(); dismiss() } catch { KaraokeUI.shared.alert = error.localizedDescription }
                }
                .keyboardShortcut("s")
            }
            .padding(8)
        }
        .navigationTitle(model.windowTitle)
        .onAppear { model.installSpaceKey() }
        .onDisappear { model.removeSpaceKey(); ProgressionPanel.close(id: model.song.id) }
        .sheet(isPresented: $model.importShown) { importSheet }
        .sheet(isPresented: $model.replaceShown) { replaceSheet }
        .background(WindowPlacer())   // open over the main window, on its screen, in front
        .alert(KaraokeUI.shared.alert ?? "", isPresented: Binding(get: { KaraokeUI.shared.alert != nil },
                                                                   set: { if !$0 { KaraokeUI.shared.alert = nil } })) {}
    }

    var playerBar: some View {
        HStack {
            Button(model.playing && !model.syncPaused ? "Pause" : "Lecture",
                   systemImage: model.playing && !model.syncPaused ? "pause.fill" : "play.fill") {
                if model.syncing { model.syncTogglePause() } else { model.playing ? model.pause() : model.play() }
            }
            .keyboardShortcut(.space, modifiers: .option)   // a bare Space would be stolen from text fields
            .help("Lecture / pause (Espace hors saisie, ou ⌥ Espace)")
            Slider(value: Binding(get: { model.position }, set: { model.seek(input: $0) }), in: 0...max(model.duration, 1))
                .disabled(model.syncing)
            Text(LRC.timecode(model.showTime)).monospacedDigit().frame(width: 70)
            if let b = model.beatCounter {
                Text("\(b.beat)/\(b.of)").monospacedDigit().frame(width: 36)
                    .foregroundStyle(b.beat == 1 ? Color.primary : Color.secondary)
                    .help("Temps en cours / temps dans la mesure")
            }
            Divider().frame(height: 16)
            Toggle("Clic", isOn: $model.clickOn).toggleStyle(.checkbox).disabled(!model.gridAvailable)
                .help("Clic sur chaque temps, plus aigu sur le temps 1")
            Slider(value: Binding(get: { Double(model.clickVolume) }, set: { model.clickVolume = Float($0) }), in: 0...1)
                .frame(width: 80).disabled(!model.clickOn).help("Volume du clic")
            Divider().frame(height: 16)
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), in: 0...1)
                .frame(width: 110)
                .help("Volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    var lyrics: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Paroles").font(.headline)
                Spacer()
                Menu("Synchroniser") {
                    Button("Synchroniser") { model.startSync(fromSelected: false) }
                    Button("Synchroniser à partir de la ligne sélectionnée") { model.startSync(fromSelected: true) }
                        .disabled(model.selectedLine == nil)
                } primaryAction: { model.startSync(fromSelected: false) }
                .fixedSize()
                .disabled(!model.syncAvailable || model.syncing)
                .help(model.syncAvailable ? "Lancer le morceau (avec le décompte) et caler chaque ligne avec Entrée" : "Analyser le morceau d'abord")
                Button("Remplacer le texte…") {
                    endEditing()
                    model.replaceDraft = model.lines.map(\.text).joined(separator: "\n")
                    model.replaceShown = true
                }
                .disabled(model.syncing && !model.syncPaused)
                Button("Ligne", systemImage: "plus") { endEditing(); model.addLine() }
            }
            if model.syncing { syncPanel }
            if let m = model.syncMessage { Text(m).font(.caption).foregroundStyle(.green) }
            List {
                ForEach(model.lines) { line in
                    let id = line.id
                    HStack {
                        Button("Aller", systemImage: "arrow.right.to.line") { endEditing(); model.seekLine(id) }
                            .disabled(model.syncing)
                            .labelStyle(.iconOnly).help("Placer la lecture au début de cette ligne")
                        Button("Caler", systemImage: "stopwatch") { endEditing(); model.stampLine(id) }
                            .labelStyle(.iconOnly).help("Caler le début de la ligne sur la lecture")
                        CommitField(value: LRC.timecode(line.time), resignOnCommit: true) { model.setTime(id, $0) }.frame(width: 70)
                        CommitField(value: line.text, resignOnCommit: true) { model.setText(id, $0) }
                        Button("Supprimer", systemImage: "trash") { endEditing(); model.deleteLine(id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    .padding(2)
                    .background(model.syncing && model.syncActiveID == id ? Color.accentColor.opacity(0.25)
                                : model.currentLine.map { model.lines[$0].id == id } == true ? Color.yellow.opacity(0.25) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if !model.syncing { model.seekLine(id) } else { model.selectedLine = id } }
                }
            }
        }
        .padding(8)
    }

    var chords: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Accords").font(.headline)
                Text("Tonalité :")
                CommitField(value: model.key, resignOnCommit: true) { model.setKey($0) }.frame(width: 110)
                    .help("ex. C# minor, Db major")
                Picker("", selection: Binding(get: { model.fix.signature ?? "" },
                                              set: { model.setSignature($0.isEmpty ? nil : $0) })) {
                    Text("Détectée (\(model.song.grid?.beatsPerBarDetecte ?? model.bpb)/4)").tag("")
                    ForEach(BarGrid.menu, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 165).disabled(!model.gridAvailable)
                Toggle("Swing", isOn: Binding(get: { model.fix.swing }, set: { model.setSwing($0) }))
                    .toggleStyle(.checkbox).disabled(!model.gridAvailable)
            }
            Text("« A B » = moitié-moitié · « Am . . F » = un symbole par temps · N.C. = sans accord · ex. Cmaj7 Dm7 G7 Am/G Gsus4 Edim7")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Rechercher la grille…") { searchChart() }
                Button("Importer une grille…") { model.importDraft = ""; model.importShown = true }
                Button("Afficher la progression d'accords") {
                    if let raw = model.song.progression {
                        let orig = model.song.progressionOriginale.map(ProgressionText.plain)
                        let text = ProgressionText.plain(raw)
                        ProgressionPanel.show(id: model.song.id, kind: "progression",
                                              title: "Progression — \(model.song.id) \(model.song.titre)", text: text,
                                              original: orig, note: orig != nil && orig != text ? "dans la tonalité du morceau" : nil)
                    }
                }
                .disabled(model.song.progression == nil)
                .help(model.song.progression == nil ? "Pas de progression Chordonomicon pour ce morceau" : "Progression complète (Chordonomicon)")
                if model.merging { ProgressView().controlSize(.small) }
            }
            if model.showSuggestion, let src = model.song.grilleProposee {
                HStack {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    Text("Grille trouvée dans \(src) : appliquer ?")
                    Spacer()
                    Button("Visualiser") { model.viewChart(source: src) }
                    Button("Appliquer") { endEditing(); model.runMerge(texte: nil, source: src) }
                    Button("Ignorer") { model.suggestionIgnored = true }
                }
                .padding(6)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            if let s = model.mergeSummary {
                Text(s).font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(model.cells.enumerated()), id: \.offset) { i, cell in
                        VStack(spacing: 0) {
                            HStack(spacing: 3) {
                                Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                                if model.hasPin(i) {
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Mesure verrouillée")
                                }
                                Spacer()
                                if let n = model.beatCount(i) {
                                    Text("\(n) t.").font(.caption2).monospacedDigit()
                                        .foregroundStyle(n == model.bpb ? Color.secondary : Color.orange)
                                        .help("\(n) temps dans cette mesure")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { if !model.syncing { model.seekBar(i) } }
                            .contextMenu {
                                Text("Corrige où tombe le temps 1 ; la suite est recomptée jusqu'à la prochaine mesure verrouillée")
                                Divider()
                                Button("Décaler le début de la mesure d'un temps plus tôt (et les suivantes)") { endEditing(); model.moveBar(i, by: -1) }
                                Button("Décaler le début de la mesure d'un temps plus tard (et les suivantes)") { endEditing(); model.moveBar(i, by: 1) }
                                Divider()
                                if model.hasPin(i) {
                                    Button("Déverrouiller cette mesure") { endEditing(); model.unpinBar(i) }
                                } else {
                                    Button("Verrouiller cette mesure (les corrections précédentes ne la décaleront pas)") { endEditing(); model.pinBar(i) }
                                }
                                if !model.gridAvailable { Text("Réanalyser le morceau pour corriger la grille") }
                            }
                            CommitField(value: cell, resignOnCommit: true) { model.setCell(i, $0) }
                        }
                        .padding(4)
                        .background(i == model.currentBar ? Color.yellow.opacity(0.25) : Color.gray.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                            model.cellErrors[i] != nil ? Color.red : model.flagged.contains(i) ? Color.orange : Color.clear,
                            lineWidth: model.flagged.contains(i) && model.cellErrors[i] == nil ? 2 : 1))
                        .help(model.cellErrors[i] ?? (model.flagged.contains(i) ? "grille et audio diffèrent : à vérifier à l'oreille"
                              : "Clic sur le numéro : aller à la mesure · clic droit : corriger le temps 1"))
                    }
                }
            }
        }
        .padding(8)
    }

    /// Ultimate Guitar and La Boîte à chansons searches in the browser: Michel picks the version he trusts.
    func searchChart() {
        let q = "\(model.song.titre) \(model.song.artiste)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        for u in ["https://www.ultimate-guitar.com/search.php?search_type=title&value=\(q)",
                  "https://www.boiteachansons.net/recherche?q=\(q)"] {
            if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        }
    }

    var importSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Importer une grille").font(.headline)
            Text("Coller une grille (accords au-dessus des paroles, ChordPro, patadata) ou ouvrir un fichier.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.importDraft).font(.system(.body, design: .monospaced)).frame(minWidth: 560, minHeight: 360)
            HStack {
                Button("Ouvrir un fichier…") {
                    let panel = NSOpenPanel()
                    // .sg / ChordPro have no system type: name them, or they show greyed out
                    panel.allowedContentTypes = [.plainText, .text]
                        + ["sg", "cho", "chopro", "crd", "pro", "chordpro"].compactMap { UTType(filenameExtension: $0) }
                    if panel.runModal() == .OK, let u = panel.url, let t = try? String(contentsOf: u, encoding: .utf8) {
                        model.importDraft = t
                    }
                }
                Spacer()
                Button("Annuler") { model.importShown = false }.keyboardShortcut(.cancelAction)
                Button("Appliquer") {
                    let t = model.importDraft
                    model.importShown = false
                    model.runMerge(texte: t, source: nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.importDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    /// Sync mode: the line to stamp, large, between its neighbours, with the keys to use.
    var syncPanel: some View {
        let ids = model.syncIDs
        let current = model.sync?.current.flatMap { ids.firstIndex(of: $0) }      // being sung: blank until Entrée
        let next = model.sync?.active.flatMap { ids.firstIndex(of: $0) }
        func text(_ i: Int?) -> String {
            guard let i, ids.indices.contains(i), let l = model.lines.first(where: { $0.id == ids[i] }) else { return " " }
            return l.text
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(text(current.map { $0 - 1 })).foregroundStyle(.secondary).lineLimit(1)
            Text(text(current)).font(.title2.weight(.semibold)).lineLimit(2)
            Text(next == nil ? "Toutes les lignes sont calées" : "à venir : " + text(next)).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                if let p = model.sync?.progress { Text("\(p.done) / \(p.total)").monospacedDigit() }
                if model.syncPaused { Text("en pause — le texte peut être modifié").foregroundStyle(.orange) }
                Spacer()
                Text("Entrée : caler la ligne · ↑ : annuler · Espace : pause · Échap : quitter")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Quitter") { model.stopSync(done: false) }
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    var replaceSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remplacer le texte").font(.headline)
            Text("Une ligne par ligne de paroles. ⌘A puis ⌘V pour tout remplacer ; les lignes inchangées gardent leur temps.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.replaceDraft).frame(minWidth: 560, minHeight: 360)
            HStack {
                Spacer()
                Button("Annuler") { model.replaceShown = false }.keyboardShortcut(.cancelAction)
                Button("Valider") {
                    let t = model.replaceDraft
                    model.replaceShown = false
                    model.replaceText(t)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    func closeAsking() {
        if model.dirty {
            let a = NSAlert()
            a.messageText = "Abandonner les modifications ?"
            a.addButton(withTitle: "Abandonner")
            a.addButton(withTitle: "Continuer")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        dismiss()
    }
}


/// Michel's editor opened on the laptop screen while Karaifyer was on the external monitor, so it
/// looked like nothing happened: centre the editor over the main window, on the same screen, in front.
struct WindowPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            if let main = NSApp.windows.first(where: { $0 !== w && $0.title == "Karaifyer" && $0.isVisible }),
               let screen = main.screen {
                var f = w.frame
                f.origin = NSPoint(x: main.frame.midX - f.width / 2, y: main.frame.midY - f.height / 2)
                let vis = screen.visibleFrame
                f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
                f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
                w.setFrame(f, display: true)
            }
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
