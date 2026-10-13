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
    var lines: [LyricLine] = []
    var cells: [String] = []
    var key: String
    var position: Double = 0
    var playing = false
    var dirty = false
    var selectedLine: Int?
    var loadError: String?
    var pad: Double { song.padS ?? 0 }
    var bpb: Int { song.beatsPerBar ?? 4 }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    init(song: SongState, karaoke: KaraokeModel) {
        self.song = song
        self.karaoke = karaoke
        key = song.key ?? "C major"
        let fm = FileManager.default
        let lrcPath = fm.fileExists(atPath: song.paths.lrcCorrige) ? song.paths.lrcCorrige : song.paths.lrc
        if let t = try? String(contentsOfFile: lrcPath, encoding: .utf8) {
            let (l, dec) = LRC.parse(t)
            // A file without the decalage tag is in recording (input) time, like LRCLIB's.
            lines = dec == nil ? l.map { LyricLine(time: $0.time + pad, text: $0.text) } : l
        }
        cells = song.bars.map { ChordGrid.cellText($0.chords, beatsPerBar: bpb) }
        var problems: [String] = []
        if song.padS == nil || song.bars.isEmpty { problems.append("Morceau pas encore analysé (paroles/accords absents).") }
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: song.paths.audio))
        player?.prepareToPlay()
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
    func seekLine(_ i: Int) { selectedLine = i; seek(input: lines[i].time - pad) }
    func seekBar(_ i: Int) { seek(input: song.bars[i].start) }

    private func rounded(_ t: Double) -> Double { (t * 100).rounded() / 100 }

    func stampLine(_ i: Int) {
        lines[i].time = rounded(showTime)
        lines.sort { $0.time < $1.time }
        dirty = true
    }
    func setText(_ i: Int, _ text: String) { lines[i].text = text; dirty = true }
    func setTime(_ i: Int, _ s: String) {
        guard let t = LRC.parseTimecode(s) else { return }
        lines[i].time = t
        lines.sort { $0.time < $1.time }
        dirty = true
    }
    func addLine() {
        lines.append(LyricLine(time: rounded(showTime), text: ""))
        lines.sort { $0.time < $1.time }
        dirty = true
    }
    func deleteLine(_ i: Int) { lines.remove(at: i); dirty = true }
    func setCell(_ i: Int, _ text: String) { cells[i] = text; dirty = true }
    func setKey(_ k: String) { key = k; dirty = true }

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
        for p in [song.paths.lrcCorrige, song.paths.accordsCorrige] {
            try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try LRC.format(lines, decalage: pad).write(toFile: song.paths.lrcCorrige, atomically: true, encoding: .utf8)
        try ChordGrid.chartText(title: song.titre, artist: song.artiste, key: key, bpm: nil, beatsPerBar: bpb, cells: cells)
            .write(toFile: song.paths.accordsCorrige, atomically: true, encoding: .utf8)
        dirty = false
        karaoke.analyse(ids: [song.id])
    }
}
