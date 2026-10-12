import pytest
from karaoke.video.timeline import build_states


def contiguous(states, total):
    assert states[0].start == 0.0 and states[-1].end == pytest.approx(total)
    for a, b in zip(states, states[1:]):
        assert a.end == pytest.approx(b.start)


def test_title_then_lines():
    st = build_states([(4.0, 6.0, "Un"), (6.5, 8.0, "Deux")], pad_s=3.5, total_s=12.0, titre="T", artiste="A")
    contiguous(st, 12.0)
    assert st[0].kind == "titre" and st[0].end == pytest.approx(3.8)
    l1 = next(s for s in st if s.current == "Un")
    assert l1.start == pytest.approx(3.8) and l1.next == "Deux"
    assert st[-1].kind == "fin"


def test_instrumental_gap_has_countdown():
    st = build_states([(4.0, 6.0, "Un"), (20.0, 22.0, "Deux")], pad_s=3.5, total_s=25.0, titre="T", artiste="A")
    contiguous(st, 25.0)
    instr = [s for s in st if s.kind == "instrumental"]
    assert instr and instr[0].next == "Deux"
    assert [s.countdown for s in instr if s.countdown] == [3, 2, 1]
    assert [s for s in instr if s.countdown == 1][0].end == pytest.approx(19.8)


def test_no_lines_is_title_only():
    st = build_states([], pad_s=2.0, total_s=30.0, titre="Instru", artiste="X")
    contiguous(st, 30.0)
    assert {s.kind for s in st} == {"titre"}
