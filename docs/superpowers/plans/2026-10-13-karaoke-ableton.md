# Karaoké live: Ableton sets and XR18 faders, implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate one ready-to-open Ableton Live 12.4.6 set (`.als`) per part of the evening from the processed song folders. Songs follow one another in the Arrangement with one locator each. Every part plays on its own XR18 channel, and a MIDI clip at each song start puts the XR18 faders at that song's default levels: parts played live start at zero.

**Architecture:** Two changes on top of the phase-0 pipeline.

1. **The `package` step** (version 4) writes channel-ready files:
   - `accompagnement.flac`: everything except vocals, guitar, bass, piano and drums (the `other` stem);
   - `guitare.flac`, `basse.flac`, `piano.flac`: mono;
   - `batterie.flac`: mono (decided 2026-10-13);
   - `guide_voix.flac`: **lead vocals** only, mono; `back_vocals.flac`: **backing vocals**, mono (new `vocals_split` step);
   - default XR18 fader values in its result: 0 for the parts in `retirer`, 0 dB for the others.
2. **A new `karaoke.ableton` package** builds sets by editing Michel's template (`gabarit.als`, gzip XML) with ElementTree. It uses element snippets copied verbatim from Michel's hand-made `reference.als`: audio clip, video clip, MIDI clip with CC envelopes, locator. Only the values change. The template's routing, tracks and settings are never touched.

**Tech Stack:** Python 3.11 (existing `karaoke` package), `xml.etree.ElementTree`, `gzip`, numpy/soundfile (existing), ffprobe. New isolated tool env `karaoke/tools/vocals` (`audio-separator`, Mel-Band RoFormer karaoke model) for the lead/backing split.

**Spec:** `docs/karaoke/cahier-des-charges.md` (§ Intégration Ableton, step 8), amended by `docs/karaoke/ableton-xr18-decisions.md`.

## Facts established from Michel's files (2026-10-12, Live 12.4.6)

The template and reference live in `/Volumes/Hypermnesia/karaoke/gabarit/gabarit Project/`: `gabarit.als` and `reference.als`.

- **Root:** `<Ableton MajorVersion="5" MinorVersion="12.0_12402" Creator="Ableton Live 12.4.6">`. Tempo 120, 4/4. `NextPointeeId` = 23035.
- **Tracks, in order (`Name/EffectiveName`), with outputs:**

| Track | Type | Output |
|---|---|---|
| Accompagnement | AudioTrack | `AudioOut/External/S8` (17/18) |
| Clic | AudioTrack | `M9` (10) |
| Guide Voix | AudioTrack | `M10` (11) |
| Guitare | AudioTrack | `M11` (12) |
| Basse | AudioTrack | `M12` (13) |
| Piano | AudioTrack | `M13` (14) |
| Batterie | AudioTrack | `S7` (15/16) → **Michel changes it to mono `M14` (15)** |
| Back Vocals | AudioTrack | **new track, added by Michel**: mono `M15` (16) |
| Vidéo | AudioTrack | none, track off |
| XR18 faders | MidiTrack | MIDI out to X18/XR18, channel 1 |

- **Where clips go:**
  - audio clips: `AudioTrack/DeviceChain/MainSequencer/Sample/ArrangerAutomation/Events`;
  - MIDI clips: `MidiTrack/DeviceChain/MainSequencer/ClipTimeable/ArrangerAutomation/Events`;
  - locators: `LiveSet/Locators/Locators`.
- **Arrangement time unit:** beats at 120 BPM, so `beats = seconds × 2`. Unwarped clips (`IsWarped=false`) keep their loop fields in **seconds**. Reference clip (201.288 s): `Time=0`, `CurrentStart=0`, `CurrentEnd=402.576`, `LoopEnd=201.288`, `HiddenLoopEnd=201.288`. `OutMarker` is 402.576 (beats) for audio clips but 201.236 (seconds) for the video clip, so each is copied as Live wrote it.
- **The video clip** is an ordinary `AudioClip` pointing to `paroles.mp4` (no audio stream needed). Live read its length as 201.2365 s and `DefaultDuration` 8876448 (= length × 44100).
- **`SampleRef/FileRef` fields:**
  - `RelativePathType=1`;
  - `RelativePath` is relative to the set's folder (`../../sortie/<dossier>/<file>`);
  - `Path` is absolute;
  - `Type=2`;
  - `OriginalFileSize` = bytes;
  - `OriginalCrc` = Live's own checksum (unknown algorithm);
  - `LastModDate` = mtime (epoch seconds);
  - `DefaultDuration` = frames;
  - `DefaultSampleRate=44100`.
- **MIDI CC envelopes:**
  - they live in `MidiClip/Envelopes/Envelopes/ClipEnvelope`;
  - `EnvelopeTarget/PointeeId` = the `Id` attribute of `MidiTrack/.../MidiControllers/ControllerTargets.{cc + 2}` (verified: CC 11 → `ControllerTargets.13` Id 22555, CC 16 → `ControllerTargets.18` Id 22560);
  - events are `FloatEvent Time Value`, the value in CC units 0–127, plus a default-value event at `Time=-63072000`.
- **XR18 MIDI (Behringer chart):** MIDI channel 1, `CC 0–15` = input-channel faders 1–16, `CC 16` = AuxLineIn 17–18 fader, value 0–127.

## Global Constraints

- Generated sets open in **Live 12.4.6** without errors or missing-media prompts. The output is gzip-compressed XML with the template's root attributes unchanged.
- **The template file is never modified.** Sets are written to `$KARAOKE_HOME/sets/<partie>.als`.
- XR18 channel ↔ track ↔ fader CC (MIDI channel 1):

| Track | XR18 channel | Fader CC |
|---|---|---|
| Clic | 10 | 9 |
| Guide Voix (lead vocals) | 11 | 10 |
| Guitare | 12 | 11 |
| Basse | 13 | 12 |
| Piano | 14 | 13 |
| Batterie (mono) | 15 | 14 |
| Back Vocals (backing vocals) | 16 | 15 |
| Accompagnement | 17–18 | 16 |

- **Per-song default faders:** parts in `retirer` → CC 0 (−∞). Other parts, the backing vocals (Back Vocals) and the accompaniment → 0 dB (`xair_cc(0.0)`). Click and guide vocal (lead) faders are **not** sent: Michel sets them once on the console (lead vocals go to the in-ears only).
- **Prerequisite (Michel):** template updated (Batterie → output 15 mono; new audio track « Back Vocals » → output 16 mono), XR18 channels 15 and 16 unlinked, mono, source USB. Task 1 copies the **updated** template.
- All files of a song still start at the same zero and have the same length (phase-0 invariant), so in a set all of a song's clips share one `Time`.
- Songs are spaced by `GAP_S = 4.0` seconds of silence. There's one locator per song, named `"<id> <titre>"`, at its start. Song order = manifest order within a `partie`.

## Review Focus

