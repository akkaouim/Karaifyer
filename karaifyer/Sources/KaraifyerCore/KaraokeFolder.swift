import Foundation

/// Choosing the karaoke folder (manifeste.csv and everything the analysis writes next to it).
public enum KaraokeFolder {
    /// A folder without a manifest but with exactly one subfolder that has one (the drive picked instead of
    /// the karaoke folder inside it): that subfolder. Otherwise nil — the folder is used as chosen.
    public static func suggestion(for path: String, subfolders: [String], hasFile: (String) -> Bool) -> String? {
        let base = normalized(path)
        if hasFile(base + "/manifeste.csv") { return nil }
        let candidates = subfolders.map { base + "/" + $0 }.filter { hasFile($0 + "/manifeste.csv") }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Most recent first, each folder once, at most `limit`.
    public static func recents(_ list: [String], adding path: String, limit: Int = 5) -> [String] {
        let p = normalized(path)
        return Array(([p] + list.map(normalized).filter { $0 != p }).prefix(limit))
    }

    /// The last two path components, for the Karaoké tab's toolbar.
    public static func displayName(_ path: String) -> String {
        normalized(path).split(separator: "/").suffix(2).joined(separator: " › ")
    }

    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
