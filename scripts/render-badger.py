#!/usr/bin/env python3
"""Derive the honey-badger icon set from the master artwork.

    python3 scripts/render-badger.py docs/badger/honey-badger-source.png

Writes docs/badger/honey-badger-<px>.png (1024..16, transparent
corners outside the badge circle) and docs/badger/favicon.ico
(16/32/48). The source PNG is the generated master; derived
files are committed and copied into every public export.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

SIZES = [1024, 512, 256, 180, 128, 64, 48, 32, 16]


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/badger/honey-badger-source.png")
    out_dir = src.parent
    img = Image.open(src).convert("RGB")
    # Crop to the badge circle: bounding box of non-white pixels.
    gray = img.convert("L")
    mask = gray.point(lambda p: 255 if p < 240 else 0)
    box = mask.getbbox()
    if box is None:
        raise SystemExit("render-badger: no non-white content found")
    cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
    half = max(box[2] - box[0], box[3] - box[1]) // 2
    img = img.crop((cx - half, cy - half, cx + half, cy + half))
    master = img.resize((1024, 1024), Image.LANCZOS).convert("RGBA")
    # Transparent corners outside the circle.
    alpha = Image.new("L", (1024, 1024), 0)
    ImageDraw.Draw(alpha).ellipse([0, 0, 1023, 1023], fill=255)
    master.putalpha(alpha)
    for size in SIZES:
        frame = master if size == 1024 else master.resize((size, size), Image.LANCZOS)
        dest = out_dir / f"honey-badger-{size}.png"
        frame.save(dest)
        print(f"render-badger: wrote {dest} ({size}x{size})")
    ico = out_dir / "favicon.ico"
    master.save(ico, sizes=[(16, 16), (32, 32), (48, 48)])
    print(f"render-badger: wrote {ico} (16/32/48)")


if __name__ == "__main__":
    main()
