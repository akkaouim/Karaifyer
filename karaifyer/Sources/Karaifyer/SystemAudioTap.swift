import AVFAudio
import CoreAudio
import Foundation

/// What a finished segment contains.
struct SegmentInfo {
    let url: URL
    let frames: Int64
    let sampleRate: Double
    let channels: Int
    let peak: Float
    /// Number of gaps/overlaps detected in the input timestamps (0 = gapless).
    let discontinuities: Int
}

/// Captures one app's audio (by bundle-ID prefix) through a Core Audio process
/// tap. The tap and its private aggregate device live for a whole batch; each
/// track is a "segment" written to its own temporary Float32 CAF file.
final class SystemAudioTap {
    let bundlePrefix: String
    private(set) var format: AVAudioFormat?
    /// Called (on the main queue) if the default output device changes mid-batch.
    var onOutputDeviceChanged: (() -> Void)?
    /// Human-readable notes gathered during start(), e.g. sample-rate changes.
    private(set) var notes: [String] = []

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    /// File writes happen here, never on Core Audio's real-time IO thread.
    private let ioQueue = DispatchQueue(label: "sysrec.tap.writer", qos: .userInteractive)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var restoreRate: (device: AudioDeviceID, rate: Double)?
    /// The output device the tap was built on.
    private var tappedOutput = AudioObjectID.unknown
    /// Source channels (0-based) to keep when tapping a multichannel device unmixed.
    private var channelMap: [Int]?

    // Accessed only on ioQueue.
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var frames: Int64 = 0
    private var peak: Float = 0
    private var writeError: Error?
    private var nextSampleTime: Float64?
    private var discontinuities = 0

    init(bundlePrefix: String) {
        self.bundlePrefix = bundlePrefix
    }

    var isRunning: Bool { procID != nil }

    /// Builds the tap + aggregate device and starts IO. Optionally switches the
    /// output device to `preferredSampleRate` first (restored in stop()).
    func start(preferredSampleRate: Double?) throws {
        guard !isRunning else { return }
        notes = []
        let output = try AudioObjectID.defaultOutputDevice()
        tappedOutput = output

        if let want = preferredSampleRate {
            let current: Double = try output.read(kAudioDevicePropertyNominalSampleRate, default: 0)
            if current != want {
                let ranges = (try? output.readArray(kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)) ?? []
                if ranges.contains(where: { $0.mMinimum <= want && want <= $0.mMaximum }) {
                    try output.write(kAudioDevicePropertyNominalSampleRate, want)
                    restoreRate = (output, current)
                    notes.append("Output device switched \(Int(current)) → \(Int(want)) Hz for the batch.")
                    Thread.sleep(forTimeInterval: 0.3) // let the device settle
                } else {
                    notes.append("Output device can't run at \(Int(want)) Hz; recording at \(Int(current)) Hz.")
                }
            }
        }

        let procs = AudioObjectID.processObjects(bundlePrefix: bundlePrefix)
        let outputUID = try output.readString(kAudioDevicePropertyDeviceUID)

        // A stereo *mixdown* folds every device channel into two and scales by
        // 1/(channels/2): on an 18-channel interface that's −19 dB. For
        // multichannel devices, tap the device stream unmixed instead and keep
        // only the device's stereo pair, which is exactly what the app sent.
        let outChannels = (try? output.readArray(kAudioDevicePropertyPreferredChannelsForStereo, of: UInt32.self,
                                                 scope: kAudioObjectPropertyScopeOutput)) ?? []
        let deviceChannels = output.channelCount(scope: kAudioObjectPropertyScopeOutput)
        let desc: CATapDescription
        if deviceChannels > 2, outChannels.count == 2 {
            desc = CATapDescription(processes: procs.map(\.id), deviceUID: outputUID, stream: 0)
            channelMap = outChannels.map { Int($0) - 1 }
            notes.append("\(deviceChannels)-channel output: capturing channels \(outChannels[0])+\(outChannels[1]) unmixed.")
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: procs.map(\.id))
            channelMap = nil
        }
        desc.name = "Karaifyer tap (\(bundlePrefix))"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        // Keep following the app if it relaunches or spawns a new audio process.
        desc.bundleIDs = Array(Set(procs.map(\.bundleID) + [bundlePrefix]))
        desc.isProcessRestoreEnabled = true
        if procs.isEmpty { notes.append("No running \(bundlePrefix) audio process yet; tapping by bundle ID.") }

