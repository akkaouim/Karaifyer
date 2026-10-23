from karaoke.chord_sources import normalise, parse


def test_normalise_spellings():
    assert [normalise(s) for s in ["Amin", "Fs", "Fsmin7", "D/Fs", "B&", "Em7", "Bbmaj7", "Gsus", "H", "Refrain"]] == \
        ["Am", "F#", "F#m7", "D/F#", "Bb", "Em7", "Bbmaj7", "Gsus4", "B", None]      # H = B (German charts)


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


from karaoke.chord_sources import Chart, ChartLine, merge

BEATS = [0.5 * i for i in range(16)]
BARS = [0, 4, 8, 12]


def words_at(*lines):            # (text, [start of each word])
    return [list(zip(t.split(), ts)) for t, ts in lines], [t for t, _ in lines]


def test_chart_type_wins_on_same_root():
    w, lt = words_at(("la la", [0.0, 1.0]))
    det = ["C#"] * 8 + ["A"] * 8
    r = merge(Chart([ChartLine(None, "la la", [(0, "C#m")])]), BEATS, BARS, 4, det, w, lt)
    assert r.cells[:2] == ["C#m", "C#m"] and r.flagged == []


def test_different_root_takes_the_detected_bass_and_flags():
    w, lt = words_at(("la la", [0.0, 2.0]))
    det = ["F#m"] * 16
    r = merge(Chart([ChartLine(None, "la la", [(0, "A")])]), BEATS, BARS, 4, det, w, lt)
    assert r.cells[0] == "F#m7" and 0 in r.flagged          # A over F# → F#m7 (Michel's naming)


def test_chorus_repeated_by_text_and_vocabulary_elsewhere():
    w, lt = words_at(("refrain ici", [0.0, 1.0]), ("couplet", [2.0]), ("refrain ici", [6.0, 7.0]))
    det = ["Am"] * 4 + ["C"] * 4 + ["Am"] * 4 + ["G"] * 4
    chart = Chart([ChartLine("chorus", "refrain ici", [(0, "Am7")]), ChartLine("verse", "couplet", [(0, "Cmaj7")])])
    r = merge(chart, BEATS, BARS, 4, det, w, lt)
    assert r.cells[0] == "Am7" and r.cells[1] == "Cmaj7" and r.cells[3].startswith("Am7") and r.repeated >= 1


def test_transposition_follows_the_detection():
    w, lt = words_at(("la", [0.0]))
    det = ["E"] * 16
    r = merge(Chart([ChartLine(None, "la", [(0, "C")])], capo=4), BEATS, BARS, 4, det, w, lt)
    assert r.cells[0] == "E" and r.flagged == []


def test_placement_skips_unmatched_lines():
    w, lt = words_at(("premier vers", [0.0, 0.5]), ("second vers", [4.0, 4.5]))
    chart = Chart([ChartLine(None, "premier vers", [(0, "Am")]), ChartLine(None, "une ligne en trop", [(0, "D")]),
                   ChartLine(None, "second vers", [(0, "G")])])
    r = merge(chart, BEATS, BARS, 4, ["N.C."] * 16, w, lt)
    assert r.cells[0] == "Am" and r.cells[2] == "G" and "D" not in "".join(r.cells)


def test_merge_without_detection_or_words():
    r = merge(Chart([ChartLine("verse_1", "", [(0, "Am"), (1, "F")])]), BEATS, BARS, 4, [], [], [])
    assert len(r.cells) == 4 and all(r.cells)


def test_verse_repeated_by_detected_roots():
    # two sections (gap ≥ 4 s between them), same detected roots; chords only placed in the first
    beats = [0.5 * i for i in range(32)]
    bars = [0, 4, 8, 12, 16, 20, 24, 28]
    w, lt = words_at(("premier couplet", [0.0, 2.0]), ("autre texte ici", [8.0, 10.0]))
    det = (["A"] * 4 + ["D"] * 4 + ["N.C."] * 8) * 2
    chart = Chart([ChartLine("verse", "premier couplet", [(0, "Amaj7"), (8, "D6")])])
    r = merge(chart, beats, bars, 4, det, w, lt)
    assert r.cells[0] == "Amaj7" and r.cells[1] == "D6"
    assert r.cells[4] == "Amaj7" and r.cells[5] == "D6" and r.repeated >= 2


