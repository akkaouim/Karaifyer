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
    def fake_align(vocals, lines, language, work):
        calls.append(lines)
        return aligned or [(1.0 + i, 0.9) for i in range(len(lines))]
    monkeypatch.setattr(L, "align_lines", fake_align)
    for name, text in (files or {}).items():
        (cfg.paroles / name).write_text(text, encoding="utf-8")
    return L.LYRICS.run(Workspace(cfg, song(id=sid)), UP), calls


def test_synced_is_shifted_by_offset(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(True, False, "[00:10.00]Bonjour\n[00:12.00]Salut", "x"))
    assert r["source"] == "lrclib-synchro" and not calls
    assert [l["t"] for l in r["lines"]] == [9.5, 11.5]


def test_plain_is_aligned(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(True, False, None, "[Refrain]\nUn\nDeux"))
    assert r["source"] == "lrclib-texte+alignement" and calls == [["Un", "Deux"]]
    assert [l["t"] for l in r["lines"]] == [1.0, 2.0]


def test_user_text_when_lrclib_missing(cfg, monkeypatch):
    r, calls = run(cfg, monkeypatch, LrclibResult(False, False, None, None), files={"009.txt": "A\nB\n"})
    assert r["source"] == "texte-fourni+alignement" and calls == [["A", "B"]]


def test_user_lrc_overrides_everything(cfg, monkeypatch):
    r, _ = run(cfg, monkeypatch, LrclibResult(True, False, "[00:01.00]x", None), files={"009.lrc": "[00:03.00]Corrigé"})
    assert r["source"] == "fichier-lrc" and r["lines"] == [{"t": 2.5, "text": "Corrigé", "score": None}]


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
