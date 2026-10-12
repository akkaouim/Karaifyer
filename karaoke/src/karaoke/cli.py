"""Command-line entry point: `karaoke manifeste | traiter | rapport`."""
import json
from pathlib import Path

import typer

from karaoke.config import Config
from karaoke.manifest import read_manifest, songs_from_sysrec, write_manifest
from karaoke.report import load_reports, song_report, write_global
from karaoke.runner import run_song
from karaoke.steps import STEPS
from karaoke.workspace import Workspace

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


def _csv_set(v: str | None) -> set[str] | None:
    return {x.strip() for x in v.split(",") if x.strip()} if v else None


@app.command()
def traiter(ids: str = typer.Option(None, help="Liste d'id à traiter, ex. 041,066"),
            etape: str = typer.Option(None, help="N'exécuter que cette étape"),
            forcer: str = typer.Option(None, help="Étapes à refaire, ex. package,video")) -> None:
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
        typer.echo(f"▶ {s.id} {s.artiste} – {s.titre}")
        res = run_song(ws, STEPS, force=_csv_set(forcer) or set(), only={etape} if etape else None)
        rep = song_report(s, res)
        ws.out.mkdir(parents=True, exist_ok=True)
        (ws.out / "rapport.json").write_text(json.dumps(rep, ensure_ascii=False, indent=2), encoding="utf-8")
        typer.echo("   " + "  ".join(f"{n}:{r['status']}" for n, r in res.items()) + f"  → {rep['statut']}")
    write_global(load_reports(cfg.sortie, [Workspace(cfg, s).out for s in songs]),
                 cfg.home / "rapport.csv", cfg.home / "rapport.html")
    typer.echo(f"Rapport : {cfg.home / 'rapport.html'}")


@app.command()
def rapport() -> None:
    """Reconstruit le rapport global depuis les rapport.json existants."""
    cfg = Config.load()
    songs = read_manifest(cfg.manifest)
    write_global(load_reports(cfg.sortie, [Workspace(cfg, s).out for s in songs]),
                 cfg.home / "rapport.csv", cfg.home / "rapport.html")
    typer.echo(f"Rapport : {cfg.home / 'rapport.html'}")
