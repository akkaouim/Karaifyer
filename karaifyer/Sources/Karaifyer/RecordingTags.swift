import Foundation
import KaraifyerCore

/// Reads the tags a recording carries (SPOTIFY_URI, title, artist) with ffprobe, for the folder's index.
enum RecordingTags {
    static let ffprobe: String? = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func read(_ url: URL) -> RecordingIndex.Entry {
        var entry = RecordingIndex.Entry(size: 0, mtime: 0, trackID: nil, title: "", artist: "")
        guard let ffprobe else { return entry }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "quiet", "-show_entries", "format_tags", "-of", "json", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return entry }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let tags = ((json?["format"] as? [String: Any])?["tags"] as? [String: String]) ?? [:]
        // tag keys come back in the case they were written (FLAC: SPOTIFY_URI; MP3: TXXX → SPOTIFY_URI)
        let lower = Dictionary(tags.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        if let uri = lower["spotify_uri"], uri.hasPrefix("spotify:track:") {
            entry.trackID = String(uri.dropFirst("spotify:track:".count))
        }
        entry.title = lower["title"] ?? ""
        entry.artist = lower["artist"] ?? ""
        return entry
    }
}
