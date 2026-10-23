import Foundation

/// The chord detector the analysis uses (karaoke/steps/chords.py ENGINES), passed as KARAOKE_ACCORDS.
public enum ChordEngine: String, CaseIterable, Sendable {
    case jiang, btc, ace, madmom
    public var label: String {
        switch self {
        case .jiang: "Jiang 2019 (recommandé)"
        case .btc: "BTC"
        case .ace: "consonance-ACE"
        case .madmom: "madmom (ancien)"
        }
    }
    public static func from(saved: String?) -> ChordEngine { saved.flatMap(ChordEngine.init(rawValue:)) ?? .jiang }
}
