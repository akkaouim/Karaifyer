import AppKit
import CoreAudio
import AVFAudio
import SwiftUI
import KaraifyerCore

@main
struct KaraifyerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // A plain stored model rather than @State: the Command Line Tools SDK
    // implements @State as a macro whose plugin only ships with Xcode.
    private let model = QueueModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .onAppear { delegate.model = model }
        } label: {
            Image(systemName: model.isRunning ? "record.circle" : "waveform")
        }

        Window("Karaifyer", id: "queue") {
            TabView(selection: Bindable(AppTabs.shared).selected) {
                QueueView(model: model)
                    .tabItem { Label("Enregistrement", systemImage: "record.circle") }.tag(AppTabs.Tab.enregistrement)
                KaraokeView(model: KaraokeModel.shared)
                    .tabItem { Label("Karaoké", systemImage: "music.mic") }.tag(AppTabs.Tab.karaoke)
                PlayerView(model: PlayerModel.shared)
                    .tabItem { Label("Lecteur", systemImage: "play.rectangle") }.tag(AppTabs.Tab.lecteur)
            }
            .onAppear { delegate.model = model }
            .background(WindowOpener())
        }
        .defaultSize(width: 1180, height: 720)
        .defaultLaunchBehavior(.presented)   // a regular app now: the window opens at launch

        WindowGroup("Corriger", id: "editor", for: String.self) { $songID in
            if let id = songID, let m = KaraokeModel.shared.editor(for: id) {
                EditorView(model: m).onDisappear { KaraokeModel.shared.closeEditor(id) }
            } else {
                Text("Morceau introuvable (actualiser l'onglet Karaoké).").padding()
            }
        }
        .defaultSize(width: 1100, height: 700)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: QueueModel?

    /// Launch flags for unattended runs:
    ///   --list <csv>  --output <dir>  --start  --quit-when-done
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--screenshots") {
                let args = ProcessInfo.processInfo.arguments
                let dir = URL(fileURLWithPath: args.indices.contains(i + 1) ? args[i + 1] : "screenshots")
                Task { await Screenshots.run(dir: dir) }
                return
            }
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--probe-tap") {
                // Diagnostic: --probe-tap <bundle-prefix|pid> <out-file>
                // Reports the format a stereo-mixdown tap advertises for a process.
                let args = Array(ProcessInfo.processInfo.arguments.dropFirst(i + 1))
                let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "/dev/stdout")
                var line = "target \(args.first ?? "?"): "
                var objs: [AudioObjectID] = []
                if let target = args.first {
                    if let pid = Int32(target) {
                        var p = pid; var obj = AudioObjectID.unknown; var size = UInt32(MemoryLayout<AudioObjectID>.size)
                        var addr = AudioObjectID.system.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
                        AudioObjectGetPropertyData(.system, &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
                        if obj != .unknown { objs = [obj] }
                    } else {
                        objs = AudioObjectID.processObjects(bundlePrefix: target).map(\.id)
                    }
                }
                let dev = (try? AudioObjectID.defaultOutputDevice()) ?? .unknown
                let devRate: Double = (try? dev.read(kAudioDevicePropertyNominalSampleRate, default: 0)) ?? 0
                line += "device \(dev.deviceName) @ \(Int(devRate)) Hz; "
                if objs.isEmpty {
                    line += "no audio process found"
                } else {
                    let desc = CATapDescription(stereoMixdownOfProcesses: objs)
                    desc.isPrivate = true
                    var tap = AudioObjectID.unknown
                    let st = AudioHardwareCreateProcessTap(desc, &tap)
                    if st == noErr, let asbd = try? tap.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription()) {
                        line += "tap reports \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch"
                        AudioHardwareDestroyProcessTap(tap)
                    } else {
                        line += "tap creation failed (\(st))"
                    }
                }
                try? (line + "\n").write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--plan-recorder-migration") {
                // Diagnostic, read-only: --plan-recorder-migration <out-file> [<output folder> <list name>] prints the
                // naming migration plan (default: the saved settings), then quits (no recorder model, nothing written).
                let args = ProcessInfo.processInfo.arguments
                let out = URL(fileURLWithPath: args.indices.contains(i + 1) ? args[i + 1] : "/dev/stdout")
                let root = args.indices.contains(i + 2) ? URL(fileURLWithPath: args[i + 2])
                    : UserDefaults.standard.url(forKey: "outputRoot") ?? QueueModel.defaultOutputRoot
                let list = args.indices.contains(i + 3) ? args[i + 3]
                    : UserDefaults.standard.url(forKey: "lastList")?.deletingPathExtension().lastPathComponent
                var text = ""
                if let job = RecorderMigrationJob.compute(outputRoot: root, listName: list) {
                    text = "target \(job.target.path) (switches: \(job.switchesFolder))\n"
                        + job.plan.renames.map { "\($0.from) -> \($0.to)" }.joined(separator: "\n")
                        + "\nduplicates: \(job.plan.duplicates)\n"
                } else {
                    text = "nothing to do\n"
                }
                try? text.write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--scan-glitches") {
                // Diagnostic: report glitches in existing files, then quit.
                for path in ProcessInfo.processInfo.arguments.dropFirst(i + 1) {
                    let url = URL(fileURLWithPath: path)
                    if let f = try? AVAudioFile(forReading: url),
                       let g = try? PostProcess.dropouts(in: url, range: (0, Int(f.length)), sampleRate: f.fileFormat.sampleRate) {
                        print("\(url.lastPathComponent): \(g.isEmpty ? "no glitches" : g.map { String(format: "%.3fs (%.1f ms)", $0.at, $0.ms) }.joined(separator: ", "))")
                    } else {
                        print("\(url.lastPathComponent): unreadable")
                    }
                }
                exit(0)
            }
            let model = QueueModel.shared
            self.model = model
            let args = ProcessInfo.processInfo.arguments
            func value(_ flag: String) -> String? {
                args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            }
            if let out = value("--output") {
                model.persistOutputRoot = false // one-off; don't change the saved folder
                model.outputRoot = URL(fileURLWithPath: out)
            }
            if let list = value("--list") {
                do { try model.load(url: URL(fileURLWithPath: list)) }
                catch { print("Karaifyer: couldn't load \(list): \(error)") }
            }
            model.quitWhenDone = args.contains("--quit-when-done")
            if args.contains("--silent") { model.silentOverride = true }
            if args.contains("--start") { model.start() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let k = KaraokeModel.shared
            guard k.runState != .idle, !(model?.quitWhenDone ?? false) else { return .terminateNow }
            let a = NSAlert()
            a.messageText = "Une analyse karaoké est en cours"
            a.informativeText = "Quitter l'arrête ; l'étape en cours sera refaite à la prochaine analyse."
            a.addButton(withTitle: "Quitter")
            a.addButton(withTitle: "Annuler")
            return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    /// Dock icon clicked with the window closed: bring it back (closing it never quits the app,
    /// so an analysis keeps running).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { WindowOpener.open?() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.shutdown()
            KaraokeModel.shared.terminateRun()   // never leave an orphaned `traiter` behind
        }
    }
}

