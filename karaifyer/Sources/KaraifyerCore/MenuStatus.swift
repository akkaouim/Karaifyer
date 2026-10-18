import Foundation

/// The menu-bar menu's two status lines. Always two, and nothing that ticks while the menu is open:
/// a line rewritten every second made macOS 26 leave its highlight bar at a stale position.
public enum MenuStatus {
    public static func lines(row: String?, title: String?, durationS: Double, banner: String?,
                             done: Int, total: Int, failed: Int) -> [String] {
        let first: String
        if let row {
            let t = max(0, Int(durationS))
            first = "Ligne \(row) · \(title ?? "")" + (t > 0 ? String(format: " (%d:%02d)", t / 60, t % 60) : "")
        } else {
            first = banner ?? "Aucun enregistrement en cours"
        }
        return [first, "\(done)/\(total) faites" + (failed > 0 ? " · \(failed) échec\(failed > 1 ? "s" : "")" : "")]
    }
}
