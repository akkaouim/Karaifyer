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

    public static func isNumbered(_ name: String) -> Bool { numbered(name) }

    static func numbered(_ name: String) -> Bool {
        (name as NSString).lastPathComponent.range(of: #"^\d+ - "#, options: .regularExpression) != nil
    }

    /// The recordings' home: from `start` up, while the parent folder itself holds numbered recordings (the recorder
    /// was pointed at a CSV subfolder of it).
    public static func target(start: String, hasNumbered: (String) -> Bool) -> String {
        var t = URL(fileURLWithPath: start).standardizedFileURL.path
        while true {
            let parent = (t as NSString).deletingLastPathComponent
            guard parent != t, parent != "/", hasNumbered(parent) else { return t }
            t = parent
        }
    }

    /// A starting folder without numbered recordings of its own (the old default ~/Music/SysRec) gives way to its
    /// subfolder holding the most.
    public static func descend(start: String, ownCount: Int, subfolderCounts: [String: Int]) -> String {
        guard ownCount == 0, let best = subfolderCounts.filter({ $0.value > 0 }).max(by: { $0.value < $1.value }) else { return start }
        return best.key
    }

    /// Recordings of subfolders (other CSVs' folders) that join the target: tracks it doesn't have yet, each once.
    /// Keys are « subfolder/name ». A subfolder holding only tracks already there (« old takes ») brings nothing.
    public static func incoming(main: [String: RecordingIndex.Entry],
                                subfolders: [String: [String: RecordingIndex.Entry]]) -> [String: RecordingIndex.Entry] {
        var have = Set(main.values.compactMap(\.trackID))
        var out: [String: RecordingIndex.Entry] = [:]
        for sub in subfolders.keys.sorted() {
            var brought = Set<String>()
            for (name, e) in subfolders[sub]!.sorted(by: { $0.key < $1.key }) {
                guard let id = e.trackID, !have.contains(id) || brought.contains(id) else { continue }
                out["\(sub)/\(name)"] = e
                brought.insert(id)
            }
            have.formUnion(brought)
        }
        return out
    }

    /// Numbered audio files renamed from their tags; a `.mp3.asd` follows its MP3. Unnumbered files and `others`
    /// (non-audio names) stay and are never renamed onto. Planning again after an interruption only lists the rest.
    public static func renames(entries: [String: RecordingIndex.Entry], others: [String],
                               incoming: [String: RecordingIndex.Entry] = [:]) -> Plan {
        var taken: [String: String?] = [:]
        for (n, e) in entries where !numbered(n) { taken[n] = e.trackID }
        for o in others where !numbered(o) { taken[o] = .some(nil) }
        var renames: [Rename] = [], duplicates: [String] = []
        var named: [String: Set<String>] = [:]               // track → extensions that already got the plain name
        let all = entries.merging(incoming) { a, _ in a }
        for n in all.keys.sorted() where numbered(n) || incoming[n] != nil {
            let e = all[n]!
            let ext = (n as NSString).pathExtension
            let id = e.trackID ?? "?\(n)"
            // a second file of the same track must not take the first one's name
            let owner = named[id, default: []].contains(ext.lowercased()) ? "dup:\(n)" : id
            // the old name came from the sheet: drop its number; an unnumbered incoming file keeps its name; tags last
            let stem = ((n as NSString).lastPathComponent as NSString).deletingPathExtension
            let unnumbered = stem.replacingOccurrences(of: #"^\d+ - "#, with: "", options: .regularExpression)
            let base = FileNaming.sanitize(unnumbered).nonEmpty ?? RecordingNaming.base(title: e.title, artist: e.artist)
            let to = RecordingNaming.unique(base: base, trackID: owner, ext: ext, existing: taken)
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
