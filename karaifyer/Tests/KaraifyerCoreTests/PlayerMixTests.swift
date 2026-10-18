import Foundation
import Testing
@testable import KaraifyerCore

struct PlayerMixTests {
    @Test func faderScale() {
        #expect(Fader.db(0) == nil && Fader.label(0) == "−∞")
        #expect(abs(Fader.db(1)! - 6) < 1e-9 && abs(Fader.db(Fader.unity)!) < 1e-9)
        #expect(abs(Fader.position(db: -12) - Fader.unity * 48 / 60) < 1e-9)
        #expect(Fader.label(Fader.position(db: -12)) == "−12 dB" && Fader.label(Fader.unity) == "0 dB")
        #expect(Fader.gain(0) == 0 && abs(Fader.gain(Fader.unity) - 1) < 1e-6)
        #expect(abs(Fader.gain(1) - Float(pow(10, 6.0 / 20))) < 1e-4)
    }

    @Test func showDefaultsFromRetirer() {
        let s = PlayerSettings.defaults(retirer: ["guitar", "other"])
        #expect(s.faders[.guitare] == 0 && s.faders[.accompagnement] == 0)
        #expect(s.faders[.clic] == Fader.unity && s.faders[.basse] == Fader.unity && s.master == Fader.unity)
        #expect(s.mutes.isEmpty && s.solos.isEmpty && s.targetBPM == nil && s.semitones == 0 && s.loopStart == nil)
    }

    @Test func muteAndSoloRules() {
        var s = PlayerSettings.defaults(retirer: [])
        s.solos = [.guitare, .basse]
        s.mutes = [.basse]                                   // muted wins over solo
        let g = s.effectiveGains()
        #expect(g[.guitare] == 1 && g[.basse] == 0 && g[.clic] == 0 && g[.piano] == 0)
        s.solos = []
        #expect(s.effectiveGains()[.clic] == 1 && s.effectiveGains()[.basse] == 0)
    }

    @Test func persistenceRoundTrip() {
        var s = PlayerSettings.defaults(retirer: ["piano"])
        s.targetBPM = 92; s.semitones = -2; s.loopStart = 30; s.loopEnd = 45; s.solos = [.clic]
        #expect(PlayerSettings.decode(s.encoded(), retirer: []) == s)
    }

    @Test func corruptSavedMixFallsBack() {
        #expect(PlayerSettings.decode(Data("nope".utf8), retirer: ["drums"]) == .defaults(retirer: ["drums"]))
        #expect(PlayerSettings.decode(nil, retirer: []) == .defaults(retirer: []))
    }

    @Test func readinessListsMissingFiles() {
        let present: Set<String> = Set(PlayerTrack.allCases.map { "/s/" + $0.file }).subtracting(["/s/piano.flac"])
        #expect(PlayerLibrary.missingFiles(in: "/s", exists: { present.contains($0) }) == ["piano.flac", "paroles.mp4"])
    }

    @Test func searchIgnoresAccentsAndCase() {
        #expect(PlayerLibrary.matches("ble", id: "041", titre: "La chanson des blés d'or", artiste: "F. Thibeault"))
        #expect(PlayerLibrary.matches("ZAZIE", id: "011", titre: "Speed", artiste: "Zazie"))
        #expect(PlayerLibrary.matches("041", id: "041", titre: "x", artiste: "y"))
        #expect(PlayerLibrary.matches("", id: "1", titre: "x", artiste: "y"))
        #expect(!PlayerLibrary.matches("brassens", id: "011", titre: "Speed", artiste: "Zazie"))
    }
}
