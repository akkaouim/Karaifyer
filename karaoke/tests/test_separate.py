from pathlib import Path
import numpy as np
import pytest
from karaoke import audio
from karaoke.steps import separate as S
from karaoke.tools import pick_stem
from karaoke.workspace import Workspace
from conftest import tone
from test_manifest import song


def test_pick_stem_is_case_insensitive():
    files = [Path("in_(vocals)_m.wav"), Path("in_(other)_m.wav"), Path("v_(Instrumental)_k.wav")]
    assert pick_stem(files, "Vocals") == files[0] and pick_stem(files, "instrumental") == files[2]
    with pytest.raises(ValueError, match="drums"):
        pick_stem(files, "drums")


def test_separate_chains_roformer_then_demucs(cfg, monkeypatch):
    ws = Workspace(cfg, song())
    audio.write_wav(ws.work / "input.wav", tone(2.0))
    calls = []
    def fake_tool(tool, args, **kw):
        calls.append((tool, args))
        assert kw["timeout"] > 0
        if tool == "vocals":                      # RoFormer: vocals = 300 Hz, instrumental = 600 Hz
            out = Path(args[args.index("--output_dir") + 1])
            audio.write_wav(out / "input_(vocals)_r.wav", tone(2.0, freq=300))
            audio.write_wav(out / "input_(other)_r.wav", tone(2.0, freq=600))
        else:                                     # Demucs on the instrumental
            out = Path(args[args.index("-o") + 1]) / "htdemucs_6s"
            for i, s in enumerate(["vocals", "drums", "bass", "guitar", "piano", "other"]):
                audio.write_wav(out / f"{s}.wav", tone(2.0, freq=1000 + 100 * i))
    monkeypatch.setattr(S, "run_tool", fake_tool)
    r = S.SEPARATE.run(ws, {"ingest": {"duration_s": 2.0}})
    assert [c[0] for c in calls] == ["vocals", "separate"]
    assert "vocals_mel_band_roformer.ckpt" in calls[0][1] and str(ws.work / "input.wav") in calls[0][1]
    assert calls[1][1][-1].endswith("(other)_r.wav")          # Demucs runs on the RoFormer instrumental
    def peak(name):
        x, _ = audio.read(ws.stems / name)
        return np.fft.rfftfreq(len(x), 1 / 44100)[np.argmax(np.abs(np.fft.rfft(x[:, 0])))]
    assert peak("vocals.wav") == pytest.approx(300, abs=1)    # vocals from RoFormer, not Demucs
    assert peak("drums.wav") == pytest.approx(1100, abs=1)
    assert peak("residu_voix.wav") == pytest.approx(1000, abs=1)
    assert r["vocals_model"] == "vocals_mel_band_roformer.ckpt"
    assert sorted(p.name for p in S.SEPARATE.artifacts(ws)) == sorted(
        ["vocals.wav", "drums.wav", "bass.wav", "guitar.wav", "piano.wav", "other.wav"])
