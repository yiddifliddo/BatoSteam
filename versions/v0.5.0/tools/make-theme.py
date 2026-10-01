#!/usr/bin/env python3
# BatoSteam - boot menu theme generator ("split screen")
# Author: Dan Lee
# Version: 0.5.0
#
# Draws the original artwork for the BatoSteam rEFInd boot menu:
#   config/theme/background.png      1920x1080 split-screen background
#   config/theme/os_batocera.png     Batocera icon (retro gamepad)
#   config/theme/os_steamos.png      SteamOS icon (modern controller)
#   config/theme/selection_big.png   glow behind the selected OS icon
#   config/theme/selection_small.png glow behind the selected tool icon
#   docs/boot-menu-preview.png       how the menu looks (rEFInd layout, approximate)
#
# All artwork is original (no Batocera or Valve logos). Needs Pillow: pip install pillow
# Usage: python3 tools/make-theme.py [--preview-only]

import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THEME = os.path.join(ROOT, "config", "theme")
DOCS = os.path.join(ROOT, "docs")
W, H = 1920, 1080
BIG_ICON = 384                       # must match big_icon_size in config/refind.conf
SEL_BIG = BIG_ICON * 144 // 128      # rEFInd's optimal selection size for that icon size
SEL_SMALL = 64 * 64 // 48 + 1

# Palette
RETRO_TOP, RETRO_MID, RETRO_BOT = (26, 6, 46), (92, 18, 104), (255, 110, 64)
STEEL_TOP, STEEL_MID, STEEL_BOT = (6, 14, 30), (14, 44, 84), (40, 110, 170)
ORANGE, PINK, CYAN, ICE = (255, 140, 60), (255, 70, 150), (90, 220, 255), (200, 235, 255)

FONT_DIRS = ["/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/TTF", "/usr/share/fonts/dejavu"]


