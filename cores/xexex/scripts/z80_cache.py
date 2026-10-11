#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Misses of the Z80 program cache (jtframe's direct-mapped BRAM cache on the snd bus),
from the Z80's program reads in MAME.

    python scripts/z80_cache.py xexex --frames 3000               # attract
    python scripts/z80_cache.py xexex --coin 900 --frames 3000 --tag _play

Misses are the SDRAM reads the cache leaves on bank 1, which it shares with the
K053250 and the K054539. Scanlines are counted only when they have a miss.
"""
import argparse
from mame_run import WORK, run


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--size", type=int, default=16384)
    ap.add_argument("--lines", default="4,8")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=3000)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    for g in a.sets:
        out = WORK / f"z80cache-{g}{a.tag}"
        path = out / "z80cache.txt"
        path.unlink(missing_ok=True)
        run(g, "z80cache.lua", out, {"ZC_SIZE": str(a.size), "ZC_LINES": a.lines,
                                     "ZC_SKIP": str(a.skip), "ZC_FRAMES": str(a.frames),
                                     "ZC_COIN": str(a.coin)})
        if not path.exists():
            print(f"{g}{a.tag}: no result")
            continue
        d = {}
        for ln in path.read_text().splitlines():
            k, *v = ln.split()
            d.setdefault(k, []).append(v)
        reads, frames = int(d["reads"][0][0]), int(d["frames"][0][0])
        print(f"{g}{a.tag}: {frames} frames, {reads} Z80 program reads "
              f"({reads / frames / 289:.1f} a scanline), cache {a.size} bytes")
        for (L, _, miss, _, mx), (_, hist) in zip(d["line"], d["perline"]):
            miss = int(miss)
            h = [int(x) for x in hist.split(",")]
            print(f"  {L}-byte lines: {miss} misses, {100 * miss / max(reads, 1):.2f} % of reads, "
                  f"{miss / frames / 289:.2f} a scanline on average, at most {mx} in one scanline")
            print(f"    scanlines with 1-3 / 4-15 / 16+ misses: {sum(h[1:4])} / {sum(h[4:16])} / {sum(h[16:])}")


if __name__ == "__main__":
    main()
