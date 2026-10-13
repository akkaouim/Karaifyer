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
    var log: [String] = []
    var banner: String?
    var runState: RunState = .idle
    var currentID: String?
    var currentStep: String?
    var stopAfterCurrentRequested = false
    private(set) var doneSteps = 0
    private(set) var plannedSteps = 0
    private var plannedSongs = 0
    private var songsLeft = 0
    private var songStarted = Date()
    private var measured: [Double] = []
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

    func appendLog(_ line: String) {
        log.append(line)
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

    /// Returns an error message (French) or nil.
    func set(id: String, field: String, value: String) async -> String? {
        let r = await pipeline.run(["modifier", "--id", id, "--champ", field, "--valeur", value])
        await refresh()
        return r.code == 0 ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func analyse(ids: [String], forced: String? = nil) {
        let busy = Set(controller.queue.map(\.id) + [controller.current?.id].compactMap { $0 })
        let jobs = (ids.isEmpty ? songs.map(\.id) : ids).filter { !busy.contains($0) }.map { Job(id: $0, forced: forced) }
        guard !jobs.isEmpty else { return }
        plannedSongs += jobs.count
        songsLeft += jobs.count
        plannedSteps += jobs.count * max(1, songs.first?.steps.count ?? 10)
        controller.start(jobs)
    }
    func pause() { controller.pause() }
    func resume() { controller.resume() }
    func stopAfterCurrent() { controller.requestStopAfterCurrent() }
    func stopNow() {
        controller.stopNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.controller.killIfStillStopping() }
    }

    // MARK: RunDriver (called by RunController on the main actor)

    nonisolated func launch(_ job: Job) {
        MainActor.assumeIsolated {
            currentID = job.id
            currentStep = nil
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
            if let i = songs.firstIndex(where: { $0.id == id }) { songs[i].statut = statut }
        case .log(let id, let l):
            if !l.hasPrefix("début ") && !l.hasPrefix("fin ") { appendLog("[\(id)] \(l)") }
        }
    }

    private func exited(_ code: Int32) {
        if code != 0 { appendLog("[\(currentID ?? "?")] processus terminé (code \(code))") }
        if code == 0 { measured.append(Date().timeIntervalSince(songStarted)) }
        songsLeft = max(0, songsLeft - 1)
        process = nil
        controller.processExited()
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
