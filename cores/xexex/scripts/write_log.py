#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Log every write to chosen regions, with frame, scanline and PC, in MAME.

    python scripts/write_log.py xexex --regions k053252 --frames 600
    python scripts/write_log.py xexex --regions lvcreg,ctrl2 --frames 3000 --coin 600

    python scripts/write_log.py xexex --regions vreg --summary --from 1500 [--reuse]

Regions are names from mame_run.REGIONS. Output work/mame/wlog-<set><tag>/writes.log,
one write a line: frame, line, address, data, mask, PC (hex). --summary prints, per
address, writes, frames written, share in vblank (256-288), the shortest window of
lines holding 99% of its writes, and the PCs that wrote it.
"""
import argparse
from collections import Counter, defaultdict

from mame_run import VBSTART, WORK, run, taps
from write_timing import window


def summary(path, first):
    by = defaultdict(lambda: {"h": [0] * 289, "fr": set(), "pc": Counter()})
    for line in open(path):
        if line.startswith("#"):
            continue
        fr, ln, addr, _data, _mask, pc = line.split()
        if int(fr) < first:
            continue
        d = by[addr]
        d["h"][int(ln)] += 1
        d["fr"].add(fr)
        d["pc"][pc] += 1
    print(f"{'addr':6s} {'writes':>7s} {'frames':>6s} {'vblank':>6s} {'99% in lines':>13s}  PCs")
    for addr in sorted(by):
        d = by[addr]
        n = sum(d["h"])
        lo, hi = window(d["h"])
        vb = 100.0 * sum(d["h"][VBSTART:]) / n
        pcs = " ".join(f"{p}:{c}" for p, c in d["pc"].most_common(4))
        print(f"{addr} {n:7d} {len(d['fr']):6d} {vb:5.1f}% {lo:6d}-{hi:<6d}  {pcs}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--regions", required=True, help="comma-separated names from mame_run.REGIONS")
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--coin", type=int, default=0, help="play from this frame (0 = attract)")
    ap.add_argument("--tag", default="")
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--from", dest="first", type=int, default=0, help="summary: from this frame")
    ap.add_argument("--reuse", action="store_true", help="summarise the existing log")
    a = ap.parse_args()
    out = WORK / f"wlog-{a.set}{a.tag}"
    if a.reuse:
        return summary(out / "writes.log", a.first)
    run(a.set, "wlog.lua", out, {"WL_TAPS": taps(a.regions.split(",")),
                                 "WL_FRAMES": str(a.frames), "WL_COIN": str(a.coin)})
    print(out / "writes.log")
    if a.summary:
        summary(out / "writes.log", a.first)


if __name__ == "__main__":
    main()
