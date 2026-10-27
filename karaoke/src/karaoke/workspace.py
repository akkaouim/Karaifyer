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
