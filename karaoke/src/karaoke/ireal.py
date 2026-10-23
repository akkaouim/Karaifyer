"""iReal Pro export: one `irealbook://` link per song (the unobfuscated import format).

Link = irealbook://Title=Composer=Style=Key=n=Progression, percent-encoded. Progression:
`[` + time signature (`T44`) + bars separated by `|` + final `Z`; minor = `-`, N.C. = `n`.
The format has no tempo or beat-position field: chords inside a bar are spread evenly by iReal.
"""
from __future__ import annotations
import html
import re
from pathlib import Path
from urllib.parse import quote

MAJOR_FLAT = {"C#": "Db", "D#": "Eb", "G#": "Ab", "A#": "Bb"}   # iReal's major keys: Db Eb Gb Ab Bb
MINOR_FLAT = {"A#": "Bb", "D#": "Eb"}                            # minor: C#- F#- G#- but Bb- Eb-


QUALITY = {"": "", "m": "-", "maj7": "^7", "m7": "-7", "m7b5": "h7", "m6": "-6", "7": "7", "6": "6",
           "9": "9", "dim": "o", "aug": "+", "sus2": "sus2", "sus4": "sus", "add9": "add9",
           "dim7": "o7", "m9": "-9", "maj9": "^9", "7sus4": "7sus", "mM7": "-^7", "11": "11", "13": "13"}


def chord(symbol: str) -> str:
    """Chart symbol (karaoke.chords.SYMBOL) → iReal syntax: m → -, maj7 → ^7, m7b5 → h7, dim → o…"""
    if symbol == "N.C.":
        return "n"
    m = re.match(r"^([A-G][#b]?)(maj9|maj7|mM7|m7b5|m9|m7|m6|7sus4|dim7|dim|aug|sus2|sus4|add9|11|13|9|7|6|m)?(/[A-G][#b]?)?$", symbol)
    if not m:
        return symbol
    return m.group(1) + QUALITY[m.group(2) or ""] + (m.group(3) or "")


def ireal_key(key: str) -> str:
    """madmom key label (`C# minor`) → iReal key field (`C#-`)."""
    root, _, mode = key.partition(" ")
    if mode == "minor":
        return MINOR_FLAT.get(root, root) + "-"
    return MAJOR_FLAT.get(root, root)


CODES = {"2/4": "T24", "3/4": "T34", "4/4": "T44", "6/8": "T68", "12/8": "T12"}


def signature_code(beats_per_bar: int, signature: str | None) -> str:
    return CODES.get(signature or "", f"T{beats_per_bar}4")


def style_for(beats_per_bar: int, signature: str | None, swing: bool) -> str:
    if signature in ("3/4", "6/8") or (signature is None and beats_per_bar == 3):
        return "Waltz"
    if signature == "12/8":
        return "Slow Rock"
    return "Medium Swing" if swing else "Pop"


def _field(s: str) -> str:
    return s.replace("=", "-")   # `=` separates the link's fields


def song_url(title: str, composer: str, style: str, key: str, bars: list[dict],
             beats_per_bar: int, bpm: float, signature: str | None = None) -> str:
    cells = [" ".join(chord(c) for _, c in b["chords"]) for b in bars]
    prog = "[" + signature_code(beats_per_bar, signature) + " |".join(cells) + " Z"
    body = "=".join([_field(title), _field(composer), _field(style), ireal_key(key), "n", prog])
    return "irealbook://" + quote(body, safe="")   # spec: percent-encode everything


def write_html(path: Path, partie: str, songs: list[tuple[str, str, str]]) -> None:
    """One link per (title, artist, url); open the page on the device where iReal Pro is installed."""
    items = "\n".join(f'<li><a href="{html.escape(u)}">{html.escape(t)}</a> — {html.escape(a)}</li>'
                      for t, a, u in songs)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>iReal Pro — {html.escape(partie)}</title>
<style>body{{font:18px system-ui;margin:16px}}li{{margin:12px 0}}</style>
<h1>iReal Pro — {html.escape(partie)}</h1>
<p>Toucher un titre pour l'importer dans iReal Pro.</p>
<ul>
{items}
</ul>
""", encoding="utf-8")


def write_pages(cfg, songs: list) -> list[Path]:
    """$KARAOKE_HOME/ireal/<partie>.html for every part with at least one charted song."""
    from karaoke.manifest import group_by_partie
    from karaoke.workspace import Workspace, slug
    pages = []
    for partie, group in group_by_partie(songs).items():
        links = []
        for s in group:
            r = (Workspace(cfg, s).read_marker("chords") or {}).get("result")
            if r and r.get("bars"):
                style = style_for(r["beats_per_bar"], r.get("signature"), r.get("swing", False))
                links.append((s.titre, s.artiste, song_url(s.titre, s.artiste, style, r["key"], r["bars"],
                                                           r["beats_per_bar"], r["bpm"], signature=r.get("signature"))))
        if links:
            path = cfg.home / "ireal" / f"{slug(partie)}.html"
            write_html(path, partie, links)
            pages.append(path)
    return pages
