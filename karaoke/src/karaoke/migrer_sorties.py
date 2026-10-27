"""One-time rename of the karaoke outputs to « Titre - Artiste » (sortie/<dossier>/, sets/<partie>/<dossier>.als).

The manifest is written first (with a backup), then the folders are renamed: a run cut short is finished by the
next one, which renames any row whose named folder is still missing while its legacy <id>_… folder exists. Sets hold
paths into sortie/, so they are rebuilt (the set step only); nothing heavier re-runs, since no other step's key
involves the folder."""
import fcntl
import glob
import shutil
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from typing import Callable

from karaoke.config import Config
from karaoke.manifest import display_name, read_manifest, unique_dossier, write_manifest
from karaoke.retirer import system_trash
from karaoke.runner import run_song
from karaoke.steps import STEPS
from karaoke.workspace import Workspace


def _legacy_dir(cfg: Config, sid: str) -> Path | None:
    dirs = [p for p in cfg.sortie.glob(f"{sid}_*") if p.is_dir()]
    return dirs[0] if len(dirs) == 1 else None


def plan(cfg: Config) -> list[dict]:
    songs = read_manifest(cfg.manifest)
    taken = {s.dossier: s.id for s in songs if s.dossier}
    out = []
    for s in songs:
        legacy = _legacy_dir(cfg, s.id)
        if s.dossier:
            if legacy is None or (cfg.sortie / s.dossier).exists():
                continue                       # done, or never analysed
            new = s.dossier                    # an interrupted run: the manifest has it, the folder doesn't yet
        else:
            new = unique_dossier(display_name(s.titre, s.artiste) or s.id, s.id, taken)
            while (cfg.sortie / new).exists():                 # a folder no row claims: never merged into
                taken[new] = "?"
                new = unique_dossier(display_name(s.titre, s.artiste) or s.id, s.id, taken)
            taken[new] = s.id
        out.append({"id": s.id, "titre": s.titre, "ancien": legacy.name if legacy else Workspace.folder_name(s),
                    "nouveau": new})
    return out


def _refuse_if_analysing(cfg: Config, ids: list[str]) -> None:
    for sid in ids:
        p = cfg.travail / sid / ".lock"
        if not p.exists():
            continue
        with open(p, "w") as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f, fcntl.LOCK_UN)
            except BlockingIOError:
                raise ValueError(f"analyse en cours ({sid}) : renommer les dossiers après")


def appliquer(cfg: Config, trash: Callable[[list[Path]], None] = system_trash) -> dict:
    items = plan(cfg)
    if not items:
        return {"renommes": 0, "sauvegarde": None, "sets": 0}
    _refuse_if_analysing(cfg, [it["id"] for it in items])
    backup = cfg.home / f"manifeste.avant-noms-{datetime.now():%Y%m%d-%H%M%S}.csv"
    shutil.copy2(cfg.manifest, backup)
    new = {it["id"]: it["nouveau"] for it in items}
    songs = [replace(s, dossier=new[s.id]) if s.id in new else s for s in read_manifest(cfg.manifest)]
    write_manifest(cfg.manifest, songs)
    for it in items:
        src, dst = cfg.sortie / it["ancien"], cfg.sortie / it["nouveau"]
        if src.is_dir() and not dst.exists():
            src.rename(dst)
    old_sets = sorted({p for it in items for p in cfg.sets.glob(f"*/{glob.escape(it['ancien'])}.als")})
    trash(old_sets)
    rebuilt = 0
    for s in songs:
        if s.id in new:
            ws = Workspace(cfg, s)
            if ws.read_marker("package"):
                run_song(ws, STEPS, only={"set"})
                rebuilt += 1
    return {"renommes": len(items), "sauvegarde": str(backup), "sets": rebuilt}
