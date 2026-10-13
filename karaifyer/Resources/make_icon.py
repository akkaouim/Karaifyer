"""Draws Karaifyer's app icon (microphone + note) → Resources/Karaifyer.icns.
Run: uv --directory ../karaoke run python ../karaifyer/Resources/make_icon.py  (Pillow + iconutil)."""
import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw

S = 1024
here = pathlib.Path(__file__).parent


def icon() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg = Image.new("RGBA", (S, S))
    px = bg.load()
    for y in range(S):                                  # violet → pink diagonal gradient
        for x in range(0, S, 4):
            f = (x + y) / (2 * S)
            c = (int(88 + 150 * f), int(40 + 30 * f), int(190 - 60 * f), 255)
            for dx in range(4):
                px[x + dx, y] = c
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([90, 90, S - 90, S - 90], radius=190, fill=255)
    img.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(img)
    white, yellow = (255, 255, 255, 255), (255, 214, 0, 255)
    d.rounded_rectangle([392, 230, 592, 560], radius=100, fill=white)          # mic capsule
    d.arc([330, 380, 654, 680], start=0, end=180, fill=white, width=34)         # cradle
    d.rectangle([475, 676, 509, 780], fill=white)                               # stem
    d.rounded_rectangle([392, 770, 592, 806], radius=18, fill=white)            # base
    d.ellipse([640, 600, 760, 690], fill=yellow)                                # note head
    d.rectangle([730, 330, 756, 650], fill=yellow)                              # note stem
    d.polygon([(756, 330), (850, 390), (850, 440), (756, 385)], fill=yellow)    # flag
    return img


def main() -> None:
    base = icon()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "Karaifyer.iconset"
        iconset.mkdir()
        for n in (16, 32, 128, 256, 512):
            base.resize((n, n), Image.LANCZOS).save(iconset / f"icon_{n}x{n}.png")
            base.resize((2 * n, 2 * n), Image.LANCZOS).save(iconset / f"icon_{n}x{n}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(here / "Karaifyer.icns")], check=True)
    base.resize((256, 256), Image.LANCZOS).save(here / "icon-preview.png")


if __name__ == "__main__":
    main()
