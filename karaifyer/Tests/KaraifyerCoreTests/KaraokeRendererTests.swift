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
        // lit() reads bitmap rows from the top of the picture
        #expect(lit(ctx, CGRect(x: 600, y: 25, width: 720, height: 70)) > 50)        // neon title
        #expect(lit(ctx, CGRect(x: 140, y: 122, width: 1640, height: 130)) > 50)     // grid row 1
        #expect(lit(ctx, CGRect(x: 140, y: 520, width: 1640, height: 120)) > 50)     // current lyric line
    }

    @Test func oldLayoutAlsoDraws() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        r.draw(at: 6.2, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "paroles", transpose: -2)
        #expect(lit(ctx, CGRect(x: 140, y: 300, width: 1640, height: 300)) > 50)    // chords + current line
    }

    @Test func drawsFast() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        let t0 = Date()
        for k in 0..<60 { r.draw(at: 6 + Double(k) / 60, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "grille", transpose: 0) }
        #expect(Date().timeIntervalSince(t0) / 60 < 0.030)          // well under a 25 fps frame, even in debug
    }

    @Test func liveFramesAreFixedSizeAndCheap() {
        let r = KaraokeRenderer(scene: scene())
        let first = r.frame(at: 6, layout: "grille", transpose: 0)
        #expect(first.width == 1920 && first.height == 1080)          // the screen scales it (GPU), whatever its size
        let t0 = Date()
        for k in 0..<30 { _ = r.frame(at: 6 + Double(k) / 30, layout: "grille", transpose: 0) }
        #expect(Date().timeIntervalSince(t0) / 30 < 0.030)
    }

    @Test func chordsStayInsideTheirCell() {
        // a 1-beat bar holding a chord written on beat 2, and a long name: neither may reach the next cell
        var sc = scene()
        sc.bars[0] = VideoScene.Bar(start: 4, beats: 1, chords: [ChordAt(beat: 0, label: "Bbmaj7/Ab"), ChordAt(beat: 2, label: "C#m7b5")])
        sc.bars[1] = VideoScene.Bar(start: 6, beats: 4, chords: [])
        let r = KaraokeRenderer(scene: sc), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        r.draw(at: 4.2, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "grille", transpose: 0)
        let cellW = (1640 - 3 * 16) / 4.0
        // the second cell of row 1 (empty bar) must stay dark; lit() reads bitmap rows from the top (rows 116…258)
        #expect(lit(ctx, CGRect(x: 140 + cellW + 16 + 8, y: 122, width: cellW - 16, height: 130)) == 0)
        #expect(lit(ctx, CGRect(x: 148, y: 122, width: cellW - 16, height: 130)) > 50)    // the chords are in their own cell
    }
}