def font(size, bold=True):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vgradient(w, h, stops):
    """Vertical gradient through a list of (position, colour) stops."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                c = lerp(c0, c1, (t - p0) / (p1 - p0))
                break
        for x in range(w):
            px[x, y] = c
    return img


def glow_text(base, xy, text, fnt, fill, glow, radius=10, anchor="mm"):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).text(xy, text, font=fnt, fill=glow + (255,), anchor=anchor)
    layer = layer.filter(ImageFilter.GaussianBlur(radius))
    base.alpha_composite(layer)
    ImageDraw.Draw(base).text(xy, text, font=fnt, fill=fill + (255,), anchor=anchor)


##
## Background
##

def retro_half():
    w, h = W // 2, H
    img = vgradient(w, h, [(0, RETRO_TOP), (0.55, RETRO_MID), (0.72, RETRO_BOT), (1, (40, 8, 50))]).convert("RGBA")
    d = ImageDraw.Draw(img)
    # Pixel stars
    rnd = random.Random(7)
    for _ in range(140):
        x, y = rnd.randrange(w), rnd.randrange(int(h * 0.5))
        s = rnd.choice([2, 2, 3, 4])
        a = rnd.randrange(90, 230)
        d.rectangle([x, y, x + s, y + s], fill=(255, 220, 255, a))
    # Retro sun (striped)
    cx, cy, r = w // 2, int(h * 0.62), 210
    sun = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sun)
    for yy in range(cy - r, cy + 1):
        t = (yy - (cy - r)) / r
        half = int(math.sqrt(max(0, r * r - (cy - yy) ** 2)))
        if t > 0.45 and int((yy - cy) / 10) % 2 == 0:
            continue
        sd.line([(cx - half, yy), (cx + half, yy)], fill=lerp((255, 230, 90), PINK, t) + (255,))
    img.alpha_composite(sun.filter(ImageFilter.GaussianBlur(1)))
    # Perspective grid floor
    horizon = int(h * 0.62)
    floor = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fd = ImageDraw.Draw(floor)
    fd.rectangle([0, horizon, w, h], fill=(30, 4, 40, 235))
    for i in range(-14, 15):
        fd.line([(cx + i * 40, horizon), (cx + i * 260, h)], fill=PINK + (170,), width=2)
    y, step = horizon, 6
    while y < h:
        fd.line([(0, y), (w, y)], fill=PINK + (170,), width=2)
        y += step
        step = int(step * 1.32) + 2
    img.alpha_composite(floor)
    # Scanlines
    sl = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sld = ImageDraw.Draw(sl)
    for yy in range(0, h, 4):
        sld.line([(0, yy), (w, yy)], fill=(0, 0, 0, 38))
    img.alpha_composite(sl)
    return img


def steel_half():
    w, h = W // 2, H
    img = vgradient(w, h, [(0, STEEL_TOP), (0.6, STEEL_MID), (1, STEEL_BOT)]).convert("RGBA")
    # Soft diagonal light beams
    beams = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    bd = ImageDraw.Draw(beams)
    for i, a in [(0, 40), (1, 26), (2, 34), (3, 20)]:
        x0 = 120 + i * 230
        bd.polygon([(x0, 0), (x0 + 90, 0), (x0 - 260, h), (x0 - 350, h)], fill=(140, 200, 255, a))
    img.alpha_composite(beams.filter(ImageFilter.GaussianBlur(28)))
    # Hex dot grid
    dots = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dots)
    for row, yy in enumerate(range(20, h, 34)):
        off = 17 if row % 2 else 0
        for xx in range(off, w, 34):
            a = int(25 + 45 * (yy / h))
            dd.ellipse([xx - 2, yy - 2, xx + 2, yy + 2], fill=(170, 220, 255, a))
    img.alpha_composite(dots)
    # Floor glow
    fl = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(fl).ellipse([-200, int(h * 0.78), w + 200, h + 260], fill=CYAN + (60,))
    img.alpha_composite(fl.filter(ImageFilter.GaussianBlur(60)))
    return img


def background():
    bg = Image.new("RGBA", (W, H))
    bg.paste(retro_half(), (0, 0))
    bg.paste(steel_half(), (W // 2, 0))
    # Glowing seam
    seam = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(seam)
    for y in range(H):
        a = 200 if y > 200 else int(200 * max(0, y - 140) / 60)   # clear behind the title
        sd.line([(W // 2 - 3, y), (W // 2 + 3, y)], fill=(255, 255, 255, a))
    bg.alpha_composite(seam.filter(ImageFilter.GaussianBlur(14)))
    bg.alpha_composite(seam.filter(ImageFilter.GaussianBlur(3)))
    # Titles
    glow_text(bg, (W // 2, 92), "BatoSteam", font(84), (255, 255, 255), (180, 160, 255), 16)
    glow_text(bg, (W // 4, 200), "BATOCERA", font(46), (255, 214, 170), ORANGE, 12)
    glow_text(bg, (W // 4, 252), "retro gaming", font(28, False), (255, 200, 230), PINK, 6)
    glow_text(bg, (3 * W // 4, 200), "STEAMOS", font(46), ICE, CYAN, 12)
    glow_text(bg, (3 * W // 4, 252), "pc gaming", font(28, False), ICE, CYAN, 6)
    # Hint line (rEFInd's own hints are hidden)
    glow_text(bg, (W // 2, H - 34), "<  >  choose      ENTER  start", font(24, False), (235, 235, 245), (0, 0, 0), 4)
    return bg.convert("RGB")


##
## Icons (drawn at 4x and scaled down for smooth edges)
##

S = 4
N = 512 * S


def rr(d, box, r, **kw):
    d.rounded_rectangle([int(v * S) for v in box], radius=int(r * S), **kw)


def ell(d, cx, cy, r, **kw):
    d.ellipse([int((cx - r) * S), int((cy - r) * S), int((cx + r) * S), int((cy + r) * S)], **kw)


def shine(img, box, r):
    """Soft white highlight, blended (not painted) onto the icon."""
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    rr(ImageDraw.Draw(layer), box, r, fill=(255, 255, 255, 90))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(6 * S)))


def finish(img):
    img = img.resize((512, 512), Image.LANCZOS)
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (0, 0), img.split()[3])
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(10)), (0, 10))
    out.alpha_composite(img)
    return out


def icon_batocera():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Body: classic 16-bit pad with a warm gradient
    body = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    rr(bd, (40, 150, 472, 372), 110, fill=(255, 255, 255, 255))
    grad = vgradient(N, N, [(0, (255, 176, 80)), (0.45, (250, 96, 90)), (0.8, (200, 36, 120)), (1, (200, 36, 120))]).convert("RGBA")
    img = Image.composite(grad, img, body.split()[3])
    d = ImageDraw.Draw(img)
    rr(d, (40, 150, 472, 372), 110, outline=(60, 10, 50, 255), width=10 * S)
    shine(img, (90, 168, 422, 200), 18)
    # D-pad
    rr(d, (96, 237, 216, 279), 8, fill=(45, 12, 45, 255))
    rr(d, (135, 198, 177, 318), 8, fill=(45, 12, 45, 255))
    # Face buttons (pixel-style colours)
    for (bx, by, col) in [(372, 214, (90, 220, 255)), (420, 258, (120, 255, 140)),
                          (324, 258, (255, 230, 90)), (372, 302, (255, 255, 255))]:
        ell(d, bx, by, 25, fill=(45, 12, 45, 255))
        ell(d, bx - 3, by - 3, 19, fill=col + (255,))
    # Start / select
    rr(d, (222, 300, 252, 314), 7, fill=(45, 12, 45, 255))
    rr(d, (262, 300, 292, 314), 7, fill=(45, 12, 45, 255))
    return finish(img)


def icon_steamos():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    mask = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    md = ImageDraw.Draw(mask)
    # Modern pad: central body + two grips
    rr(md, (70, 150, 442, 330), 80, fill=(255, 255, 255, 255))
    ell(md, 130, 330, 82, fill=(255, 255, 255, 255))
    ell(md, 382, 330, 82, fill=(255, 255, 255, 255))
    grad = vgradient(N, N, [(0, (235, 245, 255)), (0.4, (150, 200, 240)), (1, (40, 90, 160))]).convert("RGBA")
    img = Image.composite(grad, img, mask.split()[3])
    edge = mask.split()[3].filter(ImageFilter.FIND_EDGES).filter(ImageFilter.MaxFilter(31))
    outline = Image.new("RGBA", (N, N), (10, 30, 60, 255))
    img = Image.composite(outline, img, Image.eval(edge, lambda v: 255 if v > 0 else 0).convert("L"))
    img = Image.composite(grad, img, mask.split()[3].filter(ImageFilter.MinFilter(31)))
    d = ImageDraw.Draw(img)
    shine(img, (120, 165, 392, 192), 15)
    # Thumbsticks
    for (sx, sy) in [(170, 290), (320, 290)]:
        ell(d, sx, sy, 44, fill=(10, 30, 60, 255))
        ell(d, sx, sy, 31, fill=(70, 130, 200, 255))
        ell(d, sx - 6, sy - 6, 12, fill=(200, 230, 255, 255))
    # D-pad (left top)
    rr(d, (104, 204, 164, 222), 5, fill=(10, 30, 60, 255))
    rr(d, (125, 183, 143, 243), 5, fill=(10, 30, 60, 255))
    # Face buttons (right top) - one colour, glowing cyan
    for (bx, by) in [(372, 200), (402, 228), (342, 228), (372, 256)]:
        ell(d, bx, by, 15, fill=(10, 30, 60, 255))
        ell(d, bx, by, 10, fill=CYAN + (255,))
    # Centre "power" dot
    ell(d, 256, 222, 16, fill=(10, 30, 60, 255))
    ell(d, 256, 222, 9, fill=(255, 255, 255, 255))
    return finish(img)


def selection(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = size // 12
    d.rounded_rectangle([m, m, size - m, size - m], radius=size // 6, fill=(255, 255, 255, 46),
                        outline=(255, 255, 255, 210), width=max(3, size // 70))
    glow = img.filter(ImageFilter.GaussianBlur(size // 28))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(glow)
    out.alpha_composite(img)
    return out


##
## Preview (approximates rEFInd's layout: centred row of big tiles, label, tools row)
##

def preview(bg, icons, sel):
    img = bg.convert("RGBA").copy()
    tile, gap = SEL_BIG, 8
    total = 2 * tile + gap
    x0 = (W - total) // 2
    y0 = (H - tile) // 2 + 10
    for i, ic in enumerate(icons):
        x = x0 + i * (tile + gap)
        if i == 0:
            img.alpha_composite(sel.resize((tile, tile)), (x, y0))
        icon = ic.resize((BIG_ICON, BIG_ICON), Image.LANCZOS)
        img.alpha_composite(icon, (x + (tile - BIG_ICON) // 2, y0 + (tile - BIG_ICON) // 2))
    d = ImageDraw.Draw(img)
    mono = None
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]:
        if os.path.exists(p):
            mono = ImageFont.truetype(p, 28)
    mono = mono or ImageFont.load_default()
    d.text((W // 2, y0 + tile + 36), "Batocera", font=mono, fill=(255, 255, 255), anchor="mm")
    # Tools row: reboot, shutdown, firmware (simple stand-ins for rEFInd's icons)
    ty = y0 + tile + 96
    for i, glyph in enumerate(["R", "O", "F"]):
        cx = W // 2 + (i - 1) * 90
        d.ellipse([cx - 30, ty - 30, cx + 30, ty + 30], outline=(230, 230, 240), width=4)
        d.text((cx, ty), glyph, font=font(26), fill=(230, 230, 240), anchor="mm")
    d.text((W - 24, H - 24), "preview - real layout may differ slightly per screen", font=font(18, False),
           fill=(255, 255, 255, 140), anchor="rs")
    return img.convert("RGB")


def main():
    os.makedirs(THEME, exist_ok=True)
    os.makedirs(DOCS, exist_ok=True)
    preview_only = "--preview-only" in sys.argv
    if preview_only and os.path.exists(os.path.join(THEME, "background.png")):
        bg = Image.open(os.path.join(THEME, "background.png"))
        icons = [Image.open(os.path.join(THEME, n)).convert("RGBA") for n in ("os_batocera.png", "os_steamos.png")]
        sel = Image.open(os.path.join(THEME, "selection_big.png")).convert("RGBA")
    else:
        bg = background()
        icons = [icon_batocera(), icon_steamos()]
        sel = selection(SEL_BIG)
        bg.save(os.path.join(THEME, "background.png"), optimize=True)
        icons[0].save(os.path.join(THEME, "os_batocera.png"), optimize=True)
        icons[1].save(os.path.join(THEME, "os_steamos.png"), optimize=True)
        sel.save(os.path.join(THEME, "selection_big.png"), optimize=True)
        selection(SEL_SMALL).save(os.path.join(THEME, "selection_small.png"), optimize=True)
    preview(bg, icons, sel).save(os.path.join(DOCS, "boot-menu-preview.png"), optimize=True)
    print("Theme written to", THEME, "and preview to", DOCS)


if __name__ == "__main__":
    main()
