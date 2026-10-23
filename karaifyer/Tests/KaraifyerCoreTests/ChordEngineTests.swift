import Testing
@testable import KaraifyerCore

struct ChordEngineTests {
    @Test func engineFromSettings() {
        #expect(ChordEngine.from(saved: nil) == .jiang && ChordEngine.from(saved: "nope") == .jiang)
        #expect(ChordEngine.from(saved: "btc") == .btc && ChordEngine.from(saved: "madmom") == .madmom)
        #expect(ChordEngine.allCases.map(\.rawValue) == ["jiang", "btc", "ace", "madmom"])
        #expect(ChordEngine.jiang.label == "Jiang 2019 (recommandé)" && ChordEngine.madmom.label == "madmom (ancien)")
    }
}
