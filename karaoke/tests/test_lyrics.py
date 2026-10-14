import pytest
from karaoke import lrclib
from karaoke.lrclib import LrclibResult
from karaoke.runner import StepRetry
from karaoke.steps import lyrics as L
from karaoke.workspace import Workspace
from test_manifest import song

UP = {"ingest": {"offset_s": 0.5}, "separate": {}}


def run(cfg, monkeypatch, result, files=None, aligned=None, sid="009"):
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: result)
    calls = []
    def fake_align(vocals, lines, language, work, duration_s=600.0, segments=None):
        calls.append((lines, segments))
        if aligned:
            return [{"start": t, "score": sc, "words": []} for t, sc in aligned]
        return [{"start": 1.0 + i, "score": 0.9,
                 "words": [{"w": w, "s": 1.0 + i + 0.1 * k, "e": 1.0 + i + 0.1 * k + 0.08}
                           for k, w in enumerate(l.split())]} for i, l in enumerate(lines)]
    monkeypatch.setattr(L, "align_lines", fake_align)
    monkeypatch.setattr(L, "transcribe", lambda *a, **k: [])        # nothing heard unless a test says so
    for name, text in (files or {}).items():
        (cfg.paroles / name).write_text(text, encoding="utf-8")
    return L.LYRICS.run(Workspace(cfg, song(id=sid)), UP), calls


def test_synced_is_shifted_by_offset(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(True, False, "[00:10.00]Bonjour\n[00:12.00]Salut", "x"))
    assert r["source"] == "lrclib-synchro"
    # LRCLIB's times (shifted by the 0.5 s offset: 9.5, 11.5) only place the windows, 1 s back at most;
    # each line's time then comes from its first sung word (the fake aligner sings at 1.0 and 2.0)
    assert calls[0][0] == ["Bonjour", "Salut"] and calls[0][1] == [[8.5, 11.5], [10.5, 21.5]]
    assert [l["t"] for l in r["lines"]] == [1.0, 2.0]
    assert r["lines"][0]["words"][0]["text"] == "Bonjour" and r["lines"][0]["words"][0]["syllables"]


def test_plain_is_aligned(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(True, False, None, "[Refrain]\nUn\nDeux"))
    assert r["source"] == "lrclib-texte+alignement" and calls == [(["Un", "Deux"], None)]
    assert [l["t"] for l in r["lines"]] == [1.0, 2.0]


def test_user_text_when_lrclib_missing(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(False, False, None, None), files={"009.txt": "A\nB\n"})
    assert r["source"] == "texte-fourni+alignement" and calls == [(["A", "B"], None)]


def test_user_lrc_overrides_everything(cfg, monkeypatch):
    r, _ = run(cfg, monkeypatch, LrclibResult(True, False, "[00:01.00]x", None), files={"009.lrc": "[00:03.00]Corrigé"})
    assert r["source"] == "fichier-lrc" and [(l["t"], l["text"]) for l in r["lines"]] == [(2.5, "Corrigé")]


def test_instrumental_and_none(cfg, monkeypatch):
    r, _ = run(cfg, monkeypatch, LrclibResult(True, True, None, None))
    assert r["source"] == "instrumental" and r["lines"] == []
    r2, _ = run(cfg, monkeypatch, LrclibResult(False, False, None, None), sid="010")
    assert r2["source"] == "aucune" and r2["lines"] == []


def test_unaligned_lines_interpolated(cfg, monkeypatch):
    r, _ = run(cfg, monkeypatch, LrclibResult(True, False, None, "a\nb\nc"),
               aligned=[(1.0, 0.9), (None, None), (5.0, 0.8)])
    assert [l["t"] for l in r["lines"]] == [1.0, 3.0, 5.0] and r["lines"][1]["score"] is None


def test_offline_propagates_retry(cfg, monkeypatch):
    def boom(*a, **k):
        raise StepRetry("offline")
    monkeypatch.setattr(lrclib, "fetch", boom)
    with pytest.raises(StepRetry):
        L.LYRICS.run(Workspace(cfg, song(id="011")), UP)


def test_key_changes_when_user_text_appears(cfg):
    ws = Workspace(cfg, song(id="012"))
    k1 = L.LYRICS.key(ws)
    (cfg.paroles / "012.txt").write_text("x", encoding="utf-8")
    assert L.LYRICS.key(ws) != k1


