import httpx
import pytest
from karaoke.genius import fetch, lyrics_from_html, pick
from karaoke.runner import StepRetry

PAGE = """<html><body><div id="lyrics-root">
<div data-lyrics-container="true" class="Lyrics__Container">
  <div data-exclude-from-selection="true"><span>5 Contributors</span><h2>Chanson test Lyrics</h2></div>
  [Couplet 1]<br/>Première <i>ligne</i> l&#x27;été<br><a href="/x"><span>Deuxième ligne</span></a><br/>
  <div class="inner">Troisième ligne</div><br/>[Refrain]<br/>On chante (x2)<br/>
</div>
<div data-exclude-from-selection="true">You might also like</div>
<div data-lyrics-container="true">Dernière ligne x2<br/></div>
<div class="LyricsFooter">Embed</div>
</div></body></html>"""


def hit(title, artist, url, artists=None):
    return {"result": {"title": title, "primary_artist": {"name": artist}, "artist_names": artists or artist,
                       "url": url, "lyrics_state": "complete"}}


def search_json(*hits):
    return {"response": {"sections": [{"type": "song", "hits": list(hits)}]}}


def client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_page_text_without_headers_sections_or_repeat_marks():
    assert lyrics_from_html(PAGE) == ["Première ligne l'été", "Deuxième ligne", "Troisième ligne", "On chante",
                                      "Dernière ligne"]


def test_page_without_lyrics_gives_nothing():
    assert lyrics_from_html("<html><body>Pas de paroles</body></html>") == []


def test_pick_matches_title_and_artist_ignoring_accents_and_case():
    hits = [hit("Danser (Live)", "Quelqu'un d'autre", "u0"), hit("Danser", "Loic Nottet", "u1")]
    assert pick(hits, "Danser", "Loïc Nottet") == "u1"


def test_pick_accepts_a_duet_written_differently():
    hits = [hit("À ma place", "Zazie", "u1", artists="Zazie & Axel Bauer")]
    assert pick(hits, "A ma place", "Zazie & Axel Bauer") == "u1"
    assert pick(hits, "À ma place (Remix)", "Zazie") == "u1"


def test_pick_refuses_another_song():
    assert pick([hit("Danser encore", "HK", "u1"), hit("Danser", "Autre", "u2")], "Danser", "Loïc Nottet") is None


def test_fetch_searches_then_reads_the_page():
    seen = []
    def h(req):
        seen.append(req.url.path)
        if req.url.path == "/api/search/song":
            assert req.url.params["q"] == "Chanson test Artiste"
            return httpx.Response(200, json=search_json(hit("Chanson test", "Artiste", "https://genius.com/x-lyrics")))
        return httpx.Response(200, text=PAGE)
    assert fetch("Chanson test", "Artiste", client(h))[0] == "Première ligne l'été"
    assert seen == ["/api/search/song", "/x-lyrics"]


def test_fetch_not_found_is_none():
    h = lambda req: httpx.Response(200, json=search_json(hit("Autre", "Autre", "u")))
    assert fetch("Chanson test", "Artiste", client(h)) is None


@pytest.mark.parametrize("status", [403, 429, 502])
def test_fetch_unreachable_is_a_retry(status):
    with pytest.raises(StepRetry, match=f"Genius HTTP {status}"):
        fetch("t", "a", client(lambda req: httpx.Response(status)), sleep=lambda s: None)


def test_fetch_network_error_is_a_retry():
    def h(req):
        raise httpx.ConnectError("down")
    with pytest.raises(StepRetry, match="Genius"):
        fetch("t", "a", client(h), sleep=lambda s: None)


def test_pick_forgives_a_typo_in_the_sheet():
    assert pick([hit("Alors on danse", "Stromae", "u1")], "Alors on dance", "Stromae") == "u1"
    assert pick([hit("Bella", "GIMS", "u1")], "Bella", "Gimms") == "u1"
    assert pick([hit("Avanie et framboise", "Boby Lapointe", "u1")], "Avanie et framboise", "Bobby Lapointe") == "u1"
    assert pick([hit("Danser encore", "Loïc Nottet", "u1")], "Danser", "Loïc Nottet") is None
