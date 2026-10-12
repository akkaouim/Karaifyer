"""Workspace locations. Everything lives under one home folder (env KARAOKE_HOME)."""
from __future__ import annotations
import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_HOME = Path("/Volumes/Hypermnesia/karaoke")


@dataclass(frozen=True)
class Config:
    home: Path

    @classmethod
    def load(cls) -> "Config":
        env = os.environ.get("KARAOKE_HOME")
        return cls(home=Path(env) if env else DEFAULT_HOME)

    @property
    def manifest(self) -> Path:
        return self.home / "manifeste.csv"

    @property
    def paroles(self) -> Path:
        return self.home / "paroles"

    @property
    def travail(self) -> Path:
        return self.home / "travail"

    @property
    def sortie(self) -> Path:
        return self.home / "sortie"

    def ensure_dirs(self) -> None:
        for d in (self.paroles, self.travail, self.sortie):
            d.mkdir(parents=True, exist_ok=True)
