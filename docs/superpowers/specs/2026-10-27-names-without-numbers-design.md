# Names without numbers: recordings and karaoke outputs

## Why

- **Recordings are matched by the number in their name.** The recorder thinks a row is « done » when a FLAC starting
  with its number (`05 - …`) is in the folder. A second CSV numbered from 1 collides with the first: its song 05 is
  skipped because `05 - Danser…` exists.
- **The output folder isn't the folder you pick.** « Change… » picks a parent and the recorder adds a subfolder named
  after the CSV. Picking the subfolder itself nests a second one (`…/Karaoké - Copie de Feuille 1/Karaoké - Copie de
  Feuille 1 (1)`). The output folder changes before the move is confirmed, and there is no Cancel.
- **Moving recordings breaks the karaoke manifest.** It stores each FLAC's full path; the analysis also keys its first
  step on that path, so even a corrected path would re-run the analysis.
- **Michel wants readable names** — `Danser - Loïc Nottet.flac`, `sortie/Danser - Loïc Nottet/` — without the number.

## Decisions

### Identity

- **A recording's identity is its Spotify track id**, already written in every FLAC and MP3 as the `SPOTIFY_URI` tag
  (`spotify:track:<22 chars>`). All 85 FLACs in `Karaoké - Feuille 1` carry it.
- **A karaoke song's identity stays its manifest id** (`005`). Internal files keep it: `travail/<id>/`,
  `paroles/<id>.lrc|.txt`, `accords/<id>.txt`, `mesures/<id>.json`.

### Naming (one rule everywhere)

- `Titre - Artiste`, cleaned as today (`FileNaming.clean` + `sanitize`: `A/B` → `A & B`, wrapping parentheses removed,
  `: / \ ? * " < > |` handled).
  - **Recordings:** the sheet's title and artist, falling back to Spotify's.
  - **Karaoke outputs:** the manifest's.
- **On a clash** with a different song, add ` (2)`, ` (3)`, … before the extension.
  - Recordings clash when they have different Spotify ids; outputs clash when they have different manifest ids.
  - The same song keeps its own name.
- **A file or folder is never overwritten** by another song's.

### Part A — the recorder

1. **Done = a file in the folder with the row's Spotify id.**
   - The folder keeps `.karaifyer-index.json` (file name, size, modification date, Spotify id, title, artist).
   - Entries are re-read with `ffprobe` only for new or changed files. Deleting the index is harmless.
   - Duplicate rows (same track id) are done when one file exists; nothing is copied.
2. **The folder you pick is where files go.**
   - No subfolder per CSV.
   - « Subfolder per “proposé par” » still makes one subfolder per proposer inside it.
   - `sysrec-log.txt` in the folder is appended to, with a header line naming the CSV at each batch start.
3. **« Change… »** asks after the folder is picked, offering three choices:
   - « Déplacer les fichiers », which moves the recordings, the MP3s and the log;
   - « Utiliser sans déplacer »;
   - « Annuler », also on Escape.

   The setting changes only after a confirmation. The move isn't offered when the new folder is the current one or
   inside it.
4. **« Déplacer vers… »** is a context menu item on selected rows of the Enregistrement table.
   - It moves each row's FLAC, MP3 and any `.asd` beside them to the chosen folder.
   - **Safe:** a name that is taken is skipped and reported. A move to another disk copies, checks the size, keeps the
     modification date, then removes the original.
   - It's refused while a batch records or an analysis runs.
   - Afterwards, every manifest row of the current karaoke folder whose `fichier` was a moved file is updated
     (`karaoke relocaliser`, with a backup `manifeste.avant-deplacement-<date>.csv`).
   - The recorder's own view follows the output folder: moved rows read « done » only when it is the folder they went
     to. The confirmation says so.
5. **« Retrouver les enregistrements… »** is shown in the Karaoké tab when manifest rows point to missing files.
   - You pick a folder. Rows are matched by Spotify id (manifest `spotify` column vs the file's tag), else by
     `Titre - Artiste` name.
   - Matched paths are updated, with a backup.
   - This also fixes files moved in the Finder, and other karaoke folders that use the same recordings.
6. **The analysis ignores the recording's path.**
   - The ingest key becomes `size|mtime|duree_ref_s`.
   - Existing ingest markers are rewritten to the new key when the file is unchanged, so no song re-runs anything
     because of this change, nor because of a move or rename.
7. **One-time migration (recorder)**, offered by a sheet at the first launch after the update. It lists what it will
   do, with « Mettre à jour » and « Plus tard ».
   - The output folder setting becomes the old `root/<CSV name>` folder when that folder holds recordings.
   - Each `NN - Titre - Artiste.flac|.mp3|.mp3.asd` is renamed to the new rule, from its tags.
   - A second file with the same Spotify id gets the clash suffix and is listed as a duplicate for Michel to delete;
     nothing is deleted.
   - The manifest paths are updated through `karaoke relocaliser` (backup).
   - Every rename is written to `sysrec-log.txt`.
   - Subfolders (`old takes`, `Karaoké - Copie de Feuille 1…`) are not touched.

### Part B — the karaoke outputs

8. **New `dossier` column in the manifest** (last column), holding the output folder's name.
   - `Workspace.out` is `sortie/<dossier>`; the set is `sets/<Set List>/<dossier>.als`.
   - An empty `dossier` falls back to today's `<id>_<artiste>_<titre>`, so an unmigrated manifest keeps working.
   - New rows (`ajouter`, `manifeste`) get a unique `Titre - Artiste` name.
9. **Editing a title or artist** (`karaoke modifier`) recomputes `dossier` and renames the output folder and every set of
   that song at once. This replaces `adopt_previous_folder`.
10. **No more lookups by id prefix in folder names.** The set step's stale-set cleanup, « Retirer », `etat` paths and
    `sets` use `dossier`.
11. **One-time migration (outputs):** `karaoke migrer-sorties [--plan] --json`, offered by a Karaoké tab banner with a
    sheet (« Renommer » / « Plus tard »).
    - It fills `dossier` with a backup `manifeste.avant-noms-<date>.csv`, and renames `sortie/` folders.
    - It rebuilds every set at its new name (the set step only, a few seconds per song, since sets hold paths into
      `sortie/`) and removes the old `.als` files to the Trash.
    - Nothing heavy re-runs. The video, package and earlier steps stay up to date, because their keys don't involve the
      folder.
    - It is refused during an analysis. Michel should close sets open in Live first; the sheet says so.

## Out of scope

- Renaming the internal id-named files.
- Updating manifests of karaoke folders other than the current one (« Retrouver » covers them).
- Deleting duplicate recordings automatically.

## Testing

- **Swift Core:**
  - naming and clash suffix;
  - the index (reuse for unchanged files, re-read for changed ones);
  - done-by-Spotify-id, including duplicates;
  - the move-offered rule;
  - the migration planner on the real folder layout as fixtures (names only);
  - the safe-move planner (skip taken names).
- **Python:**
  - the ingest key without path, and the marker rewrite (no step re-runs after a rename);
  - `relocaliser` (backup, shared rows, Unicode variants);
  - `retrouver` by tag and by name, on real tagged FLACs made in the test;
  - `dossier` default and uniqueness;
  - `modifier` renaming folder and sets;
  - `migrer-sorties` plan and apply, with only the set step re-run;
  - « Retirer » with `dossier`.
- **Never on Michel's real folders in tests**: throwaway `KARAOKE_HOME` and temp recording folders. On real data, only
  `--plan` dry runs.
