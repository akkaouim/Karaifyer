import AppKit
import KaraifyerCore
import SwiftUI

/// The one-time move to « Titre - Artiste » names in one recordings folder (other CSVs' subfolders brought in).
struct RecorderMigrationJob: Sendable {
    let target: URL
    let plan: RecordingMigration.Plan
    let switchesFolder: Bool

    /// Reads the folders' tags off the main thread (ffprobe per file the first time).
    static func compute(outputRoot: URL, listName: String?) -> RecorderMigrationJob? {
        let fm = FileManager.default
        func audio(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { ["flac", "mp3"].contains(($0 as NSString).pathExtension.lowercased()) }
        }
        let start = RecordingMigration.outputFolder(savedRoot: outputRoot.path, listName: listName,
                                                    dirHasRecordings: { audio($0).contains { $0.hasSuffix(".flac") } })
            ?? outputRoot.path
        func numberedCount(_ dir: String) -> Int { audio(dir).filter { RecordingMigration.isNumbered($0) }.count }
        let subCounts = Dictionary(uniqueKeysWithValues: ((try? fm.contentsOfDirectory(atPath: start)) ?? [])
            .map { (start as NSString).appendingPathComponent($0) }.map { ($0, numberedCount($0)) })
        let home = RecordingMigration.descend(start: start, ownCount: numberedCount(start), subfolderCounts: subCounts)
        let target = RecordingMigration.target(start: home, hasNumbered: { numberedCount($0) > 0 })
        let targetURL = URL(fileURLWithPath: target)
        func scan(_ dir: URL) -> [String: RecordingIndex.Entry] {
            var idx = RecordingIndex.load(dir: dir)
            let listing = audio(dir.path).map { n -> (name: String, size: Int64, mtime: Double) in
                let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
                return (n, (a?[.size] as? Int64) ?? 0, ((a?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)
            }
            _ = idx.refresh(listing: listing) { RecordingTags.read(dir.appendingPathComponent($0)) }
            return idx.entries
        }
        let main = scan(targetURL)
        var subs: [String: [String: RecordingIndex.Entry]] = [:]
        var others = ((try? fm.contentsOfDirectory(atPath: target)) ?? []).filter { main[$0] == nil }
        for sub in others {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: targetURL.appendingPathComponent(sub).path, isDirectory: &isDir), isDir.boolValue else { continue }
            let entries = scan(targetURL.appendingPathComponent(sub))
            if !entries.isEmpty { subs[sub] = entries }
            others += ((try? fm.contentsOfDirectory(atPath: targetURL.appendingPathComponent(sub).path)) ?? [])
                .filter { $0.hasSuffix(".asd") }.map { "\(sub)/\($0)" }
        }
        let incoming = RecordingMigration.incoming(main: main, subfolders: subs)
        let plan = RecordingMigration.renames(entries: main, others: others, incoming: incoming)
        let switches = targetURL.standardizedFileURL != outputRoot.standardizedFileURL
        return plan.renames.isEmpty && !switches ? nil : RecorderMigrationJob(target: targetURL, plan: plan, switchesFolder: switches)
    }
}

@Observable final class QueueUI {
    static let shared = QueueUI()
    var migration: RecorderMigrationJob?
    var migrating = false
}

struct RecorderMigrationSheet: View {
    let job: RecorderMigrationJob
    let model: QueueModel
    let ui = QueueUI.shared

    var body: some View {
        let moved = job.plan.renames.filter { $0.from.contains("/") }.count
        VStack(alignment: .leading, spacing: 10) {
            Text("Nouveaux noms des enregistrements").font(.headline)
            Text("Les fichiers s'appelleront « Titre - Artiste », sans numéro, tous dans « \(job.target.lastPathComponent) »"
                 + (moved > 0 ? " (\(moved) fichier(s) des sous-dossiers des autres listes y sont rangés)" : "")
                 + ". Le dossier de sortie devient ce dossier. Le manifeste karaoké suit (une copie est gardée) ; "
                 + "rien n'est réanalysé. Chaque changement est noté dans sysrec-log.txt.")
                .fixedSize(horizontal: false, vertical: true)
            if job.switchesFolder { Text("Dossier : \(job.target.path)").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(job.plan.renames, id: \.from) { r in
                        Text("\(r.from)  →  \(r.to)").font(.caption).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(job.plan.duplicates.contains(r.to) ? .orange : .primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            if !job.plan.duplicates.isEmpty {
                Text("En orange : copies en double d'un même morceau, gardées avec un suffixe ; à supprimer vous-même.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Les autres sous-dossiers (par exemple « old takes ») ne sont pas touchés.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if ui.migrating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Plus tard", role: .cancel) { ui.migration = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(ui.migrating)
                Button("Mettre à jour") { Task { await model.migrate(job) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ui.migrating || model.isRunning)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}
