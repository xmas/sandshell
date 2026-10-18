#!/usr/bin/env python3
"""Generate the Sandshell DMG window background.

Drawn at 2x (1200x960) for a 600x480-pt Finder window. Icon positions in
make-dmg.sh are in points and line up with the callouts drawn here.

The DMG uses the committed copy, scripts/dmg-background.png; after changing
the design, regenerate it (needs Pillow, e.g. in a venv) and commit it:

    python3 scripts/make-dmg-background.py scripts/dmg-background.png

Usage: make-dmg-background.py <output.png>
"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 960  # 2x of the 600x480-pt content area
OCEAN = (29, 99, 237)
INK = (26, 29, 36)
MUTED = (91, 97, 112)
BG = (238, 241, 246)
HILITE = (227, 237, 255)


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except Exception:
        return ImageFont.load_default()


HELV = "/System/Library/Fonts/Helvetica.ttc"
MENLO = "/System/Library/Fonts/Menlo.ttc"
f_title = font(HELV, 60, index=1)   # bold
f_step = font(HELV, 30, index=1)    # bold
f_body = font(HELV, 25, index=0)
f_tag = font(HELV, 21, index=1)
f_mono = font(MENLO, 24)


def centered(draw, text, cx, y, fnt, fill):
    w = draw.textlength(text, font=fnt)
    draw.text((cx - w / 2, y), text, font=fnt, fill=fill)


def main(out):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    # Header band.
    d.rectangle([0, 0, W, 150], fill=OCEAN)
    centered(d, "Sandshell", W / 2, 44, f_title, (255, 255, 255))

    # Step 1 — drag to Applications (icons drawn by Finder at pt (155,190) and
    # (445,190); arrow sits between them).
    centered(d, "1.  Drag Sandshell onto the Applications folder", W / 2, 210, f_step, INK)
    ay = 380
    d.line([470, ay, 720, ay], fill=OCEAN, width=10)
    d.polygon([(720, ay - 22), (760, ay), (720, ay + 22)], fill=OCEAN)

    # Step 2 — read me + run setup (icons at pt (155,345) and (445,345)).
    centered(d, "2.  Open “Read Me First”, then run setup in Terminal", W / 2, 560, f_step, INK)

    # Highlight box behind the "Read Me First" icon to make it prominent (the
    # icon is drawn by Finder at pt (155,370) → px (310,740), inside this box).
    box = [150, 600, 470, 885]
    d.rounded_rectangle(box, radius=20, fill=HILITE, outline=OCEAN, width=3)
    # "START HERE" pill near the top of the box, above the icon.
    tag = "START HERE"
    tw = d.textlength(tag, font=f_tag)
    cx = (box[0] + box[2]) / 2
    d.rounded_rectangle([cx - tw / 2 - 18, 606, cx + tw / 2 + 18, 644], radius=19, fill=OCEAN)
    d.text((cx - tw / 2, 612), tag, font=f_tag, fill=(255, 255, 255))

    # The exact Terminal command, in a dark "code" pill at the bottom.
    cmd = 'bash "/Volumes/Sandshell/Sandshell Setup.command"'
    cw = d.textlength(cmd, font=f_mono)
    cy = 915
    cpill = [W / 2 - cw / 2 - 26, cy - 8, W / 2 + cw / 2 + 26, cy + 38]
    d.rounded_rectangle(cpill, radius=15, fill=INK)
    centered(d, cmd, W / 2, cy, f_mono, (230, 232, 238))

    # 144 dpi → Finder treats the 1200x960-px image as 600x480 pt (crisp on
    # retina, fills the window instead of showing only its top-left corner).
    img.save(out, dpi=(144, 144))
    print(out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "dmg-background.png")
