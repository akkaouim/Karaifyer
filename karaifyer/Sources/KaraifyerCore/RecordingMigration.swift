import Foundation

/// The one-time move from numbered names (`05 - Titre - Artiste.flac`, in `<root>/<CSV name>/`) to
/// « Titre - Artiste » names in the chosen folder itself.
public enum RecordingMigration {
    public struct Rename: Equatable, Sendable {
        public var from, to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct Plan: Equatable, Sendable {
        public var renames: [Rename]
        public var duplicates: [String]          // second copies of a track, renamed with a suffix, for Michel to delete
    }

    /// The old layout's list folder becomes the output folder, when it holds recordings.
    public static func outputFolder(savedRoot: String, listName: String?, dirHasRecordings: (String) -> Bool) -> String? {
        guard let listName, !listName.isEmpty else { return nil }
        let sub = (savedRoot as NSString).appendingPathComponent(FileNaming.sanitize(listName))
        return dirHasRecordings(sub) ? sub : nil
    }

    static func numbered(_ name: String) -> Bool { name.range(of: #"^\d+ - "#, options: .regularExpression) != nil }

    /// Numbered audio files renamed from their tags; a `.mp3.asd` follows its MP3. Unnumbered files and `others`
    /// (non-audio names) stay and are never renamed onto. Planning again after an interruption only lists the rest.
    public static func renames(entries: [String: RecordingIndex.Entry], others: [String]) -> Plan {
        var taken: [String: String?] = [:]
        for (n, e) in entries where !numbered(n) { taken[n] = e.trackID }
        for o in others where !numbered(o) { taken[o] = .some(nil) }
        var renames: [Rename] = [], duplicates: [String] = []
        var named: [String: Set<String>] = [:]               // track → extensions that already got the plain name
        for n in entries.keys.sorted() where numbered(n) {
            let e = entries[n]!
            let ext = (n as NSString).pathExtension
            let id = e.trackID ?? "?\(n)"
            // a second file of the same track must not take the first one's name
            let owner = named[id, default: []].contains(ext.lowercased()) ? "dup:\(n)" : id
            let to = RecordingNaming.unique(base: RecordingNaming.base(title: e.title, artist: e.artist),
                                            trackID: owner, ext: ext, existing: taken)
            taken[to] = .some(owner)
            if owner == id { named[id, default: []].insert(ext.lowercased()) } else { duplicates.append(to) }
            renames.append(Rename(from: n, to: to))
            if others.contains(n + ".asd") {
                renames.append(Rename(from: n + ".asd", to: to + ".asd"))
                taken[to + ".asd"] = .some(nil)
            }
        }
        return Plan(renames: renames, duplicates: duplicates)
    }
}

public enum FolderChoice {
    /// Moving the recordings is offered only to another folder that isn't inside the current one.
    public static func moveOffered(current: String, new: String) -> Bool {
        let c = URL(fileURLWithPath: current).standardizedFileURL.path
        let n = URL(fileURLWithPath: new).standardizedFileURL.path
        return n != c && !n.hasPrefix(c + "/")
    }
}

public enum SafeMove {
    /// Files whose name is free at the destination; the others are skipped, never overwritten.
    public static func plan(files: [String], destinationNames: Set<String>) -> (move: [String], skipped: [String]) {
        (files.filter { !destinationNames.contains($0) }, files.filter { destinationNames.contains($0) })
    }
}
