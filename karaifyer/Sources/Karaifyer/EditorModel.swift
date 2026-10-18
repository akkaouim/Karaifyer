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
    var cells: [String] = []
    var key: String
    /// Saved separately: a lyrics-only fix must not pin the chords to a correction (and vice versa).
    var lyricsDirty = false
    var chordsDirty = false
    var dirty: Bool { lyricsDirty || chordsDirty || gridDirty }
    var position: Double = 0
    var playing = false
    var selectedLine: UUID?
    var loadError: String?
    var pad: Double { song.padS ?? 0 }
    var bpb: Int { gridAvailable ? detectedLines.bpb : (song.beatsPerBar ?? 4) }

    // MARK: bar grid (beats step + Michel's mesures/<id>.json fix, same rule as karaoke/barfix.py)

    var fix = BarFix.empty
    var gridDirty = false
    /// The grid is editable when etat gave the beats and they agree with the song's bars (stale data: read only).
    private(set) var gridAvailable = false
    var beats: [Double] { song.grid?.beats ?? [] }
    private var detectedLines: (lines: [Int], bpb: Int) {
        guard let g = song.grid else { return ([], song.beatsPerBar ?? 4) }
        return BarGrid.lines(beats: g.beats, detected: g.downbeatsDetectees, fix: fix, detectedBPB: g.beatsPerBarDetecte, bpm: g.bpm)
    }
    var starts: [Int] { BarGrid.starts(detectedLines.lines) }
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
        let lines = Set(detectedLines.lines)
        let data = ClickTrack.wav(ClickTrack.samples(beats: beats, accents: lines, duration: p.duration))
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
        keyMonitor = SpaceKey.monitor(accepts: { $0?.title == title }) { [weak self] in
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
                if mods == .command { self.undo(); return true }
                if mods == [.command, .shift] { self.redo(); return true }
                return false
            }
            return handled ? nil : ev
        }
    }
    func removeSpaceKey() {
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
        if let g = song.grid {
            gridAvailable = BarGrid.starts(BarGrid.lines(beats: g.beats, detected: g.downbeatsDetectees, fix: fix,
                                                         detectedBPB: g.beatsPerBarDetecte, bpm: g.bpm).lines).count == song.bars.count
        }
        cells = song.bars.map { ChordGrid.cellText($0.chords, beatsPerBar: bpb) }
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
    var cellErrors: [Int: String] {
        var e: [Int: String] = [:]
        for (i, c) in cells.enumerated() {
            if case .failure(let err) = ChordGrid.parseCell(c, beatsPerBar: bpb) { e[i] = err.message }
        }
        return e
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

    func stampLine(_ id: UUID) { edit { doc.stamp(id, at: showTime); lyricsDirty = true } }
    func setText(_ id: UUID, _ text: String) { edit { doc.setText(id, text); lyricsDirty = true } }
    func setTime(_ id: UUID, _ s: String) { edit { doc.setTime(id, s); lyricsDirty = true } }
    func addLine() { edit { selectedLine = doc.add(at: showTime); lyricsDirty = true } }
    func deleteLine(_ id: UUID) { edit { doc.delete(id); lyricsDirty = true } }
    func setCell(_ i: Int, _ text: String) {
        guard cells.indices.contains(i), cells[i] != text else { return }
        edit { cells[i] = text; chordsDirty = true }
    }
    func setKey(_ k: String) { guard k != key else { return }; edit { key = k; chordsDirty = true } }

    // MARK: undo / redo (⌘Z, ⇧⌘Z) over lyrics, chords and key; the dirty flags come back too

    struct Snapshot {
        var doc: LyricsDoc; var cells: [String]; var key: String; var fix: BarFix
        var lyricsDirty, chordsDirty, gridDirty: Bool
    }
    private var snapshot: Snapshot {
        get { Snapshot(doc: doc, cells: cells, key: key, fix: fix, lyricsDirty: lyricsDirty, chordsDirty: chordsDirty, gridDirty: gridDirty) }
        set { doc = newValue.doc; cells = newValue.cells; key = newValue.key; fix = newValue.fix
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
