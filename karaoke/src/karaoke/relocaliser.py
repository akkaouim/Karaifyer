"""Recordings moved or renamed outside the pipeline (Karaifyer's « Déplacer vers… », the naming migration, the
Finder): the manifest's `fichier` follows, with a backup, and the analysis is kept (path-free ingest key)."""
import shutil
import unicodedata
from dataclasses import replace
from datetime import datetime
from pathlib import Path

from mutagen import File as MutagenFile

from karaoke.config import Config
from karaoke.manifest import read_manifest, write_manifest
from karaoke.steps.ingest import adopt_legacy_marker
from karaoke.workspace import Workspace

AUDIO = {".flac", ".mp3"}


def _norm(p) -> str:
    return unicodedata.normalize("NFC", str(p))


def _apply(cfg: Config, new_paths: dict[str, Path], what: str) -> dict:
    songs = read_manifest(cfg.manifest)
    if not any(s.id in new_paths for s in songs):
        return {"modifies": [], "sauvegarde": None}
    backup = cfg.home / f"manifeste.avant-{what}-{datetime.now():%Y%m%d-%H%M%S}.csv"
    shutil.copy2(cfg.manifest, backup)
    write_manifest(cfg.manifest, [replace(s, fichier=new_paths[s.id]) if s.id in new_paths else s for s in songs])
    for s in songs:
        if s.id in new_paths:    # its analysis was keyed with the old path: carry it over
            adopt_legacy_marker(Workspace(cfg, replace(s, fichier=new_paths[s.id])), old_path=s.fichier)
    return {"modifies": [s.id for s in songs if s.id in new_paths], "sauvegarde": str(backup)}


def relocaliser(cfg: Config, moves: dict[str, str]) -> dict:
    """`moves`: old path → new path. Every row using an old path (however its accents are encoded) follows."""
    by_old = {_norm(k): Path(v) for k, v in moves.items()}
    hits = {s.id: by_old[_norm(s.fichier)] for s in read_manifest(cfg.manifest) if _norm(s.fichier) in by_old}
    return _apply(cfg, hits, "deplacement")


def _tag(path: Path, key: str) -> str:
    try:
        a = MutagenFile(path)
        v = a.tags.get(key) if a is not None and a.tags is not None else None
        return str(v[0] if isinstance(v, list) else v) if v else ""
    except Exception:
        return ""


def retrouver(cfg: Config, dossier: Path, appliquer: bool) -> list[dict]:
    """Rows whose recording is missing, found again in `dossier`: by Spotify id (the file's SPOTIFY_URI tag), else by
    « Titre - Artiste » file name. FLAC preferred over MP3."""
    files = sorted((p for p in dossier.iterdir() if p.is_file() and p.suffix.lower() in AUDIO),
                   key=lambda p: (p.suffix.lower() != ".flac", p.name))
    by_spotify: dict[str, Path] = {}
    by_name: dict[str, Path] = {}
    for p in files:
        sid = _tag(p, "SPOTIFY_URI").removeprefix("spotify:track:")
        if sid:
            by_spotify.setdefault(sid, p)
        by_name.setdefault(_norm(p.stem).casefold(), p)
    found, new_paths = [], {}
    for s in read_manifest(cfg.manifest):
        if s.fichier.exists():
            continue
        hit, par = (by_spotify.get(s.spotify), "spotify") if s.spotify else (None, "")
        if not hit:
            hit, par = by_name.get(_norm(f"{s.titre} - {s.artiste}").casefold()), "nom"
        if hit:
            found.append({"id": s.id, "titre": s.titre, "ancien": str(s.fichier), "nouveau": str(hit), "par": par})
            new_paths[s.id] = hit
    if appliquer and new_paths:
        _apply(cfg, new_paths, "retrouver")
    return found
