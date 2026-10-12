from pathlib import Path
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
    seen = {}
    def fake_tool(tool, args, **kw):
        seen.update(tool=tool, args=args, **kw)
        out = Path(args[args.index("--output_dir") + 1])
        audio.write_wav(out / "vocals_(Vocals)_m.wav", tone(2.0, amp=0.4))
        audio.write_wav(out / "vocals_(Instrumental)_m.wav", tone(2.0, amp=0.1))
    monkeypatch.setattr(V, "run_tool", fake_tool)
    r = V.VOCALS_SPLIT.run(ws, {"ingest": {"duration_s": 2.0}, "separate": {}})
    assert (ws.stems / "lead.wav").exists() and (ws.stems / "backing.wav").exists()
    assert r["lead_rms_db"] > r["backing_rms_db"]
    assert sorted(p.name for p in V.VOCALS_SPLIT.artifacts(ws)) == ["backing.wav", "lead.wav"]
    # measured in the spike: overlap 2 halves the time (overlap 8 would not fit one night)
    assert seen["tool"] == "vocals" and seen["args"][seen["args"].index("--mdxc_overlap") + 1] == "2"
    assert seen["timeout"] > 0 and "--model_file_dir" in seen["args"]
