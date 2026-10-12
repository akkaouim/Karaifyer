# Karaoké live — Phase 0 (chaîne complète sur 3 morceaux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local Python CLI that turns a manifest plus audio files into one show-ready folder per song (accompaniment, stems, click, guide vocal, synced lyrics, lyrics video, per-song report, global risk report), run end to end on 3 test songs to produce the phase 0 go/no-go measurements.

**Architecture:** A light main package (`karaoke/src/karaoke`) runs resumable, per-song *steps*. Each step writes its artifacts under `travail/<id>/` plus a JSON marker, and the runner skips steps whose inputs haven't changed. The three heavy models (Demucs, Beat This!, WhisperX) each live in their **own uv project under `karaoke/tools/`**. They're called as subprocesses with file/JSON in and out, which isolates their conflicting torch pins (demucs 4.0.1 pins `torchaudio<2.1`) and frees GPU memory between songs. The main package does the arithmetic (grid, count-in, mixing, energy checks, video timeline) as pure, unit-tested functions.

**Tech Stack:** Python 3.11 (uv), Typer, numpy, soundfile, mutagen, httpx, Pillow, pytest; ffmpeg/ffprobe (system, built with libx264; no libass, so lyric frames are drawn with Pillow); Demucs `htdemucs_6s` (MPS); Beat This! (`final0`); WhisperX alignment only (wav2vec2, French and English).

**Spec:** `docs/karaoke/cahier-des-charges.md`

**Out of scope for this plan (separate plans):** Ableton `.als` generation and the XR18 routing (needs Live installed on this Mac plus the template set and addressing plan), the Spotify Web API manifest option, and the phase 1 polish of the HTML report and user guide.

## Global Constraints

- Python 3.11 managed by uv; main package dependencies stay light (no torch in the main env).
- Workspace root: `/Volumes/Hypermnesia/karaoke` (override with env `KARAOKE_HOME`); the internal disk has only 14 GB free.
- All audio outputs: 44,1 kHz, FLAC 24 bits.
- « Tous les fichiers audio d'un même dossier démarrent au même instant zéro et ont la même durée. »
- Durée : alerte au-delà de 2 secondes d'écart avec `duree_ref_s`.
- Tempo : un morceau dont le tempo varie de plus de 3 % est signalé.
- Clic : accent sur le premier temps, précédé du décompte (`decompte_mesures` mesures, défaut 2).
- Précision du clic : dérive inférieure à 30 ms par rapport à la batterie (tempo stable).
- Paroles : ligne affichée entre 300 ms avant et 100 ms après le début du chant.
- « Aucune transcription automatique : un morceau sans texte est signalé dans le rapport. »
- Vidéo : 1920x1080, sans son ; titre pendant le décompte ; ligne en cours mise en évidence + ligne suivante ; compte à rebours avant chaque reprise du chant après plus de 8 secondes d'instrumental.
- Hors ligne sauf la requête LRCLIB ; un morceau en échec n'arrête pas le lot.
- Stem names everywhere: `vocals, drums, bass, guitar, piano, other` (Demucs htdemucs_6s names). The `retirer` column uses these names separated by `;`.
- Work in the `mp3-pipeline` repo under `karaoke/`; commit after each task.

## Review Focus

1. **Accented and punctuated titles/artists** (« À ma place », « Zazie/Axel Bauer », « Dis, quand reviendras-tu ? »): folder names must be valid and stable, and LRCLIB queries must send the real text. Test in Task 3 (`slug`) and Task 8 (query params).
2. **LRCLIB unreachable or timing out**: the lyrics step ends `a_reessayer` and the audio outputs still get produced. Test in Task 8 and Task 4 (runner isolation).
3. **Instrumental track or no lyrics at all**: no crash; the video shows the title only, and the report flags « sans paroles ». Test in Task 11 (timeline with zero lines) and Task 12 (risk).
4. **Changing `retirer` or `decompte_mesures` for one song**: only the dependent steps rerun, not separation. Test in Task 4 (keys) with the Task 10 key function.
5. **Unknown stem name in `retirer`** (typo like `guitare`): rejected when the manifest loads, with a clear message, not a silent wrong mix. Test in Task 2.

---

## File Structure

```
karaoke/
  pyproject.toml                 main package (typer, numpy, soundfile, mutagen, httpx, pillow; dev: pytest)
  src/karaoke/
    __init__.py
    config.py                    Paths: home, entree, paroles, travail, sortie; env KARAOKE_HOME
    manifest.py                  Song dataclass, CSV read/write/validate, build from SysRec FLAC tags
    workspace.py                 slug(), song folder names, step markers (JSON), journal
    runner.py                    Step definition, dependency keys, skip/force, failure isolation, timings
    audio.py                     ffprobe duration, ffmpeg convert, soundfile read/write helpers
    tools.py                     run_tool(): subprocess into karaoke/tools/<name> uv projects
    grid.py                      PURE: meter, tempo stats, count-in plan, click synthesis, drift
    lrc.py                       PURE: LRC parse / format / shift
    lrclib.py                    LRCLIB HTTP client
    steps/__init__.py            STEPS list in execution order
    steps/ingest.py              duration check, WAV 44.1 stereo, leading-silence trim + offset
    steps/separate.py            Demucs → travail/<id>/stems/*.wav
    steps/beats.py               Beat This! → beats.json + tempo stats
    steps/package.py             accompaniment mix, click, guide vocal, stems, temps.csv → sortie/
    steps/lyrics.py              source selection, shift, WhisperX alignment → lyrics.json
    steps/check.py               vocal activity, per-line calage, line ends, drum-onset drift
    steps/video.py               paroles.lrc + paroles.mp4 into sortie/
    video/timeline.py            PURE: display states (title, current/next, countdown)
    video/render.py              Pillow frames + ffmpeg concat → mp4
    report.py                    rapport.json per song, rapport.csv + rapport.html sorted by risk
    cli.py                       Typer app: manifeste, traiter, rapport
  tools/
    separate/pyproject.toml      demucs==4.0.1 (+ its torch)
    beats/pyproject.toml         beat_this (git)
    beats/beats_tool.py          wav → {"beats":[], "downbeats":[]}
    align/pyproject.toml         whisperx
    align/align_tool.py          {"audio","language","lines"} → {"starts":[...]}
  tests/
    conftest.py                  synthetic audio fixtures, tmp workspace
    test_manifest.py  test_workspace.py  test_runner.py  test_grid.py  test_lrc.py
    test_lrclib.py  test_ingest.py  test_package.py  test_lyrics.py  test_check.py
    test_timeline.py  test_video.py  test_report.py
    test_models_slow.py          real-model integration, marker `slow`
docs/karaoke/
  cahier-des-charges.md          the spec (already committed)
  phase0-spike.md                tool versions, device, timings (Task 1)
  phase0-resultats.md            go/no-go measurements (Task 14)
```

Workspace layout on disk (`$KARAOKE_HOME`):

```
manifeste.csv
paroles/<id>.txt | <id>.lrc      texts supplied by Michel (.lrc = already synced, overrides everything)
travail/<id>/                    input.wav, stems/, *.json markers, journal.log, video frames cache
sortie/<id>_<artiste>_<titre>/   the deliverables
rapport.csv  rapport.html
```

Timeline conventions (used by every task):

- `t_in`: seconds in the **trimmed** input (`travail/<id>/input.wav`, after leading-silence removal).
- `offset_s`: leading silence removed by ingest; original time = `t_in + offset_s`.
- `pad_s`: silence prepended for the count-in; output time = `t_in + pad_s`.
- LRCLIB synced times are original times: `t_in = t_lrc - offset_s`.

---

### Task 0: Project scaffold and workspace

**Files:**
- Create: `karaoke/pyproject.toml`, `karaoke/src/karaoke/__init__.py`, `karaoke/src/karaoke/config.py`, `karaoke/src/karaoke/cli.py`, `karaoke/tests/conftest.py`, `karaoke/tests/test_config.py`
- Modify: `.gitignore` (add `karaoke/.venv/`, `karaoke/tools/*/.venv/`, `__pycache__/`, `.pytest_cache/`)

**Interfaces:**
- Produces: `Config(home: Path)` with properties `manifest: Path`, `paroles: Path`, `travail: Path`, `sortie: Path`; `Config.load() -> Config` (env `KARAOKE_HOME`, default `/Volumes/Hypermnesia/karaoke`); `Config.ensure_dirs() -> None`. Typer `app` in `karaoke.cli` with console script `karaoke`.

- [ ] **Step 1: Create the uv project**

```bash
cd ~/Documents/mp3-pipeline && mkdir -p karaoke && cd karaoke
uv init --package --name karaoke --python 3.11 --no-readme .
uv add typer numpy soundfile mutagen httpx pillow
uv add --dev pytest
```

Then make `pyproject.toml` contain these sections (keep what uv generated otherwise):

```toml
[project.scripts]
karaoke = "karaoke.cli:app"

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = ["slow: runs the real ML models (minutes); run with -m slow"]
addopts = "-m 'not slow'"
```

- [ ] **Step 2: Write the failing test**

`karaoke/tests/test_config.py`:

```python
from pathlib import Path
from karaoke.config import Config

def test_home_from_env(monkeypatch, tmp_path):
    monkeypatch.setenv("KARAOKE_HOME", str(tmp_path))
    c = Config.load()
    assert c.home == tmp_path
    assert c.manifest == tmp_path / "manifeste.csv"
    assert c.travail == tmp_path / "travail"
    assert c.sortie == tmp_path / "sortie"
    assert c.paroles == tmp_path / "paroles"

def test_default_home(monkeypatch):
    monkeypatch.delenv("KARAOKE_HOME", raising=False)
    assert Config.load().home == Path("/Volumes/Hypermnesia/karaoke")

def test_ensure_dirs(tmp_path):
    c = Config(home=tmp_path)
    c.ensure_dirs()
    for d in (c.travail, c.sortie, c.paroles):
        assert d.is_dir()
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd karaoke && uv run pytest tests/test_config.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.config`

- [ ] **Step 4: Implement**

`karaoke/src/karaoke/config.py`:

```python
from __future__ import annotations
import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_HOME = Path("/Volumes/Hypermnesia/karaoke")

@dataclass(frozen=True)
class Config:
    home: Path

    @classmethod
    def load(cls) -> "Config":
        env = os.environ.get("KARAOKE_HOME")
        return cls(home=Path(env) if env else DEFAULT_HOME)

    @property
    def manifest(self) -> Path: return self.home / "manifeste.csv"
    @property
    def paroles(self) -> Path: return self.home / "paroles"
    @property
    def travail(self) -> Path: return self.home / "travail"
    @property
    def sortie(self) -> Path: return self.home / "sortie"

    def ensure_dirs(self) -> None:
        for d in (self.paroles, self.travail, self.sortie):
            d.mkdir(parents=True, exist_ok=True)
```

`karaoke/src/karaoke/cli.py` (commands are added by later tasks):

```python
import typer

app = typer.Typer(help="Karaoké live : manifeste → dossiers prêts à jouer.", no_args_is_help=True)

@app.callback()
def main() -> None:
    """Pipeline d'analyse karaoké."""
```

`karaoke/tests/conftest.py`:

```python
import numpy as np
import pytest
import soundfile as sf
from karaoke.config import Config

SR = 44100

@pytest.fixture
def cfg(tmp_path):
    c = Config(home=tmp_path / "home")
    c.ensure_dirs()
    return c

def write_wav(path, data, sr=SR):
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.asarray(data, dtype=np.float32), sr, subtype="FLOAT")
    return path

def tone(seconds, freq=440.0, amp=0.5, sr=SR, stereo=True):
    t = np.arange(int(seconds * sr)) / sr
    x = (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    return np.stack([x, x], axis=1) if stereo else x
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd karaoke && uv run pytest -v`
Expected: 3 passed

- [ ] **Step 6: Commit**

```bash
git add karaoke .gitignore
git commit -m "karaoke: scaffold uv project, config and CLI entry point"
```

---

### Task 1: Model tool environments (spike)

Exploratory: it confirms that the three heavy tools install and run on this Mac, and records versions and timings. There are no unit tests. The deliverable is three working tool projects and `docs/karaoke/phase0-spike.md`. If a tool fails on MPS, use `cpu` and record the timing; if WhisperX can't install, record it and stop to discuss (the fallback would be torchaudio's MMS forced aligner).

**Files:**
- Create: `karaoke/tools/separate/pyproject.toml`, `karaoke/tools/beats/pyproject.toml`, `karaoke/tools/beats/beats_tool.py`, `karaoke/tools/align/pyproject.toml`, `karaoke/tools/align/align_tool.py`, `karaoke/src/karaoke/tools.py`, `docs/karaoke/phase0-spike.md`

**Interfaces:**
- Produces: `run_tool(tool: str, args: list[str], env: dict | None = None, timeout: float | None = None) -> subprocess.CompletedProcess` in `karaoke.tools`. It runs `uv run --project <karaoke/tools/tool> <args...>` with `PYTORCH_ENABLE_MPS_FALLBACK=1` and raises `ToolError(tool, returncode, stderr_tail)` on failure.
- Tool contracts (used by Tasks 6, 7, 9):
  - separate: `demucs -n htdemucs_6s -d <device> --float32 -o <outdir> --filename "{stem}.{ext}" <wav>` writes `<outdir>/htdemucs_6s/{vocals,drums,bass,guitar,piano,other}.wav`
  - beats: `python beats_tool.py <wav> <out.json> [--device mps|cpu]` writes `{"beats": [s...], "downbeats": [s...]}`
  - align: `python align_tool.py <job.json> <out.json>` with job `{"audio": path, "language": "fr"|"en", "lines": [str...]}` writes `{"starts": [s|null...], "scores": [float|null...]}`

- [ ] **Step 1: Create the three tool projects**

`karaoke/tools/separate/pyproject.toml`:

```toml
[project]
name = "karaoke-separate"
version = "0.1.0"
requires-python = "==3.11.*"
dependencies = ["demucs==4.0.1", "soundfile"]
```

`karaoke/tools/beats/pyproject.toml`:

