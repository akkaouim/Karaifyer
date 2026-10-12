import numpy as np
import pytest
from karaoke.grid import (beats_per_bar, tempo_stats, countin_plan, click_events, render_click,
                          onsets, drift_ms)


def grid(bpm=120.0, start=0.5, n=200, bpb=4):
    p = 60 / bpm
    beats = [start + i * p for i in range(n)]
    return beats, beats[::bpb]


def test_meter():
    b, d = grid(bpb=4)
    assert beats_per_bar(b, d) == 4
    b, d = grid(bpb=3)
    assert beats_per_bar(b, d) == 3
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
    assert x.ndim == 1 and 0.85 < np.abs(x).max() <= 0.9      # accent is loud and never clips


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


def test_tempo_ignores_20ms_frame_quantization():
    # Beat This! reports beats on a 20 ms grid: at 143 BPM single intervals read 0.40 or 0.42 s
    # (150 vs 143 BPM). Measured on « Le petit bal perdu »: the median-IBI metric said 5 %.
    b, _ = grid(bpm=143.0, start=0.5, n=400)
    jitter = np.random.default_rng(0).integers(-1, 2, len(b)) * 0.02     # ±1 detection frame
    q = [round(t / 0.02) * 0.02 + j for t, j in zip(b, jitter)]
    s = tempo_stats(q)
    assert s["stable"] and s["variation_pct"] < 2.0 and s["bpm"] == pytest.approx(143, abs=0.5)


def test_countin_goes_before_first_beat_even_when_first_downbeat_is_late():
    # Review: beats from 0.5 s but first downbeat detected at 12.5 s. The spec wants the
    # count-in before the song (silent accompaniment) and every detected beat clicked.
    p = 0.5
    beats = [0.5 + i * p for i in range(60)]
    downbeats = [t for t in beats if t >= 12.5][::4]
    plan = countin_plan(beats, downbeats, n_bars=2)
    assert plan.pad_s == pytest.approx(3.5, abs=1 / 44100)
    assert max(plan.times_in) < beats[0] and plan.times_in[-1] == pytest.approx(beats[0] - p)
    assert plan.accents == [True, False, False, False] * 2      # 0.5 s is a bar start (6 bars before 12.5)
    ev = click_events(plan, beats, downbeats)
    assert len(ev) == 8 + len(beats)
    assert [a for t, a in ev if abs(t - (12.5 + plan.pad_s)) < 1e-6] == [True]
