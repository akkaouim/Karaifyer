"""Step `set` — the song's Ableton Live set, written as soon as the song is processed.

Inputs:  package result {faders}; the song folder (all audio files + paroles.mp4, after `video`);
         Michel's template (Config.gabarit, only read).
Outputs: $KARAOKE_HOME/sets/<partie>/<dossier du morceau>.als; result {set, warnings}.
"""
from __future__ import annotations
import glob

from karaoke.ableton.build import SongEntry, build_set
from karaoke.runner import Step
from karaoke.workspace import Workspace, slug


def _out(ws: Workspace):
    return ws.cfg.sets / slug(ws.song.partie or "sans-partie") / f"{ws.out.name}.als"


def _key(ws: Workspace) -> str:
    tpl = ws.cfg.gabarit
    mtime = tpl.stat().st_mtime_ns if tpl.exists() else 0
    return f"{tpl}|{mtime}|{ws.song.partie}|{ws.song.titre}"


def remove_stale_sets(ws: Workspace, keep) -> None:
    """Older sets of this song (another partie, or a renamed folder) would open the wrong version."""
    # by name (« Titre - Artiste », never another song's « … (2) »), and the legacy <id>_… names
    for p in {*ws.cfg.sets.glob(f"*/{glob.escape(ws.out.name)}.als"), *ws.cfg.sets.glob(f"*/{ws.song.id}_*.als")}:
        if p != keep:
            p.unlink()


def _run(ws: Workspace, upstream: dict) -> dict:
    remove_stale_sets(ws, _out(ws))
    entry = SongEntry(ws.song.id, ws.song.titre, ws.out, upstream["package"]["faders"])
    r = build_set(ws.cfg.gabarit, [entry], _out(ws))
    return {"set": str(_out(ws)), "warnings": r["warnings"]}


SET_ABLETON = Step(name="set", deps=("package", "video"), key=_key, run=_run, version="2",   # 2: silent lead-in bar, opens on bar 1
                   artifacts=lambda ws: [_out(ws)])