```toml
[project]
name = "karaoke-beats"
version = "0.1.0"
requires-python = "==3.11.*"
dependencies = ["beat_this @ git+https://github.com/CPJKU/beat_this", "soundfile", "soxr"]
```

`karaoke/tools/beats/beats_tool.py`:

```python
"""Beat This! wrapper: wav -> {"beats": [...], "downbeats": [...]} (seconds)."""
import argparse, json
from beat_this.inference import File2Beats

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("wav"); p.add_argument("out"); p.add_argument("--device", default="mps")
    a = p.parse_args()
    f2b = File2Beats(checkpoint_path="final0", device=a.device, dbn=False)
    beats, downbeats = f2b(a.wav)
    with open(a.out, "w") as f:
        json.dump({"beats": [float(b) for b in beats], "downbeats": [float(d) for d in downbeats]}, f)

if __name__ == "__main__":
    main()
```

`karaoke/tools/align/pyproject.toml`:

```toml
[project]
name = "karaoke-align"
version = "0.1.0"
requires-python = "==3.11.*"
dependencies = ["whisperx"]
```

`karaoke/tools/align/align_tool.py`:

```python
"""Forced alignment of known lyric lines on a vocal stem (no transcription).

job.json: {"audio": path, "language": "fr"|"en", "lines": ["...", ...]}
out.json: {"starts": [seconds|null per line], "scores": [mean word score|null per line]}
"""
import json, sys
import whisperx

def main(job_path: str, out_path: str) -> None:
    job = json.load(open(job_path))
    audio = whisperx.load_audio(job["audio"])          # 16 kHz mono float32
    model, meta = whisperx.load_align_model(language_code=job["language"], device="cpu")
    lines = [l.strip() for l in job["lines"]]
    words_per_line = [len(l.split()) for l in lines]
    text = " ".join(l for l in lines if l)
    dur = len(audio) / 16000.0
    res = whisperx.align([{"start": 0.0, "end": dur, "text": text}], model, meta, audio,
                         "cpu", return_char_alignments=False)
    words = res.get("word_segments", [])
    starts, scores, i = [], [], 0
    for n in words_per_line:
        chunk = words[i:i + n]; i += n
        timed = [w for w in chunk if "start" in w]
        starts.append(float(timed[0]["start"]) if timed else None)
        sc = [w["score"] for w in timed if "score" in w]
        scores.append(float(sum(sc) / len(sc)) if sc else None)
    json.dump({"starts": starts, "scores": scores}, open(out_path, "w"))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
```

`karaoke/src/karaoke/tools.py`:

```python
from __future__ import annotations
import os, subprocess
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2] / "tools"

class ToolError(RuntimeError):
    def __init__(self, tool: str, code: int, stderr: str):
        super().__init__(f"{tool} failed (exit {code}): {stderr[-800:]}")
        self.tool, self.code, self.stderr = tool, code, stderr

def run_tool(tool: str, args: list[str], env: dict | None = None,
             timeout: float | None = None) -> subprocess.CompletedProcess:
    project = TOOLS_DIR / tool
    full_env = {**os.environ, "PYTORCH_ENABLE_MPS_FALLBACK": "1", **(env or {})}
    proc = subprocess.run(["uv", "run", "--project", str(project), *args],
                          cwd=project, env=full_env, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise ToolError(tool, proc.returncode, proc.stderr)
    return proc
```

- [ ] **Step 2: Install and run each tool on one SysRec file**

Pick any recorded FLAC, e.g. `~/Music/SysRec/Karaoké - Feuille 1/04 - J'attends - Ben Mazué & Pomme.flac` (or a file in `old takes/`). Convert it once to `/tmp/k/in.wav`, then time each tool:

```bash
mkdir -p /tmp/k && ffmpeg -v error -y -i "<file.flac>" -ac 2 -ar 44100 -c:a pcm_f32le /tmp/k/in.wav
cd ~/Documents/mp3-pipeline/karaoke/tools/separate && time uv run demucs -n htdemucs_6s -d mps --float32 -o /tmp/k/sep --filename "{stem}.{ext}" /tmp/k/in.wav
cd ../beats && time uv run python beats_tool.py /tmp/k/in.wav /tmp/k/beats.json --device mps
cd ../align && printf '{"audio":"/tmp/k/sep/htdemucs_6s/vocals.wav","language":"fr","lines":["test ligne un","test ligne deux"]}' > /tmp/k/job.json && time uv run python align_tool.py /tmp/k/job.json /tmp/k/align.json
ls /tmp/k/sep/htdemucs_6s; python3 -c "import json;d=json.load(open('/tmp/k/beats.json'));print(len(d['beats']),len(d['downbeats']))"; cat /tmp/k/align.json
```

Expected: six stem WAVs; a few hundred beats and about a quarter as many downbeats; an align JSON with two entries (the times are meaningless for fake lines; this only checks the plumbing). If `-d mps` fails for Demucs or Beat This!, rerun with `cpu` and note it.

- [ ] **Step 3: Record findings**

Write `docs/karaoke/phase0-spike.md` with: tool versions (`uv run --project tools/<t> pip list | grep -iE "torch|demucs|beat|whisperx"`), the device that worked, wall time per tool for the test song with its duration, peak memory if observed (Activity Monitor), and any install workarounds. This is the input for the 120-song time estimate.

- [ ] **Step 4: Commit**

```bash
git add karaoke/tools karaoke/src/karaoke/tools.py docs/karaoke/phase0-spike.md
git commit -m "karaoke: isolated tool envs for demucs, beat_this, whisperx + spike notes"
```

---

### Task 2: Manifest (model, CSV, validation, build from SysRec)

**Files:**
- Create: `karaoke/src/karaoke/manifest.py`, `karaoke/tests/test_manifest.py`
- Modify: `karaoke/src/karaoke/cli.py` (add `manifeste` command)

**Interfaces:**
- Produces:
  - `STEMS: tuple[str, ...] = ("vocals", "drums", "bass", "guitar", "piano", "other")`
  - `@dataclass Song(id: str, titre: str, artiste: str, album: str, duree_ref_s: float, isrc: str, fichier: Path, retirer: tuple[str, ...], decompte_mesures: int, langue: str, partie: str)`
  - `COLUMNS: list[str]` (that order)
  - `read_manifest(path: Path) -> list[Song]` (raises `ManifestError` listing every bad row)
  - `write_manifest(path: Path, songs: list[Song]) -> None`
  - `songs_from_sysrec(audio_dir: Path) -> list[Song]`: one Song per `*.flac`, using the tags SysRec writes (`title`, `artist`, `album`, `track`). `id` = zero-padded 3-digit `track`, duration from the stream, defaults `retirer=()`, `decompte_mesures=2`, `langue="fr"`, `partie=""`.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_manifest.py`:

```python
import subprocess
from pathlib import Path
import pytest
from karaoke.manifest import (Song, read_manifest, write_manifest, songs_from_sysrec,
                              ManifestError, COLUMNS)
from conftest import write_wav, tone

def song(**kw):
    base = dict(id="001", titre="Je suis un homme", artiste="Zazie", album="Zen", duree_ref_s=249.47,
                isrc="", fichier=Path("/x/01.flac"), retirer=("guitar",), decompte_mesures=2,
                langue="fr", partie="A")
    base.update(kw); return Song(**base)

def test_roundtrip(tmp_path):
    p = tmp_path / "m.csv"
    s = [song(), song(id="003", titre="À ma place", artiste="Zazie/Axel Bauer", retirer=("guitar", "bass"))]
    write_manifest(p, s)
    assert p.read_text(encoding="utf-8").splitlines()[0] == ",".join(COLUMNS)
    assert read_manifest(p) == s

def test_unknown_stem_rejected(tmp_path):
    p = tmp_path / "m.csv"
    write_manifest(p, [song()])
    p.write_text(p.read_text(encoding="utf-8").replace("guitar", "guitare"), encoding="utf-8")
    with pytest.raises(ManifestError, match="guitare"):
        read_manifest(p)

def test_bad_id_and_duplicate(tmp_path):
    p = tmp_path / "m.csv"
    write_manifest(p, [song(id="7"), song(id="002"), song(id="002")])
    with pytest.raises(ManifestError) as e:
        read_manifest(p)
    msg = str(e.value)
    assert "3 chiffres" in msg and "doublon" in msg

def test_vocals_cannot_be_kept(tmp_path):
    # vocals are always removed; listing them in retirer is harmless but normalised away
    p = tmp_path / "m.csv"
    write_manifest(p, [song(retirer=("vocals", "bass"))])
    assert read_manifest(p)[0].retirer == ("bass",)

def test_from_sysrec_tags(tmp_path):
    wav = write_wav(tmp_path / "a.wav", tone(3.0))
    flac = tmp_path / "audio" / "14 - Ma liberté de penser - Florent Pagny.flac"
    flac.parent.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-metadata", "title=Ma liberté de penser",
                    "-metadata", "artist=Florent Pagny", "-metadata", "album=Ailleurs Land",
                    "-metadata", "track=14", str(flac)], check=True)
    [s] = songs_from_sysrec(flac.parent)
    assert (s.id, s.titre, s.artiste, s.album) == ("014", "Ma liberté de penser", "Florent Pagny", "Ailleurs Land")
    assert abs(s.duree_ref_s - 3.0) < 0.05
    assert s.fichier == flac and s.decompte_mesures == 2 and s.retirer == ()
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_manifest.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.manifest`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/manifest.py`:

```python
from __future__ import annotations
import csv, re
from dataclasses import dataclass
from pathlib import Path
from mutagen import File as MutagenFile

STEMS = ("vocals", "drums", "bass", "guitar", "piano", "other")
COLUMNS = ["id", "titre", "artiste", "album", "duree_ref_s", "isrc", "fichier",
           "retirer", "decompte_mesures", "langue", "partie"]

class ManifestError(ValueError):
    pass

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

def _parse_row(row: dict, line: int, errors: list[str]) -> Song | None:
    sid = (row.get("id") or "").strip()
    if not re.fullmatch(r"\d{3}", sid):
        errors.append(f"ligne {line}: id « {sid} » doit faire 3 chiffres")
    retirer = []
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
    return Song(id=sid, titre=row.get("titre", "").strip(), artiste=row.get("artiste", "").strip(),
                album=row.get("album", "").strip(), duree_ref_s=duree, isrc=(row.get("isrc") or "").strip(),
                fichier=Path((row.get("fichier") or "").strip()), retirer=tuple(retirer),
                decompte_mesures=decompte, langue=(row.get("langue") or "fr").strip() or "fr",
                partie=(row.get("partie") or "").strip())

def read_manifest(path: Path) -> list[Song]:
    errors: list[str] = []
    songs: list[Song] = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for i, row in enumerate(csv.DictReader(f), start=2):
            s = _parse_row(row, i, errors)
            if s: songs.append(s)
    seen: set[str] = set()
    for s in songs:
        if s.id in seen:
            errors.append(f"id {s.id} en doublon")
        seen.add(s.id)
    if errors:
        raise ManifestError("Manifeste invalide :\n" + "\n".join(errors))
    return songs

def write_manifest(path: Path, songs: list[Song]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(COLUMNS)
        for s in songs:
            w.writerow([s.id, s.titre, s.artiste, s.album, f"{s.duree_ref_s:.3f}", s.isrc, str(s.fichier),
                        ";".join(s.retirer), s.decompte_mesures, s.langue, s.partie])

def _tag(audio, key: str) -> str:
    v = audio.tags.get(key) if audio.tags else None
    return (v[0] if isinstance(v, list) else str(v or "")).strip()

def songs_from_sysrec(audio_dir: Path) -> list[Song]:
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
```

Add to `karaoke/src/karaoke/cli.py`:

```python
from pathlib import Path
from karaoke.config import Config
from karaoke.manifest import songs_from_sysrec, write_manifest, read_manifest

@app.command()
def manifeste(audio: Path = typer.Option(..., help="Dossier des FLAC enregistrés par SysRec"),
              sortie: Path = typer.Option(None, help="Fichier manifeste (défaut : $KARAOKE_HOME/manifeste.csv)"),
              ecraser: bool = typer.Option(False, help="Remplacer un manifeste existant")) -> None:
    """Construit le manifeste à partir des tags des fichiers SysRec."""
    cfg = Config.load(); cfg.ensure_dirs()
    out = sortie or cfg.manifest
    if out.exists() and not ecraser:
        raise typer.BadParameter(f"{out} existe déjà (utiliser --ecraser)")
    songs = songs_from_sysrec(audio)
    write_manifest(out, songs)
    typer.echo(f"{len(songs)} morceaux écrits dans {out}. Compléter les colonnes retirer, langue et partie.")
```

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_manifest.py -v`
Expected: 5 passed. Note: mutagen exposes FLAC tracks as `tracknumber`; the `track` fallback covers other containers.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/manifest.py karaoke/src/karaoke/cli.py karaoke/tests/test_manifest.py
git commit -m "karaoke: manifest model, validation and build from SysRec tags"
```

---

### Task 3: Workspace (folder names, markers, journal)

**Files:**
- Create: `karaoke/src/karaoke/workspace.py`, `karaoke/tests/test_workspace.py`

**Interfaces:**
- Consumes: `Config`, `Song`.
- Produces:
  - `slug(text: str, max_len: int = 40) -> str`: ASCII, lowercase, words joined by `-`, stable.
  - `class Workspace(cfg: Config, song: Song)` with `work: Path` (`travail/<id>`), `out: Path` (`sortie/<id>_<slug(artiste)>_<slug(titre)>`), `stems: Path` (`work/"stems"`), `marker(step: str) -> Path` (`work/f"{step}.json"`), `read_marker(step) -> dict | None`, `write_marker(step, data: dict) -> None` (atomic), `log(msg: str) -> None` (appends a timestamped line to `work/"journal.log"`).

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_workspace.py`:

```python
from pathlib import Path
from karaoke.workspace import slug, Workspace
from test_manifest import song

def test_slug():
    assert slug("À ma place") == "a-ma-place"
    assert slug("Zazie/Axel Bauer") == "zazie-axel-bauer"
    assert slug("Dis, quand reviendras-tu ?") == "dis-quand-reviendras-tu"
    assert slug("Les copains d’abord") == "les-copains-d-abord"
    assert slug("") == "sans-titre"
    assert len(slug("x" * 100)) == 40

