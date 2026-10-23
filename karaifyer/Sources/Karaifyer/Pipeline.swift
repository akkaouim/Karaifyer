import Foundation
import KaraifyerCore

/// Settings + how to call the karaoke command line (uv run --project <karaoke> karaoke …).
struct Pipeline {
    var karaokeHome: String {
        KaraokePaths.home(saved: UserDefaults.standard.string(forKey: "karaokeHome"),
                          legacyExists: FileManager.default.fileExists(atPath: KaraokePaths.legacyHome),
                          userHome: NSHomeDirectory())
    }
    var gabarit: String {
        UserDefaults.standard.string(forKey: "gabarit") ?? karaokeHome + "/gabarit/gabarit Project/gabarit.als"
    }
    var projectDir: String {
        KaraokePaths.pipelineFolder(
            KaraokePaths.project(saved: UserDefaults.standard.string(forKey: "projectDir"),
                                 bundled: Bundle.main.object(forInfoDictionaryKey: "KaraokeProjectDir") as? String,
                                 userHome: NSHomeDirectory()),
            hasPyproject: { FileManager.default.fileExists(atPath: $0 + "/pyproject.toml") })
    }
    /// GUI apps don't get the shell PATH; ffmpeg and uv live in Homebrew's bin.
    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"]
    var uvPath: String? {
        Self.searchPath.map { $0 + "/uv" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = Self.searchPath.joined(separator: ":")
        e["KARAOKE_HOME"] = karaokeHome
        e["KARAOKE_GABARIT"] = gabarit
        e["KARAOKE_ACCORDS"] = ChordEngine.from(saved: UserDefaults.standard.string(forKey: "chordEngine")).rawValue
        e["PYTHONUNBUFFERED"] = "1"          // events must arrive line by line, not in 8 KB blocks
        e.removeValue(forKey: "VIRTUAL_ENV")
        return e
    }

    /// Blocking problems, in French, for the banner (empty = ready).
    func problems() -> [String] {
        var p: [String] = []
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: karaokeHome, isDirectory: &isDir) || !isDir.boolValue {
            p.append("Pas encore de dossier karaoké (\(karaokeHome))")
        }
        if uvPath == nil { p.append("uv introuvable : l'installer avec « brew install uv »") }
        if !Self.searchPath.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") }) {
            p.append("ffmpeg introuvable : l'installer avec « brew install ffmpeg »")
        }
        if !FileManager.default.fileExists(atPath: projectDir + "/pyproject.toml") {
            p.append("Projet karaoke introuvable : \(projectDir). Dans Réglages, choisir le dossier « karaoke » du dépôt Karaifyer (ou « Défaut »)")
        }
        return p
    }

    var homeExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: karaokeHome, isDirectory: &isDir) && isDir.boolValue
    }

    var manifestExists: Bool { FileManager.default.fileExists(atPath: karaokeHome + "/manifeste.csv") }

    func args(_ sub: [String]) -> [String] { [uvPath ?? "uv", "run", "--project", projectDir, "karaoke"] + sub }

    func traiterArgs(_ job: Job) -> [String] {
        args(["traiter", "--ids", job.id, "--json"] + (job.forced.map { ["--forcer", $0] } ?? []))
    }

    /// Short commands (etat, modifier, ajouter, manifeste): run to completion off the main thread.
    func run(_ sub: [String]) async -> (code: Int32, out: String, err: String) {
        let a = args(sub), e = env, cwd = projectDir
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: a[0])
                p.arguments = Array(a.dropFirst())
                p.environment = e
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let o = Pipe(), er = Pipe()
                p.standardOutput = o
                p.standardError = er
                do { try p.run() } catch { cont.resume(returning: (-1, "", "\(error)")); return }
                // Read stderr concurrently so a chatty command can't fill its pipe and block.
                var ed = Data()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async { ed = er.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                let od = o.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: od, as: UTF8.self),
                                        String(decoding: ed, as: UTF8.self)))
            }
        }
    }
}
