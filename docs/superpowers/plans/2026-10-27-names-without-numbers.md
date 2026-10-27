# Names Without Numbers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking. **This plan has two gates (Gate A after Part A, Gate B after
> Part B).** A gate is lifted only by a fresh subagent review of that part (see the Gate tasks). Once a gate's
> review is clean, continue autonomously into the next part without asking.

**Goal:** Recordings identified by Spotify id and named `Titre - Artiste`, written straight into the chosen folder,
movable safely (manifest paths follow, no re-analysis); karaoke output folders and sets named `Titre - Artiste`.

**Architecture:**
- **Part A, the recorder:**
  - Pure naming, index and migration logic goes in KaraifyerCore (tested).
  - The Swift app (`QueueModel`, `QueueView` in `KaraifyerApp.swift`) uses it.
  - The pipeline gains `karaoke relocaliser` / `retrouver` and a path-free ingest key.
- **Part B, the outputs:**
  - A `dossier` manifest column replaces folder names derived from the id.
  - `karaoke migrer-sorties` renames the existing folders once and rebuilds the sets.

**Tech Stack:**
- Swift 6 / SwiftPM (Command Line Tools only, no `@State`, `@Observable` models), Swift Testing;
- Python 3 (uv), typer, pytest, mutagen, soundfile.

**Spec:** `docs/superpowers/specs/2026-10-27-names-without-numbers-design.md`

## Global Constraints

- SysRec (repo root `Sources/`, `Tests/`, `Package.swift`) stays untouched. All Swift work is under `karaifyer/`.
- Never touch Michel's real data in tests. Use a throwaway `KARAOKE_HOME` (the `cfg` fixture) and temp folders. On
  real data only `--plan` dry runs; any path under `/private/tmp` written into a real manifest is a bug.
- Nothing is deleted outright: anything removed goes to the macOS Trash (`/usr/bin/trash`), injectable in tests.
- A file or folder is never overwritten by another song's; clashes get ` (2)`, ` (3)`, ….
- The audio stays in its original key; don't implement « enregistrer les accords ».
- Swift tests: `swift test --package-path karaifyer -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
- Python tests: `uv --directory karaoke run pytest -q`
- App build: `karaifyer/build-app.sh --install` (can exceed 10 min: run it in the background).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. No push or merge
  without Michel asking.
- UI text in French, matching the app; code comments in English.

## Review Focus

1. **Unicode variants of the same path** (é composed vs decomposed, as in the real manifest): `relocaliser` and
   `retrouver` must match them, as `retirer._same_file_key` does.
2. **A move to another disk:** the size is checked and the modification date kept, or the ingest key changes and the
   song re-analyses.
3. **The recorder migration on the real layout:** `Karaoké - Feuille 1` holds subfolders, `.mp3.asd` files and
   duplicate-id copies. Subfolders must not be touched, duplicates must not be deleted, and nothing may be renamed onto
   an existing name.
4. **A title edit while the output folder is missing** (never analysed): `modifier` must not fail, and must not rename
   another song's folder.
5. **Interrupted migrations** (drive unplugged half-way): a re-run must finish the job, not double-rename or lose the
   manifest backup.

Tests pinning these lines are in Tasks A2 (1), A1 (2), A4 (3), B3 (4), and A8/B4 (5).

## Rulings recorded up front

- **Base branch:** `noms-sans-numero` is cut from `dossier-karaoke` (the unmerged karaoke-folder switcher). Both touch
  `KaraokeView.swift`, and stacking avoids a conflict. Cost if wrong: one rebase.

---

## PART A — The recorder

### Task A1: Path-free ingest key, legacy markers adopted

**Files:**
- Modify: `karaoke/src/karaoke/steps/ingest.py` (the `_key` function)
- Modify: `karaoke/src/karaoke/state.py` (`song_state`), `karaoke/src/karaoke/cli.py` (the `traiter` loop)
- Test: `karaoke/tests/test_ingest_key.py`

**Interfaces:**
- Produces:
  - `ingest._key(ws) -> str`, equal to `"<size>|<mtime_ns>|<duree_ref_s>"`;
  - `ingest.adopt_legacy_marker(ws, old_path: Path | None = None) -> bool`.

- [ ] **Step 1: Write the failing tests**

```python
import hashlib
import os
from pathlib import Path
from karaoke.runner import inspect_song
from karaoke.steps import STEPS
from karaoke.steps import ingest
from karaoke.workspace import Workspace
from test_manifest import song


def legacy_full_key(path: Path, duree) -> str:
    st = path.stat()
    k = f"{path}|{st.st_size}|{st.st_mtime_ns}|{duree}"
    return hashlib.sha1("|".join(["ingest", ingest.INGEST.version, k]).encode()).hexdigest()


def test_key_does_not_contain_the_path(cfg, tmp_path):
    f = tmp_path / "a.flac"; f.write_bytes(b"x" * 10)
    ws = Workspace(cfg, song(fichier=f))
    assert str(f) not in ingest._key(ws) and ingest._key(ws).startswith("10|")


def test_legacy_marker_is_adopted_so_ingest_stays_up_to_date(cfg, tmp_path):
    f = tmp_path / "a.flac"; f.write_bytes(b"x" * 10)
    ws = Workspace(cfg, song(fichier=f))
    (ws.work / "input.wav").write_bytes(b"w")
    ws.write_marker("ingest", {"key": legacy_full_key(f, ws.song.duree_ref_s), "result": {}, "output_hash": "h"})
    assert inspect_song(ws, STEPS)["ingest"] == "perime"
    assert ingest.adopt_legacy_marker(ws) is True
    assert inspect_song(ws, STEPS)["ingest"] == "a_jour"
    assert ingest.adopt_legacy_marker(ws) is False            # already adopted: no-op


def test_marker_of_a_moved_file_is_adopted_with_its_old_path(cfg, tmp_path):
    old = tmp_path / "05 - Danser.flac"; old.write_bytes(b"x" * 10)
    ws0 = Workspace(cfg, song(fichier=old))
    (ws0.work / "input.wav").write_bytes(b"w")
    ws0.write_marker("ingest", {"key": legacy_full_key(old, ws0.song.duree_ref_s), "result": {}, "output_hash": "h"})
    new = tmp_path / "Danser.flac"; os.rename(old, new)          # rename keeps size and mtime
    ws = Workspace(cfg, song(fichier=new))
    assert ingest.adopt_legacy_marker(ws, old_path=old) is True
    assert inspect_song(ws, STEPS)["ingest"] == "a_jour"


def test_changed_file_is_not_adopted(cfg, tmp_path):
    f = tmp_path / "a.flac"; f.write_bytes(b"x" * 10)
    ws = Workspace(cfg, song(fichier=f))
    ws.write_marker("ingest", {"key": "something-else", "result": {}, "output_hash": "h"})
    assert ingest.adopt_legacy_marker(ws) is False
```

- [ ] **Step 2: Run it to see it fail**

Run: `uv --directory karaoke run pytest -q tests/test_ingest_key.py`
Expected: FAIL. The key still contains the path, and `adopt_legacy_marker` is not defined.

- [ ] **Step 3: Implement**

In `ingest.py`, replace `_key` and add the adoption below it:

```python
def _stat_key(p: Path, duree) -> str:
    st = p.stat() if p.exists() else None
    return f"{st.st_size if st else 0}|{st.st_mtime_ns if st else 0}|{duree}"


def _key(ws: Workspace) -> str:
    """Size, date and reference duration: a renamed or moved recording (same bytes, same date) stays analysed."""
    return _stat_key(ws.song.fichier, ws.song.duree_ref_s)


