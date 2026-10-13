import subprocess
import numpy as np
from karaoke.audio import probe_duration
from karaoke.video.render import render_video, _frame
from karaoke.video.timeline import State, TimedLine, build_states

BEATS = [0.5 * i for i in range(40)]


def test_render_duration_and_size(tmp_path):
    lines = [TimedLine(2.0, 4.0, "Je suis un homme", [(2.0, 2), (2.4, 7), (2.8, 10), (3.2, 13), (3.4, 16)]),
             TimedLine(4.5, 6.0, "À ma place, dis !", [(4.5, 1), (4.8, 4)])]
    st = build_states(lines, pad_s=1.5, total_s=8.0, titre="Je suis un homme", artiste="Zazie", beats=BEATS)
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


def test_lit_syllables_are_yellow():
    def yellow_pixels(lit):
        px = np.asarray(_frame(State(0, 1, "ligne", "dan ser", "", None, lit)))
        return int(((px[..., 0] > 200) & (px[..., 1] > 180) & (px[..., 2] < 80)).sum())
    assert yellow_pixels(0) == 0 < yellow_pixels(3) < yellow_pixels(7)


def test_video_step_writes_shifted_lrc_and_mp4(cfg):
    from karaoke.steps.video import VIDEO
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song(titre="Speed", artiste="Zazie"))
    words1 = [{"text": "Un", "start": 1.0, "end": 1.4, "syllables": [{"text": "Un", "start": 1.0}]}]
    words2 = [{"text": "Deux", "start": 3.0, "end": 3.5, "syllables": [{"text": "Deux", "start": 3.0}]}]
    up = {"package": {"pad_s": 2.0, "total_s": 10.0},
          "beats": {"beats": BEATS, "downbeats": []},
          "lyrics": {"lines": [{"t": 1.0, "text": "Un", "score": None, "words": words1},
                               {"t": 3.0, "text": "Deux", "score": None, "words": words2}]},
          "check": {"lines": [{"t": 1.0, "ok": True, "end": 2.5}, {"t": 3.0, "ok": True, "end": 5.0}]}}
    r = VIDEO.run(ws, up)
    assert (ws.out / "paroles.lrc").read_text(encoding="utf-8") == (
        "[karaoke:decalage=2.000]\n[00:03.00]Un\n[00:05.00]Deux\n")
    assert abs(probe_duration(ws.out / "paroles.mp4") - 10.0) < 0.1 and r["duration_s"] == 10.0
    assert sorted(p.name for p in VIDEO.artifacts(ws)) == ["paroles.lrc", "paroles.mp4"]
    assert r["states"] >= 4


def test_chords_drawn_light_blue_above_line():
    def blue_rows(chords):
        px = np.asarray(_frame(State(0, 1, "ligne", "dan ser", "", None, 0, chords)))
        mask = (px[..., 2] > 200) & (px[..., 0] < 180) & (px[..., 1] > 150) & (px[..., 1] < 240)
        return np.nonzero(mask.any(axis=1))[0]
    assert len(blue_rows(())) == 0
    rows = blue_rows(((0, "C"), (4, "Am")))
    white = np.nonzero((np.asarray(_frame(State(0, 1, "ligne", "dan ser", "", None, 0, ((0, "C"),))))
                        .min(axis=2) > 240).any(axis=1))[0]
    assert len(rows) and rows.max() < white.min()     # labels sit above the lyric row


def test_video_step_passes_chords_to_lines(cfg, monkeypatch):
    from karaoke.steps import video as V
    from karaoke.workspace import Workspace
    from test_manifest import song
    seen = {}
    monkeypatch.setattr(V, "render_video", lambda states, *a: seen.setdefault("states", states))
    ws = Workspace(cfg, song())
    words = [{"text": "Un", "start": 1.0, "end": 1.4, "syllables": [{"text": "Un", "start": 1.0}]}]
    up = {"package": {"pad_s": 2.0, "total_s": 10.0}, "beats": {"beats": BEATS, "downbeats": []},
          "lyrics": {"lines": [{"t": 1.0, "text": "Un", "score": None, "words": words}]},
          "check": {"lines": [{"t": 1.0, "ok": True, "end": 2.5}]},
          "chords": {"changes": [{"t": 0.0, "label": "Am"}]}}
    V.VIDEO.run(ws, up)
    assert any(s.chords == ((0, "Am"),) for s in seen["states"])
    assert "chords" in V.VIDEO.deps and V.VIDEO.version == "4"
