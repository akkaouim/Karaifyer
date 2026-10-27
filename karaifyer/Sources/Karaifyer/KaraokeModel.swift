import AppKit
import Foundation
import IOKit.pwr_mgt
import KaraifyerCore
import Observation

/// State of the Karaoké tab: the manifest's songs (from `karaoke etat --json`), the analysis queue
/// (one `traiter --ids <id> --json` process per song), progress and the live log.
@MainActor @Observable
final class KaraokeModel: RunDriver {
    static let shared = KaraokeModel()
    var pipeline = Pipeline()
    var songs: [SongState] = []
    var selection: Set<String> = []
    /// The table's search and column sort (click a header; again to reverse).
    var query = ""
    /// Layout of the videos the analysis renders (paroles.mp4, used by the Ableton sets); read by Pipeline.env.
    var videoLayout: String = UserDefaults.standard.string(forKey: "videoLayout") ?? "grille" {
        didSet { UserDefaults.standard.set(videoLayout, forKey: "videoLayout") }
    }
    var sortOrder: [KeyPathComparator<SongState>] = [KeyPathComparator(\SongState.id)]
    var displayedSongs: [SongState] { SongList.filtered(songs, query: query).sorted(using: sortOrder) }
    var log: [String] = []
    var banner: String?
    var runState: RunState = .idle
    var currentID: String?
    var currentStep: String?
    var stopAfterCurrentRequested = false
    /// Marker column: what the current / last run did to each song.
    var marks = RunMarks()
    /// The one automatic retry of « à réessayer » songs has been done for this run.
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var userStopped = false
    @ObservationIgnored private var retrying = false
    /// While a run is in progress (paused included) the manifest can't be edited.
    var locked: Bool { runState != .idle }
    private(set) var doneSteps = 0
    private(set) var plannedSteps = 0
    private var plannedSongs = 0
    private var songsLeft = 0
    private var songStarted = Date()
    private var measured: [Double] = []
    @ObservationIgnored private var editors: [String: EditorModel] = [:]
    @ObservationIgnored private var controller: RunController!
    @ObservationIgnored private var process: SpawnedProcess?
    @ObservationIgnored private var sleepAssertion: IOPMAssertionID = 0

    init() {
        controller = RunController(driver: self)
        controller.onChange = { [weak self] in self?.syncState() }
    }

    var progress: Double { plannedSteps == 0 ? 0 : min(1, Double(doneSteps) / Double(plannedSteps)) }

    var etaText: String {
        let s = Estimate.remaining(songsLeft: songsLeft, currentElapsed: Date().timeIntervalSince(songStarted),
                                   measuredSongSeconds: measured)
        return String(format: "reste ≈ %d h %02d", Int(s) / 3600, (Int(s) % 3600) / 60)
    }

    var statusLine: String {
        guard runState != .idle, let id = currentID else { return "" }
        let title = songs.first { $0.id == id }?.titre ?? ""
        let n = plannedSongs - songsLeft + 1
        let pause = runState == .paused ? "En pause · " : runState == .stopping ? "Arrêt… · " : ""
        return "\(pause)Morceau \(n)/\(plannedSongs) · \(id) \(title) · étape : \(currentStep ?? "…") · \(etaText)"
    }

    /// One editor model per open window: SwiftUI re-evaluates the WindowGroup body often, and a fresh
    /// model there would reset playback and edits. Dropped on close so a reopen reloads the files.
    func editor(for id: String) -> EditorModel? {
        if let e = editors[id] { return e }
        guard let s = songs.first(where: { $0.id == id }) else { return nil }
        let e = EditorModel(song: s, karaoke: self)
        editors[id] = e
        return e
    }
    func closeEditor(_ id: String) { editors[id]?.pause(); editors[id] = nil }
    var hasUnsavedEditor: Bool { editors.values.contains { $0.dirty } }
    func closeAllEditors() { for id in Array(editors.keys) { closeEditor(id) } }

