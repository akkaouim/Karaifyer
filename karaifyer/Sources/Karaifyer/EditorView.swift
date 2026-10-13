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
                Text("Enregistrer réanalyse le morceau (vidéo, set, iReal).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { closeAsking() }
                Button("Enregistrer") {
                    do { try model.save(); dismiss() } catch { KaraokeUI.shared.alert = error.localizedDescription }
                }
                .keyboardShortcut("s")
                .disabled(!model.dirty)
            }
            .padding(8)
        }
        .navigationTitle("Corriger — \(model.song.id) \(model.song.titre)")
        .alert(KaraokeUI.shared.alert ?? "", isPresented: Binding(get: { KaraokeUI.shared.alert != nil },
                                                                   set: { if !$0 { KaraokeUI.shared.alert = nil } })) {}
    }

    var playerBar: some View {
        HStack {
            Button(model.playing ? "Pause" : "Lecture", systemImage: model.playing ? "pause.fill" : "play.fill") {
                model.playing ? model.pause() : model.play()
            }
            .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { model.position }, set: { model.seek(input: $0) }), in: 0...max(model.duration, 1))
            Text(LRC.timecode(model.showTime)).monospacedDigit().frame(width: 70)
        }
    }

    var lyrics: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Paroles").font(.headline)
                Spacer()
                Button("Ligne", systemImage: "plus") { model.addLine() }
            }
            List {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { i, line in
                    HStack {
                        Button("Caler", systemImage: "stopwatch") { model.stampLine(i) }
                            .labelStyle(.iconOnly).help("Caler le début de la ligne sur la lecture")
                        CommitField(value: LRC.timecode(line.time)) { model.setTime(i, $0) }.frame(width: 70)
                        CommitField(value: line.text) { model.setText(i, $0) }
                        Button("Supprimer", systemImage: "trash") { model.deleteLine(i) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    .padding(2)
                    .background(i == model.currentLine ? Color.yellow.opacity(0.25) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.seekLine(i) }
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
                CommitField(value: model.key) { model.setKey($0) }.frame(width: 110)
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
                            CommitField(value: cell) { model.setCell(i, $0) }
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
