"""Generate the Turntable iOS app icon set from the chosen direction.

The direction is **Cut**, picked 2026-09-14: an ember ground with one black disc and
one band struck through it in the ground colour. The disc reads as a record, the band
as the cut being played. It is the one candidate that is bright, so it does not land on
a home screen as another dark square.

The shape itself is not redrawn here. It is imported from `tools/icon_directions.py`,
where all three candidates live, so the icon that ships and the icon that was picked
cannot drift apart. That module renders at 4096x4096 (4x supersampling); this one
LANCZOS-downsamples it to every size Xcode needs for iPhone, iPad and the App Store
marketing icon, and writes the PNGs plus a matching Contents.json straight into
Turntable/Assets.xcassets/AppIcon.appiconset/, replacing whatever was there.

To ship a different direction, change DIRECTION below to another key of
icon_directions.DIRECTIONS.

Run with:

    python3 tools/make_icon.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from icon_directions import DIRECTIONS  # noqa: E402

# ---------------------------------------------------------------------------
# Paths

REPO_ROOT = Path(__file__).resolve().parent.parent
ICONSET_DIR = REPO_ROOT / "Turntable" / "Assets.xcassets" / "AppIcon.appiconset"

# The owner's pick. See the module docstring.
DIRECTION = "cut"

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

    master = DIRECTIONS[DIRECTION]()  # full supersampled size

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
