import AVFAudio
import Foundation
import KaraifyerCore

struct TrackTags {
    var title: String
    var artist: String
    var album: String
    var trackNumber: String
    var comment: String
    var spotifyURI: String
    var artworkURL: String
}

/// The take contains playback glitches; re-record it.
struct GlitchError: Error, LocalizedError {
    /// (position in seconds, gap length in ms)
    let gaps: [(at: Double, ms: Double)]
    var errorDescription: String? {
        "Playback glitch at " + gaps.map { String(format: "%.2fs (%.0f ms gap)", $0.at, $0.ms) }.joined(separator: ", ")
    }
}

/// So many silences that the capture itself is broken (never kept, whatever the take count).
struct CaptureFaultError: Error, LocalizedError {
    let gaps: [(at: Double, ms: Double)]
    var errorDescription: String? { "Capture défectueuse : " + CaptureCheck.summary(gaps) }
}

struct PostProcessError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Turns a raw segment capture into the final tagged FLAC (+ optional MP3).
enum PostProcess {
    static let ffmpeg: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Result {
        let flac: URL
        let mp3: URL?
        let trimmedSeconds: Double
        let warning: String?
        /// Gaps accepted as silence in the master (seen identically in an earlier take).
        var trackSilences: [(at: Double, ms: Double)] = []
    }

    /// - Parameters:
    ///   - durationMs: Spotify's reported duration; the output is exactly this long
    ///     (unless the capture is shorter, which is reported as a warning).
    static func finalize(segment: SegmentInfo, durationMs: Int, tags: TrackTags,
                         outputBase: URL, makeMP3: Bool, allowGlitches: Bool = false,
                         knownSilences: [(at: Double, ms: Double)] = []) async throws -> Result {
        guard let ffmpeg else { throw PostProcessError(message: "ffmpeg not found (brew install ffmpeg)") }

        guard let firstLoud = try firstLoudFrame(in: segment.url) else {
            throw PostProcessError(message: "Capture is silent — check System Audio Recording permission and that Spotify's volume isn't muted.")
        }
        let range = TrimMath.trimRange(firstLoud: firstLoud, totalFrames: Int(segment.frames),
                                       sampleRate: segment.sampleRate, durationMs: durationMs)
        let found = try dropouts(in: segment.url, range: range, sampleRate: segment.sampleRate)
        if CaptureCheck.isFault(gaps: found, durationS: Double(durationMs) / 1000) {
            throw CaptureFaultError(gaps: found)
        }
        // A gap found at the same spot with the same length in an earlier take
        // is silence in the master itself, not a playback accident.
        let partOfTrack = found.filter { g in knownSilences.contains { Self.sameGap(g, $0) } }
        let glitches = found.filter { g in !partOfTrack.contains { Self.sameGap(g, $0) } }
        if !glitches.isEmpty && !allowGlitches { throw GlitchError(gaps: glitches) }
        let expected = Int(Double(durationMs) / 1000 * segment.sampleRate)
        var warning: String? = glitches.isEmpty ? nil : GlitchError(gaps: glitches).localizedDescription
        if range.count < expected - Int(segment.sampleRate * 0.05) {
            warning = (warning.map { $0 + "; " } ?? "") + String(format: "Capture %.2fs shorter than the track", Double(expected - range.count) / segment.sampleRate)
        }

        let cover = await downloadArtwork(tags.artworkURL)
        defer { if let cover { try? FileManager.default.removeItem(at: cover) } }

        let flac = outputBase.appendingPathExtension("flac")
        let partial = partialURL(for: flac)
        var args = ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", segment.url.path]
        if let cover { args += ["-i", cover.path] }
        args += ["-map", "0:a"]
        if cover != nil {
            args += ["-map", "1:v", "-c:v", "copy", "-disposition:v", "attached_pic",
                     "-metadata:s:v", "comment=Cover (front)"]
        }
        args += ["-af", "atrim=start_sample=\(range.start):end_sample=\(range.start + range.count),asetpts=PTS-STARTPTS",
                 "-c:a", "flac", "-compression_level", "8", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
        args += metadataArgs(tags)
        args.append(partial.path)
        try await run(ffmpeg, args)
        try replace(flac, with: partial)

        let mp3 = makeMP3 ? try await encodeMP3(from: flac) : nil
        return Result(flac: flac, mp3: mp3, trimmedSeconds: Double(range.start) / segment.sampleRate,
                      warning: warning, trackSilences: partOfTrack)
    }

    /// Copies an already-recorded file under a new name, rewriting the per-row tags.
    static func duplicate(from src: URL, to outputBase: URL, tags: TrackTags, makeMP3: Bool) async throws -> Result {
        guard let ffmpeg else { throw PostProcessError(message: "ffmpeg not found") }
        let flac = outputBase.appendingPathExtension("flac")
        let partial = partialURL(for: flac)
        try await run(ffmpeg, ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", src.path,
                               "-map", "0", "-c", "copy"] + metadataArgs(tags) + [partial.path])
        try replace(flac, with: partial)
        let mp3 = makeMP3 ? try await encodeMP3(from: flac) : nil
        return Result(flac: flac, mp3: mp3, trimmedSeconds: 0, warning: nil)
    }