def _full(version: str, key: str) -> str:
    return hashlib.sha1("|".join(["ingest", version, key]).encode()).hexdigest()


def adopt_legacy_marker(ws: Workspace, old_path: Path | None = None) -> bool:
    """A marker written with the old, path-based key (`<path>|size|mtime|duree`) for this same file is rewritten to
    the current key, so the change of key format — or a move from `old_path` — re-runs nothing."""
    m = ws.read_marker("ingest")
    if not m:
        return False
    p = ws.song.fichier
    legacy = _full(INGEST.version, f"{old_path or p}|{_stat_key(p, ws.song.duree_ref_s)}")
    if m.get("key") != legacy:
        return False
    ws.write_marker("ingest", {**m, "key": _full(INGEST.version, _key(ws))})
    return True
```

Add `import hashlib` at the top. `_full` must equal what `runner.run_song` computes for a step with no deps:
`sha1("|".join([name, version, key]))`. If a test shows otherwise, read `runner.py:105` and match it exactly.

Call `adopt_legacy_marker(ws)`:
- in `state.song_state`, right after its `Workspace` is built;
- in `cli.traiter`, right after `ws = Workspace(cfg, s)`.

It costs one `stat`.

- [ ] **Step 4: Run the tests and the suite**

Run: `uv --directory karaoke run pytest -q`
Expected: everything passes.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/steps/ingest.py karaoke/src/karaoke/state.py karaoke/src/karaoke/cli.py karaoke/tests/test_ingest_key.py
git commit -m "ingest: key on size+date, not path; adopt markers written with the old key"
```

### Task A2: `karaoke relocaliser` and `karaoke retrouver`

**Files:**
- Create: `karaoke/src/karaoke/relocaliser.py`
- Modify: `karaoke/src/karaoke/cli.py` (two commands)
- Test: `karaoke/tests/test_relocaliser.py`

**Interfaces:**
- Consumes: `ingest.adopt_legacy_marker(ws, old_path)` (A1); `retirer._same_file_key`.
- Produces:
  - `relocaliser.relocaliser(cfg, moves: dict[str, str]) -> dict`, returning `{"modifies": [ids], "sauvegarde": path|None}`;
  - `relocaliser.retrouver(cfg, dossier: Path, appliquer: bool) -> list[dict]`, one dict per found row:
    `{"id", "ancien", "nouveau", "par": "spotify"|"nom"}`;
  - the CLI commands `karaoke relocaliser --json` (moves as a JSON object on stdin, old path → new path) and
    `karaoke retrouver --dossier D [--plan] --json`.

- [ ] **Step 1: Write the failing tests**

```python
import json
import unicodedata
from pathlib import Path
import numpy as np
import soundfile as sf
from mutagen.flac import FLAC
from karaoke import relocaliser as RL
from karaoke.manifest import read_manifest, write_manifest
from test_manifest import song


def flac(path: Path, spotify: str = "", title="", artist="") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.zeros((4410, 2), dtype=np.float32), 44100, format="FLAC")
    f = FLAC(path)
    if spotify: f["SPOTIFY_URI"] = f"spotify:track:{spotify}"
    if title: f["title"] = title
    if artist: f["artist"] = artist
    f.save()
    return path


def test_moves_update_every_row_using_the_file_with_a_backup(cfg, tmp_path):
    old = flac(tmp_path / "rec" / "05 - Danser - Loïc Nottet.flac")
    nfd = Path(unicodedata.normalize("NFD", str(old)))
    write_manifest(cfg.manifest, [song(id="005", fichier=old), song(id="050", fichier=nfd),
                                  song(id="011", fichier=tmp_path / "other.flac")])
    new = tmp_path / "rec2" / "Danser - Loïc Nottet.flac"
    new.parent.mkdir(); old.rename(new)
    r = RL.relocaliser(cfg, {str(old): str(new)})
    assert r["modifies"] == ["005", "050"] and Path(r["sauvegarde"]).exists()
    by = {s.id: s for s in read_manifest(cfg.manifest)}
    assert by["005"].fichier == new and by["050"].fichier == new and by["011"].fichier == tmp_path / "other.flac"


def test_no_matching_row_changes_nothing_and_makes_no_backup(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(id="011", fichier=tmp_path / "x.flac")])
    assert RL.relocaliser(cfg, {"/a.flac": "/b.flac"}) == {"modifies": [], "sauvegarde": None}


def test_retrouver_by_spotify_id_then_by_name(cfg, tmp_path):
    d = tmp_path / "Nouveau"
    flac(d / "Danser - Loïc Nottet.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")
    flac(d / "Speed - Zazie.flac")
    write_manifest(cfg.manifest, [
        song(id="050", titre="Danser", artiste="Loïc Nottet", fichier=tmp_path / "gone/05 - Danser.flac",
             spotify="2j7g2ug1llC7e5F1Qzxw57"),
        song(id="056", titre="Speed", artiste="Zazie", fichier=tmp_path / "gone/56 - Speed - Zazie.flac"),
        song(id="099", titre="Absent", artiste="X", fichier=tmp_path / "gone/99.flac")])
    found = RL.retrouver(cfg, d, appliquer=False)
    assert {(f["id"], f["par"]) for f in found} == {("050", "spotify"), ("056", "nom")}
    assert read_manifest(cfg.manifest)[0].fichier == tmp_path / "gone/05 - Danser.flac"     # plan only
    RL.retrouver(cfg, d, appliquer=True)
    assert read_manifest(cfg.manifest)[0].fichier == d / "Danser - Loïc Nottet.flac"


def test_retrouver_ignores_rows_whose_file_exists(cfg, tmp_path):
    here = flac(tmp_path / "a.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")
    flac(tmp_path / "d" / "copy.flac", spotify="2j7g2ug1llC7e5F1Qzxw57")
    write_manifest(cfg.manifest, [song(id="050", fichier=here, spotify="2j7g2ug1llC7e5F1Qzxw57")])
    assert RL.retrouver(cfg, tmp_path / "d", appliquer=False) == []


def test_cli_relocaliser_reads_moves_on_stdin(cfg, tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke.cli import app
    old = flac(tmp_path / "a.flac")
    write_manifest(cfg.manifest, [song(id="005", fichier=old)])
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    r = CliRunner().invoke(app, ["relocaliser", "--json"], input=json.dumps({str(old): str(tmp_path / "b.flac")}))
    assert r.exit_code == 0 and json.loads(r.stdout)["modifies"] == ["005"]
```

- [ ] **Step 2: Run them to see them fail**

Run: `uv --directory karaoke run pytest -q tests/test_relocaliser.py`
Expected: ImportError, because `karaoke.relocaliser` doesn't exist yet.

- [ ] **Step 3: Implement `relocaliser.py`**

