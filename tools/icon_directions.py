"""Render candidate app icon directions as flat 1024px PNGs, for picking between.

Nothing here touches the asset catalog. It writes `notes/ui/icon-<name>.png` at 1024
plus one contact sheet at real home-screen sizes, because an icon is chosen at 60px and
admired at 1024. `tools/make_icon.py` is what builds the catalog, once a direction wins.

Every direction is flat: one ground colour, solid shapes, no gradient, no glow, no bevel.

    python3 tools/icon_directions.py
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

OUT_DIR = Path(__file__).resolve().parent.parent / "notes" / "ui"

CANVAS = 1024
SS = 4  # supersample, then LANCZOS down

INK = (0x0D, 0x0E, 0x10)       # near-black ground; not pure black, which flattens on glass
EMBER = (0xFF, 0x70, 0x38)     # the app's accent, unchanged
SLATE = (0x3B, 0x3F, 0x46)     # the muted member of a stack
SLATE_DIM = (0x2A, 0x2D, 0x33)


def _canvas(bg: tuple[int, int, int]) -> tuple[Image.Image, ImageDraw.ImageDraw, int]:
    size = CANVAS * SS
    img = Image.new("RGB", (size, size), bg)
    return img, ImageDraw.Draw(img), size


def _capsule(draw: ImageDraw.ImageDraw, x0, y0, x1, y1, fill) -> None:
    """A bar whose ends are true semicircles, drawn without relying on PIL's rounding."""
    r = (y1 - y0) / 2.0
    draw.rectangle((x0 + r, y0, x1 - r, y1), fill=fill)
    draw.ellipse((x0, y0, x0 + 2 * r, y1), fill=fill)
    draw.ellipse((x1 - 2 * r, y0, x1, y1), fill=fill)


def _capsule_v(draw: ImageDraw.ImageDraw, x0, y0, x1, y1, fill) -> None:
    """The same shape stood on its end."""
    r = (x1 - x0) / 2.0
    draw.rectangle((x0, y0 + r, x1, y1 - r), fill=fill)
    draw.ellipse((x0, y0, x1, y0 + 2 * r), fill=fill)
    draw.ellipse((x0, y1 - 2 * r, x1, y1), fill=fill)


def _thick_line(draw, points, width, fill) -> None:
    """A stroke stamped from overlapping discs.

    PIL's own joins leave a scalloped edge at this thickness, which reads as a caterpillar
    once the icon is downsampled. Stamping a disc per sample is slower and exactly round.
    """
    r = width / 2.0
    for x, y in points:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)
    draw.line(points, fill=fill, width=int(round(width)))


# --- direction 1: Groove -----------------------------------------------------------
# The record reduced to the only part of it that matters, drawn as one continuous line.
# No disc body, no grooves plural, no tonearm: one stroke from the edge to the centre.
# Two and a bit turns, not four, because the mark is chosen at 60 points.

def groove() -> Image.Image:
    img, draw, size = _canvas(INK)
    cx = cy = size / 2.0

    turns = 2.1
    r_outer, r_inner = 0.385 * size, 0.062 * size
    stroke = 0.062 * size

    points = []
    steps = 6000
    total = turns * 2 * math.pi
    for i in range(steps + 1):
        t = total * i / steps
        r = r_outer - (r_outer - r_inner) * (i / steps)
        angle = t - math.pi * 0.75  # the outer end opens at the top left, where a needle lands
        points.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))

    _thick_line(draw, points, stroke, EMBER)
    return img


# --- direction 2: Double T ---------------------------------------------------------
# A monogram, not a picture: a lowercase "tt" ligature, two stems through one crossbar,
# the second stem turning into a foot. Typographic marks are what serious small apps use,
# and it is the only one of the three that survives being described over the phone.

def doublet() -> Image.Image:
    img, draw, size = _canvas(INK)
    stem_w = 0.115 * size
    top, bottom = 0.150 * size, 0.812 * size
    left_x, right_x = 0.352 * size, 0.648 * size

    for cx in (left_x, right_x):
        _capsule_v(draw, cx - stem_w / 2, top, cx + stem_w / 2, bottom, EMBER)

    # The foot: the second stem turns right at the baseline, the way a "t" terminates.
    foot_h = stem_w
    _capsule(draw, right_x - stem_w / 2, bottom - foot_h,
             right_x + 0.215 * size, bottom, EMBER)

    # One crossbar through both stems, sitting where a "t" crosses rather than centred.
    bar_h = 0.098 * size
    bar_y = 0.352 * size
    _capsule(draw, 0.185 * size, bar_y, 0.815 * size, bar_y + bar_h, EMBER)
    return img


# --- direction 3: Cut --------------------------------------------------------------
# Inverted, so it is bright on a home screen rather than another dark square. One black
# disc with one band struck through it, in the ground colour: the disc reads as a record
# and the band reads as the cut being played. Two shapes, no handle, nothing to explain.

def cut() -> Image.Image:
    img, draw, size = _canvas(EMBER)
    cx = cy = size / 2.0
    r = 0.330 * size
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=INK)

    angle = math.radians(-19)
    ux, uy = math.cos(angle), math.sin(angle)
    reach = size  # past both edges, so the band is a cut and not a stripe laid on top
    # Well off centre. A band through the middle at 45 degrees is the prohibition sign;
    # a thin crescent sliced off one side is a cut.
    offset = 0.178 * size
    mx, my = cx - uy * offset, cy + ux * offset
    _thick_line(draw,
                [(mx - ux * reach, my - uy * reach), (mx + ux * reach, my + uy * reach)],
                0.098 * size, EMBER)
    return img


DIRECTIONS = {"groove": groove, "doublet": doublet, "cut": cut}
PREVIEW_SIZES = (180, 120, 87, 60)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rendered = {}
    for name, build in DIRECTIONS.items():
        master = build().resize((CANVAS, CANVAS), Image.LANCZOS)
        master.save(OUT_DIR / f"icon-{name}.png")
        rendered[name] = master
        print(f"wrote notes/ui/icon-{name}.png")

    # One sheet at the sizes an icon is actually judged at, on a neutral ground.
    pad, gutter = 40, 34
    row_h = max(PREVIEW_SIZES) + gutter
    width = pad * 2 + sum(PREVIEW_SIZES) + gutter * (len(PREVIEW_SIZES) - 1)
    sheet = Image.new("RGB", (width, pad * 2 + row_h * len(rendered)), (0x8A, 0x8A, 0x90))
    for row, master in enumerate(rendered.values()):
        x = pad
        y = pad + row * row_h
        for px in PREVIEW_SIZES:
            sheet.paste(master.resize((px, px), Image.LANCZOS), (x, y))
            x += px + gutter
    sheet.save(OUT_DIR / "icon-preview-sizes.png")
    print("wrote notes/ui/icon-preview-sizes.png")


if __name__ == "__main__":
    main()
