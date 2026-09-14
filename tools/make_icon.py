"""Generate the Turntable iOS app icon set.

Draws a single flat-design icon (a vinyl disc with concentric grooves, a
terracotta centre label, a spindle hole, and a light-grey tonearm resting
over the grooves) on a near-black background. The icon is rendered once at
4096x4096 (4x supersampling) and LANCZOS-downsampled to every size Xcode
needs for iPhone, iPad and the App Store marketing icon. All PNGs and a
matching Contents.json are written straight into
Turntable/Assets.xcassets/AppIcon.appiconset/, replacing whatever was there.

Run with:

    python3 tools/make_icon.py
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Paths

REPO_ROOT = Path(__file__).resolve().parent.parent
ICONSET_DIR = REPO_ROOT / "Turntable" / "Assets.xcassets" / "AppIcon.appiconset"

# ---------------------------------------------------------------------------
# Design constants (fractions of canvas width unless noted)

CANVAS = 1024  # final "1x" reference size
SUPERSAMPLE = 4  # render at CANVAS * SUPERSAMPLE, then downsample

BG = (0x0E, 0x0F, 0x12)  # near-black background
DISC = (0x1C, 0x1F, 0x24)  # graphite disc body
GROOVE = (0x2A, 0x2E, 0x35)  # groove rings
ACCENT = (0xC7, 0x5C, 0x38)  # terracotta centre label
ARM = (0xC9, 0xCD, 0xD4)  # tonearm + pivot

DISC_RADIUS_FRAC = 0.37  # 74% diameter
GROOVE_INNER_FRAC = 0.22
GROOVE_OUTER_FRAC = 0.36
GROOVE_COUNT = 14
GROOVE_WIDTH_FRAC = 1.0 / CANVAS  # 1px-equivalent at final 1024 scale

LABEL_RADIUS_FRAC = 0.12
SPINDLE_RADIUS_FRAC = 0.016

ARM_THICKNESS_FRAC = 0.021
PIVOT_RADIUS_FRAC = 0.034
PIVOT_X_FRAC = 0.78
PIVOT_Y_FRAC = 0.20
# Distance from dead centre where the tonearm's near end rests. Just past the
# label edge (0.12), so the arm reads as reaching across the record rather than
# as a pin dropped on it.
ARM_NEAR_RADIUS_FRAC = 0.135

# ---------------------------------------------------------------------------
# Asset catalog entries: (idiom, point size string, scale, point size as float)

ICON_ENTRIES = [
    ("iphone", "20x20", "2x", 20.0),
    ("iphone", "20x20", "3x", 20.0),
    ("iphone", "29x29", "2x", 29.0),
    ("iphone", "29x29", "3x", 29.0),
    ("iphone", "40x40", "2x", 40.0),
    ("iphone", "40x40", "3x", 40.0),
    ("iphone", "60x60", "2x", 60.0),
    ("iphone", "60x60", "3x", 60.0),
    ("ipad", "20x20", "1x", 20.0),
    ("ipad", "20x20", "2x", 20.0),
    ("ipad", "29x29", "1x", 29.0),
    ("ipad", "29x29", "2x", 29.0),
    ("ipad", "40x40", "1x", 40.0),
    ("ipad", "40x40", "2x", 40.0),
    ("ipad", "76x76", "1x", 76.0),
    ("ipad", "76x76", "2x", 76.0),
    ("ipad", "83.5x83.5", "2x", 83.5),
    ("ios-marketing", "1024x1024", "1x", 1024.0),
]


def _fmt_pt(pt: float) -> str:
    return str(int(pt)) if pt.is_integer() else str(pt)


def _filename_for(pt: float, scale: str) -> str:
    if pt == 1024.0:
        return "icon-1024.png"
    return f"icon-{_fmt_pt(pt)}@{scale}.png"


def _pixel_size(pt: float, scale: str) -> int:
    return round(pt * int(scale[0]))


# ---------------------------------------------------------------------------
# Drawing


def render_master() -> Image.Image:
    size = CANVAS * SUPERSAMPLE
    cx = cy = size / 2.0
    img = Image.new("RGB", (size, size), BG)
    draw = ImageDraw.Draw(img)

    def bbox(radius: float) -> tuple[float, float, float, float]:
        return (cx - radius, cy - radius, cx + radius, cy + radius)

    # Disc body.
    draw.ellipse(bbox(DISC_RADIUS_FRAC * size), fill=DISC)

    # Concentric groove rings.
    groove_width = max(1, round(GROOVE_WIDTH_FRAC * size))
    if GROOVE_COUNT > 1:
        step = (GROOVE_OUTER_FRAC - GROOVE_INNER_FRAC) / (GROOVE_COUNT - 1)
    else:
        step = 0.0
    for i in range(GROOVE_COUNT):
        r = (GROOVE_INNER_FRAC + step * i) * size
        draw.ellipse(bbox(r), outline=GROOVE, width=groove_width)

    # Centre label.
    draw.ellipse(bbox(LABEL_RADIUS_FRAC * size), fill=ACCENT)

    # Spindle hole.
    draw.ellipse(bbox(SPINDLE_RADIUS_FRAC * size), fill=BG)

    # Tonearm: pivot near the upper-right corner, bar running toward the
    # centre and stopping short of it, resting over the groove band.
    pivot = (PIVOT_X_FRAC * size, PIVOT_Y_FRAC * size)
    center = (cx, cy)
    dx, dy = center[0] - pivot[0], center[1] - pivot[1]
    length = (dx * dx + dy * dy) ** 0.5
    ux, uy = dx / length, dy / length
    near_end = (
        center[0] - ux * ARM_NEAR_RADIUS_FRAC * size,
        center[1] - uy * ARM_NEAR_RADIUS_FRAC * size,
    )

    thickness = max(1, round(ARM_THICKNESS_FRAC * size))
    draw.line([pivot, near_end], fill=ARM, width=thickness)
    # Round the near-end cap.
    cap_r = thickness / 2.0
    draw.ellipse(
        (
            near_end[0] - cap_r,
            near_end[1] - cap_r,
            near_end[0] + cap_r,
            near_end[1] + cap_r,
        ),
        fill=ARM,
    )
    # Pivot disc (drawn last so it fully covers the bar's far end).
    pivot_r = PIVOT_RADIUS_FRAC * size
    draw.ellipse(
        (
            pivot[0] - pivot_r,
            pivot[1] - pivot_r,
            pivot[0] + pivot_r,
            pivot[1] + pivot_r,
        ),
        fill=ARM,
    )

    return img


def build_contents_json(files_by_key: dict) -> dict:
    images = []
    for idiom, size_str, scale, pt in ICON_ENTRIES:
        images.append(
            {
                "filename": files_by_key[(pt, scale)],
                "idiom": idiom,
                "scale": scale,
                "size": size_str,
            }
        )
    return {"images": images, "info": {"version": 1, "author": "xcode"}}


def main() -> None:
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)

    master = render_master()

    # Unique (pt, scale) pairs -> filename -> rendered PNG bytes.
    unique_pairs = sorted({(pt, scale) for _, _, scale, pt in ICON_ENTRIES})
    files_by_key: dict = {}
    wanted_filenames: set[str] = set()

    for pt, scale in unique_pairs:
        filename = _filename_for(pt, scale)
        files_by_key[(pt, scale)] = filename
        wanted_filenames.add(filename)
        px = _pixel_size(pt, scale)
        resized = master.resize((px, px), Image.LANCZOS)
        out_path = ICONSET_DIR / filename
        resized.save(out_path, format="PNG")

    wanted_filenames.add("Contents.json")

    # Remove anything the new manifest does not reference.
    for existing in ICONSET_DIR.iterdir():
        if existing.name not in wanted_filenames:
            existing.unlink()

    contents = build_contents_json(files_by_key)
    contents_path = ICONSET_DIR / "Contents.json"
    with open(contents_path, "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