def test_a_chord_sung_a_beat_off_lands_on_the_change_heard_nearby():
    w, lt = words_at(("la la", [0.0, 1.5]))              # second word sung at beat 3
    det = ["Am"] * 4 + ["F"] * 12                         # the audio changes to F at beat 4
    r = merge(Chart([ChartLine(None, "la la", [(0, "Am"), (3, "F")])]), BEATS, BARS, 4, det, w, lt)
    assert r.cells[:2] == ["Am", "F"] and r.flagged == []


def test_offsets_survive_punctuation_indentation_and_braces():
    c = parse("     C            G\n    J'ai, d'abord, demandé\n")
    assert c.lines[0].text == "J'ai, d'abord, demandé" and c.lines[0].chords == [(1, "C"), (14, "G")]
    p = parse("\\[C]{O Mary}, don't \\[G]weep\n")
    assert p.lines[0].text == "O Mary, don't weep" and p.lines[0].chords == [(0, "C"), (14, "G")]
    w, lt = words_at(("J'ai, d'abord, l'ai demandé à la lune", [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0]))
    chart = Chart([ChartLine(None, "J'ai, d'abord, l'ai demandé à la lune", [(0, "C"), (30, "G")])])  # G over « la »
    r = merge(chart, BEATS, BARS, 4, ["N.C."] * 16, w, lt)
    assert r.cells[2] == "C G"                     # « la » is sung at 5.0 s = beat 10, mid bar 3


def test_chords_past_the_end_of_the_lyric_are_kept():
    c = parse("C       G        Am     F\nHi there\n")
    w, lt = words_at(("Hi there", [0.0, 1.0]))
    r = merge(c, BEATS, BARS, 4, ["N.C."] * 16, w, lt)
    joined = " ".join(r.cells)
    assert all(ch in joined.split() for ch in ("C", "G", "Am", "F"))


def test_chord_lines_with_marks_and_odd_tokens_are_kept():
    for line in ["C G (2x)", "N.C.  G", "(C)  G*", "Hm  H7", "| Am | F |  x4"]:
        c = parse(f"{line}\nla la la\n")
        assert c.lines and c.lines[0].text == "la la la" and c.lines[0].chords, line
    assert [s for _, s in parse("Hm  H7\nla\n").lines[0].chords] == ["Bm", "B7"]


def test_chart_key_and_transposition_to_the_song_key():
    from karaoke.chord_sources import chart_key, key_offset, transpose_progression, transpose_sg
    prog = "<intro_1> Em Bmin D Em G D Em <verse_1> D G Em D G Em D C D "
    assert chart_key(parse(prog)) == 7                              # G major / E minor
    assert key_offset(parse(prog), "Ab major") == 1 and key_offset(parse(prog), "F minor") == 1
    assert key_offset(parse(prog), None) == 0
    assert transpose_progression(prog, 1) == "<intro_1> Fmin Cmin Eb Fmin Ab Eb Fmin <verse_1> Eb Ab Fmin Eb Ab Fmin Eb Db Eb"
    assert transpose_progression("<verse_1> D/Fs Asus4", 2) == "<verse_1> E/Gs Bsus4"
    assert transpose_sg("Il \\[Em]était un \\[D/F#]petit", 1) == "Il \\[Fm]était un \\[Eb/G]petit"


def test_render_chart_with_chords_above_lyrics():
    from karaoke.chord_sources import render
    c = parse("\\begin{verse}\n\\[Am]On vous sou\\[F]haite\n\\end{verse}\n\\begin{chorus}\n\\[G]Tout le bonheur\n\\end{chorus}\n")
    assert render(c) == "[Couplet]\nAm         F\nOn vous souhaite\n\n[Refrain]\nG\nTout le bonheur"
    assert render(parse("<verse_1> D A <chorus_1> E")) == "Couplet 1 : D A\nRefrain 1 : E"


def test_patadata_metadata_and_diagrams_are_not_lyrics():
    c = parse("\\beginsong{X}\n  [by={Thomas Fersen},cover={x},album={Y}]\n  \\utab{Fm}{1013}\n  \\gtab{C}{X32010}\n"
              "  \\musicnote{doucement}\n\\begin{verse*}\n  \\[Fm]On me dit\n\\end{verse*}\n")
    assert [(l.section, l.text) for l in c.lines] == [("verse*", "On me dit")]
