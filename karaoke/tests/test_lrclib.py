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
        fetch("t", "a", "al", 100, client(h))
    with pytest.raises(StepRetry):
        fetch("t", "a", "al", 100, client(lambda req: httpx.Response(503)))
