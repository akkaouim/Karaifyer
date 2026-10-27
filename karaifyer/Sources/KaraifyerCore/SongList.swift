import Foundation

/// The Karaoké table's search and sort keys.
public enum SongList {
    /// SwiftUI tables only report header clicks as a new sort order: a click on « Retirer » (its stand-in sort key)
    /// folds or unfolds that column and keeps the previous sort.
    public static func headerClick(new: [KeyPathComparator<SongState>], previous: [KeyPathComparator<SongState>])
        -> (order: [KeyPathComparator<SongState>], toggleRetirer: Bool) {
        guard new.contains(where: { $0.keyPath == \SongState.retirerHeader }) else { return (new, false) }
        return (previous, true)
    }

    /// Title, artist, id or Set List contains the query (case and accents ignored); an empty query keeps all.
    public static func filtered(_ songs: [SongState], query: String) -> [SongState] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return songs }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let fq = fold(q)
        if fq == "corrige" { return songs.filter { $0.musicEdited || $0.lyricsEdited } }      // « corrigé »
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

    /// Not a sort: the « Retirer » header's click target (see SongList.headerClick).
    public var retirerHeader: Int { 0 }
    public var isVerified: Bool { !(verifie ?? "").isEmpty }
    public var verifiedSort: Int { isVerified ? 1 : 0 }
    public var bpmRounded: Int? { bpm.map { Int($0.rounded()) } }
    public var bpmSort: Double { bpm ?? -1 }        // not analysed sorts first
    public var keyShort: String { KeyName.short(key) }

    /// ♬: chords or bar fixes edited (both change the chords in the video); 🎤: lyrics edited.
    public var musicEdited: Bool { corrections?.accords != nil || corrections?.mesures != nil }
    public var lyricsEdited: Bool { corrections?.paroles != nil }
    public var correctionsSort: Int { (musicEdited ? 1 : 0) + (lyricsEdited ? 1 : 0) }
    public var correctionsHelp: String {
        let parts = [("Paroles", corrections?.paroles), ("accords", corrections?.accords), ("mesures", corrections?.mesures)]
            .compactMap { name, day in day.map { "\(name) corrigées le \($0)" } }
        guard !parts.isEmpty else { return "" }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Analysed before, but a step is out of date (saved corrections, a title edit, a setting): « Analyser » applies it.
    public var needsReanalysis: Bool {
        steps.contains { $0.status != "absent" } && steps.contains { $0.status == "perime" }
    }
    public var reanalysisSort: Int { needsReanalysis ? 1 : 0 }
}

/// « C# minor » → « C#m », « Eb major » → « Eb », for the table.
public enum KeyName {
    public static func short(_ key: String?) -> String {
        guard let key else { return "" }
        guard let m = key.wholeMatch(of: /([A-G][#b]?)\s+(major|minor)/) else { return key }
        return String(m.1) + (m.2 == "minor" ? "m" : "")
    }
}
