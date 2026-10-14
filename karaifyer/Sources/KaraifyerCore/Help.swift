import Foundation

/// Hover explanations for the Karaoké table (French, Michel's language).
public enum Help {
    static let steps: [String: String] = [
        "ingest": "Préparation : lecture de l'enregistrement, silences du début et de la fin coupés",
        "separate": "Séparation : voix et instruments (RoFormer puis Demucs)",
        "beats": "Temps : détection des temps et des mesures (tempo, clic)",
        "vocals_split": "Voix : séparation chant principal / chœurs",
        "chords": "Accords : grille d'accords (détection, ou ta correction)",
        "package": "Pistes : fichiers pour la XR18, clic avec décompte, niveaux des faders",
        "lyrics": "Paroles : récupération (LRCLIB ou ton fichier) et calage sur la voix",
        "check": "Contrôle : calage des paroles et dérive du clic",
        "video": "Vidéo : vidéo des paroles avec accords",
        "set": "Set Ableton du morceau",
    ]
    static let statuses: [String: String] = [
        "a_jour": "à jour",
        "perime": "à refaire : un réglage ou une étape précédente a changé",
        "absent": "pas encore faite",
        "echec": "échec",
        "a_reessayer": "à réessayer (souvent LRCLIB injoignable) : relancer plus tard",
        "bloque": "bloquée : une étape précédente n'est pas faite",
    ]

    public static func step(_ s: StepState) -> String {
        var t = (steps[s.name] ?? s.name) + "\n" + "État : " + (statuses[s.status] ?? s.status)
        if s.status == "a_jour", let secs = s.seconds { t += String(format: " (%.0f s)", secs) }
        if let e = s.error, !e.isEmpty { t += "\n" + e }
        if s.warned, let a = s.alert { t += "\nÀ vérifier : " + a }
        return t
    }

    public static func statut(_ statut: String, alertes: [String]) -> String {
        let list = alertes.map { "• " + $0 }.joined(separator: "\n")
        switch statut {
        case "ok": return "Prêt pour le spectacle : aucune alerte."
        case "alerte": return "À vérifier :\n" + list
        case "echec": return "Échec :\n" + list + "\nClic droit → Voir le journal pour le détail."
        case "a_reessayer": return "À réessayer (service en ligne injoignable) :\n" + list
        default: return "Ce morceau n'a pas encore été analysé."
        }
    }
}
