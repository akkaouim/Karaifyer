"""LRCLIB client (the pipeline's only network access). Network trouble → StepRetry."""
from __future__ import annotations
import time
from dataclasses import dataclass
from typing import Callable

import httpx

from karaoke.manifest import nfc
from karaoke.runner import StepRetry

BASE = "https://lrclib.net"
UA = "karaoke-live/0.1 (github.com/akkaouim/mp3-pipeline)"
DURATION_TOLERANCE_S = 3.0
BACKOFF_S = (2.0, 5.0, 10.0)   # LRCLIB answers 503 under load; measured several in a row


@dataclass(frozen=True)
class LrclibResult:
    found: bool
    instrumental: bool
    synced: str | None
    plain: str | None


NOT_FOUND = LrclibResult(False, False, None, None)


def _result(d: dict) -> LrclibResult:
    return LrclibResult(True, bool(d.get("instrumental")), d.get("syncedLyrics") or None, d.get("plainLyrics") or None)


def _get(c: httpx.Client, url: str, params: dict, sleep: Callable[[float], None]) -> httpx.Response:
    """GET with retries on 5xx/429 and network errors; raises StepRetry once retries are exhausted."""
    last = ""
    for delay in (*BACKOFF_S, None):
        try:
            r = c.get(url, headers={"User-Agent": UA}, params=params)
            if r.status_code < 500 and r.status_code != 429:
                return r
            last = f"HTTP {r.status_code}"
        except httpx.HTTPError as e:
            last = f"injoignable : {e}"
        if delay is None:
            break
        sleep(delay)
    raise StepRetry(f"LRCLIB {last}")


def fetch(titre: str, artiste: str, album: str, duree_s: float, client: httpx.Client | None = None,
          sleep: Callable[[float], None] = time.sleep) -> LrclibResult:
    c = client or httpx.Client(timeout=15.0)
    titre, artiste, album = nfc(titre), nfc(artiste), nfc(album)
    r = _get(c, f"{BASE}/api/get", {"track_name": titre, "artist_name": artiste, "album_name": album,
                                    "duration": int(round(duree_s))}, sleep)
    if r.status_code == 200:
        return _result(r.json())
    # Any other 4xx (404 not found, 400/422 e.g. empty album): fall back to search.
    s = _get(c, f"{BASE}/api/search", {"track_name": titre, "artist_name": artiste}, sleep)
    if s.status_code != 200:
        raise StepRetry(f"LRCLIB recherche HTTP {s.status_code}")
    close = [h for h in s.json() if abs(float(h.get("duration") or 0) - duree_s) <= DURATION_TOLERANCE_S]
    if not close:
        return NOT_FOUND
    # Prefer synced lyrics, then the closest duration.
    best = min(close, key=lambda h: (not h.get("syncedLyrics"), abs(float(h.get("duration") or 0) - duree_s)))
    return _result(best)
