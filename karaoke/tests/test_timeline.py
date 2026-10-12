import pytest
from karaoke.video.timeline import TimedLine, build_states

BEATS = [0.5 * i for i in range(0, 200)]          # 120 BPM grid in output time


def contiguous(states, total):
    assert states[0].start == 0.0 and states[-1].end == pytest.approx(total)
    for a, b in zip(states, states[1:]):
        assert a.end == pytest.approx(b.start)


def line(start, end, text, syl):
    return TimedLine(start, end, text, syl)


def test_syllables_light_up_in_order():
    l1 = line(4.0, 6.0, "dan ser", [(4.0, 3), (4.6, 7)])        # "dan" then "dan ser" lit
    l2 = line(6.5, 8.0, "la", [(6.5, 2)])
    st = build_states([l1, l2], pad_s=3.5, total_s=12.0, titre="T", artiste="A", beats=BEATS)
    contiguous(st, 12.0)
    assert st[0].kind == "titre" and st[0].end == pytest.approx(3.8)
    on_l1 = [(s.start, s.lit) for s in st if s.current == "dan ser"]
    assert on_l1 == [(pytest.approx(3.8), 0), (pytest.approx(4.0), 3), (pytest.approx(4.6), 7)]
    assert next(s for s in st if s.current == "dan ser").next == "la"
    assert st[-1].kind == "fin"


def test_countdown_on_last_four_beats_after_long_gap():
    l1 = line(4.0, 6.0, "un", [(4.0, 2)])
    l2 = line(20.0, 22.0, "deux", [(20.0, 4)])                  # 14 s ≈ 28 beats of silence
    st = build_states([l1, l2], pad_s=3.5, total_s=25.0, titre="T", artiste="A", beats=BEATS)
    contiguous(st, 25.0)
    cd = [(s.start, s.countdown) for s in st if s.countdown]
    assert cd == [(pytest.approx(18.0), 4), (pytest.approx(18.5), 3), (pytest.approx(19.0), 2), (pytest.approx(19.5), 1)]
    assert all(s.kind == "instrumental" and s.next == "deux" for s in st if s.countdown)
    assert next(s for s in st if s.current == "deux").start == pytest.approx(19.8)


def test_no_countdown_for_short_gap():
    l1 = line(4.0, 6.0, "un", [(4.0, 2)])
    l2 = line(9.0, 10.0, "deux", [(9.0, 4)])                    # 3 s = 6 beats: below 8
    st = build_states([l1, l2], pad_s=3.5, total_s=12.0, titre="T", artiste="A", beats=BEATS)
    assert not any(s.countdown for s in st)


def test_countdown_before_first_line_after_long_intro():
    l1 = line(15.0, 17.0, "un", [(15.0, 2)])
    st = build_states([l1], pad_s=2.0, total_s=20.0, titre="T", artiste="A", beats=BEATS)
    contiguous(st, 20.0)
    assert [s.countdown for s in st if s.countdown] == [4, 3, 2, 1]
    assert all(s.kind == "titre" for s in st if s.countdown)


def test_no_lines_is_title_only():
    st = build_states([], pad_s=2.0, total_s=30.0, titre="Instru", artiste="X", beats=BEATS)
    contiguous(st, 30.0)
    assert {s.kind for s in st} == {"titre"}