def test_paths(cfg):
    ws = Workspace(cfg, song(id="003", titre="À ma place", artiste="Zazie/Axel Bauer"))
    assert ws.work == cfg.travail / "003"
    assert ws.out == cfg.sortie / "003_zazie-axel-bauer_a-ma-place"
    assert ws.stems == ws.work / "stems"

def test_markers_and_log(cfg):
    ws = Workspace(cfg, song())
    assert ws.read_marker("ingest") is None
    ws.write_marker("ingest", {"key": "k1", "result": {"offset_s": 0.1}})
    assert ws.read_marker("ingest")["result"]["offset_s"] == 0.1
    ws.log("bonjour")
    assert "bonjour" in (ws.work / "journal.log").read_text(encoding="utf-8")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_workspace.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.workspace`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/workspace.py`:

```python
from __future__ import annotations
import json, os, re, unicodedata
from datetime import datetime
from pathlib import Path
from karaoke.config import Config
from karaoke.manifest import Song

def slug(text: str, max_len: int = 40) -> str:
    norm = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-z0-9]+", "-", norm.lower()).strip("-")
    return (s[:max_len].rstrip("-")) or "sans-titre"

class Workspace:
    def __init__(self, cfg: Config, song: Song):
        self.cfg, self.song = cfg, song
        self.work = cfg.travail / song.id
        self.out = cfg.sortie / f"{song.id}_{slug(song.artiste)}_{slug(song.titre)}"
        self.stems = self.work / "stems"
        self.work.mkdir(parents=True, exist_ok=True)

    def marker(self, step: str) -> Path:
        return self.work / f"{step}.json"

    def read_marker(self, step: str) -> dict | None:
        p = self.marker(step)
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None

    def write_marker(self, step: str, data: dict) -> None:
        p = self.marker(step)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, p)

    def log(self, msg: str) -> None:
        with open(self.work / "journal.log", "a", encoding="utf-8") as f:
            f.write(f"[{datetime.now().isoformat(timespec='seconds')}] {msg}\n")
```

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_workspace.py -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/workspace.py karaoke/tests/test_workspace.py
git commit -m "karaoke: workspace paths, slugs, step markers and per-song journal"
```

---

### Task 4: Runner (dependency keys, resume, isolation, timings)

**Files:**
- Create: `karaoke/src/karaoke/runner.py`, `karaoke/src/karaoke/steps/__init__.py`, `karaoke/tests/test_runner.py`

**Interfaces:**
- Consumes: `Workspace`.
- Produces:
  - `class StepRetry(Exception)`: the step couldn't complete for a transient reason (network); its status is `a_reessayer`.
  - `@dataclass Step(name: str, deps: tuple[str, ...], key: Callable[[Workspace], str], run: Callable[[Workspace, dict[str, dict]], dict], always: bool = False)`. `run` receives the workspace and the **results of its dependencies** (`{dep_name: result_dict}`) and returns its own result dict.
  - `run_song(ws: Workspace, steps: list[Step], force: set[str] = frozenset(), only: set[str] | None = None) -> dict[str, dict]` returns `{step: {"status": "fait"|"saute"|"echec"|"a_reessayer"|"bloque", "seconds": float, "result": dict, "error": str}}`.
  - Marker content: `{"key": str, "result": dict, "seconds": float}`. The effective key is `sha1(step.name | step.key(ws) | effective keys of deps)`, so a change upstream reruns everything downstream. Failed or blocked steps write no marker. A dependency failure makes the dependants `bloque`; independent steps still run.
  - `only`: run only these steps; their deps must already have markers, otherwise they're `bloque`. `force`: rerun these steps (and therefore their dependants).

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_runner.py`:

```python
from karaoke.runner import Step, StepRetry, run_song
from karaoke.workspace import Workspace
from test_manifest import song

def make_steps(calls, state):
    def mk(name, deps=(), fail=None):
        def run(ws, upstream):
            calls.append(name)
            if fail == "boom": raise RuntimeError("boom")
            if fail == "retry": raise StepRetry("réseau")
            return {"name": name, "up": sorted(upstream)}
        return Step(name=name, deps=deps, key=lambda ws, n=name: state.get(n, "v1"), run=run)
    return mk

def test_runs_then_skips(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("a"), mk("b", ("a",)), mk("c", ("b",))]
    ws = Workspace(cfg, song())
    r1 = run_song(ws, steps)
    assert calls == ["a", "b", "c"] and r1["c"]["result"]["up"] == ["b"]
    r2 = run_song(ws, steps)
    assert calls == ["a", "b", "c"] and {v["status"] for v in r2.values()} == {"saute"}

def test_key_change_reruns_downstream_only(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("ingest"), mk("separate", ("ingest",)), mk("package", ("separate",))]
    ws = Workspace(cfg, song())
    run_song(ws, steps); calls.clear()
    state["package"] = "retirer=bass"          # e.g. retirer column edited
    run_song(ws, steps)
    assert calls == ["package"]

def test_failure_blocks_dependants_not_siblings(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("a"), mk("b", ("a",), fail="boom"), mk("c", ("b",)), mk("d", ("a",))]
    r = run_song(Workspace(cfg, song()), steps)
    assert r["b"]["status"] == "echec" and "boom" in r["b"]["error"]
    assert r["c"]["status"] == "bloque" and r["d"]["status"] == "fait"

def test_retry_status_and_no_marker(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    ws = Workspace(cfg, song())
    r = run_song(ws, [mk("lyrics", fail="retry")])
    assert r["lyrics"]["status"] == "a_reessayer" and ws.read_marker("lyrics") is None

def test_force_and_only(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("a"), mk("b", ("a",)), mk("c", ("b",))]
    ws = Workspace(cfg, song())
    run_song(ws, steps); calls.clear()
    run_song(ws, steps, force={"b"})
    assert calls == ["b", "c"]; calls.clear()
    run_song(ws, steps, only={"c"}, force={"c"})
    assert calls == ["c"]
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_runner.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.runner`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/runner.py`:

```python
from __future__ import annotations
import hashlib, time, traceback
from dataclasses import dataclass
from typing import Callable
from karaoke.workspace import Workspace

class StepRetry(Exception):
    """Transient failure (e.g. network): retry on the next run."""

@dataclass(frozen=True)
class Step:
    name: str
    deps: tuple[str, ...]
    key: Callable[[Workspace], str]
    run: Callable[[Workspace, dict], dict]
    always: bool = False

def run_song(ws: Workspace, steps: list[Step], force: set[str] = frozenset(),
             only: set[str] | None = None) -> dict[str, dict]:
    out: dict[str, dict] = {}
    eff_keys: dict[str, str] = {}
    forced = set(force)
    for step in steps:
        t0 = time.monotonic()
        bad = [d for d in step.deps if out.get(d, {}).get("status") not in ("fait", "saute")]
        if bad:
            out[step.name] = {"status": "bloque", "seconds": 0.0, "result": {},
                              "error": f"dépend de : {', '.join(bad)}"}
            continue
        key = hashlib.sha1("|".join([step.name, step.key(ws), *(eff_keys[d] for d in step.deps)])
                           .encode()).hexdigest()
        eff_keys[step.name] = key
        marker = ws.read_marker(step.name)
        dep_forced = any(d in forced for d in step.deps)
        if dep_forced:
            forced.add(step.name)
        selected = only is None or step.name in only
        up_to_date = marker is not None and marker.get("key") == key
        if (not selected or (up_to_date and step.name not in forced)) and not step.always:
            if marker is None or not up_to_date:
                out[step.name] = {"status": "bloque", "seconds": 0.0, "result": {},
                                  "error": "étape non sélectionnée et pas à jour"}
            else:
                out[step.name] = {"status": "saute", "seconds": 0.0, "result": marker["result"], "error": ""}
            continue
        upstream = {d: out[d]["result"] for d in step.deps}
        try:
            ws.log(f"début {step.name}")
            result = step.run(ws, upstream)
            secs = time.monotonic() - t0
            ws.write_marker(step.name, {"key": key, "result": result, "seconds": secs})
            out[step.name] = {"status": "fait", "seconds": secs, "result": result, "error": ""}
            ws.log(f"fin {step.name} ({secs:.1f} s)")
        except StepRetry as e:
            out[step.name] = {"status": "a_reessayer", "seconds": time.monotonic() - t0, "result": {}, "error": str(e)}
            ws.log(f"à réessayer {step.name}: {e}")
        except Exception as e:  # one song's failure must never stop the batch
            out[step.name] = {"status": "echec", "seconds": time.monotonic() - t0, "result": {},
                              "error": f"{type(e).__name__}: {e}"}
            ws.log(f"échec {step.name}: {traceback.format_exc()}")
    return out
```

`karaoke/src/karaoke/steps/__init__.py` (filled by later tasks):

```python
from karaoke.runner import Step

STEPS: list[Step] = []
```

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_runner.py -v`
Expected: 5 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/runner.py karaoke/src/karaoke/steps/__init__.py karaoke/tests/test_runner.py
git commit -m "karaoke: resumable step runner with dependency keys and failure isolation"
```

---

### Task 5: Ingest step (duration check, WAV 44.1 stereo, leading silence)

**Files:**
- Create: `karaoke/src/karaoke/audio.py`, `karaoke/src/karaoke/steps/ingest.py`, `karaoke/tests/test_ingest.py`
- Modify: `karaoke/src/karaoke/steps/__init__.py`

**Interfaces:**
- Produces:
  - `audio.probe_duration(path: Path) -> float` (ffprobe)
  - `audio.convert_to_wav(src: Path, dst: Path) -> None`: 44100 Hz, stereo, float32 WAV
  - `audio.read(path) -> tuple[np.ndarray, int]` (frames × channels float32), `audio.write_flac(path, data, sr=44100)` (24-bit), `audio.write_wav(path, data, sr=44100)` (float32)
  - `ingest.first_sound_frame(x: np.ndarray, threshold_db: float = -60.0) -> int | None`
  - `INGEST: Step` named `"ingest"`, no deps. Result: `{"file_duration_s", "ref_delta_s", "duration_alert": bool, "offset_s", "duration_s"}`. Writes `ws.work/"input.wav"` (trimmed). Raises `FileNotFoundError` if the input is missing. Key: input path, size, mtime and `duree_ref_s`.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_ingest.py`:

```python
import numpy as np
import pytest
from karaoke import audio
from karaoke.steps.ingest import INGEST, first_sound_frame
from karaoke.workspace import Workspace
from conftest import write_wav, tone, SR
from test_manifest import song

def test_first_sound_frame():
    x = np.zeros((SR, 2), np.float32); x[22050:] = 0.1
    assert first_sound_frame(x) == 22050
    assert first_sound_frame(np.zeros((100, 2), np.float32)) is None

def test_ingest_trims_and_converts(cfg, tmp_path):
    sig = np.concatenate([np.zeros((int(0.5 * 48000), 2), np.float32), tone(4.0, sr=48000)])
    src = write_wav(tmp_path / "in48k.wav", sig, sr=48000)
    ws = Workspace(cfg, song(fichier=src, duree_ref_s=4.5))
    r = INGEST.run(ws, {})
    x, sr = audio.read(ws.work / "input.wav")
    assert sr == 44100 and x.shape[1] == 2
    assert abs(r["offset_s"] - 0.49) < 0.02            # 0.5 s silence minus 10 ms pre-roll
    assert abs(r["duration_s"] - 4.01) < 0.03
    assert abs(r["ref_delta_s"]) < 0.05 and r["duration_alert"] is False

def test_duration_alert(cfg, tmp_path):
    src = write_wav(tmp_path / "a.wav", tone(4.0))
    r = INGEST.run(Workspace(cfg, song(fichier=src, duree_ref_s=10.0)), {})
    assert r["duration_alert"] is True and r["ref_delta_s"] == pytest.approx(-6.0, abs=0.05)

def test_missing_file(cfg, tmp_path):
    with pytest.raises(FileNotFoundError):
        INGEST.run(Workspace(cfg, song(fichier=tmp_path / "absent.flac")), {})
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_ingest.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.audio`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/audio.py`:

```python
from __future__ import annotations
import subprocess
from pathlib import Path
import numpy as np
import soundfile as sf

SR = 44100

def probe_duration(path: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", str(path)], capture_output=True, text=True, check=True)
    return float(out.stdout.strip())

def convert_to_wav(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-map", "0:a:0", "-ac", "2",
                    "-ar", str(SR), "-c:a", "pcm_f32le", str(dst)], check=True)

def read(path: Path) -> tuple[np.ndarray, int]:
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    return x, sr

def write_wav(path: Path, data: np.ndarray, sr: int = SR) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.asarray(data, np.float32), sr, subtype="FLOAT")

def write_flac(path: Path, data: np.ndarray, sr: int = SR) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.clip(np.asarray(data, np.float32), -1.0, 1.0), sr, format="FLAC", subtype="PCM_24")
```

`karaoke/src/karaoke/steps/ingest.py`:

```python
from __future__ import annotations
import numpy as np
from karaoke import audio
from karaoke.runner import Step
from karaoke.workspace import Workspace

DURATION_ALERT_S = 2.0
PREROLL_S = 0.010

def first_sound_frame(x: np.ndarray, threshold_db: float = -60.0) -> int | None:
    thr = 10 ** (threshold_db / 20)
    idx = np.flatnonzero(np.max(np.abs(x), axis=1) > thr)
    return int(idx[0]) if idx.size else None

def _key(ws: Workspace) -> str:
    p = ws.song.fichier
    st = p.stat() if p.exists() else None
    return f"{p}|{st.st_size if st else 0}|{st.st_mtime_ns if st else 0}|{ws.song.duree_ref_s}"

