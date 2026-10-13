import AppKit
import Observation
import SwiftUI

/// Re-read on every change so the window updates without @State (Pipeline reads UserDefaults).
@Observable final class SettingsStore {
    static let shared = SettingsStore()
    var revision = 0
    func set(_ key: String, _ value: String?) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        revision += 1
        Task { @MainActor in await KaraokeModel.shared.refresh() }
    }
}

struct SettingsView: View {
    let store = SettingsStore.shared

    var body: some View {
        let _ = store.revision          // observe changes
        let p = Pipeline()
        let problems = p.problems()
        Form {
            row("Dossier karaoké", key: "karaokeHome", value: p.karaokeHome, folder: true)
            row("Gabarit Ableton", key: "gabarit", value: p.gabarit, folder: false)
            row("Projet karaoke (code)", key: "projectDir", value: p.projectDir, folder: true)
            Text(problems.isEmpty ? "Tout est prêt." : problems.joined(separator: "\n"))
                .foregroundStyle(problems.isEmpty ? .green : .orange)
        }
        .padding(20)
        .frame(width: 680)
    }

    func row(_ label: String, key: String, value: String, folder: Bool) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
            Button("Choisir…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = folder
                panel.canChooseFiles = !folder
                if panel.runModal() == .OK, let u = panel.url { store.set(key, u.path) }
            }
            Button("Défaut") { store.set(key, nil) }
        }
    }
}