    /// User-guide screenshots only (`--screenshots`): show an analysis in progress without running one.
    func stageRunForScreenshot(current: String, step: String, queued: [String], done: [(String, String)],
                               log lines: [String]) {
        marks.begin([current] + queued + done.map(\.0))
        for (id, st) in done { marks.running(id); marks.songEnded(id, statut: st) }
        marks.running(current)
        runState = .running; currentID = current; currentStep = step
        plannedSongs = 1 + queued.count + done.count; songsLeft = 1 + queued.count
        plannedSteps = plannedSongs * 10; doneSteps = done.count * 10 + 3
        log = lines
    }

    func appendLog(_ line: String) {
        log.append(LogLine.stamped(line.trimmingCharacters(in: .newlines)))
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    func refresh() async {
        let problems = pipeline.problems()
        banner = problems.first ?? (pipeline.manifestExists ? nil : "Pas encore de manifeste.")
        guard problems.isEmpty, pipeline.manifestExists else { songs = []; return }
        let r = await pipeline.run(["etat", "--json"])
        if r.code == 0, let list = try? SongState.decodeList(Data(r.out.utf8)) {
            songs = list
            if measured.isEmpty {   // seed the estimate from songs already fully processed
                measured = list.compactMap { s in
                    s.steps.allSatisfy { $0.status == "a_jour" } ? s.steps.compactMap(\.seconds).reduce(0, +) : nil
                }.filter { $0 > 0 }
            }
        } else {
            banner = "Lecture de l'état impossible : " + r.err.split(separator: "\n").suffix(2).joined(separator: " ")
        }
    }

    /// First launch on a new Mac: create the karaoke folder (tree, empty manifest, default Ableton
    /// template) with `karaoke init`, and remember it.
    func createWorkspace(at path: String) async {
        let r = await pipeline.run(["init", "--home", path])
        appendLog(r.code == 0 ? "Dossier karaoké créé : \(path)" : "Création impossible : \(r.err)")
        if r.code == 0 { UserDefaults.standard.set(path, forKey: "karaokeHome"); KaraokeHome.remember(path) }
        await refresh()
    }

    func createManifest(from folder: URL) async {
        let r = await pipeline.run(["manifeste", "--audio", folder.path])
        appendLog(r.out + r.err)
        await refresh()
    }

    func add(files: [URL]) async {
        let r = await pipeline.run(["ajouter"] + files.map(\.path))
        appendLog(r.code == 0 ? "Ajout : \(r.out)" : "Ajout impossible : \(r.err)")
        await refresh()
    }

    @ObservationIgnored private var edits: Task<Void, Never>?

    /// Shows the edit at once, then writes it through `modifier`; edits run one after another so a
    /// quick second click builds on the first. Returns an error message (French) or nil.
    func set(id: String, field: String, value: String) async -> String? {
        if let i = songs.firstIndex(where: { $0.id == id }) {
            switch field {
            case "titre": songs[i].titre = value
            case "artiste": songs[i].artiste = value
            case "partie": songs[i].partie = value
            case "langue": songs[i].langue = value
            case "retirer": songs[i].retirer = value.split(separator: ";").map(String.init)
            default: break
            }
        }
        let previous = edits
        let task = Task { @MainActor () -> String? in
            await previous?.value
            let r = await pipeline.run(["modifier", "--id", id, "--champ", field, "--valeur", value])
            if r.code == 0 { return nil }
            let lines = r.err.split(separator: "\n").map(String.init)
            return lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Modification refusée"
        }
        edits = Task { _ = await task.value }
        let err = await task.value
        await refresh()
        return err
    }

    func analyse(ids: [String], forced: String? = nil) {
        endEditing()
        let busy = Set(controller.queue.map(\.id) + [controller.current?.id].compactMap { $0 })
        let jobs = (ids.isEmpty ? songs.map(\.id) : ids).filter { !busy.contains($0) }.map { Job(id: $0, forced: forced) }
        guard !jobs.isEmpty else { return }
        if runState == .idle && !retrying { marks.begin(jobs.map(\.id)); retried = false; userStopped = false }
        else { marks.add(jobs.map(\.id)) }
        plannedSongs += jobs.count
        songsLeft += jobs.count
        plannedSteps += jobs.count * max(1, songs.first?.steps.count ?? 10)
        controller.start(jobs)
    }
    /// « Retirer du manifeste… »: what each song would send to the Trash (for the confirmation sheet).
    /// nil (with the reason in the alert) when the pipeline can't say.
    func planRemoval(ids: [String]) async -> [RemovalItem]? {
        let r = await pipeline.run(["retirer", "--ids", ids.joined(separator: ","), "--plan", "--json"])
        if r.code == 0, let items = try? RemovalItem.decodeList(Data(r.out.utf8)) { return items }
        KaraokeUI.shared.alert = "Retrait impossible : "
            + (r.code == 0 ? "réponse illisible" : r.err.split(separator: "\n").last.map(String.init) ?? "échec")
        return nil
    }

    /// Remove the rows (the pipeline keeps a backup of the manifest and sends the chosen files to the Trash),
    /// then forget the app's own per-song state.
    func remove(_ choice: RemovalChoice) async {
        guard !locked else { return }
        let r = await pipeline.run(choice.arguments)
        if r.code == 0 {
            appendLog("Retiré du manifeste : \(choice.ids.joined(separator: ", ")) (fichiers choisis dans la Corbeille)")
            for id in choice.ids { for k in RemovalChoice.defaultsKeys(id: id) { UserDefaults.standard.removeObject(forKey: k) } }
            selection.subtract(choice.ids)
            PlayerModel.shared.forget(ids: Set(choice.ids))
        } else {
            KaraokeUI.shared.alert = "Retrait impossible : " + (r.err.split(separator: "\n").last.map(String.init) ?? "échec")
        }
        await refresh()
    }

    /// Output folders still named « 005_artiste_titre »: the one-time rename to « Titre - Artiste » is offered.
    private(set) var outputRenames: [[String: String]] = []
    @ObservationIgnored private var outputRenamesChecked = false

    func checkOutputRenames() async {
        // asked of the pipeline, not guessed from the names: a rename cut short leaves rows already « Titre - Artiste »
        guard !outputRenamesChecked, !locked, !songs.isEmpty else { return }
        outputRenamesChecked = true
        let r = await pipeline.run(["migrer-sorties", "--plan", "--json"])
        outputRenames = r.code == 0 ? (try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: String]]) ?? [] : []
    }

    func renameOutputs() async {
        guard !locked else { return }
        appendLog("Renommage des dossiers de sortie (\(outputRenames.count))…")
        let r = await pipeline.run(["migrer-sorties"])
        appendLog(r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                              : "Renommage impossible : " + (r.err.split(separator: "\n").last.map(String.init) ?? "échec"))
        if r.code != 0 { KaraokeUI.shared.alert = "Renommage impossible : " + (r.err.split(separator: "\n").last.map(String.init) ?? "échec") }
        outputRenamesChecked = false
        outputRenames = []
        await refresh()
        await checkOutputRenames()           // whatever is left (an interrupted run) is offered again
    }

    /// Songs whose recording is no longer where the manifest says.
    var missingRecordings: [SongState] { songs.filter { !FileManager.default.fileExists(atPath: $0.fichier) } }

    /// « Retrouver les enregistrements… »: `karaoke retrouver` (by Spotify id, else by name), plan then apply.
    func findRecordings(in dir: URL, apply: Bool) async -> [[String: String]]? {
        let r = await pipeline.run(["retrouver", "--dossier", dir.path, "--json"] + (apply ? [] : ["--plan"]))
        guard r.code == 0, let list = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: String]] else {
            KaraokeUI.shared.alert = "Recherche impossible : " + (r.err.split(separator: "\n").last.map(String.init) ?? "échec")
            return nil
        }
        if apply {
            appendLog("Retrouvé \(list.count) enregistrement(s) dans \(dir.path)")
            await refresh()
        }
        return list
    }

    /// Forget the saved beat detection, then re-run from the beats step (Michel's bar-grid fix is kept).
    func redetectBeats(ids: [String]) {
        for id in ids {
            for p in KaraokePaths.beatDetection(home: pipeline.karaokeHome, id: id) { try? FileManager.default.removeItem(atPath: p) }
        }
        analyse(ids: ids, forced: "beats")
    }
    func pause() { controller.pause() }
    func pauseForRecording() { controller.pauseForRecording() }
    func recordingEnded() { controller.recordingEnded() }
    /// App quitting: continue (if paused) then terminate the process group, and wait briefly.
    func terminateRun() {
        guard let p = process else { return }
        p.signal(SIGCONT)
        p.signal(SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while kill(p.pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        if kill(p.pid, 0) == 0 { p.signal(SIGKILL) }
    }
    func resume() { controller.resume() }
    func stopAfterCurrent() { userStopped = true; controller.requestStopAfterCurrent() }
    func stopNow() {
        userStopped = true
        marks.stopped()
        controller.stopNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.controller.killIfStillStopping() }
    }

    // MARK: RunDriver (called by RunController on the main actor)

    nonisolated func launch(_ job: Job) {
        MainActor.assumeIsolated {
            currentID = job.id
            currentStep = nil
            marks.running(job.id)
            songStarted = Date()
            appendLog("$ karaoke " + pipeline.traiterArgs(job).drop(while: { $0 != "traiter" }).joined(separator: " "))
            do {
                process = try SpawnedProcess(args: pipeline.traiterArgs(job), env: pipeline.env, cwd: pipeline.projectDir,
                                             onLine: { [weak self] in self?.handle(line: $0) },
                                             onExit: { [weak self] code in self?.exited(code) })
            } catch {
                appendLog("Lancement impossible : \(error)")
                DispatchQueue.main.async { [weak self] in self?.exited(-1) }
            }
        }
    }

    nonisolated func signal(_ s: RunSignal) {
        MainActor.assumeIsolated {
            let sig: Int32
            switch s {
            case .stop: sig = SIGSTOP
            case .cont: sig = SIGCONT
            case .term: sig = SIGTERM
            case .kill: sig = SIGKILL
            }
            process?.signal(sig)
        }
    }

    private func handle(line: String) {
        guard let ev = PipelineEvent.parse(line) else { appendLog(line); return }
        switch ev {
        case .songStart(let id):
            appendLog("▶ \(id)")
        case .stepStart(let id, let step):
            currentStep = step
            appendLog("[\(id)] début \(step)")
        case .stepEnd(let id, let step, let status, let secs, let err):
            doneSteps += 1
            appendLog("[\(id)] \(step) : \(status) (\(String(format: "%.0f", secs)) s)\(err.isEmpty ? "" : " — \(err)")")
            if let i = songs.firstIndex(where: { $0.id == id }),
               let j = songs[i].steps.firstIndex(where: { $0.name == step }) {
                songs[i].steps[j].status = ["fait", "saute"].contains(status) ? "a_jour" : status
                songs[i].steps[j].error = err
            }
        case .songEnd(let id, let statut):
            appendLog("■ \(id) → \(statut)")
            marks.songEnded(id, statut: statut)
            if let i = songs.firstIndex(where: { $0.id == id }) { songs[i].statut = statut }
        case .log(let id, let l):
            if !l.hasPrefix("début ") && !l.hasPrefix("fin ") { appendLog("[\(id)] \(l)") }
        }
    }

    private func exited(_ code: Int32) {
        if code != 0 { appendLog("[\(currentID ?? "?")] processus terminé (code \(code))") }
        if let id = currentID, runState != .stopping { marks.processExited(id, code: code) }
        if code == 0 { measured.append(Date().timeIntervalSince(songStarted)) }
        songsLeft = max(0, songsLeft - 1)
        process = nil
        controller.processExited()
        if controller.state == .idle && !userStopped && !retried {
            let again = marks.retryCandidates()
            retried = true
            if !again.isEmpty {
                appendLog("Nouvel essai pour : \(again.joined(separator: ", ")) (service en ligne injoignable plus tôt)")
                retrying = true
                analyse(ids: again)
                retrying = false
            }
        }
        Task { await refresh() }
    }

    private func syncState() {
        runState = controller.state
        stopAfterCurrentRequested = controller.stopAfterCurrent
        if runState == .idle {
            currentID = nil; currentStep = nil
            plannedSongs = 0; songsLeft = 0; plannedSteps = 0; doneSteps = 0
            if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
        } else if sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Karaifyer analyse" as CFString, &sleepAssertion)
        }
    }
}