def _run(ws: Workspace, upstream: dict) -> dict:
    src = ws.song.fichier
    if not src.exists():
        raise FileNotFoundError(f"fichier d'entrée absent : {src}")
    file_dur = audio.probe_duration(src)
    full = ws.work / "input_full.wav"
    audio.convert_to_wav(src, full)
    x, sr = audio.read(full)
    first = first_sound_frame(x)
    start = max(0, (first or 0) - int(PREROLL_S * sr))
    trimmed = x[start:]
    audio.write_wav(ws.work / "input.wav", trimmed, sr)
    full.unlink()
    delta = file_dur - ws.song.duree_ref_s if ws.song.duree_ref_s else 0.0
    return {"file_duration_s": file_dur, "ref_delta_s": delta,
            "duration_alert": bool(ws.song.duree_ref_s and abs(delta) > DURATION_ALERT_S),
            "offset_s": start / sr, "duration_s": len(trimmed) / sr}

INGEST = Step(name="ingest", deps=(), key=_key, run=_run)
```

Append to `steps/__init__.py`: `from karaoke.steps.ingest import INGEST` and `STEPS = [INGEST]`.

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_ingest.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/audio.py karaoke/src/karaoke/steps karaoke/tests/test_ingest.py
git commit -m "karaoke: ingest step (duration check, 44.1 kHz WAV, leading-silence offset)"
```

---

### Task 6: Separation and beat steps (tool wrappers)

**Files:**
- Create: `karaoke/src/karaoke/steps/separate.py`, `karaoke/src/karaoke/steps/beats.py`, `karaoke/tests/test_models_slow.py`
- Modify: `karaoke/src/karaoke/steps/__init__.py`

**Interfaces:**
- Consumes: `run_tool` (Task 1), `INGEST` result, `STEMS`.
- Produces:
  - `SEPARATE: Step` `"separate"`, deps `("ingest",)`. It writes `ws.stems/{stem}.wav` for all 6 STEMS (moved out of Demucs' `htdemucs_6s/` subfolder) and returns `{"stems": [names], "device": str}`. Key: `"htdemucs_6s"`. Device from env `KARAOKE_DEVICE` (default `mps`).
  - `BEATS: Step` `"beats"`, deps `("ingest",)`. Writes `ws.work/"beats.json"` and returns `{"beats": [...], "downbeats": [...]}` (seconds in `t_in`). Key: `"beat_this-final0"`.

- [ ] **Step 1: Implement the wrappers**

`karaoke/src/karaoke/steps/separate.py`:

```python
from __future__ import annotations
import os, shutil
from karaoke.manifest import STEMS
from karaoke.runner import Step
from karaoke.tools import run_tool
from karaoke.workspace import Workspace

def _run(ws: Workspace, upstream: dict) -> dict:
    device = os.environ.get("KARAOKE_DEVICE", "mps")
    tmp = ws.work / "demucs_tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    run_tool("separate", ["demucs", "-n", "htdemucs_6s", "-d", device, "--float32", "-o", str(tmp),
                          "--filename", "{stem}.{ext}", str(ws.work / "input.wav")])
    ws.stems.mkdir(parents=True, exist_ok=True)
    for stem in STEMS:
        shutil.move(str(tmp / "htdemucs_6s" / f"{stem}.wav"), ws.stems / f"{stem}.wav")
    shutil.rmtree(tmp, ignore_errors=True)
    return {"stems": list(STEMS), "device": device}

SEPARATE = Step(name="separate", deps=("ingest",), key=lambda ws: "htdemucs_6s", run=_run)
```

`karaoke/src/karaoke/steps/beats.py`:

```python
from __future__ import annotations
import json, os
from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, run_tool
from karaoke.workspace import Workspace

def _run(ws: Workspace, upstream: dict) -> dict:
    out = ws.work / "beats.json"
    run_tool("beats", ["python", str(TOOLS_DIR / "beats" / "beats_tool.py"), str(ws.work / "input.wav"),
                       str(out), "--device", os.environ.get("KARAOKE_DEVICE", "mps")])
    data = json.loads(out.read_text())
    if len(data["beats"]) < 8:
        raise ValueError(f"trop peu de temps détectés ({len(data['beats'])})")
    return {"beats": data["beats"], "downbeats": data["downbeats"]}

BEATS = Step(name="beats", deps=("ingest",), key=lambda ws: "beat_this-final0", run=_run)
```

Set `STEPS = [INGEST, SEPARATE, BEATS]` in `steps/__init__.py`.

- [ ] **Step 2: Write the slow integration test**

`karaoke/tests/test_models_slow.py`:

```python
import os
from pathlib import Path
import pytest
from karaoke.runner import run_song
from karaoke.steps.ingest import INGEST
from karaoke.steps.separate import SEPARATE
from karaoke.steps.beats import BEATS
from karaoke.workspace import Workspace
from test_manifest import song

SAMPLE = Path(os.environ.get("KARAOKE_SAMPLE", ""))

@pytest.mark.slow
@pytest.mark.skipif(not SAMPLE.is_file(), reason="set KARAOKE_SAMPLE to a real song file")
def test_separate_and_beats_on_real_song(cfg):
    ws = Workspace(cfg, song(fichier=SAMPLE, duree_ref_s=0))
    r = run_song(ws, [INGEST, SEPARATE, BEATS])
    assert {v["status"] for v in r.values()} == {"fait"}, r
    assert sorted(p.stem for p in ws.stems.glob("*.wav")) == sorted(
        ["vocals", "drums", "bass", "guitar", "piano", "other"])
    beats = r["beats"]["result"]["beats"]
    assert 60 < 60 * len(beats) / r["ingest"]["result"]["duration_s"] < 220   # plausible BPM
```

- [ ] **Step 3: Run it**

Run: `cd karaoke && KARAOKE_SAMPLE="/tmp/k/in.wav" uv run pytest -m slow tests/test_models_slow.py -v`
Expected: PASS (takes minutes). The fast suite (`uv run pytest`) is unaffected.

- [ ] **Step 4: Commit**

```bash
git add karaoke/src/karaoke/steps karaoke/tests/test_models_slow.py
git commit -m "karaoke: demucs separation and Beat This! steps via isolated tools"
```

---

### Task 7: Beat grid math (meter, tempo stability, count-in, click, drift)

**Files:**
- Create: `karaoke/src/karaoke/grid.py`, `karaoke/tests/test_grid.py`

**Interfaces:**
- Produces (all pure, times in seconds):
  - `beats_per_bar(beats: Sequence[float], downbeats: Sequence[float]) -> int`: median beats between consecutive downbeats; 4 if fewer than 2 downbeats; clamped to 2–7.
  - `tempo_stats(beats) -> dict`: `{"bpm": float, "variation_pct": float, "stable": bool}`. Local tempo is the median IBI over sliding 8-beat windows; `variation_pct = (p95 - p5) / median * 100`; `stable = variation_pct <= 3.0`.
  - `@dataclass CountIn(pad_s: float, period_s: float, beats_per_bar: int, times_in: list[float], accents: list[bool])`. `times_in` are the count-in click times in `t_in` and may be negative; output time = `t + pad_s`.
  - `countin_plan(beats, downbeats, n_bars: int, sr: int = 44100) -> CountIn`: anchor = first downbeat (or first beat). period = median of the first 8 IBIs from the anchor. Count-in beats = `anchor - k*period` for `k = n*bpb … 1`, with an accent when `k % bpb == 0`. `pad_s = max(0, -(earliest count-in time))` rounded **up** to a whole sample.
  - `click_events(plan: CountIn, beats, downbeats) -> list[tuple[float, bool]]`: output times (count-in plus detected beats at or after the anchor), each with an accent flag.
  - `render_click(events, total_frames: int, sr=44100) -> np.ndarray` mono float32: 25 ms exponentially decaying sine; accent 1600 Hz at 0.9 amplitude, other beats 1000 Hz at 0.6.
  - `onsets(x: np.ndarray, sr: int) -> np.ndarray`: spectral-flux onset times of a mono signal (used on the drum stem).
  - `drift_ms(beats, onset_times, window_s=10.0, max_dist=0.07) -> float`: for each beat, the nearest onset within `max_dist`; median absolute offset per window; returns the **max over windows** in ms (0 if nothing matched).

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_grid.py`:

```python
import numpy as np
import pytest
from karaoke.grid import (beats_per_bar, tempo_stats, countin_plan, click_events, render_click,
                          onsets, drift_ms)

def grid(bpm=120.0, start=0.5, n=200, bpb=4):
    p = 60 / bpm
    beats = [start + i * p for i in range(n)]
    return beats, beats[::bpb]

def test_meter():
    b, d = grid(bpb=4); assert beats_per_bar(b, d) == 4
    b, d = grid(bpb=3); assert beats_per_bar(b, d) == 3
    assert beats_per_bar(b, d[:1]) == 4

def test_tempo_stable_and_unstable():
    b, _ = grid(bpm=100)
    s = tempo_stats(b)
    assert s["bpm"] == pytest.approx(100, abs=0.1) and s["stable"] and s["variation_pct"] < 0.5
    # accelerando 90 -> 110 BPM
    ibis = np.linspace(60 / 90, 60 / 110, 199)
    acc = list(np.concatenate([[0.5], 0.5 + np.cumsum(ibis)]))
    s2 = tempo_stats(acc)
    assert not s2["stable"] and s2["variation_pct"] > 3.0

def test_countin_pads_when_song_starts_early():
    b, d = grid(bpm=120, start=0.5)            # first downbeat at 0.5 s, 2 bars of 4 = 4 s
    plan = countin_plan(b, d, n_bars=2)
    assert plan.beats_per_bar == 4 and plan.period_s == pytest.approx(0.5)
    assert len(plan.times_in) == 8 and plan.accents == [True, False, False, False] * 2
    assert plan.pad_s == pytest.approx(3.5, abs=1 / 44100)
    assert min(t + plan.pad_s for t in plan.times_in) == pytest.approx(0.0, abs=1 / 44100)

def test_countin_no_pad_when_long_intro():
    b, d = grid(bpm=120, start=6.0)
    assert countin_plan(b, d, n_bars=2).pad_s == 0.0

def test_click_events_and_render():
    b, d = grid(bpm=120, start=0.5, n=16)
    plan = countin_plan(b, d, n_bars=1)
    ev = click_events(plan, b, d)
    times = [t for t, _ in ev]
    assert len(ev) == 4 + 16 and times == sorted(times)
    assert ev[4] == (pytest.approx(0.5 + plan.pad_s), True)       # first real downbeat accented
    x = render_click(ev, total_frames=int((plan.pad_s + 9) * 44100))
    assert x.ndim == 1 and np.abs(x).max() == pytest.approx(0.9, abs=0.01)

def test_drift_detects_late_onsets():
    b, _ = grid(bpm=120, start=0.5, n=100)
    on_time = np.array(b) + 0.004
    assert drift_ms(b, on_time) < 6
    late = np.array(b) + np.linspace(0, 0.05, len(b))      # drifts to 50 ms late
    assert drift_ms(b, late) > 30

def test_onsets_on_click_train():
    ev = [(0.5 + i * 0.5, False) for i in range(10)]
    x = render_click(ev, total_frames=6 * 44100)
    found = onsets(x, 44100)
    assert drift_ms([t for t, _ in ev], found) < 15
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_grid.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.grid`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/grid.py`:

```python
from __future__ import annotations
import math
from dataclasses import dataclass
from typing import Sequence
import numpy as np

STABLE_PCT = 3.0

def beats_per_bar(beats: Sequence[float], downbeats: Sequence[float]) -> int:
    if len(downbeats) < 2:
        return 4
    b = np.asarray(beats)
    counts = [int(np.sum((b >= d0 - 1e-3) & (b < d1 - 1e-3))) for d0, d1 in zip(downbeats, downbeats[1:])]
    return int(min(7, max(2, round(float(np.median(counts))))))

def tempo_stats(beats: Sequence[float]) -> dict:
    ibi = np.diff(np.asarray(beats, float))
    med = float(np.median(ibi))
    w = 8
    local = np.array([np.median(ibi[i:i + w]) for i in range(0, max(1, len(ibi) - w + 1))])
    local_bpm = 60.0 / local
    var = float((np.percentile(local_bpm, 95) - np.percentile(local_bpm, 5)) / np.median(local_bpm) * 100)
    return {"bpm": 60.0 / med, "variation_pct": var, "stable": var <= STABLE_PCT}

@dataclass(frozen=True)
class CountIn:
    pad_s: float
    period_s: float
    beats_per_bar: int
    times_in: list[float]
    accents: list[bool]

def countin_plan(beats, downbeats, n_bars: int, sr: int = 44100) -> CountIn:
    b = np.asarray(beats, float)
    anchor = float(downbeats[0]) if len(downbeats) else float(b[0])
    after = b[b >= anchor - 1e-3]
    period = float(np.median(np.diff(after[:9]))) if len(after) > 2 else 0.5
    bpb = beats_per_bar(beats, downbeats)
    n = n_bars * bpb
    times = [anchor - k * period for k in range(n, 0, -1)]
    accents = [k % bpb == 0 for k in range(n, 0, -1)]
    earliest = min(times) if times else 0.0
    pad = math.ceil(max(0.0, -earliest) * sr) / sr
    return CountIn(pad_s=pad, period_s=period, beats_per_bar=bpb, times_in=times, accents=accents)

def click_events(plan: CountIn, beats, downbeats) -> list[tuple[float, bool]]:
    anchor = plan.times_in[-1] + plan.period_s if plan.times_in else (downbeats[0] if len(downbeats) else beats[0])
    down = {round(d, 4) for d in downbeats}
    ev = [(t + plan.pad_s, a) for t, a in zip(plan.times_in, plan.accents)]
    ev += [(t + plan.pad_s, round(t, 4) in down) for t in beats if t >= anchor - 1e-3]
    return sorted(ev)

def render_click(events, total_frames: int, sr: int = 44100) -> np.ndarray:
    out = np.zeros(total_frames, np.float32)
    n = int(0.025 * sr)
    t = np.arange(n) / sr
    env = np.exp(-t / 0.006)
    hi = (0.9 * np.sin(2 * np.pi * 1600 * t) * env).astype(np.float32)
    lo = (0.6 * np.sin(2 * np.pi * 1000 * t) * env).astype(np.float32)
    for when, accent in events:
        i = int(round(when * sr))
        if 0 <= i < total_frames:
            src = hi if accent else lo
            m = min(n, total_frames - i)
            out[i:i + m] += src[:m]
    return np.clip(out, -1, 1)

def onsets(x: np.ndarray, sr: int, hop: int = 256, frame: int = 1024) -> np.ndarray:
    x = x.mean(axis=1) if x.ndim == 2 else x
    if len(x) < frame:
        return np.array([])
    win = np.hanning(frame)
    frames = np.lib.stride_tricks.sliding_window_view(x, frame)[::hop] * win
    mag = np.abs(np.fft.rfft(frames, axis=1))
    flux = np.maximum(0, np.diff(np.log1p(mag), axis=0)).sum(axis=1)
    flux = np.concatenate([[0], flux])
    thr = np.median(flux) + 2.0 * np.std(flux)
    peaks = [i for i in range(1, len(flux) - 1)
             if flux[i] > thr and flux[i] >= flux[i - 1] and flux[i] > flux[i + 1]]
    return (np.array(peaks) * hop + frame // 2) / sr

def drift_ms(beats, onset_times, window_s: float = 10.0, max_dist: float = 0.07) -> float:
    on = np.sort(np.asarray(onset_times, float))
    if on.size == 0:
        return 0.0
    rows = []
    for t in beats:
        j = np.searchsorted(on, t)
        cands = on[max(0, j - 1):j + 1]
        d = cands[np.argmin(np.abs(cands - t))] - t
        if abs(d) <= max_dist:
            rows.append((t, abs(d)))
    if not rows:
        return 0.0
    rows = np.array(rows)
    windows = np.floor(rows[:, 0] / window_s)
    return float(max(np.median(rows[windows == w, 1]) for w in np.unique(windows)) * 1000)
```

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_grid.py -v`
Expected: 7 passed. If `test_onsets_on_click_train` is marginal, tune only the `2.0 * std` threshold factor and keep the test unchanged.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/grid.py karaoke/tests/test_grid.py
git commit -m "karaoke: beat-grid math (meter, tempo stability, count-in, click, drift)"
```

---

### Task 8: LRC handling and LRCLIB client

**Files:**
- Create: `karaoke/src/karaoke/lrc.py`, `karaoke/src/karaoke/lrclib.py`, `karaoke/tests/test_lrc.py`, `karaoke/tests/test_lrclib.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) Line(t: float, text: str)`
  - `lrc.parse(text: str) -> list[Line]`: handles `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss]` and several stamps on one line; ignores metadata tags (`[ar:…]`) and empty-text lines; sorted by time.
  - `lrc.format(lines: list[Line]) -> str`
  - `lrc.shift(lines, delta: float) -> list[Line]` (clamped at 0)
  - `lrc.plain_lines(text: str) -> list[str]`: non-empty stripped lines without section markers like `[Refrain]`
  - `@dataclass LrclibResult(found: bool, instrumental: bool, synced: str | None, plain: str | None)`
  - `lrclib.fetch(titre, artiste, album, duree_s, client: httpx.Client | None = None) -> LrclibResult`. GET `https://lrclib.net/api/get` with params `track_name, artist_name, album_name, duration` (int); on 404 it falls back to `/api/search` with `track_name` and `artist_name` and takes the first hit within 3 s of the duration. Network errors and timeouts raise `StepRetry`. Sends `User-Agent: karaoke-live/0.1 (github.com/akkaouim/mp3-pipeline)`.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_lrc.py`:

```python
from karaoke.lrc import Line, parse, format, shift, plain_lines

SAMPLE = "[ar:Zazie]\n[00:12.50]Je suis un homme\n[00:15.2][01:02.00]Refrain\n\n[00:20]Fin\n"

def test_parse():
    assert parse(SAMPLE) == [Line(12.5, "Je suis un homme"), Line(15.2, "Refrain"),
                             Line(20.0, "Fin"), Line(62.0, "Refrain")]

def test_format_roundtrip():
    lines = parse(SAMPLE)
    assert parse(format(lines)) == lines
    assert format([Line(62.05, "x")]) == "[01:02.05]x\n"

def test_shift_clamps():
    assert shift([Line(0.3, "a"), Line(5.0, "b")], -0.5) == [Line(0.0, "a"), Line(4.5, "b")]

def test_plain_lines():
    assert plain_lines("[Refrain]\nLa la\n\n  Do ré  \n") == ["La la", "Do ré"]
```

`karaoke/tests/test_lrclib.py`:

```python
import httpx
import pytest
from karaoke.lrclib import fetch
from karaoke.runner import StepRetry

def client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler))

