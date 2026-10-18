import Foundation

/// Where the karaoke folder and the pipeline code are, without depending on Michel's own setup.
public enum KaraokePaths {
    /// The saved beat detection (and the audio fingerprint it was made from): deleting them makes the next
    /// `beats` run detect again instead of reusing it.
    public static func beatDetection(home: String, id: String) -> [String] {
        ["\(home)/travail/\(id)/beats.json", "\(home)/travail/\(id)/beats.source.json"]
    }

    public static let legacyHome = "/Volumes/Hypermnesia/karaoke"   // Michel's first setup, kept when present

    /// Settings choice, else Michel's legacy folder if it exists, else ~/Karaoke (created on first launch).
    public static func home(saved: String?, legacyExists: Bool, userHome: String) -> String {
        if let saved, !saved.isEmpty { return saved }
        return legacyExists ? legacyHome : userHome + "/Karaoke"
    }

    /// The pipeline is the folder holding pyproject.toml; picking the repo folder (one level up) works too.
    public static func pipelineFolder(_ path: String, hasPyproject: (String) -> Bool) -> String {
        if hasPyproject(path) { return path }
        let inner = (path as NSString).appendingPathComponent("karaoke")
        return hasPyproject(inner) ? inner : path
    }

    /// Settings choice, else the repo the app was built from (written into Info.plist by build-app.sh).
    public static func project(saved: String?, bundled: String?, userHome: String) -> String {
        if let saved, !saved.isEmpty { return saved }
        if let bundled, !bundled.isEmpty { return bundled }
        return userHome + "/Documents/mp3-pipeline/karaoke"
    }
}
