# Karaifyer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Karaifyer, a macOS app that copies SysRec's Spotify recorder and adds a Karaoké tab to drive the `karaoke` pipeline. In that tab you edit the manifest, add songs, run the analysis (with pause and stop), follow progress and logs, open the results, and correct lyrics and chords by ear.

**Architecture:**
- **Python side:** the pipeline stays in Python. It gains four commands (`traiter --json`, `etat --json`, `ajouter`, `modifier`) and support for corrected chord charts (`accords/<id>.txt`).
- **Swift side:** the new package `karaifyer/` holds a copy of SysRec plus:
  - a UI-free `KaraifyerCore` library: pipeline JSON decoding, LRC, chord grid, the run state machine and the time-left estimate, all unit-tested;
  - the SwiftUI views and process plumbing in the `Karaifyer` app target.
- **One process per song:** the app runs one `uv run karaoke traiter --ids <id> --json` process per song, in its own process group, so it can pause (SIGSTOP), resume (SIGCONT) and stop (SIGTERM, then SIGKILL).

**Tech Stack:**
- Python 3.11 + uv + pytest (existing `karaoke/` project).
- Swift 6 / SwiftPM, built with Command Line Tools only (no Xcode, no `@State`).
- SwiftUI and Observation, AVFoundation (`AVAudioPlayer`), `posix_spawn`.
- Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-13-karaifyer-design.md`

## Global Constraints

- **SysRec is not modified:** `Sources/`, `Tests/`, `Package.swift`, `build-app.sh`, `Resources/` and `SysRec.app` stay byte-identical. Karaifyer lives in `karaifyer/` only.
- **Bundle:** id `com.akkaouim.karaifyer`, name **Karaifyer**, macOS 26.0 minimum (same as SysRec).
- **No Xcode:** no `@State` (it is a macro whose plugin ships with Xcode only). Use stored `@Observable` models, as SysRec does.
- **Swift tests** run with `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
- **Python tests** run with `uv --directory karaoke run pytest -q`. Every existing test stays green.
- **UI language:** French (Michel's), as in the pipeline's messages. Code comments are in English.
- **Corrections survive re-runs:** `paroles/<id>.lrc` and `accords/<id>.txt` are never overwritten by the pipeline.
- **PATH for GUI launches:** GUI apps don't get the shell PATH, so every command the app launches gets `PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin`. ffmpeg and uv live in `/opt/homebrew/bin`.

## Review Focus

1. **Stop now during a step, then Analyser again.** The interrupted step must rerun and not be reported as done. The runner deletes markers before running, so check that SIGTERM leaves no half-written marker. The Task 6 test `test_traiter_json_events` covers the event stream; the Task 14 manual check covers the signal.
2. **Michel edits a manifest cell to an invalid value** (for example `retirer` gets an unknown stem by a bug). `modifier` refuses it with a French message, the CSV is left untouched, and the app shows the message. Test in Task 4.
3. **A corrected chord grid whose bar count doesn't match the detection** (bars added or removed by hand in the file). The chords step fails with a clear message rather than misplacing chords. Test in Task 5.
4. **Adding a file that is already in the manifest, or a file without tags.** It is skipped and reported, or titled from its file name. Test in Task 3.
5. **Pausing for hours (overnight), then resuming.** The process group still exists and continues. `RunController` must not time out a paused job. Test in Task 9.

---

## File Structure

**Python (`karaoke/`)**
- `src/karaoke/runner.py`: modify. Add an `on_event` callback to `run_song`, and add `inspect_song` (up-to-date check without running).
- `src/karaoke/workspace.py`: modify. Add an optional `on_log` listener.
- `src/karaoke/manifest.py`: modify. Add `next_id`, `songs_from_files`, `set_field` and an atomic `write_manifest`.
- `src/karaoke/chords.py`: modify. Richer chord symbols, `parse_cell`, `parse_chart`, `expand`.
- `src/karaoke/ireal.py`: modify. Map the richer symbols to iReal syntax.
- `src/karaoke/steps/chords.py`: modify. Read `accords/<id>.txt` when present.
- `src/karaoke/config.py`: modify. Add the `accords` directory.
- `src/karaoke/state.py`: create. Builds `etat` (per-song state JSON).
- `src/karaoke/cli.py`: modify. `traiter --json`, `etat`, `ajouter`, `modifier`.
- Tests: `tests/test_events.py`, `tests/test_state.py`, `tests/test_ajouter.py`, `tests/test_modifier.py`, `tests/test_chord_override.py` (new). `tests/test_ireal.py` and `tests/test_chords.py` are extended.

**Swift (`karaifyer/`)**
- `Package.swift`, `build-app.sh`, `Resources/Info.plist`: new, adapted from SysRec's.
- `Sources/KaraifyerCore/`:
  - copied: `CSV.swift`, `TrackList.swift`, `TrimMath.swift`;
  - new: `PipelineModels.swift`, `LRC.swift`, `ChordGrid.swift`, `RunController.swift`, `Estimate.swift`.
- `Sources/Karaifyer/`:
  - copied: `AudioCapturePermission.swift`, `CoreAudioUtils.swift`, `PostProcess.swift`, `QueueModel.swift`, `SpotifyController.swift`, `SystemAudioTap.swift`;
  - `KaraifyerApp.swift`: from SysRecApp.swift, adds tabs;
  - new: `Spawn.swift`, `Pipeline.swift`, `KaraokeModel.swift`, `KaraokeView.swift`, `EditorModel.swift`, `EditorView.swift`, `SettingsView.swift`.
- `Tests/KaraifyerCoreTests/`:
  - copied: `TrackListTests.swift` and `Fixtures/karaoke.csv`;
  - new: `PipelineModelsTests.swift`, `LRCTests.swift`, `ChordGridTests.swift`, `RunControllerTests.swift`.
- `README.md` (Karaifyer usage) and `docs/karaoke/karaifyer-validation.md` (manual checklist).

---

### Task 1: `traiter --json` (event stream)

**Files:**
- Modify: `karaoke/src/karaoke/workspace.py` (`Workspace.__init__`, `log`)
- Modify: `karaoke/src/karaoke/runner.py` (`run_song`)
- Modify: `karaoke/src/karaoke/cli.py` (`traiter`)
- Test: `karaoke/tests/test_events.py`

**Interfaces:**
- Produces:
  - `run_song(ws, steps, force=frozenset(), only=None, on_event: Callable[[dict], None] | None = None)`;
  - the events, one JSON object per stdout line:
    - `{"event":"song_start","id"}`
    - `{"event":"step_start","id","step"}`
    - `{"event":"step_end","id","step","status","seconds","error"}`
    - `{"event":"log","id","line"}`
    - `{"event":"song_end","id","statut"}`
  - `Workspace.on_log: Callable[[str], None] | None`.

- [ ] **Step 1: Write the failing test**

```python
# karaoke/tests/test_events.py
import json
from karaoke.runner import Step, run_song
from karaoke.workspace import Workspace
from test_manifest import song


def test_run_song_emits_step_events_and_logs(cfg):
    ws = Workspace(cfg, song())
    a = Step(name="a", deps=(), key=lambda ws: "k", run=lambda ws, up: {"x": 1})
    b = Step(name="b", deps=("a",), key=lambda ws: "k", run=lambda ws, up: 1 / 0)
    events = []
    ws.on_log = lambda line: events.append({"event": "log", "line": line})
    run_song(ws, [a, b], on_event=events.append)
    kinds = [(e["event"], e.get("step"), e.get("status")) for e in events if e["event"] != "log"]
    assert kinds == [("step_start", "a", None), ("step_end", "a", "fait"),
                     ("step_start", "b", None), ("step_end", "b", "echec")]
    end_b = [e for e in events if e.get("step") == "b" and e["event"] == "step_end"][0]
    assert "ZeroDivisionError" in end_b["error"] and end_b["id"] == "001" and end_b["seconds"] >= 0
    assert any(e["event"] == "log" and "début a" in e["line"] for e in events)


def test_skipped_steps_also_reported(cfg):
    ws = Workspace(cfg, song())
    a = Step(name="a", deps=(), key=lambda ws: "k", run=lambda ws, up: {"x": 1})
    run_song(ws, [a])
    events = []
    run_song(ws, [a], on_event=events.append)
    assert [(e["event"], e["status"]) for e in events if e["event"] == "step_end"] == [("step_end", "saute")]


def test_traiter_json_prints_one_json_object_per_line(cfg, monkeypatch, capsys):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.manifest import write_manifest
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song()])
    monkeypatch.setattr(cli, "STEPS", [Step(name="a", deps=(), key=lambda ws: "k", run=lambda ws, up: {})])
    r = CliRunner().invoke(cli.app, ["traiter", "--ids", "001", "--json"])
    assert r.exit_code == 0, r.output
    objs = [json.loads(l) for l in r.output.splitlines() if l.strip()]
    assert objs[0] == {"event": "song_start", "id": "001"}
    assert objs[-1]["event"] == "song_end" and objs[-1]["statut"] == "ok"
    assert {"event", "id", "step", "status", "seconds", "error"} <= set(
        next(o for o in objs if o["event"] == "step_end"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv --directory karaoke run pytest tests/test_events.py -q`
Expected: FAIL, with `TypeError: run_song() got an unexpected keyword argument 'on_event'` and the CLI test exiting 2 (`No such option: --json`).

- [ ] **Step 3: Implement**

In `workspace.py`, add `self.on_log = None` at the end of `Workspace.__init__`, and make `log` call it:

```python
    def log(self, msg: str) -> None:
        with open(self.work / "journal.log", "a", encoding="utf-8") as f:
            f.write(f"[{datetime.now().isoformat(timespec='seconds')}] {msg}\n")
        if self.on_log:
            self.on_log(msg)
```

(If `self.work` might not exist when `log` runs, keep the existing behaviour. Don't add mkdir here: the runner already creates it.)

In `runner.py`, change the signature to add `on_event: Callable[[dict], None] | None = None`, and add a local helper at the top of `run_song`:

```python
    def emit(step: str, status: str | None = None):
        if on_event is None:
            return
        e = out.get(step, {}) if status else {}
        ev = {"event": "step_end" if status else "step_start", "id": ws.song.id, "step": step}
        if status:
            ev.update(status=status, seconds=round(e.get("seconds", 0.0), 2), error=e.get("error", ""))
        on_event(ev)
```

Then:
- call `emit(step.name, out[step.name]["status"])` right after every assignment to `out[step.name]` (the blocked, skipped, done, retry and failure branches);
- call `emit(step.name)` just before `ws.log(f"début {step.name}")`.

In `cli.py`, add `json_out: bool = typer.Option(False, "--json", help="Événements JSON (pour Karaifyer)")` to `traiter`. In the per-song loop:

```python
        if json_out:
            emit = lambda ev: typer.echo(json.dumps(ev, ensure_ascii=False))
            ws.on_log = lambda line, sid=s.id: emit({"event": "log", "id": sid, "line": line})
            emit({"event": "song_start", "id": s.id})
        else:
            typer.echo(f"▶ {s.id} {s.artiste} – {s.titre}")
        res = run_song(ws, STEPS, force=_csv_set(forcer) or set(), only={etape} if etape else None,
                       on_event=emit if json_out else None)
        rep = song_report(s, res)
        ...  # existing rapport.json write
        if json_out:
            emit({"event": "song_end", "id": s.id, "statut": rep["statut"]})
        else:
            typer.echo("   " + ...)  # existing line
```

When `json_out` is set, skip the final « Rapport : » and « iReal Pro : » echoes, but still write them. A `log` event's line is the journal message (`début separate`, `échec …`).

- [ ] **Step 4: Run tests**

Run: `uv --directory karaoke run pytest -q`
Expected: all pass (existing 152 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/runner.py karaoke/src/karaoke/workspace.py karaoke/src/karaoke/cli.py karaoke/tests/test_events.py
git commit -m "karaoke: traiter --json event stream (for Karaifyer)"
```

---

### Task 2: `etat --json` (state without running)

**Files:**
- Modify: `karaoke/src/karaoke/runner.py` (add `inspect_song`)
- Modify: `karaoke/src/karaoke/config.py` (add the `accords` property; `ensure_dirs` also creates it)
- Create: `karaoke/src/karaoke/state.py`
- Modify: `karaoke/src/karaoke/cli.py` (add the `etat` command)
- Test: `karaoke/tests/test_state.py`

**Interfaces:**
- Consumes: `run_song` (Task 1), the markers, `rapport.json`.
- Produces:
  - `inspect_song(ws, steps) -> dict[str, str]` mapping each step to `a_jour` | `perime` | `absent`;
  - `song_state(cfg, song, steps) -> dict`;
  - the CLI `karaoke etat --json`, which prints a JSON list.
- `song_state` keys: `id, titre, artiste, album, fichier, retirer (list), langue, partie, decompte_mesures, statut, steps: [{name, status, seconds, error}], paths: {dossier, video, set, accords, lrc, audio, lrc_corrige, accords_corrige}, pad_s, beats_per_bar, key, bars`.
- Step status in `steps`: `a_jour`, or the last run's `echec` / `a_reessayer` / `bloque` from `rapport.json` when the step is not up to date, otherwise `perime` (it has a marker) or `absent` (no marker).

- [ ] **Step 1: Write the failing test**

```python
# karaoke/tests/test_state.py
import json
from karaoke.runner import Step, inspect_song, run_song
from karaoke.state import song_state
from karaoke.workspace import Workspace
from test_manifest import song


def steps(calls):
    a = Step(name="a", deps=(), key=lambda ws: calls.get("ka", "k"), run=lambda ws, up: {"x": 1})
    b = Step(name="b", deps=("a",), key=lambda ws: "k", run=lambda ws, up: {"y": 2})
    return [a, b]


def test_inspect_song_matches_runner(cfg):
    ws, calls = Workspace(cfg, song()), {}
    assert inspect_song(ws, steps(calls)) == {"a": "absent", "b": "absent"}
    run_song(ws, steps(calls))
    assert inspect_song(ws, steps(calls)) == {"a": "a_jour", "b": "a_jour"}
    calls["ka"] = "changed"                       # a's parameters changed → a and b out of date
    assert inspect_song(ws, steps(calls)) == {"a": "perime", "b": "perime"}


def test_song_state_reports_paths_failures_and_chords(cfg):
    s = song(id="005", titre="Danser", artiste="Loïc Nottet", partie="Apéro")
    ws = Workspace(cfg, s)
    run_song(ws, steps({}))
    ws.write_marker("package", {"result": {"pad_s": 2.5}})
    ws.write_marker("chords", {"result": {"key": "C# minor", "beats_per_bar": 4,
                                          "bars": [{"start": 0.0, "chords": [[0, "C#m"]]}]}})
    ws.out.mkdir(parents=True, exist_ok=True)
    (ws.out / "rapport.json").write_text(json.dumps({"statut": "echec", "etapes": {"a": "fait", "b": "echec"},
                                                      "alertes": ["b : echec ValueError: boom"]}))
    st = song_state(cfg, s, steps({"ka": "new"}))
    assert st["statut"] == "echec" and st["retirer"] == ["guitar"] and st["pad_s"] == 2.5
    assert [(x["name"], x["status"]) for x in st["steps"]] == [("a", "perime"), ("b", "echec")]
    assert "boom" in st["steps"][1]["error"]
    assert st["paths"]["video"].endswith("005_loic-nottet_danser/paroles.mp4")
    assert st["paths"]["set"].endswith("sets/apero/005_loic-nottet_danser.als")
    assert st["paths"]["accords_corrige"].endswith("accords/005.txt")
    assert st["paths"]["audio"].endswith("travail/005/input.wav")
    assert st["key"] == "C# minor" and st["bars"][0]["chords"] == [[0, "C#m"]]


def test_etat_cli_prints_json_list(cfg, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.manifest import write_manifest
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song(), song(id="002", titre="B")])
    r = CliRunner().invoke(cli.app, ["etat", "--json"])
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    assert [d["id"] for d in data] == ["001", "002"] and data[0]["statut"] == "—"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv --directory karaoke run pytest tests/test_state.py -q`
Expected: FAIL with `ImportError: cannot import name 'inspect_song'`.

- [ ] **Step 3: Implement**

In `config.py`:

```python
    @property
    def accords(self) -> Path:
        """Michel's corrected chord charts (accords/<id>.txt), never overwritten."""
        return self.home / "accords"
```

Add `self.accords` to the tuple in `ensure_dirs`.

In `runner.py`, add the following. It computes the same key as `run_song`, without running anything:

```python
def inspect_song(ws: Workspace, steps: list[Step]) -> dict[str, str]:
    """Up-to-date-ness of each step as run_song would judge it, without running anything."""
    hashes: dict[str, str | None] = {}
    out: dict[str, str] = {}
    for step in steps:
        marker = ws.read_marker(step.name)
        deps = [hashes.get(d) for d in step.deps]
        if any(h is None for h in deps):
            hashes[step.name] = None
            out[step.name] = "perime" if marker else "absent"
            continue
        key = hashlib.sha1("|".join([step.name, step.version, step.key(ws), *deps]).encode()).hexdigest()
        ok = (marker is not None and marker.get("key") == key and all(p.exists() for p in step.artifacts(ws)))
        hashes[step.name] = marker["output_hash"] if ok else None
        out[step.name] = "a_jour" if ok else ("perime" if marker else "absent")
    return out
```

(`run_song` builds its key from exactly these parts: name, version, key(ws) and the deps' output hashes. Keep the two in step.)

Create `state.py`:

```python
"""Per-song state for Karaifyer: manifest fields, step up-to-dateness, last run's failures, paths."""
from __future__ import annotations
import json

from karaoke.config import Config
from karaoke.manifest import Song
from karaoke.runner import Step, inspect_song
from karaoke.workspace import Workspace, slug


def song_state(cfg: Config, s: Song, steps: list[Step]) -> dict:
    ws = Workspace(cfg, s)
    rep_path = ws.out / "rapport.json"
    rep = json.loads(rep_path.read_text(encoding="utf-8")) if rep_path.exists() else {}
    last = rep.get("etapes", {})
    alerts = rep.get("alertes", [])
    fresh = inspect_song(ws, steps)
    out_steps = []
    for st in steps:
        status = fresh[st.name]
        if status != "a_jour" and last.get(st.name) in ("echec", "a_reessayer", "bloque"):
            status = last[st.name]
        marker = ws.read_marker(st.name) or {}
        err = next((a for a in alerts if a.startswith(f"{st.name} :")), "")
        out_steps.append({"name": st.name, "status": status, "seconds": marker.get("seconds"),
                          "error": err if status in ("echec", "a_reessayer", "bloque") else ""})
    pkg = (ws.read_marker("package") or {}).get("result") or {}
    ch = (ws.read_marker("chords") or {}).get("result") or {}
    return {"id": s.id, "titre": s.titre, "artiste": s.artiste, "album": s.album, "fichier": str(s.fichier),
            "retirer": list(s.retirer), "langue": s.langue, "partie": s.partie,
            "decompte_mesures": s.decompte_mesures, "statut": rep.get("statut", "—"), "steps": out_steps,
            "paths": {"dossier": str(ws.out), "video": str(ws.out / "paroles.mp4"),
                      "set": str(cfg.sets / slug(s.partie or "sans-partie") / f"{ws.out.name}.als"),
                      "accords": str(ws.out / "accords.txt"), "lrc": str(ws.out / "paroles.lrc"),
                      "audio": str(ws.work / "input.wav"),
                      "lrc_corrige": str(cfg.paroles / f"{s.id}.lrc"),
                      "accords_corrige": str(cfg.accords / f"{s.id}.txt")},
            "pad_s": pkg.get("pad_s"), "beats_per_bar": ch.get("beats_per_bar"), "key": ch.get("key"),
            "bars": ch.get("bars", [])}
```

In `cli.py`:

```python
@app.command()
def etat(json_out: bool = typer.Option(True, "--json", help="Sortie JSON (toujours)")) -> None:
    """État de chaque morceau du manifeste (pour Karaifyer) : étapes, statut, chemins."""
    cfg = Config.load()
    typer.echo(json.dumps([song_state(cfg, s, STEPS) for s in read_manifest(cfg.manifest)], ensure_ascii=False))
```

Add the import `from karaoke.state import song_state`. A song that has never run has `statut` `—`.

Note: the `report.song_report` alert text is `f"{n} : {st} {error}"`. The `startswith(f"{st.name} :")` match relies on that format.

- [ ] **Step 4: Run tests**

Run: `uv --directory karaoke run pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/runner.py karaoke/src/karaoke/state.py karaoke/src/karaoke/config.py karaoke/src/karaoke/cli.py karaoke/tests/test_state.py
git commit -m "karaoke: etat --json (per-song steps, status, paths) and accords/ folder"
```

---

### Task 3: `ajouter` (add songs from any audio file)

**Files:**
- Modify: `karaoke/src/karaoke/manifest.py` (add `next_id` and `songs_from_files`; make `write_manifest` atomic)
- Modify: `karaoke/src/karaoke/cli.py` (add the `ajouter` command)
- Test: `karaoke/tests/test_ajouter.py`

**Interfaces:**
- Produces:
  - `next_id(songs) -> str`: 3 digits, max + 1, `"001"` when the manifest is empty;
  - `songs_from_files(paths, existing) -> tuple[list[Song], list[str]]`: the added songs, plus the skipped files with their reason;
  - the CLI `karaoke ajouter FICHIER...`, which prints `{"ajoutes": [{id, titre, artiste}], "ignores": [msg]}`. When `manifeste.csv` doesn't exist yet, it creates it.

- [ ] **Step 1: Write the failing test**

```python
# karaoke/tests/test_ajouter.py
import json
from pathlib import Path
import soundfile as sf
from karaoke.manifest import next_id, read_manifest, songs_from_files, write_manifest
from conftest import tone
from test_manifest import song


def flac(path: Path, title=None, artist=None) -> Path:
    sf.write(str(path), tone(1.0), 44100, format="FLAC")
    if title:
        from mutagen.flac import FLAC
        f = FLAC(path); f["title"] = title; f["artist"] = artist or ""; f.save()
    return path


def test_next_id():
    assert next_id([]) == "001"
    assert next_id([song(id="007"), song(id="041")]) == "042"


def test_songs_from_files_reads_tags_falls_back_to_name_and_skips_duplicates(tmp_path):
    a = flac(tmp_path / "a.flac", "Danser", "Loïc Nottet")
    b = flac(tmp_path / "Ma chanson - live.flac")
    existing = [song(id="041", fichier=a)]
    added, skipped = songs_from_files([a, b, tmp_path / "absent.flac"], existing)
    assert [(s.id, s.titre, s.artiste) for s in added] == [("042", "Ma chanson - live", "")]
    assert abs(added[0].duree_ref_s - 1.0) < 0.05 and added[0].fichier == b.resolve()
    assert len(skipped) == 2 and "déjà" in skipped[0] and "introuvable" in skipped[1]


def test_ajouter_cli_appends_rows(cfg, tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song(id="005")])
    r = CliRunner().invoke(cli.app, ["ajouter", str(flac(tmp_path / "x.flac", "Speed", "Zazie"))])
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ajoutes"] == [{"id": "006", "titre": "Speed", "artiste": "Zazie"}]
    assert [s.id for s in read_manifest(cfg.manifest)] == ["005", "006"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv --directory karaoke run pytest tests/test_ajouter.py -q`
Expected: FAIL with `ImportError: cannot import name 'next_id'`.

- [ ] **Step 3: Implement**

In `manifest.py`:

```python
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
        title = _tag(audio, "title") if audio else ""
        added.append(Song(id=next_id(existing + added), titre=title or nfc(p.stem),
                          artiste=_tag(audio, "artist") if audio else "",
                          album=_tag(audio, "album") if audio else "",
                          duree_ref_s=float(audio.info.length) if audio else 0.0, isrc="", fichier=p,
                          retirer=(), decompte_mesures=2, langue="fr", partie=""))
        known.add(p)
    return added, skipped
```

`MutagenFile(..., easy=True)` gives `title` / `artist` keys for MP3 and M4A as well. `_tag` already handles the list values.

Make `write_manifest` atomic. Write to `path.with_suffix(".csv.tmp")`, then `os.replace` it onto `path`, and add `import os`.

In `cli.py`:

```python
@app.command()
def ajouter(fichiers: list[Path] = typer.Argument(..., help="Fichiers audio à ajouter")) -> None:
    """Ajoute des morceaux au manifeste depuis n'importe quels fichiers audio (pas seulement SysRec)."""
    cfg = Config.load()
    cfg.ensure_dirs()
    songs = read_manifest(cfg.manifest) if cfg.manifest.exists() else []
    added, skipped = songs_from_files(fichiers, songs)
    write_manifest(cfg.manifest, songs + added)
    typer.echo(json.dumps({"ajoutes": [{"id": s.id, "titre": s.titre, "artiste": s.artiste} for s in added],
                           "ignores": skipped}, ensure_ascii=False))
```

- [ ] **Step 4: Run tests**

Run: `uv --directory karaoke run pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/manifest.py karaoke/src/karaoke/cli.py karaoke/tests/test_ajouter.py
git commit -m "karaoke: ajouter (songs from any audio file) and atomic manifest writes"
```

---

### Task 4: `modifier` (edit one manifest cell, validated)

**Files:**
- Modify: `karaoke/src/karaoke/manifest.py` (add `set_field`)
- Modify: `karaoke/src/karaoke/cli.py` (add the `modifier` command)
- Test: `karaoke/tests/test_modifier.py`

**Interfaces:**
- Produces:
  - `set_field(path, sid, champ, valeur) -> Song`, which raises `ManifestError` with a French message on an invalid value;
  - the CLI `karaoke modifier --id 005 --champ retirer --valeur "guitar;other"`. It exits 0 and prints the row as JSON, or exits 1 with the message on stderr.
- Editable fields: `titre`, `artiste`, `retirer`, `langue`, `partie` and `decompte_mesures`.

- [ ] **Step 1: Write the failing test**

```python
# karaoke/tests/test_modifier.py
import pytest
from karaoke.manifest import ManifestError, read_manifest, set_field, write_manifest
from test_manifest import song


def test_set_field_updates_one_cell(cfg):
    write_manifest(cfg.manifest, [song(id="005"), song(id="006")])
    s = set_field(cfg.manifest, "005", "retirer", "guitar;other")
    assert s.retirer == ("guitar", "other")
    rows = read_manifest(cfg.manifest)
    assert rows[0].retirer == ("guitar", "other") and rows[1].retirer == ("guitar",)
    assert set_field(cfg.manifest, "006", "partie", "Dessert").partie == "Dessert"


def test_invalid_values_are_refused_and_file_untouched(cfg):
    write_manifest(cfg.manifest, [song(id="005")])
    before = cfg.manifest.read_bytes()
    for champ, valeur in [("retirer", "flute"), ("decompte_mesures", "deux"), ("id", "999"), ("couleur", "x")]:
        with pytest.raises(ManifestError):
            set_field(cfg.manifest, "005", champ, valeur)
    with pytest.raises(ManifestError, match="introuvable"):
        set_field(cfg.manifest, "404", "partie", "x")
    assert cfg.manifest.read_bytes() == before


def test_modifier_cli_error_exit(cfg, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song(id="005")])
    ok = CliRunner().invoke(cli.app, ["modifier", "--id", "005", "--champ", "langue", "--valeur", "en"])
    assert ok.exit_code == 0 and '"langue": "en"' in ok.output
    bad = CliRunner().invoke(cli.app, ["modifier", "--id", "005", "--champ", "retirer", "--valeur", "flute"])
    assert bad.exit_code == 1 and "flute" in bad.output
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv --directory karaoke run pytest tests/test_modifier.py -q`
Expected: FAIL with `ImportError: cannot import name 'set_field'`.

- [ ] **Step 3: Implement**

In `manifest.py`:

```python
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
```

Check that `_parse_row` reports a non-integer `decompte_mesures` as an error and returns None. It already does, through its `ValueError` branch.

In `cli.py`:

```python
@app.command()
def modifier(id: str = typer.Option(...), champ: str = typer.Option(...), valeur: str = typer.Option(...)) -> None:
    """Modifie une case du manifeste (avec les mêmes vérifications que la lecture)."""
    cfg = Config.load()
    try:
        s = set_field(cfg.manifest, id, champ, valeur)
    except ManifestError as e:
        typer.echo(str(e), err=True)
        raise typer.Exit(1)
    typer.echo(json.dumps({"id": s.id, "titre": s.titre, "artiste": s.artiste, "retirer": list(s.retirer),
                           "langue": s.langue, "partie": s.partie, "decompte_mesures": s.decompte_mesures},
                          ensure_ascii=False))
```

Typer's `CliRunner` mixes stderr into `output` by default, so the test's `"flute" in bad.output` holds.

- [ ] **Step 4: Run tests**

Run: `uv --directory karaoke run pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/manifest.py karaoke/src/karaoke/cli.py karaoke/tests/test_modifier.py
git commit -m "karaoke: modifier (validated single-cell manifest edit)"
```

---

### Task 5: Corrected chord charts (`accords/<id>.txt`)

**Files:**
- Modify: `karaoke/src/karaoke/chords.py` (add `SYMBOL`, `parse_cell`, `parse_chart`, `expand`)
- Modify: `karaoke/src/karaoke/ireal.py` (`chord` handles the richer symbols)
- Modify: `karaoke/src/karaoke/steps/chords.py` (override branch, key, version)
- Test: `karaoke/tests/test_chord_override.py`; extend `karaoke/tests/test_ireal.py`

**Interfaces:**
- Consumes: `Config.accords` (Task 2).
- Produces:
  - `SYMBOL`: a regex accepting `C`, `C#m`, `Bb7`, `Amaj7`, `Dm7`, `F#m7b5`, `Gsus4`, `Edim`, `Caug`, `A6`, `Am6`, `D9`, `Cadd9`, `C/E`, `Am/G` and `N.C.`;
  - `parse_cell(cell, bpb) -> list[[beat, label]]`, which raises `ValueError` (French message) when the cell is invalid;
  - `parse_chart(text, bpb) -> (key | None, bars_cells: list[str])`;
  - `expand(bars_chords, bpb) -> per-beat labels`.
- Cell syntax (the Swift `ChordGrid` in Task 8 must match it exactly):
  - tokens separated by spaces;
  - **if any token is `.`**: the token count must equal `bpb`; token *i* is beat *i*, and `.` continues the previous chord (the first token can't be `.`);
  - **otherwise**: *n* chords split the bar evenly, so chord *k* starts at beat `k * bpb // n`, and *n* must be ≤ `bpb`.
  - Empty cells are invalid.
- File format: the same as `sortie/.../accords.txt`. The line `Tonalité : <key> · …` gives the key (optional). Every line starting with `|` holds bars separated by `|`.

- [ ] **Step 1: Write the failing test**

```python
# karaoke/tests/test_chord_override.py
import json
import pytest
from karaoke.chords import expand, parse_cell, parse_chart

BEATS = [0.5 * i for i in range(16)]
DOWN = BEATS[::4]


def test_parse_cell_even_and_per_beat():
    assert parse_cell("A", 4) == [[0, "A"]]
    assert parse_cell("A B", 4) == [[0, "A"], [2, "B"]]
    assert parse_cell("Am . . F", 4) == [[0, "Am"], [3, "F"]]
    assert parse_cell("C G Am", 3) == [[0, "C"], [1, "G"], [2, "Am"]]
    assert parse_cell("Cmaj7 F#m7b5/E", 4) == [[0, "Cmaj7"], [2, "F#m7b5/E"]]
    assert parse_cell("N.C.", 4) == [[0, "N.C."]]
    for bad in ["", "H", "A . B", ". A . .", "A B C D E"]:
        with pytest.raises(ValueError):
            parse_cell(bad, 4)


def test_parse_chart_and_expand():
    text = "Danser — Loïc Nottet\nTonalité : C# minor · 100 BPM · 4/4\n\n| C#m | A | A . . B |\n| N.C. |\n"
    key, cells = parse_chart(text)
    assert key == "C# minor" and cells == ["C#m", "A", "A . . B", "N.C."]
    bars = [{"chords": parse_cell(c, 4)} for c in cells[:2]]
    assert expand(bars, 4) == ["C#m"] * 4 + ["A"] * 4


def _stems(ws, C):
    from karaoke import audio
    from conftest import tone
    for s in C.HARMONIC:
        audio.write_wav(ws.stems / f"{s}.wav", tone(8.0))


def test_step_uses_correction_without_madmom(cfg, monkeypatch):
    from karaoke.steps import chords as C
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    _stems(ws, C)
    monkeypatch.setattr(C, "run_tool", lambda *a, **k: pytest.fail("madmom must not run"))
    (cfg.accords / "001.txt").write_text("x\nTonalité : D major · 120 BPM · 4/4\n\n| D | G A | Bm . . G | D |\n")
    up = {"ingest": {"duration_s": 8.0}, "separate": {}, "beats": {"beats": BEATS, "downbeats": DOWN}}
    r = C.CHORDS.run(ws, up)
    assert r["key"] == "D major" and r["source"] == "correction"
    assert [b["chords"] for b in r["bars"]] == [[[0, "D"]], [[0, "G"], [2, "A"]], [[0, "Bm"], [3, "G"]], [[0, "D"]]]
    assert r["changes"][1] == {"t": 2.0, "label": "G"}
    assert "| D | G A | Bm . . G | D |" in (ws.out / "accords.txt").read_text()


def test_step_refuses_bar_count_mismatch(cfg, monkeypatch):
    from karaoke.steps import chords as C
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    _stems(ws, C)
    (cfg.accords / "001.txt").write_text("| D | G |\n")
    up = {"ingest": {"duration_s": 8.0}, "separate": {}, "beats": {"beats": BEATS, "downbeats": DOWN}}
    with pytest.raises(ValueError, match="2 mesures.*4"):
        C.CHORDS.run(ws, up)


def test_key_follows_correction_file(cfg):
    from karaoke.steps.chords import CHORDS
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    k0 = CHORDS.key(ws)
    (cfg.accords / "001.txt").write_text("| D |\n")
    k1 = CHORDS.key(ws)
    (cfg.accords / "001.txt").write_text("| E |\n")
    assert len({k0, k1, CHORDS.key(ws)}) == 3
```

Append to `karaoke/tests/test_ireal.py`:

```python
def test_rich_chord_symbols_to_ireal():
    assert [chord(c) for c in ["Cmaj7", "Dm7", "F#m7b5", "Edim", "Gsus4", "Am/G", "Bb7", "Caug", "Am6"]] == \
        ["C^7", "D-7", "F#h7", "Eo", "Gsus", "A-/G", "Bb7", "C+", "A-6"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv --directory karaoke run pytest tests/test_chord_override.py tests/test_ireal.py -q`
Expected: FAIL with `ImportError: cannot import name 'expand'` (or `parse_cell`), and the iReal test fails on `Cmaj7`.

- [ ] **Step 3: Implement**

In `chords.py`:

```python
import re

SYMBOL = re.compile(r"^(N\.C\.|[A-G][#b]?(m|maj7|m7b5|m7|m6|7|6|9|dim|aug|sus2|sus4|add9)?(/[A-G][#b]?)?)$")


def parse_cell(cell: str, beats_per_bar: int) -> list[list]:
    """`A B` = even split; `Am . . F` = one token per beat, `.` continues. Raises ValueError (French)."""
    toks = cell.split()
    if not toks:
        raise ValueError("mesure vide")
    bad = [t for t in toks if t != "." and not SYMBOL.match(t)]
    if bad:
        raise ValueError(f"accord non reconnu : {bad[0]}")
    if "." in toks:
        if len(toks) != beats_per_bar or toks[0] == ".":
            raise ValueError(f"« {cell} » : {beats_per_bar} temps attendus, le premier étant un accord")
        return [[i, t] for i, t in enumerate(toks) if t != "."]
    if len(toks) > beats_per_bar:
        raise ValueError(f"« {cell} » : plus d'accords que de temps ({beats_per_bar})")
    return [[k * beats_per_bar // len(toks), t] for k, t in enumerate(toks)]


def parse_chart(text: str) -> tuple[str | None, list[str]]:
    key, cells = None, []
    for line in text.splitlines():
        m = re.match(r"\s*Tonalit[ée]\s*:\s*([^·]+)", line)
        if m:
            key = m.group(1).strip()
        elif line.strip().startswith("|"):
            cells += [c.strip() for c in line.strip().strip("|").split("|")]
    return key, cells


def expand(bars: list[dict], beats_per_bar: int) -> list[str]:
    """Per-beat labels from bars' [[beat, label]] lists."""
    out = []
    for b in bars:
        cur = None
        marks = dict((i, l) for i, l in b["chords"])
        for i in range(beats_per_bar):
            cur = marks.get(i, cur)
            out.append(cur)
    return out
```

In `ireal.py`, replace `chord`:

```python
QUALITY = {"": "", "m": "-", "maj7": "^7", "m7": "-7", "m7b5": "h7", "m6": "-6", "7": "7", "6": "6",
           "9": "9", "dim": "o", "aug": "+", "sus2": "sus2", "sus4": "sus", "add9": "add9"}


def chord(symbol: str) -> str:
    if symbol == "N.C.":
        return "n"
    m = re.match(r"^([A-G][#b]?)(maj7|m7b5|m7|m6|m|7|6|9|dim|aug|sus2|sus4|add9)?(/[A-G][#b]?)?$", symbol)
    if not m:
        return symbol
    root, q, bass = m.group(1), m.group(2) or "", m.group(3) or ""
    return root + QUALITY[q] + bass
```

Add `import re` to `ireal.py`.

In `steps/chords.py`:
- **Key** of the step: `lambda ws: "madmom-deepchroma-v1|spell-by-key|" + _correction_digest(ws)`, where

  ```python
  def _correction_digest(ws):
      p = ws.cfg.accords / f"{ws.song.id}.txt"
      return hashlib.sha1(p.read_bytes()).hexdigest() if p.exists() else "-"
  ```

- **Version:** `version="2"`.
- **Override branch:** at the start of `_run`, after `beats`, `downbeats` and `bpb` are computed (move those three lines up), add:

```python
    corr = ws.cfg.accords / f"{ws.song.id}.txt"
    if corr.exists():
        key, cells = parse_chart(corr.read_text(encoding="utf-8"))
        grid = bars_from(beats, downbeats, ["N.C."] * len(beats), bpb)
        if len(cells) != len(grid):
            raise ValueError(f"accords/{ws.song.id}.txt : {len(cells)} mesures, la détection en a {len(grid)}")
        bars = [{"start": g["start"], "chords": parse_cell(c, bpb)} for g, c in zip(grid, cells)]
        labels = expand(bars, bpb)[:len(beats)]
        key = key or "C major"
        source = "correction"
    else:
        ...  # existing madmom path, which sets key=data["key"], labels, bars; source = "detection"
```

Then write `accords.txt` and the result from `key`, `bars` and `labels` for both paths. Add `"source": source` to the result (and to the failure return: `"source": "detection"`).

**Pickup bars:** `bars_from` adds a pickup bar when the first downbeat isn't beat 0. Its cell must then hold *(beats in the pickup)* tokens, but `parse_cell` validates against `bpb`. **Ruling for the executor:** accept the pickup cell against `bpb`, and truncate `expand`'s output for that bar to its real beat count. `expand` works per bar, so slice each bar's labels to `next_bar_first_beat - bar_first_beat` beats. Record this in the ledger. If it gets complicated, leave pickup bars to a ruling and test them only through `parse_cell`.

- [ ] **Step 4: Run tests**

Run: `uv --directory karaoke run pytest -q`
Expected: all pass (the existing chord-step tests still pass: no correction file → detection path).

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/chords.py karaoke/src/karaoke/ireal.py karaoke/src/karaoke/steps/chords.py karaoke/tests/test_chord_override.py karaoke/tests/test_ireal.py
git commit -m "karaoke: corrected chord charts (accords/<id>.txt) with per-beat syntax and richer symbols"
```

---

### Task 6: Karaifyer package scaffold (copy of SysRec, renamed)

**Files:**
- Create: `karaifyer/Package.swift`, `karaifyer/build-app.sh`, `karaifyer/Resources/Info.plist`
- Create, copied from SysRec:
  - `karaifyer/Sources/KaraifyerCore/{CSV,TrackList,TrimMath}.swift`
  - `karaifyer/Sources/Karaifyer/*.swift`
  - `karaifyer/Tests/KaraifyerCoreTests/TrackListTests.swift` and `Fixtures/karaoke.csv`
- Rename: `Sources/Karaifyer/SysRecApp.swift` → `KaraifyerApp.swift`

**Interfaces:**
- Produces: the `KaraifyerCore` library, the `Karaifyer` executable and the `KaraifyerCoreTests` test target; `./build-app.sh` builds `karaifyer/Karaifyer.app`.

- [ ] **Step 1: Copy and rename**

```bash
mkdir -p karaifyer/Sources karaifyer/Tests karaifyer/Resources
cp -R Sources/SysRecCore karaifyer/Sources/KaraifyerCore
cp -R Sources/SysRec karaifyer/Sources/Karaifyer
cp -R Tests/SysRecCoreTests karaifyer/Tests/KaraifyerCoreTests
git mv -f karaifyer/Sources/Karaifyer/SysRecApp.swift karaifyer/Sources/Karaifyer/KaraifyerApp.swift 2>/dev/null || mv karaifyer/Sources/Karaifyer/SysRecApp.swift karaifyer/Sources/Karaifyer/KaraifyerApp.swift
grep -rl "SysRecCore" karaifyer | xargs sed -i '' 's/SysRecCore/KaraifyerCore/g'
sed -i '' 's/struct SysRecApp: App/struct KaraifyerApp: App/; s/Window("SysRec", id: "queue")/Window("Karaifyer", id: "queue")/; s/Button("Quit SysRec")/Button("Quitter Karaifyer")/' karaifyer/Sources/Karaifyer/KaraifyerApp.swift
grep -rn "SysRec" karaifyer/Sources | grep -v "SysRec\." | head -30   # review remaining mentions
```

Review the remaining `SysRec` mentions:
- **Keep:** the default output folder `~/Music/SysRec` (shared recordings, so the manifest can be built from either app), the `print("SysRec: …")` logs (rename them to `Karaifyer:`) and any user-facing text (rename to Karaifyer).
- **Don't touch:** the `QueueModel` UserDefaults keys. They live in Karaifyer's own domain because the bundle id is different.

- [ ] **Step 2: Package.swift, Info.plist, build-app.sh**

```swift
// karaifyer/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Karaifyer",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic (CSV, track list, pipeline JSON, LRC, chord grid, run state), unit-tested.
        .target(name: "KaraifyerCore"),
        // The app: SysRec's recorder (copied) + the Karaoké tab driving the karaoke pipeline.
        .executableTarget(name: "Karaifyer", dependencies: ["KaraifyerCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KaraifyerCoreTests", dependencies: ["KaraifyerCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
```

`Resources/Info.plist` is a copy of SysRec's with:
- `CFBundleIdentifier` = `com.akkaouim.karaifyer`;
- `CFBundleName`, `CFBundleDisplayName` and `CFBundleExecutable` = `Karaifyer`;
- usage strings saying « Karaifyer records Spotify's audio output… » and « Karaifyer controls Spotify… ».

`build-app.sh` is a copy of SysRec's with every `SysRec` replaced by `Karaifyer` and `--identifier com.akkaouim.karaifyer`. It keeps the « SysRec Local Signing » certificate lookup: the same self-signed identity is fine, and the identifier keeps the permissions separate.

- [ ] **Step 3: Build and test**

Run:
```bash
cd karaifyer && swift build 2>&1 | tail -3 && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing 2>&1 | tail -3 && ./build-app.sh | tail -1
cd .. && git status --short Sources Tests Package.swift build-app.sh Resources
```
Expected:
- the build succeeds;
- the copied TrackList tests pass;
- `Built …/karaifyer/Karaifyer.app`;
- the final `git status` prints nothing (SysRec untouched).

Add `karaifyer/.build/` and `karaifyer/Karaifyer.app/` to the repo's `.gitignore` if `.build`/`SysRec.app` patterns don't already cover them. Check with `git check-ignore -v karaifyer/.build`.

- [ ] **Step 4: Commit**

```bash
git add karaifyer .gitignore
git commit -m "karaifyer: scaffold — SysRec copied and renamed (SysRec untouched)"
```

---

### Task 7: Core: pipeline models and LRC

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/PipelineModels.swift`, `karaifyer/Sources/KaraifyerCore/LRC.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/PipelineModelsTests.swift`, `LRCTests.swift`

**Interfaces:**
- Consumes: the `etat --json` output (Task 2) and the `traiter --json` events (Task 1).
- Produces:

```swift
public struct ChordAt: Codable, Equatable, Sendable { public var beat: Int; public var label: String }   // JSON [0,"C"]
public struct BarInfo: Codable, Equatable, Sendable { public var start: Double; public var chords: [ChordAt] }
public struct StepState: Codable, Equatable, Sendable { public var name, status: String; public var seconds: Double?; public var error: String? }
public struct SongPaths: Codable, Equatable, Sendable { public var dossier, video, set, accords, lrc, audio, lrcCorrige, accordsCorrige: String }
public struct SongState: Codable, Equatable, Identifiable, Sendable {
    public var id, titre, artiste, album, fichier, langue, partie, statut: String
    public var retirer: [String]; public var decompteMesures: Int
    public var steps: [StepState]; public var paths: SongPaths
    public var padS: Double?; public var beatsPerBar: Int?; public var key: String?; public var bars: [BarInfo]
    public static func decodeList(_ data: Data) throws -> [SongState]
}
public enum PipelineEvent: Equatable, Sendable {
    case songStart(id: String), stepStart(id: String, step: String)
    case stepEnd(id: String, step: String, status: String, seconds: Double, error: String)
    case songEnd(id: String, statut: String), log(id: String, line: String)
    public static func parse(_ line: String) -> PipelineEvent?   // nil for non-JSON lines
}
public struct LyricLine: Equatable, Sendable { public var time: Double; public var text: String }
public enum LRC {
    public static func parse(_ text: String) -> (lines: [LyricLine], decalage: Double?)
    public static func format(_ lines: [LyricLine], decalage: Double) -> String  // same bytes as Python lrc.format
    public static func timecode(_ t: Double) -> String       // "01:05.30"
    public static func parseTimecode(_ s: String) -> Double? // "1:05.3" / "01:05.30" → 65.3
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// karaifyer/Tests/KaraifyerCoreTests/PipelineModelsTests.swift
import Foundation
import Testing
@testable import KaraifyerCore

struct PipelineModelsTests {
    let etat = """
    [{"id":"005","titre":"Danser","artiste":"Loïc Nottet","album":"","fichier":"/x.flac","retirer":["guitar"],
      "langue":"fr","partie":"Apéro","decompte_mesures":2,"statut":"ok",
      "steps":[{"name":"ingest","status":"a_jour","seconds":3.2,"error":""},
               {"name":"video","status":"echec","seconds":null,"error":"video : echec boom"}],
      "paths":{"dossier":"/d","video":"/d/paroles.mp4","set":"/s.als","accords":"/d/accords.txt","lrc":"/d/paroles.lrc",
               "audio":"/w/input.wav","lrc_corrige":"/p/005.lrc","accords_corrige":"/a/005.txt"},
      "pad_s":2.5,"beats_per_bar":4,"key":"C# minor","bars":[{"start":0.0,"chords":[[0,"C#m"],[2,"A"]]}]}]
    """

    @Test func decodesEtat() throws {
        let s = try #require(try SongState.decodeList(Data(etat.utf8)).first)
        #expect(s.id == "005" && s.retirer == ["guitar"] && s.padS == 2.5 && s.beatsPerBar == 4)
        #expect(s.steps[1].status == "echec" && s.steps[0].seconds == 3.2)
        #expect(s.paths.lrcCorrige == "/p/005.lrc")
        #expect(s.bars[0].chords == [ChordAt(beat: 0, label: "C#m"), ChordAt(beat: 2, label: "A")])
    }

    @Test func decodesNullsForUnprocessedSong() throws {
        let raw = etat.replacingOccurrences(of: "\"pad_s\":2.5,\"beats_per_bar\":4,\"key\":\"C# minor\"",
                                            with: "\"pad_s\":null,\"beats_per_bar\":null,\"key\":null")
        let s = try #require(try SongState.decodeList(Data(raw.utf8)).first)
        #expect(s.padS == nil && s.key == nil)
    }

    @Test func parsesEvents() {
        #expect(PipelineEvent.parse(#"{"event":"song_start","id":"005"}"#) == .songStart(id: "005"))
        #expect(PipelineEvent.parse(#"{"event":"step_end","id":"005","step":"beats","status":"fait","seconds":4.5,"error":""}"#)
                == .stepEnd(id: "005", step: "beats", status: "fait", seconds: 4.5, error: ""))
        #expect(PipelineEvent.parse(#"{"event":"log","id":"005","line":"début beats"}"#) == .log(id: "005", line: "début beats"))
        #expect(PipelineEvent.parse(#"{"event":"song_end","id":"005","statut":"alerte"}"#) == .songEnd(id: "005", statut: "alerte"))
        #expect(PipelineEvent.parse("Traceback (most recent call last):") == nil)
    }
}
```

```swift
// karaifyer/Tests/KaraifyerCoreTests/LRCTests.swift
import Testing
@testable import KaraifyerCore

struct LRCTests {
    @Test func roundTripMatchesPythonFormat() {
        let text = "[karaoke:decalage=2.000]\n[00:03.00]Un\n[01:05.30]Deux mots\n"
        let (lines, dec) = LRC.parse(text)
        #expect(dec == 2.0)
        #expect(lines == [LyricLine(time: 3.0, text: "Un"), LyricLine(time: 65.3, text: "Deux mots")])
        #expect(LRC.format(lines, decalage: 2.0) == text)
    }

    @Test func parseIgnoresOtherTagsAndSortsByTime() {
        let (lines, dec) = LRC.parse("[ar:Zazie]\n[00:10.00]B\n[00:02.50]A\n\n")
        #expect(dec == nil && lines.map(\.text) == ["A", "B"])
    }

    @Test func timecodes() {
        #expect(LRC.timecode(65.3) == "01:05.30")
        #expect(LRC.parseTimecode("1:05.3") == 65.3)
        #expect(LRC.parseTimecode("01:05.30") == 65.3)
        #expect(LRC.parseTimecode("abc") == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing 2>&1 | tail -5`
Expected: compile errors, `cannot find 'SongState' in scope` / `cannot find 'LRC' in scope`.

- [ ] **Step 3: Implement**

```swift
// karaifyer/Sources/KaraifyerCore/PipelineModels.swift
import Foundation

/// A chord change inside a bar; JSON form is the pipeline's `[beat, "label"]` pair.
public struct ChordAt: Codable, Equatable, Sendable {
    public var beat: Int
    public var label: String
    public init(beat: Int, label: String) { self.beat = beat; self.label = label }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        beat = try c.decode(Int.self)
        label = try c.decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(beat); try c.encode(label)
    }
}

public struct BarInfo: Codable, Equatable, Sendable {
    public var start: Double
    public var chords: [ChordAt]
}

public struct StepState: Codable, Equatable, Sendable {
    public var name: String
    public var status: String          // a_jour | perime | absent | echec | a_reessayer | bloque
    public var seconds: Double?
    public var error: String?
}

public struct SongPaths: Codable, Equatable, Sendable {
    public var dossier, video, set, accords, lrc, audio, lrcCorrige, accordsCorrige: String
}

/// One manifest row plus its pipeline state, as printed by `karaoke etat --json`.
public struct SongState: Codable, Equatable, Identifiable, Sendable {
    public var id, titre, artiste, album, fichier, langue, partie, statut: String
    public var retirer: [String]
    public var decompteMesures: Int
    public var steps: [StepState]
    public var paths: SongPaths
    public var padS: Double?
    public var beatsPerBar: Int?
    public var key: String?
    public var bars: [BarInfo]

    public static func decodeList(_ data: Data) throws -> [SongState] {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode([SongState].self, from: data)
    }
}

/// One line of `karaoke traiter --json`.
public enum PipelineEvent: Equatable, Sendable {
    case songStart(id: String)
    case stepStart(id: String, step: String)
    case stepEnd(id: String, step: String, status: String, seconds: Double, error: String)
    case songEnd(id: String, statut: String)
    case log(id: String, line: String)

    public static func parse(_ line: String) -> PipelineEvent? {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ev = o["event"] as? String, let id = o["id"] as? String else { return nil }
        let s = { (k: String) in o[k] as? String ?? "" }
        switch ev {
        case "song_start": return .songStart(id: id)
        case "step_start": return .stepStart(id: id, step: s("step"))
        case "step_end": return .stepEnd(id: id, step: s("step"), status: s("status"),
                                         seconds: (o["seconds"] as? NSNumber)?.doubleValue ?? 0, error: s("error"))
        case "song_end": return .songEnd(id: id, statut: s("statut"))
        case "log": return .log(id: id, line: s("line"))
        default: return nil
        }
    }
}
```

```swift
// karaifyer/Sources/KaraifyerCore/LRC.swift
import Foundation

public struct LyricLine: Equatable, Sendable {
    public var time: Double       // show time, seconds
    public var text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}

/// The pipeline's LRC dialect: `[karaoke:decalage=x.xxx]` + `[mm:ss.cc]text` lines (karaoke/lrc.py).
public enum LRC {
    public static func parse(_ text: String) -> (lines: [LyricLine], decalage: Double?) {
        var lines: [LyricLine] = []
        var dec: Double?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let r = raw.range(of: #"^\[karaoke:decalage=([0-9.]+)\]"#, options: .regularExpression) {
                dec = Double(raw[r].dropFirst("[karaoke:decalage=".count).dropLast())
                continue
            }
            guard let r = raw.range(of: #"^\[\d+:\d+(\.\d+)?\]"#, options: .regularExpression),
                  let t = parseTimecode(String(raw[r].dropFirst().dropLast())) else { continue }
            lines.append(LyricLine(time: t, text: String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
        return (lines.sorted { $0.time < $1.time }, dec)
    }

    public static func format(_ lines: [LyricLine], decalage: Double) -> String {
        "[karaoke:decalage=\(String(format: "%.3f", decalage))]\n"
            + lines.map { "[\(timecode($0.time))]\($0.text)\n" }.joined()
    }

    public static func timecode(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    public static func parseTimecode(_ s: String) -> Double? {
        let p = s.split(separator: ":")
        guard p.count == 2, let m = Double(p[0]), let sec = Double(p[1]) else { return nil }
        return ((m * 60 + sec) * 100).rounded() / 100
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore karaifyer/Tests
git commit -m "karaifyer: core pipeline models (etat, events) and LRC"
```

---

### Task 8: Core: chord grid (Swift twin of `parse_cell`)

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/ChordGrid.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/ChordGridTests.swift`

**Interfaces:**
- Consumes: `ChordAt` (Task 7), and the Task 5 syntax (it must match exactly).
- Produces:

```swift
public enum ChordGrid {
    public static func isValidSymbol(_ s: String) -> Bool
    public static func parseCell(_ cell: String, beatsPerBar: Int) -> Result<[ChordAt], CellError>
    public static func cellText(_ chords: [ChordAt], beatsPerBar: Int) -> String   // inverse of parseCell
    public static func chartText(title: String, artist: String, key: String, bpm: Int?, beatsPerBar: Int, cells: [String]) -> String
    public static func barIndex(at t: Double, bars: [BarInfo]) -> Int?            // input time → bar
}
public struct CellError: Error, Equatable { public let message: String }
```

- [ ] **Step 1: Write the failing test**

```swift
// karaifyer/Tests/KaraifyerCoreTests/ChordGridTests.swift
import Testing
@testable import KaraifyerCore

struct ChordGridTests {
    func ok(_ c: String, _ bpb: Int = 4) -> [ChordAt]? { try? ChordGrid.parseCell(c, beatsPerBar: bpb).get() }

    @Test func sameSemanticsAsPython() {
        #expect(ok("A") == [ChordAt(beat: 0, label: "A")])
        #expect(ok("A B") == [ChordAt(beat: 0, label: "A"), ChordAt(beat: 2, label: "B")])
        #expect(ok("Am . . F") == [ChordAt(beat: 0, label: "Am"), ChordAt(beat: 3, label: "F")])
        #expect(ok("C G Am", 3) == [ChordAt(beat: 0, label: "C"), ChordAt(beat: 1, label: "G"), ChordAt(beat: 2, label: "Am")])
        #expect(ok("Cmaj7 F#m7b5/E") != nil && ok("N.C.") != nil)
        for bad in ["", "H", "A . B", ". A . .", "A B C D E"] { #expect(ok(bad) == nil) }
    }

    @Test func cellTextIsInverse() {
        for c in ["A", "A B", "Am . . F", "C . G .", "N.C."] {
            #expect(ChordGrid.cellText(ok(c)!, beatsPerBar: 4) == c)
        }
        #expect(ChordGrid.cellText([ChordAt(beat: 0, label: "C"), ChordAt(beat: 2, label: "G")], beatsPerBar: 4) == "C G")
    }

    @Test func chartTextParsesBackLikeAccordsTxt() {
        let t = ChordGrid.chartText(title: "Danser", artist: "Loïc Nottet", key: "C# minor", bpm: 100, beatsPerBar: 4,
                                    cells: ["C#m", "A", "A", "A B", "C#m"])
        #expect(t == "Danser — Loïc Nottet\nTonalité : C# minor · 100 BPM · 4/4\n\n| C#m | A | A | A B |\n| C#m |\n")
    }

    @Test func barIndex() {
        let bars = [BarInfo(start: 0, chords: []), BarInfo(start: 2, chords: []), BarInfo(start: 4, chords: [])]
        #expect(ChordGrid.barIndex(at: -1, bars: bars) == nil)
        #expect(ChordGrid.barIndex(at: 2.5, bars: bars) == 1)
        #expect(ChordGrid.barIndex(at: 99, bars: bars) == 2)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing 2>&1 | tail -5`
Expected: compile error, `cannot find 'ChordGrid' in scope`.

- [ ] **Step 3: Implement**

```swift
// karaifyer/Sources/KaraifyerCore/ChordGrid.swift
import Foundation

public struct CellError: Error, Equatable { public let message: String }

/// Chord-grid cells, same syntax as karaoke/chords.py `parse_cell`:
/// `A B` splits the bar evenly; `Am . . F` gives one token per beat, `.` continues the previous chord.
public enum ChordGrid {
    static let symbol = #"^(N\.C\.|[A-G][#b]?(m|maj7|m7b5|m7|m6|7|6|9|dim|aug|sus2|sus4|add9)?(/[A-G][#b]?)?)$"#

    public static func isValidSymbol(_ s: String) -> Bool {
        s.range(of: symbol, options: .regularExpression) != nil
    }

    public static func parseCell(_ cell: String, beatsPerBar: Int) -> Result<[ChordAt], CellError> {
        let toks = cell.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !toks.isEmpty else { return .failure(CellError(message: "mesure vide")) }
        if let bad = toks.first(where: { $0 != "." && !isValidSymbol($0) }) {
            return .failure(CellError(message: "accord non reconnu : \(bad)"))
        }
        if toks.contains(".") {
            guard toks.count == beatsPerBar, toks[0] != "." else {
                return .failure(CellError(message: "\(beatsPerBar) temps attendus, le premier étant un accord"))
            }
            return .success(toks.enumerated().filter { $0.element != "." }.map { ChordAt(beat: $0.offset, label: $0.element) })
        }
        guard toks.count <= beatsPerBar else {
            return .failure(CellError(message: "plus d'accords que de temps (\(beatsPerBar))"))
        }
        return .success(toks.enumerated().map { ChordAt(beat: $0.offset * beatsPerBar / toks.count, label: $0.element) })
    }

    public static func cellText(_ chords: [ChordAt], beatsPerBar: Int) -> String {
        let n = chords.count
        if chords.enumerated().allSatisfy({ $0.element.beat == $0.offset * beatsPerBar / max(n, 1) }) {
            return chords.map(\.label).joined(separator: " ")
        }
        var toks = Array(repeating: ".", count: beatsPerBar)
        for c in chords where c.beat < beatsPerBar { toks[c.beat] = c.label }
        return toks.joined(separator: " ")
    }

    public static func chartText(title: String, artist: String, key: String, bpm: Int?, beatsPerBar: Int,
                                 cells: [String]) -> String {
        var head = "\(title) — \(artist)\nTonalité : \(key)"
        if let bpm { head += " · \(bpm) BPM" }
        head += " · \(beatsPerBar)/4\n\n"
        let rows = stride(from: 0, to: cells.count, by: 4).map { "| " + cells[$0..<min($0 + 4, cells.count)].joined(separator: " | ") + " |" }
        return head + rows.joined(separator: "\n") + "\n"
    }

    public static func barIndex(at t: Double, bars: [BarInfo]) -> Int? {
        bars.lastIndex { $0.start <= t + 1e-6 }
    }
}
```

- [ ] **Step 4: Run tests**

Run: same as Step 2.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/ChordGrid.swift karaifyer/Tests/KaraifyerCoreTests/ChordGridTests.swift
git commit -m "karaifyer: chord grid cells (same syntax as the pipeline)"
```

---

### Task 9: Core: run state machine and time-left estimate

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/RunController.swift`, `karaifyer/Sources/KaraifyerCore/Estimate.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/RunControllerTests.swift`

**Interfaces:**
- Produces:

```swift
public enum RunState: Equatable, Sendable { case idle, running, paused, stopping }
public enum RunSignal: Equatable, Sendable { case stop, cont, term, kill }
public struct Job: Equatable, Sendable { public var id: String; public var forced: String?; public init(id: String, forced: String? = nil) }
public protocol RunDriver: AnyObject {
    func launch(_ job: Job)          // start `traiter --ids job.id [--forcer job.forced] --json`
    func signal(_ s: RunSignal)      // to the running process group
}
@MainActor public final class RunController {
    public private(set) var state: RunState
    public private(set) var current: Job?
    public private(set) var queue: [Job]
    public private(set) var stopAfterCurrent: Bool
    public var onChange: (() -> Void)?
    public init(driver: RunDriver)
    public func start(_ jobs: [Job])         // idle → running (launches first); running → appends (skipping ids already queued/current)
    public func pause(); public func resume()
    public func requestStopAfterCurrent()
    public func stopNow()                    // cont (if paused) + term; state = stopping
    public func killIfStillStopping()        // caller invokes 10 s after stopNow
    public func processExited()              // launch next, or idle
}
public enum Estimate {
    public static func remaining(songsLeft: Int, currentElapsed: Double, measuredSongSeconds: [Double]) -> Double
}
```

- [ ] **Step 1: Write the failing test**

```swift
// karaifyer/Tests/KaraifyerCoreTests/RunControllerTests.swift
import Testing
@testable import KaraifyerCore

final class FakeDriver: RunDriver {
    var calls: [String] = []
    func launch(_ job: Job) { calls.append("launch \(job.id)\(job.forced.map { " +\($0)" } ?? "")") }
    func signal(_ s: RunSignal) { calls.append("\(s)") }
}

@MainActor struct RunControllerTests {
    @Test func runsJobsInSequence() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005"), Job(id: "011", forced: "video")])
        #expect(c.state == .running && c.current?.id == "005")
        c.start([Job(id: "005"), Job(id: "012")])        // already-queued ids not duplicated
        c.processExited(); c.processExited(); c.processExited()
        #expect(d.calls == ["launch 005", "launch 011 +video", "launch 012"] && c.state == .idle)
    }

    @Test func pauseResumeNeverTimesOut() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005")]); c.pause()
        #expect(c.state == .paused)
        c.killIfStillStopping()                          // no effect while merely paused (overnight pause)
        c.resume()
        #expect(c.state == .running && d.calls == ["launch 005", "stop", "cont"])
    }

    @Test func stopAfterCurrentFinishesThenIdles() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005"), Job(id: "011")]); c.requestStopAfterCurrent(); c.processExited()
        #expect(c.state == .idle && c.queue.isEmpty && d.calls == ["launch 005"])
    }

    @Test func stopNowFromPausedContinuesThenTerminatesThenKills() {
        let d = FakeDriver(); let c = RunController(driver: d)
        c.start([Job(id: "005"), Job(id: "011")]); c.pause(); c.stopNow()
        #expect(c.state == .stopping)
        c.killIfStillStopping()
        c.processExited()
        #expect(d.calls == ["launch 005", "stop", "cont", "term", "kill"] && c.state == .idle && c.queue.isEmpty)
    }

    @Test func estimate() {
        #expect(Estimate.remaining(songsLeft: 3, currentElapsed: 100, measuredSongSeconds: []) == 3 * 420 - 100)
        #expect(Estimate.remaining(songsLeft: 2, currentElapsed: 50, measuredSongSeconds: [300, 500]) == 750)
        #expect(Estimate.remaining(songsLeft: 1, currentElapsed: 9999, measuredSongSeconds: []) == 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing 2>&1 | tail -5`
Expected: compile error, `cannot find type 'RunDriver' in scope`.

- [ ] **Step 3: Implement**

```swift
// karaifyer/Sources/KaraifyerCore/RunController.swift
import Foundation

public enum RunState: Equatable, Sendable { case idle, running, paused, stopping }
public enum RunSignal: Equatable, Sendable { case stop, cont, term, kill }

public struct Job: Equatable, Sendable {
    public var id: String
    public var forced: String?
    public init(id: String, forced: String? = nil) { self.id = id; self.forced = forced }
}

public protocol RunDriver: AnyObject {
    func launch(_ job: Job)
    func signal(_ s: RunSignal)
}

/// One pipeline process per song, in sequence. Pause/resume = SIGSTOP/SIGCONT on the process
/// group; stop now = SIGCONT + SIGTERM, then SIGKILL if it is still alive after 10 s.
@MainActor public final class RunController {
    public private(set) var state: RunState = .idle
    public private(set) var current: Job?
    public private(set) var queue: [Job] = []
    public private(set) var stopAfterCurrent = false
    public var onChange: (() -> Void)?
    private let driver: RunDriver

    public init(driver: RunDriver) { self.driver = driver }

    public func start(_ jobs: [Job]) {
        let busy = Set(queue.map(\.id) + [current?.id].compactMap { $0 })
        queue += jobs.filter { !busy.contains($0.id) }
        if state == .idle { stopAfterCurrent = false; launchNext() }
        onChange?()
    }

    public func pause() {
        guard state == .running else { return }
        driver.signal(.stop); state = .paused; onChange?()
    }

    public func resume() {
        guard state == .paused else { return }
        driver.signal(.cont); state = .running; onChange?()
    }

    public func requestStopAfterCurrent() { stopAfterCurrent = true; onChange?() }

    public func stopNow() {
        guard state == .running || state == .paused else { return }
        if state == .paused { driver.signal(.cont) }
        driver.signal(.term)
        queue.removeAll(); state = .stopping; onChange?()
    }

    public func killIfStillStopping() {
        if state == .stopping { driver.signal(.kill) }
    }

    public func processExited() {
        current = nil
        if state == .stopping || stopAfterCurrent { queue.removeAll(); state = .idle; stopAfterCurrent = false }
        else { launchNext() }
        onChange?()
    }

    private func launchNext() {
        guard !queue.isEmpty else { state = .idle; return }
        current = queue.removeFirst()
        state = .running
        driver.launch(current!)
    }
}
```

```swift
// karaifyer/Sources/KaraifyerCore/Estimate.swift
import Foundation

public enum Estimate {
    /// Seconds left: songs left × mean measured song time (7 min when nothing measured), minus
    /// the time already spent on the current song.
    public static func remaining(songsLeft: Int, currentElapsed: Double, measuredSongSeconds: [Double]) -> Double {
        let per = measuredSongSeconds.isEmpty ? 420 : measuredSongSeconds.reduce(0, +) / Double(measuredSongSeconds.count)
        return max(0, Double(songsLeft) * per - currentElapsed)
    }
}
```

(The `songsLeft` count includes the current song.)

- [ ] **Step 4: Run tests**

Run: same as Step 2.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/RunController.swift karaifyer/Sources/KaraifyerCore/Estimate.swift karaifyer/Tests/KaraifyerCoreTests/RunControllerTests.swift
git commit -m "karaifyer: run state machine (pause/resume/stop) and time-left estimate"
```

---

### Task 10: App: process plumbing and the Karaoké model

**Files:**
- Create: `karaifyer/Sources/Karaifyer/Spawn.swift`, `Pipeline.swift`, `KaraokeModel.swift`

**Interfaces:**
- Consumes: `RunController`, `RunDriver`, `PipelineEvent`, `SongState`, `Estimate` (Tasks 7–9).
- Produces:
  - `SpawnedProcess(args:env:cwd:onLine:onExit:)`: launches the command in a new process group and streams stdout+stderr lines; `signal(Int32)` sends to the group;
  - `Pipeline` (settings plus command helpers): `karaokeHome`, `gabarit`, `projectDir`, `uvPath`, `env`, `problems() -> [String]`, `run(_ args:) async -> (code, out, err)` for short commands, and `traiterArgs(job)`;
  - `@Observable KaraokeModel`:
    - `songs: [SongState]`, `selection: Set<String>`, `log: [String]` (capped at 5000), `banner: String?`;
    - `runState`, `currentID`, `currentStep`, `progress: Double`, `etaText`;
    - `refresh()`, `add(files:)`, `set(id:field:value:)`;
    - `analyse(ids:forced:)`, `pause()`, `resume()`, `stopAfterCurrent()`, `stopNow()`.

This task wires live processes. TDD stops at the Core boundary: the logic here is thin glue around tested Core types. Verify it with the commands in Step 4.

- [ ] **Step 1: Spawn.swift**

```swift
// karaifyer/Sources/Karaifyer/Spawn.swift
import Foundation

/// A child process in its own process group (so SIGSTOP/SIGCONT/SIGTERM reach uv, Python and the
/// ML tool it starts), with stdout+stderr streamed line by line on the main queue.
final class SpawnedProcess {
    private(set) var pid: pid_t = 0
    private let onLine: (String) -> Void
    private let onExit: (Int32) -> Void
    private var buffer = Data()

    init(args: [String], env: [String: String], cwd: String,
         onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) throws {
        self.onLine = onLine; self.onExit = onExit
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        posix_spawn_file_actions_addclose(&fa, fds[0])
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) }
                posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }
        let rc = posix_spawn(&pid, args[0], &fa, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT) }
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        reader.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { self?.consume(chunk) }
            if chunk.isEmpty { h.readabilityHandler = nil }
        }
        let p = pid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(p, &status, 0)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
            DispatchQueue.main.async { self?.onExit(code) }
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            onLine(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if chunk.isEmpty, !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
    }

    func signal(_ sig: Int32) { if pid > 0 { kill(-pid, sig) } }
}
```

- [ ] **Step 2: Pipeline.swift**

```swift
// karaifyer/Sources/Karaifyer/Pipeline.swift
import Foundation
import KaraifyerCore

/// Settings + how to call the karaoke command line (uv run --project <karaoke> karaoke …).
struct Pipeline {
    var karaokeHome: String { UserDefaults.standard.string(forKey: "karaokeHome") ?? "/Volumes/Hypermnesia/karaoke" }
    var gabarit: String {
        UserDefaults.standard.string(forKey: "gabarit") ?? karaokeHome + "/gabarit/gabarit Project/gabarit.als"
    }
    var projectDir: String {
        UserDefaults.standard.string(forKey: "projectDir")
            ?? NSHomeDirectory() + "/Documents/mp3-pipeline/karaoke"
    }
    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"]
    var uvPath: String? {
        Self.searchPath.map { $0 + "/uv" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = Self.searchPath.joined(separator: ":")
        e["KARAOKE_HOME"] = karaokeHome
        e["KARAOKE_GABARIT"] = gabarit
        e["PYTHONUNBUFFERED"] = "1"
        e.removeValue(forKey: "VIRTUAL_ENV")
        return e
    }

    /// Blocking problems, in French, for the banner (empty = ready).
    func problems() -> [String] {
        var p: [String] = []
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: karaokeHome, isDirectory: &isDir) || !isDir.boolValue {
            p.append("Dossier karaoké introuvable : \(karaokeHome) (disque branché ?)")
        }
        if uvPath == nil { p.append("uv introuvable (installer uv ou vérifier /opt/homebrew/bin)") }
        if !FileManager.default.fileExists(atPath: projectDir + "/pyproject.toml") {
            p.append("Projet karaoke introuvable : \(projectDir) (Réglages)")
        }
        return p
    }

    var manifestExists: Bool { FileManager.default.fileExists(atPath: karaokeHome + "/manifeste.csv") }

    func args(_ sub: [String]) -> [String] { [uvPath ?? "uv", "run", "--project", projectDir, "karaoke"] + sub }

    func traiterArgs(_ job: Job) -> [String] {
        args(["traiter", "--ids", job.id, "--json"] + (job.forced.map { ["--forcer", $0] } ?? []))
    }

    /// Short commands (etat, modifier, ajouter, manifeste): run to completion off the main thread.
    func run(_ sub: [String]) async -> (code: Int32, out: String, err: String) {
        let a = args(sub), e = env, cwd = projectDir
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: a[0]); p.arguments = Array(a.dropFirst())
                p.environment = e; p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let o = Pipe(), er = Pipe(); p.standardOutput = o; p.standardError = er
                do { try p.run() } catch { cont.resume(returning: (-1, "", "\(error)")); return }
                let od = o.fileHandleForReading.readDataToEndOfFile()
                let ed = er.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: od, as: UTF8.self),
                                        String(decoding: ed, as: UTF8.self)))
            }
        }
    }
}
```

- [ ] **Step 3: KaraokeModel.swift**

```swift
// karaifyer/Sources/Karaifyer/KaraokeModel.swift
import AppKit
import Foundation
import IOKit.pwr_mgt
import KaraifyerCore
import Observation

@MainActor @Observable
final class KaraokeModel: RunDriver {
    static let shared = KaraokeModel()
    var pipeline = Pipeline()
    var songs: [SongState] = []
    var selection: Set<String> = []
    var log: [String] = []
    var banner: String?
    var runState: RunState = .idle
    var currentID: String?
    var currentStep: String?
    var stopAfterCurrentRequested = false
    private(set) var doneSteps = 0
    private(set) var plannedSteps = 0
    private var songsLeft = 0
    private var songStarted = Date()
    private var measured: [Double] = []
    @ObservationIgnored private var controller: RunController!
    @ObservationIgnored private var process: SpawnedProcess?
    @ObservationIgnored private var sleepAssertion: IOPMAssertionID = 0

    init() {
        controller = RunController(driver: self)
        controller.onChange = { [weak self] in self?.syncState() }
    }

    var progress: Double { plannedSteps == 0 ? 0 : Double(doneSteps) / Double(plannedSteps) }
    var etaText: String {
        let s = Estimate.remaining(songsLeft: songsLeft, currentElapsed: Date().timeIntervalSince(songStarted),
                                   measuredSongSeconds: measured)
        return String(format: "reste ≈ %d h %02d", Int(s) / 3600, (Int(s) % 3600) / 60)
    }
    var statusLine: String {
        guard runState != .idle, let id = currentID, let s = songs.first(where: { $0.id == id }) else { return "" }
        let n = plannedSongs - songsLeft + 1
        let pause = runState == .paused ? "En pause · " : ""
        return "\(pause)Morceau \(n)/\(plannedSongs) · \(s.id) \(s.titre) · étape : \(currentStep ?? "…") · \(etaText)"
    }
    private var plannedSongs = 0

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    func refresh() async {
        let problems = pipeline.problems()
        banner = problems.first ?? (pipeline.manifestExists ? nil : "Pas encore de manifeste.")
        guard problems.isEmpty, pipeline.manifestExists else { songs = []; return }
        let r = await pipeline.run(["etat", "--json"])
        if r.code == 0, let list = try? SongState.decodeList(Data(r.out.utf8)) {
            songs = list
            measured = list.compactMap { s in
                s.steps.allSatisfy { $0.status == "a_jour" } ? s.steps.compactMap(\.seconds).reduce(0, +) : nil
            }.filter { $0 > 0 }
        } else {
            banner = "Lecture de l'état impossible : " + r.err.split(separator: "\n").suffix(2).joined(separator: " ")
        }
    }

    func createManifest(from folder: URL) async {
        let r = await pipeline.run(["manifeste", "--audio", folder.path])
        appendLog(r.out + r.err); await refresh()
    }

    func add(files: [URL]) async {
        let r = await pipeline.run(["ajouter"] + files.map(\.path))
        appendLog(r.code == 0 ? "Ajout : \(r.out)" : "Ajout impossible : \(r.err)")
        await refresh()
    }

    /// Returns an error message (French) or nil.
    func set(id: String, field: String, value: String) async -> String? {
        let r = await pipeline.run(["modifier", "--id", id, "--champ", field, "--valeur", value])
        await refresh()
        return r.code == 0 ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func analyse(ids: [String], forced: String? = nil) {
        let jobs = (ids.isEmpty ? songs.map(\.id) : ids).map { Job(id: $0, forced: forced) }
        plannedSongs += jobs.count; songsLeft += jobs.count
        plannedSteps += jobs.count * max(1, songs.first?.steps.count ?? 10)
        controller.start(jobs)
    }
    func pause() { controller.pause() }
    func resume() { controller.resume() }
    func stopAfterCurrent() { controller.requestStopAfterCurrent() }
    func stopNow() {
        controller.stopNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.controller.killIfStillStopping() }
    }

    // MARK: RunDriver
    nonisolated func launch(_ job: Job) {
        MainActor.assumeIsolated {
            currentID = job.id; currentStep = nil; songStarted = Date()
            do {
                process = try SpawnedProcess(args: pipeline.traiterArgs(job), env: pipeline.env, cwd: pipeline.projectDir,
                                             onLine: { [weak self] in self?.handle(line: $0) },
                                             onExit: { [weak self] code in self?.exited(code) })
            } catch {
                appendLog("Lancement impossible : \(error)"); exited(-1)
            }
        }
    }

    nonisolated func signal(_ s: RunSignal) {
        MainActor.assumeIsolated {
            let sig: Int32 = switch s { case .stop: SIGSTOP; case .cont: SIGCONT; case .term: SIGTERM; case .kill: SIGKILL }
            process?.signal(sig)
        }
    }

    private func handle(line: String) {
        guard let ev = PipelineEvent.parse(line) else { appendLog(line); return }
        switch ev {
        case .songStart(let id): appendLog("▶ \(id)")
        case .stepStart(let id, let step): currentStep = step; appendLog("[\(id)] début \(step)")
        case .stepEnd(let id, let step, let status, let secs, let err):
            doneSteps += 1
            appendLog("[\(id)] \(step) : \(status) (\(String(format: "%.0f", secs)) s)\(err.isEmpty ? "" : " — \(err)")")
            if let i = songs.firstIndex(where: { $0.id == id }), let j = songs[i].steps.firstIndex(where: { $0.name == step }) {
                songs[i].steps[j].status = ["fait", "saute"].contains(status) ? "a_jour" : status
                songs[i].steps[j].error = err
            }
        case .songEnd(let id, let statut): appendLog("■ \(id) → \(statut)")
        case .log(let id, let l): if !l.hasPrefix("début ") && !l.hasPrefix("fin ") { appendLog("[\(id)] \(l)") }
        }
    }

    private func exited(_ code: Int32) {
        if code != 0 { appendLog("[\(currentID ?? "?")] processus terminé (code \(code))") }
        measured.append(Date().timeIntervalSince(songStarted))
        songsLeft = max(0, songsLeft - 1); process = nil
        controller.processExited()
        Task { await refresh() }
    }

    private func syncState() {
        runState = controller.state
        stopAfterCurrentRequested = controller.stopAfterCurrent
        if runState == .idle {
            currentID = nil; currentStep = nil; plannedSongs = 0; songsLeft = 0; plannedSteps = 0; doneSteps = 0
            if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
        } else if sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Karaifyer analyse" as CFString, &sleepAssertion)
        }
    }
}
```

**Rule for the measured time:** append the song's measured time only when the song actually ran. That is the case here, because `exited` runs only for launched jobs.

- [ ] **Step 4: Build and smoke-test against the real pipeline**

Run:
```bash
cd karaifyer && swift build 2>&1 | grep -E "error|warning: unre|Compiling|Build" | tail -5
```
Expected: build OK.

Then check by hand, with a throwaway `swift run`-free check through the real CLI: `uv --directory ../karaoke run karaoke etat --json | head -c 300` prints JSON. The UI wiring is exercised in Task 11.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/Karaifyer/Spawn.swift karaifyer/Sources/Karaifyer/Pipeline.swift karaifyer/Sources/Karaifyer/KaraokeModel.swift
git commit -m "karaifyer: process group spawning, pipeline commands, Karaoké model"
```

---

### Task 11: App: Karaoké tab (toolbar, table, progress, terminal), tabs, menu bar

**Files:**
- Create: `karaifyer/Sources/Karaifyer/KaraokeView.swift`
- Modify: `karaifyer/Sources/Karaifyer/KaraifyerApp.swift` (window with a `TabView`; menu-bar analysis items)

**Interfaces:**
- Consumes: `KaraokeModel` (Task 10); `QueueView` / `QueueModel` (copied).
- Produces: `KaraokeView(model:)`; the window shows the « Enregistrement » and « Karaoké » tabs; the menu bar shows the analysis status and its controls.

- [ ] **Step 1: KaraokeView.swift**

```swift
// karaifyer/Sources/Karaifyer/KaraokeView.swift
import AppKit
import KaraifyerCore
import SwiftUI
import UniformTypeIdentifiers

let STEP_NAMES = ["ingest", "separate", "beats", "vocals_split", "chords", "package", "lyrics", "check", "video", "set"]
let RETIRER = [("guitar", "Guit."), ("bass", "Basse"), ("piano", "Piano"), ("drums", "Batt."), ("other", "Autres")]
let LANGUES = ["fr", "en", "es", "it", "de", "pt"]

struct KaraokeView: View {
    @Bindable var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow
    var terminalShown: Bool { UserDefaults.standard.object(forKey: "terminalShown") as? Bool ?? true }
    @Bindable private var ui = KaraokeUI.shared

    var body: some View {
        VStack(spacing: 0) {
            if let b = model.banner { bannerView(b) }
            toolbar.padding(8)
            table
            footer
        }
        .task { await model.refresh() }
        .alert(ui.alert ?? "", isPresented: Binding(get: { ui.alert != nil }, set: { if !$0 { ui.alert = nil } })) {}
    }

    func bannerView(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
            Spacer()
            if !model.pipeline.manifestExists && model.pipeline.problems().isEmpty {
                Button("Créer le manifeste depuis un dossier SysRec…") { pickFolder { url in Task { await model.createManifest(from: url) } } }
            }
            Button("Réessayer") { Task { await model.refresh() } }
        }
        .padding(8).background(.orange.opacity(0.12))
    }

    var toolbar: some View {
        HStack {
            Button("Ajouter des morceaux…", systemImage: "plus") { pickFiles { urls in Task { await model.add(files: urls) } } }
            Divider().frame(height: 18)
            Button("Analyser", systemImage: "play.fill") { model.analyse(ids: Array(model.selection)) }
                .disabled(model.banner != nil)
            switch model.runState {
            case .running: Button("Pause", systemImage: "pause.fill") { model.pause() }
            case .paused: Button("Reprendre", systemImage: "playpause.fill") { model.resume() }
            default: EmptyView()
            }
            if model.runState == .running || model.runState == .paused {
                Button(model.stopAfterCurrentRequested ? "Arrêt après ce morceau…" : "Arrêter après ce morceau") { model.stopAfterCurrent() }
                    .disabled(model.stopAfterCurrentRequested)
                Button("Arrêter maintenant", systemImage: "stop.fill") { model.stopNow() }
            }
            Spacer()
            Button("Rapport") { open(model.pipeline.karaokeHome + "/rapport.html") }
            Button("iReal Pro") {
                let dir = model.pipeline.karaokeHome + "/ireal"
                let pages = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".html") } ?? []
                open(pages.count == 1 ? dir + "/" + pages[0] : dir)
            }
            Button("", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.help("Actualiser")
        }
    }

    var table: some View {
        Table(model.songs, selection: $model.selection) {
            TableColumn("id") { s in Text(s.id).monospacedDigit() }.width(36)
            TableColumn("Titre") { s in EditText(value: s.titre) { commit(s, "titre", $0) } }
            TableColumn("Artiste") { s in EditText(value: s.artiste) { commit(s, "artiste", $0) } }
            TableColumn("Retirer (joué en live)") { s in
                HStack(spacing: 6) {
                    ForEach(RETIRER, id: \.0) { stem, label in
                        Toggle(label, isOn: Binding(get: { s.retirer.contains(stem) }, set: { on in
                            var r = s.retirer.filter { $0 != stem }; if on { r.append(stem) }
                            commit(s, "retirer", RETIRER.map(\.0).filter(r.contains).joined(separator: ";"))
                        })).toggleStyle(.checkbox).font(.caption)
                    }
                }
            }.width(min: 300)
            TableColumn("Langue") { s in
                Picker("", selection: Binding(get: { s.langue }, set: { commit(s, "langue", $0) })) {
                    ForEach(LANGUES, id: \.self) { Text($0) }
                }.labelsHidden()
            }.width(64)
            TableColumn("Partie") { s in EditText(value: s.partie) { commit(s, "partie", $0) } }.width(110)
            TableColumn("Statut") { s in Text(s.statut).foregroundStyle(color(statut: s.statut)) }.width(70)
            TableColumn("Étapes") { s in
                HStack(spacing: 3) {
                    ForEach(s.steps, id: \.name) { st in
                        Circle().fill(color(step: st, running: model.currentID == s.id && model.currentStep == st.name))
                            .frame(width: 9, height: 9)
                            .help("\(st.name) : \(st.status)\(st.error?.isEmpty == false ? "\n\(st.error!)" : "")")
                    }
                }
            }.width(130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let s = model.songs.first(where: { $0.id == id }) {
                Button("Ouvrir le dossier") { open(s.paths.dossier) }
                Button("Ouvrir la vidéo") { open(s.paths.video) }
                Button("Ouvrir le set Ableton") { open(s.paths.set) }
                Button("Ouvrir la grille d'accords") { open(s.paths.accords) }
                Button("Voir le journal") { open(model.pipeline.karaokeHome + "/travail/\(s.id)/journal.log") }
                Divider()
                Button("Corriger paroles et accords…") { openWindow(id: "editor", value: s.id) }
                Button("Refaire le morceau") { model.analyse(ids: Array(ids), forced: "ingest") }
                Menu("Refaire une étape") {
                    ForEach(STEP_NAMES, id: \.self) { st in Button(st) { model.analyse(ids: Array(ids), forced: st) } }
                }
            }
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.runState != .idle {
                ProgressView(value: model.progress)
                Text(model.statusLine).font(.caption).monospacedDigit()
            }
            DisclosureGroup("Terminal", isExpanded: $ui.terminalShown) {
                TerminalView(lines: model.log).frame(minHeight: 160, idealHeight: 200)
                HStack { Spacer(); Button("Copier") { copy(model.log.joined(separator: "\n")) } }
            }
        }
        .padding(8)
    }

    func commit(_ s: SongState, _ field: String, _ value: String) {
        Task { if let err = await model.set(id: s.id, field: field, value: value) { ui.alert = err } }
    }
}

/// UI-only state kept outside the view (no @State without Xcode).
@Observable final class KaraokeUI {
    static let shared = KaraokeUI()
    var alert: String?
    var terminalShown = true
}

/// Text cell that commits on Return / focus loss, not on every keystroke.
struct EditText: View {
    let value: String
    let onCommit: (String) -> Void
    var body: some View {
        TextField("", text: Binding(get: { value }, set: { _ in }), onCommit: {})
            .onSubmit {}
            .overlay(CommitField(value: value, onCommit: onCommit))
    }
}

/// AppKit text field (commits on end-editing); SwiftUI's TextField needs @State to hold a draft.
struct CommitField: NSViewRepresentable {
    let value: String
    let onCommit: (String) -> Void
    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: value)
        f.isBordered = false; f.drawsBackground = false; f.delegate = context.coordinator
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) {
        if f.currentEditor() == nil { f.stringValue = value }
        context.coordinator.onCommit = onCommit; context.coordinator.original = value
    }
    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, original: value) }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void; var original: String
        init(onCommit: @escaping (String) -> Void, original: String) { self.onCommit = onCommit; self.original = original }
        func controlTextDidEndEditing(_ n: Notification) {
            guard let f = n.object as? NSTextField, f.stringValue != original else { return }
            onCommit(f.stringValue)
        }
    }
}

/// Monospaced, auto-scrolling log.
struct TerminalView: NSViewRepresentable {
    let lines: [String]
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false; tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = .textBackgroundColor
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        let atBottom = sv.contentView.bounds.maxY >= (tv.bounds.height - 20)
        tv.string = lines.joined(separator: "\n")
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }
}

func color(statut: String) -> Color {
    switch statut { case "ok": .green; case "alerte": .orange; case "echec": .red; case "a_reessayer": .yellow; default: .secondary }
}

func color(step: StepState, running: Bool) -> Color {
    if running { return .blue }
    switch step.status { case "a_jour": return .green; case "echec": return .red
    case "bloque", "a_reessayer": return .orange; default: return .gray.opacity(0.4) }
}

func open(_ path: String) {
    if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    else { KaraokeUI.shared.alert = "Introuvable : \(path)" }
}

func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

func pickFiles(_ done: @escaping ([URL]) -> Void) {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true; p.canChooseDirectories = false
    p.allowedContentTypes = [.audio]
    if p.runModal() == .OK { done(p.urls) }
}

func pickFolder(_ done: @escaping (URL) -> Void) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = false
    if p.runModal() == .OK, let u = p.url { done(u) }
}
```

**Executor note on `EditText`:** without `@State`, use `CommitField` directly as the cell, `CommitField(value: s.titre) { commit(s, "titre", $0) }`, and delete the `EditText` wrapper if the overlay misbehaves. Record which one you kept in the ledger. Replace `@Bindable private var ui = KaraokeUI.shared` with a plain `let ui = KaraokeUI.shared` plus `Bindable(ui).terminalShown` where a binding is needed, if `@Bindable` on a stored default doesn't compile.

- [ ] **Step 2: Tabs and menu bar in KaraifyerApp.swift**

Replace the `Window` scene's content with:

```swift
        Window("Karaifyer", id: "queue") {
            TabView {
                QueueView(model: model)
                    .tabItem { Label("Enregistrement", systemImage: "record.circle") }
                KaraokeView(model: KaraokeModel.shared)
                    .tabItem { Label("Karaoké", systemImage: "music.mic") }
            }
            .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1180, height: 720)

        WindowGroup("Corriger", id: "editor", for: String.self) { $songID in
            if let id = songID { EditorView(model: EditorModel(songID: id, karaoke: KaraokeModel.shared)) }
        }
        .defaultSize(width: 1100, height: 700)

        Settings { SettingsView() }
```

In `MenuContent`, add a section after the `Text("\(c.done)/\(c.total) done" …)` line:

```swift
        let k = KaraokeModel.shared
        if k.runState != .idle {
            Divider()
            Text(k.statusLine)
            if k.runState == .running { Button("Pause de l'analyse") { k.pause() } }
            if k.runState == .paused { Button("Reprendre l'analyse") { k.resume() } }
            Button("Arrêter l'analyse après ce morceau") { k.stopAfterCurrent() }
            Button("Arrêter l'analyse maintenant") { k.stopNow() }
        }
```

The `EditorView`, `EditorModel` and `SettingsView` types arrive in Tasks 12–13. To build this task alone, add temporary stubs at the bottom of `KaraokeView.swift`:

```swift
struct SettingsView: View { var body: some View { Text("Réglages") } }
```

plus `EditorModel` / `EditorView` placeholder structs. Task 12 replaces them. Record this in the ledger.

**Recording conflict (spec §3):** in `QueueModel.start()` (the copied recorder), at its very beginning:

```swift
        if KaraokeModel.shared.runState == .running {
            let a = NSAlert()
            a.messageText = "Une analyse karaoké est en cours"
            a.informativeText = "La mettre en pause pendant l'enregistrement ? (la charge peut provoquer des coupures)"
            a.addButton(withTitle: "Mettre en pause"); a.addButton(withTitle: "Continuer les deux")
            if a.runModal() == .alertFirstButtonReturn { KaraokeModel.shared.pause() }
        }
```

`QueueModel` isn't `@MainActor`-isolated in SysRec. If the compiler complains, wrap the block in `MainActor.assumeIsolated { … }`, as SysRec's AppDelegate does.

- [ ] **Step 3: Build, launch, smoke-check**

Run:
```bash
cd karaifyer && ./build-app.sh | tail -1 && open Karaifyer.app
```
Expected: the app launches, the menu-bar icon appears, and **Open Queue…** shows both tabs. In the Karaoké tab, the 4 test songs appear with green step dots. Click Analyser with nothing selected: the terminal pane shows `▶ 005`, `[005] ingest : saute (0 s)` and so on, and the run goes idle after the 4 songs (all skipped). Check that `/Volumes/Hypermnesia/karaoke/manifeste.csv` was not modified (`git diff`-free: compare `md5` before and after).

- [ ] **Step 4: Commit**

```bash
git add karaifyer/Sources/Karaifyer
git commit -m "karaifyer: Karaoké tab (manifest table, run controls, progress, terminal) and menu bar"
```

---

### Task 12: App: correction editor (lyrics + chords + player)

**Files:**
- Create: `karaifyer/Sources/Karaifyer/EditorModel.swift`, `karaifyer/Sources/Karaifyer/EditorView.swift` (and remove the Task 11 stubs)

**Interfaces:**
- Consumes: `SongState` (paths, padS, bars, beatsPerBar, key), `LRC`, `ChordGrid`, `KaraokeModel.analyse(ids:)`.
- Produces:
  - `EditorModel(songID:karaoke:)` with:
    - `lines: [LyricLine]` (show time), `cells: [String]`, `key: String`;
    - `position: Double` (input time), `playing`, `dirty`;
    - `cellErrors: [Int: String]`;
    - `currentLine: Int?`, `currentBar: Int?`;
    - `play()`, `pause()`, `seek(input:)`, `seekLine(_:)`, `seekBar(_:)`, `stampLine(_:)`, `save() throws`.
  - `EditorView(model:)`.

- [ ] **Step 1: EditorModel.swift**

```swift
// karaifyer/Sources/Karaifyer/EditorModel.swift
import AVFoundation
import Foundation
import KaraifyerCore
import Observation

/// One song's lyrics + chord grid, with playback of travail/<id>/input.wav (input time).
/// Lyrics are in show time (= input + pad_s), like paroles.lrc; bars are in input time.
@MainActor @Observable
final class EditorModel {
    let song: SongState
    let karaoke: KaraokeModel
    var lines: [LyricLine] = []
    var cells: [String] = []
    var key: String
    var position: Double = 0
    var playing = false
    var dirty = false
    var selectedLine: Int?
    var loadError: String?
    var pad: Double { song.padS ?? 0 }
    var bpb: Int { song.beatsPerBar ?? 4 }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    init(songID: String, karaoke: KaraokeModel) {
        self.karaoke = karaoke
        song = karaoke.songs.first { $0.id == songID }!
        key = song.key ?? "C major"
        let fm = FileManager.default
        let lrcPath = fm.fileExists(atPath: song.paths.lrcCorrige) ? song.paths.lrcCorrige : song.paths.lrc
        if let t = try? String(contentsOfFile: lrcPath, encoding: .utf8) {
            let (l, dec) = LRC.parse(t)
            lines = dec == nil ? l.map { LyricLine(time: $0.time + pad, text: $0.text) } : l   // no tag = input time
        }
        cells = song.bars.map { ChordGrid.cellText($0.chords, beatsPerBar: bpb) }
        if song.padS == nil || song.bars.isEmpty { loadError = "Morceau pas encore analysé (paroles/accords absents)." }
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: song.paths.audio))
        player?.prepareToPlay()
        if player == nil { loadError = (loadError ?? "") + " Audio introuvable : \(song.paths.audio)" }
    }

    var duration: Double { player?.duration ?? 0 }
    var showTime: Double { position + pad }
    var currentLine: Int? { lines.lastIndex { $0.time <= showTime + 1e-6 } }
    var currentBar: Int? { ChordGrid.barIndex(at: position, bars: song.bars) }
    var cellErrors: [Int: String] {
        var e: [Int: String] = [:]
        for (i, c) in cells.enumerated() {
            if case .failure(let err) = ChordGrid.parseCell(c, beatsPerBar: bpb) { e[i] = err.message }
        }
        return e
    }

    func play() {
        player?.play(); playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                self.position = p.currentTime
                if !p.isPlaying { self.pause() }
            }
        }
    }
    func pause() { player?.pause(); playing = false; timer?.invalidate(); timer = nil }
    func seek(input t: Double) { player?.currentTime = max(0, min(t, duration)); position = player?.currentTime ?? 0 }
    func seekLine(_ i: Int) { selectedLine = i; seek(input: lines[i].time - pad) }
    func seekBar(_ i: Int) { seek(input: song.bars[i].start) }

    func stampLine(_ i: Int) {
        lines[i].time = (showTime * 100).rounded() / 100
        lines.sort { $0.time < $1.time }
        dirty = true
    }
    func setText(_ i: Int, _ text: String) { lines[i].text = text; dirty = true }
    func setTime(_ i: Int, _ s: String) {
        if let t = LRC.parseTimecode(s) { lines[i].time = t; lines.sort { $0.time < $1.time }; dirty = true }
    }
    func addLine() { lines.append(LyricLine(time: (showTime * 100).rounded() / 100, text: "")); lines.sort { $0.time < $1.time }; dirty = true }
    func deleteLine(_ i: Int) { lines.remove(at: i); dirty = true }
    func setCell(_ i: Int, _ text: String) { cells[i] = text; dirty = true }

    struct SaveError: LocalizedError { let errorDescription: String? }

    /// Writes paroles/<id>.lrc and accords/<id>.txt, then re-runs the song.
    func save() throws {
        if let (i, msg) = cellErrors.sorted(by: { $0.key < $1.key }).first {
            throw SaveError(errorDescription: "Mesure \(i + 1) : \(msg)")
        }
        let fm = FileManager.default
        for p in [song.paths.lrcCorrige, song.paths.accordsCorrige] {
            try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try LRC.format(lines, decalage: pad).write(toFile: song.paths.lrcCorrige, atomically: true, encoding: .utf8)
        try ChordGrid.chartText(title: song.titre, artist: song.artiste, key: key, bpm: nil, beatsPerBar: bpb, cells: cells)
            .write(toFile: song.paths.accordsCorrige, atomically: true, encoding: .utf8)
        dirty = false
        karaoke.analyse(ids: [song.id])
    }
}
```

**Corrected file is a no-op:** if a corrected file equals what the pipeline would produce anyway, the run is a cheap no-op. That's intended.

- [ ] **Step 2: EditorView.swift**

```swift
// karaifyer/Sources/Karaifyer/EditorView.swift
import KaraifyerCore
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let e = model.loadError { Text(e).foregroundStyle(.orange).padding(6) }
            playerBar.padding(8)
            HSplitView {
                lyrics.frame(minWidth: 420)
                chords.frame(minWidth: 420)
            }
            HStack {
                Spacer()
                Button("Annuler") { closeAsking() }
                Button("Enregistrer") {
                    do { try model.save(); dismiss() } catch { KaraokeUI.shared.alert = error.localizedDescription }
                }
                .keyboardShortcut("s").disabled(!model.dirty)
            }.padding(8)
        }
        .navigationTitle("Corriger — \(model.song.id) \(model.song.titre)")
        .onDisappear { model.pause() }
    }

    var playerBar: some View {
        HStack {
            Button(model.playing ? "Pause" : "Lecture", systemImage: model.playing ? "pause.fill" : "play.fill") {
                model.playing ? model.pause() : model.play()
            }.keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { model.position }, set: { model.seek(input: $0) }), in: 0...max(model.duration, 1))
            Text(LRC.timecode(model.showTime)).monospacedDigit().frame(width: 70)
        }
    }

    var lyrics: some View {
        VStack(alignment: .leading) {
            HStack { Text("Paroles").font(.headline); Spacer()
                     Button("Ligne", systemImage: "plus") { model.addLine() } }
            List {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { i, line in
                    HStack {
                        Button("", systemImage: "stopwatch") { model.stampLine(i) }.help("Caler sur la lecture")
                        CommitField(value: LRC.timecode(line.time)) { model.setTime(i, $0) }.frame(width: 70)
                        CommitField(value: line.text) { model.setText(i, $0) }
                        Button("", systemImage: "trash") { model.deleteLine(i) }.buttonStyle(.borderless)
                    }
                    .padding(2)
                    .background(i == model.currentLine ? Color.yellow.opacity(0.25) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.seekLine(i) }
                }
            }
        }.padding(8)
    }

    var chords: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Accords").font(.headline)
                Text("Tonalité :"); CommitField(value: model.key) { model.key = $0; model.dirty = true }.frame(width: 110)
                Text("\(model.bpb)/4").foregroundStyle(.secondary)
            }
            Text("« A B » = moitié-moitié · « Am . . F » = un symbole par temps · N.C. = sans accord")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(model.cells.enumerated()), id: \.offset) { i, cell in
                        VStack(spacing: 0) {
                            Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onTapGesture { model.seekBar(i) }
                            CommitField(value: cell) { model.setCell(i, $0) }
                        }
                        .padding(4)
                        .background(i == model.currentBar ? Color.yellow.opacity(0.25) : Color.gray.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.cellErrors[i] == nil ? .clear : .red))
                        .help(model.cellErrors[i] ?? "")
                    }
                }
            }
        }.padding(8)
    }

    func closeAsking() {
        if model.dirty {
            let a = NSAlert(); a.messageText = "Abandonner les modifications ?"
            a.addButton(withTitle: "Abandonner"); a.addButton(withTitle: "Continuer")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        dismiss()
    }
}
```

**`EditorModel` lifetime:** the `WindowGroup` builds `EditorModel(songID:…)` in its body. Make sure it isn't re-created on every body evaluation. If it is (playback stops, edits vanish), cache the models in `KaraokeModel` (`var editors: [String: EditorModel]`, created once per id) and use `karaoke.editor(for: id)`. Record this in the ledger.

- [ ] **Step 3: Build and check by hand**

Run: `cd karaifyer && ./build-app.sh | tail -1 && open Karaifyer.app`
Expected: right-click 005 → *Corriger paroles et accords…* opens the editor:
- **Lyrics:** the lines show times like `00:12.40`.
- **Chord grid:** shows `C#m`, `A`, … (4 per row).
- **Lecture:** plays; the current line and bar are highlighted. Clicking a bar jumps there. ⏱ moves a line and re-sorts.
- **Invalid cell:** typing `H` turns the cell's border red, and Enregistrer then gives the error.
- **Saving a valid change:** writes `/Volumes/Hypermnesia/karaoke/paroles/005.lrc` and `accords/005.txt`. The terminal shows `[005] chords : fait`, `lyrics : fait`, `video : fait` and `set : fait`.

Then restore the original state of 005 (delete the two correction files and re-run 005) so the test data stays clean.

- [ ] **Step 4: Commit**

```bash
git add karaifyer/Sources/Karaifyer
git commit -m "karaifyer: correction editor (timed lyrics, chord grid, player, save → re-run)"
```

---

### Task 13: App: Settings window

**Files:**
- Create: `karaifyer/Sources/Karaifyer/SettingsView.swift` (and remove the Task 11 stub)

**Interfaces:**
- Consumes: the UserDefaults keys read by `Pipeline` (`karaokeHome`, `gabarit`, `projectDir`).
- Produces: `SettingsView`.

- [ ] **Step 1: Implement**

```swift
// karaifyer/Sources/Karaifyer/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    let p = Pipeline()
    var body: some View {
        Form {
            row("Dossier karaoké", key: "karaokeHome", value: p.karaokeHome, folder: true)
            row("Gabarit Ableton", key: "gabarit", value: p.gabarit, folder: false)
            row("Projet karaoke (code)", key: "projectDir", value: p.projectDir, folder: true)
            let problems = p.problems()
            Text(problems.isEmpty ? "Tout est prêt." : problems.joined(separator: "\n"))
                .foregroundStyle(problems.isEmpty ? .green : .orange)
        }
        .padding(20).frame(width: 640)
    }

    func row(_ label: String, key: String, value: String, folder: Bool) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Button("Choisir…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
                if panel.runModal() == .OK, let u = panel.url {
                    UserDefaults.standard.set(u.path, forKey: key)
                    Task { await KaraokeModel.shared.refresh() }
                }
            }
            Button("Défaut") { UserDefaults.standard.removeObject(forKey: key); Task { await KaraokeModel.shared.refresh() } }
        }
    }
}
```

The view reads UserDefaults on each render. Because there's no `@State`, it won't refresh by itself after « Choisir… ». Closing and reopening Settings shows the new value. If that matters during the validation, back it with an `@Observable SettingsStore` holding the three strings, and ledger the choice.

- [ ] **Step 2: Build and check**

Run: `cd karaifyer && ./build-app.sh | tail -1 && open Karaifyer.app`
Expected: Karaifyer → Réglages… (⌘,) shows the three paths and « Tout est prêt. ». Choose a non-existent folder for « Dossier karaoké », and the Karaoké tab shows the orange banner with Analyser disabled. Click « Défaut », and the banner goes away after « Réessayer ».

- [ ] **Step 3: Commit**

```bash
git add karaifyer/Sources/Karaifyer
git commit -m "karaifyer: settings (karaoke folder, Ableton template, pipeline project)"
```

---

### Task 14: Docs, validation checklist and Michel's run

**Files:**
- Create: `karaifyer/README.md`, `docs/karaoke/karaifyer-validation.md`
- Modify: `README.md` (root; one paragraph pointing to Karaifyer, without touching the SysRec sections' content)

**Interfaces:** none.

- [ ] **Step 1: Write `karaifyer/README.md`**

It covers:
- what Karaifyer is (SysRec's recorder plus the Karaoké tab);
- building it (`cd karaifyer && ./build-app.sh --install`);
- the permissions asked on first launch;
- the Karaoké tab in brief: adding songs, retirer checkboxes, Analyser / Pause / Arrêter, the terminal, the context menu, the editor syntax (`A B`, `Am . . F`, `N.C.`, accepted symbols), and that corrections live in `paroles/` and `accords/` and survive re-runs;
- Settings.

All in French, like `karaoke/README.md`.

- [ ] **Step 2: Write `docs/karaoke/karaifyer-validation.md`** (Michel fills in ✅ / ❌)

| # | Check | Result |
|---|---|---|
| 1 | Karaifyer opens; macOS asks for system audio recording and control of Spotify; SysRec still opens and records as before | |
| 2 | Enregistrement tab: record 2 songs from a short list | |
| 3 | Karaoké tab: the songs appear; « Ajouter des morceaux… » with an MP3 from outside SysRec adds a row (title from the tags or the file name) | |
| 4 | Ticking/unticking Retirer, changing Langue and Partie: `manifeste.csv` is updated (open it to check); the package / set dots go grey | |
| 5 | Analyser (2 new songs): progress bar, current step, time left, live terminal | |
| 6 | Pause for a few minutes, then Reprendre: the analysis continues where it was | |
| 7 | Arrêter après ce morceau: the current song finishes, the next one doesn't start | |
| 8 | Arrêter maintenant during « separate », then Analyser: the step is redone, no song reported done wrongly | |
| 9 | Right-click: open folder / video / set / chord grid / journal | |
| 10 | Editor: playback, current line and bar highlighted, ⏱, edit a lyric line and a chord (`Am . . F`), Enregistrer → video and iReal page updated with the correction | |
| 11 | Re-run « Refaire le morceau »: the corrections from #10 are still there | |
| 12 | Start a recording while an analysis runs: Karaifyer proposes to pause the analysis | |

- [ ] **Step 3: Run the full test suites**

Run:
```bash
uv --directory karaoke run pytest -q 2>&1 | tail -1
cd karaifyer && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing 2>&1 | tail -2
cd .. && git diff --stat main -- Sources Tests Package.swift build-app.sh Resources
```
Expected: both suites green, and the last command prints nothing (SysRec untouched).

- [ ] **Step 4: Commit, then hand the checklist to Michel**

```bash
git add karaifyer/README.md docs/karaoke/karaifyer-validation.md README.md
git commit -m "karaifyer: README and validation checklist"
```

Hand Michel the checklist. Record his results in the ledger and fix any ❌ with TDD where the cause is in Core or Python, and with a manual re-check where it is UI glue.
