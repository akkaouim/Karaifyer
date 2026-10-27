import AppKit
import KaraifyerCore

extension Notification.Name {
    /// The karaoke folder changed: Corriger windows belong to the old one and close.
    static let karaokeHomeChanged = Notification.Name("karaokeHomeChanged")
}

/// Changing the karaoke folder, from the Karaoké tab or Settings: refused during an analysis or with unsaved
/// corrections; a parent folder of a karaoke folder is caught; the Lecteur and Corriger windows let go of the old one.
@MainActor enum KaraokeHome {
    static var recents: [String] { UserDefaults.standard.stringArray(forKey: "karaokeRecents") ?? [] }

    static func choose() {
        guard canSwitch() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Utiliser ce dossier"
        panel.message = "Dossier karaoké : celui qui contient manifeste.csv (ou un dossier vide pour en commencer un)."
        panel.directoryURL = URL(fileURLWithPath: Pipeline().karaokeHome).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var path = url.path
        let fm = FileManager.default
        let subs = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        if let s = KaraokeFolder.suggestion(for: path, subfolders: subs, hasFile: { fm.fileExists(atPath: $0) }) {
            let a = NSAlert()
            a.messageText = "Utiliser « \(KaraokeFolder.displayName(s)) » ?"
            a.informativeText = "Ce dossier n'a pas de manifeste, mais « \((s as NSString).lastPathComponent) » à l'intérieur en a un.\n\n\(s)"
            a.addButton(withTitle: "Utiliser « \((s as NSString).lastPathComponent) »")
            a.addButton(withTitle: "Garder le dossier choisi")
            a.addButton(withTitle: "Annuler")
            switch a.runModal() {
            case .alertFirstButtonReturn: path = s
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        switchTo(path)
    }

    /// nil: back to the default folder.
    static func switchTo(_ path: String?) {
        guard canSwitch() else { return }
        let k = KaraokeModel.shared
        remember(Pipeline().karaokeHome)          // the folder left stays one click away in « Récents »
        NotificationCenter.default.post(name: .karaokeHomeChanged, object: nil)
        k.closeAllEditors()
        PlayerModel.shared.forgetAll()
        k.selection = []
        if let path { UserDefaults.standard.set(path, forKey: "karaokeHome") }
        else { UserDefaults.standard.removeObject(forKey: "karaokeHome") }
        remember(Pipeline().karaokeHome)
        k.appendLog("Dossier karaoké : \(Pipeline().karaokeHome)")
        SettingsStore.shared.revision += 1
        Task { await k.refresh() }
    }

    static func remember(_ path: String) {
        UserDefaults.standard.set(KaraokeFolder.recents(recents, adding: path), forKey: "karaokeRecents")
    }

    private static func canSwitch() -> Bool {
        let k = KaraokeModel.shared
        let reason = k.locked ? "Une analyse est en cours : l'arrêter d'abord."
            : k.hasUnsavedEditor ? "Une fenêtre Corriger a des modifications non enregistrées : les enregistrer ou les annuler d'abord."
            : nil
        if let reason { KaraokeUI.shared.alert = "Impossible de changer de dossier karaoké. \(reason)" }
        return reason == nil
    }
}
