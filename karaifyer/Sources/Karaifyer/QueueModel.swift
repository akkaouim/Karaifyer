import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt
import Observation
import KaraifyerCore

enum RowStatus: Equatable {
    case pending
    case waiting(String)
    case recording
    case encoding
    case done
    case failed(String)
    case skipped

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .waiting(let s): return s
        case .recording: return "● Recording"
        case .encoding: return "Encoding…"
        case .done: return "✓ Done"
        case .failed(let s): return "✗ \(s)"
        case .skipped: return "Skipped"
        }
    }
}

struct RowState {
    var status: RowStatus = .pending
    var file: URL?
    var note: String?
}

/// A row-level failure; `fatal` stops the whole batch.
private struct RowFailure: Error {
    let message: String
    /// Stop the whole batch; the row goes back to pending so Start redoes it.
    var fatal = false
    var requeue = false
    /// Spotify misbehaved (ignored or reverted `play track`): restart it before retrying.
    var restartSpotify = false
    /// Re-recording for quality; doesn't consume the normal retry budget.
    var glitch = false
}

@Observable
@MainActor
final class QueueModel {
    static let shared = QueueModel()

    // List
    private(set) var listURL: URL?
    private(set) var rows: [TrackRow] = []
    private(set) var states: [Int: RowState] = [:]
    var selection: Set<Int> = []
    private(set) var ignoredLines: [(line: Int, reason: String)] = []

    // Run state
    private(set) var isRunning = false
    private(set) var currentIndex: Int?
    private(set) var positionSec: Double = 0
    private(set) var durationSec: Double = 0
    var banner: String?
    /// Terminate the app once the batch ends (for unattended runs).
    var quitWhenDone = false

    // Settings (persisted)
    var makeMP3: Bool = UserDefaults.standard.object(forKey: "makeMP3") as? Bool ?? true {
        didSet { UserDefaults.standard.set(makeMP3, forKey: "makeMP3") }
    }
    var groupByProposer: Bool = UserDefaults.standard.bool(forKey: "groupByProposer") {
        didSet { UserDefaults.standard.set(groupByProposer, forKey: "groupByProposer"); refreshDoneStates() }
    }
    var matchSpotifyRate: Bool = UserDefaults.standard.object(forKey: "matchSpotifyRate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(matchSpotifyRate, forKey: "matchSpotifyRate") }
    }
    static let defaultOutputRoot = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SysRec")
    /// A saved folder inside a temp directory is ignored: macOS clears those,
    /// and recordings left there would be lost.
    /// Route playback to BlackHole (44.1 kHz) during a batch: the file is exactly
    /// Spotify's stream with no resampling, but nothing is audible. Off by default.
    var silentViaBlackHole: Bool = UserDefaults.standard.bool(forKey: "silentViaBlackHole") {
        didSet { UserDefaults.standard.set(silentViaBlackHole, forKey: "silentViaBlackHole") }
    }
    /// One-off override from the --silent launch flag (not saved).
    var silentOverride: Bool?
    var silentMode: Bool { silentOverride ?? silentViaBlackHole }
    private var outputToRestore: AudioDeviceID?

    var outputRoot: URL = {
        guard let saved = UserDefaults.standard.url(forKey: "outputRoot"), !QueueModel.isTemporary(saved) else {
            return QueueModel.defaultOutputRoot
        }
        return saved
    }() {
        didSet {
            if persistOutputRoot { UserDefaults.standard.set(outputRoot, forKey: "outputRoot") }
            refreshDoneStates()
        }
    }
    /// False for one-off overrides (the --output launch flag).
    var persistOutputRoot = true

    static func isTemporary(_ url: URL) -> Bool {
        let p = url.resolvingSymlinksInPath().path
        return ["/private/tmp/", "/tmp/", "/private/var/folders/", NSTemporaryDirectory()].contains { p.hasPrefix($0) }
    }

    private let spotify = SpotifyController()
    private var tap: SystemAudioTap?
    private var runTask: Task<Void, Never>?
    /// "Stop After Track" was clicked; shown in the UI until the batch ends.
    private(set) var stopRequested = false
    private var skipRequested = false
    private var deviceChanged = false
    private var sleepAssertion: IOPMAssertionID = 0
    private var shortRetries: [Int: Int] = [:]
    private var glitchRetries: [Int: Int] = [:]
    private var faultRetries: [Int: Int] = [:]
    /// Gaps seen in earlier takes of each row; a gap seen again is part of the track.
    private var gapHistory: [Int: [(at: Double, ms: Double)]] = [:]

    init() {
        if let last = UserDefaults.standard.url(forKey: "lastList"), FileManager.default.fileExists(atPath: last.path) {
            try? load(url: last)
        }
    }

    // MARK: - Derived

    var listName: String { listURL?.deletingPathExtension().lastPathComponent ?? "Karaifyer" }
    /// The chosen folder itself: every list records into it (songs already there count as done).
    var listDir: URL { outputRoot }
    var counts: (done: Int, failed: Int, total: Int) {
        let done = states.values.filter { $0.status == .done }.count
        let failed = states.values.filter { if case .failed = $0.status { return true } else { return false } }.count
        return (done, failed, rows.count)
    }
    var currentRow: TrackRow? { currentIndex.map { rows[$0] } }

