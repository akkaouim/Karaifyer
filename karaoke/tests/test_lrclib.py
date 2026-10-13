import httpx
import pytest
from karaoke.lrclib import fetch
from karaoke.runner import StepRetry


def client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_get_synced():
    seen = {}
    def h(req):
        seen.update(dict(req.url.params))
        return httpx.Response(200, json={"instrumental": False, "syncedLyrics": "[00:01.00]a", "plainLyrics": "a"})
    r = fetch("À ma place", "Zazie/Axel Bauer", "Zen", 329.8, client(h))
    assert r.found and r.synced == "[00:01.00]a"
    assert seen["track_name"] == "À ma place" and seen["artist_name"] == "Zazie/Axel Bauer"
    assert seen["duration"] == "330"


def test_404_falls_back_to_search():
    def h(req):
        if req.url.path == "/api/get":
            return httpx.Response(404, json={})
        return httpx.Response(200, json=[{"duration": 400, "syncedLyrics": "x"},
                                         {"duration": 331, "syncedLyrics": None, "plainLyrics": "p", "instrumental": False}])
    r = fetch("t", "a", "al", 329.8, client(h))
    assert r.found and r.synced is None and r.plain == "p"


def test_search_prefers_synced_among_close_durations():
    # measured on LRCLIB: the first close hit was plain-only while others were synced
    def h(req):
        if req.url.path == "/api/get":
            return httpx.Response(404, json={})
        return httpx.Response(200, json=[{"duration": 198.6, "plainLyrics": "p"},
                                         {"duration": 199.0, "syncedLyrics": "[00:02.00]far"},
                                         {"duration": 196.0, "syncedLyrics": "[00:01.00]near"}])
    r = fetch("t", "a", "al", 196.9, client(h))
    assert r.synced == "[00:01.00]near"


def test_not_found():
    r = fetch("t", "a", "al", 100, client(lambda req: httpx.Response(404, json={}) if req.url.path == "/api/get"
                                         else httpx.Response(200, json=[])))
    assert not r.found


def test_network_error_and_503_are_retry():
    def h(req):
        raise httpx.ConnectError("offline")
    with pytest.raises(StepRetry):
        fetch("t", "a", "al", 100, client(h), sleep=lambda s: None)
    with pytest.raises(StepRetry):
        fetch("t", "a", "al", 100, client(lambda req: httpx.Response(503)), sleep=lambda s: None)


def test_transient_503_is_retried_with_backoff():
    calls, sleeps = [], []
    def h(req):
        calls.append(req.url.path)
        if len(calls) < 3:
            return httpx.Response(503)
        return httpx.Response(200, json={"syncedLyrics": "[00:01.00]a"})
    r = fetch("t", "a", "al", 100, client(h), sleep=sleeps.append)
    assert r.synced == "[00:01.00]a" and len(calls) == 3 and sleeps == [2.0, 5.0]


def test_gives_up_after_retries():
    sleeps = []
    with pytest.raises(StepRetry):
        fetch("t", "a", "al", 100, client(lambda req: httpx.Response(503)), sleep=sleeps.append)
    assert sleeps == [2.0, 5.0, 10.0, 30.0, 60.0]     # 043: a 17 s outage window was too short


def test_query_is_nfc():
    import unicodedata
    seen = {}
    def h(req):
        seen.update(dict(req.url.params))
        return httpx.Response(200, json={"syncedLyrics": "[00:01.00]a"})
    fetch(unicodedata.normalize("NFD", "Danser"), unicodedata.normalize("NFD", "Loïc Nottet"), "A", 196, client(h))
    assert seen["artist_name"] == "Loïc Nottet"


def test_any_4xx_on_get_falls_back_to_search():
    # Review: a 400/422 (e.g. empty album from tags) must not mean "retry forever".
    def h(req):
        if req.url.path == "/api/get":
            return httpx.Response(400, json={"message": "bad album"})
        return httpx.Response(200, json=[{"duration": 100, "syncedLyrics": "[00:01.00]a"}])
    assert fetch("t", "a", "", 100, client(h)).synced == "[00:01.00]a"
