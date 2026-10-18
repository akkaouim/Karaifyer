import Foundation

/// Where the karaoke folder and the pipeline code are, without depending on Michel's own setup.
public enum KaraokePaths {
    public static let legacyHome = "/Volumes/Hypermnesia/karaoke"   // Michel's first setup, kept when present

    /// Settings choice, else Michel's legacy folder if it exists, else ~/Karaoke (created on first launch).
    public static func home(saved: String?, legacyExists: Bool, userHome: String) -> String {
        if let saved, !saved.isEmpty { return saved }
        return legacyExists ? legacyHome : userHome + "/Karaoke"
    }

    /// Settings choice, else the repo the app was built from (written into Info.plist by build-app.sh).
    public static func project(saved: String?, bundled: String?, userHome: String) -> String {
        if let saved, !saved.isEmpty { return saved }
        if let bundled, !bundled.isEmpty { return bundled }
        return userHome + "/Documents/mp3-pipeline/karaoke"
    }
}
