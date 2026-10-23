import AppKit
import AVFoundation
import Foundation
import KaraifyerCore
import Observation

/// One song's lyrics + chord grid, with playback of travail/<id>/input.wav (input time).
/// Lyrics are in show time (= input + pad_s), like paroles.lrc; bars are in input time.
@MainActor @Observable
final class EditorModel {
    let song: SongState
    let karaoke: KaraokeModel
    var doc = LyricsDoc(lines: [])
    var lines: [LyricLine] { doc.lines }
    var cells: [String] = [] { didSet { recheckCells() } }
    var key: String
    /// Saved separately: a lyrics-only fix must not pin the chords to a correction (and vice versa).
    var lyricsDirty = false
    var chordsDirty = false
    var dirty: Bool { lyricsDirty || chordsDirty || gridDirty }
    var position: Double = 0
    var playing = false
    var selectedLine: UUID?
    var loadError: String?

    // MARK: chord charts (pasted tab, open datasets) merged with the detection by `karaoke grilles fusionner`

    /// Bars where the chart and the audio disagree (orange, « à vérifier à l'oreille »); a review aid, not saved.
    var flagged: Set<Int> = []
    var mergeSummary: String?
    var merging = false
    var importShown = false
    var importDraft = ""
    var suggestionIgnored: Bool {
        get { UserDefaults.standard.bool(forKey: "chordSuggestionIgnored.\(song.id)") }
        set { UserDefaults.standard.set(newValue, forKey: "chordSuggestionIgnored.\(song.id)"); ignoredRevision += 1 }
    }
    private var ignoredRevision = 0
    var showSuggestion: Bool { _ = ignoredRevision; return song.grilleProposee != nil && !suggestionIgnored }

    struct MergeError: Error { let message: String }

    /// Run the merge in the background (a pasted chart on stdin, or the suggested open chart) and apply it.
    func runMerge(texte: String?, source: String?) {
        // the merge cuts chords on the bar lines the pipeline knows: unsaved bar fixes would shift every chord
        guard !gridDirty else {
            loadError = "Enregistrer d'abord la correction des mesures, puis importer la grille."
            return
        }
        guard !merging else { return }
        let p = Pipeline()
        var args = p.args(["grilles", "fusionner", "--id", song.id, "--json"])
        if let source { args += ["--source", source] }
        if texte != nil { args += ["--texte", "-"] }
        let env = p.env, cwd = p.projectDir
        merging = true
        Task.detached {
            let result = Self.runProcess(args: args, env: env, cwd: cwd, input: texte)
            await MainActor.run {
                self.merging = false
                switch result {
                case .success(let data):
                    if let r = try? JSONDecoder().decode(MergeResult.self, from: data) { self.applyMerge(r) }
                    else { self.loadError = "Fusion de la grille : réponse illisible" }
                case .failure(let e):
                    self.loadError = "Fusion de la grille : \(e.message)"
                }
            }
        }
    }

