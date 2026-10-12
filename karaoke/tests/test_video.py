import subprocess
from karaoke.audio import probe_duration
from karaoke.video.render import render_video
from karaoke.video.timeline import build_states


def test_render_duration_and_size(tmp_path):
    st = build_states([(2.0, 4.0, "Je suis un homme"), (4.5, 6.0, "À ma place, dis !")],
                      pad_s=1.5, total_s=8.0, titre="Je suis un homme", artiste="Zazie")
    out = tmp_path / "v.mp4"
    render_video(st, out, tmp_path / "frames")
    assert abs(probe_duration(out) - 8.0) < 0.1
    dims = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                           "stream=width,height", "-of", "csv=p=0", str(out)],
                          capture_output=True, text=True).stdout.strip()
    assert dims == "1920,1080"
    audio_streams = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                                    "stream=index", "-of", "csv=p=0", str(out)],
                                   capture_output=True, text=True).stdout.strip()
    assert audio_streams == ""


def test_video_step_writes_shifted_lrc_and_mp4(cfg):
    from karaoke.steps.video import VIDEO
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song(titre="Speed", artiste="Zazie"))
    up = {"package": {"pad_s": 2.0, "total_s": 10.0},
          "lyrics": {"lines": [{"t": 1.0, "text": "Un", "score": None}, {"t": 3.0, "text": "Deux", "score": None}]},
          "check": {"lines": [{"t": 1.0, "ok": True, "end": 2.5}, {"t": 3.0, "ok": True, "end": 5.0}]}}
    r = VIDEO.run(ws, up)
    assert (ws.out / "paroles.lrc").read_text(encoding="utf-8") == "[00:03.00]Un\n[00:05.00]Deux\n"
    assert abs(probe_duration(ws.out / "paroles.mp4") - 10.0) < 0.1 and r["duration_s"] == 10.0
    assert sorted(p.name for p in VIDEO.artifacts(ws)) == ["paroles.lrc", "paroles.mp4"]
