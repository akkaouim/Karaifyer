import AppKit
import KaraifyerCore
import Observation
import SwiftUI

/// Mix export: the engine renders the whole song offline to a 24-bit WAV (what is heard: faders, mutes,
/// solos, master, tempo, pitch), then ffmpeg encodes it in the chosen format and quality.
@MainActor @Observable final class ExportUI {
    static let shared = ExportUI()
    @ObservationIgnored private var renderedVideo: URL?
    var shown = false
    var options = ExportOptions.decode(UserDefaults.standard.data(forKey: "playerExport"))
    var running = false
    var progress = 0.0
    var message: String?
    var lastFile: URL?
    @ObservationIgnored var cancelled = false
    @ObservationIgnored var ffmpeg: SpawnedProcess?

    func remember() { UserDefaults.standard.set(options.encoded(), forKey: "playerExport") }

    func run(player: PlayerModel) {
        guard let s = player.loaded, let engine = player.exportEngine() else { return }
        remember()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportOptions.fileName(id: s.id, titre: s.titre, ext: options.ext)
        panel.directoryURL = URL(fileURLWithPath: s.paths.dossier)
        guard panel.runModal() == .OK, let out = panel.url else { return }
        guard let ff = Pipeline.searchPath.map({ $0 + "/ffmpeg" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            message = "ffmpeg introuvable : brew install ffmpeg"
            return
        }
        player.stopEverything()
        running = true; cancelled = false; progress = 0; message = nil; lastFile = nil
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("karaifyer-mix-\(UUID().uuidString).wav")
        let total = ExportOptions.duration(songSeconds: engine.length, rate: player.rate)

        // 0. the video, drawn by the live renderer at the export's layout, transposition and tempo (first 40 %)
        var video = s.paths.video, timed = false, share = 0.0
        if options.kind == .videoMaster, let scene = player.scene {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("karaifyer-video-\(UUID().uuidString).mp4")
            share = 0.4
            do {
                try VideoExporter.export(scene: scene, to: tmp, layout: player.videoLayout, transpose: player.settings.semitones,
                                         rate: Double(player.rate)) { p in
                    MainActor.assumeIsolated { self.progress = p * share }
                    RunLoop.main.run(until: Date())
                    return !MainActor.assumeIsolated { self.cancelled }
                }
                video = tmp.path
                timed = true
                renderedVideo = tmp
            } catch {
                finish(error: cancelled ? nil : "Vidéo : \(error.localizedDescription)", out: out, wav: wav)
                return
            }
        }

        // 1. render (first half of what's left); the run loop is pumped so the sheet stays responsive
        do {
            try engine.renderOffline(to: wav) { p in
                MainActor.assumeIsolated { self.progress = share + p * (1 - share) / 2 }
                RunLoop.main.run(until: Date())
                return !MainActor.assumeIsolated { self.cancelled }
            }
        } catch {
            finish(error: cancelled ? nil : "Rendu impossible : \(error.localizedDescription)", out: out, wav: wav)
            return
        }

        // 2. encode with ffmpeg (second half), progress from « -progress pipe:1 » (out_time_us)
        let args = [ff, "-y", "-progress", "pipe:1", "-nostats", "-loglevel", "error"]
            + options.ffmpegArgs(wav: wav.path, video: video, rate: player.rate, out: ExportOptions.partialURL(for: out).path,
                                 videoTimed: timed)
        var lastErr = ""
        do {
            ffmpeg = try SpawnedProcess(
                args: args, env: ["PATH": Pipeline.searchPath.joined(separator: ":")], cwd: NSTemporaryDirectory(),
                onLine: { [weak self] line in
                    if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), total > 0 {
                        self?.progress = share + (1 - share) * (0.5 + 0.5 * min(1, us / 1e6 / total))
                    } else if !line.contains("=") && !line.isEmpty {
                        lastErr = line
                    }
                },
                onExit: { [weak self] code in
                    guard let self else { return }
                    let ok = code == 0 && !self.cancelled
                    self.finish(error: ok || self.cancelled ? nil : "ffmpeg : \(lastErr)", out: out, wav: wav, ok: ok)
                })
        } catch {
            finish(error: "ffmpeg : \(error.localizedDescription)", out: out, wav: wav)
        }
    }

    func cancel() {
        cancelled = true
        ffmpeg?.signal(SIGTERM)
    }

    /// ffmpeg wrote to a hidden partial file: on success it replaces `out`; otherwise it is deleted and a file
    /// already at `out` is left untouched.
    private func finish(error: String?, out: URL, wav: URL, ok: Bool = false) {
        try? FileManager.default.removeItem(at: wav)
        if let v = renderedVideo { try? FileManager.default.removeItem(at: v); renderedVideo = nil }
        let partial = ExportOptions.partialURL(for: out)
        var ok = ok, error = error
        if ok {
            do {
                if FileManager.default.fileExists(atPath: out.path) {
                    _ = try FileManager.default.replaceItemAt(out, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: out)
                }
            } catch let e {
                ok = false
                error = "Écriture impossible : \(e.localizedDescription)"
            }
        }
        if !ok { try? FileManager.default.removeItem(at: partial) }
        running = false
        ffmpeg = nil
        if ok {
            lastFile = out
            message = "Exporté : \(out.lastPathComponent)"
        } else {
            message = error ?? "Export annulé"
        }
    }
}

struct ExportSheet: View {
    let player: PlayerModel

    var body: some View {
        @Bindable var ui = ExportUI.shared
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporter le mix").font(.headline)
            Picker("Contenu", selection: $ui.options.kind) {
                Text("Vidéo + master").tag(ExportKind.videoMaster)
                Text("Master seul (audio)").tag(ExportKind.masterOnly)
            }
            .pickerStyle(.segmented)
            if ui.options.kind == .masterOnly {
                Picker("Format", selection: $ui.options.format) {
                    Text("AAC (.m4a)").tag(AudioFormat.aac)
                    Text("MP3").tag(AudioFormat.mp3)
                    Text("WAV").tag(AudioFormat.wav)
                    Text("FLAC").tag(AudioFormat.flac)
                }
                if ui.options.format.lossless {
                    Picker("Qualité", selection: $ui.options.bits) {
                        Text("16 bits").tag(16)
                        Text("24 bits").tag(24)
                    }
                } else {
                    Picker("Débit", selection: $ui.options.kbps) {
                        ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
            } else {
                Picker("Résolution", selection: $ui.options.height) {
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                }
                Picker("Qualité vidéo", selection: $ui.options.highQuality) {
                    Text("Haute").tag(true)
                    Text("Standard").tag(false)
                }
                Picker("Son (AAC)", selection: $ui.options.videoKbps) {
                    ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
            Text("Tout le morceau, tel qu'on l'entend (faders, mute/solo, master, tempo, hauteur).")
                .font(.caption).foregroundStyle(.secondary)
            if ui.running { ProgressView(value: ui.progress) }
            if let m = ui.message { Text(m).foregroundStyle(ui.lastFile == nil ? .orange : .green) }
            HStack {
                if let f = ui.lastFile {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                }
                Spacer()
                if ui.running {
                    Button("Annuler") { ui.cancel() }
                } else {
                    Button("Fermer") { ui.shown = false; ui.message = nil; ui.lastFile = nil }
                    Button("Exporter…") { ui.run(player: player) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
