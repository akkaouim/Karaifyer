"""Step `lyrics` — synced lyric lines, never transcribed.

Inputs:  manifest row; ingest result (offset_s); stems/vocals.wav (for alignment only);
         optional $KARAOKE_HOME/paroles/<id>.lrc (Michel's corrected file, wins over everything)
         or paroles/<id>.txt (plain text to align).
Outputs: result {source, language, lines: [{t, text, score}]} with t in trimmed-input time.
Sources, in priority order: fichier-lrc, instrumental, lrclib-synchro, lrclib-texte+alignement,
texte-fourni+alignement, aucune.
"""
from __future__ import annotations
import json
from pathlib import Path

from karaoke import lrc, lrclib
from karaoke.runner import Step, StepRetry
from karaoke.tools import TOOLS_DIR, run_tool, tool_timeout
from karaoke.workspace import Workspace


def align_lines(vocals: Path, lines: list[str], language: str, work: Path,
                duration_s: float = 600.0) -> list[tuple[float | None, float | None]]:
    """WhisperX forced alignment (isolated tool). Returns (start, score) per line."""
    job, out = work / "align_job.json", work / "align_out.json"
    # Plain ASCII spaces only: WhisperX splits words on " " but str.split() also on
    # non-breaking spaces, and a mismatch shifts every following line.
    lines = [" ".join(l.split()) for l in lines]
    job.write_text(json.dumps({"audio": str(vocals), "language": language, "lines": lines}, ensure_ascii=False),
                   encoding="utf-8")
    run_tool("align", ["python", str(TOOLS_DIR / "align" / "align_tool.py"), str(job), str(out)],
             timeout=tool_timeout("align", duration_s))
    d = json.loads(out.read_text())
    return list(zip(d["starts"], d["scores"]))


def _interpolate(times: list[float | None]) -> list[float]:
    known = [(i, t) for i, t in enumerate(times) if t is not None]
    if not known:
        return [0.0] * len(times)
    out = []
    for i, t in enumerate(times):
        if t is not None:
            out.append(t)
            continue
        before = [(j, u) for j, u in known if j < i]
        after = [(j, u) for j, u in known if j > i]
        if before and after:
            (j0, u0), (j1, u1) = before[-1], after[0]
            out.append(u0 + (u1 - u0) * (i - j0) / (j1 - j0))
        else:
            out.append((before[-1] if before else after[0])[1])
    return [round(t, 3) for t in out]


def _paths(ws: Workspace) -> tuple[Path, Path]:
    return ws.cfg.paroles / f"{ws.song.id}.lrc", ws.cfg.paroles / f"{ws.song.id}.txt"


def _key(ws: Workspace) -> str:
    parts = [ws.song.titre, ws.song.artiste, ws.song.album, str(ws.song.duree_ref_s), ws.song.langue]
    for p in _paths(ws):
        parts.append(str(p.stat().st_mtime_ns) if p.exists() else "-")
    return "|".join(parts)


def _run(ws: Workspace, upstream: dict) -> dict:
    s, offset = ws.song, upstream["ingest"]["offset_s"]
    user_lrc, user_txt = _paths(ws)

    def synced(text: str, source: str) -> dict:
        lines = lrc.shift(lrc.parse(text), -offset)
        return {"source": source, "language": s.langue,
                "lines": [{"t": l.t, "text": l.text, "score": None} for l in lines]}

    if user_lrc.exists():
        text = user_lrc.read_text(encoding="utf-8")
        show = lrc.show_offset(text)
        if show is not None:   # a corrected copy of sortie/.../paroles.lrc (show time)
            lines = lrc.shift(lrc.parse(text), -show)
            return {"source": "fichier-lrc", "language": s.langue,
                    "lines": [{"t": l.t, "text": l.text, "score": None} for l in lines]}
        return synced(text, "fichier-lrc")
    try:
        res = lrclib.fetch(s.titre, s.artiste, s.album, s.duree_ref_s)
    except StepRetry:
        if not user_txt.exists():
            raise
        res = lrclib.NOT_FOUND   # offline: the supplied text still works (spec: offline except LRCLIB)
    if res.instrumental:
        return {"source": "instrumental", "language": s.langue, "lines": []}
    if res.synced:
        return synced(res.synced, "lrclib-synchro")
    if res.plain:
        text, source = res.plain, "lrclib-texte+alignement"
    elif user_txt.exists():
        text, source = user_txt.read_text(encoding="utf-8"), "texte-fourni+alignement"
    else:
        return {"source": "aucune", "language": s.langue, "lines": []}
    texts = lrc.plain_lines(text)
    aligned = align_lines(ws.stems / "vocals.wav", texts, s.langue, ws.work,
                          upstream["ingest"].get("duration_s", 600.0))
    times = _interpolate([t for t, _ in aligned])
    return {"source": source, "language": s.langue,
            "lines": [{"t": t, "text": x, "score": sc} for t, x, (_, sc) in zip(times, texts, aligned)]}


LYRICS = Step(name="lyrics", deps=("ingest", "separate"), key=_key, run=_run)