1. **A song folder with a missing file** (e.g. an old phase-0 folder without `guitare.flac`). Set generation must refuse it with a clear message naming the song, not write a set Live opens with missing media. Test in Task 6.
2. **Titles with XML-special characters** (`&`, `<`, quotes, « Il est cinq heures, Paris s'éveille »). Locator names and clip names must be escaped correctly. ElementTree handles this, but there's a test in Task 5.
3. **An empty `partie` cell.** Those songs go into one set named `sans-partie`, never silently dropped. Test in Task 3.
4. **Re-running `karaoke sets`** after a song changes. The set is fully regenerated from the template (no clip accumulation). Test in Task 6.
5. **Id collisions.** Every new element gets an `Id` unique within its parent list, the same way Live numbers them, and `NextPointeeId` stays above every `PointeeId` used. Test in Task 5.

---

## File Structure

```
karaoke/src/karaoke/
  xair.py                       PURE: X Air fader law dB ↔ CC
  steps/vocals_split.py         lead / backing vocals (audio-separator, isolated tool env)
  steps/package.py              (modify) v4: channel files + fader defaults
  manifest.py                   (modify) group_by_partie()
  ableton/__init__.py
  ableton/snippets/audioclip.xml   copied from reference.als (Accompagnement clip)
  ableton/snippets/videoclip.xml   copied from reference.als (Vidéo clip)
  ableton/snippets/midiclip.xml    copied from reference.als (XR18 faders clip)
  ableton/snippets/locator.xml     copied from reference.als
  ableton/als.py                load/save gzip XML, track lookup, Id helpers
  ableton/clips.py              audio_clip(), video_clip(), midi_clip(), locator()
  ableton/build.py              SongEntry, build_set()
  cli.py                        (modify) `karaoke sets`
karaoke/tests/
  fixtures/ableton/gabarit.als, reference.als     (copies of Michel's files)
  test_xair.py  test_vocals_split.py  test_package.py (modify)  test_manifest.py (modify)
  test_als.py  test_clips.py  test_build.py
docs/karaoke/ableton-validation.md                 (Task 7: Michel's checks in Live)
```

---

### Task 1: Fixtures and snippets from Michel's reference set

**Files:**
- Create: `karaoke/tests/fixtures/ableton/gabarit.als`, `karaoke/tests/fixtures/ableton/reference.als` (copies), `karaoke/src/karaoke/ableton/__init__.py`, `karaoke/src/karaoke/ableton/snippets/{audioclip,videoclip,midiclip,locator}.xml`, `karaoke/tests/test_als.py`
- Create: `karaoke/src/karaoke/ableton/als.py`

**Interfaces:**
- Produces:
  - `load_als(path: Path) -> ET.ElementTree` (gunzip + parse);
  - `save_als(tree: ET.ElementTree, path: Path) -> None` (serialize with `<?xml version="1.0" encoding="UTF-8"?>`, gzip);
  - `track(liveset: ET.Element, name: str) -> ET.Element` (by `Name/EffectiveName`, `KeyError` listing the names found);
  - `arranger_events(track_el) -> ET.Element` (the `Events` list for audio or MIDI tracks);
  - `snippet(name: str) -> ET.Element` (fresh parse of `snippets/<name>.xml`);
  - `controller_target_id(midi_track, cc: int) -> str` (Id of `ControllerTargets.{cc+2}`);
  - `TRACKS = {"accompagnement": "Accompagnement", "clic": "Clic", "guide_voix": "Guide Voix", "guitare": "Guitare", "basse": "Basse", "piano": "Piano", "batterie": "Batterie", "back_vocals": "Back Vocals", "video": "Vidéo", "faders": "XR18 faders"}`.

- [ ] **Step 1: Copy fixtures and extract snippets**

```bash
cd ~/Documents/mp3-pipeline/karaoke
mkdir -p tests/fixtures/ableton src/karaoke/ableton/snippets
P="/Volumes/Hypermnesia/karaoke/gabarit/gabarit Project"
cp "$P/gabarit.als" "$P/reference.als" tests/fixtures/ableton/
uv run python - <<'EOF'
import gzip, xml.etree.ElementTree as ET
ls = ET.fromstring(gzip.open("tests/fixtures/ableton/reference.als").read()).find("LiveSet")
by = {t.find("Name/EffectiveName").get("Value"): t for t in ls.find("Tracks")}
out = {
  "audioclip": by["Accompagnement"].find(".//Sample/ArrangerAutomation/Events/AudioClip"),
  "videoclip": by["Vidéo"].find(".//Sample/ArrangerAutomation/Events/AudioClip"),
  "midiclip":  by["XR18 faders"].find(".//ClipTimeable/ArrangerAutomation/Events/MidiClip"),
  "locator":   ls.find("Locators/Locators/Locator"),
}
for name, el in out.items():
    open(f"src/karaoke/ableton/snippets/{name}.xml", "w", encoding="utf-8").write(ET.tostring(el, encoding="unicode"))
EOF
echo '"""Ableton Live set generation from Michel'"'"'s template."""' > src/karaoke/ableton/__init__.py
```

Add to `pyproject.toml` nothing: uv_build packages non-Python files under `src/` by default. Verify with `uv run python -c "import importlib.resources as r; print(r.files('karaoke.ableton').joinpath('snippets/audioclip.xml').is_file())"` → `True`.

- [ ] **Step 2: Write the failing tests**

`karaoke/tests/test_als.py`:

```python
from pathlib import Path
import gzip
import pytest
from karaoke.ableton.als import (load_als, save_als, track, arranger_events, snippet,
                                 controller_target_id, TRACKS)

FIX = Path(__file__).parent / "fixtures" / "ableton"


def test_load_and_tracks():
    ls = load_als(FIX / "gabarit.als").getroot().find("LiveSet")
    # tracks are found by name; Michel may order them as he likes
    assert sorted(t.find("Name/EffectiveName").get("Value") for t in ls.find("Tracks")) == sorted(TRACKS.values())
    assert len(arranger_events(track(ls, "Accompagnement"))) == 0
    assert arranger_events(track(ls, "XR18 faders")).tag == "Events"
    with pytest.raises(KeyError, match="Accompagnement"):
        track(ls, "Inconnue")


def test_controller_ids_match_reference():
    # Michel's reference clip drew CC 11 and CC 16: its PointeeIds must be ControllerTargets.13 / .18
    ls = load_als(FIX / "reference.als").getroot().find("LiveSet")
    mt = track(ls, "XR18 faders")
    clip_ids = [e.get("Value") for e in mt.iter("PointeeId")][-2:]
    assert clip_ids == [controller_target_id(mt, 11), controller_target_id(mt, 16)]


def test_save_roundtrip(tmp_path):
    tree = load_als(FIX / "gabarit.als")
    save_als(tree, tmp_path / "x.als")
    raw = gzip.open(tmp_path / "x.als").read()
    assert raw.startswith(b'<?xml version="1.0" encoding="UTF-8"?>')
    root = load_als(tmp_path / "x.als").getroot()
    assert root.get("Creator") == "Ableton Live 12.4.6" and root.get("MinorVersion") == "12.0_12402"


def test_snippets_are_fresh_copies():
    a, b = snippet("audioclip"), snippet("audioclip")
    a.set("Time", "99")
    assert b.get("Time") == "0" and snippet("midiclip").tag == "MidiClip" and snippet("locator").tag == "Locator"
```

- [ ] **Step 3: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_als.py -q`
Expected: FAIL, `ModuleNotFoundError: karaoke.ableton.als`

- [ ] **Step 4: Implement**

`karaoke/src/karaoke/ableton/als.py`:

```python
"""Read/write Ableton .als files (gzip XML) and find the template's parts."""
from __future__ import annotations
import gzip
import importlib.resources
import xml.etree.ElementTree as ET
from pathlib import Path

TRACKS = {"accompagnement": "Accompagnement", "clic": "Clic", "guide_voix": "Guide Voix",
          "guitare": "Guitare", "basse": "Basse", "piano": "Piano", "batterie": "Batterie",
          "back_vocals": "Back Vocals", "video": "Vidéo", "faders": "XR18 faders"}


def load_als(path: Path) -> ET.ElementTree:
    return ET.ElementTree(ET.fromstring(gzip.open(path).read()))


def save_als(tree: ET.ElementTree, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = ET.tostring(tree.getroot(), encoding="unicode")
    with gzip.open(path, "wb") as f:
        f.write(('<?xml version="1.0" encoding="UTF-8"?>\n' + body).encode("utf-8"))


def track(liveset: ET.Element, name: str) -> ET.Element:
    tracks = list(liveset.find("Tracks"))
    for t in tracks:
        if t.find("Name/EffectiveName").get("Value") == name:
            return t
    found = [t.find("Name/EffectiveName").get("Value") for t in tracks]
    raise KeyError(f"piste « {name} » absente du gabarit (pistes : {', '.join(found)})")


def arranger_events(track_el: ET.Element) -> ET.Element:
    seq = track_el.find("DeviceChain/MainSequencer")
    holder = seq.find("Sample") if track_el.tag == "AudioTrack" else seq.find("ClipTimeable")
    return holder.find("ArrangerAutomation/Events")


def snippet(name: str) -> ET.Element:
    text = importlib.resources.files("karaoke.ableton").joinpath(f"snippets/{name}.xml").read_text(encoding="utf-8")
    return ET.fromstring(text)


def controller_target_id(midi_track: ET.Element, cc: int) -> str:
    return midi_track.find(f".//MidiControllers/ControllerTargets.{cc + 2}").get("Id")
```

- [ ] **Step 5: Run tests, commit**

Run: `cd karaoke && uv run pytest -q`. Expected: all pass.

```bash
git add karaoke/tests/fixtures karaoke/src/karaoke/ableton karaoke/tests/test_als.py
git commit -m "karaoke: Ableton fixtures, snippets from Michel's reference set, .als I/O"
```

---

### Task 2: X Air fader law (dB ↔ MIDI CC)

**Files:**
- Create: `karaoke/src/karaoke/xair.py`, `karaoke/tests/test_xair.py`

**Interfaces:**
- Produces:
  - `xair_cc(db: float) -> int`, where `-inf` gives 0;
  - `xair_db(cc: int) -> float`;
  - `FADER_CC = {"clic": [9], "guide_voix": [10], "guitare": [11], "basse": [12], "piano": [13], "batterie": [14], "back_vocals": [15], "accompagnement": [16]}`.
- The law is the X32/X-Air fader taper on a 0–1 float `f`, with `f = cc / 127`:

| Range of `f` | dB |
|---|---|
| f ≥ 0.5 | `f·40 − 30` |
| f ≥ 0.25 | `f·80 − 50` |
| f ≥ 0.0625 | `f·160 − 70` |
| f > 0 | `f·480 − 90` |
| f = 0 | −∞ |

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_xair.py`:

```python
import math
import pytest
from karaoke.xair import xair_cc, xair_db, FADER_CC


def test_unity_and_off():
    assert xair_cc(0.0) == 95 and abs(xair_db(95)) < 0.1
    assert xair_cc(-math.inf) == 0 and xair_db(0) == -math.inf


def test_roundtrip_and_clamp():
    for db in (-50.0, -30.0, -10.0, -3.0, 5.0):
        assert xair_db(xair_cc(db)) == pytest.approx(db, abs=0.7)
    assert xair_cc(20.0) == 127 and xair_cc(-200.0) == 0


def test_fader_map_matches_xr18_plan():
    # XR18 channel n ↔ CC n-1 on MIDI channel 1; AuxLineIn 17-18 ↔ CC 16
    assert FADER_CC["guitare"] == [11] and FADER_CC["batterie"] == [14] and FADER_CC["back_vocals"] == [15]
    assert FADER_CC["accompagnement"] == [16]
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_xair.py -q`
Expected: FAIL, `ModuleNotFoundError: karaoke.xair`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/xair.py`:

```python
"""Behringer X Air fader law (same taper as X32) and the karaoke XR18 fader map.

XR18 MIDI (Behringer chart): MIDI channel 1, CC 0-15 = input faders 1-16, CC 16 = AuxLineIn 17-18.
"""
from __future__ import annotations
import math

# Ableton track -> XR18 fader CCs (XR18 channel n = CC n-1; 17/18 = CC 16)
FADER_CC = {"clic": [9], "guide_voix": [10], "guitare": [11], "basse": [12], "piano": [13],
            "batterie": [14], "back_vocals": [15], "accompagnement": [16]}


def _db_from_f(f: float) -> float:
    if f <= 0:
        return -math.inf
    if f >= 0.5:
        return f * 40 - 30
    if f >= 0.25:
        return f * 80 - 50
    if f >= 0.0625:
        return f * 160 - 70
    return f * 480 - 90


def _f_from_db(db: float) -> float:
    if db == -math.inf or db <= -90:
        return 0.0
    if db >= -10:
        f = (db + 30) / 40
    elif db >= -30:
        f = (db + 50) / 80
    elif db >= -60:
        f = (db + 70) / 160
    else:
        f = (db + 90) / 480
    return min(1.0, max(0.0, f))


def xair_db(cc: int) -> float:
    return _db_from_f(cc / 127)


def xair_cc(db: float) -> int:
    return int(round(_f_from_db(db) * 127))
```

- [ ] **Step 4: Run tests, commit**

Run: `cd karaoke && uv run pytest -q`. Expected: all pass.

```bash
git add karaoke/src/karaoke/xair.py karaoke/tests/test_xair.py
git commit -m "karaoke: X Air fader law and XR18 fader map"
```

---

### Task 2b: Lead / backing vocal split (`vocals_split` step)

Demucs `htdemucs_6s` has a single `vocals` stem. A dedicated karaoke model splits it into the lead singer and the backing vocals. Partly exploratory (like phase-0 Task 1): install the tool, confirm the model name, time it, and get Michel's judgement by ear on the 4 test songs before relying on it.

**Files:**
- Create: `karaoke/tools/vocals/pyproject.toml`, `karaoke/src/karaoke/steps/vocals_split.py`, `karaoke/tests/test_vocals_split.py`
- Modify: `karaoke/src/karaoke/tools.py` (timeout entry), `karaoke/src/karaoke/steps/__init__.py`, `karaoke/tests/test_models_slow.py`

**Interfaces:**
- Consumes: `stems/vocals.wav` (from `separate`), `run_tool`, `tool_timeout`.
- Produces:
  - `VOCALS_SPLIT: Step` named `"vocals_split"`, deps `("ingest", "separate")`;
  - artifacts `stems/lead.wav` and `stems/backing.wav` (float32, same length as `vocals.wav`);
  - result `{"model": str, "lead_rms_db": float, "backing_rms_db": float}`;
  - `pick_outputs(files: list[Path]) -> tuple[Path, Path]` (lead = the file whose name contains `(Vocals)`, backing = the one with `(Instrumental)`; `ValueError` otherwise);
  - `tool_timeout("vocals", d)`, with `_TIMEOUTS["vocals"] = (300.0, 3.0)`.
- Model: `mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt` (run through `audio-separator`). On the vocal stem, its « Vocals » output is the lead and its « Instrumental » output is what is left, i.e. the backing vocals. If `audio-separator --list_models` names it differently, take the karaoke Mel-Band RoFormer listed and record a ruling.

- [ ] **Step 1: Tool env and spike**

`karaoke/tools/vocals/pyproject.toml`:

```toml
[project]
name = "karaoke-vocals"
version = "0.1.0"
requires-python = "==3.11.*"
dependencies = ["audio-separator"]
```

```bash
cd ~/Documents/mp3-pipeline/karaoke/tools/vocals && uv sync
uv run audio-separator --list_models | grep -i -E "karaoke|kara"
K=/Volumes/Hypermnesia/karaoke/travail/005/stems
mkdir -p /tmp/kv && time uv run audio-separator "$K/vocals.wav" \
  --model_filename mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt \
  --output_dir /tmp/kv --output_format WAV
ls /tmp/kv
```

Expected: two WAVs, `…(Vocals)….wav` and `…(Instrumental)….wav`. Record the model name, device (MPS or CPU), wall time for the 197 s song, and output names in `docs/karaoke/phase0-spike.md` (new section). **Michel listens** to both files for 005, 011, 012, 041 before Task 3 relies on them.

- [ ] **Step 2: Write the failing tests**

`karaoke/tests/test_vocals_split.py`:

```python
from pathlib import Path
import numpy as np
import pytest
from karaoke import audio
from karaoke.steps import vocals_split as V
from karaoke.workspace import Workspace
from conftest import tone
from test_manifest import song


def test_pick_outputs():
    files = [Path("vocals_(Instrumental)_m.wav"), Path("vocals_(Vocals)_m.wav")]
    assert V.pick_outputs(files) == (files[1], files[0])
    with pytest.raises(ValueError):
        V.pick_outputs([Path("a.wav")])


def test_step_moves_outputs_into_stems(cfg, monkeypatch):
    ws = Workspace(cfg, song())
    audio.write_wav(ws.stems / "vocals.wav", tone(2.0))
    def fake_tool(tool, args, **kw):
        out = Path(args[args.index("--output_dir") + 1])
        audio.write_wav(out / "vocals_(Vocals)_m.wav", tone(2.0, amp=0.4))
        audio.write_wav(out / "vocals_(Instrumental)_m.wav", tone(2.0, amp=0.1))
        assert kw["timeout"] > 0
    monkeypatch.setattr(V, "run_tool", fake_tool)
    r = V.VOCALS_SPLIT.run(ws, {"ingest": {"duration_s": 2.0}, "separate": {}})
    assert (ws.stems / "lead.wav").exists() and (ws.stems / "backing.wav").exists()
    assert r["lead_rms_db"] > r["backing_rms_db"]
    assert sorted(p.name for p in V.VOCALS_SPLIT.artifacts(ws)) == ["backing.wav", "lead.wav"]
```

- [ ] **Step 3: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_vocals_split.py -q`
Expected: FAIL, `ImportError` (no `vocals_split`).

- [ ] **Step 4: Implement**

`karaoke/src/karaoke/steps/vocals_split.py`:

```python
"""Step `vocals_split` — lead vs backing vocals (karaoke Mel-Band RoFormer via audio-separator).

Inputs:  travail/<id>/stems/vocals.wav (Demucs).
Outputs: stems/lead.wav (lead singer), stems/backing.wav (backing vocals); result {model, lead_rms_db,
         backing_rms_db}. On the vocal stem the model's « Vocals » output is the lead and its
         « Instrumental » output the remainder, i.e. the backing vocals.
"""
from __future__ import annotations
import shutil
from pathlib import Path

import numpy as np

from karaoke import audio
from karaoke.runner import Step
from karaoke.tools import run_tool, tool_timeout
from karaoke.workspace import Workspace

MODEL = "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt"


def pick_outputs(files: list[Path]) -> tuple[Path, Path]:
    lead = [f for f in files if "(Vocals)" in f.name]
    backing = [f for f in files if "(Instrumental)" in f.name]
    if len(lead) != 1 or len(backing) != 1:
        raise ValueError(f"sorties inattendues de audio-separator : {[f.name for f in files]}")
    return lead[0], backing[0]


def _rms_db(path: Path) -> float:
    x, _ = audio.read(path)
    return float(20 * np.log10(np.sqrt((x.astype(np.float64) ** 2).mean()) + 1e-12))


def _run(ws: Workspace, upstream: dict) -> dict:
    tmp = ws.work / "vocals_tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    run_tool("vocals", ["audio-separator", str(ws.stems / "vocals.wav"), "--model_filename", MODEL,
                        "--output_dir", str(tmp), "--output_format", "WAV"],
             timeout=tool_timeout("vocals", upstream["ingest"]["duration_s"]))
    lead, backing = pick_outputs(sorted(tmp.glob("*.wav")))
    shutil.move(str(lead), ws.stems / "lead.wav")
    shutil.move(str(backing), ws.stems / "backing.wav")
    shutil.rmtree(tmp, ignore_errors=True)
    return {"model": MODEL, "lead_rms_db": _rms_db(ws.stems / "lead.wav"),
            "backing_rms_db": _rms_db(ws.stems / "backing.wav")}


VOCALS_SPLIT = Step(name="vocals_split", deps=("ingest", "separate"), key=lambda ws: MODEL, run=_run,
                    artifacts=lambda ws: [ws.stems / "lead.wav", ws.stems / "backing.wav"])
```

In `tools.py` add `"vocals": (300.0, 3.0)` to `_TIMEOUTS`. In `steps/__init__.py` import `VOCALS_SPLIT` and insert it after `BEATS`: `[INGEST, SEPARATE, BEATS, VOCALS_SPLIT, PACKAGE, LYRICS, CHECK, VIDEO]`. In `test_models_slow.py` add `VOCALS_SPLIT` to the real-model run and assert both files exist.

If audio-separator resamples or changes the length, pad or trim `lead`/`backing` to `len(vocals.wav)` in `_run` before saving (the package step requires equal lengths); add that to the test if it happens in the spike.

- [ ] **Step 5: Run tests, commit**

Run: `cd karaoke && uv run pytest -q` (fast), then `KARAOKE_SAMPLE=<a song> uv run pytest -m slow -q`.

```bash
git add karaoke/tools/vocals karaoke/src/karaoke/steps karaoke/src/karaoke/tools.py karaoke/tests docs/karaoke/phase0-spike.md
git commit -m "karaoke: lead/backing vocal split step (karaoke Mel-Band RoFormer)"
```

---

### Task 3: Package v4 (channel files, fader defaults) and parts grouping

**Files:**
- Modify: `karaoke/src/karaoke/steps/package.py`, `karaoke/tests/test_package.py`, `karaoke/src/karaoke/manifest.py`, `karaoke/tests/test_manifest.py`

**Interfaces:**
- Consumes: `xair_cc`, `FADER_CC`.
- Produces:
  - `package.CHANNEL_FILES = {"guitare": "guitar", "basse": "bass", "piano": "piano", "batterie": "drums"}` (file stem → Demucs stem; all mono);
  - PACKAGE deps become `("ingest", "separate", "beats", "vocals_split")`; `guide_voix.flac` = `stems/lead.wav` mono, `back_vocals.flac` = `stems/backing.wav` mono (Task 2b);
  - `package.ROUTED = {"vocals", "guitar", "bass", "piano", "drums"}`.
  - Package result gains `"faders": {"guitare": int, "basse": int, "piano": int, "batterie": int, "back_vocals": int, "accompagnement": int}` (`back_vocals` and `accompagnement` always `xair_cc(0.0)`). The value is 0 if the part's stem is in `retirer`, else `xair_cc(0.0)`; accompaniment is always `xair_cc(0.0)`. It also gains `"live": [...]` (the parts muted by default).
  - `accompagnement.flac` = sum of stems not in `ROUTED` (today: `other`), with the same peak protection as before. `pistes/` keeps all 6 stereo stems.
  - `manifest.group_by_partie(songs) -> dict[str, list[Song]]` keeps first-appearance order of parts and manifest order inside each; an empty `partie` becomes `"sans-partie"`.

- [ ] **Step 1: Write the failing tests**

Replace `test_retirer_changes_accompaniment` and extend the artifacts test in `karaoke/tests/test_package.py`:

```python
def test_accompaniment_excludes_all_routed_parts(cfg):
    ws, up, _ = setup(cfg, retirer=("guitar",))
    r = PACKAGE.run(ws, up)
    acc, _ = audio.read(ws.out / "accompagnement.flac")
    spec = np.abs(np.fft.rfft(acc[200000:244100, 0]))
    freqs = np.fft.rfftfreq(44100, 1 / 44100)
    def level(f):
        return spec[np.argmin(np.abs(freqs - f))]
    # stems: vocals 200, drums 300, bass 400, guitar 500, piano 600, other 700 Hz
    assert level(700) > 100 * max(level(200), level(300), level(400), level(500), level(600))
    for f in ("guitare", "basse", "piano", "batterie", "guide_voix", "back_vocals"):
        assert sf.info(str(ws.out / f"{f}.flac")).channels == 1, f
    assert r["faders"] == {"guitare": 0, "basse": 95, "piano": 95, "batterie": 95, "back_vocals": 95, "accompagnement": 95}
    assert r["live"] == ["guitare"]
```

In `setup()`, also write `ws.stems / "lead.wav"` (tone 800 Hz) and `ws.stems / "backing.wav"` (tone 900 Hz) and add `"vocals_split": {}` to `up`. Add `"guitare.flac", "basse.flac", "piano.flac", "batterie.flac", "back_vocals.flac"` to the expected names in `test_all_files_same_length_and_zero` (both the length loop and the `PACKAGE.artifacts` assertion). Append to `karaoke/tests/test_manifest.py`:

```python
def test_group_by_partie_keeps_order_and_unassigned():
    from karaoke.manifest import group_by_partie
    songs = [song(id="001", partie="B"), song(id="002", partie="A"), song(id="003", partie="B"), song(id="004", partie="")]
    g = group_by_partie(songs)
    assert list(g) == ["B", "A", "sans-partie"]
    assert [s.id for s in g["B"]] == ["001", "003"]
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_package.py tests/test_manifest.py -q`
Expected: FAIL (`faders` missing, `guitare.flac` missing, `group_by_partie` missing).

- [ ] **Step 3: Implement**

In `karaoke/src/karaoke/steps/package.py`: add the constants, import `from karaoke.xair import xair_cc`, and replace the mixing and writing block with:

```python
ROUTED = {"vocals", "guitar", "bass", "piano", "drums"}
CHANNEL_FILES = {"guitare": "guitar", "basse": "bass", "piano": "piano", "batterie": "drums"}   # all mono
```

```python
    kept = [stems[s] for s in STEMS if s not in ROUTED]
    acc = np.sum(kept, axis=0) if kept else np.zeros_like(x)
    peak = float(np.abs(acc).max()) if acc.size else 0.0
    gain = 0.999 / peak if peak > 0.999 else 1.0
    out = ws.out
    (out / "pistes").mkdir(parents=True, exist_ok=True)
    audio.write_flac(out / "accompagnement.flac", _pad(acc * gain, pad, total), sr)
    lead, _ = audio.read(ws.stems / "lead.wav")
    backing, _ = audio.read(ws.stems / "backing.wav")
    audio.write_flac(out / "guide_voix.flac", _pad(lead.mean(axis=1), pad, total), sr)
    audio.write_flac(out / "back_vocals.flac", _pad(backing.mean(axis=1), pad, total), sr)
    for name, stem in CHANNEL_FILES.items():
        audio.write_flac(out / f"{name}.flac", _pad(stems[stem].mean(axis=1), pad, total), sr)
    for s in STEMS:
        audio.write_flac(out / "pistes" / f"{s}.flac", _pad(stems[s], pad, total), sr)
```

In the returned dict, replace `"removed": removed` with:

```python
            "live": [n for n, stem in CHANNEL_FILES.items() if stem in ws.song.retirer],
            "faders": {**{n: (0 if stem in ws.song.retirer else xair_cc(0.0)) for n, stem in CHANNEL_FILES.items()},
                       "back_vocals": xair_cc(0.0), "accompagnement": xair_cc(0.0)},
```

Delete the now-unused `removed = …` line. Add the five channel files (`guitare, basse, piano, batterie, back_vocals`) to `_artifacts`, and `"vocals_split"` to the PACKAGE deps. Set `version="4"` with the comment `# 4: channel files for the XR18 plan, accompaniment = other, fader defaults`.

Update `karaoke/src/karaoke/report.py` if it reads `removed` (it doesn't; check with `grep -n removed karaoke/src`).

In `karaoke/src/karaoke/manifest.py`:

```python
def group_by_partie(songs: list[Song]) -> dict[str, list[Song]]:
    """Songs per part of the evening, parts in first-appearance order; empty partie → « sans-partie »."""
    groups: dict[str, list[Song]] = {}
    for s in songs:
        groups.setdefault(s.partie or "sans-partie", []).append(s)
    return groups
```

- [ ] **Step 4: Run tests, commit**

Run: `cd karaoke && uv run pytest -q`. Expected: all pass (update `test_temps_csv` / others only if they referenced `removed`).

```bash
git add karaoke/src/karaoke/steps/package.py karaoke/src/karaoke/manifest.py karaoke/tests
git commit -m "karaoke: package v4 (XR18 channel files, accompaniment = other, fader defaults)"
```

---

### Task 4: Clip and locator builders

**Files:**
- Create: `karaoke/src/karaoke/ableton/clips.py`, `karaoke/tests/test_clips.py`

**Interfaces:**
- Consumes: `snippet()`.
- Produces (each returns a new `ET.Element` built from the snippet; times in **beats** = seconds × 2):
  - `@dataclass MediaInfo(path: Path, rel_path: str, frames: int, seconds: float, size: int, mtime: int)`;
  - `media_info(path: Path, set_dir: Path) -> MediaInfo` (frames from soundfile for FLAC; for MP4, `seconds` from ffprobe `format=duration`, `frames = int(seconds × 44100)`);
  - `audio_clip(info, start_s, name, color) -> Element`;
  - `video_clip(info, start_s, name) -> Element`;
  - `midi_clip(start_s, length_s, values: dict[str, int], target_ids: dict[int, str], fader_cc: dict[str, list[int]]) -> Element`;
  - `locator(time_s, name, id_) -> Element`.
- The fields set on audio and video clips (everything else is kept from the snippet):
  - `Time`, `CurrentStart` = start beats; `CurrentEnd` = start + seconds × 2;
  - `Loop/LoopEnd`, `Loop/HiddenLoopEnd` = seconds;
  - `Loop/OutMarker` = seconds × 2 for audio, seconds for video (as Live wrote it);
  - `Name`, `Color`, `ScrollerTimePreserver/RightTime` = seconds;
  - `FileRef/RelativePath`, `Path`, `OriginalFileSize`, `OriginalCrc` = `0`;
  - `LastModDate`, `DefaultDuration` = frames, `DefaultSampleRate` = 44100.
- MIDI clip:
  - `Time`, `CurrentStart` = start, `CurrentEnd` = start + length;
  - `Loop/LoopEnd`, `HiddenLoopEnd`, `OutMarker` = length in beats;
  - one `ClipEnvelope` per CC (Id 0…n), `PointeeId` = `target_ids[cc]`;
  - events `FloatEvent Id=0 Time=-63072000 Value=v` and `Id=1 Time=0 Value=v` (clip-relative time).

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_clips.py`:

```python
from pathlib import Path
import xml.etree.ElementTree as ET
import pytest
from karaoke.ableton.clips import MediaInfo, audio_clip, video_clip, midi_clip, locator
from karaoke.ableton.als import load_als, track, controller_target_id

FIX = Path(__file__).parent / "fixtures" / "ableton"


def ref_clip(track_name):
    ls = load_als(FIX / "reference.als").getroot().find("LiveSet")
    t = track(ls, track_name)
    return t.find(".//ArrangerAutomation/Events/*")


def v(el, path):
    return el.find(path).get("Value")


def test_audio_clip_reproduces_reference_values():
    ref = ref_clip("Accompagnement")
    info = MediaInfo(Path("/Volumes/Hypermnesia/karaoke/sortie/005_loic-nottet_danser/accompagnement.flac"),
                     "../../sortie/005_loic-nottet_danser/accompagnement.flac", 8876810, 8876810 / 44100,
                     32304640, 1791829791)
    c = audio_clip(info, 0.0, "accompagnement", 9)
    for p in ("CurrentStart", "CurrentEnd", "Loop/LoopEnd", "Loop/OutMarker", "Loop/HiddenLoopEnd",
              "SampleRef/DefaultDuration", "SampleRef/LastModDate"):
        assert float(v(c, p)) == pytest.approx(float(v(ref, p)), abs=1e-9), p
    for p in ("Name", "IsWarped", "SampleRef/FileRef/Path", "SampleRef/FileRef/RelativePath"):
        assert v(c, p) == v(ref, p), p


def test_audio_clip_at_later_position():
    info = MediaInfo(Path("/x/a.flac"), "../a.flac", 441000, 10.0, 1, 1)
    c = audio_clip(info, 60.0, "a", 1)
    assert (c.get("Time"), v(c, "CurrentStart"), v(c, "CurrentEnd")) == ("120", "120", "140")
    assert v(c, "Loop/LoopEnd") == "10"


def test_video_clip_outmarker_in_seconds():
    info = MediaInfo(Path("/x/p.mp4"), "../p.mp4", 8876448, 201.2364625850340, 2765786, 1)
    c = video_clip(info, 0.0, "paroles")
    assert float(v(c, "Loop/OutMarker")) == 201.236462585034 and float(v(c, "CurrentEnd")) == 402.472925170068


def test_midi_clip_targets_and_values():
    ls = load_als(FIX / "gabarit.als").getroot().find("LiveSet")
    mt = track(ls, "XR18 faders")
    ids = {cc: controller_target_id(mt, cc) for cc in (11, 12, 13, 14, 15, 16)}
    c = midi_clip(10.0, 0.5, {"guitare": 0, "batterie": 95, "accompagnement": 95}, ids,
                  {"guitare": [11], "batterie": [14, 15], "accompagnement": [16]})   # one part on two CCs still works
    envs = c.findall("Envelopes/Envelopes/ClipEnvelope")
    targets = {e.find("EnvelopeTarget/PointeeId").get("Value"):
               [ev.get("Value") for ev in e.findall("Automation/Events/FloatEvent")] for e in envs}
    assert targets == {ids[11]: ["0", "0"], ids[14]: ["95", "95"], ids[15]: ["95", "95"], ids[16]: ["95", "95"]}
    assert (c.get("Time"), v(c, "CurrentEnd")) == ("20", "21")


def test_locator_escapes_names():
    loc = locator(30.0, "082 Il est cinq heures, Paris s'éveille & <co>", 3)
    assert loc.get("Id") == "3" and v(loc, "Time") == "60"
    assert ET.fromstring(ET.tostring(loc)).find("Name").get("Value") == "082 Il est cinq heures, Paris s'éveille & <co>"
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_clips.py -q`
Expected: FAIL, `ModuleNotFoundError: karaoke.ableton.clips`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/ableton/clips.py`:

```python
"""Arrangement clips and locators, built from Michel's reference snippets (Live 12.4.6).

Arrangement time is in beats at the template's 120 BPM: beats = seconds × 2. Clips are
unwarped, so their loop fields are in seconds (as Live writes them).
"""
from __future__ import annotations
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
import xml.etree.ElementTree as ET

import soundfile as sf

from karaoke.ableton.als import snippet

BEATS_PER_SECOND = 2.0      # template tempo 120 BPM
DEFAULT_EVENT_TIME = "-63072000"


def _num(x: float) -> str:
    return repr(float(x)).rstrip("0").rstrip(".") if float(x) != int(x) else str(int(x))


def _set(el: ET.Element, path: str, value) -> None:
    el.find(path).set("Value", value if isinstance(value, str) else _num(value))


@dataclass(frozen=True)
class MediaInfo:
    path: Path
    rel_path: str
    frames: int
    seconds: float
    size: int
    mtime: int


def media_info(path: Path, set_dir: Path) -> MediaInfo:
    st = path.stat()
    if path.suffix.lower() == ".mp4":
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "default=nw=1:nk=1", str(path)], capture_output=True, text=True, check=True)
        seconds = float(out.stdout.strip())
        frames = int(seconds * 44100)
    else:
        info = sf.info(str(path))
        frames, seconds = info.frames, info.frames / info.samplerate
    return MediaInfo(path, os.path.relpath(path, set_dir), frames, seconds, st.st_size, int(st.st_mtime))


def _media_clip(kind: str, info: MediaInfo, start_s: float, name: str, color: int | None) -> ET.Element:
    c = snippet(kind)
    start = start_s * BEATS_PER_SECOND
    c.set("Time", _num(start))
    _set(c, "CurrentStart", start)
    _set(c, "CurrentEnd", start + info.seconds * BEATS_PER_SECOND)
    _set(c, "Loop/LoopEnd", info.seconds)
    _set(c, "Loop/HiddenLoopEnd", info.seconds)
    _set(c, "Loop/OutMarker", info.seconds * BEATS_PER_SECOND if kind == "audioclip" else info.seconds)
    _set(c, "Name", name)
    if color is not None:
        _set(c, "Color", str(color))
    _set(c, "ScrollerTimePreserver/RightTime", info.seconds)
    fr = c.find("SampleRef/FileRef")
    _set(fr, "RelativePath", info.rel_path)
    _set(fr, "Path", str(info.path))
    _set(fr, "OriginalFileSize", str(info.size))
    _set(fr, "OriginalCrc", "0")
    _set(c, "SampleRef/LastModDate", str(info.mtime))
    _set(c, "SampleRef/DefaultDuration", str(info.frames))
    _set(c, "SampleRef/DefaultSampleRate", "44100")
    return c


def audio_clip(info: MediaInfo, start_s: float, name: str, color: int) -> ET.Element:
    return _media_clip("audioclip", info, start_s, name, color)


def video_clip(info: MediaInfo, start_s: float, name: str) -> ET.Element:
    return _media_clip("videoclip", info, start_s, name, None)


def midi_clip(start_s: float, length_s: float, values: dict[str, int], target_ids: dict[int, str],
              fader_cc: dict[str, list[int]]) -> ET.Element:
    c = snippet("midiclip")
    start, length = start_s * BEATS_PER_SECOND, length_s * BEATS_PER_SECOND
    c.set("Time", _num(start))
    _set(c, "CurrentStart", start)
    _set(c, "CurrentEnd", start + length)
    for p in ("Loop/LoopEnd", "Loop/HiddenLoopEnd", "Loop/OutMarker"):
        _set(c, p, length)
    envs = c.find("Envelopes/Envelopes")
    template = envs.find("ClipEnvelope")
    for e in list(envs):
        envs.remove(e)
    n = 0
    for part, value in values.items():
        for cc in fader_cc[part]:
            e = ET.fromstring(ET.tostring(template))
            e.set("Id", str(n))
            e.find("EnvelopeTarget/PointeeId").set("Value", target_ids[cc])
            events = e.find("Automation/Events")
            for ev in list(events):
                events.remove(ev)
            ET.SubElement(events, "FloatEvent", Id="0", Time=DEFAULT_EVENT_TIME, Value=str(value))
            ET.SubElement(events, "FloatEvent", Id="1", Time="0", Value=str(value))
            envs.append(e)
            n += 1
    return c


def locator(time_s: float, name: str, id_: int) -> ET.Element:
    loc = snippet("locator")
    loc.set("Id", str(id_))
    _set(loc, "Time", time_s * BEATS_PER_SECOND)
    _set(loc, "Name", name)
    return loc
```

- [ ] **Step 4: Run tests, commit**

Run: `cd karaoke && uv run pytest -q`. Expected: all pass. If `test_audio_clip_reproduces_reference_values` fails on number formatting only (e.g. `402.57641733266735` vs `402.576417332667`), compare as floats; Live parses either.

```bash
git add karaoke/src/karaoke/ableton/clips.py karaoke/tests/test_clips.py
git commit -m "karaoke: Ableton clip and locator builders from reference snippets"
```

---

### Task 5: Set builder

**Files:**
- Create: `karaoke/src/karaoke/ableton/build.py`, `karaoke/tests/test_build.py`

**Interfaces:**
- Consumes: Tasks 1, 2, 4; package result (`pad_s`, `total_s`, `faders`).
- Produces:
  - `@dataclass SongEntry(id: str, titre: str, folder: Path, faders: dict[str, int])`;
  - `SetError(ValueError)`;
  - `build_set(template: Path, songs: list[SongEntry], out: Path, gap_s: float = 4.0) -> dict`. It loads the template (fresh each call) and checks every required file exists. Required: `accompagnement.flac, clic.flac, guide_voix.flac, guitare.flac, basse.flac, piano.flac, batterie.flac, back_vocals.flac, paroles.mp4`; any missing raises `SetError` listing song id and file names. For each song, at `t = Σ(previous durations + gap)`, it appends to each track the audio clip of its file, the video clip and a 0.5 s MIDI clip with `faders`, and adds one locator `"<id> <titre>"`. Clip names = file stem; colors kept from the snippet. Locator Ids 0…n−1. It writes `out` and returns `{"songs": n, "duration_s": float, "locators": [names]}`.

- [ ] **Step 1: Write the failing tests**

`karaoke/tests/test_build.py`:

```python
from pathlib import Path
import subprocess
import numpy as np
import pytest
from karaoke import audio
from karaoke.ableton.als import load_als, track, arranger_events
from karaoke.ableton.build import SongEntry, SetError, build_set

FIX = Path(__file__).parent / "fixtures" / "ableton"
FILES = ["accompagnement", "clic", "guide_voix", "guitare", "basse", "piano", "batterie", "back_vocals"]


def make_song(root: Path, sid: str, seconds: float) -> SongEntry:
    folder = root / "sortie" / f"{sid}_x"
    for f in FILES:
        audio.write_flac(folder / f"{f}.flac", np.zeros((int(seconds * 44100), 2 if f == "accompagnement" else 1), np.float32))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=black:s=320x180:d={seconds}",
                    "-c:v", "libx264", str(folder / "paroles.mp4")], check=True)
    return SongEntry(sid, f"Titre {sid} & co", folder,
                     {"guitare": 0, "basse": 95, "piano": 95, "batterie": 95, "back_vocals": 95, "accompagnement": 95})


def test_two_songs_layout(tmp_path):
    songs = [make_song(tmp_path, "001", 10.0), make_song(tmp_path, "002", 6.0)]
    out = tmp_path / "sets" / "A.als"
    r = build_set(FIX / "gabarit.als", songs, out)
    ls = load_als(out).getroot().find("LiveSet")
    acc = arranger_events(track(ls, "Accompagnement"))
    assert [c.get("Time") for c in acc] == ["0", "28"]            # song 2 at (10 s + 4 s gap) × 2 beats
    assert [l.find("Name").get("Value") for l in ls.findall("Locators/Locators/Locator")] == ["001 Titre 001 & co", "002 Titre 002 & co"]
    assert len(arranger_events(track(ls, "Vidéo"))) == 2 and len(arranger_events(track(ls, "XR18 faders"))) == 2
    assert r["songs"] == 2 and r["duration_s"] == pytest.approx(20.0, abs=0.1)
    path = acc[1].find("SampleRef/FileRef/RelativePath").get("Value")
    assert path == "../sortie/002_x/accompagnement.flac"


def test_template_untouched_and_rebuild_is_clean(tmp_path):
    before = (FIX / "gabarit.als").read_bytes()
    songs = [make_song(tmp_path, "001", 4.0)]
    out = tmp_path / "sets" / "A.als"
    build_set(FIX / "gabarit.als", songs, out)
    build_set(FIX / "gabarit.als", songs, out)
    ls = load_als(out).getroot().find("LiveSet")
    assert len(arranger_events(track(ls, "Accompagnement"))) == 1
    assert (FIX / "gabarit.als").read_bytes() == before


def test_missing_file_is_refused(tmp_path):
    s = make_song(tmp_path, "001", 4.0)
    (s.folder / "guitare.flac").unlink()
    with pytest.raises(SetError, match="001.*guitare.flac"):
        build_set(FIX / "gabarit.als", [s], tmp_path / "sets" / "A.als")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_build.py -q`
Expected: FAIL, `ModuleNotFoundError: karaoke.ableton.build`

- [ ] **Step 3: Implement**

`karaoke/src/karaoke/ableton/build.py`:

```python
"""Assemble one Ableton set from the template: songs in sequence, one locator each,
XR18 fader defaults sent by a MIDI clip at each song start."""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path

from karaoke.ableton.als import TRACKS, arranger_events, controller_target_id, load_als, save_als, track
from karaoke.ableton.clips import audio_clip, locator, media_info, midi_clip, video_clip
from karaoke.xair import FADER_CC

AUDIO_FILES = ["accompagnement", "clic", "guide_voix", "guitare", "basse", "piano", "batterie", "back_vocals"]
FADER_CLIP_S = 0.5


class SetError(ValueError):
    pass


@dataclass(frozen=True)
class SongEntry:
    id: str
    titre: str
    folder: Path
    faders: dict[str, int]


def _check(songs: list[SongEntry]) -> None:
    problems = []
    for s in songs:
        missing = [f"{n}.flac" for n in AUDIO_FILES if not (s.folder / f"{n}.flac").exists()]
        if not (s.folder / "paroles.mp4").exists():
            missing.append("paroles.mp4")
        if missing:
            problems.append(f"{s.id} ({s.folder.name}) : manque {', '.join(missing)}")
    if problems:
        raise SetError("Fichiers manquants, relancer « karaoke traiter » :\n" + "\n".join(problems))


def build_set(template: Path, songs: list[SongEntry], out: Path, gap_s: float = 4.0) -> dict:
    _check(songs)
    tree = load_als(template)
    ls = tree.getroot().find("LiveSet")
    set_dir = out.parent
    events = {k: arranger_events(track(ls, name)) for k, name in TRACKS.items()}
    faders_track = track(ls, TRACKS["faders"])
    target_ids = {cc: controller_target_id(faders_track, cc) for ccs in FADER_CC.values() for cc in ccs}
    loc_list = ls.find("Locators/Locators")
    t, names = 0.0, []
    for i, s in enumerate(songs):
        infos = {n: media_info(s.folder / f"{n}.flac", set_dir) for n in AUDIO_FILES}
        video = media_info(s.folder / "paroles.mp4", set_dir)
        for n, info in infos.items():
            events[n].append(audio_clip(info, t, n, 9))
        events["video"].append(video_clip(video, t, "paroles"))
        events["faders"].append(midi_clip(t, FADER_CLIP_S, s.faders, target_ids, FADER_CC))
        name = f"{s.id} {s.titre}"
        loc_list.append(locator(t, name, i))
        names.append(name)
        t += infos["accompagnement"].seconds + gap_s
    save_als(tree, out)
    return {"songs": len(songs), "duration_s": max(0.0, t - gap_s), "locators": names}
```

Expected `duration_s` in the test: 10 + 4 + 6 = 20.

- [ ] **Step 4: Run tests, commit**

Run: `cd karaoke && uv run pytest -q`. Expected: all pass.

```bash
git add karaoke/src/karaoke/ableton/build.py karaoke/tests/test_build.py
git commit -m "karaoke: Ableton set builder (songs in sequence, locators, XR18 fader clips)"
```

---

### Task 6: `karaoke sets` command

**Files:**
- Modify: `karaoke/src/karaoke/cli.py`, `karaoke/src/karaoke/config.py`
- Test: `karaoke/tests/test_build.py` (append)

**Interfaces:**
- Consumes: `read_manifest`, `group_by_partie`, `Workspace`, package markers (`ws.read_marker("package")["result"]["faders"]`), `build_set`.
- Produces:
  - `Config.gabarit` = `home/"gabarit"/"gabarit Project"/"gabarit.als"`, overridable with env `KARAOKE_GABARIT`;
  - `Config.sets` = `home/"sets"`;
  - CLI `karaoke sets [--partie NAME]` writes `sets/<slug(partie)>.als` per part. It prints songs per set and total duration. It exits 1 with the `SetError` message if files are missing, or if a song has no package marker (« pas encore traité »).

- [ ] **Step 1: Write the failing test**

Append to `karaoke/tests/test_build.py`:

```python
def test_cli_sets_writes_one_set_per_partie(tmp_path, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    from karaoke.config import Config
    from karaoke.manifest import write_manifest
    from karaoke.workspace import Workspace
    from test_manifest import song
    import shutil
    home = tmp_path / "home"
    monkeypatch.setenv("KARAOKE_HOME", str(home))
    monkeypatch.setenv("KARAOKE_GABARIT", str(FIX / "gabarit.als"))
    cfg = Config.load(); cfg.ensure_dirs()
    songs = [song(id="001", partie="Apéro"), song(id="002", partie="Dîner"), song(id="003", partie="Apéro")]
    write_manifest(cfg.manifest, songs)
    for s in songs:
        ws = Workspace(cfg, s)
        src = make_song(tmp_path / "src", s.id, 4.0)
        shutil.copytree(src.folder, ws.out)
        ws.write_marker("package", {"key": "k", "output_hash": "h", "seconds": 1,
                                    "result": {"faders": src.faders, "pad_s": 0.0, "total_s": 4.0}})
    r = CliRunner().invoke(cli.app, ["sets"])
    assert r.exit_code == 0, r.output
    assert sorted(p.name for p in cfg.sets.glob("*.als")) == ["apero.als", "diner.als"]
    ls = load_als(cfg.sets / "apero.als").getroot().find("LiveSet")
    assert [l.find("Name").get("Value")[:3] for l in ls.findall("Locators/Locators/Locator")] == ["001", "003"]
```

- [ ] **Step 2: Run to verify failure**

Run: `cd karaoke && uv run pytest tests/test_build.py -q -k cli`
Expected: FAIL (no `sets` command, no `Config.gabarit`).

- [ ] **Step 3: Implement**

In `config.py` add:

```python
    @property
    def gabarit(self) -> Path:
        env = os.environ.get("KARAOKE_GABARIT")
        return Path(env) if env else self.home / "gabarit" / "gabarit Project" / "gabarit.als"

    @property
    def sets(self) -> Path:
        return self.home / "sets"
```

In `cli.py` add (imports at top: `from karaoke.ableton.build import SetError, SongEntry, build_set`, `from karaoke.manifest import group_by_partie`, `from karaoke.workspace import slug`):

```python
@app.command()
def sets(partie: str = typer.Option(None, help="Ne générer que cette partie")) -> None:
    """Génère un set Ableton (.als) par partie de soirée, à partir du gabarit."""
    cfg = Config.load()
    groups = group_by_partie(read_manifest(cfg.manifest))
    for name, songs in groups.items():
        if partie and name != partie:
            continue
        entries, missing = [], []
        for s in songs:
            ws = Workspace(cfg, s)
            marker = ws.read_marker("package")
            if not marker or "faders" not in marker["result"]:
                missing.append(f"{s.id} {s.titre}")
                continue
            entries.append(SongEntry(s.id, s.titre, ws.out, marker["result"]["faders"]))
        if missing:
            typer.echo(f"[{name}] pas encore traité (lancer « karaoke traiter ») : " + " ; ".join(missing), err=True)
            raise typer.Exit(1)
        out = cfg.sets / f"{slug(name)}.als"
        try:
            r = build_set(cfg.gabarit, entries, out)
        except SetError as e:
            typer.echo(f"[{name}] {e}", err=True)
            raise typer.Exit(1)
        typer.echo(f"{out} : {r['songs']} morceaux, {r['duration_s'] / 60:.0f} min")
```

- [ ] **Step 4: Run tests, commit**

Run: `cd karaoke && uv run pytest -q`. Expected: all pass.

```bash
git add karaoke/src/karaoke/cli.py karaoke/src/karaoke/config.py karaoke/tests/test_build.py
git commit -m "karaoke: 'karaoke sets' generates one Ableton set per part of the evening"
```

---

### Task 7: Real run and validation in Live (with Michel)

**Files:**
- Create: `docs/karaoke/ableton-validation.md`
- Modify: `karaoke/README.md` (add the `sets` command and the Live checklist)

- [ ] **Step 1: Reprocess the 4 phase-0 songs and generate a test set**

```bash
export KARAOKE_HOME=/Volumes/Hypermnesia/karaoke
cd ~/Documents/mp3-pipeline/karaoke
# give the 4 phase-0 songs a partie, e.g. "test", in manifeste.csv, then:
uv run karaoke traiter          # package v4 + video rerun; separation reused
uv run karaoke sets --partie test
```

Expected: `sets/test.als`, 4 songs, about 14 min. Every song folder now holds `guitare.flac`, `basse.flac`, `piano.flac`, `batterie.flac`, `back_vocals.flac`, and `guide_voix.flac` now contains the lead vocals only.

- [ ] **Step 2: Michel opens the set in Live 12.4.6 and checks (record each answer in `ableton-validation.md`)**

1. The set opens with no error and no « media files missing » prompt. (This tests `OriginalCrc=0`. If Live complains, record the exact message: the fallback is to leave `OriginalCrc` out or let Live rescan, a follow-up ruling.)
2. 4 locators in the right order and the clips aligned, with each song's video under its audio.
3. Play from each locator: sound on XR18 channels 10–18 as per the plan, accompaniment on 17–18.
4. At each song start the XR18 faders jump in X Air: parts in `retirer` at −∞; the others, Back Vocals (16) and 17–18 at about 0 dB.
5. Lead/backing split by ear: channel 11 has the lead singer only, channel 16 the backing vocals, no lead left in 16 (record per song).
6. The video window shows the lyrics in sync with the voice; full screen on the projector (spec phase-0 criterion).
7. Video sync holds across all 4 songs (spec: « tenue de la synchronisation vidéo sur un set de 15 morceaux »; repeat with a 15-song set once the full batch exists).

- [ ] **Step 3: Commit**

```bash
git add docs/karaoke/ableton-validation.md karaoke/README.md
git commit -m "karaoke: Ableton set validation notes and usage"
```

---

## Self-review notes

- **Spec coverage:**
  - step 8 (one `.als` per part, songs in sequence, a locator per title, XR18 routing): Tasks 3–6;
  - routing is inherited from Michel's template (never touched);
  - the decisions document (parts extracted, faders at zero for live parts, MIDI fader control): Tasks 2–3 and 5;
  - the phase-0 deferred criteria (set opens, right channels, full-screen video, sync over 15 songs): Task 7.
- **Known risk, carried to Task 7:** `OriginalCrc` is Live's private checksum. The plan writes `0`, and Michel's first opening tells us whether Live accepts it.
- **Decision to confirm with Michel:** click and guide vocal faders are not driven by the set; he sets them once on the console.
- **Type consistency:**
  - `faders` keys `guitare/basse/piano/batterie/back_vocals/accompagnement` are used identically in package, `FADER_CC`, `midi_clip`, `SongEntry` and the tests;
  - beats = seconds × 2 everywhere via `BEATS_PER_SECOND`.

---

## Part 2 (requested by Michel, 2026-10-13, after the Live validation)

Michel's decisions:
- Syllable-by-syllable colour (step, not a smooth wipe).
- Word timing within ±0.5 s counts as correct.
- A **4-3-2-1** countdown on the last 4 beats before a line that follows more than 8 beats of silence.
- Separation chain: RoFormer vocals → Demucs 6s on the instrumental → karaoke split on the RoFormer vocals.
- **One Live set per song** with an automatic stop at the song's end.

He asked for these to be implemented directly. Each task follows the same rules as above: TDD, a commit per task, ledger rulings.

### Task 8: Separation v2 (RoFormer vocals + Demucs on the instrumental)
- `separate` step, version 2:
  1. `audio-separator` with `vocals_mel_band_roformer.ckpt` (vocals score 12.6; spike: 2 min 33 s for 197 s at overlap 2) on `input.wav` gives `(vocals)` and `(other)`;
  2. Demucs `htdemucs_6s` on the `(other)` instrumental gives drums, bass, guitar, piano, other;
  3. Demucs's residual `vocals` from the instrumental is kept as `stems/residu_voix.wav` and excluded from every mix.
- `stems/vocals.wav` = the RoFormer vocals; the other 5 stems come from Demucs. `vocals_split` runs on these vocals, unchanged.
- `pick_outputs` matches stem labels case-insensitively: the RoFormer writes `(vocals)/(other)`, the karaoke model `(Vocals)/(Instrumental)`.

### Task 9: Word and syllable timing
- `align_tool` v2:
  - the job may carry `segments` ([start, end] per line) so each line is aligned within its own window (used for lines already synced by LRCLIB or a user LRC);
  - it returns `words` per line `[{w, s, e}]` in addition to `starts`/`scores`.
- `lyrics` step v2:
  - aligns every song that has lyrics;
  - keeps the line start from LRCLIB/LRC when present;
  - attaches `words: [{text, start, end, syllables: [{text, start}]}]` to each line.
- Syllables come from `pyphen` (`fr_FR` / `en_US`). Each syllable's start is spread over its word's duration in proportion to its letters. Words without timing are interpolated between the line start and the next line.
- `check` step v2: a word is in time if vocal activity starts within **±0.5 s** of its start. `word_rate` is added to the result, and the report alerts when `word_rate < 0.9`.

### Task 10: Video v3 (syllable colour, beat countdown)
- The video step depends on `beats` too. Beats in output time = `beats + pad_s`.
- Timeline states:
  - for each line, one state per syllable start (`lit` = number of syllables already sung);
  - the frame draws the current line with sung syllables in yellow and the rest in white, plus the next line in grey.
- Gaps: if more than 8 beats separate the end of singing from the next line (or the title from the first line), the last 4 beats before the line show `4`, `3`, `2`, `1` (replaces the 8-second / 3-dot rule).

### Task 11: One set per song, automatic stop
- `karaoke sets` writes `sets/<partie>/<id> <titre>.als`, one song per set.
- Automatic stop: if the template has a MIDI track **« Auto stop »** (output: IAC Driver bus), a MIDI clip at the song's end (`total_s + 0.5 s`) sends **CC 119 = 127**. Live's Stop button is MIDI-mapped once by Michel to IAC CC 119.
- New command `karaoke apprendre-stop`: sends CC 119 on the IAC bus every 0.5 s for 20 s, so Michel can map the Stop button in MIDI Map mode.
- Michel's one-time setup:
  1. turn on the IAC Driver in Audio MIDI Setup;
  2. add the « Auto stop » MIDI track to the template, output IAC Driver Bus 1;
  3. in Live's MIDI settings, set the IAC input « Remote » to On;
  4. map Stop to CC 119.

### Task 12: Real run and validation
- Reprocess the 4 test songs (new separation, alignment, video), generate 4 song sets, and Michel checks:
  - the auto stop;
  - the syllable colours and the countdown;
  - the separation by ear (optional).
