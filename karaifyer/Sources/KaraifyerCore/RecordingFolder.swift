import Foundation

/// Recordings are named « Titre - Artiste » and identified by their Spotify id (the SPOTIFY_URI tag), not a number.
public enum RecordingNaming {
    public static func base(title: String, artist: String) -> String {
        let t = FileNaming.clean(title), a = FileNaming.clean(artist)
        return FileNaming.sanitize(a.isEmpty ? t : "\(t) - \(a)")
    }

    /// The first of `base`, `base (2)`… whose name is free (or this track's) for every extension, so a new FLAC
    /// never lands next to — or its MP3 over — another track's file.
    public static func uniqueBase(base: String, trackID: String, exts: [String], existing: [String: String?]) -> String {
        var n = 1
        while true {
            let b = n == 1 ? base : "\(base) (\(n))"
            if exts.allSatisfy({ ext in existing["\(b).\(ext)"].map { $0 == trackID } ?? true }) { return b }
            n += 1
        }
    }

    /// `base.ext`, or `base (2).ext`, `base (3).ext`… when the name holds another song. The same song keeps its name.
    public static func unique(base: String, trackID: String, ext: String, existing: [String: String?]) -> String {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(ext)" : "\(base) (\(n)).\(ext)"
            guard let owner = existing[name] else { return name }
            if owner == trackID { return name }
            n += 1
        }
    }
}

/// `.karaifyer-index.json` in a recordings folder: tags read once per file version (size + date), so matching rows
/// to files by Spotify id doesn't run ffprobe on every refresh. Deleting it only costs one re-read.
public struct RecordingIndex: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var size: Int64
        public var mtime: Double
        public var trackID: String?
        public var title, artist: String

        public init(size: Int64, mtime: Double, trackID: String?, title: String, artist: String) {
            self.size = size
            self.mtime = mtime
            self.trackID = trackID
            self.title = title
            self.artist = artist
        }
    }

    public static let fileName = ".karaifyer-index.json"
    public var entries: [String: Entry] = [:]

    public init() {}

    public static func load(dir: URL) -> RecordingIndex {
        (try? JSONDecoder().decode(RecordingIndex.self, from: Data(contentsOf: dir.appendingPathComponent(fileName))))
            ?? RecordingIndex()
    }

    public func save(dir: URL) {
        if let d = try? JSONEncoder().encode(self) {
            try? d.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        }
    }

    /// Re-reads only new or changed files (by size and date), drops vanished ones; true when anything changed.
    /// A failed read (nil) isn't stored, so it is tried again; hidden files (`.partial-…`) are never indexed.
    public mutating func refresh(listing: [(name: String, size: Int64, mtime: Double)], read: (String) -> Entry?) -> Bool {
        var changed = false
        let listing = listing.filter { !$0.name.hasPrefix(".") }
        let names = Set(listing.map(\.name))
        for gone in entries.keys where !names.contains(gone) {
            entries[gone] = nil
            changed = true
        }
        for f in listing {
            if let e = entries[f.name], e.size == f.size, e.mtime == f.mtime { continue }
            guard var e = read(f.name) else { continue }
            e.size = f.size
            e.mtime = f.mtime
            entries[f.name] = e
            changed = true
        }
        return changed
    }

    public func file(for trackID: String, ext: String = "flac") -> String? {
        entries.filter { $0.value.trackID == trackID && ($0.key as NSString).pathExtension.lowercased() == ext }
            .keys.sorted().first
    }
}
