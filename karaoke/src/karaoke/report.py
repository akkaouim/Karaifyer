"""Per-song rapport.json and the global risk-sorted report (CSV + HTML)."""
from __future__ import annotations
import csv
import html
import json
from pathlib import Path

from karaoke.manifest import Song


def song_report(song: Song, results: dict[str, dict]) -> dict:
    alerts: list[str] = []
    risk = 0

    def res(n: str) -> dict:
        return results.get(n, {}).get("result", {}) or {}

    statuses = {n: r["status"] for n, r in results.items()}
    # A blocked step is a consequence of its dependency's status, already counted there.
    for n, st in statuses.items():
        if st == "echec":
            risk += 100
            alerts.append(f"{n} : {st} {results[n].get('error', '')}".strip())
        elif st == "a_reessayer":
            risk += 40
            alerts.append(f"{n} : à réessayer ({results[n].get('error', '')})")
    ing, pkg, lyr, chk = res("ingest"), res("package"), res("lyrics"), res("check")
    if ing.get("duration_alert"):
        risk += 15
        alerts.append(f"écart de durée {ing.get('ref_delta_s', 0):+.1f} s")
    if pkg and not pkg.get("stable", True):
        risk += 20
        hors = (1 - pkg["steady_share"]) * 100 if pkg.get("steady_share") is not None else pkg.get("variation_pct", 0)
        alerts.append(f"tempo instable ({hors:.0f} % du morceau hors tempo)")
    if (chk.get("drift_ms") or 0) > 30:
        risk += 20
        alerts.append(f"dérive du clic {chk['drift_ms']:.0f} ms")
    for w in res("set").get("warnings", []):
        alerts.append(f"set Ableton : {w}")
    if lyr.get("source") == "aucune":
        risk += 60
        alerts.append("sans paroles : fournir paroles/<id>.txt")
    if lyr.get("source") == "transcription":
        risk += 30
        alerts.append("paroles transcrites automatiquement : à relire")
    rate = chk.get("rate")   # line times now follow the sung words: informative only
    word_rate = chk.get("word_rate")
    if word_rate is not None and word_rate < 0.9:
        risk += round((0.9 - word_rate) * 200)
        alerts.append(f"paroles à vérifier : {word_rate * 100:.0f} % des mots calés (±0,5 s)")
    ch = res("chords")
    if ch.get("erreur"):
        alerts.append(f"chords : {ch['moteur'] + ' — ' if ch.get('moteur') else ''}{ch['erreur']} (grille vide)")
    values = set(statuses.values())
    if "echec" in values:
        statut = "echec"
    elif "a_reessayer" in values:
        statut = "a_reessayer"
    elif "bloque" in values:
        statut = "echec"
    else:
        statut = "alerte" if alerts else "ok"
    return {"id": song.id, "titre": song.titre, "artiste": song.artiste,
            "statut": statut,
            "etapes": statuses, "secondes": {n: round(r.get("seconds", 0), 1) for n, r in results.items()},
            "duree_ecart_s": ing.get("ref_delta_s"),
            "tempo": {k: pkg.get(k) for k in ("bpm", "variation_pct", "steady_share", "stable")},
            "clic_derive_ms": chk.get("drift_ms"),
            "paroles": {"source": lyr.get("source"), "lignes": len(lyr.get("lines", [])), "taux_calage": rate,
                        "taux_mots": word_rate},
            "accords": {k: ch.get(k) for k in ("source", "moteur", "entree")},
            "alertes": alerts, "risque": risk}


FIELDS = ["id", "titre", "artiste", "statut", "risque", "source_paroles", "taux_calage",
          "bpm", "variation_tempo_pct", "clic_derive_ms", "alertes"]


def _flat(r: dict) -> dict:
    t, p = r.get("tempo") or {}, r.get("paroles") or {}
    return {"id": r["id"], "titre": r["titre"], "artiste": r["artiste"], "statut": r["statut"],
            "risque": r["risque"], "source_paroles": p.get("source"),
            "taux_calage": "" if p.get("taux_calage") is None else f"{p['taux_calage']:.0%}",
            "bpm": "" if t.get("bpm") is None else f"{t['bpm']:.1f}",
            "variation_tempo_pct": "" if t.get("variation_pct") is None else f"{t['variation_pct']:.1f}",
            "clic_derive_ms": "" if r.get("clic_derive_ms") is None else f"{r['clic_derive_ms']:.0f}",
            "alertes": " ; ".join(r["alertes"])}


def write_global(rows: list[dict], csv_path: Path, html_path: Path) -> None:
    rows = sorted(rows, key=lambda r: -r["risque"])
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow(_flat(r))
    body = "".join("<tr class='{}'>{}</tr>".format(r["statut"], "".join(
        f"<td>{html.escape(str(v))}</td>" for v in _flat(r).values())) for r in rows)
    head = "".join(f"<th>{h}</th>" for h in FIELDS)
    html_path.write_text(
        "<!doctype html><meta charset='utf-8'><title>Rapport karaoké</title>"
        "<style>body{font:14px system-ui;margin:24px}table{border-collapse:collapse}"
        "td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}"
        "tr.echec{background:#fdd}tr.alerte{background:#ffe9c7}tr.a_reessayer{background:#e6efff}</style>"
        f"<h1>Rapport karaoké ({len(rows)} morceaux)</h1><table><tr>{head}</tr>{body}</table>", encoding="utf-8")


def load_reports(sortie: Path, folders: list[Path] | None = None) -> list[dict]:
    """Reports from the given show folders (the current manifest), or every folder."""
    paths = [f / "rapport.json" for f in folders] if folders is not None else sorted(sortie.glob("*/rapport.json"))
    return [json.loads(p.read_text(encoding="utf-8")) for p in paths if p.exists()]