        var tap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(desc, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Karaifyer Aggregate",
            kAudioAggregateDeviceUIDKey: "sysrec-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                // Tap and main device share a clock; compensation would only resample.
                kAudioSubTapDriftCompensationKey: false,
            ]],
        ]
        var agg = AudioObjectID.unknown
        do {
            try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg), "AudioHardwareCreateAggregateDevice")
        } catch {
            teardown(); throw error
        }
        aggregateID = agg
        // Large IO buffer: latency is irrelevant for recording, and the extra
        // slack avoids missed cycles (heard as short runs of digital silence).
        if let r = try? agg.read(kAudioDevicePropertyBufferFrameSizeRange, default: AudioValueRange(),
                                 scope: kAudioObjectPropertyScopeGlobal) {
            let size = UInt32(min(4096, r.mMaximum))
            try? agg.write(kAudioDevicePropertyBufferFrameSize, size)
            notes.append("IO buffer \(size) frames.")
        }

        var asbd: AudioStreamBasicDescription = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        // IO runs at the aggregate's rate (its main device's), which can differ
        // from what the tap reports: with BlackHole at 44.1 kHz the tap said 48 kHz
        // while buffers arrived at 44.1 kHz, so files were labelled 9% fast.
        let deviceRate: Double = (try? agg.read(kAudioDevicePropertyNominalSampleRate, default: 0)) ?? 0
        if deviceRate > 0 && deviceRate != asbd.mSampleRate {
            notes.append("Tap reports \(Int(asbd.mSampleRate)) Hz, device runs at \(Int(deviceRate)) Hz; using \(Int(deviceRate)) Hz.")
            asbd.mSampleRate = deviceRate
        }
        // >2 channels needs an explicit layout or AVAudioFormat returns nil.
        let layout = asbd.mChannelsPerFrame > 2
            ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame)
            : nil
        let tapFmt = layout.map { AVAudioFormat(streamDescription: &asbd, channelLayout: $0) }
            ?? AVAudioFormat(streamDescription: &asbd)
        guard let fmt = tapFmt else {
            teardown(); throw CoreAudioError(what: "unsupported tap format", status: -1)
        }
        if let map = channelMap, map.allSatisfy({ $0 >= 0 && $0 < Int(fmt.channelCount) }) {
        } else if fmt.channelCount == 2 {
            channelMap = [0, 1]
        } else {
            teardown(); throw CoreAudioError(what: "tap has \(fmt.channelCount) channels but no stereo pair", status: -1)
        }
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 2, interleaved: true)!
        format = out
        let map = channelMap!

        // No dispatch queue: the block runs synchronously on the IO thread, so
        // the input buffers are valid while we copy. A queued block can run
        // after Core Audio has reused them (that dropped/duplicated 512-frame
        // chunks in early tests).
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { [weak self] _, input, inputTime, _, _ in
            self?.captureOnIOThread(input, time: inputTime.pointee, tapFormat: fmt, map: map, out: out)
        }
        do {
            try check(status, "AudioDeviceCreateIOProcIDWithBlock")
            procID = proc
            try check(AudioDeviceStart(aggregateID, proc), "AudioDeviceStart")
        } catch {
            teardown(); throw error
        }
        installDeviceListener()
    }

    func stop() {
        _ = try? endSegment()
        teardown()
    }

    /// Starts writing captured audio to a fresh temp file.
    func beginSegment(url: URL) throws {
        guard let fmt = format else { throw CoreAudioError(what: "tap not started", status: -1) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
        ioQueue.sync {
            file = f; fileURL = url; frames = 0; peak = 0; writeError = nil
            nextSampleTime = nil; discontinuities = 0
        }
    }

    /// Stops writing and closes the current segment file.
    @discardableResult
    func endSegment() throws -> SegmentInfo? {
        // ioQueue is FIFO, so this runs after every buffer captured so far is written.
        let (f, url, n, pk, err, gaps): (AVAudioFile?, URL?, Int64, Float, Error?, Int) = ioQueue.sync {
            defer { file = nil; fileURL = nil }
            return (file, fileURL, frames, peak, writeError, discontinuities)
        }
        guard let f, let url, let fmt = format else { return nil }
        f.close()
        if let err { throw err }
        return SegmentInfo(url: url, frames: n, sampleRate: fmt.sampleRate, channels: Int(fmt.channelCount),
                           peak: pk, discontinuities: gaps)
    }

    /// Live stats for the current segment (frames written, peak level).
    func currentStats() -> (frames: Int64, peak: Float) {
        ioQueue.sync { (frames, peak) }
    }

    // MARK: - Private

    /// Real-time IO thread: copy the tap's stereo pair out of the input
    /// buffers, then hand the copy to the writer queue. The aggregate's input
    /// list holds the output device's own input streams (e.g. 18 channels on a
    /// USB interface) *followed by* the tap's stream, so the tap is the last
    /// buffer (interleaved) or the last N buffers (planar).
    private func captureOnIOThread(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp,
                                   tapFormat fmt: AVAudioFormat, map: [Int], out: AVAudioFormat) {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let ch = Int(fmt.channelCount)
        let planar = !fmt.isInterleaved
        let needed = planar ? ch : 1
        guard all.count >= needed else { return }
        let first = all.count - needed
        let bytesPerFrame = MemoryLayout<Float>.size * (planar ? 1 : ch)
        let frames = Int(all[first].mDataByteSize) / bytesPerFrame
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(frames)),
              let dst = copy.floatChannelData?[0] else { return }
        if planar {
            for (o, c) in map.enumerated() {
                guard let src = all[first + c].mData?.assumingMemoryBound(to: Float.self) else { return }
                for f in 0..<frames { dst[f * 2 + o] = src[f] }
            }
        } else {
            guard let src = all[first].mData?.assumingMemoryBound(to: Float.self) else { return }
            let l = map[0], r = map[1]
            for f in 0..<frames {
                dst[f * 2] = src[f * ch + l]
                dst[f * 2 + 1] = src[f * ch + r]
            }
        }
        copy.frameLength = AVAudioFrameCount(frames)
        let sampleTime = time.mFlags.contains(.sampleTimeValid) ? time.mSampleTime : -1
        ioQueue.async { [weak self] in self?.write(copy, sampleTime: sampleTime) }
    }

    /// Writer queue.
    private func write(_ buf: AVAudioPCMBuffer, sampleTime: Float64) {
        guard let file, writeError == nil else { return }
        if sampleTime >= 0 {
            if let expected = nextSampleTime, abs(sampleTime - expected) > 0.5 { discontinuities += 1 }
            nextSampleTime = sampleTime + Float64(buf.frameLength)
        }
        do {
            try file.write(from: buf)
            frames += Int64(buf.frameLength)
            if let p = buf.floatChannelData?[0] {
                for i in 0..<Int(buf.frameLength) * 2 { let v = abs(p[i]); if v > peak { peak = v } }
            }
        } catch {
            writeError = error
        }
    }

    private func installDeviceListener() {
        var addr = AudioObjectID.system.address(kAudioHardwarePropertyDefaultOutputDevice)
        // Notifications arrive asynchronously, possibly for a switch made just
        // before the tap was built (silent mode). React only to a real change
        // away from the tapped device.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let now = try? AudioObjectID.defaultOutputDevice(), now != self.tappedOutput else { return }
            self.onOutputDeviceChanged?()
        }
        if AudioObjectAddPropertyListenerBlock(.system, &addr, .main, block) == noErr {
            deviceListener = block
        }
    }

    private func teardown() {
        if let block = deviceListener {
            var addr = AudioObjectID.system.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(.system, &addr, .main, block)
            deviceListener = nil
        }
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        if let r = restoreRate {
            try? r.device.write(kAudioDevicePropertyNominalSampleRate, r.rate)
            restoreRate = nil
        }
        format = nil
        channelMap = nil
    }

    deinit { teardown() }
}
