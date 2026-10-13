import Foundation
import Testing
@testable import KaraifyerCore

struct RunMarksTests {
    @Test func marksFollowTheRun() {
        var m = RunMarks()
        m.begin(["042", "043", "044"])
        #expect(m["042"] == .queued && m["005"] == nil)
        m.running("042")
        m.songEnded("042", statut: "alerte")
        m.running("043")
        m.processExited("043", code: 1)                 // died without a song_end
        m.running("044")
        #expect(m["042"] == .done(statut: "alerte") && m["043"] == .failed && m["044"] == .running)
        m.stopped()                                     // Arrêter maintenant
        #expect(m["044"] == .stopped)
    }

    @Test func queuedSongsDroppedByAStopAreUnmarked() {
        var m = RunMarks()
        m.begin(["042", "043"]); m.running("042"); m.stopped()
        #expect(m["042"] == .stopped && m["043"] == nil)
    }

    @Test func aNewRunClearsTheOldMarksButAddingToARunKeepsThem() {
        var m = RunMarks()
        m.begin(["042"]); m.running("042"); m.songEnded("042", statut: "ok")
        m.begin(["043"])                                // new run: old marks cleared
        #expect(m["042"] == nil && m["043"] == .queued)
        m.add(["044"])                                  // appended to the same run
        #expect(m["043"] == .queued && m["044"] == .queued)
    }

    @Test func decodesAlerts() throws {
        let raw = #"[{"id":"005","titre":"","artiste":"","album":"","fichier":"","retirer":[],"langue":"fr","partie":"","decompte_mesures":2,"statut":"alerte","alertes":["dérive du clic 44 ms"],"steps":[],"paths":{"dossier":"","video":"","set":"","accords":"","lrc":"","audio":"","lrc_corrige":"","accords_corrige":""},"pad_s":null,"beats_per_bar":null,"key":null,"bars":[]}]"#
        #expect(try SongState.decodeList(Data(raw.utf8))[0].alertes == ["dérive du clic 44 ms"])
    }

    @Test func helpTexts() {
        #expect(Help.step(StepState(name: "separate", status: "a_jour", seconds: 42, error: "")).contains("Séparation"))
        #expect(Help.step(StepState(name: "separate", status: "a_jour", seconds: 42, error: "")).contains("à jour"))
        let failed = Help.step(StepState(name: "video", status: "echec", seconds: nil, error: "video : echec ffmpeg"))
        #expect(failed.contains("Vidéo") && failed.contains("échec") && failed.contains("ffmpeg"))
        #expect(Help.statut("alerte", alertes: ["dérive du clic 44 ms"]).contains("dérive du clic 44 ms"))
        #expect(Help.statut("ok", alertes: []).contains("Prêt"))
        #expect(Help.statut("—", alertes: []).contains("pas encore"))
    }
}
