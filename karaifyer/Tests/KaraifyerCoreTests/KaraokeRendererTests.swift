import CoreGraphics
import Foundation
import Testing
@testable import KaraifyerCore

struct KaraokeRendererTests {
    func scene() -> VideoScene {
        let bars = (0..<8).map { VideoScene.Bar(start: 4 + Double($0) * 2, beats: 4, chords: [ChordAt(beat: 0, label: "Am"), ChordAt(beat: 2, label: "F")]) }
        return VideoScene(version: 1, layout: "grille", titre: "Tout le bonheur du monde", artiste: "Sinsémilia", key: "C major",
                          padS: 4, totalS: 20, beats: (0..<40).map { Double($0) * 0.5 }, bars: bars,
                          states: [VideoScene.State(start: 0, end: 20, kind: "ligne", current: "On vous souhaite tout le bonheur du monde",
                                                    next: "Et que quelqu'un vous tende la main", countdown: nil, lit: 12,
                                                    chords: [ChordAt(beat: 0, label: "Am")], chart: [], chartPos: nil, nextChords: [])])
    }

    func lit(_ ctx: CGContext, _ rect: CGRect) -> Int {          // pixels clearly brighter than the background
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self), w = ctx.width
        var n = 0
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 4) {
            let p = (y * w + x) * 4; if Int(data[p]) + Int(data[p + 1]) + Int(data[p + 2]) > 300 { n += 1 } } }
        return n
    }

    @Test func drawsTitleGridAndLyrics() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        r.draw(at: 6.2, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "grille", transpose: 0)
        // CG origin is bottom-left: top band = high y
        #expect(lit(ctx, CGRect(x: 600, y: 1000, width: 720, height: 70)) > 50)      // neon title
        #expect(lit(ctx, CGRect(x: 140, y: 750, width: 1640, height: 160)) > 50)     // grid row 1
        #expect(lit(ctx, CGRect(x: 140, y: 330, width: 1640, height: 140)) > 50)     // current lyric line
    }

    @Test func oldLayoutAlsoDraws() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        r.draw(at: 6.2, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "paroles", transpose: -2)
        #expect(lit(ctx, CGRect(x: 140, y: 450, width: 1640, height: 300)) > 50)
    }

    @Test func drawsFast() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        let t0 = Date()
        for k in 0..<60 { r.draw(at: 6 + Double(k) / 60, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "grille", transpose: 0) }
        #expect(Date().timeIntervalSince(t0) / 60 < 0.030)          // well under a 25 fps frame, even in debug
    }
}
