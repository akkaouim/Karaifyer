"""Command-line entry point: `karaoke manifeste | traiter | rapport`."""
import json
from pathlib import Path

import typer

from karaoke.ableton.build import SetError, SongEntry, build_set
from karaoke.config import Config
from karaoke.ireal import write_pages
from karaoke.manifest import group_by_partie, read_manifest, songs_from_sysrec, write_manifest
from karaoke.report import load_reports, song_report, write_global
from karaoke.runner import run_song
from karaoke.steps.set_ableton import remove_stale_sets
from karaoke.tools import TOOLS_DIR, ToolError, run_tool
from karaoke.steps import STEPS
from karaoke.workspace import Workspace, slug

app = typer.Typer(help="Karaoké live : manifeste → dossiers prêts à jouer.", no_args_is_help=True)


@app.callback()
def main() -> None:
    """Pipeline d'analyse karaoké."""


@app.command()
def manifeste(audio: Path = typer.Option(..., help="Dossier des FLAC enregistrés par SysRec"),
              sortie: Path = typer.Option(None, help="Fichier manifeste (défaut : $KARAOKE_HOME/manifeste.csv)"),
              ecraser: bool = typer.Option(False, help="Remplacer un manifeste existant")) -> None:
    """Construit le manifeste à partir des tags des fichiers SysRec."""
    cfg = Config.load()
    cfg.ensure_dirs()
    out = sortie or cfg.manifest
    if out.exists() and not ecraser:
        typer.echo(f"{out} existe déjà (utiliser --ecraser)", err=True)
        raise typer.Exit(1)
    songs = songs_from_sysrec(audio)
    write_manifest(out, songs)
    typer.echo(f"{len(songs)} morceaux écrits dans {out}. Compléter les colonnes retirer, langue et partie.")


def _emit(ev: dict) -> None:
    typer.echo(json.dumps(ev, ensure_ascii=False))


def _csv_set(v: str | None) -> set[str] | None:
    return {x.strip() for x in v.split(",") if x.strip()} if v else None


@app.command()
def traiter(ids: str = typer.Option(None, help="Liste d'id à traiter, ex. 041,066"),
            etape: str = typer.Option(None, help="N'exécuter que cette étape"),
            forcer: str = typer.Option(None, help="Étapes à refaire, ex. package,video"),
            json_out: bool = typer.Option(False, "--json", help="Événements JSON, un par ligne (pour Karaifyer)")) -> None:
    """Traite les morceaux du manifeste (reprend là où il s'est arrêté)."""
    cfg = Config.load()
    cfg.ensure_dirs()
    songs = read_manifest(cfg.manifest)
    wanted = _csv_set(ids)
    names = [s.name for s in STEPS]
    for opt in filter(None, [etape, *(_csv_set(forcer) or [])]):
        if opt not in names:
            typer.echo(f"étape inconnue « {opt} » (étapes : {', '.join(names)})", err=True)
            raise typer.Exit(2)
    for s in songs:
        if wanted and s.id not in wanted:
            continue
        ws = Workspace(cfg, s)
        ws.adopt_previous_folder()
        if json_out:
            ws.on_log = lambda line, sid=s.id: _emit({"event": "log", "id": sid, "line": line})
            _emit({"event": "song_start", "id": s.id})
        else:
            typer.echo(f"▶ {s.id} {s.artiste} – {s.titre}")
        res = run_song(ws, STEPS, force=_csv_set(forcer) or set(), only={etape} if etape else None,
                       on_event=_emit if json_out else None)
        rep = song_report(s, res)
        ws.out.mkdir(parents=True, exist_ok=True)
        (ws.out / "rapport.json").write_text(json.dumps(rep, ensure_ascii=False, indent=2), encoding="utf-8")
        if json_out:
            _emit({"event": "song_end", "id": s.id, "statut": rep["statut"]})
        else:
            typer.echo("   " + "  ".join(f"{n}:{r['status']}" for n, r in res.items()) + f"  → {rep['statut']}")
    write_global(load_reports(cfg.sortie, [Workspace(cfg, s).out for s in songs]),
                 cfg.home / "rapport.csv", cfg.home / "rapport.html")
    pages = write_pages(cfg, songs)
    if not json_out:
        typer.echo(f"Rapport : {cfg.home / 'rapport.html'}")
        for page in pages:
            typer.echo(f"iReal Pro : {page}")


@app.command()
def rapport() -> None:
    """Reconstruit le rapport global depuis les rapport.json existants."""
    cfg = Config.load()
    songs = read_manifest(cfg.manifest)
    write_global(load_reports(cfg.sortie, [Workspace(cfg, s).out for s in songs]),
                 cfg.home / "rapport.csv", cfg.home / "rapport.html")
    typer.echo(f"Rapport : {cfg.home / 'rapport.html'}")


@app.command()
def sets(partie: str = typer.Option(None, help="Ne générer que cette partie")) -> None:
    """Génère un set Ableton (.als) par morceau, rangé par partie de soirée, à partir du gabarit."""
    cfg = Config.load()
    groups = group_by_partie(read_manifest(cfg.manifest))
    warned = False
    for name, songs in groups.items():
        if partie and name != partie:
            continue
        missing = [f"{s.id} {s.titre}" for s in songs
                   if "faders" not in ((Workspace(cfg, s).read_marker("package") or {}).get("result") or {})]
        if missing:
            typer.echo(f"[{name}] pas encore traité (lancer « karaoke traiter ») : " + " ; ".join(missing), err=True)
            raise typer.Exit(1)
        for s in songs:
            ws = Workspace(cfg, s)
            entry = SongEntry(s.id, s.titre, ws.out, ws.read_marker("package")["result"]["faders"])
            out = cfg.sets / slug(name) / f"{ws.out.name}.als"
            remove_stale_sets(ws, out)
            try:
                r = build_set(cfg.gabarit, [entry], out)
            except SetError as e:
                typer.echo(f"[{name}] {e}", err=True)
                raise typer.Exit(1)
            typer.echo(f"{out.relative_to(cfg.home)} : {r['duration_s'] / 60:.1f} min")
            if r["warnings"] and not warned:
                for w in r["warnings"]:
                    typer.echo(f"⚠ {w}", err=True)
                warned = True


@app.command(name="apprendre-stop")
def apprendre_stop(secondes: float = typer.Option(20.0, help="Durée d'envoi")) -> None:
    """Envoie le signal d'arrêt automatique (CC 119 sur le bus IAC) pour l'assigner au bouton Stop de Live."""
    typer.echo("Dans Live : passer en mode MIDI Map (⌘M), cliquer sur le bouton Stop (■), puis attendre :\n"
               "le signal arrive et s'assigne. Quitter le mode MIDI Map (⌘M) et enregistrer le gabarit.")
    try:
        run_tool("midi", ["python", str(TOOLS_DIR / "midi" / "send_cc.py"), "--cc", "119", "--value", "127",
                          "--seconds", str(secondes)], timeout=secondes + 60)
    except ToolError as e:
        typer.echo(str(e), err=True)
        raise typer.Exit(1)
    typer.echo("Terminé.")
