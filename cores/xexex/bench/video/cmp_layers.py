#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare bench/video's tile layers (<prefix>-lyr<L>.bin) with scripts/video_model.py's
(layers.npz): finds the x/y offset that aligns them best, then counts the pixels that
differ in pen, colour or alpha flag.

    python bench/video/cmp_layers.py <prefix> <model dir> [width]"""
import sys

import numpy as np


def main():
    prefix, mdir = sys.argv[1], sys.argv[2]
    w = int(sys.argv[3]) if len(sys.argv) > 3 else 384
    m = np.load(f"{mdir}/layers.npz")
    for l in range(4):
        raw = np.fromfile(f"{prefix}-lyr{l}.bin", "<u2")
        r = raw.reshape(-1, w)
        rp, rc, ra = r & 0xf, r >> 4 & 0xf, r >> 8 & 1
        mp, mc, ma = m[f"pen{l}"], m[f"col{l}"], m[f"alp{l}"]
        best = None
        for dy in range(-8, 9):
            for dx in range(-8, 9):
                h = min(r.shape[0], mp.shape[0] - max(dy, 0)) - max(-dy, 0)
                ys = slice(max(-dy, 0), max(-dy, 0) + h)
                ym = slice(max(dy, 0), max(dy, 0) + h)
                xs = slice(max(-dx, 0), w - max(dx, 0))
                xm = slice(max(dx, 0), w - max(-dx, 0))
                a, b = rp[ys, xs], mp[ym, xm]
                d = (a != b) | ((b != 0) & ((rc[ys, xs] != mc[ym, xm]) | (ra[ys, xs] != ma[ym, xm])))
                n = int(d.sum())
                if best is None or n < best[0]:
                    best = (n, dx, dy, d.size, int((b != 0).sum()))
        n, dx, dy, size, opaque = best
        print(f"layer {l}: {n} of {size} pixels differ at offset x {dx:+d} y {dy:+d} "
              f"(model opaque {opaque})")


if __name__ == "__main__":
    main()