def test_alignment_job_has_plain_spaces_only(cfg, monkeypatch, tmp_path):
    # Review: str.split() splits on U+00A0/U+202F but WhisperX only on " ", so word counts
    # drifted after every non-breaking space (common in French: « reviendras-tu ? »).
    import json as _json
    seen = {}
    def fake_tool(tool, args, **kw):
        job = _json.loads(open(args[2], encoding="utf-8").read())
        seen.update(job)
        _json.dump({"starts": [1.0] * len(job["lines"]), "scores": [1.0] * len(job["lines"]),
                    "words": [[] for _ in job["lines"]]}, open(args[3], "w"))
    monkeypatch.setattr(L, "run_tool", fake_tool)
    L.align_lines(tmp_path / "v.wav", ["Dis, quand reviendras-tu ?", "un deux   trois"], "fr", tmp_path)
    assert "segments" not in seen
    assert seen["lines"] == ["Dis, quand reviendras-tu ?", "un deux trois"]


def test_corrected_output_lrc_copied_back_keeps_its_timing(cfg, monkeypatch):
    # Review: Michel corrects sortie/.../paroles.lrc (show time, count-in included) and copies it
    # to paroles/<id>.lrc. The tag written by the pipeline says how to shift it back.
    r, _ = run(cfg, monkeypatch, LrclibResult(False, False, None, None),
               files={"009.lrc": "[karaoke:decalage=4.780]\n[00:18.70]Ligne corrigée\n"})
    assert r["source"] == "fichier-lrc" and r["lines"][0]["t"] == pytest.approx(18.70 - 4.78)


def test_offline_uses_supplied_text(cfg, monkeypatch):
    # Review: the spec says everything except the LRCLIB request works offline; a supplied
    # paroles/<id>.txt must not stay blocked behind an unreachable LRCLIB.
    def offline(*a, **k):
        raise StepRetry("offline")
    monkeypatch.setattr(lrclib, "fetch", offline)
    calls = []
    monkeypatch.setattr(L, "align_lines", lambda v, lines, lang, work, d=600.0, segments=None: calls.append(lines)
                        or [{"start": 1.0 + i, "score": 0.9, "words": []} for i in range(len(lines))])
    (cfg.paroles / "013.txt").write_text("A\nB\n", encoding="utf-8")
    r = L.LYRICS.run(Workspace(cfg, song(id="013")), UP)
    assert r["source"] == "texte-fourni+alignement" and calls == [["A", "B"]]


def _pinned_align(calls):
    """Windowed: first words pinned at each window's start (043). Whole song: the real times (1 s earlier)."""
    def fake(vocals, lines, language, work, duration_s=600.0, segments=None):
        calls.append(segments)
        out = []
        for i, l in enumerate(lines):
            s = segments[i][0] if segments else 10.0 + 3 * i - 1.0
            out.append({"start": s, "score": 0.9,
                        "words": [{"w": w, "s": s + 0.3 * k, "e": s + 0.3 * k + 0.2} for k, w in enumerate(l.split())]})
        return out
    return fake


SYNC = "".join(f"[00:{10 + 3 * i:02d}.00]ligne numero {i}\n" for i in range(6))


def test_lrclib_times_off_for_this_recording_realign_on_the_whole_song(cfg, monkeypatch):
    # 043: LRCLIB's version differs; first words pinned at « 0.5 s before the line » on 43 % of lines
    calls = []
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: LrclibResult(False, False, SYNC, "x"))
    monkeypatch.setattr(L, "align_lines", _pinned_align(calls))
    r = L.LYRICS.run(Workspace(cfg, song(id="009")), {"ingest": {"offset_s": 0.0}, "separate": {}})
    assert r["source"] == "lrclib-synchro+realignement"
    assert calls[0] is not None and calls[-1] is None                    # windowed first, then whole song
    assert [round(l["t"], 2) for l in r["lines"]] == [9.0 + 3 * i for i in range(6)]


def test_corrected_file_is_never_realigned(cfg, monkeypatch):
    calls = []
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: pytest.fail("LRCLIB must not be asked"))
    monkeypatch.setattr(L, "align_lines", _pinned_align(calls))
    (cfg.paroles / "009.lrc").write_text("[karaoke:decalage=0.000]\n" + SYNC, encoding="utf-8")
    r = L.LYRICS.run(Workspace(cfg, song(id="009")), {"ingest": {"offset_s": 0.0}, "separate": {}})
    assert r["source"] == "fichier-lrc" and None not in calls


def _aligner_at(offset, calls):
    """Each line's words sung `offset` s after the LRC time (inside the window)."""
    def fake(vocals, lines, language, work, duration_s=600.0, segments=None):
        calls.append(segments)
        out = []
        for i, l in enumerate(lines):
            lrc_t = 10.0 + 3 * i
            s = lrc_t + offset
            out.append({"start": s, "score": 0.9,
                        "words": [{"w": w, "s": s + 0.3 * k, "e": s + 0.3 * k + 0.2} for k, w in enumerate(l.split())]})
        return out
    return fake


