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


# --- beat-grid cleanup (Michel's run: 044 half tempo in quiet parts, 042 bars of 2 beats) ---
P = 0.42                                     # ≈ 143 BPM


def even(n, p=P, t0=1.0):
    return [round(t0 + p * i, 4) for i in range(n)]


def test_half_tempo_section_is_filled():
    from karaoke.grid import regularize
    full = even(64)
    detected = full[:16] + full[16:48:2] + full[48:]          # every other beat missing in the middle
    beats, down, info = regularize(detected, full[::4])
    assert len(beats) == 64 and max(abs(a - b) for a, b in zip(beats, full)) < 1e-6
    assert info["added"] == 16 and info["removed"] == 0


def test_stray_extra_beat_is_removed():
    from karaoke.grid import regularize
    full = even(40)
    detected = sorted(full + [full[10] + 0.1])
    beats, _, info = regularize(detected, full[::4])
    assert beats == full and info["removed"] == 1


def test_two_beat_bars_become_regular_bars():
    from karaoke.grid import regularize
    full = even(48)
    # every bar's beat 1 is detected, plus a false « beat 3 » bar line in 8 of the 12 bars (as in 042)
    down = sorted(full[::4] + [full[i + 2] for i in range(8, 40, 4)])
    beats, down2, info = regularize(full, down)
    assert down2 == full[::4] and info["bars_regularized"]


def test_drifting_tempo_is_left_alone():
    from karaoke.grid import regularize
    beats, t = [], 1.0
    for i in range(80):                      # 100 → 115 BPM, gradual
        beats.append(round(t, 4))
        t += 60 / (100 + 15 * i / 79)
    out, down, info = regularize(beats, beats[::4])
    assert out == beats and down == beats[::4] and info["added"] == info["removed"] == 0


def test_real_break_is_left_alone():
    from karaoke.grid import regularize
    full = even(40)
    detected = full[:20] + full[26:]                          # 6-beat silence: a real stop, not half tempo
    beats, _, info = regularize(detected, detected[::4])
    assert beats == detected and info["added"] == 0


def test_genuine_bar_shifts_keep_detected_downbeats():
    from karaoke.grid import regularize
    full = even(48)
    down = full[0:16:4] + full[17:48:4]                       # a 5-beat bar: later bars start one beat later
    _, down2, info = regularize(full, down)
    assert down2 == down and not info["bars_regularized"]


def test_free_tempo_song_is_left_alone():
    # 041 (old, free-tempo recording) lost 71 beats to the first version of the cleanup
    import random
    from karaoke.grid import regularize
    rnd, t, beats = random.Random(7), 1.0, []
    for _ in range(120):
        beats.append(round(t, 4))
        t += P * rnd.uniform(0.55, 1.9)
    out, down, info = regularize(beats, beats[::4])
    assert out == beats and down == beats[::4] and info == {"added": 0, "removed": 0, "bars_regularized": False}


def test_slow_section_with_full_bars_is_not_doubled():
    # Speed: a genuinely slower section keeps 4 beats per bar — those are real beats, not skipped ones
    from karaoke.grid import regularize
    fast = even(40)
    slow = [round(fast[-1] + 2 * P * (i + 1), 4) for i in range(8)]   # 8 beats at half tempo, 2 bars of 4
    beats = fast + slow
    down = beats[:40:4] + [slow[3], slow[7]]
    out, _, info = regularize(beats, down)
    assert info["added"] == 0 and out == beats


def test_bar_lines_are_rebuilt_per_regular_stretch():
    # 044: a stretch tracked at 3/4 tempo shifts the detected bar lines by a beat afterwards; each regular
    # stretch gets its own vote, the unreadable stretch keeps its detected bar lines
    from karaoke.grid import regularize
    a = even(64)                                              # regular, bars on beats 0, 4, 8…
    odd = [round(a[-1] + 1.33 * P * (i + 1), 4) for i in range(9)]    # tracked at 3/4 tempo (044's share)
    c = [round(odd[-1] + P * (i + 1), 4) for i in range(65)]          # regular again
    beats = a + odd + c
    down_a = a[::4] + [a[i + 2] for i in range(4, 60, 8)]            # some false « beat 3 » lines
    down_odd = odd[::3]
    down_c = c[1::4] + [c[i + 2] for i in range(1, 61, 8)]           # bars on c[1], c[5]… (shifted) + false beat-3 lines
    out, down, info = regularize(beats, down_a + down_odd + down_c)
    assert info["bars_regularized"]
    assert [d for d in down if d <= a[-1]] == a[::4]
    assert [d for d in down if odd[0] <= d <= odd[-1]] == down_odd
    assert [d for d in down if d >= c[0]] == c[1::4]
