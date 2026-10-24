#!/usr/bin/env python3
"""Render docs/social-preview.png (1280x640 GitHub social card).

Deterministic Pillow text card; regenerate with:
    python3 scripts/render-social.py docs/social-preview.png
The PNG is committed once and reused by every public export.
"""
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
BG = (13, 27, 42)
FG = (230, 240, 248)
ACCENT = (56, 189, 248)
MUTED = (148, 175, 196)


def font(size, bold=True):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold
        else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "docs/social-preview.png"
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([48, 48, W - 48, H - 48], 28, outline=ACCENT, width=3)
    d.text((96, 92), "gRPC in the browser", font=font(76), fill=FG)
    d.text((96, 188), "over WebRTC DataChannels", font=font(62), fill=ACCENT)
    d.multiline_text(
        (96, 292),
        "Dependency-free generated clients & servers\n"
        "JavaScript · Go · Rust · Python + 12 more languages",
        font=font(36, bold=False), fill=MUTED, spacing=14)
    d.text((96, 452), "No grpc-web proxy. No external runtime.",
           font=font(36), fill=FG)
    d.text((96, 528), "browser-grpc.github.io/grpc-over-datachannels",
           font=font(30, bold=False), fill=ACCENT)
    try:
        badger = Image.open("docs/badger/honey-badger-1024.png").convert("RGBA")
        badger = badger.resize((230, 230), Image.LANCZOS)
        img.paste(badger, (990, 345), badger)
    except OSError:
        pass  # text-only card still valid
    img.save(out)
    print(f"render-social: wrote {out} ({W}x{H})")


if __name__ == "__main__":
    main()
