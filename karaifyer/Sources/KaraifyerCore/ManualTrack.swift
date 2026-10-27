import Foundation

/// A song's title, artist and album from its public Spotify page (og:title, og:description « Artiste · Album ·
/// Song · 2023 »), shown when a song is added by hand. Only a preview: the recording takes Spotify's own metadata.
public enum SpotifyPage {
    public struct Track: Equatable, Sendable {
        public var title, artist, album: String
    }

    public static func parse(html: String) -> Track? {
        func meta(_ property: String) -> String? {
            guard let m = html.firstMatch(of: try! Regex(#"<meta property="\#(property)" content="([^"]*)""#)),
                  let s = m.output[1].substring else { return nil }
            return decode(String(s))
        }
        guard let title = meta("og:title"), let desc = meta("og:description") else { return nil }
        let parts = desc.components(separatedBy: " · ")
        guard parts.count >= 3, parts.contains("Song") else { return nil }      // a playlist, album or artist page
        return Track(title: title, artist: parts[0], album: parts[1])
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&lt;": "<", "&gt;": ">", "&#39;": "'", "&apos;": "'"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        while let m = out.firstMatch(of: /&#(x?)([0-9A-Fa-f]+);/) {
            let code = UInt32(m.output.2, radix: m.output.1.isEmpty ? 10 : 16).flatMap(Unicode.Scalar.init)
            out.replaceSubrange(m.range, with: code.map { String(Character($0)) } ?? "")
        }
        return out
    }

    /// The track page, in English so the description's « Song » marker is stable.
    public static func request(trackID: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://open.spotify.com/track/\(trackID)")!, timeoutInterval: 10)
        r.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        return r
    }
}

/// A song added to the queue by hand (« Ajouter un morceau… »), after the loaded list's rows: numbered M1, M2…
public enum ManualTrack {
    /// nil when the track is already in the queue.
    public static func row(trackID: String, title: String, artist: String, proposer: String, after rows: [TrackRow]) -> TrackRow? {
        guard !rows.contains(where: { $0.trackID == trackID }) else { return nil }
        let n = rows.filter { $0.number.hasPrefix("M") }.count + 1
        return TrackRow(index: rows.count, number: "M\(n)", title: title, artist: artist, proposer: proposer,
                        trackID: trackID, duplicateOf: nil)
    }
}
