import CoreGraphics
import CoreText
import Foundation

/// Draws the lyrics video at a show time: neon background (brick wall, cyan frame pulsing on the beat, title in pink
/// neon breathing), then « Grille + paroles » (2 rows of 4 bars, active row on top, beat cursor; lyrics only below)
/// or « Accords sur les paroles » (the former video: chords above the syllables, 4-bar row in instrumentals).
/// Everything is a function of `t`, so the Lecteur, the export and `karaifyer-render` draw the same frames.
public final class KaraokeRenderer {
    public static let W: CGFloat = 1920, H: CGFloat = 1080
    let scene: VideoScene
    let downbeats: Set<Int>
    private var fonts: [String: CTFont] = [:]
    private var lines: [String: CTLine] = [:]
    private var wraps: [String: [[Int]]] = [:]
    private var bricks: CGImage?
    private var frameImage: CGImage?
    private var titleImage: CGImage?
    /// The glow images are mostly transparent: only these strips (in 1920×1080 coordinates) are composited per frame.
    private var frameStrips: [(CGImage, CGRect)] = []
    private var titleStrip: (CGImage, CGRect)?
    private var titleWidth: CGFloat = 0

    // Colours (Global Constraints of the plan)
    static let cyan = CGColor(red: 0.243, green: 0.902, blue: 1, alpha: 1)
    static let pink = CGColor(red: 1, green: 0.310, blue: 0.847, alpha: 1)
    static let yellow = CGColor(red: 1, green: 0.839, blue: 0, alpha: 1)
    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let grey = CGColor(red: 0.588, green: 0.588, blue: 0.588, alpha: 1)
    static let chordBlue = CGColor(red: 0.471, green: 0.784, blue: 1, alpha: 1)
    static let previewBlue = CGColor(red: 0.353, green: 0.549, blue: 0.745, alpha: 1)
    static let red = CGColor(red: 1, green: 0.314, blue: 0.314, alpha: 1)

    public init(scene: VideoScene) {
        self.scene = scene
        downbeats = scene.downbeatIndices
    }

    public static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    // MARK: drawing

    private var offscreen: CGContext?

    /// A live frame at the video's own size (1920×1080), drawn into a reused context; the screen scales it (layer
    /// contents, on the GPU), so a Retina or 4K full screen costs the same as 1080p.
    public func frame(at t: Double, layout: String, transpose: Int) -> CGImage {
        if offscreen == nil { offscreen = Self.bitmap(width: Int(Self.W), height: Int(Self.H)) }
        let ctx = offscreen!
        draw(at: t, in: ctx, size: CGSize(width: Self.W, height: Self.H), layout: layout, transpose: transpose)
        return ctx.makeImage()!
    }

