"""Workspace locations. Everything lives under one home folder (env KARAOKE_HOME)."""
from __future__ import annotations
import os
from dataclasses import dataclass
from pathlib import Path

LEGACY_HOME = Path("/Volumes/Hypermnesia/karaoke")   # Michel's first setup: still used when present
DEFAULT_HOME = Path.home() / "Karaoke"


@dataclass(frozen=True)
class Config:
    home: Path

    @classmethod
    def load(cls) -> "Config":
        env = os.environ.get("KARAOKE_HOME")
        if env:
            return cls(home=Path(env))
        return cls(home=LEGACY_HOME if LEGACY_HOME.exists() else DEFAULT_HOME)

    @property
    def manifest(self) -> Path:
        return self.home / "manifeste.csv"

    @property
    def paroles(self) -> Path:
        return self.home / "paroles"

    @property
    def accords(self) -> Path:
        """Michel's corrected chord charts (accords/<id>.txt), never overwritten."""
        return self.home / "accords"

    @property
    def travail(self) -> Path:
        return self.home / "travail"

    @property
    def sortie(self) -> Path:
        return self.home / "sortie"

    @property
    def gabarit(self) -> Path:
        """Michel's Ableton template (only read, never modified)."""
        env = os.environ.get("KARAOKE_GABARIT")
        return Path(env) if env else self.home / "gabarit" / "gabarit Project" / "gabarit.als"

    @property
    def sets(self) -> Path:
        return self.home / "sets"

    def ensure_dirs(self) -> None:
        for d in (self.paroles, self.accords, self.travail, self.sortie, self.sets):
            d.mkdir(parents=True, exist_ok=True)
