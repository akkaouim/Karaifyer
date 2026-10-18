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
    var dirty: Bool { lyricsDirty || chordsDirty }
    var position: Double = 0
    var playing = false
    var selectedLine: UUID?
    var loadError: String?
    var pad: Double { song.padS ?? 0 }
    var bpb: Int { song.beatsPerBar ?? 4 }
    /// Playback volume (0…1), shared by every song and remembered.
    var volume: Float = UserDefaults.standard.object(forKey: "editorVolume") as? Float ?? 1 {
        didSet { player?.volume = volume; UserDefaults.standard.set(volume, forKey: "editorVolume") }
    }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var keyMonitor: Any?
    var windowTitle: String { "Corriger — \(song.id) \(song.titre)" }

    /// Space plays/pauses in this song's window when no text field is being edited.
    func installSpaceKey() {
        guard keyMonitor == nil else { return }
        let title = windowTitle
        keyMonitor = SpaceKey.monitor(accepts: { $0?.title == title }) { [weak self] in
            guard let self else { return }
            self.playing ? self.pause() : self.play()
        }
    }
    func removeSpaceKey() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
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
        cells = song.bars.map { ChordGrid.cellText($0.chords, beatsPerBar: bpb) }
        var problems: [String] = []
        if song.padS == nil || song.bars.isEmpty { problems.append("Morceau pas encore analysé (paroles/accords absents).") }
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: song.paths.audio))
        player?.prepareToPlay()
        player?.volume = volume
        if player == nil { problems.append("Audio introuvable : \(song.paths.audio)") }
        loadError = problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    var duration: Double { player?.duration ?? 0 }
    var showTime: Double { position + pad }
    var currentLine: Int? { lines.lastIndex { $0.time <= showTime + 1e-6 } }
    var currentBar: Int? { ChordGrid.barIndex(at: position, bars: song.bars) }
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
        playing = false
        timer?.invalidate()
        timer = nil
    }

    func seek(input t: Double) {
        player?.currentTime = max(0, min(t, duration))
        position = player?.currentTime ?? 0
    }
    func seekLine(_ id: UUID) {
        guard let l = lines.first(where: { $0.id == id }) else { return }
        selectedLine = id
        seek(input: l.time - pad)
    }
    func seekBar(_ i: Int) { seek(input: song.bars[i].start) }

    func stampLine(_ id: UUID) { doc.stamp(id, at: showTime); lyricsDirty = true }
    func setText(_ id: UUID, _ text: String) { doc.setText(id, text); lyricsDirty = true }
    func setTime(_ id: UUID, _ s: String) { doc.setTime(id, s); lyricsDirty = true }
    func addLine() { selectedLine = doc.add(at: showTime); lyricsDirty = true }
    func deleteLine(_ id: UUID) { doc.delete(id); lyricsDirty = true }
    func setCell(_ i: Int, _ text: String) {
        guard cells.indices.contains(i), cells[i] != text else { return }
        cells[i] = text
        chordsDirty = true
    }
    func setKey(_ k: String) { guard k != key else { return }; key = k; chordsDirty = true }

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
        if chordsDirty {
            try ensureDir(song.paths.accordsCorrige)
            try ChordGrid.chartText(title: song.titre, artist: song.artiste, key: key, bpm: nil, beatsPerBar: bpb, cells: cells)
                .write(toFile: song.paths.accordsCorrige, atomically: true, encoding: .utf8)
        }
        lyricsDirty = false
        chordsDirty = false
        karaoke.analyse(ids: [song.id])
    }
}
