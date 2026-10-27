import Foundation

/// The Karaoké table's search and sort keys.
public enum SongList {
    /// Title, artist, id or Set List contains the query (case and accents ignored); an empty query keeps all.
    public static func filtered(_ songs: [SongState], query: String) -> [SongState] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return songs }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let fq = fold(q)
        return songs.filter { s in [s.id, s.titre, s.artiste, s.partie].contains { fold($0).contains(fq) } }
    }
}

extension SongState {
    /// Severity first: échec, à réessayer, à vérifier, ok, then not analysed.
    public static func rank(statut: String) -> Int {
        ["echec": 0, "a_reessayer": 1, "alerte": 2, "ok": 3][statut] ?? 4
    }
    public var statutRank: Int { Self.rank(statut: statut) }
    /// Steps done, for sorting the « Étapes » column by progress.
    public var stepsDone: Int { steps.filter { $0.status == "a_jour" }.count }

    public var isVerified: Bool { !(verifie ?? "").isEmpty }
    public var verifiedSort: Int { isVerified ? 1 : 0 }
    public var bpmRounded: Int? { bpm.map { Int($0.rounded()) } }
    public var bpmSort: Double { bpm ?? -1 }        // not analysed sorts first
    public var keyShort: String { KeyName.short(key) }
}

/// « C# minor » → « C#m », « Eb major » → « Eb », for the table.
public enum KeyName {
    public static func short(_ key: String?) -> String {
        guard let key else { return "" }
        guard let m = key.wholeMatch(of: /([A-G][#b]?)\s+(major|minor)/) else { return key }
        return String(m.1) + (m.2 == "minor" ? "m" : "")
    }
}
