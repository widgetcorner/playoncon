#!/usr/bin/env python3
"""Regenerate assets/images/venue-map-dark.png from venue-map.png.

Duotone luminance inversion tuned to the "campground at night" dark theme:
white ground -> deep pine, black roads/text/icons -> cream, grey buildings ->
dark sage; bluish pixels (Lay Lake + its label) map to night-lake blues
instead. Geometry is untouched, so hotspot rects and the GPS affine fit in
the app apply to both variants unchanged.

Run after editing the light map:  python3 scripts/make-dark-map.py
Requires: pip install Pillow
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'assets/images/venue-map.png'
DST = ROOT / 'assets/images/venue-map-dark.png'

PINE = (0x1B, 0x26, 0x20)     # was white ground
CREAM = (0xD8, 0xCB, 0xA8)    # was black roads/text
LAKE_HI = (0x24, 0x3A, 0x52)  # was light lake blue
LAKE_LO = (0x8F, 0xB4, 0xD8)  # was dark blue marks (lake label text)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    src = Image.open(SRC).convert('RGB')
    px = src.load()
    w, h = src.size
    out = Image.new('RGB', (w, h))
    po = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if b > r + 12 and b > g + 6:  # bluish -> lake tones
                t = (r + g + b) / (3 * 255.0)
                po[x, y] = lerp(LAKE_LO, LAKE_HI, t ** 0.8)
            else:
                lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                po[x, y] = lerp(CREAM, PINE, lum ** 0.7)  # mids toward pine
    out.save(DST, optimize=True)
    print(f'wrote {DST} ({w}x{h})')


if __name__ == '__main__':
    main()
