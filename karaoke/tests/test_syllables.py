import pytest
from karaoke.syllables import syllabify, word_syllables, timed_words


def test_syllabify_french_and_english():
    assert syllabify("danser", "fr") == ["dan", "ser"]
    assert "".join(syllabify("éternellement", "fr")) == "éternellement" and len(syllabify("éternellement", "fr")) >= 4
    assert syllabify("je", "fr") == ["je"]
    assert "".join(syllabify("wonderful", "en")) == "wonderful"


def test_punctuation_stays_attached():
    s = syllabify("revoir,", "fr")
    assert "".join(s) == "revoir," and s[-1].endswith(",")


def test_word_syllables_spread_by_letters():
    syl = word_syllables("danser", 10.0, 11.2, "fr")             # dan | ser : 3 + 3 letters
    assert [x["text"] for x in syl] == ["dan", "ser"]
    assert syl[0]["start"] == pytest.approx(10.0) and syl[1]["start"] == pytest.approx(10.6)


def test_timed_words_interpolates_missing_times():
    aligned = [{"w": "Je", "s": 5.0, "e": 5.2}, {"w": "suis", "s": None, "e": None}, {"w": "là", "s": 6.0, "e": 6.4}]
    words = timed_words("Je suis là", aligned, line_start=5.0, line_end=8.0, lang="fr")
    assert [w["text"] for w in words] == ["Je", "suis", "là"]
    assert words[1]["start"] == pytest.approx(5.6)                 # between 5.2 and 6.0
    assert all(w["syllables"][0]["start"] == pytest.approx(w["start"]) for w in words)


def test_timed_words_without_alignment_spreads_over_the_line():
    words = timed_words("un deux trois quatre", [], line_start=0.0, line_end=4.0, lang="fr")
    assert [round(w["start"], 2) for w in words] == [0.0, 1.0, 2.0, 3.0]
