"""Lyrics video rendering: one PNG per distinct display state (Pillow), assembled by ffmpeg."""
from __future__ import annotations
import hashlib
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from karaoke.video.timeline import State

W, H = 1920, 1080
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG = "/System/Library/Fonts/Supplemental/Arial.ttf"
SYM = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"   # ♪ and ● (missing from Arial)


def _font(path: str, size: int):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default(size)


def _wrap(draw, text, font, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = f"{cur} {w}".strip()
        if draw.textlength(trial, font=font) <= width or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    return lines + ([cur] if cur else [])


YELLOW, WHITE, GREY, CHORD = (255, 214, 0), (255, 255, 255), (150, 150, 150), (120, 200, 255)


def _karaoke_line(draw, y, text, lit, font, chords=(), chord_font=None):
    """Current line, centered and wrapped; its first `lit` characters (sung syllables) in yellow.
    Chord labels (char offset, label) sit above their syllable, pushed right to avoid overlaps."""
    words, offsets, pos = text.split(" "), [], 0
    for w in words:
        offsets.append(pos)
        pos += len(w) + 1
    rows, cur = [], []
    for i, w in enumerate(words):
        trial = " ".join(words[j] for j in cur + [i])
        if cur and draw.textlength(trial, font=font) > W - 200:
            rows.append(cur)
            cur = [i]
        else:
            cur.append(i)
    if cur:
        rows.append(cur)
    space = draw.textlength(" ", font=font)
    chord_h = int(chord_font.size * 1.1) if chords else 0
    for row in rows:
        x = (W - draw.textlength(" ".join(words[i] for i in row), font=font)) / 2
        if chords:
            starts = {i: x + draw.textlength(" ".join(words[j] for j in row[:row.index(i)]) + (" " if i != row[0] else ""), font=font)
                      for i in row}
            right = -1e9
            for off, label in chords:
                i = max(j for j in range(len(words)) if offsets[j] <= off)   # word holding the syllable
                if i in starts:
                    k = min(off - offsets[i], len(words[i]))
                    lx = max(starts[i] + draw.textlength(words[i][:k], font=font), right)
                    draw.text((lx, y), label, font=chord_font, fill=CHORD)
                    right = lx + draw.textlength(label + " ", font=chord_font)
            y += chord_h
        for i in row:
            w, n = words[i], max(0, min(len(words[i]), lit - offsets[i]))
            if n:
                draw.text((x, y), w[:n], font=font, fill=YELLOW)
            if n < len(w):
                draw.text((x + draw.textlength(w[:n], font=font), y), w[n:], font=font, fill=WHITE)
            x += draw.textlength(w, font=font) + space
        y += int(font.size * 1.25)
    return y


def _centered(draw, y, text, font, fill):
    for line in _wrap(draw, text, font, W - 200):
        draw.text(((W - draw.textlength(line, font=font)) / 2, y), line, font=font, fill=fill)
        y += int(font.size * 1.25)
    return y


def _frame(s: State) -> Image.Image:
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    big, mid, sym = _font(BOLD, 96), _font(REG, 64), _font(SYM, 160)
    if s.kind == "titre":
        _centered(d, 380, s.current, big, (255, 255, 255))
    elif s.kind == "ligne":
        y = _karaoke_line(d, 380 - (60 if s.chords else 0), s.current, s.lit, big, s.chords, _font(BOLD, 72))
        _centered(d, max(y + 60, 640), s.next, mid, GREY)
    elif s.kind == "instrumental":
        _centered(d, 300, "♪", sym, (90, 90, 90))
        _centered(d, 640, s.next, mid, GREY)
    if s.countdown:     # 4-3-2-1 on the last beats before the next line
        _centered(d, 90, str(s.countdown), _font(BOLD, 200), (255, 80, 80))
    return img


def render_video(states: list[State], out_mp4: Path, work: Path, fps: int = 25) -> None:
    work.mkdir(parents=True, exist_ok=True)
    entries = []
    for s in states:
        h = hashlib.sha1(repr((s.kind, s.current, s.next, s.countdown, s.lit, s.chords)).encode()).hexdigest()[:16]
        png = work / f"{h}.png"
        if not png.exists():
            _frame(s).save(png)
        entries.append((png, s.end - s.start))
    lst = work / "concat.txt"
    with open(lst, "w", encoding="utf-8") as f:
        for png, dur in entries:
            f.write(f"file '{png}'\nduration {dur:.6f}\n")
        f.write(f"file '{entries[-1][0]}'\n")
    total = sum(d for _, d in entries)
    out_mp4.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                    "-vf", f"fps={fps},format=yuv420p", "-c:v", "libx264", "-tune", "stillimage",
                    "-crf", "20", "-t", f"{total:.3f}", "-an", str(out_mp4)], check=True)
