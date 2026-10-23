import os
from pathlib import Path
import pytest
from karaoke.runner import run_song
from karaoke.steps.ingest import INGEST
from karaoke.steps.separate import SEPARATE
from karaoke.steps.beats import BEATS
from karaoke.steps.vocals_split import VOCALS_SPLIT
from karaoke.workspace import Workspace
from test_manifest import song

SAMPLE = Path(os.environ.get("KARAOKE_SAMPLE", "/nonexistent"))


@pytest.mark.slow
@pytest.mark.skipif(not SAMPLE.is_file(), reason="set KARAOKE_SAMPLE to a real song file")
def test_separate_and_beats_on_real_song(cfg):
    ws = Workspace(cfg, song(fichier=SAMPLE, duree_ref_s=0))
    r = run_song(ws, [INGEST, SEPARATE, BEATS, VOCALS_SPLIT])
    assert {v["status"] for v in r.values()} == {"fait"}, r
    assert {"vocals", "drums", "bass", "guitar", "piano", "other", "lead", "backing"} <= {
        p.stem for p in ws.stems.glob("*.wav")}
    assert (ws.stems / "lead.wav").exists() and (ws.stems / "backing.wav").exists()
    beats = r["beats"]["result"]["beats"]
    assert 60 < 60 * len(beats) / r["ingest"]["result"]["duration_s"] < 220   # plausible BPM


@pytest.mark.slow
@pytest.mark.skipif(not SAMPLE.is_file(), reason="set KARAOKE_SAMPLE to a real song file")
@pytest.mark.parametrize("project,script", [("chords_dl", "jiang_tool.py"), ("chords_dl", "btc_tool.py"),
                                            ("chords_ace", "ace_tool.py")])
def test_chord_engine_on_a_real_clip(tmp_path, project, script):
    import json, subprocess
    from karaoke.chords import SYMBOL, symbol
    from karaoke.tools import TOOLS_DIR, run_tool
    clip = tmp_path / "clip.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "30", "-t", "20", "-i", str(SAMPLE), str(clip)], check=True)
    run_tool(project, ["python", str(TOOLS_DIR / project / script), str(clip), str(tmp_path / "o.json")], timeout=3600)
    segs = json.loads((tmp_path / "o.json").read_text())["segments"]
    assert segs and all(SYMBOL.match(symbol(l)) for _, _, l in segs)
