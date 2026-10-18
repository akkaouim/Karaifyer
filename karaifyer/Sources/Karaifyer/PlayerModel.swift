import AppKit
import AVFoundation
import KaraifyerCore
import Observation

/// The Lecteur tab: one loaded song, its audio engine, a silent video slaved to the engine, and the song's
/// saved settings (mix, tempo, pitch, loop points).
@MainActor @Observable
final class PlayerModel {
    static let shared = PlayerModel()
    var query = ""
    var selectedID: String?
    private(set) var loaded: SongState?
    var settings = PlayerSettings.defaults(retirer: [])
    var loopOn = false
    var error: String?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var length: Double = 0
    @ObservationIgnored let videoPlayer = AVPlayer()
    @ObservationIgnored private var engine: PlayerEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var ticks = 0

    var songs: [SongState] { KaraokeModel.shared.songs }
    func missing(for s: SongState) -> [String] {
        PlayerLibrary.missingFiles(in: s.paths.dossier, exists: { FileManager.default.fileExists(atPath: $0) })
    }
    var filteredSongs: [SongState] {
        songs.filter { PlayerLibrary.matches(query, id: $0.id, titre: $0.titre, artiste: $0.artiste) }
    }
    var songBPM: Double? { loaded?.bpm }
    var rate: Float { Tempo.rate(target: settings.targetBPM, song: songBPM) }
    var loopRange: (Double, Double)? {
        guard let a = settings.loopStart, let b = settings.loopEnd, b > a else { return nil }
        return (a, b)
    }

    /// Load a ready song (deliberate: double-click, « Charger » or Return). Replaces the loaded song.
    func load(_ id: String) {
        guard let s = songs.first(where: { $0.id == id }), missing(for: s).isEmpty else { return }
        stopEverything()
        do {
            let urls = PlayerTrack.allCases.map { URL(fileURLWithPath: s.paths.dossier + "/" + $0.file) }
            let e = try PlayerEngine(tracks: urls)
            engine = e
            loaded = s
            length = e.length
            position = 0
            error = nil
            settings = PlayerSettings.decode(UserDefaults.standard.data(forKey: key(s.id)), retirer: s.retirer)
            loopOn = false
            videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: s.paths.dossier + "/paroles.mp4")))
            videoPlayer.isMuted = true
            applyAll()
        } catch {
            self.error = "Lecture impossible : \(error.localizedDescription)"
        }
    }

    private func key(_ id: String) -> String { "playerMix.\(id)" }
    private func save() { if let s = loaded { UserDefaults.standard.set(settings.encoded(), forKey: key(s.id)) } }

    private func applyAll() {
        guard let e = engine else { return }
        let g = settings.effectiveGains()
        e.setGains(PlayerTrack.allCases.map { g[$0] ?? 0 })
        e.setMaster(settings.masterGain)
        e.setPitch(cents: Pitch.cents(settings.semitones))
        e.setRate(rate)
        e.setLoop(loopOn ? loopRange : nil)
        if isPlaying { videoPlayer.rate = rate }
    }

    func togglePlay() {
        guard let e = engine else { return }
        if isPlaying {
            e.pause()
            videoPlayer.pause()
            isPlaying = false
            stopTimer()
        } else {
            if e.position >= length - 0.05 { e.seek(to: 0) }
            guard e.play() else {
                error = "Sortie audio indisponible : vérifiez la sortie son du Mac."
                return
            }
            error = nil
            isPlaying = true
            resyncVideo(force: true)
            videoPlayer.rate = rate
            startTimer()
        }
    }

    func restart() { seek(0) }

    func seek(_ t: Double) {
        engine?.seek(to: t)
        position = engine?.position ?? t
        resyncVideo(force: true)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let e = engine else { return }
        guard e.isPlaying else {                                  // the output device went away and won't restart
            videoPlayer.pause()
            isPlaying = false
            stopTimer()
            error = "Lecture interrompue : la sortie son a changé."
            return
        }
        let previous = position
        position = e.position
        ticks += 1
        // a loop wrap re-anchors the video at once; drift is checked every 0.5 s
        if position < previous - 0.05 || ticks % 5 == 0 { resyncVideo(force: false, previous: previous) }
        if !loopOn && position >= length - 0.02 { togglePlay(); seek(0) }
    }

    /// The video follows the audio: re-seek it when it drifts more than 40 ms (or always when forced).
    private func resyncVideo(force: Bool, previous: Double? = nil) {
        let now = engine?.position ?? 0
        let target = CMTime(seconds: now, preferredTimescale: 600)
        if force || VideoSync.needsResync(previous: previous ?? now, current: now,
                                          video: videoPlayer.currentTime().seconds) {
            videoPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func stopEverything() {
        engine?.pause()
        videoPlayer.pause()
        isPlaying = false
        stopTimer()
    }

    // MARK: mixer, tempo, pitch, loop (each change applied live and saved)

    func setFader(_ t: PlayerTrack, _ v: Double) { settings.faders[t] = v; applyAll(); save() }
    func toggleMute(_ t: PlayerTrack) { settings.mutes.formSymmetricDifference([t]); applyAll(); save() }
    func toggleSolo(_ t: PlayerTrack) { settings.solos.formSymmetricDifference([t]); applyAll(); save() }
    func setMaster(_ v: Double) { settings.master = v; applyAll(); save() }

    func setBPM(_ bpm: Double?) {
        guard let song = songBPM else { return }
        settings.targetBPM = bpm.map { Tempo.clamp($0, song: song) }
        applyAll()
        save()
    }

    func setSemitones(_ n: Int) { settings.semitones = Pitch.clamp(n); applyAll(); save() }

    /// Bar lines in song time: the analysis' bars are in input time; the song files start with the count-in.
    private var bars: [Double] {
        guard let s = loaded else { return [] }
        return s.bars.map { $0.start + (s.padS ?? 0) }
    }

    func markLoopStart() { settings.loopStart = LoopMath.snap(position, bars: bars); orderLoop() }
    func markLoopEnd() { settings.loopEnd = LoopMath.snap(position, bars: bars); orderLoop() }

    private func orderLoop() {
        if let a = settings.loopStart, let b = settings.loopEnd {
            (settings.loopStart, settings.loopEnd) = LoopMath.ordered(a, b)
        }
        applyAll()
        save()
    }

    func toggleLoop() { loopOn.toggle(); applyAll() }
    func clearLoop() { settings.loopStart = nil; settings.loopEnd = nil; loopOn = false; applyAll(); save() }

    // MARK: Space = play/pause everything, except while a text field is being edited

    func installSpaceKey() {
        guard keyMonitor == nil else { return }
        // only the main window and the full-screen video: a « Corriger » window has its own Space
        keyMonitor = SpaceKey.monitor(accepts: { w in w?.title == "Karaifyer" || (w != nil && w === FullScreenVideo.window) }) {
            [weak self] in self?.togglePlay()
        }
    }

    func removeSpaceKey() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    func exportEngine() -> PlayerEngine? { engine }
}