```python
"""Recordings moved or renamed outside the pipeline (Karaifyer's « Déplacer vers… », the naming migration, the
Finder): the manifest's `fichier` follows, with a backup, and the analysis is kept (path-free ingest key)."""
import shutil
import unicodedata
from dataclasses import replace
from datetime import datetime
from pathlib import Path

from mutagen import File as MutagenFile

from karaoke.config import Config
from karaoke.manifest import read_manifest, write_manifest
from karaoke.steps.ingest import adopt_legacy_marker
from karaoke.workspace import Workspace

AUDIO = {".flac", ".mp3"}


def _norm(p) -> str:
    return unicodedata.normalize("NFC", str(p))


def _backup(cfg: Config, what: str) -> Path:
    b = cfg.home / f"manifeste.avant-{what}-{datetime.now():%Y%m%d-%H%M%S}.csv"
    shutil.copy2(cfg.manifest, b)
    return b


def _apply(cfg: Config, new_paths: dict[str, Path], what: str) -> dict:
    songs = read_manifest(cfg.manifest)
    changed = [s for s in songs if s.id in new_paths]
    if not changed:
        return {"modifies": [], "sauvegarde": None}
    backup = _backup(cfg, what)
    out = [replace(s, fichier=new_paths[s.id]) if s.id in new_paths else s for s in songs]
    write_manifest(cfg.manifest, out)
    for old, s in ((o, n) for o in changed for n in out if n.id == o.id):
        adopt_legacy_marker(Workspace(cfg, s), old_path=old.fichier)
    return {"modifies": [s.id for s in changed], "sauvegarde": str(backup)}


def relocaliser(cfg: Config, moves: dict[str, str]) -> dict:
    by_old = {_norm(k): Path(v) for k, v in moves.items()}
    hits = {s.id: by_old[_norm(s.fichier)] for s in read_manifest(cfg.manifest) if _norm(s.fichier) in by_old}
    return _apply(cfg, hits, "deplacement")


def _tag(path: Path, key: str) -> str:
    try:
        a = MutagenFile(path)
        v = a.tags.get(key) if a and a.tags else None
        return str(v[0] if isinstance(v, list) else v) if v else ""
    except Exception:
        return ""


def _name_key(titre: str, artiste: str) -> str:
    return _norm(f"{titre} - {artiste}").casefold()


def retrouver(cfg: Config, dossier: Path, appliquer: bool) -> list[dict]:
    files = [p for p in sorted(dossier.iterdir()) if p.suffix.lower() in AUDIO and p.is_file()]
    flacs_first = sorted(files, key=lambda p: p.suffix.lower() != ".flac")
    by_spotify, by_name = {}, {}
    for p in flacs_first:
        sid = _tag(p, "SPOTIFY_URI").removeprefix("spotify:track:")
        if sid: by_spotify.setdefault(sid, p)
        by_name.setdefault(_norm(p.stem).casefold(), p)
    found, new_paths = [], {}
    for s in read_manifest(cfg.manifest):
        if s.fichier.exists():
            continue
        hit, par = (by_spotify.get(s.spotify), "spotify") if s.spotify else (None, "")
        if not hit:
            hit, par = by_name.get(_name_key(s.titre, s.artiste)), "nom"
        if hit:
            found.append({"id": s.id, "ancien": str(s.fichier), "nouveau": str(hit), "par": par})
            new_paths[s.id] = hit
    if appliquer:
        _apply(cfg, new_paths, "retrouver")
    return found
```

The name match compares the file name's stem with `Titre - Artiste`. The test's « Speed - Zazie.flac » has no tags,
so it can only be found by name.

Add the two CLI commands next to `retirer` in `cli.py`, following its pattern. `relocaliser` reads
`json.load(sys.stdin)`. Both print `json.dumps(..., ensure_ascii=False)` with `--json`, else one line per row.

- [ ] **Step 4: Run the tests and the suite** — `uv --directory karaoke run pytest -q`. Expected: everything passes.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/relocaliser.py karaoke/src/karaoke/cli.py karaoke/tests/test_relocaliser.py
git commit -m "karaoke relocaliser / retrouver: manifest paths follow moved recordings, with a backup"
```

### Task A3: Core naming, recording index, done-by-Spotify-id

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/RecordingFolder.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/RecordingFolderTests.swift`

**Interfaces:**
- Produces:
  - `RecordingNaming.base(title:artist:) -> String`, giving `"Titre - Artiste"` cleaned with
    `FileNaming.clean` / `sanitize`, or the title alone when the artist is empty;
  - `RecordingNaming.unique(base:trackID:ext:existing:) -> String`, the file name with its extension. `existing` maps
    each file name in the folder to its track id (`[String: String?]`).
  - `RecordingIndex` (Codable):
    - `entries: [String: Entry]`, where `Entry` is `{size: Int64, mtime: Double, trackID: String?, title, artist}`;
    - `static func load(dir:) -> RecordingIndex`;
    - `func save(dir:)`;
    - `mutating func refresh(listing: [(name: String, size: Int64, mtime: Double)], read: (String) -> Entry) -> Bool`,
      which re-reads only new or changed names, drops vanished ones, and returns whether anything changed;
    - `func file(for trackID: String, ext: String = "flac") -> String?`.
  - `RecordingIndex.fileName = ".karaifyer-index.json"`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import KaraifyerCore

struct RecordingFolderTests {
    @Test func namesAreTitleThenArtist() {
        #expect(RecordingNaming.base(title: "À ma place", artist: "Zazie/Axel Bauer") == "À ma place - Zazie & Axel Bauer")
        #expect(RecordingNaming.base(title: "Intro", artist: "") == "Intro")
    }

    @Test func clashWithAnotherSongGetsASuffix() {
        let existing: [String: String?] = ["Danser - Loïc Nottet.flac": "AAA", "Danser - Loïc Nottet (2).flac": "BBB"]
        #expect(RecordingNaming.unique(base: "Danser - Loïc Nottet", trackID: "AAA", ext: "flac", existing: existing)
                == "Danser - Loïc Nottet.flac")                                   // same song keeps its name
        #expect(RecordingNaming.unique(base: "Danser - Loïc Nottet", trackID: "CCC", ext: "flac", existing: existing)
                == "Danser - Loïc Nottet (3).flac")
        #expect(RecordingNaming.unique(base: "Speed - Zazie", trackID: "X", ext: "mp3", existing: existing)
                == "Speed - Zazie.mp3")
    }

    @Test func indexRereadsOnlyNewOrChangedFiles() {
        var idx = RecordingIndex()
        var reads: [String] = []
        let read = { (n: String) -> RecordingIndex.Entry in
            reads.append(n); return .init(size: 0, mtime: 0, trackID: "id-\(n)", title: "", artist: "")
        }
        #expect(idx.refresh(listing: [("a.flac", 10, 1), ("b.flac", 20, 2)], read: read))
        #expect(reads == ["a.flac", "b.flac"])
        reads = []
        #expect(!idx.refresh(listing: [("a.flac", 10, 1), ("b.flac", 20, 2)], read: read))
        #expect(reads.isEmpty)
        #expect(idx.refresh(listing: [("a.flac", 11, 1)], read: read))            // a changed, b gone
        #expect(reads == ["a.flac"] && idx.entries["b.flac"] == nil)
        #expect(idx.entries["a.flac"]?.size == 11)
    }

    @Test func fileForATrackPrefersTheRequestedExtension() {
        var idx = RecordingIndex()
        _ = idx.refresh(listing: [("S.mp3", 1, 1), ("S.flac", 1, 1)]) { _ in .init(size: 0, mtime: 0, trackID: "T", title: "", artist: "") }
        #expect(idx.file(for: "T") == "S.flac" && idx.file(for: "T", ext: "mp3") == "S.mp3" && idx.file(for: "U") == nil)
    }

    @Test func indexRoundTripsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var idx = RecordingIndex()
        _ = idx.refresh(listing: [("a.flac", 1, 1)]) { _ in .init(size: 0, mtime: 0, trackID: "T", title: "t", artist: "a") }
        idx.save(dir: dir)
        #expect(RecordingIndex.load(dir: dir).file(for: "T") == "a.flac")
        #expect(RecordingIndex.load(dir: dir.appendingPathComponent("none")).entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail** — `swift test … --filter RecordingFolderTests`. Expected: the build fails
  because the types are undefined.

- [ ] **Step 3: Implement `RecordingFolder.swift`**

