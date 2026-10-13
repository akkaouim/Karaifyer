import Foundation
import Testing
@testable import KaraifyerCore

struct TrackListTests {
    func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "karaoke", withExtension: "csv", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func parsesKaraokeSheet() throws {
        let result = TrackList.parse(try fixture())
        #expect(result.rows.count == 85)
        #expect(result.ignored.isEmpty)

        let first = result.rows[0]
        #expect(first.number == "1")
        #expect(first.title == "Je suis un homme")
        #expect(first.artist == "Zazie")
        #expect(first.proposer == "Thierry et Gaëlle")
        #expect(first.trackID == "2YNWgxevUxpjZDgW4i5Aky")

        let soleil = try #require(result.rows.first { $0.number == "33" })
        #expect(soleil.artist == "Bleu Soleil, Luiza")
        let dis = try #require(result.rows.first { $0.number == "53" })
        #expect(dis.title == "Dis, quand reviendras-tu ?")

        // Numbering gaps from the sheet are preserved, no rows from the empty tail.
        #expect(!result.rows.contains { $0.number == "37" || $0.number == "51" })
        #expect(result.rows.last?.number == "87")

        let r14 = try #require(result.rows.first { $0.number == "14" })
        let r80 = try #require(result.rows.first { $0.number == "80" })
        #expect(r14.duplicateOf == nil)
        #expect(r80.duplicateOf == r14.index)
        #expect(result.rows.filter { $0.duplicateOf != nil }.count == 1)
    }

    @Test func fileNames() throws {
        let rows = TrackList.parse(try fixture()).rows
        func name(_ n: String, _ t: String? = nil, _ a: String? = nil) -> String {
            FileNaming.baseName(row: rows.first { $0.number == n }!, spotifyTitle: t, spotifyArtist: a, width: 2)
        }
        #expect(name("1") == "01 - Je suis un homme - Zazie")
        #expect(name("3") == "03 - À ma place - Zazie & Axel Bauer")
        #expect(name("14") == "14 - Ma liberté de penser - Florent Pagny")
        #expect(name("53") == "53 - Dis, quand reviendras-tu - Barbara")
        #expect(name("75", "Le pouding à l'arsenic", "Gérard Calvi") == "75 - Le pouding à l'arsenic - Gérard Calvi")
    }

    @Test func plainListOfLinks() {
        let text = """
        https://open.spotify.com/track/2YNWgxevUxpjZDgW4i5Aky?si=abc
        spotify:track:30BWTpgeLnFCQlm7QoF9uV

        https://open.spotify.com/intl-fr/track/38y3xAP05YHlGzPdDDN182
        https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M
        """
        let r = TrackList.parse(text)
        #expect(r.rows.map(\.trackID) == ["2YNWgxevUxpjZDgW4i5Aky", "30BWTpgeLnFCQlm7QoF9uV", "38y3xAP05YHlGzPdDDN182"])
        #expect(r.ignored.count == 1)
    }

    @Test func csvQuoting() {
        let rows = CSV.parse("a,\"b, c\",\"say \"\"hi\"\"\"\r\n1,2,3\n")
        #expect(rows == [["a", "b, c", "say \"hi\""], ["1", "2", "3"]])
    }

    @Test func trimRange() {
        let r = TrimMath.trimRange(firstLoud: 4410, totalFrames: 44100 * 10, sampleRate: 44100, durationMs: 5000)
        #expect(r.start == 4410)
        #expect(r.count == 220500)
        // Capture shorter than reported duration: clamp.
        let s = TrimMath.trimRange(firstLoud: 0, totalFrames: 1000, sampleRate: 44100, durationMs: 5000)
        #expect(s == (0, 1000))
    }

    @Test func quietFadeInIsKept() {
        // Zeros while paused, then a fade-in starting at −100 dBFS: the start is the first non-zero sample.
        var x = [Float](repeating: 0, count: 2 * 1000)
        x += (0..<1000).flatMap { _ in [Float(0.00001), Float(0.00001)] }
        let f = x.withUnsafeBufferPointer { TrimMath.firstLoudFrame($0, channels: 2) }
        #expect(f == 1000)
    }

    @Test func dropoutScanner() {
        let rate = 48000.0
        func run(_ build: (inout [Float]) -> Void) -> [Int] {
            var x = [Float](); build(&x)
            var sc = TrimMath.DropoutScanner(channels: 2, sampleRate: rate)
            x.withUnsafeBufferPointer { sc.feed($0) }
            return sc.dropouts
        }
        let tone: (Int) -> [Float] = { n in (0..<n).flatMap { i in [Float(sin(Double(i) * 0.1) * 0.5), Float(sin(Double(i) * 0.1) * 0.5)] } }
        // Leading silence then music: no dropout.
        #expect(run { $0 += [Float](repeating: 0, count: 2 * 20000); $0 += tone(48000) }.isEmpty)
        // 512-frame hole in the middle of music: one dropout at frame 48000.
        #expect(run { $0 += tone(48000); $0 += [Float](repeating: 0, count: 2 * 512); $0 += tone(48000) } == [48000])
        // Music, then a 2 s deliberate silence, then music: not a glitch.
        #expect(run { $0 += tone(48000); $0 += [Float](repeating: 0, count: 2 * 96000); $0 += tone(48000) }.isEmpty)
        // Stall that resumes with a few quiet samples before the music: still a glitch.
        #expect(run { $0 += tone(48000); $0 += [Float](repeating: 0, count: 2 * 9600)
                      $0 += [Float](repeating: 0.00001, count: 2 * 200); $0 += tone(48000) } == [48000])
        // Trailing silence: not a glitch.
        #expect(run { $0 += tone(48000); $0 += [Float](repeating: 0, count: 2 * 1000) }.isEmpty)
    }
}
