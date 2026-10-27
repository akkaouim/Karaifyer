import Foundation

/// One song of `karaoke retirer --plan --json`: what removing it from the manifest would send to the Trash.
public struct RemovalItem: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public var fichiers: [String]
        public var taille: Int64
    }

    public struct Audio: Codable, Equatable, Sendable {
        public var fichiers: [String]
        public var taille: Int64
        public var fichier: String
        public var partage: Bool          // another manifest row uses the same recording: never offered
    }

    public var id, titre, artiste: String
    public var analyse, corrections: Group
    public var audio: Audio

    public static func decodeList(_ data: Data) throws -> [RemovalItem] {
        try JSONDecoder().decode([RemovalItem].self, from: data)
    }

    public static func total(_ items: [RemovalItem], _ group: KeyPath<RemovalItem, Group>) -> Int64 {
        items.reduce(0) { $0 + $1[keyPath: group].taille }
    }

    /// Recordings that would really go: shared ones are always kept.
    public static func audioTotal(_ items: [RemovalItem]) -> Int64 {
        items.filter { !$0.audio.partage }.reduce(0) { $0 + $1.audio.taille }
    }

    public static func audioOffered(_ items: [RemovalItem]) -> Bool {
        items.contains { !$0.audio.partage && !$0.audio.fichiers.isEmpty }
    }
}

/// What Michel ticked in the confirmation sheet, as the pipeline command.
public struct RemovalChoice: Equatable, Sendable {
    public var ids: [String]
    public var analyse, corrections, audio: Bool

    public init(ids: [String], analyse: Bool, corrections: Bool, audio: Bool) {
        self.ids = ids
        self.analyse = analyse
        self.corrections = corrections
        self.audio = audio
    }

    public var arguments: [String] {
        ["retirer", "--ids", ids.joined(separator: ",")] + (analyse ? ["--analyse"] : [])
            + (corrections ? ["--corrections"] : []) + (audio ? ["--audio"] : []) + ["--json"]
    }

    /// The app's per-song settings, forgotten with the song (a later song could reuse the id).
    public static func defaultsKeys(id: String) -> [String] {
        ["playerMix.\(id)", "chordSuggestionIgnored.\(id)"]
    }
}
