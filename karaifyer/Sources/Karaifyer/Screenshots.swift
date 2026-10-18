import AppKit
import KaraifyerCore
import SwiftUI
import WebKit

/// `Karaifyer --screenshots <dir>`: renders the app's own views (and the HTML report / iReal page) to
/// PNG for the user guide, from real data — no screen-recording permission needed. Then quits.
@MainActor enum Screenshots {
    static func run(dir: URL) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let k = KaraokeModel.shared
        await k.refresh()
        render(KaraokeView(model: k), CGSize(width: 1500, height: 860), dir, "01-karaoke.png")

        let journal = (try? String(contentsOfFile: k.pipeline.karaokeHome + "/travail/042/journal.log", encoding: .utf8)) ?? ""
        let all = journal.split(separator: "\n")
        let lastRun = all.lastIndex { $0.contains("début ingest") || $0.contains("début package") } ?? 0
        let lines = all[lastRun...].prefix(12).map { l -> String in
            let s = String(l)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return s }
            let time = s[s.index(s.startIndex, offsetBy: 12)..<close]     // HH:MM:SS from the ISO stamp
            return "\(time) [042] " + s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        k.stageRunForScreenshot(current: "043", step: "separate", queued: ["044", "045"],
                                done: [("042", "ok")], log: lines)
        render(KaraokeView(model: k), CGSize(width: 1500, height: 860), dir, "02-analyse-en-cours.png")

        if let e = k.editor(for: "042") {
            e.seek(input: 31.0)
            render(EditorView(model: e), CGSize(width: 1250, height: 760), dir, "03-editeur.png")
        }
        render(SettingsView(), CGSize(width: 700, height: 230), dir, "04-reglages.png")

        let q = QueueModel.shared
        if let csv = Bundle.main.url(forResource: "karaoke", withExtension: "csv") ?? fixtureCSV() { try? q.load(url: csv) }
        render(QueueView(model: q), CGSize(width: 1250, height: 700), dir, "05-enregistrement.png")

        await web(URL(fileURLWithPath: k.pipeline.karaokeHome + "/rapport.html"), CGSize(width: 1400, height: 900), dir, "06-rapport.png")
        let ireal = URL(fileURLWithPath: k.pipeline.karaokeHome + "/ireal/test.html")
        await web(ireal, CGSize(width: 700, height: 420), dir, "07-ireal.png")
        exit(0)
    }

    static func fixtureCSV() -> URL? {
        let u = URL(fileURLWithPath: Pipeline().projectDir).deletingLastPathComponent()
            .appendingPathComponent("karaifyer/Tests/KaraifyerCoreTests/Fixtures/karaoke.csv")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func window(_ size: CGSize, content: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = content
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))      // off every screen
        w.orderBack(nil)
        return w
    }

    static func render<V: View>(_ view: V, _ size: CGSize, _ dir: URL, _ name: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let w = window(size, content: host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // let tables and async tasks fill in
        save(host, dir.appendingPathComponent(name))
        w.orderOut(nil)
    }

    static func save(_ v: NSView, _ url: URL) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func web(_ url: URL, _ size: CGSize, _ dir: URL, _ name: String) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let wv = WKWebView(frame: NSRect(origin: .zero, size: size))
        let w = window(size, content: wv)
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        for _ in 0..<40 where wv.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let img = try? await wv.takeSnapshot(configuration: nil),
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
        w.orderOut(nil)
    }
}