    nonisolated static func runProcess(args: [String], env: [String: String], cwd: String, input: String?) -> Result<Data, MergeError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = inp
        do { try proc.run() } catch { return .failure(MergeError(message: error.localizedDescription)) }
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let last = errText.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            return .failure(MergeError(message: last.map(String.init) ?? "échec (\(proc.terminationStatus))"))
        }
        return .success(data)
    }

    /// « Visualiser »: the open chart as text (song's key, and as written), in a floating panel.
    func viewChart(source: String) {
        let p = Pipeline()
        let args = p.args(["grilles", "voir", "--id", song.id, "--source", source, "--json"])
        let env = p.env, cwd = p.projectDir
        let id = song.id, title = "\(source) — \(song.id) \(song.titre)"
        Task.detached {
            let result = Self.runProcess(args: args, env: env, cwd: cwd, input: nil)
            await MainActor.run {
                switch result {
                case .success(let data):
                    if let c = try? JSONDecoder().decode(ChartText.self, from: data) {
                        ProgressionPanel.show(id: id, kind: "chart", title: title, text: c.texte, original: c.original, note: c.shift)
                    } else { self.loadError = "Grille ouverte : réponse illisible" }
                case .failure(let e):
                    self.loadError = "Grille ouverte : \(e.message)"
                }
            }
        }
    }

    /// One undoable step: the merged cells and their orange marks.
    func applyMerge(_ r: MergeResult) {
        guard r.cells.count == cells.count else {
            loadError = "Fusion de la grille : \(r.cells.count) mesures, la grille en a \(cells.count) (réanalyser le morceau)"
            return
        }
        edit { cells = r.cells; flagged = Set(r.flagged); chordsDirty = true }
        mergeSummary = r.summary
    }
    var pad: Double { song.padS ?? 0 }
    var bpb: Int { gridAvailable ? gridBPB : (song.beatsPerBar ?? 4) }

    // MARK: bar grid (beats step + Michel's mesures/<id>.json fix, same rule as karaoke/barfix.py)

    var fix = BarFix.empty { didSet { recomputeGrid() } }
    var gridDirty = false
    /// The grid is editable when etat gave the beats and they agree with the song's bars (stale data: read only).
    private(set) var gridAvailable = false
    var beats: [Double] { song.grid?.beats ?? [] }
    /// The grid for the current fix, kept (not recomputed per cell and per redraw: playback redraws 20×/s).
    private(set) var barLines: [Int] = []
    private(set) var starts: [Int] = []
    private var gridBPB = 4
    private func recomputeGrid() {
        guard let g = song.grid else { barLines = []; starts = []; gridBPB = song.beatsPerBar ?? 4; return }
        let r = BarGrid.lines(beats: g.beats, detected: g.downbeatsDetectees, fix: fix, detectedBPB: g.beatsPerBarDetecte, bpm: g.bpm)
        barLines = r.lines; starts = BarGrid.starts(r.lines); gridBPB = r.bpb
        recheckCells()
    }
    func barStart(_ i: Int) -> Double { gridAvailable ? beats[starts[i]] : song.bars[i].start }
    func beatCount(_ i: Int) -> Int? {
        guard gridAvailable, i < starts.count else { return nil }
        return (i + 1 < starts.count ? starts[i + 1] : beats.count) - starts[i]
    }
    var beatCounter: (beat: Int, of: Int)? {
        guard gridAvailable else { return nil }
        return BarGrid.beatInBar(index: beats.lastIndex { $0 <= position + 1e-6 }, starts: starts, beatCount: beats.count)
    }

    private func changeFix(_ new: BarFix) {
        guard gridAvailable, new != fix, cellErrors.isEmpty else { return }
        edit {
            let oldStarts = starts, oldBPB = bpb
            fix = new
            if let c = BarGrid.recut(cells: cells, from: oldStarts, oldBPB: oldBPB, to: starts, newBPB: bpb, beatCount: beats.count) { cells = c }
            gridDirty = true
        }
        rebuildClick()
    }
    func moveBar(_ i: Int, by d: Int) { guard i < starts.count else { return }; changeFix(BarGrid.moved(fix, beats: beats, line: starts[i], by: d)) }
    func pinBar(_ i: Int) { guard i < starts.count else { return }; changeFix(BarGrid.pinned(fix, beats: beats, line: starts[i])) }
    func unpinBar(_ i: Int) { guard i < starts.count else { return }; changeFix(BarGrid.unpinned(fix, beats: beats, line: starts[i])) }
    func hasPin(_ i: Int) -> Bool { gridAvailable && i < starts.count && BarGrid.hasPin(fix, beats: beats, line: starts[i]) }
    func setSignature(_ s: String?) { var f = fix; f.signature = s; changeFix(f) }
    func setSwing(_ on: Bool) { var f = fix; f.swing = on; changeFix(f) }

    // MARK: click overlay (« Clic »), its own volume, both remembered for every song

    var clickOn: Bool = UserDefaults.standard.bool(forKey: "editorClickOn") {
        didSet { UserDefaults.standard.set(clickOn, forKey: "editorClickOn"); applyClickVolume() }
    }
    var clickVolume: Float = UserDefaults.standard.object(forKey: "editorClickVolume") as? Float ?? 0.7 {
        didSet { UserDefaults.standard.set(clickVolume, forKey: "editorClickVolume"); applyClickVolume() }
    }
    @ObservationIgnored private var clickPlayer: AVAudioPlayer?
    private func applyClickVolume() { clickPlayer?.volume = clickOn ? clickVolume : 0 }

    /// Re-render the click from the grid as it stands in the window; keeps it running in step with the recording.
    func rebuildClick() {
        guard gridAvailable, let p = player else { return }
        let data = ClickTrack.wav(ClickTrack.samples(beats: beats, accents: Set(barLines), duration: p.duration))
        clickPlayer?.stop()
        clickPlayer = try? AVAudioPlayer(data: data)
        clickPlayer?.prepareToPlay()
        applyClickVolume()
        if playing { startClick() }
    }
    private func startClick() {
        guard let p = player, let c = clickPlayer else { return }
        let at = p.deviceCurrentTime + 0.05
        c.currentTime = p.currentTime + 0.05
        c.play(atTime: at)
    }
    /// Playback volume (0…1), shared by every song and remembered.
    var volume: Float = UserDefaults.standard.object(forKey: "editorVolume") as? Float ?? 1 {
        didSet { player?.volume = volume; UserDefaults.standard.set(volume, forKey: "editorVolume") }
    }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var undoMonitor: Any?
    var windowTitle: String { "Corriger — \(song.id) \(song.titre)" }

    /// Space plays/pauses in this song's window when no text field is being edited.
    func installSpaceKey() {
        guard keyMonitor == nil else { return }
        let title = windowTitle
        keyMonitor = SpaceKey.monitor(accepts: { [weak self] w in w?.title == title && !(self?.syncing ?? false) }) { [weak self] in
            guard let self else { return }
            self.playing ? self.pause() : self.play()
        }
        // ⌘Z / ⇧⌘Z undo the editor's steps, unless a field is being typed in (it then undoes its own text)
        undoMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            nonisolated(unsafe) let e = ev
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, e.window?.title == title, !(e.window?.firstResponder is NSText),
                      e.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
                let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
                if self.syncing {                       // during sync, ⌘Z cancels the last stamp; ⇧⌘Z does nothing
                    if mods == .command { self.syncCancel() }
                    return mods == .command || mods == [.command, .shift]
                }
                if mods == .command { self.undo(); return true }
                if mods == [.command, .shift] { self.redo(); return true }
                return false
            }
            return handled ? nil : ev
        }
    }
    func removeSpaceKey() {
        stopSync(done: false)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = undoMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        undoMonitor = nil
    }
    @ObservationIgnored private var timer: Timer?

    init(song: SongState, karaoke: KaraokeModel) {
        self.song = song
        self.karaoke = karaoke
        key = song.key ?? "C major"
        let fm = FileManager.default
        let lrcPath = fm.fileExists(atPath: song.paths.lrcCorrige) ? song.paths.lrcCorrige : song.paths.lrc
        if let t = try? String(contentsOfFile: lrcPath, encoding: .utf8) {
            doc = LyricsDoc(lines: LRC.showTimeLines(t, pad: song.padS ?? 0))   // converts with the file's own decalage
        }
        fix = BarFix.decode(song.paths.mesuresCorrige.flatMap { fm.contents(atPath: $0) })
        recomputeGrid()                            // didSet doesn't run in init
        if let g = song.grid {                     // same bar positions as the song's chords, else etat is stale
            gridAvailable = BarGrid.matches(starts: starts, beats: g.beats, bars: song.bars.map(\.start))
        }
        cells = song.bars.map { ChordGrid.cellText($0.chords, beatsPerBar: bpb) }
        recheckCells()                             // didSet doesn't run in init
        var problems: [String] = []
        if song.padS == nil || song.bars.isEmpty { problems.append("Morceau pas encore analysé (paroles/accords absents).") }
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: song.paths.audio))
        player?.prepareToPlay()
        player?.volume = volume
        if player == nil { problems.append("Audio introuvable : \(song.paths.audio)") }
        loadError = problems.isEmpty ? nil : problems.joined(separator: " ")
        rebuildClick()
    }

    var duration: Double { player?.duration ?? 0 }
    var showTime: Double { position + pad }
    var currentLine: Int? { lines.lastIndex { $0.time <= showTime + 1e-6 } }
    var currentBar: Int? {
        gridAvailable ? starts.lastIndex { beats[$0] <= position + 1e-6 } : ChordGrid.barIndex(at: position, bars: song.bars)
    }
    /// Checked when a cell or the bar length changes, not per redraw: every cell reads it twice, and playback
    /// redraws 20×/s — recomputing it there cost ~90 ms a frame and made the bar highlight lag behind the music.
    private(set) var cellErrors: [Int: String] = [:]
    private func recheckCells() {
        var e: [Int: String] = [:]
        for (i, c) in cells.enumerated() {
            if case .failure(let err) = ChordGrid.parseCell(c, beatsPerBar: bpb) { e[i] = err.message }
        }
        if e != cellErrors { cellErrors = e }
    }

    func play() {
        guard let p = player else { return }
        p.play()
        startClick()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                self.position = p.currentTime
                if !p.isPlaying { self.pause() }
            }
        }
    }

    func pause() {
        player?.pause()
        clickPlayer?.pause()
        playing = false
        timer?.invalidate()
        timer = nil
    }

    func seek(input t: Double) {
        player?.currentTime = max(0, min(t, duration))
        position = player?.currentTime ?? 0
        clickPlayer?.currentTime = position
        if playing { clickPlayer?.stop(); startClick() }
    }
    func seekLine(_ id: UUID) {
        guard let l = lines.first(where: { $0.id == id }) else { return }
        selectedLine = id
        seek(input: l.time - pad)
    }
    func seekBar(_ i: Int) { seek(input: barStart(i)) }

    // MARK: lyric tap sync — Return stamps the active line at the moment it's sung (snapped to the voice)

    var syncing = false
    var replaceShown = false
    var replaceDraft = ""
    var sync: LyricsSync<UUID>?
    var syncMessage: String?
    private(set) var syncIDs: [UUID] = []
    @ObservationIgnored private var countIn: AVAudioPlayer?
    @ObservationIgnored private var voiceEnvelope: [Float]?
    @ObservationIgnored private var syncMonitor: Any?
    @ObservationIgnored private var syncTimer: Timer?
    private(set) var syncPaused = false

    private var clicFile: String { song.paths.dossier + "/clic.flac" }
    private var voiceFile: String { song.paths.dossier + "/guide_voix.flac" }
    var syncAvailable: Bool {
        song.padS != nil && player != nil && FileManager.default.fileExists(atPath: clicFile)
            && FileManager.default.fileExists(atPath: voiceFile)
    }
    var syncActiveID: UUID? { sync?.active }

    /// Show time now: the count-in's own time while it plays, then pad + the recording's time.
    private var syncShowNow: Double {
        SyncTime.showTime(countInPlaying: countIn?.isPlaying == true, countInTime: countIn?.currentTime ?? 0,
                            recordingTime: player?.currentTime ?? 0, pad: pad)
    }

    /// The show's count-in: the first pad_s seconds of the delivered click track.
    private func makeCountIn() -> AVAudioPlayer? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: clicFile)) else { return nil }
        let frames = AVAudioFrameCount(min(Double(f.length), pad * f.processingFormat.sampleRate))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: frames),
              (try? f.read(into: buf, frameCount: frames)) != nil, let ch = buf.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        let p = try? AVAudioPlayer(data: ClickTrack.wav(samples))
        p?.volume = volume
        p?.prepareToPlay()
        return p
    }

    func startSync(fromSelected: Bool) {
        guard syncAvailable, let p = player, !lines.isEmpty else { return }
        pause()
        endEditing()
        if voiceEnvelope == nil { voiceEnvelope = try? VocalOnset.load(url: URL(fileURLWithPath: voiceFile)) }
        syncIDs = lines.map(\.id)
        let start = fromSelected ? (selectedLine.flatMap { id in syncIDs.firstIndex(of: id) } ?? 0) : 0
        sync = LyricsSync(ids: syncIDs, startAt: start)
        syncMessage = nil
        syncPaused = false
        if start == 0 {
            countIn = makeCountIn()
            p.currentTime = 0
            let t0 = p.deviceCurrentTime + 0.1
            countIn?.play(atTime: t0)
            p.play(atTime: t0 + pad)
            if let c = clickPlayer { c.currentTime = 0; c.play(atTime: t0 + pad) }
        } else {
            countIn = nil
            p.currentTime = max(0, SyncTime.startTime(from: start, times: lines.map(\.time)) - pad)
            p.play()
            startClick()
        }
        syncing = true
        playing = true
        installSyncKeys()
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, self.syncing else { return }
                self.position = p.currentTime
                if !self.syncPaused, self.countIn?.isPlaying != true, p.currentTime >= p.duration - 0.05 || (!p.isPlaying && p.currentTime > 0) {
                    self.stopSync(done: true)
                }
            }
        }
    }

    private func installSyncKeys() {
        guard syncMonitor == nil else { return }
        let title = windowTitle
        syncMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            nonisolated(unsafe) let e = ev
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.syncing, e.window?.title == title, !(e.window?.firstResponder is NSText),
                      e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
                switch e.keyCode {
                case 36, 76: if !e.isARepeat && !self.syncPaused { self.syncStamp() }   // Return / keypad Enter
                case 126, 51: self.syncCancel()                   // ↑ / ⌫
                case 49: if !e.isARepeat { self.syncTogglePause() }   // Space
                case 53: self.stopSync(done: false)               // Escape
                default: return false
                }
                return true
            }
            return handled ? nil : ev
        }
    }

    func syncStamp() {
        guard var s = sync, let id = s.active, let line = lines.first(where: { $0.id == id }) else { return }
        let press = syncShowNow
        let snapped = voiceEnvelope.flatMap { VocalOnset.find(envelope: $0, near: press) } ?? press
        // never before the line stamped just before (sync order), so the saved lines stay in order
        let prevID = s.ids.firstIndex(of: id).flatMap { $0 > 0 ? s.ids[$0 - 1] : nil }
        let t = SyncTime.clamp(snapped, after: prevID.flatMap { p in lines.first { $0.id == p }?.time })
        edit { doc.stamp(line.id, at: t); lyricsDirty = true }
        _ = s.stamp(oldTime: line.time)
        sync = s
        selectedLine = line.id
    }

    func syncCancel() {
        guard var s = sync, let (id, old) = s.cancel() else { return }
        edit { doc.stamp(id, at: old); lyricsDirty = true }
        sync = s
    }

    /// While syncing, any change to the lines (a line added, deleted or replaced while paused, an undo) is followed.
    private func reconcileSync() {
        guard syncing, var s = sync else { return }
        s.reconcile(lines.map(\.id))
        sync = s
        syncIDs = s.ids
    }

    func syncTogglePause() {
        guard syncing, let p = player else { return }
        if syncPaused {
            let at = p.deviceCurrentTime + 0.05
            if let c = countIn, c.currentTime > 0, c.currentTime < c.duration - 0.01 {
                c.play(atTime: at)
                p.play(atTime: at + (c.duration - c.currentTime))
            } else {
                p.play(atTime: at)
                if let c = clickPlayer { c.currentTime = p.currentTime + 0.05; c.play(atTime: at) }
            }
            syncPaused = false
        } else {
            countIn?.pause()
            p.pause()
            clickPlayer?.pause()
            syncPaused = true
        }
    }

    func stopSync(done: Bool) {
        guard syncing else { return }
        syncTimer?.invalidate()
        syncTimer = nil
        if let m = syncMonitor { NSEvent.removeMonitor(m) }
        syncMonitor = nil
        countIn?.stop()
        countIn = nil
        player?.pause()
        clickPlayer?.pause()
        let n = sync?.progress.done ?? 0
        syncing = false
        playing = false
        syncPaused = false
        syncMessage = done ? "\(n) ligne\(n > 1 ? "s" : "") synchronisée\(n > 1 ? "s" : "")" : nil
    }

    /// « Remplacer le texte… »: unchanged lines keep their times; new ones are placed between their neighbours.
    func replaceText(_ text: String) {
        let r = LyricsText.replace(old: lines.map { (time: $0.time, text: $0.text) }, with: text)
        edit { doc = LyricsDoc(lines: r.lines.map { LyricLine(time: $0.time, text: $0.text) }); lyricsDirty = true }
        if syncing {
            let start = r.firstChanged ?? sync?.active.flatMap { a in syncIDs.firstIndex(of: a) } ?? 0
            syncIDs = lines.map(\.id)
            sync = LyricsSync(ids: syncIDs, startAt: min(start, syncIDs.count))
        }
    }

    func stampLine(_ id: UUID) { edit { doc.stamp(id, at: showTime); lyricsDirty = true } }
    func setText(_ id: UUID, _ text: String) { edit { doc.setText(id, text); lyricsDirty = true } }
    func setTime(_ id: UUID, _ s: String) { edit { doc.setTime(id, s); lyricsDirty = true } }
    func addLine() { edit { selectedLine = doc.add(at: showTime); lyricsDirty = true } }
    func deleteLine(_ id: UUID) { edit { doc.delete(id); lyricsDirty = true } }
    func setCell(_ i: Int, _ text: String) {
        guard cells.indices.contains(i), cells[i] != text else { return }
        edit { cells[i] = text; chordsDirty = true; flagged.remove(i) }
    }
    func setKey(_ k: String) { guard k != key else { return }; edit { key = k; chordsDirty = true } }

    // MARK: undo / redo (⌘Z, ⇧⌘Z) over lyrics, chords and key; the dirty flags come back too

    struct Snapshot {
        var doc: LyricsDoc; var cells: [String]; var key: String; var fix: BarFix; var flagged: Set<Int>
        var lyricsDirty, chordsDirty, gridDirty: Bool
    }
    private var snapshot: Snapshot {
        get { Snapshot(doc: doc, cells: cells, key: key, fix: fix, flagged: flagged, lyricsDirty: lyricsDirty,
                       chordsDirty: chordsDirty, gridDirty: gridDirty) }
        set { doc = newValue.doc; cells = newValue.cells; key = newValue.key; fix = newValue.fix; flagged = newValue.flagged
              lyricsDirty = newValue.lyricsDirty; chordsDirty = newValue.chordsDirty; gridDirty = newValue.gridDirty }
    }
    private var history = UndoHistory<Snapshot>()
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// One undoable step; a change that leaves everything as it was records nothing.
    private func edit(_ change: () -> Void) {
        let before = snapshot
        change()
        if before.doc.lines != doc.lines || before.cells != cells || before.key != key || before.fix != fix {
            history.record(before)
        }
        if before.doc.lines.map(\.id) != doc.lines.map(\.id) { reconcileSync() }
    }
    func undo() { if let s = history.undo(from: snapshot) { snapshot = s; rebuildClick() } }
    func redo() { if let s = history.redo(from: snapshot) { snapshot = s; rebuildClick() } }

    struct SaveError: LocalizedError { let errorDescription: String? }

    /// Writes paroles/<id>.lrc and accords/<id>.txt, then re-runs the song (lyrics/chords → video → set).
    func save() throws {
        if let (i, msg) = cellErrors.sorted(by: { $0.key < $1.key }).first {
            throw SaveError(errorDescription: "Mesure \(i + 1) : \(msg)")
        }
        if song.padS == nil || song.bars.isEmpty {
            throw SaveError(errorDescription: "Analyser le morceau avant de le corriger.")
        }
        let fm = FileManager.default
        func ensureDir(_ p: String) throws {
            try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        if lyricsDirty {
            try ensureDir(song.paths.lrcCorrige)
            try LRC.format(lines, decalage: pad).write(toFile: song.paths.lrcCorrige, atomically: true, encoding: .utf8)
        }
        if gridDirty, let p = song.paths.mesuresCorrige {
            if fix.isEmpty { try? fm.removeItem(atPath: p) } else { try ensureDir(p); try fix.encoded().write(to: URL(fileURLWithPath: p)) }
        }
        // a grid change re-cuts the cells: an existing chart must follow, or the pipeline counts a different number of bars
        if chordsDirty || (gridDirty && fm.fileExists(atPath: song.paths.accordsCorrige)) {
            try ensureDir(song.paths.accordsCorrige)
            try ChordGrid.chartText(title: song.titre, artist: song.artiste, key: key, bpm: nil, beatsPerBar: bpb,
                                    cells: cells, signature: fix.signature)
                .write(toFile: song.paths.accordsCorrige, atomically: true, encoding: .utf8)
        }
        lyricsDirty = false
        chordsDirty = false
        gridDirty = false
        karaoke.analyse(ids: [song.id])
    }
}