def test_get_synced():
    seen = {}
    def h(req):
        seen.update(dict(req.url.params))
        return httpx.Response(200, json={"instrumental": False, "syncedLyrics": "[00:01.00]a", "plainLyrics": "a"})
    r = fetch("À ma place", "Zazie/Axel Bauer", "Zen", 329.8, client(h))
    assert r.found and r.synced == "[00:01.00]a"
    assert seen["track_name"] == "À ma place" and seen["artist_name"] == "Zazie/Axel Bauer"
    assert seen["duration"] == "330"

def test_404_falls_back_to_search():
    def h(req):
        if req.url.path == "/api/get":
            return httpx.Response(404, json={})
        return httpx.Response(200, json=[{"duration": 400, "syncedLyrics": "x"},
                                         {"duration": 331, "syncedLyrics": None, "plainLyrics": "p", "instrumental": False}])
    r = fetch("t", "a", "al", 329.8, client(h))
    assert r.found and r.synced is None and r.plain == "p"

def test_not_found():
    r = fetch("t", "a", "al", 100, client(lambda req: httpx.Response(404, json={}) if req.url.path == "/api/get"
                                         else httpx.Response(200, json=[])))
    assert not r.found

def test_network_error_is_retry():
    def h(req): raise httpx.ConnectError("offline")
    with pytest.raises(StepRetry):
        fetch("t", "a", "al", 100, client(h))
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_lrc.py tests/test_lrclib.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/lrc.py`:

```python
from __future__ import annotations
import re
from dataclasses import dataclass

STAMP = re.compile(r"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]")
SECTION = re.compile(r"^\s*\[[^\]]*\]\s*$")

@dataclass(frozen=True)
class Line:
    t: float
    text: str

def parse(text: str) -> list[Line]:
    out = []
    for raw in text.splitlines():
        stamps = list(STAMP.finditer(raw))
        if not stamps:
            continue
        lyric = raw[stamps[-1].end():].strip()
        if not lyric:
            continue
        for m in stamps:
            frac = m.group(3) or "0"
            t = int(m.group(1)) * 60 + int(m.group(2)) + int(frac) / (10 ** len(frac))
            out.append(Line(round(t, 3), lyric))
    return sorted(out, key=lambda l: l.t)

def format(lines: list[Line]) -> str:
    def stamp(t: float) -> str:
        cs = int(round(t * 100))
        return f"[{cs // 6000:02d}:{(cs // 100) % 60:02d}.{cs % 100:02d}]"
    return "".join(f"{stamp(l.t)}{l.text}\n" for l in lines)

def shift(lines: list[Line], delta: float) -> list[Line]:
    return [Line(max(0.0, round(l.t + delta, 3)), l.text) for l in lines]

def plain_lines(text: str) -> list[str]:
    return [s.strip() for s in text.splitlines() if s.strip() and not SECTION.match(s)]
```

`karaoke/src/karaoke/lrclib.py`:

```python
from __future__ import annotations
from dataclasses import dataclass
import httpx
from karaoke.runner import StepRetry

BASE = "https://lrclib.net"
UA = "karaoke-live/0.1 (github.com/akkaouim/mp3-pipeline)"

@dataclass(frozen=True)
class LrclibResult:
    found: bool
    instrumental: bool
    synced: str | None
    plain: str | None

def _result(d: dict) -> LrclibResult:
    return LrclibResult(True, bool(d.get("instrumental")), d.get("syncedLyrics") or None, d.get("plainLyrics") or None)

def fetch(titre: str, artiste: str, album: str, duree_s: float, client: httpx.Client | None = None) -> LrclibResult:
    c = client or httpx.Client(timeout=15.0)
    headers = {"User-Agent": UA}
    try:
        r = c.get(f"{BASE}/api/get", headers=headers, params={
            "track_name": titre, "artist_name": artiste, "album_name": album, "duration": int(round(duree_s))})
        if r.status_code == 200:
            return _result(r.json())
        if r.status_code != 404:
            raise StepRetry(f"LRCLIB HTTP {r.status_code}")
        s = c.get(f"{BASE}/api/search", headers=headers, params={"track_name": titre, "artist_name": artiste})
        if s.status_code != 200:
            raise StepRetry(f"LRCLIB recherche HTTP {s.status_code}")
        hits = [h for h in s.json() if abs(float(h.get("duration") or 0) - duree_s) <= 3.0]
        return _result(hits[0]) if hits else LrclibResult(False, False, None, None)
    except httpx.HTTPError as e:
        raise StepRetry(f"LRCLIB injoignable : {e}") from e
```

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_lrc.py tests/test_lrclib.py -v`
Expected: 8 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/lrc.py karaoke/src/karaoke/lrclib.py karaoke/tests/test_lrc.py karaoke/tests/test_lrclib.py
git commit -m "karaoke: LRC parse/format/shift and LRCLIB client with search fallback"
```

---

### Task 9: Lyrics step (source selection, shift, alignment)

**Files:**
- Create: `karaoke/src/karaoke/steps/lyrics.py`, `karaoke/tests/test_lyrics.py`

**Interfaces:**
- Consumes: `lrclib.fetch`, `lrc.*`, `run_tool("align", …)`, `INGEST` result (`offset_s`), stems from `SEPARATE`.
- Produces: `LYRICS: Step` `"lyrics"`, deps `("ingest", "separate")`. Result: `{"source": str, "lines": [{"t": float, "text": str, "score": float|None}], "language": str}`, with times in `t_in`. Source priority:
  1. `paroles/<id>.lrc` (Michel's corrected file, original timing) → `"fichier-lrc"`, shifted by `-offset_s`
  2. LRCLIB `instrumental` → `"instrumental"`, no lines
  3. LRCLIB synced → `"lrclib-synchro"`, shifted by `-offset_s`
  4. LRCLIB plain → `"lrclib-texte+alignement"`, aligned on `stems/vocals.wav`
  5. `paroles/<id>.txt` → `"texte-fourni+alignement"`, aligned
  6. nothing → `"aucune"`, no lines (flagged in the report)
  Lines the aligner can't place (`null`) get a time interpolated between their neighbours and `score: None`. The key includes the mtimes of `paroles/<id>.lrc` and `.txt`, so dropping in a file reruns the step.
- `align_lines(vocals: Path, lines: list[str], language: str, work: Path) -> list[tuple[float|None, float|None]]`: the injectable seam for tests (module-level function).

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_lyrics.py`:

```python
import pytest
from karaoke import lrclib
from karaoke.lrclib import LrclibResult
from karaoke.runner import StepRetry
from karaoke.steps import lyrics as L
from karaoke.workspace import Workspace
from test_manifest import song

UP = {"ingest": {"offset_s": 0.5}, "separate": {}}

def run(cfg, monkeypatch, result, files=None, aligned=None, sid="009"):
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: result)
    calls = []
    def fake_align(vocals, lines, language, work):
        calls.append(lines)
        return aligned or [(1.0 + i, 0.9) for i in range(len(lines))]
    monkeypatch.setattr(L, "align_lines", fake_align)
    for name, text in (files or {}).items():
        (cfg.paroles / name).write_text(text, encoding="utf-8")
    return L.LYRICS.run(Workspace(cfg, song(id=sid)), UP), calls

def test_synced_is_shifted_by_offset(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(True, False, "[00:10.00]Bonjour\n[00:12.00]Salut", "x"))
    assert r["source"] == "lrclib-synchro" and not calls
    assert [l["t"] for l in r["lines"]] == [9.5, 11.5]

def test_plain_is_aligned(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(True, False, None, "[Refrain]\nUn\nDeux"))
    assert r["source"] == "lrclib-texte+alignement" and calls == [["Un", "Deux"]]
    assert [l["t"] for l in r["lines"]] == [1.0, 2.0]

def test_user_text_when_lrclib_missing(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(False, False, None, None), files={"009.txt": "A\nB\n"})
    assert r["source"] == "texte-fourni+alignement" and calls == [["A", "B"]]

def test_user_lrc_overrides_everything(cfg, monkeypatch):
    r, _ = run(cfg, monkeypatch, LrclibResult(True, False, "[00:01.00]x", None), files={"009.lrc": "[00:03.00]Corrigé"})
    assert r["source"] == "fichier-lrc" and r["lines"] == [{"t": 2.5, "text": "Corrigé", "score": None}]

def test_instrumental_and_none(cfg, monkeypatch):
    r, _ = run(cfg, monkeypatch, LrclibResult(True, True, None, None))
    assert r["source"] == "instrumental" and r["lines"] == []
    r2, _ = run(cfg, monkeypatch, LrclibResult(False, False, None, None), sid="010")
    assert r2["source"] == "aucune" and r2["lines"] == []

def test_unaligned_lines_interpolated(cfg, monkeypatch):
    r, _ = run(cfg, monkeypatch, LrclibResult(True, False, None, "a\nb\nc"),
               aligned=[(1.0, 0.9), (None, None), (5.0, 0.8)])
    assert [l["t"] for l in r["lines"]] == [1.0, 3.0, 5.0] and r["lines"][1]["score"] is None

def test_offline_propagates_retry(cfg, monkeypatch):
    def boom(*a, **k): raise StepRetry("offline")
    monkeypatch.setattr(lrclib, "fetch", boom)
    with pytest.raises(StepRetry):
        L.LYRICS.run(Workspace(cfg, song(id="011")), UP)
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_lyrics.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.steps.lyrics`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/steps/lyrics.py`:

```python
from __future__ import annotations
import json
from pathlib import Path
from karaoke import lrc, lrclib
from karaoke.runner import Step
from karaoke.tools import TOOLS_DIR, run_tool
from karaoke.workspace import Workspace