```swift
import Foundation

/// Recordings are named « Titre - Artiste » and identified by their Spotify id (the SPOTIFY_URI tag), not a number.
public enum RecordingNaming {
    public static func base(title: String, artist: String) -> String {
        let t = FileNaming.clean(title), a = FileNaming.clean(artist)
        return FileNaming.sanitize(a.isEmpty ? t : "\(t) - \(a)")
    }

    /// `base.ext`, or `base (2).ext`, `base (3).ext`… when the name holds another song. The same song keeps its name.
    public static func unique(base: String, trackID: String, ext: String, existing: [String: String?]) -> String {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(ext)" : "\(base) (\(n)).\(ext)"
            guard let owner = existing[name] else { return name }
            if owner == trackID { return name }
            n += 1
        }
    }
}

/// `.karaifyer-index.json` in a recordings folder: tags read once per file version (size + date), so matching rows
/// to files by Spotify id doesn't run ffprobe on every refresh. Deleting it only costs one re-read.
public struct RecordingIndex: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var size: Int64
        public var mtime: Double
        public var trackID: String?
        public var title, artist: String
        public init(size: Int64, mtime: Double, trackID: String?, title: String, artist: String) {
            self.size = size; self.mtime = mtime; self.trackID = trackID; self.title = title; self.artist = artist
        }
    }

    public static let fileName = ".karaifyer-index.json"
    public var entries: [String: Entry] = [:]
    public init() {}

    public static func load(dir: URL) -> RecordingIndex {
        (try? JSONDecoder().decode(RecordingIndex.self, from: Data(contentsOf: dir.appendingPathComponent(fileName))))
            ?? RecordingIndex()
    }

    public func save(dir: URL) {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic) }
    }

    public mutating func refresh(listing: [(name: String, size: Int64, mtime: Double)], read: (String) -> Entry) -> Bool {
        var changed = false
        let names = Set(listing.map(\.name))
        for gone in entries.keys where !names.contains(gone) { entries[gone] = nil; changed = true }
        for f in listing {
            if let e = entries[f.name], e.size == f.size, e.mtime == f.mtime { continue }
            var e = read(f.name)
            e.size = f.size; e.mtime = f.mtime
            entries[f.name] = e
            changed = true
        }
        return changed
    }

    public func file(for trackID: String, ext: String = "flac") -> String? {
        entries.filter { $0.value.trackID == trackID && ($0.key as NSString).pathExtension.lowercased() == ext }
            .keys.sorted().first
    }
}
```

`FileNaming.clean` is `static` (internal), which is fine inside the same module.

- [ ] **Step 4: Run the tests** — the whole Swift suite. Expected: everything passes.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/RecordingFolder.swift karaifyer/Tests/KaraifyerCoreTests/RecordingFolderTests.swift
git commit -m "Core: « Titre - Artiste » naming with clash suffix, recording index keyed by Spotify id"
```

### Task A4: Core migration planner, safe-move planner, move-offered rule

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/RecordingMigration.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/RecordingMigrationTests.swift`

**Interfaces:**
- Consumes: `RecordingNaming`, `RecordingIndex.Entry` (A3).
- Produces:
  - `RecordingMigration.outputFolder(savedRoot: String, listName: String?, dirHasRecordings: (String) -> Bool) -> String?`:
    the new output folder when the old `root/<list>` layout is found, else nil;
  - `RecordingMigration.renames(entries: [String: RecordingIndex.Entry], others: [String]) -> Plan`:
    - `Plan` is `{renames: [(from: String, to: String)], duplicates: [String]}`;
    - `others` are the folder's non-audio file names, so a `.asd` follows its `.mp3` and no rename lands on any of
      them;
    - only names with a numeric `NN - ` prefix are renamed.
  - `FolderChoice.moveOffered(current: String, new: String) -> Bool`.
  - `SafeMove.plan(files: [String], destinationNames: Set<String>) -> (move: [String], skipped: [String])`:
    moves by name, skipping names already present in the destination.

- [ ] **Step 1: Write the failing tests** (fixture names copied from the real folder)

```swift
import Testing
@testable import KaraifyerCore

struct RecordingMigrationTests {
    let e = { (id: String?, t: String, a: String) in RecordingIndex.Entry(size: 1, mtime: 1, trackID: id, title: t, artist: a) }

    @Test func oldLayoutMovesTheOutputFolderIntoTheListFolder() {
        let has = { (p: String) in p == "/Users/m/Music/SysRec/Karaoké - Feuille 1" }
        #expect(RecordingMigration.outputFolder(savedRoot: "/Users/m/Music/SysRec", listName: "Karaoké - Feuille 1",
                                                dirHasRecordings: has) == "/Users/m/Music/SysRec/Karaoké - Feuille 1")
        #expect(RecordingMigration.outputFolder(savedRoot: "/Users/m/Music/SysRec/Karaoké - Feuille 1", listName: "X",
                                                dirHasRecordings: has) == nil)
        #expect(RecordingMigration.outputFolder(savedRoot: "/r", listName: nil, dirHasRecordings: has) == nil)
    }

    @Test func numberedFilesAreRenamedFromTheirTags() {
        let p = RecordingMigration.renames(entries: [
            "05 - Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet"),
            "05 - Danser - Loïc Nottet.mp3": e("AAA", "Danser", "Loïc Nottet"),
            "03 - À ma place - Zazie & Axel Bauer.flac": e("BBB", "À ma place", "Zazie/Axel Bauer"),
        ], others: ["sysrec-log.txt"])
        #expect(Set(p.renames.map { "\($0.from)→\($0.to)" }) == [
            "05 - Danser - Loïc Nottet.flac→Danser - Loïc Nottet.flac",
            "05 - Danser - Loïc Nottet.mp3→Danser - Loïc Nottet.mp3",
            "03 - À ma place - Zazie & Axel Bauer.flac→À ma place - Zazie & Axel Bauer.flac"])
        #expect(p.duplicates.isEmpty)
    }

    @Test func asdFollowsItsMp3() {
        let p = RecordingMigration.renames(entries: ["39 - La petite église - Jean Lumière.mp3": e("C", "La petite église", "Jean Lumière")],
                                           others: ["39 - La petite église - Jean Lumière.mp3.asd"])
        #expect(p.renames.contains { $0.from == "39 - La petite église - Jean Lumière.mp3.asd" && $0.to == "La petite église - Jean Lumière.mp3.asd" })
    }

    // rows 14 and 80 of the sheet: one track recorded once, copied under a second number
    @Test func secondCopyOfATrackGetsASuffixAndIsListed() {
        let p = RecordingMigration.renames(entries: [
            "14 - Lili - Aaron.flac": e("L", "Lili", "Aaron"), "80 - Lili - Aaron.flac": e("L", "Lili", "Aaron")], others: [])
        #expect(Set(p.renames.map(\.to)) == ["Lili - Aaron.flac", "Lili - Aaron (2).flac"])
        #expect(p.duplicates == ["Lili - Aaron (2).flac"])
    }

    @Test func neverRenamesOntoAnExistingNameNorTouchesUnnumberedFiles() {
        let p = RecordingMigration.renames(entries: [
            "Danser - Loïc Nottet.flac": e("X", "Danser", "Loïc Nottet"),        // already new-style, another song
            "05 - Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet")], others: [])
        #expect(p.renames.map(\.to) == ["Danser - Loïc Nottet (2).flac"])
    }

    @Test func moveIsOfferedOnlyToAnotherFolderNotInsideTheCurrentOne() {
        #expect(FolderChoice.moveOffered(current: "/a/b", new: "/a/c"))
        #expect(!FolderChoice.moveOffered(current: "/a/b", new: "/a/b/"))
        #expect(!FolderChoice.moveOffered(current: "/a/b", new: "/a/b/sub"))
        #expect(FolderChoice.moveOffered(current: "/a/b/sub", new: "/a/b"))
        #expect(FolderChoice.moveOffered(current: "/a/b", new: "/a/bc"))
    }

    @Test func safeMoveSkipsNamesTakenAtTheDestination() {
        let r = SafeMove.plan(files: ["A.flac", "B.flac"], destinationNames: ["B.flac"])
        #expect(r.move == ["A.flac"] && r.skipped == ["B.flac"])
    }
}
```

