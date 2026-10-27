"""Per-song folders: travail/<id>/ for intermediate artifacts, sortie/<id>_<artiste>_<titre>/ for deliverables."""
from __future__ import annotations
import json
import os
import re
import unicodedata
from datetime import datetime
from pathlib import Path

from karaoke.config import Config
from karaoke.manifest import Song, display_name, unique_dossier  # noqa: F401 (re-exported)


def slug(text: str, max_len: int = 40) -> str:
    # Every non-alphanumeric char (including ’ and other non-ASCII punctuation) separates
    # words; accents are then dropped (combining marks kept until the ASCII encode).
    decomposed = unicodedata.normalize("NFKD", text)
    spaced = "".join(c if c.isalnum() or unicodedata.combining(c) else " " for c in decomposed)
    norm = spaced.encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-z0-9]+", "-", norm.lower()).strip("-")
    return s[:max_len].rstrip("-") or "sans-titre"


class Workspace:
    def __init__(self, cfg: Config, song: Song):
        self.cfg, self.song = cfg, song
        self.work = cfg.travail / song.id
        self.out = cfg.sortie / self.folder_name(song)
        self.stems = self.work / "stems"
        self.on_log = None   # optional listener (Karaifyer's live terminal via traiter --json)
        self.work.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def folder_name(song: Song) -> str:
        """sortie/<this>: the manifest's `dossier` (« Titre - Artiste »), else the legacy <id>_<artiste>_<titre>.
        Computable without creating travail/<id> (as constructing a Workspace does)."""
        return song.dossier or f"{song.id}_{slug(song.artiste)}_{slug(song.titre)}"

    def adopt_previous_folder(self) -> None:
        """If the song's title/artist changed, rename its existing show folder instead of
        starting a second one (keeps one folder per id)."""
        if self.out.exists():
            return
        previous = [p for p in self.cfg.sortie.glob(f"{self.song.id}_*") if p.is_dir()]
        if len(previous) == 1:
            previous[0].rename(self.out)

    def marker(self, step: str) -> Path:
        # Markers live in their own folder so they never collide with a step's artifacts
        # (the beats tool writes travail/<id>/beats.json).
        return self.work / "etapes" / f"{step}.json"

    def read_marker(self, step: str) -> dict | None:
        p = self.marker(step)
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None

    def write_marker(self, step: str, data: dict) -> None:
        p = self.marker(step)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, p)

    def log(self, msg: str) -> None:
        with open(self.work / "journal.log", "a", encoding="utf-8") as f:
            f.write(f"[{datetime.now().isoformat(timespec='seconds')}] {msg}\n")
        if self.on_log:
            self.on_log(msg)


def renommer_dossier(cfg: Config, sid: str) -> str:
    """After a title or artist edit: the song's output folder and its sets take the new « Titre - Artiste » name
    (` (2)`… when another song holds it, case ignored), and the manifest's `dossier` follows. A song never analysed
    only gets the name. A legacy <id>_… folder is found by its id prefix (its name used the old title). The set is
    rebuilt, since it holds paths into the folder. A failed rename leaves the manifest as it was."""
    import glob
    from dataclasses import replace
    from karaoke.manifest import read_manifest, write_manifest
    songs = read_manifest(cfg.manifest)
    s = next(x for x in songs if x.id == sid)
    taken = {x.dossier: x.id for x in songs if x.dossier and x.id != sid}
    if s.dossier:
        old_dirs = [cfg.sortie / s.dossier]
        old_sets = list(cfg.sets.glob(f"*/{glob.escape(s.dossier)}.als"))
    else:
        old_dirs = [p for p in cfg.sortie.glob(f"{sid}_*") if p.is_dir()]
        old_sets = list(cfg.sets.glob(f"*/{sid}_*.als"))
    old_dir = next((p for p in old_dirs if p.is_dir()), None)

    def ours(p: Path) -> bool:                 # the song's own folder, whatever the case it is spelled in
        return old_dir is not None and p.exists() and os.path.samefile(p, old_dir)

    name = display_name(s.titre, s.artiste) or sid
    new = unique_dossier(name, sid, taken)
    while (cfg.sortie / new).exists() and not ours(cfg.sortie / new):     # a folder no row claims: never merged into
        taken[new] = "?"
        new = unique_dossier(name, sid, taken)
    if new == s.dossier:
        return new
    write_manifest(cfg.manifest, [replace(x, dossier=new) if x.id == sid else x for x in songs])
    try:
        if old_dir is not None and old_dir.name != new:
            old_dir.rename(cfg.sortie / new)
        renamed = []
        for p in old_sets:
            target = p.with_name(f"{new}.als")
            if p.name != target.name and (not target.exists() or os.path.samefile(p, target)):
                p.rename(target)
                renamed.append(target)
    except OSError:
        write_manifest(cfg.manifest, songs)    # the folder kept its name: so does the manifest
        raise
    ws = Workspace(cfg, replace(s, dossier=new))
    marker = ws.read_marker("package")
    if marker and renamed and cfg.gabarit.exists():
        from karaoke.steps.set_ableton import SET_ABLETON
        try:
            SET_ABLETON.run(ws, {"package": marker["result"], "video": {}})
        except Exception as e:                 # the analysis rebuilds it anyway; say so rather than fail the edit
            ws.log(f"set non refait après renommage : {e}")
    return new