def align_lines(vocals: Path, lines: list[str], language: str, work: Path) -> list[tuple[float | None, float | None]]:
    job, out = work / "align_job.json", work / "align_out.json"
    job.write_text(json.dumps({"audio": str(vocals), "language": language, "lines": lines}, ensure_ascii=False),
                   encoding="utf-8")
    run_tool("align", ["python", str(TOOLS_DIR / "align" / "align_tool.py"), str(job), str(out)])
    d = json.loads(out.read_text())
    return list(zip(d["starts"], d["scores"]))

def _interpolate(times: list[float | None]) -> list[float]:
    known = [(i, t) for i, t in enumerate(times) if t is not None]
    if not known:
        return [0.0] * len(times)
    out = []
    for i, t in enumerate(times):
        if t is not None:
            out.append(t); continue
        before = [(j, u) for j, u in known if j < i]
        after = [(j, u) for j, u in known if j > i]
        if before and after:
            (j0, u0), (j1, u1) = before[-1], after[0]
            out.append(u0 + (u1 - u0) * (i - j0) / (j1 - j0))
        else:
            out.append((before[-1] if before else after[0])[1])
    return [round(t, 3) for t in out]

def _paths(ws: Workspace) -> tuple[Path, Path]:
    return ws.cfg.paroles / f"{ws.song.id}.lrc", ws.cfg.paroles / f"{ws.song.id}.txt"

def _key(ws: Workspace) -> str:
    parts = [ws.song.titre, ws.song.artiste, ws.song.album, str(ws.song.duree_ref_s), ws.song.langue]
    for p in _paths(ws):
        parts.append(str(p.stat().st_mtime_ns) if p.exists() else "-")
    return "|".join(parts)

def _run(ws: Workspace, upstream: dict) -> dict:
    s, offset = ws.song, upstream["ingest"]["offset_s"]
    user_lrc, user_txt = _paths(ws)
    def synced(text: str, source: str) -> dict:
        lines = lrc.shift(lrc.parse(text), -offset)
        return {"source": source, "language": s.langue,
                "lines": [{"t": l.t, "text": l.text, "score": None} for l in lines]}
    if user_lrc.exists():
        return synced(user_lrc.read_text(encoding="utf-8"), "fichier-lrc")
    res = lrclib.fetch(s.titre, s.artiste, s.album, s.duree_ref_s)
    if res.instrumental:
        return {"source": "instrumental", "language": s.langue, "lines": []}
    if res.synced:
        return synced(res.synced, "lrclib-synchro")
    if res.plain:
        text, source = res.plain, "lrclib-texte+alignement"
    elif user_txt.exists():
        text, source = user_txt.read_text(encoding="utf-8"), "texte-fourni+alignement"
    else:
        return {"source": "aucune", "language": s.langue, "lines": []}
    texts = lrc.plain_lines(text)
    aligned = align_lines(ws.stems / "vocals.wav", texts, s.langue, ws.work)
    times = _interpolate([t for t, _ in aligned])
    return {"source": source, "language": s.langue,
            "lines": [{"t": t, "text": x, "score": sc} for t, x, (_, sc) in zip(times, texts, aligned)]}

LYRICS = Step(name="lyrics", deps=("ingest", "separate"), key=_key, run=_run)
```

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_lyrics.py -v`
Expected: 7 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/steps/lyrics.py karaoke/tests/test_lyrics.py
git commit -m "karaoke: lyrics step with source priority, offset shift and alignment fallback"
```

---

### Task 10: Package step (count-in, mixes, click, stems, temps.csv)

**Files:**
- Create: `karaoke/src/karaoke/steps/package.py`, `karaoke/tests/test_package.py`
- Modify: `karaoke/src/karaoke/steps/__init__.py`

**Interfaces:**
- Consumes: `grid.*`, `audio.*`, `STEMS`, results of `ingest` and `beats`, stems on disk.
- Produces: `PACKAGE: Step` `"package"`, deps `("ingest", "separate", "beats")`. Key: `retirer` + `decompte_mesures`. It writes into `ws.out`: `accompagnement.flac` (stereo: sum of stems not in `{"vocals"} ∪ retirer`, scaled down uniformly if the peak exceeds 0.999), `clic.flac` (mono), `guide_voix.flac` (mono vocal mean), `pistes/<stem>.flac` (stereo, all 6), and `temps.csv` (`temps_s,premier_temps,source` with source `decompte|detecte`, output times). Every audio file is exactly `total_frames = pad_frames + input_frames` long. Result: `{"pad_s", "total_s", "beats_per_bar", "bpm", "variation_pct", "stable", "removed": [...], "gain_db": float}`.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_package.py`:

```python
import csv
import numpy as np
import pytest
import soundfile as sf
from karaoke import audio
from karaoke.steps.package import PACKAGE
from karaoke.workspace import Workspace
from conftest import tone
from test_manifest import song

def setup(cfg, retirer=("guitar",), decompte=2):
    ws = Workspace(cfg, song(retirer=retirer, decompte_mesures=decompte))
    n = 10 * 44100
    audio.write_wav(ws.work / "input.wav", tone(10.0))
    for i, stem in enumerate(["vocals", "drums", "bass", "guitar", "piano", "other"]):
        audio.write_wav(ws.stems / f"{stem}.wav", tone(10.0, freq=200 + 100 * i, amp=0.1))
    beats = [0.5 + 0.5 * i for i in range(19)]
    up = {"ingest": {"offset_s": 0.0, "duration_s": 10.0}, "separate": {},
          "beats": {"beats": beats, "downbeats": beats[::4]}}
    return ws, up, n

def test_all_files_same_length_and_zero(cfg):
    ws, up, n = setup(cfg)
    r = PACKAGE.run(ws, up)
    pad = int(round(r["pad_s"] * 44100))
    assert r["pad_s"] == pytest.approx(3.5, abs=1e-4)
    files = ["accompagnement.flac", "clic.flac", "guide_voix.flac"] + [f"pistes/{s}.flac" for s in
             ["vocals", "drums", "bass", "guitar", "piano", "other"]]
    for f in files:
        info = sf.info(str(ws.out / f))
        assert info.frames == pad + n and info.samplerate == 44100 and info.subtype == "PCM_24", f
    assert sf.info(str(ws.out / "clic.flac")).channels == 1
    acc, _ = audio.read(ws.out / "accompagnement.flac")
    assert np.abs(acc[:pad - 10]).max() == 0.0                # silent count-in

def test_retirer_changes_accompaniment(cfg):
    ws, up, _ = setup(cfg, retirer=("guitar", "bass"))
    r = PACKAGE.run(ws, up)
    assert r["removed"] == ["bass", "guitar", "vocals"]
    acc, _ = audio.read(ws.out / "accompagnement.flac")
    spec = np.abs(np.fft.rfft(acc[200000:244100, 0]))
    freqs = np.fft.rfftfreq(44100, 1 / 44100)
    def level(f): return spec[np.argmin(np.abs(freqs - f))]
    assert level(300) > 100 * level(200)          # drums kept, vocals removed
    assert level(400) < level(300) / 100          # bass removed

def test_temps_csv(cfg):
    ws, up, _ = setup(cfg)
    PACKAGE.run(ws, up)
    rows = list(csv.DictReader(open(ws.out / "temps.csv", encoding="utf-8")))
    assert rows[0] == {"temps_s": "0.000000", "premier_temps": "1", "source": "decompte"}
    assert sum(r["source"] == "decompte" for r in rows) == 8
    first_detected = next(r for r in rows if r["source"] == "detecte")
    assert float(first_detected["temps_s"]) == pytest.approx(4.0, abs=1e-4)

def test_key_depends_on_retirer_and_decompte(cfg):
    a = PACKAGE.key(Workspace(cfg, song(retirer=("bass",), decompte_mesures=2)))
    b = PACKAGE.key(Workspace(cfg, song(retirer=("guitar",), decompte_mesures=2)))
    c = PACKAGE.key(Workspace(cfg, song(retirer=("bass",), decompte_mesures=1)))
    assert len({a, b, c}) == 3
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_package.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.steps.package`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/steps/package.py`:

```python
from __future__ import annotations
import csv
import numpy as np
from karaoke import audio, grid
from karaoke.manifest import STEMS
from karaoke.runner import Step
from karaoke.workspace import Workspace

def _pad(x: np.ndarray, pad: int, total: int) -> np.ndarray:
    shape = (total,) + x.shape[1:]
    out = np.zeros(shape, np.float32)
    n = min(len(x), total - pad)
    out[pad:pad + n] = x[:n]
    return out

def _key(ws: Workspace) -> str:
    return f"retirer={';'.join(sorted(ws.song.retirer))}|decompte={ws.song.decompte_mesures}"