struct MenuContent: View {
    @Bindable var model: QueueModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let c = model.counts
        let row = model.currentRow
        ForEach(MenuStatus.lines(row: row?.number, title: row.map { model.states[$0.index]?.note ?? $0.title },
                                 durationS: model.durationSec, banner: model.banner,
                                 done: c.done, total: c.total, failed: c.failed), id: \.self) { Text($0) }
        let k = KaraokeModel.shared
        if k.runState != .idle {
            Divider()
            Text(k.statusLine)
            if k.runState == .running { Button("Pause de l'analyse") { k.pause() } }
            if k.runState == .paused { Button("Reprendre l'analyse") { k.resume() } }
            Button("Arrêter l'analyse après ce morceau") { k.stopAfterCurrent() }
            Button("Arrêter l'analyse maintenant") { k.stopNow() }
        }
        Divider()
        Button("Open Queue…") {
            openWindow(id: "queue")
            NSApp.activate()
        }
        if model.isRunning {
            Button("Skip Track") { model.skipCurrent() }
            if model.stopRequested {
                Button("Stopping After This Track…") {}.disabled(true)
            } else {
                Button("Stop After This Track") { model.stopAfterThisTrack() }
            }
            Button("Stop Now") { model.stopNow() }
        } else {
            Button("Start Batch") { model.start() }
                .disabled(model.rows.isEmpty)
        }
        Toggle("Also save MP3 (320 kbps)", isOn: $model.makeMP3)
        Button("Open Output Folder") { openFolder(model.listDir) }
        Divider()
        Button("Quitter Karaifyer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct QueueView: View {
    @Bindable var model: QueueModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(model.rows, selection: $model.selection) {
                TableColumn("#") { Text($0.number).monospacedDigit() }.width(36)
                TableColumn("Titre") { Text($0.title) }
                TableColumn("Artiste") { Text($0.artist) }
                TableColumn("Proposé par") { Text($0.proposer) }.width(min: 80, ideal: 140)
                TableColumn("Status") { row in
                    let st = model.states[row.index] ?? RowState()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(st.status.label).foregroundStyle(color(st.status))
                        if let note = st.note, st.status != .recording {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(st.note ?? "")
                }
                .width(min: 120, ideal: 220)
                TableColumn("File") { row in
                    if let f = model.states[row.index]?.file {
                        Button(f.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                            .buttonStyle(.link)
                    }
                }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button(ids.count > 1 ? "Déplacer \(ids.count) enregistrements vers…" : "Déplacer vers…") {
                    moveRows(model.rows.filter { ids.contains($0.index) })
                }
                .disabled(ids.isEmpty || model.isRunning || KaraokeModel.shared.locked)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 360)
        .onAppear { model.offerMigration() }
        .sheet(isPresented: Binding(get: { QueueUI.shared.migration != nil }, set: { if !$0 { QueueUI.shared.migration = nil } })) {
            if let job = QueueUI.shared.migration { RecorderMigrationSheet(job: job, model: model) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Load List…", action: loadList).disabled(model.isRunning)
                Text(model.listURL?.lastPathComponent ?? "No list loaded").foregroundStyle(.secondary)
                Spacer()
                if model.isRunning {
                    Button("Skip") { model.skipCurrent() }
                    if model.stopRequested {
                        Button("Stopping after this track…") {}.disabled(true)
                    } else {
                        Button("Stop After Track") { model.stopAfterThisTrack() }
                    }
                    Button("Stop Now", role: .destructive) { model.stopNow() }
                } else {
                    Button("Retry Failed") { model.retryFailed() }
                        .disabled(model.counts.failed == 0)
                    Button("Start") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.rows.isEmpty)
                }
            }
            HStack(spacing: 16) {
                Toggle("Also save MP3 (320 kbps)", isOn: $model.makeMP3)
                Toggle("Subfolder per “proposé par”", isOn: $model.groupByProposer).disabled(model.isRunning)
                Toggle("Switch output to 44.1 kHz while recording", isOn: $model.matchSpotifyRate).disabled(model.isRunning)
                    .help("Spotify streams at 44.1 kHz. Recording at the same rate avoids a resampling step.")
                Spacer()
            }
            .toggleStyle(.checkbox)
            HStack {
                Toggle("Silent recording via BlackHole (44.1 kHz, no resampling)", isOn: $model.silentViaBlackHole)
                    .disabled(model.isRunning)
                    .help("During a batch, macOS output is switched to BlackHole at 44.1 kHz, so each file is exactly Spotify's stream with no conversion. It switches the output for the whole Mac (calls and other apps go silent too), and your normal output comes back when the batch ends. Don't switch the output by hand during the batch: Karaifyer would stop.")
                if model.silentViaBlackHole {
                    Text("All Mac audio goes silent while recording (not for use during calls).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .toggleStyle(.checkbox)
            HStack {
                Text("Output:").foregroundStyle(.secondary)
                Button(model.listDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { openFolder(model.listDir) }
                    .buttonStyle(.link)
                Button("Change…", action: chooseOutput).disabled(model.isRunning)
                Spacer()
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if let row = model.currentRow {
                Text("Row \(row.number)").bold()
                ProgressView(value: min(model.positionSec, model.durationSec), total: max(model.durationSec, 1))
                    .frame(width: 200)
                Text("\(timecode(model.positionSec)) / \(timecode(model.durationSec))").monospacedDigit()
            }
            if let banner = model.banner {
                Text(banner).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            let c = model.counts
            Text("\(c.done)/\(c.total) done" + (c.failed > 0 ? " · \(c.failed) failed" : ""))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func color(_ s: RowStatus) -> Color {
        switch s {
        case .done: return .green
        case .failed: return .red
        case .recording: return .red
        case .encoding, .waiting: return .orange
        default: return .secondary
        }
    }

    private func loadList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.load(url: url) } catch { model.banner = "Couldn't read list: \(error.localizedDescription)" }
    }

    private func moveRows(_ rows: [TrackRow]) {
        let done = rows.filter { model.existingFile(for: $0) != nil }
        guard !done.isEmpty else { model.banner = "Ces lignes n'ont pas encore d'enregistrement."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Déplacer ici"
        // a subfolder of the output folder is fine (sorting); the output folder itself would be a no-op
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL.path != model.listDir.standardizedFileURL.path else { return }
        let alert = NSAlert()
        alert.messageText = "Déplacer \(done.count) enregistrement(s) vers « \(url.lastPathComponent) » ?"
        alert.informativeText = "Les lignes déplacées apparaîtront « à enregistrer » tant que le dossier de sortie n'est pas "
            + "celui-ci. Le manifeste karaoké suit (une copie est gardée). Aucun fichier n'est écrasé."
        alert.addButton(withTitle: "Déplacer")
        alert.addButton(withTitle: "Annuler").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { model.banner = await model.move(rows: done, to: url) }
    }

    /// The folder changes only once confirmed; moving is offered only to another folder, never one inside this one.
    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.directoryURL = model.outputRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let old = model.listDir
        let existing = FolderChoice.moveOffered(current: old.path, new: url.path) ? model.recordedFiles(in: old) : []
        var move = false
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Déplacer les enregistrements vers ce dossier ?"
            alert.informativeText = "\(existing.count) fichier(s) dans le dossier actuel. Les morceaux comptent comme enregistrés "
                + "seulement si leurs fichiers sont dans le dossier de sortie.\n\nDe : \(old.path)\nVers : \(url.path)"
            alert.addButton(withTitle: "Déplacer les fichiers")
            alert.addButton(withTitle: "Utiliser sans déplacer")
            alert.addButton(withTitle: "Annuler").keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn: move = true
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        var pairs: [(from: URL, to: URL)] = []
        if move {
            do {
                let r = try model.moveFiles(existing, to: url)
                pairs = r.moved
                model.banner = "\(r.moved.count) fichier(s) déplacé(s)"
                    + (r.skipped.isEmpty ? "." : " ; déjà présents, laissés en place : \(r.skipped.joined(separator: ", ")).")
            } catch {
                model.banner = "Déplacement interrompu : \(error.localizedDescription)"
            }
        }
        model.persistOutputRoot = true
        model.outputRoot = url
        if !pairs.isEmpty { Task { await model.relocate(pairs) } }
    }
}

func timecode(_ s: Double) -> String {
    let t = max(0, Int(s))
    return String(format: "%d:%02d", t / 60, t % 60)
}

func openFolder(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
}


/// Keeps SwiftUI's openWindow action so the app delegate can reopen the main window.
struct WindowOpener: View {
    @MainActor static var open: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { WindowOpener.open = { openWindow(id: "queue") } }
    }
}
