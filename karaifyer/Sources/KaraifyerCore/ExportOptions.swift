import Foundation

public enum ExportKind: String, Codable, CaseIterable, Sendable { case videoMaster, masterOnly }

public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case aac, mp3, wav, flac
    public var ext: String { self == .aac ? "m4a" : rawValue }
    public var lossless: Bool { self == .wav || self == .flac }
}

/// The export sheet's choices (remembered in UserDefaults `playerExport`) and the ffmpeg command they make.
public struct ExportOptions: Codable, Equatable, Sendable {
    public var kind: ExportKind
    public var format: AudioFormat
    public var kbps: Int          // AAC / MP3
    public var bits: Int          // WAV / FLAC
    public var height: Int        // video: 1080 or 720
    public var highQuality: Bool  // video: CRF 18 vs 23
    public var videoKbps: Int     // video's AAC sound

    public static let defaults = ExportOptions(kind: .masterOnly, format: .aac, kbps: 256, bits: 24,
                                               height: 1080, highQuality: true, videoKbps: 256)

    public var ext: String { kind == .videoMaster ? "mp4" : format.ext }

    /// ffmpeg arguments after `-y`, given the rendered WAV, the song's video, the playback rate and the output.
    /// `videoTimed`: the video was rendered at the export's tempo already (Karaifyer's renderer) — no re-timing,
    /// only a resize when the chosen height isn't the rendered 1080.
    public func ffmpegArgs(wav: String, video: String, rate: Float, out: String, videoTimed: Bool = false) -> [String] {
        if kind == .videoMaster {
            let r = String(format: "%g", rate)
            let filter = videoTimed ? (height == 1080 ? [] : ["-vf", "scale=-2:\(height)"])
                                    : ["-vf", "setpts=PTS/\(r),scale=-2:\(height)"]
            return ["-i", video, "-i", wav, "-map", "0:v:0", "-map", "1:a:0"]
                + filter + ["-c:v", "libx264", "-crf", highQuality ? "18" : "23",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(videoKbps)k", "-shortest",
                    "-movflags", "+faststart", out]
        }
        switch format {
        case .aac: return ["-i", wav, "-c:a", "aac", "-b:a", "\(kbps)k", out]
        case .mp3: return ["-i", wav, "-c:a", "libmp3lame", "-b:a", "\(kbps)k", out]
        case .wav: return ["-i", wav, "-c:a", bits == 16 ? "pcm_s16le" : "pcm_s24le", out]
        case .flac:
            return ["-i", wav, "-c:a", "flac", "-sample_fmt", bits == 16 ? "s16" : "s32"]
                + (bits == 16 ? [] : ["-bits_per_raw_sample", "24"]) + [out]
        }
    }

    public static func fileName(id: String, titre: String, ext: String) -> String {
        let safe = titre.map { "/:?\\*\"<>|".contains($0) ? "-" : $0 }
        return "\(id) \(String(safe)) – mix.\(ext)"
    }

    public static func duration(songSeconds: Double, rate: Float) -> Double { songSeconds / Double(rate) }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data?) -> ExportOptions {
        guard let data, let o = try? JSONDecoder().decode(ExportOptions.self, from: data) else { return .defaults }
        return o
    }

    /// Where ffmpeg writes before the result replaces `out` (hidden, same folder, same extension), so a
    /// cancelled or failed export never touches a file already there.
    public static func partialURL(for out: URL) -> URL {
        let name = "." + out.deletingPathExtension().lastPathComponent + ".partial." + out.pathExtension
        return out.deletingLastPathComponent().appendingPathComponent(name)
    }
}