- [ ] **Step 2: Run them to see them fail.** Expected: the build fails because the types are undefined.

- [ ] **Step 3: Implement `RecordingMigration.swift`**

```swift
import Foundation

public enum RecordingMigration {
    public struct Plan: Equatable, Sendable {
        public var renames: [Rename]
        public var duplicates: [String]
    }
    public struct Rename: Equatable, Sendable { public var from, to: String }

    public static func outputFolder(savedRoot: String, listName: String?, dirHasRecordings: (String) -> Bool) -> String? {
        guard let listName, !listName.isEmpty else { return nil }
        let sub = (savedRoot as NSString).appendingPathComponent(FileNaming.sanitize(listName))
        return dirHasRecordings(sub) ? sub : nil
    }

    static func numbered(_ name: String) -> Bool { name.range(of: #"^\d+ - "#, options: .regularExpression) != nil }

    public static func renames(entries: [String: RecordingIndex.Entry], others: [String]) -> Plan {
        // names that stay put (unnumbered audio, other files) are taken from the start
        var taken: [String: String?] = [:]
        for (n, e) in entries where !numbered(n) { taken[n] = e.trackID }
        for o in others { taken[o] = .some(nil) }
        var renames: [Rename] = [], duplicates: [String] = []
        var seenTrack: [String: Set<String>] = [:]          // trackID → extensions already given the plain name
        for n in entries.keys.sorted() where numbered(n) {
            let e = entries[n]!
            let ext = (n as NSString).pathExtension
            let base = RecordingNaming.base(title: e.title, artist: e.artist)
            let id = e.trackID ?? "?\(n)"
            // a second file of the same track must not claim the first one's name
            let owner = seenTrack[id, default: []].contains(ext) ? "dup:\(n)" : id
            let to = RecordingNaming.unique(base: base, trackID: owner, ext: ext, existing: taken)
            taken[to] = .some(owner)
            if owner != id { duplicates.append(to) } else { seenTrack[id, default: []].insert(ext) }
            renames.append(Rename(from: n, to: to))
            if ext.lowercased() == "mp3", others.contains(n + ".asd") {
                renames.append(Rename(from: n + ".asd", to: to + ".asd"))
            }
        }
        return Plan(renames: renames, duplicates: duplicates)
    }
}

public enum FolderChoice {
    public static func moveOffered(current: String, new: String) -> Bool {
        let c = URL(fileURLWithPath: current).standardizedFileURL.path, n = URL(fileURLWithPath: new).standardizedFileURL.path
        return n != c && !n.hasPrefix(c + "/")
    }
}

public enum SafeMove {
    public static func plan(files: [String], destinationNames: Set<String>) -> (move: [String], skipped: [String]) {
        (files.filter { !destinationNames.contains($0) }, files.filter { destinationNames.contains($0) })
    }
}
```

The `.asd` test may show that `others` also needs to block the renamed `.asd` name. Add each `.asd` target to
`taken` if so.

- [ ] **Step 4: Run the Swift suite.** Expected: everything passes.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/RecordingMigration.swift karaifyer/Tests/KaraifyerCoreTests/RecordingMigrationTests.swift
git commit -m "Core: recorder migration planner, move-offered rule, safe-move planner"
```

### Task A5: The recorder writes into the chosen folder, done by Spotify id, new names

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/QueueModel.swift`:
  - `listDir`;
  - `directory(for:)`;
  - `existingFile(for:)`;
  - `refreshDoneStates`;
  - `process(_:)`, both the duplicate branch and the finalize naming;
  - `log`;
  - the start of `runBatch`.
- Create: `karaifyer/Sources/Karaifyer/RecordingTags.swift` (ffprobe tag reader)

**Interfaces:**
- Consumes: `RecordingNaming`, `RecordingIndex` (A3).
- Produces:
  - `QueueModel.index(for dir: URL) -> RecordingIndex`, refreshed and saved;
  - `RecordingTags.read(_ url: URL) -> RecordingIndex.Entry`, which reads `SPOTIFY_URI`, `title` and `artist` with
    `ffprobe -show_entries format_tags`.

- [ ] **Step 1: Implement**
  - **`listDir` is `outputRoot` itself.** Remove the CSV-name subfolder; `directory(for:)` keeps the per-proposer
    subfolder.
  - **`existingFile(for:)`** returns `index(for: dir).file(for: row.trackID).map { dir.appendingPathComponent($0) }`.
  - **`index(for:)`:**
    - list `*.flac` and `*.mp3`, with size and modification date, through
      `FileManager.contentsOfDirectory(at:includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])`;
    - call `refresh(listing:read:)` with `RecordingTags.read`;
    - `save(dir:)` when it changed;
    - cache it per directory in the model for the session (`@ObservationIgnored private var indexes: [URL: RecordingIndex]`).
  - **Duplicate rows** (`row.duplicateOf`): no copy. They're done when `existingFile` finds the track, which
    `refreshDoneStates` already does. Remove the copy branch in `process`. A duplicate row reached in a batch while
    its source is done gets `.done`, with the note « même morceau que la ligne N ».
  - **Naming in `process` (finalize):** `let name = RecordingNaming.unique(base: RecordingNaming.base(title: row.title.isEmpty ? meta.title : row.title, artist: row.artist.isEmpty ? meta.artist : row.artist), trackID: row.trackID, ext: "flac", existing: index(for: dir).entries.mapValues(\.trackID))`;
    `outputBase = dir.appendingPathComponent((name as NSString).deletingPathExtension)`. The MP3 gets the same base,
    since `PostProcess` derives it. After finalize, refresh the index for `dir`.
  - **`runBatch` start:** `log("— Lot « \(listName) » (\(rows.count) morceaux) —")`.
  - `numberWidth` stays only for display, if it's still used anywhere. Remove it when the compiler shows it unused.

- [ ] **Step 2: Build and run the whole Swift suite**

Run: `swift build --package-path karaifyer && swift test …`
Expected: the build succeeds and everything passes.

- [ ] **Step 3: Check against a copy, never the real folder**

1. Copy 3 FLACs from `~/Music/SysRec/Karaoké - Feuille 1` into a scratch folder.
2. Run a tiny Swift snippet, or `swift test` with a temporary test that is not committed, which builds the index with
   `RecordingTags.read`.
3. Expected: 3 entries with 22-character track ids.

- [ ] **Step 4: Commit**

```bash
git add karaifyer/Sources/Karaifyer/QueueModel.swift karaifyer/Sources/Karaifyer/RecordingTags.swift
git commit -m "Recorder: files go straight into the chosen folder, named « Titre - Artiste », done by Spotify id"
```