    static func encodeMP3(from flac: URL) async throws -> URL {
        guard let ffmpeg else { throw PostProcessError(message: "ffmpeg not found") }
        let mp3 = flac.deletingPathExtension().appendingPathExtension("mp3")
        let partial = partialURL(for: mp3)
        try await run(ffmpeg, ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", flac.path,
                               "-map", "0", "-c:v", "copy", "-c:a", "libmp3lame", "-b:a", "320k",
                               "-id3v2_version", "3", partial.path])
        try replace(mp3, with: partial)
        return mp3
    }

    // MARK: - Helpers

    static func partialURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".partial-" + url.lastPathComponent)
    }

    private static func replace(_ dst: URL, with src: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: src, to: dst)
    }

    private static func metadataArgs(_ t: TrackTags) -> [String] {
        var a: [String] = []
        func add(_ k: String, _ v: String) { if !v.isEmpty { a += ["-metadata", "\(k)=\(v)"] } }
        add("title", t.title)
        add("artist", t.artist)
        add("album", t.album)
        add("track", t.trackNumber)
        add("comment", t.comment)
        add("SPOTIFY_URI", t.spotifyURI)
        return a
    }

    /// Scans a capture file for the first sample above the silence threshold.
    static func firstLoudFrame(in url: URL) throws -> Int? {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let chunk: AVAudioFrameCount = 16384
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        var base = 0
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { return nil }
            var best: Int?
            let channels = Int(fmt.channelCount)
            let stride = fmt.isInterleaved ? channels : 1
            let planes = fmt.isInterleaved ? 1 : channels
            for c in 0..<planes {
                let p = UnsafeBufferPointer(start: data[c], count: n * stride)
                if let f = TrimMath.firstLoudFrame(p, channels: stride) { best = min(best ?? f, f) }
            }
            if let best { return base + best }
            base += n
        }
        return nil
    }

    /// Same position (±10 ms) and length (±5 ms or ±10%) in two takes.
    static func sameGap(_ a: (at: Double, ms: Double), _ b: (at: Double, ms: Double)) -> Bool {
        abs(a.at - b.at) <= 0.010 && abs(a.ms - b.ms) <= max(5, 0.1 * max(a.ms, b.ms))
    }

    /// Glitch times (seconds from the trimmed start) within `range` of a capture.
    static func dropouts(in url: URL, range: (start: Int, count: Int), sampleRate: Double) throws -> [(at: Double, ms: Double)] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let ch = Int(file.processingFormat.channelCount)
        file.framePosition = AVAudioFramePosition(range.start)
        let chunk: AVAudioFrameCount = 32768
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        var scanner = TrimMath.DropoutScanner(channels: ch, sampleRate: sampleRate)
        var remaining = range.count
        while remaining > 0 {
            try file.read(into: buf, frameCount: min(chunk, AVAudioFrameCount(remaining)))
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let p = buf.floatChannelData?[0] else { break }
            scanner.feed(UnsafeBufferPointer(start: p, count: n * ch))
            remaining -= n
        }
        return zip(scanner.dropouts, scanner.dropoutLengths).map { (Double($0) / sampleRate, Double($1) / sampleRate * 1000) }
    }

    private static func downloadArtwork(_ s: String) async -> URL? {
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sysrec-cover-\(UUID().uuidString).jpg")
        return (try? data.write(to: tmp)) != nil ? tmp : nil
    }

    private static func run(_ exe: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: PostProcessError(message: "ffmpeg failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
