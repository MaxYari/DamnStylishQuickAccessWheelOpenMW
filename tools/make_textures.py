#!/usr/bin/env python3
"""Draws the wheel's clock-like hand into textures/MaxYari/quick access wheel/:
arrow.png (its head), shaft.png (its shaft) and hub.png (the pin it turns on).

Everything else on the wheel is vanilla Morrowind UI (the MWUI box templates,
menu_icon_equip / menu_icon_magic backgrounds, item and spell icons); the hand
is the one thing vanilla has no art for. OpenMW 0.51 UI images can't be
rotated, so the head and shaft are atlases of ARROW_FRAMES pre-rotated frames,
frame k pointing at k * 360 / ARROW_FRAMES degrees counter-clockwise from
screen right. player.lua picks frames with the same constants. Every sheet
must stay a power of two on both sides: OpenMW rescales any other size, which
shifts every frame. Colours are vanilla's FontColor_color_normal with a dark
outline, like the menu ornaments. They are drawn clean: the hand's wear is a
large-scale shading along the whole hand that player.lua puts on each piece.

Plain Python (zlib + struct), no PIL. Shapes are anti-aliased from their
signed distance, so one sample per pixel is enough.
"""

import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "textures", "MaxYari", "quick access wheel")

GOLD = (202, 165, 96)
DARK = (14, 10, 6)

ARROW_FRAMES = 64
ARROW_COLS = 8
ARROW_CELL = 64
# Shaft pieces, in cell pixels: half the distance between the cap centres, and the gold's radius.
# Short, so the shading player.lua gives each piece changes in small steps along the shaft.
SHAFT_HALF_LENGTH = 5
SHAFT_RADIUS = 3


def write_png(path, width, height, pixels):
    """pixels: flat list of (r, g, b, a) floats in 0..1, row by row."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw += bytes(max(0, min(255, round(v * 255))) for v in pixels[y * width + x])

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("wrote", os.path.relpath(path, os.path.join(HERE, "..")), f"{width}x{height}")


def coverage(sd):
    """Signed distance (negative inside) -> pixel coverage."""
    return max(0.0, min(1.0, 0.5 - sd))


def over(dst, src):
    """Straight-alpha 'src over dst'."""
    sr, sg, sb, sa = src
    dr, dg, db, da = dst
    a = sa + da * (1 - sa)
    if a <= 0:
        return (0.0, 0.0, 0.0, 0.0)
    return (
        (sr * sa + dr * da * (1 - sa)) / a,
        (sg * sa + dg * da * (1 - sa)) / a,
        (sb * sa + db * da * (1 - sa)) / a,
        a,
    )


def polygon_sd(px, py, pts):
    """Signed distance to a simple polygon (negative inside)."""
    d = float("inf")
    inside = False
    n = len(pts)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        wx, wy = px - ax, py - ay
        t = max(0.0, min(1.0, (wx * ex + wy * ey) / (ex * ex + ey * ey)))
        d = min(d, math.hypot(wx - ex * t, wy - ey * t))
        if (ay > py) != (by > py) and px < ax + (py - ay) / (by - ay) * (bx - ax):
            inside = not inside
    return -d if inside else d


def arrow_atlas():
    rows = math.ceil(ARROW_FRAMES / ARROW_COLS)
    w, h = ARROW_COLS * ARROW_CELL, rows * ARROW_CELL
    pixels = [(0.0, 0.0, 0.0, 0.0)] * (w * h)
    gold = tuple(v / 255 for v in GOLD)
    dark = tuple(v / 255 for v in DARK)
    # Arrowhead pointing along +x, in cell pixels from the cell centre: a chevron with a notch.
    head = [(24, 0), (-12, -17), (-4, 0), (-12, 17)]
    c = ARROW_CELL / 2
    for k in range(ARROW_FRAMES):
        angle = 2 * math.pi * k / ARROW_FRAMES
        ca, sa = math.cos(angle), math.sin(angle)
        # Screen y grows downward, so a counter-clockwise screen angle flips the y.
        pts = [(x * ca - y * sa, -(x * sa + y * ca)) for x, y in head]
        ox, oy = (k % ARROW_COLS) * ARROW_CELL, (k // ARROW_COLS) * ARROW_CELL
        for y in range(ARROW_CELL):
            for x in range(ARROW_CELL):
                sd = polygon_sd(x + 0.5 - c, y + 0.5 - c, pts)
                px = (*dark, 0.9 * coverage(sd - 2.5))
                px = over(px, (*gold, coverage(sd)))
                pixels[(oy + y) * w + ox + x] = px
    return w, h, pixels


def capsule_sd(px, py, angle, half_length, radius):
    """Signed distance to a capsule through the cell centre, pointing at `angle` (screen, y down)."""
    dx, dy = math.cos(angle) * half_length, -math.sin(angle) * half_length
    t = max(-1.0, min(1.0, (px * dx + py * dy) / (half_length * half_length)))
    return math.hypot(px - dx * t, py - dy * t) - radius


def shaft_atlas():
    """The hand's shaft, as short pre-rotated capsules that player.lua lines up along the hand.

    Rows 0-7 are the dark outlines, rows 8-15 the gold fills: drawing every outline before any
    fill makes the overlapping pieces read as one unbroken shaft.
    """
    rows = math.ceil(ARROW_FRAMES / ARROW_COLS)
    w, h = ARROW_COLS * ARROW_CELL, 2 * rows * ARROW_CELL
    pixels = [(0.0, 0.0, 0.0, 0.0)] * (w * h)
    gold = tuple(v / 255 for v in GOLD)
    dark = tuple(v / 255 for v in DARK)
    c = ARROW_CELL / 2
    # The outline is opaque: the pieces overlap, and a see-through one would darken at every joint.
    for layer, (colour, alpha, radius) in enumerate(((dark, 1.0, SHAFT_RADIUS + 2.5), (gold, 1.0, SHAFT_RADIUS))):
        for k in range(ARROW_FRAMES):
            angle = 2 * math.pi * k / ARROW_FRAMES
            ox = (k % ARROW_COLS) * ARROW_CELL
            oy = (layer * rows + k // ARROW_COLS) * ARROW_CELL
            for y in range(ARROW_CELL):
                for x in range(ARROW_CELL):
                    sd = capsule_sd(x + 0.5 - c, y + 0.5 - c, angle, SHAFT_HALF_LENGTH, radius)
                    pixels[(oy + y) * w + ox + x] = (*colour, alpha * coverage(sd))
    return w, h, pixels


def hub():
    """The pin the hand turns on: a gold ring with a stud, outlined dark."""
    size = 64
    c = size / 2
    gold = tuple(v / 255 for v in GOLD)
    dark = tuple(v / 255 for v in DARK)
    pixels = []
    for y in range(size):
        for x in range(size):
            r = math.hypot(x + 0.5 - c, y + 0.5 - c)
            px = (*dark, 0.9 * coverage(r - 29))
            px = over(px, (*gold, coverage(abs(r - 22) - 3.5)))
            px = over(px, (*gold, coverage(r - 8)))
            pixels.append(px)
    return size, size, pixels


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, make in (("arrow.png", arrow_atlas), ("shaft.png", shaft_atlas), ("hub.png", hub)):
        w, h, pixels = make()
        write_png(os.path.join(OUT, name), w, h, pixels)


if __name__ == "__main__":
    main()