### Task A6: « Change… » with move / use without moving / Annuler

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/KaraifyerApp.swift` (`QueueView.chooseOutput`)
- Modify: `karaifyer/Sources/Karaifyer/QueueModel.swift` (`recordedFiles`, `moveRecordings`)

**Interfaces:**
- Consumes: `FolderChoice.moveOffered`, `SafeMove.plan` (A4).

- [ ] **Step 1: Implement**
  - **`chooseOutput`:**
    1. Run the panel.
    2. If it was cancelled, return. **Nothing changes.**
    3. Let `old = model.listDir`, `new = url`.
    4. If `FolderChoice.moveOffered(old, new)` and `recordedFiles(in: old)` isn't empty, show an alert:
       - message: « Déplacer les N enregistrements vers ce dossier ? »;
       - informative text naming both folders;
       - buttons « Déplacer les fichiers », « Utiliser sans déplacer » and « Annuler » (`keyEquivalent = "\u{1b}"`).
    5. Set `model.outputRoot = new` **only** after « Déplacer » or « Utiliser ». On « Déplacer », call
       `model.moveRecordings(from: old)` before switching.
  - **`recordedFiles`:** `.flac`, `.mp3`, `.mp3.asd`, `sysrec-log.txt`, `RecordingIndex.fileName`.
  - **`moveRecordings(from:to:)`:**
    - names come from `SafeMove.plan`;
    - when both folders are on the same volume, use `FileManager.moveItem`;
    - otherwise, copy, compare sizes, re-apply the modification date, then remove the source.
    - The log is appended to the destination's log, not moved over it, when the destination already has one.
    - It returns `(moved: [(old: URL, new: URL)], skipped: [String])`. The pairs feed `karaoke relocaliser` in A7.
  - **After a move:** run `karaoke relocaliser` with the moved audio pairs, using the same call as A7
    (`QueueModel.relocate(_:)`). This keeps the manifest right even here.

- [ ] **Step 2: Build and run the Swift suite.** Expected: the build succeeds and everything passes.

- [ ] **Step 3: Commit** — `git commit -m "Recorder « Change… »: move / use without moving / Annuler; the folder changes only on confirm"`

### Task A7: « Déplacer vers… » on selected rows; « Retrouver les enregistrements… » in the Karaoké tab

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/KaraifyerApp.swift`, adding to `QueueView` the table's `selection` and a
  `.contextMenu(forSelectionType:)`
- Modify: `karaifyer/Sources/Karaifyer/QueueModel.swift` (`move(rows:to:)`, `relocate(_:)`)
- Modify: `karaifyer/Sources/Karaifyer/KaraokeModel.swift`, `KaraokeView.swift` (the banner button and `retrouver`)

**Interfaces:**
- Consumes:
  - `karaoke relocaliser --json` (stdin) and `karaoke retrouver --dossier D [--plan] --json` (A2);
  - `moveRecordings`-style safe moving (A6).
- Produces:
  - `QueueModel.move(rows: [TrackRow], to: URL) async -> String`, returning a summary line for the banner;
  - `QueueModel.relocate(_ pairs: [(URL, URL)]) async`.

- [ ] **Step 1: Implement**
  - **Selection:** `QueueView` gets `@Bindable` selection storage (`QueueModel.selection: Set<Int>`) and
    `Table(model.rows, selection: $model.selection)`.
  - **Context menu:** « Déplacer vers… » runs an `NSOpenPanel` (folders, `canCreateDirectories`), then an alert:
    - « Déplacer N enregistrement(s) vers « <dossier> » ? Les lignes déplacées apparaîtront « à enregistrer » tant
      que le dossier de sortie n'est pas celui-ci. »;
    - buttons « Déplacer » and « Annuler ».
    - It's disabled while `model.isRunning || KaraokeModel.shared.locked`.
  - **`move(rows:to:)`:**
    - for each row, take its FLAC, MP3 and `.asd`, through `existingFile` and its siblings;
    - move them safely;
    - refresh both indexes;
    - log every move in the source folder's log;
    - call `relocate`.
  - **`relocate`:**
    - runs `Pipeline().run(["relocaliser", "--json"])` with the pairs as a JSON object on stdin, through
      `EditorModel.runProcess(args:env:cwd:input:)` with `Pipeline().args(["relocaliser", "--json"])`;
    - logs « Manifeste : N ligne(s) mises à jour »;
    - refreshes `KaraokeModel.shared`.
  - **Karaoké tab:**
    - When any song's `fichier` is missing (`!FileManager.default.fileExists(atPath: s.fichier)`), the banner area
      shows « N enregistrement(s) introuvable(s) » with a « Retrouver… » button. The button is hidden while
      `model.locked`.
    - « Retrouver… » runs a folder panel, then `retrouver --plan --json`, then an alert listing the « id titre → nom
      du fichier » matches with « Mettre à jour » / « Annuler ». On confirm it runs `retrouver --json` (apply) and
      refreshes.
    - No match: an alert « Aucun enregistrement retrouvé dans ce dossier ».

- [ ] **Step 2: Build and run both suites.** Expected: the build succeeds and both suites pass.

- [ ] **Step 3: Commit** — `git commit -m "Enregistrement: « Déplacer vers… » (manifest follows); Karaoké: « Retrouver les enregistrements… »"`

### Task A8: One-time recorder migration sheet

**Files:**
- Create: `karaifyer/Sources/Karaifyer/RecorderMigrationSheet.swift`
- Modify: `karaifyer/Sources/Karaifyer/QueueModel.swift` (`migrationPlan()`, `migrate(_:)`), `KaraifyerApp.swift`
  (sheet on `QueueView`)

**Interfaces:**
- Consumes: `RecordingMigration.outputFolder` / `renames` (A4), the index (A3), `relocate` (A7).

- [ ] **Step 1: Write the failing test for re-running after an interruption** (Review Focus 5), in
  `RecordingMigrationTests`:

```swift
    // drive unplugged half-way: files already renamed are unnumbered, the rest are still numbered
    @Test func rerunAfterInterruptionFinishesWithoutDoubleRenaming() {
        let p = RecordingMigration.renames(entries: [
            "Danser - Loïc Nottet.flac": e("AAA", "Danser", "Loïc Nottet"),
            "06 - La lettre - Renan Luce.flac": e("BBB", "La lettre", "Renan Luce")], others: [])
        #expect(p.renames == [.init(from: "06 - La lettre - Renan Luce.flac", to: "La lettre - Renan Luce.flac")])
    }
```

Run it. It should already pass, because planning only renames numbered names. If it fails, fix `renames`.

- [ ] **Step 2: Implement**
  - **`migrationPlan()`** returns nil when `UserDefaults` `recorderMigrationDone` is set, or when there's nothing to
    do. Otherwise it returns:
    - the new output folder, from `outputFolder(savedRoot: outputRoot.path, listName: listURL's name, …)`, where
      "has recordings" means the folder contains at least one `.flac`;
    - the rename plan for that folder, from its refreshed index plus the non-audio names.
  - **The sheet:**
    - title « Nouveaux noms des enregistrements »;
    - text: « Les fichiers s'appelleront « Titre - Artiste », sans numéro. Le dossier de sortie devient « … ». Le
      manifeste karaoké suit (une copie est gardée). »;
    - a scrolling list of « ancien → nouveau » (`monospacedDigit`), and the duplicates listed in orange as « copie
      en double, à supprimer vous-même »;
    - buttons « Plus tard » (cancel, Escape) and « Mettre à jour ».
  - **`migrate(_:)`:**
    1. Set `outputRoot`.
    2. For each rename in order, run `FileManager.moveItem` (same folder), logging `ancien → nouveau` in
       `sysrec-log.txt`. A failure stops the loop and shows the error; a later launch offers the rest, since the plan
       is recomputed.
    3. Refresh the index.
    4. Call `relocate` with the audio pairs.
    5. Set `recorderMigrationDone` only when every rename succeeded.
  - **Presentation:** from `QueueView.onAppear`, through `QueueUI.shared.migration` (an observable holder, following
    `KaraokeUI`).

- [ ] **Step 3: Dry run on the real folder (read-only)**

