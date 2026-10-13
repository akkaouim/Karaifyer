import Foundation

/// The manifest's `retirer` cell after ticking/unticking one stem, from the CURRENT value
/// (not a stale row snapshot), in the table's column order.
public enum Retirer {
    public static func toggled(_ current: [String], _ stem: String, on: Bool, order: [String]) -> String {
        var set = Set(current)
        if on { set.insert(stem) } else { set.remove(stem) }
        return order.filter(set.contains).joined(separator: ";")
    }
}
