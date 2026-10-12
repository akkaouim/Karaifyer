"""Per-song folders: travail/<id>/ for intermediate artifacts, sortie/<id>_<artiste>_<titre>/ for deliverables."""
from __future__ import annotations
import json
import os
import re
import unicodedata
from datetime import datetime
from pathlib import Path

from karaoke.config import Config
from karaoke.manifest import Song


def slug(text: str, max_len: int = 40) -> str:
    norm = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-z0-9]+", "-", norm.lower()).strip("-")
    return s[:max_len].rstrip("-") or "sans-titre"


class Workspace:
    def __init__(self, cfg: Config, song: Song):
        self.cfg, self.song = cfg, song
        self.work = cfg.travail / song.id
        self.out = cfg.sortie / f"{song.id}_{slug(song.artiste)}_{slug(song.titre)}"
        self.stems = self.work / "stems"
        self.work.mkdir(parents=True, exist_ok=True)

    def marker(self, step: str) -> Path:
        return self.work / f"{step}.json"

    def read_marker(self, step: str) -> dict | None:
        p = self.marker(step)
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None

    def write_marker(self, step: str, data: dict) -> None:
        p = self.marker(step)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, p)

    def log(self, msg: str) -> None:
        with open(self.work / "journal.log", "a", encoding="utf-8") as f:
            f.write(f"[{datetime.now().isoformat(timespec='seconds')}] {msg}\n")
