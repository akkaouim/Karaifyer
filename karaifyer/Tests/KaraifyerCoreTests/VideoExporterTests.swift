import AVFoundation
import Foundation
import Testing
@testable import KaraifyerCore

struct VideoExporterTests {
    func scene(total: Double) -> VideoScene {
        VideoScene(version: 1, layout: "grille", titre: "T", artiste: "A", key: nil, padS: 1, totalS: total,
                   beats: (0..<12).map { Double($0) * 0.5 }, bars: [VideoScene.Bar(start: 1, beats: 4, chords: [ChordAt(beat: 0, label: "C")])],
                   states: [VideoScene.State(start: 0, end: total, kind: "ligne", current: "la la", next: "", countdown: nil, lit: 2,
                                             chords: [], chart: [], chartPos: nil, nextChords: [])])
    }

    func duration(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

    @Test func exportsTheSceneDuration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).mp4")
        try VideoExporter.export(scene: scene(total: 3), to: url, layout: "grille", transpose: 0) { _ in true }
        #expect(abs(try await duration(url) - 3) < 0.05)
    }

    @Test func exportDurationFollowsRate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).mp4")
        try VideoExporter.export(scene: scene(total: 3), to: url, layout: "grille", transpose: 0, rate: 1.5) { _ in true }
        #expect(abs(try await duration(url) - 2) < 0.05)              // 3 s of song at ×1.5
    }
}
