"""Removing songs from the manifest (Karaifyer's « Retirer du manifeste… »): the row goes, a backup of the
manifest is kept, the chosen files go to the macOS Trash (never deleted outright), and everything derived from
the manifest — the grilles index, the report, the iReal pages — is rebuilt without the removed songs."""
import glob
import json
import shutil
import subprocess
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import Callable

from karaoke.config import Config
from karaoke.grilles import folder, indexer
from karaoke.ireal import write_pages
from karaoke.manifest import read_manifest, write_manifest
from karaoke.report import load_reports, write_global
from karaoke.workspace import Workspace, slug


def _size(p: Path) -> int:
    if p.is_dir():
        return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    return p.stat().st_size if p.exists() else 0


def _group(paths: list[Path]) -> dict:
    paths = [p for p in paths if p.exists()]
    return {"fichiers": [str(p) for p in paths], "taille": sum(_size(p) for p in paths)}


def _analyse(cfg: Config, song) -> list[Path]:
    """Built by the analysis: travail/<id>, sortie/<dossier>, sets/*/<dossier>.als (any partie, also a stale one),
    and the legacy <id>_… names."""
    name, sid = Workspace.folder_name(song), song.id
    found = {cfg.travail / sid, cfg.sortie / name, *(p for p in cfg.sortie.glob(f"{sid}_*") if p.is_dir()),
             *cfg.sets.glob(f"*/{glob.escape(name)}.als"), *cfg.sets.glob(f"*/{sid}_*.als")}
    return sorted(found)


def _corrections(cfg: Config, sid: str) -> list[Path]:
    """Michel's own work on the song: lyrics, chord chart, bar fixes."""
    return [cfg.paroles / f"{sid}.lrc", cfg.paroles / f"{sid}.txt", cfg.accords / f"{sid}.txt",
            cfg.mesures / f"{sid}.json"]


def _same_file_key(p: Path):
    """The same recording, however the manifest spells it (é composed or not, as macOS accepts both)."""
    try:
        st = p.stat()
        return ("inode", st.st_dev, st.st_ino)
    except OSError:
        return ("path", unicodedata.normalize("NFC", str(p)))


def plan(cfg: Config, ids: list[str]) -> list[dict]:
    """What removing `ids` would touch, per song, with sizes. The recording is `partage` when another manifest
    row (not being removed) uses the same file: it's then never offered."""
    songs = read_manifest(cfg.manifest)
    by_id = {s.id: s for s in songs}
    missing = [i for i in ids if i not in by_id]
    if missing:
        raise ValueError(f"absent du manifeste : {', '.join(missing)}")
    kept = {_same_file_key(s.fichier) for s in songs if s.id not in ids}
    out, seen = [], set()
    for sid in ids:
        s = by_id[sid]
        key = _same_file_key(s.fichier)
        audio = _group([] if key in seen else [s.fichier])   # two removed rows, one recording: listed once
        seen.add(key)
        out.append({"id": sid, "titre": s.titre, "artiste": s.artiste,
                    "analyse": _group(_analyse(cfg, s)), "corrections": _group(_corrections(cfg, sid)),
                    "audio": {**audio, "fichier": str(s.fichier), "partage": _same_file_key(s.fichier) in kept}})
    return out


def system_trash(paths: list[Path]) -> None:
    """macOS Trash (each volume's own), so a removal can be undone from the Finder."""
    if paths:
        subprocess.run(["/usr/bin/trash", *map(str, paths)], check=True, capture_output=True)


def retirer(cfg: Config, ids: list[str], analyse: bool = True, corrections: bool = True, audio: bool = False,
            trash: Callable[[list[Path]], None] = system_trash) -> dict:
    items = plan(cfg, ids)                     # raises on an unknown id before anything changes
    songs = read_manifest(cfg.manifest)
    backup = cfg.home / f"manifeste.avant-retrait-{datetime.now():%Y%m%d-%H%M%S}.csv"
    shutil.copy2(cfg.manifest, backup)
    removed = [s for s in songs if s.id in ids]
    write_manifest(cfg.manifest, [s for s in songs if s.id not in ids])

    chosen: list[Path] = []
    for it in items:
        if analyse:
            chosen += map(Path, it["analyse"]["fichiers"])
        if corrections:
            chosen += map(Path, it["corrections"]["fichiers"])
        if audio and not it["audio"]["partage"]:
            chosen += map(Path, it["audio"]["fichiers"])

    # derived from the manifest: rebuilt without the removed rows
    for sid in ids:
        for p in (folder(cfg) / "progressions" / f"{sid}.txt", folder(cfg) / "progressions" / f"{sid}.original.txt"):
            p.unlink(missing_ok=True)
    if (folder(cfg) / "correspondances.json").exists():
        indexer(cfg)
    rest = read_manifest(cfg.manifest)
    write_global(load_reports(cfg.sortie, [cfg.sortie / Workspace.folder_name(s) for s in rest]),
                 cfg.home / "rapport.csv", cfg.home / "rapport.html")
    pages = set(write_pages(cfg, rest))
    for partie in {s.partie or "sans-partie" for s in removed}:
        page = cfg.home / "ireal" / f"{slug(partie)}.html"
        if page not in pages:
            page.unlink(missing_ok=True)       # the part has no charted song left
    trash(chosen)                              # last: a Trash failure leaves the manifest and its derivatives consistent
    return {"retires": ids, "sauvegarde": str(backup), "corbeille": [str(p) for p in chosen]}
