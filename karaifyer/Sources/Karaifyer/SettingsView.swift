import AppKit
import KaraifyerCore
import Observation
import SwiftUI

/// Re-read on every change so the window updates without @State (Pipeline reads UserDefaults).
@Observable final class SettingsStore {
    static let shared = SettingsStore()
    var revision = 0
    var grillesStatus: String?

    /// Download the open chord charts, then link Spotify ids from the recording sheet Karaifyer last opened.
    func downloadCharts() {
        let p = Pipeline()
        let sheet = UserDefaults.standard.url(forKey: "lastList")?.path
        let env = p.env, cwd = p.projectDir
        let dl = p.args(["grilles", "telecharger"])
        let link = sheet.map { p.args(["grilles", "lier", "--feuille", $0]) }
        grillesStatus = "téléchargement…"
        Task.detached {
            var status: String
            switch EditorModel.runProcess(args: dl, env: env, cwd: cwd, input: nil) {
            case .failure(let e): status = "échec : \(e.message)"
            case .success:
                status = "à jour"
                if let link, case .success(let out) = EditorModel.runProcess(args: link, env: env, cwd: cwd, input: nil) {
                    status = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? status
                }
            }
            let final = status
            await MainActor.run {
                self.grillesStatus = final
                self.revision += 1
                Task { await KaraokeModel.shared.refresh() }
            }
        }
    }
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
            HStack {
                Text("Détecteur d'accords").frame(width: 170, alignment: .leading)
                Picker("", selection: Binding(get: { ChordEngine.from(saved: UserDefaults.standard.string(forKey: "chordEngine")) },
                                              set: { store.set("chordEngine", $0.rawValue) })) {
                    ForEach(ChordEngine.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 260)
                Spacer()
            }
            Text("S'applique aux analyses suivantes ; changer de détecteur refait l'étape des accords (≈ 10 s par morceau). La première utilisation installe le détecteur (connexion requise une fois).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Grilles ouvertes").frame(width: 170, alignment: .leading)
                Text(chartsDate(p)).foregroundStyle(.secondary)
                Spacer()
                if let s = store.grillesStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                Button("Télécharger") { store.downloadCharts() }.disabled(store.grillesStatus == "téléchargement…")
            }
            Text("Chordonomicon (CC BY-NC 4.0, d'après Ultimate Guitar) et patadata (sans licence déclarée) : usage privé. ≈ 100 Mo, une fois ; les morceaux sont reliés par la feuille d'enregistrement.")
                .font(.caption).foregroundStyle(.secondary)
            Text(problems.isEmpty ? "Tout est prêt." : problems.joined(separator: "\n"))
                .foregroundStyle(problems.isEmpty ? .green : .orange)
        }
        .padding(20)
        .frame(width: 680)
    }

    func chartsDate(_ p: Pipeline) -> String {
        let path = p.karaokeHome + "/grilles/correspondances.json"
        guard let d = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            return "pas encore téléchargées"
        }
        return "copie du " + d.formatted(date: .abbreviated, time: .omitted)
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
