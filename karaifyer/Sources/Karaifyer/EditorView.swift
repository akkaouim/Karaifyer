import AppKit
import KaraifyerCore
import SwiftUI

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
        .onDisappear { model.removeSpaceKey() }
        .background(WindowPlacer())   // open over the main window, on its screen, in front
        .alert(KaraokeUI.shared.alert ?? "", isPresented: Binding(get: { KaraokeUI.shared.alert != nil },
                                                                   set: { if !$0 { KaraokeUI.shared.alert = nil } })) {}
    }

    var playerBar: some View {
        HStack {
            Button(model.playing ? "Pause" : "Lecture", systemImage: model.playing ? "pause.fill" : "play.fill") {
                model.playing ? model.pause() : model.play()
            }
            .keyboardShortcut(.space, modifiers: .option)   // a bare Space would be stolen from text fields
            .help("Lecture / pause (Espace hors saisie, ou ⌥ Espace)")
            Slider(value: Binding(get: { model.position }, set: { model.seek(input: $0) }), in: 0...max(model.duration, 1))
            Text(LRC.timecode(model.showTime)).monospacedDigit().frame(width: 70)
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
                Button("Ligne", systemImage: "plus") { endEditing(); model.addLine() }
            }
            List {
                ForEach(model.lines) { line in
                    let id = line.id
                    HStack {
                        Button("Aller", systemImage: "arrow.right.to.line") { endEditing(); model.seekLine(id) }
                            .labelStyle(.iconOnly).help("Placer la lecture au début de cette ligne")
                        Button("Caler", systemImage: "stopwatch") { endEditing(); model.stampLine(id) }
                            .labelStyle(.iconOnly).help("Caler le début de la ligne sur la lecture")
                        CommitField(value: LRC.timecode(line.time), resignOnCommit: true) { model.setTime(id, $0) }.frame(width: 70)
                        CommitField(value: line.text, resignOnCommit: true) { model.setText(id, $0) }
                        Button("Supprimer", systemImage: "trash") { endEditing(); model.deleteLine(id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    .padding(2)
                    .background(model.currentLine.map { model.lines[$0].id == id } == true ? Color.yellow.opacity(0.25) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.seekLine(id) }
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
                Text("\(model.bpb)/4").foregroundStyle(.secondary)
            }
            Text("« A B » = moitié-moitié · « Am . . F » = un symbole par temps · N.C. = sans accord · ex. Cmaj7 Dm7 G7 Am/G")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(model.cells.enumerated()), id: \.offset) { i, cell in
                        VStack(spacing: 0) {
                            Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { model.seekBar(i) }
                            CommitField(value: cell, resignOnCommit: true) { model.setCell(i, $0) }
                        }
                        .padding(4)
                        .background(i == model.currentBar ? Color.yellow.opacity(0.25) : Color.gray.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.cellErrors[i] == nil ? Color.clear : Color.red))
                        .help(model.cellErrors[i] ?? "Cliquer sur le numéro pour aller à la mesure")
                    }
                }
            }
        }
        .padding(8)
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
