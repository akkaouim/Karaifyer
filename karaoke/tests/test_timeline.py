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


def test_line_chords_places_changes_on_sung_syllable():
    from karaoke.video.timeline import TimedLine, line_chords
    # "dan ser en core": syllables dan(10.0) ser(10.5) en(11.0) core(11.5)
    line = TimedLine(10.0, 12.5, "dan ser en core", [(10.0, 3), (10.5, 7), (11.0, 10), (11.5, 15)])
    changes = [{"t": 2.0, "label": "C"}, {"t": 10.7, "label": "Am"}, {"t": 11.6, "label": "F"},
               {"t": 13.0, "label": "G"}]
    # chord sounding at line start at 0; Am during « ser » (starts at char 4); F during « core » (char 11)
    assert line_chords(line, changes) == [(0, "C"), (4, "Am"), (11, "F")]


def test_line_chords_skips_no_chord_and_keeps_last_change_per_syllable():
    from karaoke.video.timeline import TimedLine, line_chords
    line = TimedLine(10.0, 12.0, "dan ser", [(10.0, 3), (10.5, 7)])
    assert line_chords(line, [{"t": 0.0, "label": "N.C."}, {"t": 10.6, "label": "C"}, {"t": 10.8, "label": "G"}]) \
        == [(4, "G")]
    assert line_chords(line, []) == []


def test_line_states_carry_chords():
    from karaoke.video.timeline import TimedLine, build_states
    line = TimedLine(1.0, 2.0, "la", [(1.0, 2)], chords=((0, "C"),))
    states = build_states([line], 0.0, 4.0, "T", "A", [])
    assert all(s.chords == ((0, "C"),) for s in states if s.kind == "ligne")


def test_instrumental_states_show_current_chart_row():
    from karaoke.video.timeline import State, with_chart
    # 6 bars of 2 s from t=1; rows of 4: [C Am F G] then [C G]
    bars = [(1.0 + 2 * i, c) for i, c in enumerate(["C", "Am F", "N.C.", "G", "C", "G"])]
    states = [State(0.0, 4.0, "titre", "T", "", None), State(4.0, 8.0, "ligne", "la", "", None),
              State(8.0, 14.0, "instrumental", "", "x", 1)]
    out = with_chart(states, bars, 4)
    titre = [s for s in out if s.kind == "titre"]
    assert [(s.start, s.end, s.chart_pos) for s in titre] == [(0.0, 1.0, None), (1.0, 3.0, 0), (3.0, 4.0, 1)]
    assert titre[0].chart == () and titre[1].chart == ("C", "Am F", "N.C.", "G")
    assert [s for s in out if s.kind == "ligne"][0].chart == ()            # sung lines keep chords above
    inst = [s for s in out if s.kind == "instrumental"]
    assert [(s.start, s.chart, s.chart_pos) for s in inst] == [
        (8.0, ("C", "Am F", "N.C.", "G"), 3), (9.0, ("C", "G"), 0), (11.0, ("C", "G"), 1), (13.0, (), None)]
    assert all(s.countdown == 1 for s in inst)                             # other fields preserved
    assert with_chart(states, [], 4) == states