def _run(ws: Workspace, upstream: dict) -> dict:
    beats, downbeats = upstream["beats"]["beats"], upstream["beats"]["downbeats"]
    x, sr = audio.read(ws.work / "input.wav")
    plan = grid.countin_plan(beats, downbeats, ws.song.decompte_mesures, sr)
    pad = int(round(plan.pad_s * sr))
    total = pad + len(x)
    stats = grid.tempo_stats(beats)
    removed = sorted({"vocals", *ws.song.retirer})
    stems = {s: audio.read(ws.stems / f"{s}.wav")[0] for s in STEMS}

    acc = sum(stems[s] for s in STEMS if s not in removed)
    peak = float(np.abs(acc).max()) if len(acc) else 0.0
    gain = 0.999 / peak if peak > 0.999 else 1.0
    out = ws.out
    (out / "pistes").mkdir(parents=True, exist_ok=True)
    audio.write_flac(out / "accompagnement.flac", _pad(acc * gain, pad, total), sr)
    audio.write_flac(out / "guide_voix.flac", _pad(stems["vocals"].mean(axis=1), pad, total), sr)
    for s in STEMS:
        audio.write_flac(out / "pistes" / f"{s}.flac", _pad(stems[s], pad, total), sr)
    events = grid.click_events(plan, beats, downbeats)
    audio.write_flac(out / "clic.flac", grid.render_click(events, total, sr), sr)

    n_count = len(plan.times_in)
    with open(out / "temps.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["temps_s", "premier_temps", "source"])
        for i, (t, accent) in enumerate(events):
            w.writerow([f"{t:.6f}", int(accent), "decompte" if i < n_count else "detecte"])
    return {"pad_s": pad / sr, "total_s": total / sr, "beats_per_bar": plan.beats_per_bar,
            "bpm": stats["bpm"], "variation_pct": stats["variation_pct"], "stable": stats["stable"],
            "removed": removed, "gain_db": float(20 * np.log10(gain))}

PACKAGE = Step(name="package", deps=("ingest", "separate", "beats"), key=_key, run=_run)
```

Set `STEPS = [INGEST, SEPARATE, BEATS, PACKAGE]`.

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_package.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/steps karaoke/tests/test_package.py
git commit -m "karaoke: package step (count-in pad, accompaniment, click, stems, temps.csv)"
```

---

### Task 11: Lyrics check step (vocal activity, calage rate, line ends, click drift)

**Files:**
- Create: `karaoke/src/karaoke/steps/check.py`, `karaoke/tests/test_check.py`
- Modify: `karaoke/src/karaoke/steps/__init__.py`

**Interfaces:**
- Consumes: `LYRICS` result, `BEATS` result, stems `vocals` and `drums`, `grid.onsets`, `grid.drift_ms`.
- Produces:
  - `vocal_activity(x: np.ndarray, sr: int, hop_s=0.05) -> np.ndarray[bool]`: frame RMS (50 ms) active when above `max(-45 dBFS, p75(dB) - 20 dB)`.
  - `CHECK: Step` `"check"`, deps `("beats", "separate", "lyrics")`. Result: `{"rate": float|None, "lines": [{"t", "ok": bool, "end": float}], "drift_ms": float}`. A line is **ok** when at least 50% of frames in `[t, t+0.5 s]` are active. `end` is the end of the last active frame before the next line's `t`, or `t + 3` if there is none. `rate = ok/total`, or `None` without lines. `drift_ms = grid.drift_ms(detected beats, onsets(drums stem))`.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_check.py`:

```python
import numpy as np
import pytest
from karaoke import audio
from karaoke.steps.check import CHECK, vocal_activity
from karaoke.workspace import Workspace
from conftest import tone
from test_manifest import song

def vocals_with_phrases(phrases, total=20.0):
    x = np.zeros((int(total * 44100), 2), np.float32)
    for a, b in phrases:
        x[int(a * 44100):int(b * 44100)] = tone(b - a, amp=0.3)[: int(b * 44100) - int(a * 44100)]
    return x

def test_activity():
    act = vocal_activity(vocals_with_phrases([(1, 2)], total=3), 44100)
    assert act[25] and not act[5] and not act[50]

def test_check_rate_and_ends(cfg):
    ws = Workspace(cfg, song())
    audio.write_wav(ws.stems / "vocals.wav", vocals_with_phrases([(2, 5), (8, 10), (15, 18)]))
    audio.write_wav(ws.stems / "drums.wav", np.zeros((20 * 44100, 2), np.float32))
    lines = [{"t": 2.0, "text": "a", "score": 1}, {"t": 8.0, "text": "b", "score": 1},
             {"t": 12.0, "text": "faux", "score": 1}, {"t": 15.0, "text": "c", "score": 1}]
    up = {"beats": {"beats": [0.5 * i for i in range(40)], "downbeats": []}, "separate": {},
          "lyrics": {"lines": lines, "source": "x"}}
    r = CHECK.run(ws, up)
    assert [l["ok"] for l in r["lines"]] == [True, True, False, True]
    assert r["rate"] == 0.75
    assert r["lines"][0]["end"] == pytest.approx(5.0, abs=0.06)

def test_no_lines(cfg):
    ws = Workspace(cfg, song())
    audio.write_wav(ws.stems / "vocals.wav", np.zeros((44100, 2), np.float32))
    audio.write_wav(ws.stems / "drums.wav", np.zeros((44100, 2), np.float32))
    r = CHECK.run(ws, {"beats": {"beats": [0.5, 1.0], "downbeats": []}, "separate": {},
                       "lyrics": {"lines": [], "source": "aucune"}})
    assert r["rate"] is None and r["lines"] == []
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_check.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.steps.check`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/steps/check.py`:

```python
from __future__ import annotations
import numpy as np
from karaoke import audio, grid
from karaoke.runner import Step
from karaoke.workspace import Workspace

HOP_S = 0.05

def vocal_activity(x: np.ndarray, sr: int, hop_s: float = HOP_S) -> np.ndarray:
    mono = x.mean(axis=1) if x.ndim == 2 else x
    hop = int(hop_s * sr)
    n = len(mono) // hop
    if n == 0:
        return np.zeros(0, bool)
    rms = np.sqrt((mono[: n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    thr = max(-45.0, float(np.percentile(db, 75)) - 20.0)
    return db > thr

def _run(ws: Workspace, upstream: dict) -> dict:
    vx, sr = audio.read(ws.stems / "vocals.wav")
    act = vocal_activity(vx, sr)
    lines = upstream["lyrics"]["lines"]
    out = []
    for i, line in enumerate(lines):
        a, b = int(line["t"] / HOP_S), int((line["t"] + 0.5) / HOP_S)
        win = act[a:b]
        ok = bool(win.size and win.mean() >= 0.5)
        nxt = lines[i + 1]["t"] if i + 1 < len(lines) else len(act) * HOP_S
        seg = act[a:int(nxt / HOP_S)]
        idx = np.flatnonzero(seg)
        # last vocal activity before the next line starts (what gap detection needs)
        end = (a + idx[-1] + 1) * HOP_S if idx.size else line["t"] + 3.0
        out.append({"t": line["t"], "ok": ok, "end": round(end, 3)})
    dx, _ = audio.read(ws.stems / "drums.wav")
    drift = grid.drift_ms(upstream["beats"]["beats"], grid.onsets(dx, sr))
    rate = (sum(l["ok"] for l in out) / len(out)) if out else None
    return {"rate": rate, "lines": out, "drift_ms": drift}

CHECK = Step(name="check", deps=("beats", "separate", "lyrics"), key=lambda ws: "v1", run=_run)
```

Set `STEPS = [INGEST, SEPARATE, BEATS, PACKAGE, LYRICS, CHECK]` (LYRICS comes from Task 9).

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_check.py -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/steps karaoke/tests/test_check.py
git commit -m "karaoke: lyrics calage check, line ends and click drift vs drums"
```

---

### Task 12: Lyrics video (timeline, Pillow frames, ffmpeg assembly)

**Files:**
- Create: `karaoke/src/karaoke/video/__init__.py`, `karaoke/src/karaoke/video/timeline.py`, `karaoke/src/karaoke/video/render.py`, `karaoke/src/karaoke/steps/video.py`, `karaoke/tests/test_timeline.py`, `karaoke/tests/test_video.py`
- Modify: `karaoke/src/karaoke/steps/__init__.py`

**Interfaces:**
- Consumes: results of `package` (`pad_s`, `total_s`), `lyrics` (`lines`, `source`), `check` (`lines[].end`).
- Produces:
  - `@dataclass(frozen=True) State(start: float, end: float, kind: str, current: str, next: str, countdown: int | None)` with `kind ∈ {"titre", "ligne", "instrumental", "fin"}`. Times are **output** times.
  - `build_states(lines: list[tuple[float, float, str]], pad_s: float, total_s: float, titre: str, artiste: str, lead_s: float = 0.2, gap_s: float = 8.0, countdown_s: float = 3.0) -> list[State]`. `lines` are `(start_out, end_out, text)`. The states cover `[0, total_s]` contiguously with no overlaps. A line is shown from `start - lead_s`. A gap with `next_start - end > gap_s` becomes an `instrumental` state whose last `countdown_s` seconds are split into 1-second states with countdown 3, 2, 1. The title shows as one state until the first line's display time, with a countdown in its last seconds if the first line starts more than `gap_s` after the count-in.
  - `render.render_video(states, out_mp4: Path, work: Path, fps: int = 25) -> None`: one PNG per distinct `(kind, current, next, countdown)`, an ffmpeg concat list with durations, libx264 yuv420p, no audio.
  - `VIDEO: Step` `"video"`, deps `("package", "lyrics", "check")`. It writes `ws.out/"paroles.lrc"` (line times + `pad_s`) and `ws.out/"paroles.mp4"`. Result: `{"duration_s", "states": n}`.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_timeline.py`:

```python
import pytest
from karaoke.video.timeline import build_states

def contiguous(states, total):
    assert states[0].start == 0.0 and states[-1].end == pytest.approx(total)
    for a, b in zip(states, states[1:]):
        assert a.end == pytest.approx(b.start)

def test_title_then_lines():
    st = build_states([(4.0, 6.0, "Un"), (6.5, 8.0, "Deux")], pad_s=3.5, total_s=12.0, titre="T", artiste="A")
    contiguous(st, 12.0)
    assert st[0].kind == "titre" and st[0].end == pytest.approx(3.8)
    l1 = next(s for s in st if s.current == "Un")
    assert l1.start == pytest.approx(3.8) and l1.next == "Deux"
    assert st[-1].kind == "fin"

def test_instrumental_gap_has_countdown():
    st = build_states([(4.0, 6.0, "Un"), (20.0, 22.0, "Deux")], pad_s=3.5, total_s=25.0, titre="T", artiste="A")
    contiguous(st, 25.0)
    instr = [s for s in st if s.kind == "instrumental"]
    assert instr and instr[0].next == "Deux"
    assert [s.countdown for s in instr if s.countdown] == [3, 2, 1]
    assert [s for s in instr if s.countdown == 1][0].end == pytest.approx(19.8)

def test_no_lines_is_title_only():
    st = build_states([], pad_s=2.0, total_s=30.0, titre="Instru", artiste="X")
    contiguous(st, 30.0)
    assert {s.kind for s in st} == {"titre"}
```

`karaoke/tests/test_video.py`:

```python
from karaoke.audio import probe_duration
from karaoke.video.render import render_video
from karaoke.video.timeline import build_states

def test_render_duration_and_size(tmp_path):
    st = build_states([(2.0, 4.0, "Je suis un homme"), (4.5, 6.0, "À ma place, dis !")],
                      pad_s=1.5, total_s=8.0, titre="Je suis un homme", artiste="Zazie")
    out = tmp_path / "v.mp4"
    render_video(st, out, tmp_path / "frames")
    assert abs(probe_duration(out) - 8.0) < 0.1
    import subprocess
    dims = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                           "stream=width,height", "-of", "csv=p=0", str(out)], capture_output=True, text=True).stdout.strip()
    assert dims == "1920,1080"
    audio_streams = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                                    "stream=index", "-of", "csv=p=0", str(out)], capture_output=True, text=True).stdout.strip()
    assert audio_streams == ""
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_timeline.py tests/test_video.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.video`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/video/__init__.py`: empty file.

`karaoke/src/karaoke/video/timeline.py`:

```python
from __future__ import annotations
from dataclasses import dataclass

@dataclass(frozen=True)
class State:
    start: float
    end: float
    kind: str
    current: str
    next: str
    countdown: int | None

def _wait(start: float, end: float, kind: str, current: str, nxt: str, countdown_s: float,
          with_countdown: bool) -> list[State]:
    if end <= start:
        return []
    if not with_countdown or end - start <= countdown_s:
        return [State(start, end, kind, current, nxt, None)]
    cd_start = end - countdown_s
    out = [State(start, cd_start, kind, current, nxt, None)]
    n = int(round(countdown_s))
    for k in range(n):
        out.append(State(cd_start + k, cd_start + k + 1 if k < n - 1 else end, kind, current, nxt, n - k))
    return out

def build_states(lines, pad_s, total_s, titre, artiste, lead_s=0.2, gap_s=8.0, countdown_s=3.0) -> list[State]:
    title = f"{titre} — {artiste}"
    if not lines:
        return [State(0.0, total_s, "titre", title, "", None)]
    shows = [max(0.0, s - lead_s) for s, _, _ in lines]
    states: list[State] = []
    first = shows[0]
    states += _wait(0.0, first, "titre", title, lines[0][2], countdown_s, first - pad_s > gap_s)
    for i, (start, end, text) in enumerate(lines):
        nxt = lines[i + 1][2] if i + 1 < len(lines) else ""
        show = shows[i]
        stop = shows[i + 1] if i + 1 < len(lines) else min(total_s, max(end, start) + 2.0)
        if i + 1 < len(lines) and lines[i + 1][0] - end > gap_s:
            sing_end = min(stop, end + 0.5)
            states.append(State(show, sing_end, "ligne", text, nxt, None))
            states += _wait(sing_end, stop, "instrumental", "", nxt, countdown_s, True)
        else:
            states.append(State(show, stop, "ligne", text, nxt, None))
    if states[-1].end < total_s:
        states.append(State(states[-1].end, total_s, "fin", "", "", None))
    return [s for s in states if s.end - s.start > 1e-6]
```

`karaoke/src/karaoke/video/render.py`:

```python
from __future__ import annotations
import hashlib, subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from karaoke.video.timeline import State

W, H = 1920, 1080
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG = "/System/Library/Fonts/Supplemental/Arial.ttf"
SYM = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"   # ♪ and ● (missing from Arial)

def _font(path: str, size: int):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default(size)

def _wrap(draw, text, font, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = f"{cur} {w}".strip()
        if draw.textlength(trial, font=font) <= width or not cur:
            cur = trial
        else:
            lines.append(cur); cur = w
    return lines + ([cur] if cur else [])

def _centered(draw, y, text, font, fill):
    for line in _wrap(draw, text, font, W - 200):
        draw.text(((W - draw.textlength(line, font=font)) / 2, y), line, font=font, fill=fill)
        y += int(font.size * 1.25)
    return y

def _frame(s: State) -> Image.Image:
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    big, mid, small = _font(BOLD, 96), _font(REG, 64), _font(SYM, 160)
    if s.kind == "titre":
        _centered(d, 380, s.current, big, (255, 255, 255))
    elif s.kind == "ligne":
        y = _centered(d, 380, s.current, big, (255, 214, 0))
        _centered(d, max(y + 60, 640), s.next, mid, (150, 150, 150))
    elif s.kind == "instrumental":
        _centered(d, 300, "♪", small, (90, 90, 90))
        _centered(d, 640, s.next, mid, (150, 150, 150))
    if s.countdown:
        _centered(d, 120, "●" * s.countdown, _font(SYM, 110), (255, 80, 80))
    return img

def render_video(states: list[State], out_mp4: Path, work: Path, fps: int = 25) -> None:
    work.mkdir(parents=True, exist_ok=True)
    entries = []
    for s in states:
        h = hashlib.sha1(repr((s.kind, s.current, s.next, s.countdown)).encode()).hexdigest()[:16]
        png = work / f"{h}.png"
        if not png.exists():
            _frame(s).save(png)
        entries.append((png, s.end - s.start))
    lst = work / "concat.txt"
    with open(lst, "w", encoding="utf-8") as f:
        for png, dur in entries:
            f.write(f"file '{png}'\nduration {dur:.6f}\n")
        f.write(f"file '{entries[-1][0]}'\n")
    total = sum(d for _, d in entries)
    out_mp4.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                    "-vf", f"fps={fps},format=yuv420p", "-c:v", "libx264", "-tune", "stillimage",
                    "-crf", "20", "-t", f"{total:.3f}", "-an", str(out_mp4)], check=True)
```

`karaoke/src/karaoke/steps/video.py`:

```python
from __future__ import annotations
from karaoke import lrc
from karaoke.runner import Step
from karaoke.video.render import render_video
from karaoke.video.timeline import build_states
from karaoke.workspace import Workspace

def _run(ws: Workspace, upstream: dict) -> dict:
    pad, total = upstream["package"]["pad_s"], upstream["package"]["total_s"]
    lines = upstream["lyrics"]["lines"]
    ends = {round(l["t"], 3): l["end"] for l in upstream["check"]["lines"]}
    timed = [(l["t"] + pad, ends.get(round(l["t"], 3), l["t"] + 3.0) + pad, l["text"]) for l in lines]
    (ws.out / "paroles.lrc").write_text(lrc.format([lrc.Line(round(s, 3), t) for s, _, t in timed]),
                                        encoding="utf-8")
    states = build_states(timed, pad, total, ws.song.titre, ws.song.artiste)
    render_video(states, ws.out / "paroles.mp4", ws.work / "frames")
    return {"duration_s": total, "states": len(states)}

VIDEO = Step(name="video", deps=("package", "lyrics", "check"), key=lambda ws: f"{ws.song.titre}|{ws.song.artiste}|v1", run=_run)
```

Set `STEPS = [INGEST, SEPARATE, BEATS, PACKAGE, LYRICS, CHECK, VIDEO]`.

- [ ] **Step 4: Run tests**

Run: `cd karaoke && uv run pytest tests/test_timeline.py tests/test_video.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/video karaoke/src/karaoke/steps karaoke/tests/test_timeline.py karaoke/tests/test_video.py
git commit -m "karaoke: lyrics video (display timeline, Pillow frames, ffmpeg concat)"
```

---

### Task 13: Reports and the `traiter` / `rapport` commands

**Files:**
- Create: `karaoke/src/karaoke/report.py`, `karaoke/tests/test_report.py`
- Modify: `karaoke/src/karaoke/cli.py`, `karaoke/src/karaoke/steps/__init__.py`

**Interfaces:**
- Consumes: `run_song` outputs, `Workspace`, `read_manifest`, `STEPS`.
- Produces:
  - `song_report(song: Song, results: dict[str, dict]) -> dict`: `{"id","titre","artiste","statut": "ok"|"alerte"|"echec","etapes": {name: status},"secondes": {name: s},"duree_ecart_s","tempo": {"bpm","variation_pct","stable"},"clic_derive_ms","paroles": {"source","lignes","taux_calage"},"alertes": [str],"risque": int}`.
  - Risk score: failed or blocked step +100; lyrics `aucune` +60 (« sans paroles »); `a_reessayer` +40; calage under 90% +`round((0.9 - rate) * 200)`; unstable tempo +20; drift over 30 ms +20; duration delta over 2 s +15. `statut` is `echec` if any step failed or was blocked, else `alerte` if there are alerts, else `ok`.
  - `write_global(rows: list[dict], csv_path: Path, html_path: Path) -> None`, sorted by `risque` descending.
  - REPORT step: `REPORT = Step("report", deps=(), key=…, run=…, always=True)` is **not** used; the CLI writes `rapport.json` after each song so failures are reported too.
  - CLI: `karaoke traiter [--ids 041,066] [--etape NAME] [--forcer NAME,...]` runs every manifest song (or `--ids`), writes `ws.out/"rapport.json"` and then the global report. `karaoke rapport` rebuilds the global report from existing `rapport.json` files.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_report.py`:

```python
from karaoke.report import song_report, write_global
from test_manifest import song

