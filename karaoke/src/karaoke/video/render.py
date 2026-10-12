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
        y = _centered(d, 380, s.current, big, (255, 214, 0))
        _centered(d, max(y + 60, 640), s.next, mid, (150, 150, 150))
    elif s.kind == "instrumental":
        _centered(d, 300, "♪", sym, (90, 90, 90))
        _centered(d, 640, s.next, mid, (150, 150, 150))
    if s.countdown:
        _centered(d, 120, "●" * s.countdown, _font(SYM, 110), (255, 80, 80))
    return img


def render_video(states: list[State], out_mp4: Path, work: Path, fps: int = 25) -> None:
    work.mkdir(parents=True, exist_ok=True)
    entries = []
    for s in states:
        h = hashlib.sha1(repr((s.kind, s.current, s.next, s.countdown)).encode()).hexdigest()[:16]
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
