import KaraifyerCore
import SwiftUI

/// « Ajouter un morceau… »: a Spotify link (and who proposed it) instead of a CSV row. The song's title and artist
/// are looked up on its public Spotify page as a preview; the recording takes Spotify's own metadata.
@MainActor @Observable final class AddTrackUI {
    static let shared = AddTrackUI()
    var shown = false
    var link = "" { didSet { if link != oldValue { lookUp() } } }
    var proposer = ""
    var trackID: String?
    var preview: SpotifyPage.Track?
    var status = ""
    @ObservationIgnored private var lookup: Task<Void, Never>?

    func open() {
        link = ""
        proposer = ""
        trackID = nil
        preview = nil
        status = ""
        shown = true
    }

    private func lookUp() {
        lookup?.cancel()
        preview = nil
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        trackID = TrackList.extractTrackID(text)
        guard let id = trackID else {
            status = text.isEmpty ? "" : "Ce n'est pas un lien vers un morceau Spotify (album, playlist ?)."
            return
        }
        let q = QueueModel.shared
        if let row = q.rows.first(where: { $0.trackID == id }) {
            status = "Déjà dans la liste (ligne \(row.number))."
            return
        }
        status = "Recherche…"
        lookup = Task {
            let found: SpotifyPage.Track? = await {
                guard let (data, _) = try? await URLSession.shared.data(for: SpotifyPage.request(trackID: id)) else { return nil }
                return SpotifyPage.parse(html: String(decoding: data, as: UTF8.self))
            }()
            guard !Task.isCancelled, trackID == id else { return }
            preview = found
            let probe = TrackRow(index: -1, number: "", title: "", artist: "", proposer: "", trackID: id, duplicateOf: nil)
            let already = q.existingFile(for: probe).map { " Déjà enregistré : « \($0.lastPathComponent) »." } ?? ""
            status = (found == nil ? "Titre introuvable (hors ligne ?) : il sera lu dans Spotify à l'enregistrement." : "") + already
        }
    }

    var canAdd: Bool {
        guard let id = trackID else { return false }
        return !QueueModel.shared.rows.contains { $0.trackID == id }
    }
}

struct AddTrackSheet: View {
    let model: QueueModel
    let ui = AddTrackUI.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajouter un morceau").font(.headline)
            TextField("Lien Spotify du morceau", text: Bindable(ui).link)
                .textFieldStyle(.roundedBorder)
            if let p = ui.preview {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                    Text(p.title).bold()
                    Text("— \(p.artist)" + (p.album.isEmpty ? "" : " (\(p.album))")).foregroundStyle(.secondary)
                }
            }
            if !ui.status.isEmpty { Text(ui.status).font(.caption).foregroundStyle(.secondary) }
            TextField("Proposé par (facultatif)", text: Bindable(ui).proposer)
                .textFieldStyle(.roundedBorder)
            Text("Le morceau est ajouté à la fin de la liste pour cette session ; « Start » l'enregistre comme les autres.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { ui.shown = false }.keyboardShortcut(.cancelAction)
                Button("Ajouter") {
                    guard let id = ui.trackID else { return }
                    model.addManual(trackID: id, title: ui.preview?.title ?? "", artist: ui.preview?.artist ?? "",
                                    proposer: ui.proposer.trimmingCharacters(in: .whitespaces))
                    ui.shown = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ui.canAdd || model.isRunning)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
