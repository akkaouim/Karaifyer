from karaoke.lrc import Line, parse, format, shift, plain_lines

SAMPLE = "[ar:Zazie]\n[00:12.50]Je suis un homme\n[00:15.2][01:02.00]Refrain\n\n[00:20]Fin\n"


def test_parse():
    assert parse(SAMPLE) == [Line(12.5, "Je suis un homme"), Line(15.2, "Refrain"),
                             Line(20.0, "Fin"), Line(62.0, "Refrain")]


def test_format_roundtrip():
    lines = parse(SAMPLE)
    assert parse(format(lines)) == lines
    assert format([Line(62.05, "x")]) == "[01:02.05]x\n"


def test_shift_clamps():
    assert shift([Line(0.3, "a"), Line(5.0, "b")], -0.5) == [Line(0.0, "a"), Line(4.5, "b")]


def test_plain_lines():
    assert plain_lines("[Refrain]\nLa la\n\n  Do ré  \n") == ["La la", "Do ré"]


def test_guessed_lines_by_file_order():
    from karaoke.lrc import parse_marked
    # the app writes [karaoke:a_caler=…] with the indices of every timed line, empty ones included
    text = "[karaoke:decalage=0.500]\n[karaoke:a_caler=1,2]\n[00:09.00]Trois\n[00:05.00]Deux\n[00:07.00]\n[00:03.00]Un\n"
    assert parse_marked(text) == [(Line(3.0, "Un"), False), (Line(5.0, "Deux"), True), (Line(9.0, "Trois"), False)]
    assert [g for _, g in parse_marked(SAMPLE)] == [False] * 4