Write a temporary test, not committed, that builds the plan for `~/Music/SysRec/Karaoké - Feuille 1` using
`RecordingTags.read`, and prints the renames and duplicates. Expected:
- 85 FLAC renames, plus the MP3s and the one `.asd`;
- no target equal to an existing name;
- duplicates only where two files share a track id.

Paste the summary into the ledger. **Do not run `migrate` on real data.**

- [ ] **Step 4: Build, both suites, commit**

```bash
git add karaifyer/Sources/Karaifyer/RecorderMigrationSheet.swift karaifyer/Sources/Karaifyer/QueueModel.swift karaifyer/Sources/Karaifyer/KaraifyerApp.swift karaifyer/Tests/KaraifyerCoreTests/RecordingMigrationTests.swift
git commit -m "Recorder: one-time migration sheet (output folder, « Titre - Artiste » names, manifest follows)"
```

### Task A9: Docs, build, install

- [ ] **Step 1: Update the guide.** In `docs/guide/GUIDE.md`, rewrite the Enregistrement section's folder, naming and
  « done » paragraphs, and add:
  - « Change… » (three choices);
  - « Déplacer vers… »;
  - « Retrouver les enregistrements… »;
  - the migration sheet.

  In French, in the guide's style.
- [ ] **Step 2: Build and install** — `karaifyer/build-app.sh --install` in the background. Expected: « Installed
  ~/Applications/Karaifyer.app ».
- [ ] **Step 3: Commit** — `git commit -m "Guide: recordings named « Titre - Artiste », folder choice, move, retrieve"`

### Gate A: subagent review of Part A

- [ ] **Step 1:** `review-package` with the plan, the merge base (the `dossier-karaoke` tip), and HEAD.
- [ ] **Step 2:** Dispatch a reviewer (model **opus**) with:
  - superpowers:requesting-code-review's `code-reviewer.md`;
  - the package path, the plan and the spec;
  - Review Focus items 1, 2, 3 and 5 verbatim;
  - the ledger's `Ruling:` lines.

  Scope: Part A only.
- [ ] **Step 3:** Re-grade the findings by their effect on Michel.
  - **Critical and Important:** one fix pass, each fix RED→GREEN, whole suites green, ledgered.
  - **Minor:** ledgered as deferred.
- [ ] **Step 4:** Ledger `Gate A: passed (<review summary>)`, rebuild and install if anything was fixed, and **continue
  to Part B without asking**.

---

## PART B — The karaoke outputs

### Task B1: `dossier` column, unique `Titre - Artiste` names

**Files:**
- Modify: `karaoke/src/karaoke/manifest.py`:
  - `COLUMNS`;
  - `Song`, with `dossier: str = ""` after `spotify`;
  - `_parse_row`;
  - `write_manifest`;
  - `songs_from_sysrec`;
  - `songs_from_files`.
- Modify: `karaoke/src/karaoke/workspace.py`:
  - `folder_name`: `song.dossier or legacy`;
  - a new `display_name(titre, artiste)`;
  - a new `unique_dossier(song, taken)`.
- Test: `karaoke/tests/test_dossier.py`

**Interfaces:**
- Produces:
  - `workspace.display_name(titre: str, artiste: str) -> str`, a port of `RecordingNaming.base`:
    - `A/B` → `A & B`;
    - wrapping parentheses removed;
    - `:` → ` -`;
    - `/ \ ? * " < > |` removed;
    - whitespace collapsed;
    - ` .` trimmed;
    - at most 200 characters.
  - `workspace.unique_dossier(name: str, sid: str, taken: dict[str, str]) -> str`, where `taken` maps each folder name
    to its song id, giving `name`, `name (2)`, …;
  - `Workspace.folder_name(song)`, which returns `song.dossier` when set, else the legacy `<id>_<slug>_<slug>`.

- [ ] **Step 1: Write the failing tests**

```python
from karaoke.manifest import read_manifest, write_manifest, songs_from_files, COLUMNS
from karaoke.workspace import Workspace, display_name, unique_dossier
from test_manifest import song


def test_display_name_matches_the_recorder():
    assert display_name("À ma place", "Zazie/Axel Bauer") == "À ma place - Zazie & Axel Bauer"
    assert display_name("Dis: quand?", "(Barbara)") == "Dis - quand - Barbara"


def test_unique_dossier_suffixes_other_songs_only():
    taken = {"Danser - Loïc Nottet": "050"}
    assert unique_dossier("Danser - Loïc Nottet", "050", taken) == "Danser - Loïc Nottet"
    assert unique_dossier("Danser - Loïc Nottet", "200", taken) == "Danser - Loïc Nottet (2)"


def test_dossier_column_round_trips_and_defaults_to_legacy(cfg, tmp_path):
    write_manifest(cfg.manifest, [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet"),
                                  song(id="011")])
    a, b = read_manifest(cfg.manifest)
    assert COLUMNS[-1] == "dossier" and a.dossier == "Danser - Loïc Nottet"
    assert Workspace(cfg, a).out == cfg.sortie / "Danser - Loïc Nottet"
    assert Workspace(cfg, b).out.name == "011_zazie_je-suis-un-homme"          # unmigrated row: unchanged


def test_manifest_without_the_column_still_reads(cfg):
    cfg.manifest.write_text(",".join(COLUMNS[:-1]) + "\n" + "005,T,A,,1,,/x.flac,,2,fr,,\n", encoding="utf-8")
    assert read_manifest(cfg.manifest)[0].dossier == ""


def test_added_songs_get_a_unique_readable_folder(cfg, tmp_path):
    existing = [song(id="050", titre="Danser", artiste="Loïc Nottet", dossier="Danser - Loïc Nottet")]
    f = tmp_path / "x.flac"; f.write_bytes(b"")
    added, _ = songs_from_files([f], existing)
    assert added[0].dossier == display_name(added[0].titre, added[0].artiste)
```

- [ ] **Step 2: Run them to see them fail.** Expected: ImportError on `display_name`.

- [ ] **Step 3: Implement.**
  - Add `"dossier"` to `COLUMNS` and `dossier=(row.get("dossier") or "").strip()` in `_parse_row`.
  - Write it in `write_manifest`'s row.
  - In `songs_from_files` and `songs_from_sysrec`, set `dossier=unique_dossier(display_name(t, a), sid, taken)`,
    where `taken` is built from the existing rows plus the rows added so far.
  - Put `display_name` and `unique_dossier` in `workspace.py`, next to `slug`.
- [ ] **Step 4: Run the suite.** Expected: everything passes. Existing tests that build `Song(...)` positionally may need
  the new keyword-only default; fix them in the same commit.
- [ ] **Step 5: Commit** — `git commit -m "manifest: dossier column, « Titre - Artiste » output folder names"`

### Task B2: Look folders up by `dossier`, not by id prefix

