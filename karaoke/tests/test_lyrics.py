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
    for name, text in (files or {}).items():
        (cfg.paroles / name).write_text(text, encoding="utf-8")
    return L.LYRICS.run(Workspace(cfg, song(id=sid)), UP), calls


def test_synced_is_shifted_by_offset(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(True, False, "[00:10.00]Bonjour\n[00:12.00]Salut", "x"))
    assert r["source"] == "lrclib-synchro"
    assert [l["t"] for l in r["lines"]] == [9.5, 11.5]            # line starts keep LRCLIB's timing
    # every line is also aligned word by word, within its own window
    assert calls[0][0] == ["Bonjour", "Salut"] and calls[0][1] == [[9.0, 11.5], [11.0, 21.5]]
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