def test_lrclib_line_time_becomes_its_first_sung_word(cfg, monkeypatch):
    # Michel: LRCLIB's times are 0.3–0.7 s off at random; the pipeline knows when each line is sung
    calls = []
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: LrclibResult(False, False, SYNC, "x"))
    monkeypatch.setattr(L, "align_lines", _aligner_at(0.6, calls))
    r = L.LYRICS.run(Workspace(cfg, song(id="009")), {"ingest": {"offset_s": 0.0}, "separate": {}})
    assert r["source"] == "lrclib-synchro"
    assert [round(l["t"], 2) for l in r["lines"]] == [10.6 + 3 * i for i in range(6)]


def test_window_looks_one_second_back_but_not_before_the_previous_line(cfg, monkeypatch):
    calls = []
    sync = "[00:10.00]un deux\n[00:10.50]trois quatre\n[00:14.00]cinq six\n"
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: LrclibResult(False, False, sync, "x"))
    monkeypatch.setattr(L, "align_lines", _aligner_at(0.0, calls))
    L.LYRICS.run(Workspace(cfg, song(id="009")), {"ingest": {"offset_s": 0.0}, "separate": {}})
    assert [s[0] for s in calls[0]] == [9.0, 10.0, 13.0]


def test_corrected_file_keeps_its_own_line_times(cfg, monkeypatch):
    calls = []
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: pytest.fail("LRCLIB must not be asked"))
    monkeypatch.setattr(L, "align_lines", _aligner_at(0.6, calls))
    (cfg.paroles / "009.lrc").write_text("[karaoke:decalage=0.000]\n" + SYNC, encoding="utf-8")
    r = L.LYRICS.run(Workspace(cfg, song(id="009")), {"ingest": {"offset_s": 0.0}, "separate": {}})
    assert [round(l["t"], 2) for l in r["lines"]] == [10.0 + 3 * i for i in range(6)]



def w(text, s, e):
    return {"w": text, "s": s, "e": e}


def test_transcribed_words_become_lines_at_pauses():
    words = [w("Je", 1.0, 1.2), w("t'aime", 1.3, 1.8), w("encore", 1.9, 2.4),     # pause 1.2 s
             w("et", 3.6, 3.7), w("toujours", 3.8, 4.5)]
    lines = L.lines_from_words(words)
    assert [l["text"] for l in lines] == ["Je t'aime encore", "et toujours"]
    assert lines[0]["start"] == 1.0 and [x["w"] for x in lines[1]["words"]] == ["et", "toujours"]


def test_long_phrases_are_split_for_the_screen():
    words = [w(f"mot{i}", 1.0 + 0.4 * i, 1.3 + 0.4 * i) for i in range(23)]   # 23 words, no pause
    lines = L.lines_from_words(words)
    assert all(len(l["words"]) <= L.MAX_LINE_WORDS for l in lines) and sum(len(l["words"]) for l in lines) == 23


def test_no_lyrics_anywhere_transcribes_the_lead_vocal(cfg, monkeypatch):
    # LRCLIB has nothing, Michel gave no text: the singer's voice is transcribed as a draft to proofread
    seen = {}
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: lrclib.NOT_FOUND)
    def fake_transcribe(vocals, language, work, duration_s=600.0):
        seen.update(vocals=vocals, language=language)
        return L.lines_from_words([w("Jeanne", 5.0, 5.5), w("et", 5.6, 5.7), w("Serge", 5.8, 6.4)])
    monkeypatch.setattr(L, "transcribe", fake_transcribe)
    ws = Workspace(cfg, song(id="054"))
    ws.stems.mkdir(parents=True, exist_ok=True)
    (ws.stems / "lead.wav").write_bytes(b"")                       # written by vocals_split in a real run
    r = L.LYRICS.run(ws, {"ingest": {"offset_s": 0.0, "duration_s": 120.0}, "separate": {}, "vocals_split": {}})
    assert r["source"] == "transcription" and seen["vocals"] == ws.stems / "lead.wav" and seen["language"] == "fr"
    assert [l["text"] for l in r["lines"]] == ["Jeanne et Serge"] and r["lines"][0]["t"] == 5.0
    assert [x["text"] for x in r["lines"][0]["words"]] == ["Jeanne", "et", "Serge"]
    assert "vocals_split" in L.LYRICS.deps


def test_nothing_heard_stays_without_lyrics(cfg, monkeypatch):
    monkeypatch.setattr(lrclib, "fetch", lambda *a, **k: lrclib.NOT_FOUND)
    monkeypatch.setattr(L, "transcribe", lambda *a, **k: [])
    r = L.LYRICS.run(Workspace(cfg, song(id="054")), {"ingest": {"offset_s": 0.0}, "separate": {}, "vocals_split": {}})
    assert r["source"] == "aucune" and r["lines"] == []
