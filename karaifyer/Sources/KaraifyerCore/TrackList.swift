import Foundation

/// One recordable row of the input sheet.
public struct TrackRow: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    /// Position among parsed rows (0-based), stable identity for the UI.
    public let index: Int
    /// The sheet's own number column ("1", "38", …); falls back to index+1.
    public let number: String
    public let title: String
    public let artist: String
    public let proposer: String
    /// 22-char Spotify base62 track ID.
    public let trackID: String
    /// Index of an earlier row with the same track ID, if any.
    public let duplicateOf: Int?

    public var uri: String { "spotify:track:\(trackID)" }
}

public struct TrackListParseResult: Sendable {
    public var rows: [TrackRow]
    /// Lines that had content but no recognizable Spotify track link.
    public var ignored: [(line: Int, reason: String)]
}

public enum TrackListError: Error, LocalizedError, Equatable {
    case noHeader
    public var errorDescription: String? {
        switch self {
        case .noHeader: return "Couldn't find a header row with a Spotify link column."
        }
    }
}

public enum TrackList {
    static let trackRegex = try! NSRegularExpression(
        pattern: #"(?:open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?track/|spotify:track:)([A-Za-z0-9]{22})"#
    )
    static let otherSpotifyRegex = try! NSRegularExpression(
        pattern: #"open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?(album|playlist|artist|episode|show)/|spotify:(album|playlist|artist|episode|show):"#
    )

    public static func extractTrackID(_ s: String) -> String? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = trackRegex.firstMatch(in: s, range: range),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Parses a sheet export. Columns are located by header name, not position:
    /// the link column contains "spotify", title "titre"/"title", artist
    /// "artist", proposer "propos"; the number column is the first header-less
    /// column whose cells look numeric. If no header row exists, every cell
    /// of every line is scanned for track links (plain list of URLs).
    public static func parse(_ text: String) -> TrackListParseResult {
        let table = CSV.parse(text)
        let lower = { (s: String) in s.lowercased().folding(options: .diacriticInsensitive, locale: nil) }

        guard let headerIdx = table.firstIndex(where: { row in
            row.contains { cell in
                let l = lower(cell)
                return l.contains("spotify") && !l.contains("spotify.com") && !l.contains("spotify:")
            }
        }) else {
            return parsePlain(table)
        }
        let header = table[headerIdx].map(lower)
        func col(_ pred: (String) -> Bool) -> Int? { header.firstIndex(where: pred) }
        let linkCol = col { $0.contains("spotify") }!
        let titleCol = col { $0.contains("titre") || $0.contains("title") }
        let artistCol = col { $0.contains("artist") }
        let proposerCol = col { $0.contains("propos") }

        let body = Array(table[(headerIdx + 1)...])
        let numberCol: Int? = header.indices.first { c in
            guard header[c].trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            let vals = body.compactMap { $0.indices.contains(c) ? $0[c] : nil }.filter { !$0.isEmpty }
            return !vals.isEmpty && vals.allSatisfy { Int($0.trimmingCharacters(in: .whitespaces)) != nil }
        }

        var rows: [TrackRow] = []
        var ignored: [(Int, String)] = []
        var firstByID: [String: Int] = [:]
        for (offset, cells) in body.enumerated() {
            let lineNo = headerIdx + offset + 2 // 1-based file line
            func cell(_ c: Int?) -> String {
                guard let c, cells.indices.contains(c) else { return "" }
                return cells[c].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let link = cell(linkCol)
            guard let id = extractTrackID(link) else {
                if !link.isEmpty {
                    ignored.append((lineNo, otherSpotifyRegex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)) != nil
                        ? "not a track link (album/playlist links aren't supported)"
                        : "no Spotify track link"))
                }
                continue
            }
            let index = rows.count
            let num = cell(numberCol)
            rows.append(TrackRow(
                index: index,
                number: num.isEmpty ? String(index + 1) : num,
                title: cell(titleCol),
                artist: cell(artistCol),
                proposer: cell(proposerCol),
                trackID: id,
                duplicateOf: firstByID[id]
            ))
            if firstByID[id] == nil { firstByID[id] = index }
        }
        return TrackListParseResult(rows: rows, ignored: ignored)
    }

    static func parsePlain(_ table: [[String]]) -> TrackListParseResult {
        var rows: [TrackRow] = []
        var ignored: [(Int, String)] = []
        var firstByID: [String: Int] = [:]
        for (i, cells) in table.enumerated() {
            guard let id = cells.lazy.compactMap(extractTrackID).first else {
                if cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    ignored.append((i + 1, "no Spotify track link"))
                }
                continue
            }
            // A non-link cell, if present, is used as the title.
            let name = cells.first { extractTrackID($0) == nil && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            let index = rows.count
            rows.append(TrackRow(index: index, number: String(index + 1), title: name, artist: "",
                                 proposer: "", trackID: id, duplicateOf: firstByID[id]))
            if firstByID[id] == nil { firstByID[id] = index }
        }
        return TrackListParseResult(rows: rows, ignored: ignored)
    }
}

/// File naming rules.
public enum FileNaming {
    /// "NN - Title - Artist" using sheet values, falling back to Spotify
    /// metadata for empty cells. Numbers are zero-padded to `width`.
    public static func baseName(row: TrackRow, spotifyTitle: String?, spotifyArtist: String?, width: Int) -> String {
        let num = Int(row.number).map { String(format: "%0\(width)d", $0) } ?? row.number
        let title = clean(row.title).nonEmpty ?? clean(spotifyTitle ?? "").nonEmpty ?? row.trackID
        let artist = clean(row.artist).nonEmpty ?? clean(spotifyArtist ?? "").nonEmpty
        return sanitize([num, title, artist].compactMap { $0 }.joined(separator: " - "))
    }

    /// Strips wrapping parentheses and turns "A/B" into "A & B".
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("("), t.hasSuffix(")"), t.count > 2 {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t.replacingOccurrences(of: #"\s*/\s*"#, with: " & ", options: .regularExpression)
    }

    /// Removes characters that are illegal or awkward in macOS/Finder file names.
    public static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: ":", with: " -")
        for ch in ["/", "\\", "?", "*", "\"", "<", ">", "|"] {
            t = t.replacingOccurrences(of: ch, with: "")
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(t.prefix(200))
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
