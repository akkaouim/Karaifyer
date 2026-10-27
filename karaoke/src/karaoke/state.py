"""Per-song state for Karaifyer: manifest fields, step up-to-dateness, last run's failures, paths."""
from __future__ import annotations
import json
from pathlib import Path
from datetime import datetime

from karaoke.steps.ingest import adopt_legacy_marker
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
    adopt_legacy_marker(ws)          # one stat: markers from the path-based key stay up to date
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
    bt = (ws.read_marker("beats") or {}).get("result") or {}
    grid = None
    if bt.get("beats"):            # results from before the fix file lack the *_detecte fields: derive them
        from karaoke.barfix import on_beat
        from karaoke.grid import beats_per_bar, tempo_stats
        det = on_beat(bt["beats"], bt.get("downbeats_detectees", bt.get("downbeats", [])))
        grid = {"beats": bt["beats"], "downbeats_detectees": det,
                "beats_per_bar_detecte": bt.get("beats_per_bar_detecte") or beats_per_bar(bt["beats"], det),
                "bpm": bt.get("bpm") or tempo_stats(bt["beats"])["bpm"],
                "signature": bt.get("signature"), "swing": bool(bt.get("swing", False))}
    return {"id": s.id, "titre": s.titre, "artiste": s.artiste, "album": s.album, "fichier": str(s.fichier),
            "retirer": list(s.retirer), "langue": s.langue, "partie": s.partie,
            "decompte_mesures": s.decompte_mesures, "statut": rep.get("statut", "—"), "alertes": alerts,
            "verifie": s.verifie or None,
            "corrections": _corrections(cfg, s.id),
            "steps": out_steps,
            "paths": {"dossier": str(ws.out), "video": str(ws.out / "paroles.mp4"),
                      "set": str(cfg.sets / slug(s.partie or "sans-partie") / f"{ws.out.name}.als"),
                      "accords": str(ws.out / "accords.txt"), "lrc": str(ws.out / "paroles.lrc"),
                      "audio": str(ws.work / "input.wav"),
                      "lrc_corrige": str(cfg.paroles / f"{s.id}.lrc"),
                      "accords_corrige": str(cfg.accords / f"{s.id}.txt"),
                      "mesures_corrige": str(cfg.mesures / f"{s.id}.json")},
            "pad_s": pkg.get("pad_s"), "bpm": pkg.get("bpm"), "beats_per_bar": ch.get("beats_per_bar"), "key": ch.get("key"),
            "bars": ch.get("bars", []), "grid": grid, **_open_charts(cfg, s.id)}


def _corrections(cfg: Config, sid: str) -> dict:
    """Michel's own edits (their last change, YYYY-MM-DD): lyrics (timed or plain text), chord chart, bar fixes."""
    def day(*paths: Path) -> str | None:
        times = [p.stat().st_mtime for p in paths if p.exists()]
        return datetime.fromtimestamp(max(times)).strftime("%Y-%m-%d") if times else None
    return {"paroles": day(cfg.paroles / f"{sid}.lrc", cfg.paroles / f"{sid}.txt"),
            "accords": day(cfg.accords / f"{sid}.txt"), "mesures": day(cfg.mesures / f"{sid}.json")}


def _open_charts(cfg: Config, sid: str) -> dict:
    """Chordonomicon progression (as is) and which open chart Corriger can suggest."""
    g = cfg.home / "grilles"
    p = g / "progressions" / f"{sid}.txt"
    o = g / "progressions" / f"{sid}.original.txt"
    idx_path = g / "correspondances.json"
    idx = json.loads(idx_path.read_text(encoding="utf-8")).get(sid, {}) if idx_path.exists() else {}
    proposee = "patadata" if idx.get("patadata") else "chordonomicon" if idx.get("chordonomicon") else None
    return {"progression": p.read_text(encoding="utf-8") if p.exists() else None,
            "progression_originale": o.read_text(encoding="utf-8") if o.exists() else None, "grille_proposee": proposee}