def ok(result): return {"status": "fait", "seconds": 1.0, "result": result, "error": ""}

BASE = {"ingest": ok({"ref_delta_s": 0.1, "duration_alert": False}),
        "separate": ok({}), "beats": ok({}),
        "package": ok({"bpm": 120.0, "variation_pct": 1.0, "stable": True}),
        "lyrics": ok({"source": "lrclib-synchro", "lines": [{}] * 10}),
        "check": ok({"rate": 1.0, "drift_ms": 8.0}), "video": ok({})}

def test_clean_song_is_ok():
    r = song_report(song(), BASE)
    assert r["statut"] == "ok" and r["risque"] == 0 and r["alertes"] == []

def test_risks_add_up():
    res = dict(BASE)
    res["lyrics"] = ok({"source": "aucune", "lines": []})
    res["check"] = ok({"rate": None, "drift_ms": 45.0})
    res["package"] = ok({"bpm": 90.0, "variation_pct": 6.0, "stable": False})
    r = song_report(song(), res)
    assert r["statut"] == "alerte" and r["risque"] == 60 + 20 + 20
    assert any("sans paroles" in a for a in r["alertes"])

def test_failure_and_retry():
    res = dict(BASE)
    res["separate"] = {"status": "echec", "seconds": 0, "result": {}, "error": "boom"}
    res["lyrics"] = {"status": "a_reessayer", "seconds": 0, "result": {}, "error": "offline"}
    r = song_report(song(), res)
    assert r["statut"] == "echec" and r["risque"] >= 140

def test_global_sorted(tmp_path):
    rows = [song_report(song(id="001"), BASE), {**song_report(song(id="002"), BASE), "risque": 50}]
    write_global(rows, tmp_path / "r.csv", tmp_path / "r.html")
    lines = (tmp_path / "r.csv").read_text(encoding="utf-8").splitlines()
    assert lines[1].startswith("002") and "<table" in (tmp_path / "r.html").read_text(encoding="utf-8")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_report.py -v`
Expected: FAIL, `ModuleNotFoundError: karaoke.report`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/report.py`:

```python
from __future__ import annotations
import csv, html, json
from pathlib import Path
from karaoke.manifest import Song

def song_report(song: Song, results: dict[str, dict]) -> dict:
    alerts, risk = [], 0
    def res(n): return results.get(n, {}).get("result", {})
    statuses = {n: r["status"] for n, r in results.items()}
    for n, st in statuses.items():
        if st in ("echec", "bloque"):
            risk += 100; alerts.append(f"{n} : {st} {results[n].get('error', '')}".strip())
        elif st == "a_reessayer":
            risk += 40; alerts.append(f"{n} : à réessayer ({results[n].get('error', '')})")
    ing, pkg, lyr, chk = res("ingest"), res("package"), res("lyrics"), res("check")
    if ing.get("duration_alert"):
        risk += 15; alerts.append(f"écart de durée {ing.get('ref_delta_s', 0):+.1f} s")
    if pkg and not pkg.get("stable", True):
        risk += 20; alerts.append(f"tempo instable ({pkg.get('variation_pct', 0):.1f} %)")
    if chk.get("drift_ms", 0) > 30:
        risk += 20; alerts.append(f"dérive du clic {chk['drift_ms']:.0f} ms")
    if lyr.get("source") == "aucune":
        risk += 60; alerts.append("sans paroles : fournir paroles/<id>.txt")
    rate = chk.get("rate")
    if rate is not None and rate < 0.9:
        risk += round((0.9 - rate) * 200); alerts.append(f"calage des paroles {rate:.0%}")
    failed = any(st in ("echec", "bloque") for st in statuses.values())
    return {"id": song.id, "titre": song.titre, "artiste": song.artiste,
            "statut": "echec" if failed else ("alerte" if alerts else "ok"),
            "etapes": statuses, "secondes": {n: round(r.get("seconds", 0), 1) for n, r in results.items()},
            "duree_ecart_s": ing.get("ref_delta_s"),
            "tempo": {k: pkg.get(k) for k in ("bpm", "variation_pct", "stable")},
            "clic_derive_ms": chk.get("drift_ms"),
            "paroles": {"source": lyr.get("source"), "lignes": len(lyr.get("lines", [])), "taux_calage": rate},
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
        w = csv.DictWriter(f, fieldnames=FIELDS); w.writeheader()
        for r in rows: w.writerow(_flat(r))
    body = "".join("<tr class='{}'>{}</tr>".format(r["statut"], "".join(
        f"<td>{html.escape(str(v))}</td>" for v in _flat(r).values())) for r in rows)
    head = "".join(f"<th>{h}</th>" for h in FIELDS)
    html_path.write_text(
        "<!doctype html><meta charset='utf-8'><title>Rapport karaoké</title>"
        "<style>body{font:14px system-ui;margin:24px}table{border-collapse:collapse}"
        "td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}"
        "tr.echec{background:#fdd}tr.alerte{background:#ffe9c7}</style>"
        f"<h1>Rapport karaoké ({len(rows)} morceaux)</h1><table><tr>{head}</tr>{body}</table>", encoding="utf-8")

def load_reports(sortie: Path) -> list[dict]:
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(sortie.glob("*/rapport.json"))]
```

Add to `karaoke/src/karaoke/cli.py`:

```python
import json
from karaoke.report import song_report, write_global, load_reports
from karaoke.runner import run_song
from karaoke.steps import STEPS
from karaoke.workspace import Workspace

def _csv_set(v: str | None) -> set[str] | None:
    return {x.strip() for x in v.split(",") if x.strip()} if v else None

@app.command()
def traiter(ids: str = typer.Option(None, help="Liste d'id à traiter, ex. 041,066"),
            etape: str = typer.Option(None, help="N'exécuter que cette étape"),
            forcer: str = typer.Option(None, help="Étapes à refaire, ex. package,video")) -> None:
    """Traite les morceaux du manifeste (reprend là où il s'est arrêté)."""
    cfg = Config.load(); cfg.ensure_dirs()
    songs = read_manifest(cfg.manifest)
    wanted = _csv_set(ids)
    names = {s.name for s in STEPS}
    for opt in filter(None, [etape, *(_csv_set(forcer) or [])]):
        if opt not in names:
            raise typer.BadParameter(f"étape inconnue « {opt} » (étapes : {', '.join(names)})")
    for s in songs:
        if wanted and s.id not in wanted:
            continue
        ws = Workspace(cfg, s)
        typer.echo(f"▶ {s.id} {s.artiste} – {s.titre}")
        res = run_song(ws, STEPS, force=_csv_set(forcer) or set(), only={etape} if etape else None)
        rep = song_report(s, res)
        ws.out.mkdir(parents=True, exist_ok=True)
        (ws.out / "rapport.json").write_text(json.dumps(rep, ensure_ascii=False, indent=2), encoding="utf-8")
        typer.echo("   " + "  ".join(f"{n}:{r['status']}" for n, r in res.items()) + f"  → {rep['statut']}")
    write_global(load_reports(cfg.sortie), cfg.home / "rapport.csv", cfg.home / "rapport.html")
    typer.echo(f"Rapport : {cfg.home / 'rapport.html'}")

@app.command()
def rapport() -> None:
    """Reconstruit le rapport global depuis les rapport.json existants."""
    cfg = Config.load()
    write_global(load_reports(cfg.sortie), cfg.home / "rapport.csv", cfg.home / "rapport.html")
    typer.echo(f"Rapport : {cfg.home / 'rapport.html'}")
```

Final `steps/__init__.py`:

```python
from karaoke.steps.ingest import INGEST
from karaoke.steps.separate import SEPARATE
from karaoke.steps.beats import BEATS
from karaoke.steps.package import PACKAGE
from karaoke.steps.lyrics import LYRICS
from karaoke.steps.check import CHECK
from karaoke.steps.video import VIDEO

STEPS = [INGEST, SEPARATE, BEATS, PACKAGE, LYRICS, CHECK, VIDEO]
```

- [ ] **Step 4: Run the whole fast suite**

Run: `cd karaoke && uv run pytest -v`
Expected: all fast tests pass (about 50). Also run `uv run karaoke --help`: it lists `manifeste`, `traiter`, `rapport`.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/report.py karaoke/src/karaoke/cli.py karaoke/src/karaoke/steps/__init__.py karaoke/tests/test_report.py
git commit -m "karaoke: per-song and global risk reports, traiter/rapport commands"
```

---

### Task 14: Phase 0 run on 3 songs and go/no-go measurements

**Files:**
- Create: `docs/karaoke/phase0-resultats.md`
- Modify: `karaoke/README.md` (create: one-page usage, see Step 5)

**Interfaces:**
- Consumes: everything above. The 3 test songs come from Michel (titles to be confirmed: stable tempo, old or fluctuating, French and missing from LRCLIB), recorded with SysRec into `~/Music/SysRec/<list>/`.

- [ ] **Step 1: Build the phase 0 manifest**

```bash
export KARAOKE_HOME=/Volumes/Hypermnesia/karaoke
cd ~/Documents/mp3-pipeline/karaoke
uv run karaoke manifeste --audio "$HOME/Music/SysRec/Karaoké - Feuille 1"
```

Edit `$KARAOKE_HOME/manifeste.csv` to keep only the 3 test rows, and set `retirer` per song (for example `guitar;piano` for what Michel and Pierre play) and `langue`. For the French song missing from LRCLIB, put its text in `$KARAOKE_HOME/paroles/<id>.txt`.

- [ ] **Step 2: Run the pipeline and time it**

```bash
time uv run karaoke traiter
open "$KARAOKE_HOME/rapport.html"
```

Expected: 3 folders in `$KARAOKE_HOME/sortie/`, each with `accompagnement.flac, clic.flac, guide_voix.flac, pistes/ (6), paroles.lrc, paroles.mp4, temps.csv, rapport.json`. Run it again: every step shows `saute`, which shows resume works. Then change `retirer` for one song and run again: only `package` and `video` rerun for that song.

- [ ] **Step 3: Verify the sync invariant on disk**

```bash
cd "$KARAOKE_HOME/sortie" && for d in */; do
  for f in "$d"*.flac "$d"pistes/*.flac; do printf "%s %s\n" "$(ffprobe -v error -show_entries stream=duration_ts -of csv=p=0 "$f")" "$f"; done | sort | uniq -c -w 12
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$d/paroles.mp4"
done
```

Expected: within each folder, every FLAC has the same `duration_ts`, and the MP4 duration matches to within 0.1 s.

- [ ] **Step 4: Fill in the go/no-go table**

Write `docs/karaoke/phase0-resultats.md` with one row per criterion from the spec's phase 0. Measured: click drift per song (`clic_derive_ms` in the report; the target is under 30 ms on the stable song), lyric calage rate (target ≥ 90%), and processing time per song from `rapport.json` `secondes`, extrapolated as `sum / total audio minutes × 480 min` against the target of under two nights. Michel's judgement by ear: separation usable with no annoying doubling with the live parts. The two Ableton criteria are marked « reporté au plan Ableton ». Also note which hypotheses held (machine, disk, French lyrics coverage across the 3 songs).

- [ ] **Step 5: One-page usage**

`karaoke/README.md`:

````markdown
# Karaoké live : pipeline d'analyse

```sh
export KARAOKE_HOME=/Volumes/Hypermnesia/karaoke     # disque externe (≈ 0,5 Go par morceau en travail)
uv run karaoke manifeste --audio "~/Music/SysRec/Karaoké - Feuille 1"   # puis compléter retirer / langue / partie
uv run karaoke traiter                    # tout, reprend là où ça s'est arrêté
uv run karaoke traiter --ids 041 --forcer package,video   # refaire un morceau après changement de « retirer »
uv run karaoke rapport                    # rapport.csv / rapport.html triés par risque
```

Paroles manquantes : `$KARAOKE_HOME/paroles/<id>.txt` (texte brut, aligné automatiquement) ou
`<id>.lrc` (déjà synchronisé, prioritaire). Spec : `docs/karaoke/cahier-des-charges.md`.
````

- [ ] **Step 6: Commit**

```bash
git add docs/karaoke/phase0-resultats.md karaoke/README.md
git commit -m "karaoke: phase 0 results and usage page"
```

---

## Self-review notes (done while writing)

- **Spec coverage:** processing steps 1–7 → Tasks 5, 6, 7+10, 8+9, 11, 12, 13. Step 8 (Ableton) → separate plan, noted at the top. Manifest columns → Task 2; the `isrc` column is kept but filled only by the future Spotify option (SysRec tags carry no ISRC, and nothing in this pipeline needs it). Non-functional requirements: resume and targeted reprocessing → Task 4 plus the CLI `--ids/--etape/--forcer`; traceability → `journal.log` plus the reports; offline except LRCLIB → only `lrclib.fetch` touches the network; click and lyric precision measured → Tasks 11 and 14.
- **Deviation from the spec, deliberate:** the spec names « ffmpeg avec sous-titres ASS ». This ffmpeg has no libass, so frames are drawn with Pillow and assembled by ffmpeg (Task 12). Same output, and it allows the countdown and highlight styling. Also, a `paroles/<id>.lrc` file overrides every source, so Michel's manual corrections stick.
- **Type consistency:** step names `ingest, separate, beats, package, lyrics, check, video` are used identically in deps, `STEPS`, the report and the CLI. Upstream result keys are used only as defined: `offset_s`, `duration_s`, `beats`, `downbeats`, `pad_s`, `total_s`, `lines[].t/text/score`, `lines[].end`, `rate`, `drift_ms`.
