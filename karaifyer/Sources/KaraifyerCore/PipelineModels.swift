import Foundation

/// A chord change inside a bar; JSON form is the pipeline's `[beat, "label"]` pair.
public struct ChordAt: Codable, Equatable, Sendable {
    public var beat: Int
    public var label: String
    public init(beat: Int, label: String) { self.beat = beat; self.label = label }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        beat = try c.decode(Int.self)
        label = try c.decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(beat)
        try c.encode(label)
    }
}

public struct BarInfo: Codable, Equatable, Sendable {
    public var start: Double          // input time, seconds
    public var chords: [ChordAt]
    public init(start: Double, chords: [ChordAt]) { self.start = start; self.chords = chords }
}

public struct StepState: Codable, Equatable, Sendable {
    public var name: String
    public var status: String          // a_jour | perime | absent | echec | a_reessayer | bloque
    public var seconds: Double?
    public var error: String?
    public var alert: String?          // a report alert about this step's result (orange dot)

    public init(name: String, status: String, seconds: Double?, error: String?, alert: String? = nil) {
        self.name = name; self.status = status; self.seconds = seconds; self.error = error; self.alert = alert
    }
    /// Done, but its result raised an alert (a failure stays red).
    public var warned: Bool { status == "a_jour" && !(alert ?? "").isEmpty }
}

public struct SongPaths: Codable, Equatable, Sendable {
    public var dossier, video, set, accords, lrc, audio, lrcCorrige, accordsCorrige: String
    public var mesuresCorrige: String?   // mesures/<id>.json (bar-grid fix); absent in older etat output
}

/// The beat grid as the editor needs it (beats step result): beats and bar lines before Michel's fix.
public struct GridInfo: Codable, Equatable, Sendable {
    public var beats: [Double]
    public var downbeatsDetectees: [Double]
    public var beatsPerBarDetecte: Int
    public var bpm: Double
    public var signature: String?
    public var swing: Bool
}

/// One manifest row plus its pipeline state, as printed by `karaoke etat --json`.
public struct SongState: Codable, Equatable, Identifiable, Sendable {
    public var id, titre, artiste, album, fichier, langue, partie, statut: String
    public var alertes: [String]?         // why « alerte » / « echec » (rapport.json)
    public var retirer: [String]
    public var decompteMesures: Int
    public var steps: [StepState]
    public var paths: SongPaths
    public var padS: Double?
    public var bpm: Double?            // typical (median) tempo, for the player
    public var beatsPerBar: Int?
    public var key: String?
    public var bars: [BarInfo]
    public var grid: GridInfo?

    public static func decodeList(_ data: Data) throws -> [SongState] {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode([SongState].self, from: data)
    }
}

/// One line of `karaoke traiter --json`.
public enum PipelineEvent: Equatable, Sendable {
    case songStart(id: String)
    case stepStart(id: String, step: String)
    case stepEnd(id: String, step: String, status: String, seconds: Double, error: String)
    case songEnd(id: String, statut: String)
    case log(id: String, line: String)

    public static func parse(_ line: String) -> PipelineEvent? {
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ev = o["event"] as? String, let id = o["id"] as? String else { return nil }
        let s = { (k: String) in o[k] as? String ?? "" }
        switch ev {
        case "song_start": return .songStart(id: id)
        case "step_start": return .stepStart(id: id, step: s("step"))
        case "step_end": return .stepEnd(id: id, step: s("step"), status: s("status"),
                                         seconds: (o["seconds"] as? NSNumber)?.doubleValue ?? 0, error: s("error"))
        case "song_end": return .songEnd(id: id, statut: s("statut"))
        case "log": return .log(id: id, line: s("line"))
        default: return nil
        }
    }
}
