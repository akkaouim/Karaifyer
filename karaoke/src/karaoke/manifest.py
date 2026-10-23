"""The manifest: one CSV row per song. Contract shared by every step.

Columns: id (3 digits), titre, artiste, album, duree_ref_s, isrc, fichier (audio path),
retirer (stems played live, `;`-separated, Demucs names), decompte_mesures, langue, partie.
"""
from __future__ import annotations
import csv
import os
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from mutagen import File as MutagenFile

STEMS = ("vocals", "drums", "bass", "guitar", "piano", "other")
COLUMNS = ["id", "titre", "artiste", "album", "duree_ref_s", "isrc", "fichier",
           "retirer", "decompte_mesures", "langue", "partie", "spotify"]


class ManifestError(ValueError):
    pass


def nfc(text: str) -> str:
    """Composed Unicode. Spotify/macOS metadata can be decomposed ("Loi" + U+0308), which
    breaks matching (LRCLIB found nothing for « Loïc Nottet » in phase 0)."""
    return unicodedata.normalize("NFC", text).strip()


@dataclass(frozen=True)
class Song:
    id: str
    titre: str
    artiste: str
    album: str
    duree_ref_s: float
    isrc: str
    fichier: Path
    retirer: tuple[str, ...]
    decompte_mesures: int
    langue: str
    partie: str
    spotify: str = ""            # Spotify track id (from the recording sheet), for Chordonomicon


def _parse_row(row: dict, line: int, errors: list[str]) -> Song | None:
    sid = (row.get("id") or "").strip()
    if not re.fullmatch(r"\d{3}", sid):
        errors.append(f"ligne {line}: id « {sid} » doit faire 3 chiffres")
    retirer: list[str] = []
    for name in filter(None, (x.strip() for x in (row.get("retirer") or "").split(";"))):
        if name not in STEMS:
            errors.append(f"ligne {line}: piste inconnue « {name} » dans retirer (attendu : {', '.join(STEMS)})")
        elif name != "vocals" and name not in retirer:
            retirer.append(name)
    try:
        duree = float(row.get("duree_ref_s") or 0)
        decompte = int(row.get("decompte_mesures") or 2)
    except ValueError as e:
        errors.append(f"ligne {line}: nombre invalide ({e})")
        return None
    return Song(id=sid, titre=nfc(row.get("titre") or ""), artiste=nfc(row.get("artiste") or ""),
                album=nfc(row.get("album") or ""), duree_ref_s=duree, isrc=(row.get("isrc") or "").strip(),
                fichier=Path((row.get("fichier") or "").strip()), retirer=tuple(retirer),
                decompte_mesures=decompte, langue=(row.get("langue") or "fr").strip() or "fr",
                partie=(row.get("partie") or "").strip(), spotify=(row.get("spotify") or "").strip())


def read_manifest(path: Path) -> list[Song]:
    errors: list[str] = []
    songs: list[Song] = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for i, row in enumerate(csv.DictReader(f), start=2):
            s = _parse_row(row, i, errors)
            if s:
                songs.append(s)
    seen: set[str] = set()
    for s in songs:
        if s.id in seen:
            errors.append(f"id {s.id} en doublon")
        seen.add(s.id)
    if errors:
        raise ManifestError("Manifeste invalide :\n" + "\n".join(errors))
    return songs


def write_manifest(path: Path, songs: list[Song]) -> None:
    """Atomic: the app and the command line may read it at any moment."""
    tmp = path.with_suffix(".csv.tmp")
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(COLUMNS)
        for s in songs:
            w.writerow([s.id, s.titre, s.artiste, s.album, f"{s.duree_ref_s:.3f}", s.isrc, str(s.fichier),
                        ";".join(s.retirer), s.decompte_mesures, s.langue, s.partie, s.spotify])
    os.replace(tmp, path)


def _tag(audio, key: str) -> str:
    v = audio.tags.get(key) if audio.tags else None
    return nfc(v[0] if isinstance(v, list) and v else str(v or ""))


def songs_from_sysrec(audio_dir: Path) -> list[Song]:
    """One Song per FLAC, from the tags SysRec writes (title, artist, album, track)."""
    songs = []
    for flac in sorted(audio_dir.glob("*.flac")):
        audio = MutagenFile(flac)
        track = re.match(r"\d+", _tag(audio, "tracknumber") or _tag(audio, "track") or flac.name)
        if not track:
            continue
        songs.append(Song(id=f"{int(track.group()):03d}", titre=_tag(audio, "title"),
                          artiste=_tag(audio, "artist"), album=_tag(audio, "album"),
                          duree_ref_s=float(audio.info.length), isrc="", fichier=flac, retirer=(),
                          decompte_mesures=2, langue="fr", partie=""))
    return songs


def group_by_partie(songs: list[Song]) -> dict[str, list[Song]]:
    """Songs per part of the evening, parts in first-appearance order; empty partie → « sans-partie »."""
    groups: dict[str, list[Song]] = {}
    for s in songs:
        groups.setdefault(s.partie or "sans-partie", []).append(s)
    return groups


AUDIO_EXT = {".flac", ".wav", ".mp3", ".m4a", ".aac", ".aiff", ".aif"}


def next_id(songs: list[Song]) -> str:
    return f"{max((int(s.id) for s in songs), default=0) + 1:03d}"


def songs_from_files(paths: list[Path], existing: list[Song]) -> tuple[list[Song], list[str]]:
    """Manifest rows for audio files from anywhere (not only SysRec): tags when present, else the
    file name as title. Files already in the manifest (same resolved path) are skipped."""
    known = {Path(s.fichier).resolve() for s in existing}
    added: list[Song] = []
    skipped: list[str] = []
    for p in paths:
        p = Path(p).expanduser()
        if not p.exists():
            skipped.append(f"{p} : introuvable")
            continue
        p = p.resolve()
        if p in known:
            skipped.append(f"{p.name} : déjà dans le manifeste")
            continue
        if p.suffix.lower() not in AUDIO_EXT:
            skipped.append(f"{p.name} : format non pris en charge")
            continue
        audio = MutagenFile(p, easy=True)
        ok = audio is not None   # a tagless file is falsy (dict-like), but still has a duration
        added.append(Song(id=next_id(existing + added), titre=(_tag(audio, "title") if ok else "") or nfc(p.stem),
                          artiste=_tag(audio, "artist") if ok else "",
                          album=_tag(audio, "album") if ok else "",
                          duree_ref_s=float(audio.info.length) if ok else 0.0, isrc="", fichier=p,
                          retirer=(), decompte_mesures=2, langue="fr", partie=""))
        known.add(p)
    return added, skipped


EDITABLE = ("titre", "artiste", "retirer", "langue", "partie", "decompte_mesures")


def set_field(path: Path, sid: str, champ: str, valeur: str) -> Song:
    """Change one cell, validated exactly like read_manifest; the file is untouched on error."""
    if champ not in EDITABLE:
        raise ManifestError(f"champ « {champ} » non modifiable (modifiables : {', '.join(EDITABLE)})")
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    row = next((r for r in rows if (r.get("id") or "").strip() == sid), None)
    if row is None:
        raise ManifestError(f"morceau {sid} introuvable dans le manifeste")
    row[champ] = valeur
    errors: list[str] = []
    songs = [_parse_row(r, i, errors) for i, r in enumerate(rows, start=2)]
    if errors or any(s is None for s in songs):
        raise ManifestError("; ".join(errors) or f"valeur invalide pour {champ} : « {valeur} »")
    write_manifest(path, songs)
    return next(s for s in songs if s.id == sid)
