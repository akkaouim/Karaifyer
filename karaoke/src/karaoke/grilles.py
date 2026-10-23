"""Open chord charts: Chordonomicon (CC BY-NC 4.0, Ultimate Guitar progressions by Spotify id) and patadata (French
songbook, chords inline in the lyrics, no licence stated — private use). Downloaded once into $KARAOKE_HOME/grilles/,
matched to the manifest (Spotify id from the recording sheet; artist/title slugs), merged with the detection on
demand (`karaoke grilles fusionner`)."""
from __future__ import annotations
import csv
import hashlib
import io
import json
import re
import shutil
import tarfile
import unicodedata
import urllib.request
from pathlib import Path

from karaoke.chord_sources import key_offset, merge, parse, render, transpose_progression, transpose_sg
from karaoke.chords import chords_per_beat
from karaoke.config import Config
from karaoke.manifest import Song, read_manifest, write_manifest
from karaoke.workspace import Workspace

CHORDONOMICON_URL = ("https://huggingface.co/datasets/ailsntua/Chordonomicon/resolve/refs%2Fconvert%2Fparquet/"
                     "default/train/0000.parquet")
CHORDONOMICON_SHA256 = "64a925d6953371a2a6fd137ada353aae3e3bbbb817fe7c225a6bfb68474602a0"
PATADATA = ("patacrep/patadata", "9722bfc68c9bb68bbc751d1ad3a953be9eb1ea2b")
SPOTIFY = re.compile(r"open\.spotify\.com/(?:intl-[a-z]+/)?track/([A-Za-z0-9]{22})")


def folder(cfg: Config) -> Path:
    return cfg.home / "grilles"


def slug(s: str) -> str:
    s = unicodedata.normalize("NFKD", s.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "_", s).strip("_")


def _get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=300) as r:
        return r.read()


