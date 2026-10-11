#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a bench/video frame (.ppm) with MAME's (snap-<frame>.png): the pixels that
differ over the lines both show, at the x/y offset that aligns them best, and an image
of MAME | RTL | differences (bright where they differ).

    python bench/video/cmp_frame.py rtl.ppm mame.png out.png"""
import sys

import numpy as np
from PIL import Image


def main():
    r = np.array(Image.open(sys.argv[1]).convert("RGB")).astype(int)
    m = np.array(Image.open(sys.argv[2]).convert("RGB")).astype(int)
    best = None
    for dy in range(-4, 5):
        for dx in range(-4, 5):
            h = min(r.shape[0], m.shape[0] - max(dy, 0)) - max(-dy, 0)
            w = min(r.shape[1], m.shape[1]) - abs(dx)
            a = r[max(-dy, 0):max(-dy, 0) + h, max(-dx, 0):max(-dx, 0) + w]
            b = m[max(dy, 0):max(dy, 0) + h, max(dx, 0):max(dx, 0) + w]
            d = np.any(a != b, -1)
            if best is None or d.sum() < best[0]:
                best = (int(d.sum()), dx, dy, a, b, d)
    n, dx, dy, a, b, d = best
    print(f"{n} of {d.size} pixels differ at offset x {dx:+d} y {dy:+d}")
    diff = np.where(d[..., None], b, b // 4)
    Image.fromarray(np.concatenate([b, a, diff], 1).astype(np.uint8)).save(sys.argv[3])


if __name__ == "__main__":
    main()
