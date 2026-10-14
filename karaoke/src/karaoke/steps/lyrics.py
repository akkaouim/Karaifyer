"""Step `lyrics` — synced lyric lines, never transcribed.

Inputs:  manifest row; ingest result (offset_s); stems/vocals.wav (for alignment only);
         optional $KARAOKE_HOME/paroles/<id>.lrc (Michel's corrected file, wins over everything)
         or paroles/<id>.txt (plain text to align).
Outputs: result {source, language, lines: [{t, text, score, words}]} with t in trimmed-input time;
         words = [{text, start, end, syllables: [{text, start}]}] from WhisperX word alignment (every
         song with lyrics is aligned; synced sources keep their line starts and align within each line).
Sources, in priority order: fichier-lrc, instrumental, lrclib-synchro, lrclib-texte+alignement,
texte-fourni+alignement, aucune.
"""
from __future__ import annotations
import json
from pathlib import Path

from karaoke import lrc, lrclib
from karaoke.syllables import timed_words
from karaoke.runner import Step, StepRetry
from karaoke.tools import TOOLS_DIR, run_tool, tool_timeout
from karaoke.workspace import Workspace


LINE_TAIL_S = 10.0     # window after the last synced line
LINE_LEAD_S = 1.0      # a synced line's window starts up to 1 s before its timestamp (never before the previous line)
# LRCLIB's timings can come from another version of the song (043): the first word then gets pinned at
# its window's earliest point on many lines. Measured: 5–25 % on well-synced songs, 43 % on 043.
PINNED_MAX = 0.35


def align_lines(vocals: Path, lines: list[str], language: str, work: Path, duration_s: float = 600.0,
                segments: list[list[float]] | None = None) -> list[dict]:
    """WhisperX forced alignment (isolated tool). Returns per line {start, score, words: [{w, s, e}]}.
    With `segments` ([start, end] per line) each line is aligned inside its own window."""
    job, out = work / "align_job.json", work / "align_out.json"
    # Plain ASCII spaces only: WhisperX splits words on " " but str.split() also on
    # non-breaking spaces, and a mismatch shifts every following line.
    lines = [" ".join(l.split()) for l in lines]
    payload = {"audio": str(vocals), "language": language, "lines": lines}
    if segments is not None:
        payload["segments"] = segments
    job.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    run_tool("align", ["python", str(TOOLS_DIR / "align" / "align_tool.py"), str(job), str(out)],
             timeout=tool_timeout("align", duration_s))
    d = json.loads(out.read_text())
    words = d.get("words") or [[] for _ in lines]
    return [{"start": st, "score": sc, "words": w} for st, sc, w in zip(d["starts"], d["scores"], words)]


MAX_LINE_WORDS = 10      # transcribed lines: what fits on the projector
MAX_LINE_S = 6.0
LINE_PAUSE_S = 0.8       # a pause this long between words starts a new line


def transcribe(vocals: Path, language: str, work: Path, duration_s: float = 600.0) -> list[dict]:
    """Whisper transcription of the vocal stem (isolated tool) → karaoke lines (lines_from_words)."""
    job, out = work / "transcribe_job.json", work / "transcribe_out.json"
    job.write_text(json.dumps({"audio": str(vocals), "language": language}, ensure_ascii=False), encoding="utf-8")
    run_tool("align", ["python", str(TOOLS_DIR / "align" / "transcribe_tool.py"), str(job), str(out)],
             timeout=tool_timeout("transcribe", duration_s))
    return lines_from_words(json.loads(out.read_text()).get("words", []))


def lines_from_words(words: list[dict]) -> list[dict]:
    """Cut a transcription into screen lines: at pauses, and before a line gets too long.
    Each line: {start, text, score, words: [{w, s, e}]} (the aligner's format)."""
    timed = [w for w in words if w.get("s") is not None and w.get("e") is not None]
    lines, cur = [], []
    for w in timed:
        if cur and (w["s"] - cur[-1]["e"] >= LINE_PAUSE_S or len(cur) >= MAX_LINE_WORDS
                    or w["e"] - cur[0]["s"] > MAX_LINE_S):
            lines.append(cur)
            cur = []
        cur.append(w)
    if cur:
        lines.append(cur)
    return [{"start": l[0]["s"], "text": " ".join(x["w"] for x in l), "score": None, "words": l} for l in lines]


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