    func directory(for row: TrackRow) -> URL {
        guard groupByProposer, !row.proposer.isEmpty else { return listDir }
        return listDir.appendingPathComponent(FileNaming.sanitize(row.proposer), isDirectory: true)
    }

    /// Existing finished FLAC for a row: the file in its folder carrying the row's Spotify id, whatever its name.
    func existingFile(for row: TrackRow) -> URL? {
        let dir = directory(for: row)
        return index(for: dir).file(for: row.trackID).map { dir.appendingPathComponent($0) }
    }

    /// The folder's recordings by Spotify id (.karaifyer-index.json). Never blocks: answers with what is known and
    /// re-reads new or changed files' tags (ffprobe) in the background, then updates the rows.
    func index(for dir: URL) -> RecordingIndex {
        if let idx = indexes[dir] { return idx }
        let idx = RecordingIndex.load(dir: dir)
        indexes[dir] = idx
        scheduleRefresh(dir)
        return idx
    }

    /// The index brought up to date, tags read off the main thread — for decisions (recording, naming, moving).
    func freshIndex(for dir: URL) async -> RecordingIndex {
        let base = indexes[dir] ?? RecordingIndex.load(dir: dir)
        let idx = await Task.detached { Self.refreshed(base, dir: dir) }.value
        indexes[dir] = idx
        return idx
    }

    private func scheduleRefresh(_ dir: URL) {
        guard !refreshing.contains(dir) else { return }
        refreshing.insert(dir)
        Task {
            let before = indexes[dir]
            let idx = await freshIndex(for: dir)
            refreshing.remove(dir)
            if idx != before { refreshDoneStates() }
        }
    }