def telecharger(cfg: Config, download=None, log=print) -> None:
    g = folder(cfg)
    g.mkdir(parents=True, exist_ok=True)
    dl = download or _get
    log("Chordonomicon (≈ 92 Mo)…")
    data = dl(CHORDONOMICON_URL)
    if hashlib.sha256(data).hexdigest() != CHORDONOMICON_SHA256:
        raise RuntimeError("Chordonomicon : somme de contrôle incorrecte (téléchargement abîmé ?)")
    tmp = g / "chordonomicon.parquet.tmp"
    tmp.write_bytes(data)
    tmp.replace(g / "chordonomicon.parquet")
    log("patadata…")
    repo, commit = PATADATA
    data = dl(f"https://codeload.github.com/{repo}/tar.gz/{commit}")
    tmpdir = g / "patadata.tmp"
    shutil.rmtree(tmpdir, ignore_errors=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
        for m in t.getmembers():
            parts = Path(m.name).parts[1:]
            if m.isfile() and parts and parts[0] == "songs" and m.name.endswith(".sg") and ".." not in parts:
                m.name = str(Path(*parts))
                t.extract(m, tmpdir)
    shutil.rmtree(g / "patadata", ignore_errors=True)
    tmpdir.rename(g / "patadata")
    indexer(cfg)


def lier(cfg: Config, feuille: Path) -> int:
    """Spotify ids from the recording sheet, matched on the sheet number at the start of each audio file name."""
    by_number: dict[int, str] = {}
    with open(feuille, newline="", encoding="utf-8-sig") as f:
        for row in csv.reader(f):
            num = next((int(c) for c in row if c.strip().isdigit()), None)
            link = next((m.group(1) for c in row if (m := SPOTIFY.search(c))), None)
            if num is not None and link:
                by_number.setdefault(num, link)
    songs, linked = read_manifest(cfg.manifest), 0
    out = []
    for s in songs:
        m = re.match(r"^(\d+)\s*-", Path(s.fichier).name)
        sid = by_number.get(int(m.group(1))) if m else None
        if sid and sid != s.spotify:
            s = Song(**{**s.__dict__, "spotify": sid})
        linked += bool(sid)
        out.append(s)
    write_manifest(cfg.manifest, out)
    if (folder(cfg) / "chordonomicon.parquet").exists() or (folder(cfg) / "patadata").exists():
        indexer(cfg)
    return linked


def indexer(cfg: Config) -> dict:
    g = folder(cfg)
    songs = read_manifest(cfg.manifest)
    pata: dict[str, dict[str, str]] = {}
    root = g / "patadata"
    if root.exists():
        for p in root.glob("songs/*/*.sg"):
            pata.setdefault(slug(p.parent.name), {})[slug(p.stem)] = str(p.relative_to(root))
    progressions: dict[str, str | None] = {}
    pq_path = g / "chordonomicon.parquet"
    ids = sorted({s.spotify for s in songs if s.spotify})
    if pq_path.exists() and ids:
        import pyarrow as pa
        import pyarrow.compute as pc
        import pyarrow.parquet as pq
        t = pq.read_table(pq_path, columns=["chords", "spotify_song_id"])
        t = t.filter(pc.is_in(t.column("spotify_song_id"), value_set=pa.array(ids)))
        seen: dict[str, set[str]] = {}
        for r in t.to_pylist():
            seen.setdefault(r["spotify_song_id"], set()).add(r["chords"].strip())
        progressions = {k: (next(iter(v)) if len(v) == 1 else None) for k, v in seen.items()}
    (g / "progressions").mkdir(parents=True, exist_ok=True)
    index = {}
    for s in songs:
        artist, title = pata.get(slug(s.artiste), {}), slug(s.titre)
        hit = artist.get(title) or next((v for k, v in artist.items() if title and (title in k or k in title)), None)
        prog = progressions.get(s.spotify) if s.spotify else None
        out, orig = g / "progressions" / f"{s.id}.txt", g / "progressions" / f"{s.id}.original.txt"
        k = 0
        if prog:      # saved in the song's key (detected), the chart as written kept next to it
            k = key_offset(parse(prog), _song_key(cfg, s))
            out.write_text(transpose_progression(prog, k) if k else prog, encoding="utf-8")
            orig.write_text(prog, encoding="utf-8")
        else:
            out.unlink(missing_ok=True)
            orig.unlink(missing_ok=True)
        index[s.id] = {"patadata": hit, "chordonomicon": bool(prog), "transposition": k}
    (g / "correspondances.json").write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
    return index


def _song_key(cfg: Config, song: Song) -> str | None:
    return ((Workspace(cfg, song).read_marker("chords") or {}).get("result") or {}).get("key")


def songbook_header(raw: str, transposed: bool = False) -> str:
    """patadata's song header for reading: « Par : … · Album : … » and the chord diagrams (\\utab ukulele, \\gtab
    guitar), which are not lyrics for the merge but help to play the chart."""
    lines = []
    meta = dict(re.findall(r"\b(by|album)=\{([^}]*)\}", raw))
    parts = ([f"Par : {meta['by']}"] if "by" in meta else []) + ([f"Album : {meta['album']}"] if "album" in meta else [])
    if parts:
        lines.append(" · ".join(parts))
    tabs = [f"{c} {f} ({'ukulélé' if k == 'u' else 'guitare'})" for k, c, f in re.findall(r"\\([ug])tab\{([^}]*)\}\{([^}]*)\}", raw)]
    if tabs:
        lines.append("Doigtés : " + " · ".join(tabs) + (" — version d'origine, non transposés" if transposed else ""))
    return "\n".join(lines)


def voir(cfg: Config, song: Song, source: str | None = None) -> dict:
    """The open chart as text, in the song's key and as written (« Visualiser »)."""
    g = folder(cfg)
    idx = json.loads((g / "correspondances.json").read_text(encoding="utf-8")).get(song.id, {})
    src = source or ("patadata" if idx.get("patadata") else "chordonomicon")
    if src == "patadata" and idx.get("patadata"):
        raw = (g / "patadata" / idx["patadata"]).read_text(encoding="utf-8")
        k = key_offset(parse(raw), _song_key(cfg, song))
        moved = transpose_sg(raw, k)
    elif idx.get("chordonomicon"):
        src = "chordonomicon"
        p = g / "progressions" / f"{song.id}.original.txt"
        raw = p.read_text(encoding="utf-8") if p.exists() else (g / "progressions" / f"{song.id}.txt").read_text(encoding="utf-8")
        k = key_offset(parse(raw), _song_key(cfg, song))
        moved = transpose_progression(raw, k) if k else raw
    else:
        raise ValueError(f"aucune grille ouverte pour {song.id}")
    head = (lambda t: t + "\n\n" if t else "")
    return {"source": src, "texte": head(songbook_header(raw, transposed=bool(k))) + render(parse(moved)),
            "original": head(songbook_header(raw)) + render(parse(raw)), "transposition": k}


def fusionner(cfg: Config, song: Song, texte: str | None = None, source: str | None = None) -> dict:
    g = folder(cfg)
    if texte is None:
        idx = json.loads((g / "correspondances.json").read_text(encoding="utf-8")).get(song.id, {})
        src = source or ("patadata" if idx.get("patadata") else "chordonomicon")
        if src == "patadata" and idx.get("patadata"):
            texte = (g / "patadata" / idx["patadata"]).read_text(encoding="utf-8")
        elif idx.get("chordonomicon"):
            texte, src = (g / "progressions" / f"{song.id}.txt").read_text(encoding="utf-8"), "chordonomicon"
        else:
            raise ValueError(f"aucune grille ouverte pour {song.id}")
    else:
        src = "collée"
    ws = Workspace(cfg, song)
    bt = (ws.read_marker("beats") or {}).get("result") or {}
    ch = (ws.read_marker("chords") or {}).get("result") or {}
    ly = (ws.read_marker("lyrics") or {}).get("result") or {}
    beats = bt.get("beats", [])
    if not beats or not ch.get("bars"):
        raise ValueError("analyser le morceau d'abord")
    det_file = ws.work / "chords.json"
    detected = chords_per_beat(json.loads(det_file.read_text())["segments"], beats) if det_file.exists() else []
    bar_starts = [min(range(len(beats)), key=lambda i: abs(beats[i] - b["start"])) for b in ch["bars"]]
    lines = ly.get("lines", [])
    words = [[(w["text"], w["start"]) for w in l.get("words") or []] for l in lines]
    r = merge(parse(texte), beats, bar_starts, ch.get("beats_per_bar") or 4, detected, words, [l["text"] for l in lines])
    return {"cells": r.cells, "flagged": r.flagged, "placed": r.placed, "repeated": r.repeated, "vocab": r.vocab,
            "source": src}
