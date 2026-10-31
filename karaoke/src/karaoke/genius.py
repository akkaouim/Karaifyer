"""Genius client: plain lyrics (no timestamps) when LRCLIB is down or has nothing; the lyrics step aligns them.

Genius's official API gives no lyrics, so this reads the public search and song page as a browser does
(private use; it breaks if Genius changes its page). Network trouble → StepRetry; no matching song → None.
"""
from __future__ import annotations
import re
import time
import unicodedata
from difflib import SequenceMatcher
from html.parser import HTMLParser
from typing import Callable

import httpx

from karaoke.lrc import plain_lines
from karaoke.manifest import nfc
from karaoke.runner import StepRetry

BASE = "https://genius.com"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
BACKOFF_S = (2.0, 5.0)
REPEAT = re.compile(r"\s*[\(\[]?\s*[x×]\s*\d+\s*[\)\]]?\s*$", re.IGNORECASE)   # « (x2) », « x3 » at a line's end


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", nfc(s).casefold())
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", s)               # « (Live) », « [Remix] »
    return " ".join(re.sub(r"[^\w]+", " ", s).split())


SIMILAR = 0.85     # the sheet's typos (« Alors on dance », « Gimms », « Bobby Lapointe »); « Danser encore » is 0.63


def _similar(a: str, b: str) -> bool:
    return bool(a and b) and (a == b or SequenceMatcher(None, a, b).ratio() >= SIMILAR)


def _close(a: str, b: str) -> bool:
    a, b = _norm(a), _norm(b)
    return _similar(a, b) or (bool(a and b) and (f" {a} " in f" {b} " or f" {b} " in f" {a} "))


def pick(hits: list[dict], titre: str, artiste: str) -> str | None:
    """The first hit whose title and artist match the sheet's (accents, case, parentheses, small typos ignored)."""
    for h in hits:
        r = h.get("result") or {}
        artists = [(r.get("primary_artist") or {}).get("name") or "", r.get("artist_names") or ""]
        if _similar(_norm(r.get("title") or ""), _norm(titre)) and any(_close(a, artiste) for a in artists) and r.get("url"):
            return r["url"]
    return None


class _Lyrics(HTMLParser):
    """Text of the data-lyrics-container divs, minus their data-exclude-from-selection parts; <br> = new line."""
    VOID = {"br", "img", "hr", "input", "meta", "link", "wbr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0          # open elements inside the current container (0 = outside)
        self.skip = 0           # depth at which an excluded part started (0 = none)
        self.out: list[str] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "br":
            if self.depth and not self.skip:
                self.out.append("\n")
            return
        if tag in self.VOID:
            return
        if self.depth:
            self.depth += 1
            if not self.skip and a.get("data-exclude-from-selection") == "true":
                self.skip = self.depth
        elif tag == "div" and a.get("data-lyrics-container") == "true":
            self.depth = 1
            self.out.append("\n")

    def handle_endtag(self, tag):
        if not self.depth or tag in self.VOID:
            return
        if self.skip == self.depth:
            self.skip = 0
        self.depth -= 1
        if tag == "div":
            self.out.append("\n")

    def handle_data(self, data):
        if self.depth and not self.skip:
            self.out.append(re.sub(r"\s+", " ", data))     # spaces kept around <i>, <a>…; lines come from <br>


def lyrics_from_html(page: str) -> list[str]:
    p = _Lyrics()
    p.feed(page)
    lines = [" ".join(l.split()) for l in "".join(p.out).splitlines()]
    return [x for x in (REPEAT.sub("", l).strip() for l in plain_lines("\n".join(lines))) if x]


def _get(c: httpx.Client, url: str, params: dict | None, sleep: Callable[[float], None]) -> httpx.Response:
    last = ""
    for delay in (*BACKOFF_S, None):
        try:
            r = c.get(url, params=params, headers={"User-Agent": UA}, follow_redirects=True)
            if r.status_code < 400 or r.status_code == 404:
                return r
            last = f"HTTP {r.status_code}"
            if r.status_code not in (429,) and r.status_code < 500:
                break           # 403 (blocked) won't fix itself in seconds
        except httpx.HTTPError as e:
            last = f"injoignable : {e}"
        if delay is None:
            break
        sleep(delay)
    raise StepRetry(f"Genius {last}")


def fetch(titre: str, artiste: str, client: httpx.Client | None = None,
          sleep: Callable[[float], None] = time.sleep) -> list[str] | None:
    """The song's lyric lines from Genius, or None when Genius has no matching song with lyrics."""
    c = client or httpx.Client(timeout=15.0)
    r = _get(c, f"{BASE}/api/search/song", {"q": f"{nfc(titre)} {nfc(artiste)}", "per_page": 10}, sleep)
    if r.status_code != 200:
        return None
    try:
        hits = [h for s in r.json()["response"]["sections"] for h in s.get("hits", [])]
    except (ValueError, KeyError, TypeError):
        raise StepRetry("Genius : réponse de recherche illisible")
    url = pick(hits, titre, artiste)
    if url is None:
        return None
    page = _get(c, url, None, sleep)
    lines = lyrics_from_html(page.text) if page.status_code == 200 else []
    return lines or None
