"""LRCLIB client (the pipeline's only network access). Network trouble → StepRetry."""
from __future__ import annotations
from dataclasses import dataclass

import httpx

from karaoke.runner import StepRetry

BASE = "https://lrclib.net"
UA = "karaoke-live/0.1 (github.com/akkaouim/mp3-pipeline)"
DURATION_TOLERANCE_S = 3.0


@dataclass(frozen=True)
class LrclibResult:
    found: bool
    instrumental: bool
    synced: str | None
    plain: str | None


NOT_FOUND = LrclibResult(False, False, None, None)


def _result(d: dict) -> LrclibResult:
    return LrclibResult(True, bool(d.get("instrumental")), d.get("syncedLyrics") or None, d.get("plainLyrics") or None)


def fetch(titre: str, artiste: str, album: str, duree_s: float, client: httpx.Client | None = None) -> LrclibResult:
    c = client or httpx.Client(timeout=15.0)
    headers = {"User-Agent": UA}
    try:
        r = c.get(f"{BASE}/api/get", headers=headers, params={
            "track_name": titre, "artist_name": artiste, "album_name": album, "duration": int(round(duree_s))})
        if r.status_code == 200:
            return _result(r.json())
        if r.status_code != 404:
            raise StepRetry(f"LRCLIB HTTP {r.status_code}")
        s = c.get(f"{BASE}/api/search", headers=headers, params={"track_name": titre, "artist_name": artiste})
        if s.status_code != 200:
            raise StepRetry(f"LRCLIB recherche HTTP {s.status_code}")
        close = [h for h in s.json() if abs(float(h.get("duration") or 0) - duree_s) <= DURATION_TOLERANCE_S]
        if not close:
            return NOT_FOUND
        # Prefer synced lyrics, then the closest duration.
        best = min(close, key=lambda h: (not h.get("syncedLyrics"), abs(float(h.get("duration") or 0) - duree_s)))
        return _result(best)
    except httpx.HTTPError as e:
        raise StepRetry(f"LRCLIB injoignable : {e}") from e
