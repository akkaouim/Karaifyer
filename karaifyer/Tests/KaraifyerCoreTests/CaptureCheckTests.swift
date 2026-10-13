import Testing
@testable import KaraifyerCore

struct CaptureCheckTests {
    // Row 19 (Brassens): 43 ms of silence every 85 ms for 4 minutes — kept as « in the track itself »
    @Test func regularHalfBufferSilencesAreACaptureFault() {
        let gaps = (0..<2800).map { (at: 0.043 + Double($0) * 0.0853, ms: 42.7) }
        #expect(CaptureCheck.isFault(gaps: gaps, durationS: 241))
    }

    @Test func aFewRealSilencesAreNot() {
        let gaps = [(at: 61.2, ms: 180.0), (at: 120.5, ms: 95.0), (at: 200.0, ms: 300.0)]
        #expect(!CaptureCheck.isFault(gaps: gaps, durationS: 240))
    }

    @Test func manySilencesOrMuchSilenceIsAFault() {
        let many = (0..<40).map { (at: Double($0) * 5, ms: 12.0) }          // 40 gaps
        #expect(CaptureCheck.isFault(gaps: many, durationS: 240))
        let long = [(at: 10.0, ms: 13_000.0)]                                // 13 s of 240 s = 5.4 %
        #expect(CaptureCheck.isFault(gaps: long, durationS: 240))
        let ok = (0..<20).map { (at: Double($0) * 10, ms: 30.0) }           // 20 gaps, 0.25 %
        #expect(!CaptureCheck.isFault(gaps: ok, durationS: 240))
    }

    @Test func summaryLine() {
        let gaps = (0..<2806).map { (at: Double($0) * 0.0853, ms: 42.7) }
        #expect(CaptureCheck.summary(gaps) == "2806 silences (43 ms en moyenne, toutes les 85 ms)")
        #expect(CaptureCheck.summary([(at: 61.2, ms: 180.0)]) == "1 silence (180 ms) à 61.20s")
    }
}
