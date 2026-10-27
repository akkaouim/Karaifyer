"""Command-line entry point: `karaoke manifeste | traiter | rapport`."""
import json
from pathlib import Path

import typer

from karaoke.ableton.build import SetError, SongEntry, build_set
from karaoke.config import Config
from karaoke.ireal import write_pages
from karaoke.manifest import ManifestError, group_by_partie, set_field, read_manifest, songs_from_files, songs_from_sysrec, write_manifest
from karaoke.report import load_reports, song_report, write_global
from karaoke.runner import run_song
from karaoke.state import song_state
from karaoke.steps.set_ableton import remove_stale_sets
from karaoke.tools import TOOLS_DIR, ToolError, run_tool
from karaoke.steps import STEPS
from karaoke.steps.ingest import adopt_legacy_marker
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
    cfg = _workspace()
    out = sortie or cfg.manifest
    if out.exists() and read_manifest(out) and not ecraser:     # an empty manifest (just set up) is replaced
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
    cfg = _workspace()
    songs = read_manifest(cfg.manifest)
    if not songs:
        typer.echo(f"Aucun morceau dans {cfg.manifest}. Ajouter des morceaux avec « karaoke ajouter fichier1.flac … » "
                   "ou depuis Karaifyer (onglet Karaoké, « Ajouter des morceaux… »).")
        return
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
        adopt_legacy_marker(ws)
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
def etat(json_out: bool = typer.Option(True, "--json", help="Sortie JSON (toujours)")) -> None:
    """État de chaque morceau du manifeste (pour Karaifyer) : étapes, statut, chemins."""
    cfg = _workspace()
    typer.echo(json.dumps([song_state(cfg, s, STEPS) for s in read_manifest(cfg.manifest)], ensure_ascii=False))


@app.command()
def ajouter(fichiers: list[Path] = typer.Argument(..., help="Fichiers audio à ajouter")) -> None:
    """Ajoute des morceaux au manifeste depuis n'importe quels fichiers audio (pas seulement SysRec)."""
    cfg = _workspace()
    songs = read_manifest(cfg.manifest)
    added, skipped = songs_from_files(fichiers, songs)
    write_manifest(cfg.manifest, songs + added)
    typer.echo(json.dumps({"ajoutes": [{"id": s.id, "titre": s.titre, "artiste": s.artiste} for s in added],
                           "ignores": skipped}, ensure_ascii=False))


@app.command()
def modifier(id: str = typer.Option(..., help="Id du morceau"), champ: str = typer.Option(..., help="Colonne"),
             valeur: str = typer.Option(..., help="Nouvelle valeur")) -> None:
    """Modifie une case du manifeste (avec les mêmes vérifications que la lecture)."""
    cfg = _workspace()
    try:
        s = set_field(cfg.manifest, id, champ, valeur)
    except ManifestError as e:
        typer.echo(str(e), err=True)
        raise typer.Exit(1)
    typer.echo(json.dumps({"id": s.id, "titre": s.titre, "artiste": s.artiste, "retirer": list(s.retirer),
                           "langue": s.langue, "partie": s.partie, "decompte_mesures": s.decompte_mesures},
                          ensure_ascii=False))


def setup_workspace(cfg: Config) -> list[str]:
    """The karaoke folder with everything it needs: tree, empty manifest, default Ableton template.
    Nothing existing is overwritten. Every command calls it, so a new Mac needs no manual setup."""
    import shutil
    cfg.ensure_dirs()
    created = []
    if not cfg.manifest.exists():
        write_manifest(cfg.manifest, [])
        created.append(str(cfg.manifest))
    tpl = cfg.home / "gabarit" / "gabarit Project" / "gabarit.als"
    if not tpl.exists():
        tpl.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(__file__).parent / "ableton" / "templates" / "gabarit.als", tpl)
        created.append(str(tpl))
    return created


def _workspace() -> Config:
    cfg = Config.load()
    setup_workspace(cfg)
    return cfg


@app.command()
def init(home: Path = typer.Option(None, "--home", help="Dossier karaoké à créer (défaut : KARAOKE_HOME ou ~/Karaoke)")) -> None:
    """Crée le dossier karaoké : arborescence, manifeste vide, gabarit Ableton par défaut (rien n'est écrasé)."""
    cfg = Config(home=home) if home else Config.load()
    created = setup_workspace(cfg)
    typer.echo(json.dumps({"home": str(cfg.home), "created": created}, ensure_ascii=False))


@app.command()
def rapport() -> None:
    """Reconstruit le rapport global depuis les rapport.json existants."""
    cfg = _workspace()
    songs = read_manifest(cfg.manifest)
    write_global(load_reports(cfg.sortie, [Workspace(cfg, s).out for s in songs]),
                 cfg.home / "rapport.csv", cfg.home / "rapport.html")
    typer.echo(f"Rapport : {cfg.home / 'rapport.html'}")


