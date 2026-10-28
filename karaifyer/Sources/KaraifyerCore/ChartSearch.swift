import Foundation

/// Chord-chart searches in the browser, one site at a time: Michel picks the version he trusts.
public enum ChartSearch: CaseIterable, Sendable {
    case ultimateGuitar, boiteAChansons

    public var label: String {
        switch self {
        case .ultimateGuitar: "Ultimate Guitar"
        case .boiteAChansons: "La Boîte à chansons"
        }
    }

    public func url(titre: String, artiste: String) -> URL? {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let q = "\(titre) \(artiste)".addingPercentEncoding(withAllowedCharacters: safe) ?? ""
        switch self {
        case .ultimateGuitar: return URL(string: "https://www.ultimate-guitar.com/search.php?search_type=title&value=\(q)")
        case .boiteAChansons: return URL(string: "https://www.boiteachansons.net/recherche?q=\(q)")
        }
    }
}
