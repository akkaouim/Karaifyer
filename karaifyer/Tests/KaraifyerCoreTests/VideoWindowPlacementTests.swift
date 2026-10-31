import CoreGraphics
import Testing
@testable import KaraifyerCore

struct VideoWindowPlacementTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let tv = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    @Test func goesToTheScreenTheMainWindowIsNotOn() {
        #expect(VideoWindowPlacement.showScreen(screens: [laptop, tv], mainWindowScreen: 0) == 1)
        #expect(VideoWindowPlacement.showScreen(screens: [laptop, tv], mainWindowScreen: 1) == 0)
    }

    @Test func oneScreenMeansNoShowScreen() {
        #expect(VideoWindowPlacement.showScreen(screens: [laptop], mainWindowScreen: 0) == nil)
        #expect(VideoWindowPlacement.showScreen(screens: [], mainWindowScreen: nil) == nil)
    }

    @Test func withThreeScreensTheLargestOtherOne() {
        let small = CGRect(x: -1024, y: 0, width: 1024, height: 768)
        #expect(VideoWindowPlacement.showScreen(screens: [laptop, small, tv], mainWindowScreen: 0) == 2)
    }

    @Test func unknownMainScreenCountsAsTheFirst() {
        #expect(VideoWindowPlacement.showScreen(screens: [laptop, tv], mainWindowScreen: nil) == 1)
    }

    @Test func defaultFrameIsCentred16by9() {
        let f = VideoWindowPlacement.centred(in: laptop, width: 960)
        #expect(f.size == CGSize(width: 960, height: 540) && f.midX == laptop.midX && f.midY == laptop.midY)
    }
}