**Files:**
- Modify:
  - `karaoke/src/karaoke/steps/set_ableton.py` (`remove_stale_sets`);
  - `karaoke/src/karaoke/retirer.py` (`_analyse`);
  - `karaoke/src/karaoke/state.py` (paths, already via `ws.out`, so check it);
  - `karaoke/src/karaoke/cli.py` (`sets`, `traiter`'s `adopt_previous_folder`).
- Test: extend `karaoke/tests/test_retirer.py` and the set tests (`grep -l remove_stale_sets karaoke/tests`).

- [ ] **Step 1: Write the failing tests**
  - « Retirer » of a song with `dossier="Danser - Loïc Nottet"` trashes `sortie/Danser - Loïc Nottet` and
    `sets/a/Danser - Loïc Nottet.als`.
  - It still trashes a legacy `sortie/050_*` / `sets/*/050_*.als` when present.
  - `remove_stale_sets` removes `sets/old-partie/Danser - Loïc Nottet.als` when the current set is
    `sets/new-partie/Danser - Loïc Nottet.als`, and never touches `Danser - Loïc Nottet (2).als`, which is another
    song.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement**
  - **`_analyse`:** `[travail/<id>, sortie/<folder_name>] + sets/*/<folder_name>.als`, plus the legacy globs
    `sortie/<id>_*`, `sets/*/<id>_*.als`, deduplicated.
  - **`remove_stale_sets`:** remove `sets/*/<ws.out.name>.als` other than `keep`, plus legacy `*/<id>_*.als`.
  - **`traiter`:** keep `adopt_previous_folder` only for rows with an empty `dossier`.
- [ ] **Step 4: Run the suite, then commit** — `git commit -m "Outputs found by dossier, not by id prefix (sets, retirer)"`

### Task B3: `modifier` titre/artiste renames the folder and the sets

**Files:**
- Modify: `karaoke/src/karaoke/manifest.py` (`set_field`), or a wrapper in `cli.modifier`
- Test: `karaoke/tests/test_dossier.py`

- [ ] **Step 1: Write the failing tests**
  - Changing the title of a migrated song (`dossier="Danser - Loïc Nottet"`, with `sortie/Danser - Loïc Nottet/` and
    `sets/a/Danser - Loïc Nottet.als` existing) to « Danse » gives:
    - the manifest `dossier` « Danse - Loïc Nottet »;
    - the folder and the set renamed;
    - the old names gone.
  - **Review Focus 4:** a song whose output folder doesn't exist (never analysed) gets its new `dossier` and no error.
  - When another song already owns « Danse - Loïc Nottet », the edited one becomes « Danse - Loïc Nottet (2) » and the
    other's folder is untouched.
  - A legacy row (`dossier` empty) gets a `dossier` on its first title edit, and its `<id>_…` folder is renamed.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** a `renommer_dossier(cfg, sid)` in `workspace.py`, called by `cli.modifier` after
  `set_field` when `champ in ("titre", "artiste")`:
  - compute the new unique name;
  - if `sortie/<old>` exists and `sortie/<new>` doesn't, `rename` it;
  - rename each `sets/*/<old>.als` to `<new>.als` in the same folder;
  - write `dossier`.
- [ ] **Step 4: Run the suite, then commit** — `git commit -m "modifier: a title/artist edit renames the output folder and sets"`

### Task B4: `karaoke migrer-sorties`

**Files:**
- Create: `karaoke/src/karaoke/migrer_sorties.py`
- Modify: `karaoke/src/karaoke/cli.py`
- Test: `karaoke/tests/test_migrer_sorties.py`

**Interfaces:**
- Produces:
  - `migrer_sorties.plan(cfg) -> list[dict]`, one dict per song: `{"id", "ancien", "nouveau"}`;
  - `migrer_sorties.appliquer(cfg, trash=system_trash) -> dict`, returning `{"renommes": n, "sauvegarde": path, "sets": n}`;
  - the CLI `karaoke migrer-sorties [--plan] --json`.

- [ ] **Step 1: Write the failing tests**, in a throwaway home with two analysed-looking songs:
  - Each song has `sortie/<id>_x_y/`, a set `sets/a/<id>_x_y.als`, and `travail/<id>/` with fake markers, where the
    video and package markers are up to date per `inspect_song`.
  - `plan` lists both renames and changes nothing.
  - `appliquer` gives:
    - the folders renamed;
    - the manifest `dossier` filled, with a backup;
    - the old `.als` passed to the fake trash;
    - `inspect_song` showing video, package and earlier steps still `a_jour`, and only the set step not up to date.
  - Monkeypatch `run_song` to record calls: the set step runs, with `only={"set"}`, for each song.
  - **Review Focus 5:** running `appliquer` twice renames nothing the second time and doesn't make a second backup.
  - It is refused (ValueError) while `cfg.home / "travail" / <id> / ".lock"` is held, if `run_song` uses such a lock.
    Read `runner.py:62-70` for the lock name; skip this case if there is none, and ledger the ruling.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.**
  - **`plan`:** for rows with an empty `dossier`, compute `unique_dossier(display_name(titre, artiste), id, taken)`,
    where `taken` comes from the rows that already have one, plus the names assigned so far.
  - **`appliquer`:**
    1. If `plan` is empty, return zeros.
    2. Back up the manifest (`manifeste.avant-noms-<date>.csv`).
    3. For each song, rename `sortie/<legacy>` to `sortie/<new>` if it exists and the target doesn't.
    4. Write the manifest with the `dossier` values.
    5. For each song with a `package` marker, run `run_song(Workspace(cfg, s), STEPS, only={"set"})`, which writes
       `sets/<partie>/<new>.als`.
    6. Trash the legacy `sets/*/<id>_*.als`.
  - The CLI prints the plan, or applies it.
- [ ] **Step 4: Dry run on the real data.**

Run: `KARAOKE_HOME=/Volumes/Hypermnesia/karaoke uv --directory karaoke run karaoke migrer-sorties --plan --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d)); print(d[:3])"`

Expected:
- one entry per manifest row;
- no two identical `nouveau` values;
- no `/private/tmp` anywhere.

Paste the summary into the ledger. **Do not apply on real data.**
- [ ] **Step 5: Run the suite, then commit** — `git commit -m "karaoke migrer-sorties: rename outputs to « Titre - Artiste », rebuild sets only"`

### Task B5: Karaoké tab migration banner and sheet; docs; build

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/KaraokeModel.swift`, `KaraokeView.swift`
- Modify: `docs/guide/GUIDE.md`

- [ ] **Step 1: Implement**
  - **After `refresh()`:** if any song's `paths.dossier` last path component matches `^\d{3}_`, run
    `migrer-sorties --plan --json` once per session. When it's not empty, show a banner « Les dossiers de sortie
    peuvent prendre le nom « Titre - Artiste » » with a « Renommer… » button. The button is disabled while `locked`.
  - **The sheet:**
    - lists `ancien → nouveau`;
    - warns « Fermez d'abord les sets ouverts dans Ableton Live. Les sets sont refaits (quelques secondes par
      morceau) ; rien d'autre n'est réanalysé. »;
    - buttons « Plus tard » and « Renommer ».
  - **On « Renommer »:** run `migrer-sorties --json`, with progress through `appendLog`, then refresh.
  - **The guide:** output folder names, the banner, and that internal files keep the id.
- [ ] **Step 2: Build, both suites, install in the background.** Expected: everything passes and the app is installed.
- [ ] **Step 3: Commit** — `git commit -m "Karaoké tab: rename output folders to « Titre - Artiste » (banner + sheet); guide"`

### Gate B: subagent review of Part B

- [ ] **Step 1:** `review-package` from the Gate A HEAD to HEAD.
- [ ] **Step 2:** Dispatch a reviewer (model **opus**) with:
  - `code-reviewer.md`, the package, the plan and the spec;
  - Review Focus items 1, 4 and 5 verbatim;
  - the `Ruling:` lines.

  Scope: Part B.
- [ ] **Step 3:** Re-grade, then one fix pass (TDD) for Critical and Important; ledger the Minors as deferred.
- [ ] **Step 4:** Ledger `Gate B: passed`, rebuild and install if anything changed.

### Finish

- [ ] Delete this plan's `.superpowers/sdd/` workspace.
- [ ] Report the rulings and deferred minors, and list the two migrations Michel runs from the app:
  1. the recorder sheet at launch;
  2. the Karaoké tab banner, after closing Live.
- [ ] Present the finishing options (merge / PR / keep). **No merge or push without Michel asking.**
