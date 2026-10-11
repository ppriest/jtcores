#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""When the game writes each video region, by scanline relative to vblank, in MAME.

    python scripts/write_timing.py xexex --skip 600 --frames 1800
    python scripts/write_timing.py xexex --coin 600 --skip 1500 --frames 1800 --tag _play
    python scripts/write_timing.py xexex --reuse            # re-print from work/mame/

Counts writes to every region in mame_run.REGIONS (or --regions) by line over
--frames frames after --skip. Raw result work/mame/wtiming-<set><tag>/wtiming.txt,
closing snapshot in its snap/ folder.

Report per region: writes a frame; frames with a write; share in vblank (lines
256-288); share in the first 24 lines of vblank; the shortest window of lines
holding 99% of the writes (MAME line numbers, may wrap); and a strip of 8-line
columns starting at vblank (' ' none, '.' under 1%, 0-9 tenths, '#' over 90%).
"""
import argparse
from pathlib import Path

from mame_run import VBSTART, VTOTAL, WORK, run, taps


def parse(path):
    d = {"hist": {}, "last": {}, "nfr": {}}
    for line in Path(path).read_text().splitlines():
        if line.startswith("#"):
            continue
        k, _, v = line.partition(" ")
        if k in ("vtotal", "frames", "errors"):
            d[k] = int(v)
        else:
            name, _, vals = v.partition(" ")
            d[k][name] = int(vals) if k == "nfr" else [int(x) for x in vals.split(",")]
    return d


def window(h, share=0.99):
    """Shortest circular run of lines holding `share` of the writes -> (first, last)."""
    n, total = len(h), sum(h)
    best = None
    for start in range(n):
        acc = 0
        for ln in range(n):
            acc += h[(start + ln) % n]
            if acc >= share * total:
                if best is None or ln < best[1] - best[0]:
                    best = (start, start + ln)
                break
    return best[0], best[1] % n


def report(title, d):
    vt, nf = d["vtotal"], d["frames"]
    blank = VTOTAL - VBSTART
    print(f"{title}: {vt} lines, vblank {VBSTART}-{vt - 1}, {nf} frames, lua errors {d.get('errors', 0)}")
    print(f"  {'region':8s} {'/frame':>8s} {'frames':>6s} {'vblank':>6s} {'vb+0..23':>8s} "
          f"{'99% in lines':>13s}  from line {VBSTART}, 8 lines a column")
    for name, h in d["hist"].items():
        total = sum(h)
        if not total:
            print(f"  {name:8s} {0:8.1f} {0:6d}")
            continue
        rel = [h[(i + VBSTART) % vt] for i in range(vt)]
        strip = ""
        for b in range(0, vt, 8):
            f = sum(rel[b:b + 8]) / total
            strip += " " if f == 0 else "." if f < 0.01 else "#" if f > 0.9 else str(min(9, int(f * 10)))
        pct = lambda k: 100.0 * sum(rel[:k]) / total  # noqa: E731
        lo, hi = window(h)
        print(f"  {name:8s} {total / nf:8.1f} {d['nfr'].get(name, 0):6d} {pct(blank):5.1f}% "
              f"{pct(24):7.1f}% {lo:6d}-{hi:<6d}  |{strip}|")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0, help="play from this frame; counting still starts at --skip")
    ap.add_argument("--regions", default=None, help="comma-separated subset of mame_run.REGIONS")
    ap.add_argument("--snaps", default="", help="extra snapshot frames, comma-separated")
    ap.add_argument("--tag", default="")
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args()
    for g in a.sets:
        out = WORK / f"wtiming-{g}{a.tag}"
        path = out / "wtiming.txt"
        if not (a.reuse and path.exists()):
            path.unlink(missing_ok=True)
            run(g, "wtiming.lua", out, {
                "WT_TAPS": taps(a.regions.split(",") if a.regions else None),
                "WT_SKIP": str(a.skip), "WT_FRAMES": str(a.frames), "WT_COIN": str(a.coin),
                "WT_SNAPS": a.snaps})
        if not path.exists():
            print(f"{g}{a.tag}: no result (MAME failed?)\n")
            continue
        extra = f", coin at frame {a.coin}" if a.coin else ""
        report(f"{g}{a.tag} (skip {a.skip}{extra})", parse(path))


if __name__ == "__main__":
    main()