    nonisolated static func refreshed(_ start: RecordingIndex, dir: URL) -> RecordingIndex {
        var idx = start
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let listing = items.filter { ["flac", "mp3"].contains($0.pathExtension.lowercased()) }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (name: u.lastPathComponent, size: Int64(v?.fileSize ?? 0),
                    mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        if idx.refresh(listing: listing, read: { RecordingTags.read(dir.appendingPathComponent($0)) }), !items.isEmpty {
            idx.save(dir: dir)
        }
        return idx
    }
    @ObservationIgnored private var indexes: [URL: RecordingIndex] = [:]
    @ObservationIgnored private var refreshing: Set<URL> = []

    // MARK: - Commands

    func load(url: URL) throws {
        guard !isRunning else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = TrackList.parse(text)
        listURL = url
        rows = parsed.rows
        ignoredLines = parsed.ignored
        states = [:]
        UserDefaults.standard.set(url, forKey: "lastList")
        refreshDoneStates()
        let dupes = rows.filter { $0.duplicateOf != nil }.count
        banner = "Loaded \(rows.count) tracks" + (dupes > 0 ? " (\(dupes) duplicate\(dupes > 1 ? "s" : ""), recorded once)" : "")
            + (ignoredLines.isEmpty ? "" : ", \(ignoredLines.count) lines ignored") + "."
    }

    func refreshDoneStates() {
        for dir in Set(rows.map { directory(for: $0) }) where indexes[dir] != nil { scheduleRefresh(dir) }
        for row in rows {
            if let f = existingFile(for: row) {
                states[row.index] = RowState(status: .done, file: f)
            } else if states[row.index]?.status == .done {
                states[row.index] = RowState()
            }
        }
    }

    func start() {
        guard !isRunning, !rows.isEmpty else { return }
        // « Plus tard » on the naming update: recordings of the loaded list may sit in another folder and be recorded again
        if !UserDefaults.standard.bool(forKey: "recorderMigrationDone"), let job = pendingMigration {
            let a = NSAlert()
            a.messageText = "Les noms des enregistrements n'ont pas encore été mis à jour"
            a.informativeText = "Des morceaux déjà enregistrés (dans « \(job.target.lastPathComponent) » ou ses sous-dossiers) "
                + "pourraient être enregistrés une seconde fois."
            a.addButton(withTitle: "Mettre à jour d'abord…")
            a.addButton(withTitle: "Enregistrer quand même")
            a.addButton(withTitle: "Annuler").keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: QueueUI.shared.migration = job; return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        // Analysis load caused recording glitches before: offer to pause it (default).
        if KaraokeModel.shared.runState == .running {
            let a = NSAlert()
            a.messageText = "Une analyse karaoké est en cours"
            a.informativeText = "La mettre en pause pendant l'enregistrement ? (la charge peut provoquer des coupures)"
            a.addButton(withTitle: "Mettre en pause")
            a.addButton(withTitle: "Continuer les deux")
            a.addButton(withTitle: "Annuler").keyEquivalent = "\u{1b}"     // Escape: don't start the recording
            switch a.runModal() {
            case .alertFirstButtonReturn: KaraokeModel.shared.pauseForRecording()
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        stopRequested = false
        skipRequested = false
        runTask = Task { await runBatch() }
    }

    func stopNow() { runTask?.cancel() }
    func stopAfterThisTrack() {
        guard isRunning, !stopRequested else { return }
        stopRequested = true
        let which = currentRow.map { "row \($0.number)" } ?? "the current track"
        banner = "Will stop after \(which) finishes."
        log("Stop requested: will stop after \(which)")
    }

    /// What « Déplacer les fichiers » takes along: recordings, their Ableton analysis files, the log.
    func recordedFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { u in
            let n = u.lastPathComponent.lowercased()
            return n.hasSuffix(".flac") || n.hasSuffix(".mp3") || n.hasSuffix(".mp3.asd") || n == "sysrec-log.txt"
        }
    }

    /// Moves files into `dir` without ever overwriting: a taken name is skipped. Another disk: copy with the size
    /// checked and the exact modification date kept (the analysis keys on it), then remove the original. The log is
    /// appended to the destination's log. Every failure is reported per file, so what moved still reaches the manifest.
    /// Runs off the main thread.
    nonisolated static func moveFiles(_ files: [URL], to dir: URL) -> (moved: [(from: URL, to: URL)], skipped: [String]) {
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return ([], files.map { "\($0.lastPathComponent) (\(error.localizedDescription))" })
        }
        let present = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        let volume = { (u: URL) in (try? u.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject) ?? nil }
        var moved: [(from: URL, to: URL)] = [], skipped: [String] = []
        for f in files {
            let dst = dir.appendingPathComponent(f.lastPathComponent)
            do {
                if f.lastPathComponent == "sysrec-log.txt", present.contains("sysrec-log.txt") {
                    let h = try FileHandle(forWritingTo: dst)
                    h.seekToEndOfFile(); h.write(try Data(contentsOf: f)); try h.close()
                    try fm.removeItem(at: f)
                    continue
                }
                guard SafeMove.plan(files: [f.lastPathComponent], destinationNames: present).skipped.isEmpty else {
                    skipped.append(f.lastPathComponent); continue
                }
                if volume(f) == volume(dir) {
                    try fm.moveItem(at: f, to: dst)
                } else {
                    try SafeMove.copy(from: f, to: dst)
                    try fm.removeItem(at: f)
                }
                moved.append((f, dst))
            } catch {
                skipped.append("\(f.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        return (moved, skipped)
    }

    /// At launch: retry manifest updates left pending, then offer the one-time naming migration unless done.
    func offerMigration() {
        Task { await flushRelocations() }
        if RecordingTags.ffprobe == nil {
            banner = "ffprobe introuvable (brew install ffmpeg) : les morceaux déjà enregistrés ne peuvent pas être reconnus."
        }
        guard !UserDefaults.standard.bool(forKey: "recorderMigrationDone"), !isRunning, QueueUI.shared.migration == nil else { return }
        let root = outputRoot, list = listURL?.deletingPathExtension().lastPathComponent
        Task {
            let job = await Task.detached { RecorderMigrationJob.compute(outputRoot: root, listName: list) }.value
            pendingMigration = job
            if let job { QueueUI.shared.migration = job } else { UserDefaults.standard.set(true, forKey: "recorderMigrationDone") }
        }
    }
    @ObservationIgnored private(set) var pendingMigration: RecorderMigrationJob?

    /// Renames (and brings in) as planned, never onto an existing name; stops at the first failure, and the next
    /// launch offers the rest. Each rename is journaled for the manifest before the next one, and the folder's index
    /// follows the renames (no tag re-read).
    func migrate(_ job: RecorderMigrationJob) async {
        let ui = QueueUI.shared
        ui.migrating = true
        defer { ui.migrating = false }
        let fm = FileManager.default
        var done: [RecordingMigration.Rename] = [], failure: String?
        log("— Nouveaux noms « Titre - Artiste » (\(job.plan.renames.count) fichier(s)) —")
        for r in job.plan.renames {
            let src = job.target.appendingPathComponent(r.from), dst = job.target.appendingPathComponent(r.to)
            guard !fm.fileExists(atPath: dst.path) else { failure = "« \(r.to) » existe déjà"; break }
            do {
                try fm.moveItem(at: src, to: dst)
                addPending([(src, dst)])
                done.append(r)
                log("Renommé : \(r.from) → \(r.to)" + (job.plan.duplicates.contains(r.to) ? " (copie en double)" : ""))
            } catch {
                failure = "\(r.from) : \(error.localizedDescription)"
                break
            }
        }
        var idx = RecordingIndex.load(dir: job.target)
        for r in done {
            idx.entries[r.from] = nil
            if let e = job.entries[r.from] { idx.entries[r.to] = e }
        }
        idx.save(dir: job.target)
        indexes = [job.target: idx]
        persistOutputRoot = true
        outputRoot = job.target
        await flushRelocations()
        if let failure {
            banner = "Mise à jour des noms interrompue (\(done.count) faite(s)) : \(failure). Elle sera reproposée au prochain lancement."
        } else {
            UserDefaults.standard.set(true, forKey: "recorderMigrationDone")
            pendingMigration = nil
            banner = "\(done.count) enregistrement(s) renommé(s)."
        }
        ui.migration = nil
    }

    /// « Déplacer vers… »: the rows' FLAC, MP3 and .asd go to `dir` (off the main thread); the manifest follows.
    func move(rows: [TrackRow], to dir: URL) async -> String {
        var files: [URL] = []
        for row in rows {
            let src = directory(for: row)
            let idx = await freshIndex(for: src)
            for ext in ["flac", "mp3"] {
                guard let name = idx.file(for: row.trackID, ext: ext) else { continue }
                files.append(src.appendingPathComponent(name))
                let asd = src.appendingPathComponent(name + ".asd")
                if FileManager.default.fileExists(atPath: asd.path) { files.append(asd) }
            }
        }
        guard !files.isEmpty else { return "Aucun enregistrement à déplacer pour ces lignes." }
        let r = await moveAndFollow(files, to: dir)
        return "\(r.moved.count) fichier(s) déplacé(s) vers \(dir.lastPathComponent)"
            + (r.skipped.isEmpty ? "." : " ; laissés en place : \(r.skipped.joined(separator: ", ")).")
    }

    /// Moves off the main thread, logs, refreshes the rows, and has the manifest follow.
    func moveAndFollow(_ files: [URL], to dir: URL) async -> (moved: [(from: URL, to: URL)], skipped: [String]) {
        banner = "Déplacement de \(files.count) fichier(s)…"
        let r = await Task.detached { Self.moveFiles(files, to: dir) }.value
        for m in r.moved { log("Déplacé : \(m.from.path) → \(m.to.path)") }
        indexes = [:]
        refreshDoneStates()
        await relocate(r.moved)
        return r
    }

    /// The karaoke manifest follows moved recordings (`karaoke relocaliser`, which keeps a backup). Moves are
    /// journaled first, so a failure (drive unplugged, app quit) is retried at the next launch.
    func relocate(_ pairs: [(from: URL, to: URL)]) async {
        addPending(pairs)
        await flushRelocations()
    }

    private var pendingRelocations: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "pendingRelocations") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "pendingRelocations") }
    }

    /// x → y after a → x reads a → y (the manifest still says a).
    private func addPending(_ pairs: [(from: URL, to: URL)]) {
        var d = pendingRelocations
        for p in pairs where ["flac", "mp3"].contains(p.from.pathExtension.lowercased()) {
            for (k, v) in d where v == p.from.path { d[k] = p.to.path }
            d[p.from.path] = p.to.path
        }
        pendingRelocations = d
    }

    func flushRelocations() async {
        let d = pendingRelocations
        guard !d.isEmpty, let json = try? JSONSerialization.data(withJSONObject: d) else { return }
        let p = Pipeline()
        guard p.problems().isEmpty, p.manifestExists else { return }      // drive away: keep them for later
        let args = p.args(["relocaliser", "--json"]), env = p.env, cwd = p.projectDir
        let input = String(decoding: json, as: UTF8.self)
        let result = await Task.detached { EditorModel.runProcess(args: args, env: env, cwd: cwd, input: input) }.value
        switch result {
        case .success(let data):
            var left = pendingRelocations
            for k in d.keys where left[k] == d[k] { left[k] = nil }
            pendingRelocations = left
            let n = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["modifies"] as? [Any]
            KaraokeModel.shared.appendLog("Manifeste : \(n?.count ?? 0) ligne(s) suivent les enregistrements déplacés")
        case .failure(let e):
            banner = "Manifeste karaoké pas encore mis à jour (\(e.message)) : ce sera refait au prochain lancement, "
                + "ou utilisez « Retrouver… » dans l'onglet Karaoké."
        }
        await KaraokeModel.shared.refresh()
    }

    func skipCurrent() { skipRequested = true }

    /// « Ajouter un morceau… »: one song after the list's rows, for this session only (gone on quit or list load).
    @discardableResult
    func addManual(trackID: String, title: String, artist: String, proposer: String) -> TrackRow? {
        guard !isRunning, let row = ManualTrack.row(trackID: trackID, title: title, artist: artist, proposer: proposer, after: rows)
        else { return nil }
        rows.append(row)
        refreshDoneStates()
        return row
    }

    /// « Retirer de la liste » for added songs: the row goes, a recorded file stays.
    func removeManual(_ ids: Set<Int>) {
        guard !isRunning else { return }
        let keep = rows.filter { !(ids.contains($0.index) && $0.number.hasPrefix("M")) }
        guard keep.count != rows.count else { return }
        var newStates: [Int: RowState] = [:], m = 0, renumbered: [TrackRow] = []
        for (i, r) in keep.enumerated() {
            if let s = states[r.index] { newStates[i] = s }
            if r.number.hasPrefix("M") { m += 1 }
            renumbered.append(TrackRow(index: i, number: r.number.hasPrefix("M") ? "M\(m)" : r.number, title: r.title,
                                       artist: r.artist, proposer: r.proposer, trackID: r.trackID, duplicateOf: r.duplicateOf))
        }
        rows = renumbered
        states = newStates
        selection = []
    }

    func retryFailed() {
        for (i, s) in states where { if case .failed = s.status { return true }; return s.status == .skipped }() {
            states[i] = RowState()
        }
    }

    /// Synchronous cleanup for app termination.
    func shutdown() {
        runTask?.cancel()
        tap?.stop()
        tap = nil
        restoreOutputDevice()
        if isRunning { Task { try? await spotify.pause() } }
        releaseSleep()
    }

    // MARK: - Batch

    private func runBatch() async {
        isRunning = true
        banner = nil
        deviceChanged = false
        preventSleep()
        log("— Lot « \(listName) » (\(rows.count) morceaux) —")
        defer {
            tap?.stop()
            tap = nil
            restoreOutputDevice()
            currentIndex = nil
            isRunning = false
            releaseSleep()
            KaraokeModel.shared.recordingEnded()   // resumes an analysis paused for this recording
        }

        if AudioCapturePermission.status != .authorized {
            banner = "Waiting for System Audio Recording permission…"
            log("Waiting for you to allow System Audio Recording in the macOS prompt…")
            NSApp.activate()
            let granted = await AudioCapturePermission.request()
            log("System Audio Recording permission: \(granted ? "granted" : "not granted") (status now \(AudioCapturePermission.status))")
            if !granted {
                banner = "Karaifyer needs System Audio Recording permission. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then press Start again."
                AudioCapturePermission.openSettings()
                if quitWhenDone { NSApp.terminate(nil) }
                return
            }
            banner = nil
        }

        do {
            try await spotify.ensureRunning()
            try await spotify.prepareForRecording()
            if silentMode { try await switchToBlackHole() }
            let t = SystemAudioTap(bundlePrefix: SpotifyController.bundleID)
            t.onOutputDeviceChanged = { [weak self] in Task { @MainActor in self?.deviceChanged = true } }
            try t.start(preferredSampleRate: (matchSpotifyRate || silentMode) ? 44100 : nil)
            tap = t
            if !t.notes.isEmpty { log(t.notes.joined(separator: " ")) }
        } catch {
            banner = error.localizedDescription
            log("Batch could not start: \(banner!)")
            if quitWhenDone { NSApp.terminate(nil) }
            return
        }

        var attempts: [Int: Int] = [:]
        var totalTries: [Int: Int] = [:]
        var lastFinished: TrackRow?
        var i = 0
        while i < rows.count {
            if Task.isCancelled || stopRequested { break }
            let row = rows[i]
            guard states[row.index]?.status ?? .pending == .pending else { i += 1; continue }
            currentIndex = row.index
            skipRequested = false
            defer { lastFinished = row }
            do {
                try await process(row)
                i += 1
            } catch let f as RowFailure {
                totalTries[row.index, default: 0] += 1
                if f.requeue && (f.glitch || attempts[row.index, default: 0] < 2) && !Task.isCancelled
                    && totalTries[row.index]! < 6 {
                    if !f.glitch { attempts[row.index, default: 0] += 1 }
                    if f.restartSpotify {
                        log("Row \(row.number): \(f.message) — restarting Spotify")
                        states[row.index] = RowState(status: .waiting("Restarting Spotify…"))
                        do {
                            try await restartSpotifyAndTap()
                        } catch {
                            banner = "Couldn't restart Spotify: \(error.localizedDescription)"
                            states[row.index] = RowState(note: banner)
                            break
                        }
                    }
                    states[row.index] = RowState(status: .pending, note: f.message)
                    log("Row \(row.number): \(f.message) — retrying")
                    continue // same i
                }
                states[row.index] = RowState(status: (Task.isCancelled || f.fatal) ? .pending : .failed(f.message), note: f.message)
                log("Row \(row.number): \(f.message)")
                if f.fatal { banner = f.message; break }
                i += 1
            } catch is CancellationError {
                states[row.index] = RowState()
                break
            } catch let e as SpotifyError where [-1743, -1712, -2741].contains(e.code) {
                // Permission, timeout or script error: every row would fail the same way.
                states[row.index] = RowState(status: .pending, note: e.localizedDescription)
                log("Row \(row.number): \(e.localizedDescription)")
                banner = e.localizedDescription
                break
            } catch {
                states[row.index] = RowState(status: .failed(error.localizedDescription))
                log("Row \(row.number): \(error.localizedDescription)")
                i += 1
            }
        }
        try? await spotify.pause()
        let c = counts
        let tally = "\(c.done)/\(c.total) done, \(c.failed) failed."
        if Task.isCancelled {
            banner = "Stopped. " + tally
        } else if stopRequested {
            banner = "Stopped after row \(lastFinished?.number ?? "?") as you asked. " + tally + " Press Start to continue."
        } else if banner == nil || banner!.hasPrefix("Will stop") {
            banner = "Finished: " + tally
        }
        stopRequested = false
        log(banner ?? "")
        // Recap: rows that failed or finished with a warning, so nothing hides in a long log.
        let review = rows.compactMap { row -> String? in
            guard let s = states[row.index] else { return nil }
            if case .failed(let m) = s.status { return "Row \(row.number) ✗ \(m)" }
            if s.status == .done, let note = s.note { return "Row \(row.number) ⚠ \(note)" }
            return nil
        }
        if !review.isEmpty { log("À vérifier (\(review.count)) : " + review.joined(separator: " | ")) }
        if quitWhenDone {
            tap?.stop(); tap = nil
            NSApp.terminate(nil)
        }
    }

    /// Plays `row` at volume 0 until it has run smoothly for 1.5 s, then pauses
    /// at position 0 with the volume restored. Throws RowFailure for ads or a
    /// misbehaving Spotify (same handling as the recording start).
    private func prebuffer(_ row: TrackRow) async throws {
        states[row.index] = RowState(status: .waiting("Buffering…"))
        try await spotify.setVolume(0)
        do {
            try await spotify.play(uri: row.uri)
            var lastPlay = Date()
            var replays = 0
            let deadline = Date().addingTimeInterval(30)
            while true {
                try Task.checkCancellation()
                if Date() > deadline { throw RowFailure(message: "Spotify didn't start the track (unavailable in your region?)") }
                try await Task.sleep(for: .milliseconds(150))
                guard let s = try? await spotify.poll() else { continue }
                let ours = s.trackURI == row.uri || Self.titlesMatch(row.title, s.title)
                if s.trackURI.hasPrefix("spotify:ad:") {
                    states[row.index] = RowState(status: .waiting("Ad playing (muted)…"))
                    lastPlay = Date() // wait the ad out
                } else if s.state == .playing && ours && s.positionSec >= 1.5 {
                    break
                } else if Date().timeIntervalSince(lastPlay) > 3 && !(s.state == .playing && ours) {
                    guard replays < 2 else {
                        throw RowFailure(message: "Spotify kept playing “\(s.title)” instead of this track",
                                         requeue: true, restartSpotify: true)
                    }
                    replays += 1
                    try await spotify.play(uri: row.uri)
                    lastPlay = Date()
                }
            }
            try await spotify.pause()
            try await spotify.seek(to: 0)
            try await spotify.setVolume(100)
        } catch {
            try? await spotify.pause()
            try? await spotify.setVolume(100)
            throw error
        }
    }

    /// Spotify's audio process changes on relaunch, so the tap is rebuilt too.
    private func restartSpotifyAndTap() async throws {
        tap?.stop()
        tap = nil
        try await spotify.restart()
        try await spotify.prepareForRecording()
        let t = SystemAudioTap(bundlePrefix: SpotifyController.bundleID)
        t.onOutputDeviceChanged = { [weak self] in Task { @MainActor in self?.deviceChanged = true } }
        try t.start(preferredSampleRate: (matchSpotifyRate || silentMode) ? 44100 : nil)
        tap = t
    }

    /// Makes BlackHole the system output for the batch (restored afterwards).
    private func switchToBlackHole() async throws {
        guard let bh = AudioObjectID.outputDevice(nameContaining: "BlackHole") else {
            throw PostProcessError(message: "Silent recording needs BlackHole (brew install blackhole-2ch). Turn the option off to record through your normal output.")
        }
        let current = try AudioObjectID.defaultOutputDevice()
        guard current != bh else { return }
        try AudioObjectID.setDefaultOutputDevice(bh)
        outputToRestore = current
        log("Silent recording: output switched from \(current.deviceName) to \(bh.deviceName); you won't hear playback.")
        try await Task.sleep(for: .seconds(1)) // let Spotify move its stream
    }

    private func restoreOutputDevice() {
        guard let dev = outputToRestore else { return }
        outputToRestore = nil
        do {
            try AudioObjectID.setDefaultOutputDevice(dev)
            log("Output restored to \(dev.deviceName).")
        } catch {
            log("Couldn't restore output to \(dev.deviceName): \(error.localizedDescription)")
        }
    }

    private func process(_ row: TrackRow) async throws {
        let dir = directory(for: row)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Already in the folder (a duplicate row of a track just recorded, or a file added meanwhile): one file per
        // track, nothing is copied.
        let retake = shortRetries[row.index] != nil || glitchRetries[row.index] != nil || faultRetries[row.index] != nil
        if !retake, let name = await freshIndex(for: dir).file(for: row.trackID) {
            let f = dir.appendingPathComponent(name)
            let note = row.duplicateOf.map { "même morceau que la ligne \(rows[$0].number)" }
            states[row.index] = RowState(status: .done, file: f, note: note)
            log("Row \(row.number): already recorded → \(f.lastPathComponent)")
            return
        }

        guard let tap else { throw RowFailure(message: "Tap not running", fatal: true) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sysrec-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 0. Pre-buffer: play the first seconds silently so the take comes from
        // Spotify's cache. Uncached tracks often stall in their first second.
        try await prebuffer(row)

        // 1. Arm the recorder, then resume from 0 (no reload, unlike `play track`).
        states[row.index] = RowState(status: .waiting("Starting…"))
        try tap.beginSegment(url: tmp)
        try await spotify.resume()

        // 2. Wait for Spotify to actually play our track from the top. Right
        // after `play track` Spotify may still report the previous track, or
        // resume ours at a stale position and skip ahead; re-issue play then.
        var meta: SpotifySnapshot?
        let startDeadline = Date().addingTimeInterval(20)
        var lastPlayCommand = Date()
        var replays = 0
        var sawAd = false
        while meta == nil {
            try Task.checkCancellation()
            if Date() > startDeadline { try? await spotify.pause(); _ = try? tap.endSegment(); throw RowFailure(message: "Spotify didn't start the track (unavailable in your region?)") }
            // While Spotify is loading it has no current track and the poll errors (-1700).
            guard let s = try? await spotify.poll() else {
                try await Task.sleep(for: .milliseconds(200)); continue
            }
            let settled = Date().timeIntervalSince(lastPlayCommand) > 2
            if s.trackURI.hasPrefix("spotify:ad:") {
                sawAd = true
                states[row.index] = RowState(status: .waiting("Ad playing…"))
            } else if s.state == .playing && s.positionSec < 2
                        && (s.trackURI == row.uri || (settled && Self.titlesMatch(row.title, s.title))) {
                // Exact ID, or Spotify relinked it to another release of the same song.
                if sawAd {
                    _ = try? tap.endSegment()
                    throw RowFailure(message: "Ad before track", requeue: true)
                }
                meta = s
            } else if settled {
                guard replays < 3 else {
                    try? await spotify.pause(); _ = try? tap.endSegment()
                    throw RowFailure(message: "Spotify kept playing “\(s.title)” instead of this track",
                                     requeue: true, restartSpotify: true)
                }
                replays += 1
                try? await spotify.pause()
                try await spotify.play(uri: row.uri)
                lastPlayCommand = Date()
            }
            if meta == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let meta else { return }
        let playingURI = meta.trackURI
        let durMs = meta.durationMs
        durationSec = Double(durMs) / 1000
        states[row.index] = RowState(status: .recording, note: "\(meta.artist) – \(meta.title)")

        // 3. Monitor until the track ends.
        var maxPos = 0.0
        var advanced = false // ended by Spotify moving to another track (vs. stopping)
        var pollFailures = 0
        let playStart = Date()
        var silenceChecked = false
        monitor: while true {
            if Task.isCancelled { try? await spotify.pause(); _ = try? tap.endSegment(); throw CancellationError() }
            if skipRequested {
                try? await spotify.pause(); _ = try? tap.endSegment()
                states[row.index] = RowState(status: .skipped)
                return
            }
            if deviceChanged {
                try? await spotify.pause(); _ = try? tap.endSegment()
                throw RowFailure(message: "Audio output device changed — restart the batch", fatal: true)
            }
            let nearEnd = maxPos * 1000 >= Double(durMs) - 2500
            let s: SpotifySnapshot
            do {
                s = try await spotify.poll()
                pollFailures = 0
            } catch {
                // Right after a track ends with nothing queued, Spotify briefly has
                // no current track (-1728): that's the end. Elsewhere, retry a while.
                if nearEnd { break monitor }
                pollFailures += 1
                if pollFailures >= 30 { throw error }
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if s.trackURI != playingURI {
                if nearEnd { advanced = true; break monitor }
                try? await spotify.pause(); _ = try? tap.endSegment()
                // An ad, or an early skip (Spotify glitch), is worth a retry; a
                // change late in the track means someone else is driving Spotify.
                throw RowFailure(message: s.trackURI.hasPrefix("spotify:ad:") ? "Ad interrupted the track" : "Track changed mid-recording",
                                 requeue: s.trackURI.hasPrefix("spotify:ad:") || maxPos < 10,
                                 restartSpotify: !s.trackURI.hasPrefix("spotify:ad:") && maxPos < 10)
            }
            if s.state != .playing {
                if nearEnd { break monitor }
                // Paused by hand mid-track: the capture now contains a gap, so
                // this take is unusable. Put the row back and stop the batch.
                _ = try? tap.endSegment()
                throw RowFailure(message: "Paused in Spotify mid-track — press Start to redo this row", fatal: true)
            }
            if s.positionSec < maxPos - 0.5 {
                // Spotify jumped back (restarted the track): the take has a repeat.
                try? await spotify.pause(); _ = try? tap.endSegment()
                throw RowFailure(message: "Spotify restarted the track mid-take", requeue: true, glitch: true)
            }
            maxPos = max(maxPos, s.positionSec)
            positionSec = s.positionSec
            if !silenceChecked && Date().timeIntervalSince(playStart) > 4 {
                silenceChecked = true
                if tap.currentStats().peak == 0 {
                    try? await spotify.pause(); _ = try? tap.endSegment()
                    throw RowFailure(message: "No audio captured. Allow Karaifyer in System Settings → Privacy & Security → Screen & System Audio Recording (‘System Audio Recording Only’), then restart Karaifyer.", fatal: true)
                }
            }
            let remaining = Double(durMs) / 1000 - s.positionSec
            try await Task.sleep(for: .milliseconds(remaining < 2.5 ? 25 : 150))
        }

        // 4. Let the end of the track play out before pausing. Spotify reports
        // the next track (or "stopped") once it has finished *decoding*, with
        // part of the old track still buffered for output; pausing right away
        // cut ~150 ms off songs that end abruptly. Whatever of the next track
        // gets captured meanwhile is removed by the duration-based trim.
        try await Task.sleep(for: .milliseconds(advanced ? 700 : 1500))
        try? await spotify.pause()
        try await Task.sleep(for: .milliseconds(300))
        guard let seg = try tap.endSegment() else { throw RowFailure(message: "No capture") }

        // 5. Trim, encode, tag.
        states[row.index] = RowState(status: .encoding)
        let name = RecordingNaming.uniqueBase(
            base: RecordingNaming.base(title: row.title.isEmpty ? meta.title : row.title,
                                       artist: row.artist.isEmpty ? meta.artist : row.artist),
            trackID: row.trackID, exts: ["flac", "mp3"], existing: await freshIndex(for: dir).entries.mapValues(\.trackID))
        let base = dir.appendingPathComponent(name)
        let tags = TrackTags(title: meta.title, artist: meta.artist, album: meta.album,
                             trackNumber: row.number, comment: comment(for: row),
                             spotifyURI: row.uri, artworkURL: meta.artworkURL)   // the sheet's id: a relinked take still matches its row
        if seg.discontinuities > 0, (shortRetries[row.index] ?? 0) < 1 {
            shortRetries[row.index, default: 0] += 1
            throw RowFailure(message: "Capture had \(seg.discontinuities) gap(s)", requeue: true)
        }
        // Glitchy takes (Spotify stalls/restarts, dropped IO cycles) are re-recorded
        // up to twice; the last attempt is kept with a warning.
        let glitchTries = glitchRetries[row.index] ?? 0
        let r: PostProcess.Result
        do {
            r = try await PostProcess.finalize(segment: seg, durationMs: durMs, tags: tags,
                                               outputBase: base, makeMP3: makeMP3, allowGlitches: glitchTries >= 2,
                                               knownSilences: gapHistory[row.index] ?? [])
        } catch let g as GlitchError {
            glitchRetries[row.index] = glitchTries + 1
            gapHistory[row.index, default: []] += g.gaps
            throw RowFailure(message: g.localizedDescription, requeue: true, glitch: true)
        } catch let c as CaptureFaultError {
            // Row 19: a broken capture repeats identically, so rebuild the capture (and Spotify) before
            // retrying; after two rebuilds, mark the row failed rather than keep a damaged file.
            let n = (faultRetries[row.index] ?? 0) + 1
            faultRetries[row.index] = n
            if seg.halfEmptyBuffers > 0 { log("Row \(row.number): \(seg.halfEmptyBuffers) half-empty IO buffers in this take") }
            if n <= 2 {
                throw RowFailure(message: c.localizedDescription + " — capture reconstruite", requeue: true,
                                 restartSpotify: true, glitch: true)
            }
            throw RowFailure(message: c.localizedDescription + " — ligne non enregistrée, à relancer")
        }
        if r.warning != nil, (shortRetries[row.index] ?? 0) < 1 {
            // Missing audio at the end; a second take is cheap insurance.
            shortRetries[row.index, default: 0] += 1
            throw RowFailure(message: r.warning!, requeue: true)
        }
        states[row.index] = RowState(status: .done, file: r.flac, note: r.warning)
        _ = await freshIndex(for: dir)          // the new file joins the index (its duplicate rows read « done »)
        refreshDoneStates()
        log(String(format: "Row %@: %@ — %.0f Hz, %.2fs, lead-in trimmed %.3fs, peak %.1f dBFS, %d gaps%@",
                   row.number, r.flac.lastPathComponent, seg.sampleRate, Double(durMs) / 1000,
                   r.trimmedSeconds, 20 * log10(max(seg.peak, 1e-9)), seg.discontinuities,
                   r.warning.map { " — WARNING: \($0)" } ?? ""))
        if !r.trackSilences.isEmpty {
            log("Row \(row.number): \(CaptureCheck.summary(r.trackSilences)) identical in two takes: part of the track, kept")
        }
        if seg.halfEmptyBuffers > 0 { log("Row \(row.number): WARNING \(seg.halfEmptyBuffers) half-empty IO buffers") }
    }

    /// Loose title comparison for relinked tracks (sheet titles have typos/case/accents).
    static func titlesMatch(_ sheet: String, _ spotify: String) -> Bool {
        func norm(_ t: String) -> String {
            t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        let a = norm(sheet), b = norm(spotify)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    private func comment(for row: TrackRow) -> String {
        row.proposer.isEmpty ? "" : "Proposé par: \(row.proposer)"
    }

    private func log(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let url = listDir.appendingPathComponent("sysrec-log.txt")
        try? FileManager.default.createDirectory(at: listDir, withIntermediateDirectories: true)
        let data = Data("[\(ts)] \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func preventSleep() {
        guard sleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Karaifyer is recording a batch" as CFString, &sleepAssertion)
    }

    private func releaseSleep() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }
}
