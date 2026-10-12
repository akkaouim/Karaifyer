"""Command-line entry point: `karaoke manifeste | traiter | rapport`."""
import typer

app = typer.Typer(help="Karaoké live : manifeste → dossiers prêts à jouer.", no_args_is_help=True)


@app.callback()
def main() -> None:
    """Pipeline d'analyse karaoké."""
