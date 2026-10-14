"""Per-song state for Karaifyer: manifest fields, step up-to-dateness, last run's failures, paths."""
from __future__ import annotations
import json

from karaoke.config import Config
from karaoke.manifest import Song
from karaoke.runner import Step, inspect_song
from karaoke.workspace import Workspace, slug

FAILED = ("echec", "a_reessayer", "bloque")
# Which step's result each report alert questions (the app turns that step's dot orange).
ALERT_STEP = (("tempo instable", "beats"), ("dérive du clic", "package"), ("paroles", "lyrics"),
              ("sans paroles", "lyrics"), ("calage", "lyrics"), ("écart de durée", "ingest"))


def _step_of(alert: str) -> str | None:
    return next((step for prefix, step in ALERT_STEP if alert.startswith(prefix)), None)


def song_state(cfg: Config, s: Song, steps: list[Step]) -> dict:
    ws = Workspace(cfg, s)
    rep_path = ws.out / "rapport.json"
    rep = json.loads(rep_path.read_text(encoding="utf-8")) if rep_path.exists() else {}
    last, alerts = rep.get("etapes", {}), rep.get("alertes", [])
    fresh = inspect_song(ws, steps)
    out_steps = []
    for st in steps:
        status = fresh[st.name]
        if status != "a_jour" and last.get(st.name) in FAILED:
            status = last[st.name]
        marker = ws.read_marker(st.name) or {}
        err = next((a for a in alerts if a.startswith(f"{st.name} :")), "")   # report.song_report's format
        mine = [a for a in alerts if _step_of(a) == st.name]
        out_steps.append({"name": st.name, "status": status, "seconds": marker.get("seconds"),
                          "error": err if status in FAILED else "", "alert": " · ".join(mine)})
    pkg = (ws.read_marker("package") or {}).get("result") or {}
    ch = (ws.read_marker("chords") or {}).get("result") or {}
    return {"id": s.id, "titre": s.titre, "artiste": s.artiste, "album": s.album, "fichier": str(s.fichier),
            "retirer": list(s.retirer), "langue": s.langue, "partie": s.partie,
            "decompte_mesures": s.decompte_mesures, "statut": rep.get("statut", "—"), "alertes": alerts,
            "steps": out_steps,
            "paths": {"dossier": str(ws.out), "video": str(ws.out / "paroles.mp4"),
                      "set": str(cfg.sets / slug(s.partie or "sans-partie") / f"{ws.out.name}.als"),
                      "accords": str(ws.out / "accords.txt"), "lrc": str(ws.out / "paroles.lrc"),
                      "audio": str(ws.work / "input.wav"),
                      "lrc_corrige": str(cfg.paroles / f"{s.id}.lrc"),
                      "accords_corrige": str(cfg.accords / f"{s.id}.txt")},
            "pad_s": pkg.get("pad_s"), "beats_per_bar": ch.get("beats_per_bar"), "key": ch.get("key"),
            "bars": ch.get("bars", [])}