@app.command()
def retirer(ids: str = typer.Option(..., help="Identifiants à retirer, séparés par des virgules"),
            analyse: bool = typer.Option(False, help="Mettre à la Corbeille travail/, sortie/ et le set .als"),
            corrections: bool = typer.Option(False, help="Mettre à la Corbeille paroles/, accords/, mesures/"),
            audio: bool = typer.Option(False, help="Mettre à la Corbeille l'enregistrement (jamais s'il est partagé)"),
            plan: bool = typer.Option(False, "--plan", help="Seulement lister ce qui serait retiré, avec les tailles"),
            as_json: bool = typer.Option(False, "--json")) -> None:
    """Retire des morceaux du manifeste (sauvegarde gardée) ; les fichiers choisis partent à la Corbeille."""
    from karaoke import retirer as R
    cfg = _workspace()
    wanted = [i.strip() for i in ids.split(",") if i.strip()]
    try:
        out = R.plan(cfg, wanted) if plan else R.retirer(cfg, wanted, analyse=analyse, corrections=corrections,
                                                         audio=audio, trash=lambda ps: R.system_trash(ps))
    except ValueError as e:
        typer.echo(str(e), err=True)
        raise typer.Exit(1)
    if as_json:
        typer.echo(json.dumps(out, ensure_ascii=False))
    elif plan:
        for it in out:
            typer.echo(f"{it['id']} {it['titre']} : analyse {it['analyse']['taille']} o, "
                       f"corrections {it['corrections']['taille']} o, audio {it['audio']['taille']} o"
                       + (" (partagé)" if it["audio"]["partage"] else ""))
    else:
        typer.echo(f"Retiré : {', '.join(out['retires'])} — sauvegarde {out['sauvegarde']}, "
                   f"{len(out['corbeille'])} élément(s) à la Corbeille")


@app.command()
def sets(partie: str = typer.Option(None, help="Ne générer que cette partie")) -> None:
    """Génère un set Ableton (.als) par morceau, rangé par partie de soirée, à partir du gabarit."""
    cfg = _workspace()
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


grilles_app = typer.Typer(help="Grilles d'accords ouvertes (Chordonomicon, patadata) et fusion avec la détection.")
app.add_typer(grilles_app, name="grilles")


@grilles_app.command("telecharger")
def grilles_telecharger() -> None:
    """Télécharge Chordonomicon et patadata (≈ 100 Mo, une fois) dans $KARAOKE_HOME/grilles/."""
    from karaoke import grilles
    grilles.telecharger(_workspace(), log=typer.echo)
    typer.echo("Grilles ouvertes à jour.")


@grilles_app.command("lier")
def grilles_lier(feuille: Path = typer.Option(..., help="Feuille d'enregistrement (CSV avec les liens Spotify)")) -> None:
    """Relie chaque morceau à son id Spotify (numéro de ligne de la feuille au début du nom de fichier)."""
    from karaoke import grilles
    typer.echo(f"{grilles.lier(_workspace(), feuille)} morceaux reliés")


@grilles_app.command("fusionner")
def grilles_fusionner(id: str = typer.Option(..., help="Id du morceau"),
                      texte: str = typer.Option(None, help="« - » : grille collée lue sur l'entrée standard"),
                      source: str = typer.Option(None, help="patadata | chordonomicon"),
                      json_out: bool = typer.Option(False, "--json", help="Sortie JSON (pour Karaifyer)")) -> None:
    """Fusionne une grille (collée ou ouverte) avec la détection : cases de la grille et mesures à vérifier."""
    import sys
    from karaoke import grilles
    cfg = _workspace()
    song = next((s for s in read_manifest(cfg.manifest) if s.id == id), None)
    if song is None:
        raise typer.BadParameter(f"morceau {id} introuvable")
    r = grilles.fusionner(cfg, song, sys.stdin.read() if texte == "-" else texte, source)
    typer.echo(json.dumps(r, ensure_ascii=False) if json_out else " | ".join(r["cells"]))


@grilles_app.command("voir")
def grilles_voir(id: str = typer.Option(..., help="Id du morceau"),
                 source: str = typer.Option(None, help="patadata | chordonomicon"),
                 json_out: bool = typer.Option(False, "--json", help="Sortie JSON (pour Karaifyer)")) -> None:
    """La grille ouverte du morceau en texte, dans la tonalité du morceau et telle qu'écrite."""
    from karaoke import grilles
    cfg = _workspace()
    song = next((s for s in read_manifest(cfg.manifest) if s.id == id), None)
    if song is None:
        raise typer.BadParameter(f"morceau {id} introuvable")
    v = grilles.voir(cfg, song, source)
    typer.echo(json.dumps(v, ensure_ascii=False) if json_out else v["texte"])
