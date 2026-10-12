import os
from pathlib import Path
import pytest
from karaoke.runner import run_song
from karaoke.steps.ingest import INGEST
from karaoke.steps.separate import SEPARATE
from karaoke.steps.beats import BEATS
from karaoke.workspace import Workspace
from test_manifest import song

SAMPLE = Path(os.environ.get("KARAOKE_SAMPLE", "/nonexistent"))


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
