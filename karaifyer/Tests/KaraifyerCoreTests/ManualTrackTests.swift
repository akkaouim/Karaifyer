import Testing
@testable import KaraifyerCore

struct ManualTrackTests {
    let page = """
    <html><head><title>Danser - Song, Lyrics, and Music Video by Loïc Nottet | Spotify</title>
    <meta property="og:title" content="Danser"/><meta property="og:description" content="Loïc Nottet · Addictocrate · Song · 2023"/>
    """

    @Test func readsTitleArtistAlbumFromTheTrackPage() {
        #expect(SpotifyPage.parse(html: page) == SpotifyPage.Track(title: "Danser", artist: "Loïc Nottet", album: "Addictocrate"))
    }

    @Test func decodesEntitiesAndKeepsSeveralArtists() {
        let p = #"<meta property="og:title" content="J&#x27;envoie valser &amp; co"/><meta property="og:description" content="Zazie, Axel Bauer · À ma place · Song · 2001"/>"#
        #expect(SpotifyPage.parse(html: p) == SpotifyPage.Track(title: "J'envoie valser & co", artist: "Zazie, Axel Bauer", album: "À ma place"))
    }

    @Test func aPageThatIsNotASongGivesNothing() {
        #expect(SpotifyPage.parse(html: "<html></html>") == nil)
        #expect(SpotifyPage.parse(html: #"<meta property="og:title" content="Mix"/><meta property="og:description" content="Playlist · Spotify · 50 items"/>"#) == nil)
    }

    @Test func onlyTrackLinksAreAccepted() {
        #expect(TrackList.extractTrackID("https://open.spotify.com/intl-fr/track/2j7g2ug1llC7e5F1Qzxw57?si=abc") == "2j7g2ug1llC7e5F1Qzxw57")
        #expect(TrackList.extractTrackID("https://open.spotify.com/album/2j7g2ug1llC7e5F1Qzxw57") == nil)
        #expect(TrackList.extractTrackID("https://open.spotify.com/playlist/2j7g2ug1llC7e5F1Qzxw57") == nil)
    }

    @Test func addedRowsAreNumberedAfterTheListAndNeverTwice() {
        let existing = [TrackRow(index: 0, number: "1", title: "A", artist: "B", proposer: "", trackID: "AAAAAAAAAAAAAAAAAAAAAA", duplicateOf: nil)]
        let r = ManualTrack.row(trackID: "2j7g2ug1llC7e5F1Qzxw57", title: "Danser", artist: "Loïc Nottet", proposer: "Gaëlle", after: existing)
        #expect(r?.index == 1 && r?.number == "M1" && r?.proposer == "Gaëlle")
        let r2 = ManualTrack.row(trackID: "BBBBBBBBBBBBBBBBBBBBBB", title: "", artist: "", proposer: "", after: existing + [r!])
        #expect(r2?.number == "M2")
        #expect(ManualTrack.row(trackID: "AAAAAAAAAAAAAAAAAAAAAA", title: "", artist: "", proposer: "", after: existing) == nil)
    }
}
