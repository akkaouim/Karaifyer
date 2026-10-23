from karaoke.chord_sources import normalise, parse


def test_normalise_spellings():
    assert [normalise(s) for s in ["Amin", "Fs", "Fsmin7", "D/Fs", "B&", "Em7", "Bbmaj7", "Gsus", "H", "Refrain"]] == \
        ["Am", "F#", "F#m7", "D/F#", "Bb", "Em7", "Bbmaj7", "Gsus4", None, None]


def test_chords_above_lyrics_with_column_offsets():
    c = parse("[Verse 1]\nAm        F\nOn vous souhaite tout le bonheur\n   G    Am\nEt que quelqu'un\n")
    assert [(l.section, l.text, l.chords) for l in c.lines] == [
        ("Verse 1", "On vous souhaite tout le bonheur", [(0, "Am"), (10, "F")]),
        ("Verse 1", "Et que quelqu'un", [(3, "G"), (8, "Am")])]


def test_chordpro_and_patadata_inline():
    a = parse("{title: X}\n[Am]On vous sou[F]haite\n")
    b = parse("\\capo{2}\n\\begin{chorus}\n  \\[Am]On vous sou\\[F]haite\n\\end{chorus}\n")
    assert a.lines[0].text == "On vous souhaite" and a.lines[0].chords == [(0, "Am"), (11, "F")]
    assert b.capo == 2 and b.lines[0].section == "chorus" and b.lines[0].chords == [(0, "Am"), (11, "F")]


def test_chordonomicon_progression():
    c = parse("<intro_1> E G <verse_1> D A Bmin <chorus_1> E Fs/As")
    assert [(l.section, l.text, [s for _, s in l.chords]) for l in c.lines] == [
        ("intro_1", "", ["E", "G"]), ("verse_1", "", ["D", "A", "Bm"]), ("chorus_1", "", ["E", "F#/A#"])]


def test_chord_only_lines_and_capo_in_a_tab():
    c = parse("Capo 3\nIntro: Am F C G\n\nAm\nla la\n")
    assert c.capo == 3 and c.lines[0].text == "" and [s for _, s in c.lines[0].chords] == ["Am", "F", "C", "G"]
