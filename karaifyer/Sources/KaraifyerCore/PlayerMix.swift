import Foundation

/// The player's 8 tracks, in mixer order, with their files and their `retirer` stem.
public enum PlayerTrack: String, CaseIterable, Codable, Sendable {
    case clic, guideVoix, guitare, basse, piano, batterie, accompagnement, backVocals

    public var file: String {
        switch self {
        case .guideVoix: "guide_voix.flac"
        case .backVocals: "back_vocals.flac"
        default: rawValue + ".flac"
        }
    }

    public var label: String {
        switch self {
        case .clic: "Clic"
        case .guideVoix: "Guide voix"
        case .guitare: "Guitare"
        case .basse: "Basse"
        case .piano: "Piano"
        case .batterie: "Batterie"
        case .accompagnement: "Accompagnement"
        case .backVocals: "Back Vocals"
        }
    }

    public var retirerStem: String? {
        switch self {
        case .guitare: "guitar"
        case .basse: "bass"
        case .piano: "piano"
        case .batterie: "drums"
        case .accompagnement: "other"
        default: nil
        }
    }
}

/// Fader travel 0…1: 0 = −∞, then −60…+6 dB linear in dB (0 dB at 60/66 ≈ 0.91, like a desk).
public enum Fader {
    static let minDB = -60.0, maxDB = 6.0
    public static let unity = -minDB / (maxDB - minDB)

    public static func db(_ position: Double) -> Double? {
        position <= 0 ? nil : minDB + (maxDB - minDB) * min(1, position)
    }

    public static func position(db: Double?) -> Double {
        guard let db else { return 0 }
        return max(0, min(1, (db - minDB) / (maxDB - minDB)))
    }

    public static func gain(_ position: Double) -> Float {
        guard let d = db(position) else { return 0 }
        return Float(pow(10, d / 20))
    }

    public static func label(_ position: Double) -> String {
        guard let d = db(position) else { return "−∞" }
        let r = Int(d.rounded())
        return r == 0 ? "0 dB" : (r > 0 ? "+\(r) dB" : "−\(-r) dB")
    }
}

/// One song's player state, saved per song (UserDefaults key `playerMix.<id>`).
public struct PlayerSettings: Codable, Equatable, Sendable {
    public var faders: [PlayerTrack: Double]
    public var mutes: Set<PlayerTrack>
    public var solos: Set<PlayerTrack>
    public var master: Double
    public var targetBPM: Double?
    public var semitones: Int
    public var loopStart: Double?
    public var loopEnd: Double?

    /// Like the show: parts played live (`retirer`) at zero, everything else at 0 dB.
    public static func defaults(retirer: [String]) -> PlayerSettings {
        var f: [PlayerTrack: Double] = [:]
        for t in PlayerTrack.allCases {
            f[t] = t.retirerStem.map { retirer.contains($0) } == true ? 0 : Fader.unity
        }
        return PlayerSettings(faders: f, mutes: [], solos: [], master: Fader.unity, targetBPM: nil, semitones: 0,
                              loopStart: nil, loopEnd: nil)
    }

    /// Mute wins; with any solo, only soloed (unmuted) tracks sound.
    public func effectiveGains() -> [PlayerTrack: Float] {
        var g: [PlayerTrack: Float] = [:]
        for t in PlayerTrack.allCases {
            let silent = mutes.contains(t) || (!solos.isEmpty && !solos.contains(t))
            g[t] = silent ? 0 : Fader.gain(faders[t] ?? Fader.unity)
        }
        return g
    }

    public var masterGain: Float { Fader.gain(master) }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// A missing or unreadable saved entry falls back to the show defaults.
    public static func decode(_ data: Data?, retirer: [String]) -> PlayerSettings {
        guard let data, let s = try? JSONDecoder().decode(PlayerSettings.self, from: data) else {
            return defaults(retirer: retirer)
        }
        return s
    }
}

public enum PlayerLibrary {
    /// Files missing for the song to be playable ([] = ready): the 8 tracks, then the video.
    public static func missingFiles(in folder: String, exists: (String) -> Bool) -> [String] {
        (PlayerTrack.allCases.map(\.file) + ["paroles.mp4"]).filter { !exists(folder + "/" + $0) }
    }

    /// Case- and accent-insensitive search on id, title and artist.
    public static func matches(_ query: String, id: String, titre: String, artiste: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return [id, titre, artiste].contains { fold($0).contains(fold(q)) }
    }
}
