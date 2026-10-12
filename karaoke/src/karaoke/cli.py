"""Command-line entry point: `karaoke manifeste | traiter | rapport`."""
from pathlib import Path

import typer

from karaoke.config import Config
from karaoke.manifest import read_manifest, songs_from_sysrec, write_manifest

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
