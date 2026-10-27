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
        // per track and extension: a FLAC brought in before an interruption doesn't strand its MP3
        func key(_ name: String, _ e: RecordingIndex.Entry) -> String? {
            e.trackID.map { "\($0).\((name as NSString).pathExtension.lowercased())" }
        }
        var have = Set(main.compactMap { key($0.key, $0.value) })
        var out: [String: RecordingIndex.Entry] = [:]
        for sub in subfolders.keys.sorted() {
            var brought = Set<String>()
            for (name, e) in subfolders[sub]!.sorted(by: { $0.key < $1.key }) {
                guard let k = key(name, e), !have.contains(k), !brought.contains(k) else { continue }
                out["\(sub)/\(name)"] = e
                brought.insert(k)
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
        for (n, e) in entries where !numbered(n) {              // renamed before an interruption: they keep it
            if let id = e.trackID { named[id, default: []].insert((n as NSString).pathExtension.lowercased()) }
        }
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
    public struct CopyError: LocalizedError {
        public let errorDescription: String?
    }

    /// A copy to another disk: same size, and the source's modification date to the nanosecond (the analysis keys on
    /// it). A failed copy leaves nothing at the destination.
    public static func copy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        do {
            try fm.copyItem(at: src, to: dst)
            var a = stat(), b = stat()
            guard stat(src.path, &a) == 0, stat(dst.path, &b) == 0, a.st_size == b.st_size else {
                throw CopyError(errorDescription: "copie incomplète : \(src.lastPathComponent)")
            }
            if a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec || a.st_mtimespec.tv_nsec != b.st_mtimespec.tv_nsec {
                var times = [a.st_atimespec, a.st_mtimespec]
                guard utimensat(AT_FDCWD, dst.path, &times, 0) == 0 else {
                    throw CopyError(errorDescription: "date non conservée : \(src.lastPathComponent)")
                }
            }
        } catch {
            try? fm.removeItem(at: dst)
            throw error
        }
    }

    /// Files whose name is free at the destination; the others are skipped, never overwritten.
    public static func plan(files: [String], destinationNames: Set<String>) -> (move: [String], skipped: [String]) {
        (files.filter { !destinationNames.contains($0) }, files.filter { destinationNames.contains($0) })
    }
}