def _pinned_share(lines: list[dict], windows: list[float]) -> float:
    """Share of lines whose first word sits at the very start of its alignment window."""
    timed = [(l, w) for l, w in zip(lines, windows) if l.get("words")]
    if not timed:
        return 0.0
    return sum(1 for l, w in timed if abs(l["words"][0]["start"] - w) <= 0.02) / len(timed)


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

    vocals = ws.stems / "vocals.wav"
    duration = upstream["ingest"].get("duration_s", 600.0)

    def with_words(starts: list[float], texts: list[str], aligned: list[dict]) -> list[dict]:
        out = []
        for i, (t, x, a) in enumerate(zip(starts, texts, aligned)):
            end = starts[i + 1] if i + 1 < len(starts) else t + LINE_TAIL_S
            out.append({"t": t, "text": x, "score": a.get("score"),
                        "words": timed_words(x, a.get("words") or [], t, end, s.langue)})
        return out

    windows: list[float] = []

    def synced_lines(lines: list[lrc.Line], snap: bool) -> list[dict]:
        """Align each line inside its window. snap: the line's time becomes its first sung word (LRCLIB's
        times are 0.3–0.7 s off at random); Michel's own corrected files keep their times."""
        if not lines:
            return []
        starts, texts = [l.t for l in lines], [l.text for l in lines]
        segs = [[round(max(starts[i - 1] if i else 0.0, t - LINE_LEAD_S), 3),
                 round(starts[i + 1] if i + 1 < len(starts) else t + LINE_TAIL_S, 3)] for i, t in enumerate(starts)]
        windows[:] = [a for a, _ in segs]
        aligned = align_lines(vocals, texts, s.langue, ws.work, duration, segments=segs)
        out = with_words(starts, texts, aligned)
        if snap:
            prev = -1.0
            for l in out:
                if l.get("words"):
                    l["t"] = max(round(l["words"][0]["start"], 3), prev + 0.01)
                prev = l["t"]
        return out

    def synced(text: str, source: str, snap: bool = True) -> dict:
        return {"source": source, "language": s.langue,
                "lines": synced_lines(lrc.shift(lrc.parse(text), -offset), snap)}

    if user_lrc.exists():
        text = user_lrc.read_text(encoding="utf-8")
        show = lrc.show_offset(text)
        if show is not None:   # a corrected copy of sortie/.../paroles.lrc (show time)
            return {"source": "fichier-lrc", "language": s.langue,
                    "lines": synced_lines(lrc.shift(lrc.parse(text), -show), snap=False)}
        return synced(text, "fichier-lrc", snap=False)
    try:
        res = lrclib.fetch(s.titre, s.artiste, s.album, s.duree_ref_s)
    except StepRetry:
        if not user_txt.exists():
            raise
        res = lrclib.NOT_FOUND   # offline: the supplied text still works (spec: offline except LRCLIB)
    if res.instrumental:
        return {"source": "instrumental", "language": s.langue, "lines": []}
    if res.synced:
        lrc_lines = lrc.shift(lrc.parse(res.synced), -offset)
        out = {"source": "lrclib-synchro", "language": s.langue, "lines": synced_lines(lrc_lines, snap=False)}
        if _pinned_share(out["lines"], windows) <= PINNED_MAX:
            prev = -1.0
            for l in out["lines"]:                # times from the sung words (see synced_lines)
                if l.get("words"):
                    l["t"] = max(round(l["words"][0]["start"], 3), prev + 0.01)
                prev = l["t"]
            return out
        # The times don't fit this recording: keep LRCLIB's text, align it on the whole song.
        texts = [l["text"] for l in out["lines"]]
        aligned = align_lines(vocals, texts, s.langue, ws.work, duration)
        times = _interpolate([a["start"] for a in aligned])
        return {"source": "lrclib-synchro+realignement", "language": s.langue,
                "lines": with_words(times, texts, aligned)}
    if res.plain:
        text, source = res.plain, "lrclib-texte+alignement"
    elif user_txt.exists():
        text, source = user_txt.read_text(encoding="utf-8"), "texte-fourni+alignement"
    else:
        # No lyrics anywhere: transcribe the lead singer as a draft (flagged « à relire »).
        lead = ws.stems / "lead.wav"
        heard = transcribe(lead if lead.exists() else vocals, s.langue, ws.work, duration)
        if not heard:
            return {"source": "aucune", "language": s.langue, "lines": []}
        times = [l["start"] for l in heard]
        return {"source": "transcription", "language": s.langue,
                "lines": with_words(times, [l["text"] for l in heard], heard)}
    texts = lrc.plain_lines(text)
    aligned = align_lines(vocals, texts, s.langue, ws.work, duration)
    times = _interpolate([a["start"] for a in aligned])
    return {"source": source, "language": s.langue, "lines": with_words(times, texts, aligned)}


LYRICS = Step(name="lyrics", deps=("ingest", "separate", "vocals_split"), key=_key, run=_run,
              version="5")   # 2: words/syllables; 3: realign; 4: line time = first sung word; 5: transcription when no lyrics
