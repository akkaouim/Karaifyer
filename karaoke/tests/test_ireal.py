from urllib.parse import unquote
from karaoke.ireal import chord, ireal_key, song_url, write_html

BARS = [{"start": 0.0, "chords": [[0, "C"]]}, {"start": 2.0, "chords": [[0, "Am"], [2, "F"]]},
        {"start": 4.0, "chords": [[0, "N.C."]]}, {"start": 6.0, "chords": [[0, "Ebm"]]}]


def test_chord_syntax():
    assert chord("Am") == "A-" and chord("C") == "C" and chord("N.C.") == "n" and chord("Ebm") == "Eb-"


def test_key_mapping():
    assert ireal_key("C# minor") == "C#-" and ireal_key("C major") == "C"
    assert ireal_key("C# major") == "Db" and ireal_key("A# minor") == "Bb-"


def test_song_url_layout():
    url = song_url("Danser", "Loïc Nottet", "Pop", "C# minor", BARS, 4, 120.0)
    assert url.startswith("irealbook://") and "#" not in url and " " not in url   # # would start a fragment
    assert unquote(url[len("irealbook://"):]) == "Danser=Loïc Nottet=Pop=C#-=n=[T44C |A- F |n |Eb- Z"


def test_song_url_waltz_and_reserved_chars():
    url = unquote(song_url("A=B", "X", "Waltz", "C major", BARS[:1], 3, 90.0)[len("irealbook://"):])
    assert url == "A-B=X=Waltz=C=n=[T34C Z"


def test_write_html(tmp_path):
    out = tmp_path / "ireal" / "test.html"
    write_html(out, "test", [("Danser", "Loïc Nottet", "irealbook://x%20y")])
    html = out.read_text()
    assert 'href="irealbook://x%20y"' in html and "Danser" in html and "<title>" in html


def test_write_pages_groups_by_partie_and_skips_songs_without_chords(cfg):
    from karaoke.ireal import write_pages
    from karaoke.workspace import Workspace
    from test_manifest import song
    a, b, c = song(id="001", partie="Apéro"), song(id="002", titre="Sans accords", partie="Apéro"), song(id="003", partie="")
    for s in (a, c):
        Workspace(cfg, s).write_marker("chords", {"result": {"key": "C major", "bpm": 120.0, "beats_per_bar": 4,
                                                              "bars": BARS}})
    pages = write_pages(cfg, [a, b, c])
    assert sorted(p.name for p in pages) == ["apero.html", "sans-partie.html"]
    html = (cfg.home / "ireal" / "apero.html").read_text()
    assert html.count("irealbook://") == 1 and "Je suis un homme" in html


def test_song_url_fully_percent_encoded_like_the_official_example():
    import re
    body = song_url("Danser", "Loïc Nottet", "Pop", "C# minor", BARS, 4, 120.0)[len("irealbook://"):]
    assert re.fullmatch(r"[A-Za-z0-9_.~%-]*", body), body        # = [ | , # all as %XX
    assert "%3D" in body and "%7C" in body and "%5B" in body


def test_rich_chord_symbols_to_ireal():
    assert [chord(c) for c in ["Cmaj7", "Dm7", "F#m7b5", "Edim", "Gsus4", "Am/G", "Bb7", "Caug", "Am6"]] == \
        ["C^7", "D-7", "F#h7", "Eo", "Gsus", "A-/G", "Bb7", "C+", "A-6"]


def test_signature_codes_and_styles():
    from karaoke.ireal import signature_code, style_for
    assert [signature_code(n, s) for n, s in [(4, None), (3, None), (2, "6/8"), (4, "12/8"), (12, "12/8"), (2, "2/4")]] == \
        ["T44", "T34", "T68", "T12", "T12", "T24"]
    assert style_for(3, None, False) == "Waltz" and style_for(2, "6/8", False) == "Waltz"
    assert style_for(4, "12/8", False) == "Slow Rock" and style_for(4, "4/4", True) == "Medium Swing"
    assert style_for(4, None, False) == "Pop"
    url = unquote(song_url("X", "Y", "Slow Rock", "C major", BARS[:1], 4, 60.0, signature="12/8"))
    assert "[T12" in url
