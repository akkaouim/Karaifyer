import AVFoundation
import Foundation

/// The player's audio: one AVAudioPlayerNode per track → per-track mixer (gain) → submix → time-pitch
/// (tempo + transposition) → main mixer (master) → output. Seeking, looping and tempo changes reschedule
/// every node from the same frame, so all tracks stay sample-aligned. Also renders offline for export.
public final class PlayerEngine: @unchecked Sendable {
    let engine = AVAudioEngine()
    let files: [AVAudioFile]
    let players: [AVAudioPlayerNode]
    let gains: [AVAudioMixerNode]
    let submix = AVAudioMixerNode()
    let timePitch = AVAudioUnitTimePitch()
    public let sampleRate: Double
    public let length: Double
    public private(set) var isPlaying = false
    private var anchor: Double = 0                 // song time where the current schedule starts
    private var loop: (Double, Double)?
    private var generation = 0                     // invalidates stale loop completions
    private var lastPosition: Double = 0           // last audible position, for a restart after a device change
    private var observer: NSObjectProtocol?
    /// How many times playing has been rescheduled / restarted after a device change (for tests).
    public private(set) var reschedules = 0
    public private(set) var restarts = 0

    public init(tracks: [URL]) throws {
        files = try tracks.map { try AVAudioFile(forReading: $0) }
        guard let first = files.first else { throw CocoaError(.fileReadNoSuchFile) }
        sampleRate = first.processingFormat.sampleRate
        length = files.map { Double($0.length) / $0.processingFormat.sampleRate }.min() ?? 0
        players = files.map { _ in AVAudioPlayerNode() }
        gains = files.map { _ in AVAudioMixerNode() }
        engine.attach(submix)
        engine.attach(timePitch)
        for (i, f) in files.enumerated() {
            engine.attach(players[i])
            engine.attach(gains[i])
            engine.connect(players[i], to: gains[i], format: f.processingFormat)
            engine.connect(gains[i], to: submix, format: nil)
        }
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        engine.connect(submix, to: timePitch, format: stereo)
        engine.connect(timePitch, to: engine.mainMixerNode, format: stereo)
        engine.prepare()
        // A change of output device (or its format) stops the engine: restart where the music was.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self] _ in
            guard let self, self.isPlaying, !self.engine.isInManualRenderingMode else { return }
            let at = self.lastPosition
            self.isPlaying = false
            self.restarts += 1
            self.play(from: at)
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    public func setGains(_ g: [Float]) {
        for (i, m) in gains.enumerated() where i < g.count { m.outputVolume = g[i] }
    }
    public func setMaster(_ g: Float) { engine.mainMixerNode.outputVolume = g }
    /// The time-pitch unit changes speed on the fly; the nodes' source-frame clock is unaffected, so
    /// nothing needs rescheduling (rescheduling caused an audible dropout on every tempo click).
    public func setRate(_ r: Float) {
        guard r != timePitch.rate else { return }
        timePitch.rate = r
    }
    public func setPitch(cents: Float) { timePitch.pitch = cents }

    public func setLoop(_ l: (Double, Double)?) {
        let new = l.flatMap { $0.1 > $0.0 ? $0 : nil }
        if new?.0 == loop?.0 && new?.1 == loop?.1 { return }
        let p = position
        loop = new
        if isPlaying { play(from: p) }
    }

    /// Song time now, as heard: the anchor plus song seconds pulled by the first node (its sample time counts
    /// source frames, i.e. song frames, before the time-pitch unit), minus what is still between the node and
    /// the speakers (time-pitch read-ahead + output latency, in song seconds), wrapped inside the loop.
    public var position: Double {
        guard isPlaying, let nt = players[0].lastRenderTime, let pt = players[0].playerTime(forNodeTime: nt) else {
            return anchor
        }
        let lead = (timePitch.auAudioUnit.latency + engine.outputNode.presentationLatency) * Double(timePitch.rate)
        let p = Self.songPosition(anchor: anchor, elapsed: Double(pt.sampleTime) / pt.sampleRate,
                                  lead: lead, loop: loop, length: length)
        lastPosition = p
        return p
    }

    static func songPosition(anchor: Double, elapsed: Double, lead: Double, loop: (Double, Double)?,
                             length: Double) -> Double {
        min(length, LoopMath.position(start: anchor, elapsed: max(0, elapsed - lead), loop: loop))
    }

    /// Start playing from `t` (default: where it is). False when the audio output cannot start.
    @discardableResult
    public func play(from t: Double? = nil) -> Bool {
        let start = min(max(0, t ?? position), length)
        schedule(from: start)
        if !engine.isRunning {
            do { try engine.start() } catch { isPlaying = false; return false }
        }
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        players.forEach { $0.play(at: when) }
        isPlaying = true
        lastPosition = start
        return true
    }

    public func pause() {
        let p = position
        isPlaying = false
        generation += 1
        players.forEach { $0.stop() }
        anchor = p
    }

    public func seek(to t: Double) {
        if isPlaying {
            play(from: t)
        } else {
            generation += 1
            players.forEach { $0.stop() }
            anchor = min(max(0, t), length)
        }
    }

    /// Stop every node and schedule each one from song time `start`: up to the loop end, then the loop
    /// segment again and again (4 passes queued ahead, each consumed pass queues one more), or to the end.
    private func schedule(from start: Double) {
        generation += 1
        let gen = generation
        players.forEach { $0.stop() }
        anchor = start
        reschedules += 1
        for (i, f) in files.enumerated() {
            let sr = f.processingFormat.sampleRate
            let from = AVAudioFramePosition(start * sr)
            if let (a, b) = loop, start < b {
                let end = AVAudioFramePosition(b * sr)
                players[i].scheduleSegment(f, startingFrame: from, frameCount: AVAudioFrameCount(max(0, end - from)), at: nil)
                let a0 = AVAudioFramePosition(a * sr), count = AVAudioFrameCount(max(1, end - a0))
                for _ in 0..<4 { scheduleLoopPass(i, from: a0, count: count, gen: gen) }
            } else {
                players[i].scheduleSegment(f, startingFrame: from, frameCount: AVAudioFrameCount(max(0, f.length - from)), at: nil)
            }
        }
    }

    /// One loop pass; when it has been consumed, queue one more (so 4 stay ahead and the wrap never starves).
    private func scheduleLoopPass(_ i: Int, from: AVAudioFramePosition, count: AVAudioFrameCount, gen: Int) {
        players[i].scheduleSegment(files[i], startingFrame: from, frameCount: count, at: nil,
                                   completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self, self.generation == gen, self.isPlaying else { return }
            self.scheduleLoopPass(i, from: from, count: count, gen: gen)
        }
    }

    /// The whole song (no loop) through the same graph, faster than real time, to a 24-bit WAV.
    /// `progress(0…1)` returning false cancels: the partial file is deleted and CancellationError thrown.
    public func renderOffline(to url: URL, progress: (Double) -> Bool) throws {
        let wasPlaying = isPlaying
        let resumeAt = position
        pause()
        engine.stop()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        defer {
            players.forEach { $0.stop() }
            engine.stop()
            engine.disableManualRenderingMode()
            engine.prepare()
            anchor = resumeAt
            if wasPlaying { play(from: resumeAt) }
        }
        let savedLoop = loop
        loop = nil
        schedule(from: 0)
        loop = savedLoop
        try engine.start()
        players.forEach { $0.play() }
        let total = AVAudioFramePosition(length / Double(timePitch.rate) * sampleRate)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                   frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buf.frameCapacity), total - done))
            let st = try engine.renderOffline(n, to: buf)
            guard st == .success else { break }
            try file.write(from: buf)
            done += AVAudioFramePosition(buf.frameLength)
            if !progress(Double(done) / Double(total)) {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
        }
    }
}