    public func draw(at t: Double, in ctx: CGContext, size: CGSize, layout: String, transpose: Int) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // A top-left, 1920×1080 coordinate space whatever the target size.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / Self.W, y: -size.height / Self.H)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        background(ctx, t: t)
        let flats = ChordText.prefersFlats(key: scene.key, shift: transpose)
        let state = VideoClock.state(scene, at: t)
        if layout == "paroles" {
            chordsOverLyrics(ctx, state: state, transpose: transpose, flats: flats)
        } else {
            grid(ctx, t: t, transpose: transpose, flats: flats)
            lyrics(ctx, state: state)
        }
    }

    private func background(_ ctx: CGContext, t: Double) {
        let full = CGRect(x: 0, y: 0, width: Self.W, height: Self.H)
        ctx.setFillColor(CGColor(red: 0.043, green: 0.043, blue: 0.078, alpha: 1))
        ctx.fill(full)
        if bricks == nil { bricks = makeBricks() }
        if frameImage == nil { makeNeon() }
        drawImage(ctx, bricks!, alpha: 1)
        let glow = VideoClock.frameGlow(t: t, beats: scene.beats, downbeats: downbeats)
        for (img, r) in frameStrips { drawImage(ctx, img, in: r, alpha: glow) }
        if let (img, r) = titleStrip { drawImage(ctx, img, in: r, alpha: VideoClock.titleBrightness(t: t)) }
    }

    /// Strips of a full-frame image, cut once (top-left rects; CGImage cropping counts from the top too).
    private func strips(_ img: CGImage, _ rects: [CGRect]) -> [(CGImage, CGRect)] {
        rects.compactMap { r in img.cropping(to: r).map { ($0, r) } }
    }

    private func drawImage(_ ctx: CGContext, _ img: CGImage, in r: CGRect, alpha: Double) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// Images are drawn in the flipped space: flip them back so they keep their orientation.
    private func drawImage(_ ctx: CGContext, _ img: CGImage, alpha: Double) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: 0, y: Self.H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: Self.W, height: Self.H))
        ctx.restoreGState()
    }

    /// Draws into a 1920×1080 image using the same top-left coordinates as the frames.
    private func image(_ body: (CGContext) -> Void) -> CGImage {
        let c = Self.bitmap(width: Int(Self.W), height: Int(Self.H))
        c.translateBy(x: 0, y: Self.H)
        c.scaleBy(x: 1, y: -1)
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        body(c)
        return c.makeImage()!
    }

    private func makeBricks() -> CGImage {
        image { c in
            var seed: UInt64 = 0x5EED
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            let rowH: CGFloat = 46, brickW: CGFloat = 120, mortar: CGFloat = 3
            c.setFillColor(CGColor(red: 0.063, green: 0.063, blue: 0.094, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: Self.W, height: Self.H))
            var y: CGFloat = 0, row = 0
            while y < Self.H {
                var x: CGFloat = row % 2 == 0 ? 0 : -brickW / 2
                while x < Self.W {
                    let v = 0.106 + 0.03 * rnd()
                    c.setFillColor(CGColor(red: v, green: v, blue: v + 0.045, alpha: 1))
                    c.fill(CGRect(x: x + mortar, y: y + mortar, width: brickW - mortar, height: rowH - mortar))
                    x += brickW
                }
                y += rowH
                row += 1
            }
        }
    }

    private var titleText: String { scene.artiste.isEmpty ? scene.titre : "\(scene.titre) — \(scene.artiste)" }

    private func titleFontSize() -> CGFloat {
        var size: CGFloat = 64
        while size > 36 && width(of: titleText, font("Arial-BoldMT", size)) > 1500 { size -= 4 }
        return size
    }

    private func makeNeon() {
        let size = titleFontSize()
        let f = font("Arial-BoldMT", size)
        titleWidth = width(of: titleText, f)
        let gapL = Self.W / 2 - titleWidth / 2 - 30, gapR = Self.W / 2 + titleWidth / 2 + 30
        frameImage = image { c in
            let r = CGRect(x: 60, y: 60, width: Self.W - 120, height: Self.H - 120), rad: CGFloat = 18
            let p = CGMutablePath()
            p.move(to: CGPoint(x: gapR, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: rad)
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: rad)
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: rad)
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: gapL, y: r.minY), radius: rad)
            p.addLine(to: CGPoint(x: gapL, y: r.minY))
            c.setLineCap(.round)
            for (w, blur, a) in [(CGFloat(14), CGFloat(40), 0.35), (8, 18, 0.7), (4, 0, 1.0)] {
                c.saveGState()
                c.setShadow(offset: .zero, blur: blur, color: Self.cyan)
                c.setStrokeColor(Self.cyan.copy(alpha: a)!)
                c.setLineWidth(w)
                c.addPath(p)
                c.strokePath()
                c.restoreGState()
            }
        }
        defer {
            let band: CGFloat = 130            // the frame line + its glow: 60 ± ~65 px
            frameStrips = strips(frameImage!, [CGRect(x: 0, y: 0, width: Self.W, height: band),
                                               CGRect(x: 0, y: Self.H - band, width: Self.W, height: band),
                                               CGRect(x: 0, y: band, width: band, height: Self.H - 2 * band),
                                               CGRect(x: Self.W - band, y: band, width: band, height: Self.H - 2 * band)])
            titleStrip = strips(titleImage!, [CGRect(x: 0, y: 0, width: Self.W, height: 150)]).first
        }
        titleImage = image { c in
            let baseline: CGFloat = 60 + size * 0.36
            for (blur, color) in [(CGFloat(30), Self.pink), (12, Self.pink), (0, CGColor(red: 1, green: 0.85, blue: 0.97, alpha: 1))] {
                c.saveGState()
                c.setShadow(offset: .zero, blur: blur, color: Self.pink)
                drawText(c, titleText, f, color, x: Self.W / 2 - titleWidth / 2, baseline: baseline)
                c.restoreGState()
            }
        }
    }

    // MARK: « Grille + paroles »

    static let gridX: CGFloat = 140, gridW: CGFloat = 1640, gap: CGFloat = 16
    // the grid takes the top third of the frame (60…1020), the lyrics the rest
    static let rowsY: [(CGFloat, CGFloat)] = [(116, 258), (270, 412)]

    private func grid(_ ctx: CGContext, t: Double, transpose: Int, flats: Bool) {
        guard let g = VideoClock.grid(scene, at: t) else {
            let f = font("ArialUnicodeMS", 160)
            drawCentered(ctx, "♪", f, Self.grey, baseline: 320)
            return
        }
        let cellW = (Self.gridW - 3 * Self.gap) / 4
        for (r, row) in g.rows.enumerated() where r < 2 {
            let (y0, y1) = Self.rowsY[r]
            for (k, b) in row.enumerated() {
                let cell = CGRect(x: Self.gridX + CGFloat(k) * (cellW + Self.gap), y: y0, width: cellW, height: y1 - y0)
                let current = r == 0 && b == g.activeBar
                ctx.setFillColor(current ? Self.yellow.copy(alpha: 0.18)! : Self.white.copy(alpha: r == 0 ? 0.08 : 0.05)!)
                ctx.addPath(CGPath(roundedRect: cell, cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.fillPath()
                let bar = scene.bars[b]
                let beats = max(bar.beats, 1), inner = cellW - 48
                // a chord written past the bar's last beat sits on its last beat; long names shrink to fit the cell
                let labels = bar.chords.map { (min(max($0.beat, 0), beats - 1), ChordText.transpose($0.label, by: transpose, flats: flats)) }
                var size: CGFloat = 52
                while size > 28 && labels.reduce(CGFloat(0), { $0 + width(of: $1.1 + " ", font("Arial-BoldMT", size)) }) > inner { size -= 4 }
                let chordFont = font("Arial-BoldMT", size)
                ctx.saveGState()
                ctx.clip(to: cell)
                var right = -CGFloat.infinity
                for (beat, label) in labels {
                    let w = width(of: label, chordFont)
                    var x = max(cell.minX + 24 + CGFloat(beat) / CGFloat(beats) * inner, right)
                    x = max(min(x, cell.maxX - 16 - w), right)
                    let color = r == 0 ? Self.white : Self.grey.copy(alpha: 0.55)!
                    drawText(ctx, label, chordFont, color, x: x, baseline: y0 + 88)
                    right = x + w + width(of: " ", chordFont)
                }
                ctx.restoreGState()
                if current, let beat = g.activeBeat {
                    let x = cell.minX + 24 + CGFloat(min(beat, beats - 1)) / CGFloat(beats) * inner
                    ctx.setFillColor(Self.yellow)
                    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y1 - 22, width: 40, height: 8), cornerWidth: 4, cornerHeight: 4, transform: nil))
                    ctx.fillPath()
                }
            }
        }
        if g.activeBar == nil, let first = scene.bars.first {             // count-in: its beats as dots
            let pre = scene.beats.filter { $0 < first.start - 1e-3 }
            let shown = Array(pre.suffix(8))
            for (i, b) in shown.enumerated() {
                let x = Self.W / 2 + (CGFloat(i) - CGFloat(shown.count - 1) / 2) * 44
                ctx.setFillColor(b <= t ? Self.yellow : Self.grey.copy(alpha: 0.5)!)
                ctx.fillEllipse(in: CGRect(x: x - 9, y: 424, width: 18, height: 18))
            }
        }
    }

    private func lyrics(_ ctx: CGContext, state: VideoScene.State?) {
        guard let s = state else { return }
        let big = font("Arial-BoldMT", 88), mid = font("ArialMT", 60)
        var y: CGFloat = 610
        if let n = s.countdown {
            drawCentered(ctx, String(n), font("Arial-BoldMT", 100), Self.red, baseline: 512)
        }
        switch s.kind {
        case "ligne":
            y = karaokeLine(ctx, s.current, lit: s.lit, font: big, firstBaseline: y)
            if !s.next.isEmpty { _ = wrappedCentered(ctx, s.next, mid, Self.grey, firstBaseline: min(990, max(860, y + 40))) }
        case "titre", "instrumental":
            if !s.next.isEmpty { _ = wrappedCentered(ctx, s.next, mid, Self.grey, firstBaseline: 760) }
        default:
            break
        }
    }

    // MARK: « Accords sur les paroles » (the former video, inside the same frame)

    private func chordsOverLyrics(_ ctx: CGContext, state: VideoScene.State?, transpose: Int, flats: Bool) {
        guard let s = state else { return }
        let big = font("Arial-BoldMT", 96), mid = font("ArialMT", 64), chartFont = font("Arial-BoldMT", 80)
        let tr = { (c: [ChordAt]) in c.map { ChordAt(beat: $0.beat, label: ChordText.transpose($0.label, by: transpose, flats: flats)) } }
        let chart = s.chart.map { $0.split(separator: " ").map { ChordText.transpose(String($0), by: transpose, flats: flats) }.joined(separator: " ") }
        switch s.kind {
        case "titre":
            if !chart.isEmpty { chartRow(ctx, chart, pos: s.chartPos, font: chartFont, top: 520) }
            if !s.next.isEmpty { _ = wrappedCentered(ctx, s.next, mid, Self.grey, firstBaseline: 760) }
        case "ligne":
            let y = karaokeLine(ctx, s.current, lit: s.lit, font: big, firstBaseline: 380 + 86 - (s.chords.isEmpty ? 0 : 60),
                                chords: tr(s.chords), chordFont: font("Arial-BoldMT", 72), chordColor: Self.chordBlue)
            preview(ctx, s.next, tr(s.nextChords), font: mid, top: max(y + 60 - 86, 640))
        case "instrumental":
            if !chart.isEmpty { chartRow(ctx, chart, pos: s.chartPos, font: chartFont, top: 400) }
            else { drawCentered(ctx, "♪", font("ArialUnicodeMS", 160), CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1), baseline: 450) }
            preview(ctx, s.next, tr(s.nextChords), font: mid, top: 640)
        case "fin":
            if !chart.isEmpty { chartRow(ctx, chart, pos: s.chartPos, font: chartFont, top: 450) }
        default:
            break
        }
        if let n = s.countdown { drawCentered(ctx, String(n), font("Arial-BoldMT", 150), Self.red, baseline: 290) }
    }

    private func chartRow(_ ctx: CGContext, _ chart: [String], pos: Int?, font f: CTFont, top: CGFloat) {
        var parts: [(String, CGColor)] = [("|", Self.grey)]
        for (i, cell) in chart.enumerated() { parts += [(" \(cell) ", i == pos ? Self.yellow : Self.chordBlue), ("|", Self.grey)] }
        var x = Self.W / 2 - parts.reduce(0) { $0 + width(of: $1.0, f) } / 2
        for (txt, color) in parts {
            drawText(ctx, txt, f, color, x: x, baseline: top + CTFontGetAscent(f))
            x += width(of: txt, f)
        }
    }

    private func preview(_ ctx: CGContext, _ text: String, _ chords: [ChordAt], font f: CTFont, top: CGFloat) {
        guard !text.isEmpty else { return }
        if chords.isEmpty {
            _ = wrappedCentered(ctx, text, f, Self.grey, firstBaseline: top + CTFontGetAscent(f))
        } else {
            _ = karaokeLine(ctx, text, lit: 0, font: f, firstBaseline: top + 48 + CTFontGetAscent(f), chords: chords,
                            chordFont: font("Arial-BoldMT", 48), chordColor: Self.previewBlue, base: Self.grey)
        }
    }

    // MARK: text

    /// A line centred and wrapped at 1680 px: its first `lit` characters yellow; chords (character offset, symbol)
    /// above their syllable, pushed right so they never overlap. Returns the baseline after the last row.
    private func karaokeLine(_ ctx: CGContext, _ text: String, lit: Int, font f: CTFont, firstBaseline: CGFloat,
                             chords: [ChordAt] = [], chordFont: CTFont? = nil, chordColor: CGColor = chordBlue,
                             base: CGColor = white) -> CGFloat {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var offsets: [Int] = [], pos = 0
        for w in words { offsets.append(pos); pos += w.count + 1 }
        let rows = wrapped(words, f, key: text)
        let space = width(of: " ", f)
        let chordH = chordFont.map { CTFontGetSize($0) * 1.1 } ?? 0
        var y = firstBaseline
        for row in rows {
            var x = Self.W / 2 - width(of: row.map { words[$0] }.joined(separator: " "), f) / 2
            if let cf = chordFont, !chords.isEmpty {
                var starts: [Int: CGFloat] = [:], sx = x
                for i in row { starts[i] = sx; sx += width(of: words[i], f) + space }
                var right = -CGFloat.infinity
                for c in chords {
                    guard let i = (0..<words.count).last(where: { offsets[$0] <= c.beat }), let start = starts[i] else { continue }
                    let k = min(c.beat - offsets[i], words[i].count)
                    let lx = max(start + width(of: String(words[i].prefix(k)), f), right)
                    // just above the text row, which moves down by chordH once the chords are placed
                    drawText(ctx, c.label, cf, chordColor, x: lx, baseline: y + chordH - CTFontGetCapHeight(f) - 14)
                    right = lx + width(of: c.label + " ", cf)
                }
                y += chordH
            }
            for i in row {
                let w = words[i], n = max(0, min(w.count, lit - offsets[i]))
                if n > 0 { drawText(ctx, String(w.prefix(n)), f, Self.yellow, x: x, baseline: y) }
                if n < w.count {
                    drawText(ctx, String(w.dropFirst(n)), f, base, x: x + width(of: String(w.prefix(n)), f), baseline: y)
                }
                x += width(of: w, f) + space
            }
            y += CTFontGetSize(f) * 1.25
        }
        return y
    }

    private func wrappedCentered(_ ctx: CGContext, _ text: String, _ f: CTFont, _ color: CGColor, firstBaseline: CGFloat) -> CGFloat {
        let words = text.split(separator: " ").map(String.init)
        var y = firstBaseline
        for row in wrapped(words, f, key: text) {
            drawCentered(ctx, row.map { words[$0] }.joined(separator: " "), f, color, baseline: y)
            y += CTFontGetSize(f) * 1.25
        }
        return y
    }

    private func wrapped(_ words: [String], _ f: CTFont, key: String) -> [[Int]] {
        let k = "\(CTFontGetSize(f))|\(key)"
        if let w = wraps[k] { return w }
        var rows: [[Int]] = [], cur: [Int] = []
        for i in words.indices {
            let trial = (cur + [i]).map { words[$0] }.joined(separator: " ")
            if !cur.isEmpty && width(of: trial, f) > 1680 { rows.append(cur); cur = [i] } else { cur.append(i) }
        }
        if !cur.isEmpty { rows.append(cur) }
        if wraps.count > 500 { wraps.removeAll() }
        wraps[k] = rows
        return rows
    }

    private func font(_ name: String, _ size: CGFloat) -> CTFont {
        let k = "\(name)|\(size)"
        if let f = fonts[k] { return f }
        let f = CTFontCreateWithName(name as CFString, size, nil)
        fonts[k] = f
        return f
    }

    private func line(_ text: String, _ f: CTFont, _ color: CGColor) -> CTLine {
        let k = "\(CTFontGetSize(f))|\(CTFontCopyPostScriptName(f))|\(color.components ?? [])|\(text)"
        if let l = lines[k] { return l }
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        if lines.count > 4000 { lines.removeAll() }
        lines[k] = l
        return l
    }

    private func width(of text: String, _ f: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, f, Self.white), nil, nil, nil))
    }

    private func drawText(_ ctx: CGContext, _ text: String, _ f: CTFont, _ color: CGColor, x: CGFloat, baseline: CGFloat) {
        guard !text.isEmpty else { return }
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line(text, f, color), ctx)
    }

    private func drawCentered(_ ctx: CGContext, _ text: String, _ f: CTFont, _ color: CGColor, baseline: CGFloat) {
        drawText(ctx, text, f, color, x: Self.W / 2 - width(of: text, f) / 2, baseline: baseline)
    }
}
