#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""K053250 mode, orientation and zoom per frame, as MAME draws it.

    python scripts/k053250_survey.py xexex --frames 30000 [--coin 600 --tag _play]
    python scripts/k053250_survey.py xexex --reuse [--tag _play]

Per-frame log work/mame/k053250-<set><tag>/k053250.txt (see scripts/mame/k053250.lua),
snapshots in its snap/ folder. Report: frames per reg-4 value, drawn frames split
normal / rotated, zoom range per value, the line of the DMA edge, and runs of frames
with the same value (runs under --min frames are left out of the run table).
"""
import argparse
from collections import Counter, defaultdict

from mame_run import WORK, run


def decode(ctrl):
    return (f"{'rot' if not ctrl & 1 else 'nor'} w{ctrl >> 5}"
            f"{' fx' if ctrl & 8 else ''}{' fy' if ctrl & 0x10 else ''}{' noclip' if ctrl & 4 else ''}")


def load(path):
    rows, snaps = [], []
    for line in open(path):
        if line.startswith("# snap"):
            p = line.split()
            snaps.append((int(p[2]), int(p[4]), p[6]))
        elif not line.startswith("#"):
            f, c, sx, sy, dr, zl, zh, z40, nd, dl = line.split()
            rows.append((int(f), int(c, 16), int(sx), int(sy), int(dr), int(zl), int(zh),
                         int(z40), int(nd), int(dl)))
    return rows, snaps


def report(rows, snaps, min_run):
    key = lambda c: c & 0xfd  # noqa: E731  bit 1 is the DMA strobe
    print(f"{len(rows)} frames, {rows[0][0]}-{rows[-1][0]}")
    per = defaultdict(lambda: {"fr": 0, "drawn": 0, "zl": 1 << 20, "zh": -1, "lines": Counter(), "z40": 0, "dl": 0})
    for f, c, sx, sy, dr, zl, zh, z40, nd, dl in rows:
        p = per[key(c)]
        p["fr"] += 1
        if dr:
            p["drawn"] += 1
            p["zl"], p["zh"] = min(p["zl"], zl), max(p["zh"], zh)
            p["z40"] += z40
            p["dl"] += dr
    print(f"\n{'reg4&fd':7s} {'decoded':22s} {'frames':>7s} {'drawn':>7s} {'zoom min':>8s} {'zoom max':>8s} {'z=40 share':>10s}")
    for k in sorted(per):
        p = per[k]
        zr = (f"{p['zl']:8x} {p['zh']:8x} {100.0 * p['z40'] / p['dl']:9.1f}%" if p["drawn"] else
              f"{'-':>8s} {'-':>8s} {'-':>10s}")
        print(f"{k:02x}      {decode(k):22s} {p['fr']:7d} {p['drawn']:7d} {zr}")
    print("\ndrawn frames by their largest zoom word (0x40 = 1:1, larger = shrink):")
    edges = [0x40, 0x80, 0x100, 0x200, 0x400, 1 << 16]
    print(f"{'reg4&fd':7s} " + " ".join(f"{'<=%x' % e if e < 1 << 16 else '>400':>7s}" for e in edges))
    for k in sorted(per):
        zs = [r[6] for r in rows if r[4] and key(r[1]) == k]
        if zs:
            cnt, lo = [], -1
            for e in edges:
                cnt.append(sum(1 for z in zs if lo < z <= e))
                lo = e
            print(f"{k:02x}      " + " ".join(f"{c:7d}" for c in cnt))
    nor = sum(1 for r in rows if r[4] and r[1] & 1)
    rot = sum(1 for r in rows if r[4] and not r[1] & 1)
    print(f"\ndrawn frames: normal {nor}, rotated {rot}; not drawn {len(rows) - nor - rot}")
    dl = Counter(r[9] for r in rows if r[8])
    nd = Counter(r[8] for r in rows)
    print(f"DMAs a frame: {dict(sorted(nd.items()))}")
    if dl:
        ls = sorted(dl.elements())
        print(f"DMA edge line: min {ls[0]}, median {ls[len(ls) // 2]}, max {ls[-1]}; "
              f"most common {dl.most_common(5)}")
    print(f"\nruns of one reg-4 value and drawn state, {min_run}+ frames:")
    print(f"{'frames':>13s} {'reg4':>4s} {'decoded':22s} {'drawn lines':>11s} {'zoom':>9s} {'sx range':>13s} {'sy range':>13s}")
    start = 0
    for i in range(1, len(rows) + 1):
        if i < len(rows) and key(rows[i][1]) == key(rows[start][1]) and bool(rows[i][4]) == bool(rows[start][4]):
            continue
        seg = rows[start:i]
        if len(seg) >= min_run:
            c = key(seg[0][1])
            d = [r for r in seg if r[4]]
            if d:
                dr = f"{min(r[4] for r in d)}-{max(r[4] for r in d)}"
                zm = f"{min(r[5] for r in d):x}-{max(r[6] for r in d):x}"
            else:
                dr, zm = "0", "-"
            sx = f"{min(r[2] for r in seg)}..{max(r[2] for r in seg)}"
            sy = f"{min(r[3] for r in seg)}..{max(r[3] for r in seg)}"
            print(f"{seg[0][0]:6d}-{seg[-1][0]:<6d} {c:4x} {decode(c):22s} {dr:>11s} {zm:>9s} {sx:>13s} {sy:>13s}")
        start = i
    if snaps:
        print("\nsnapshots: " + ", ".join(f"{n:04d}.png frame {f} ctrl {c}" for n, f, c in snaps))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", type=int, default=30000)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--snaps", type=int, default=40, help="max snapshots")
    ap.add_argument("--every", type=int, default=0, help="also snapshot every N frames")
    ap.add_argument("--min", type=int, default=30, help="shortest run listed")
    ap.add_argument("--tag", default="")
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args()
    out = WORK / f"k053250-{a.set}{a.tag}"
    if not a.reuse:
        run(a.set, "k053250.lua", out, {"SV_FRAMES": str(a.frames), "SV_COIN": str(a.coin),
                                        "SV_SNAPS": str(a.snaps), "SV_EVERY": str(a.every)})
    rows, snaps = load(out / "k053250.txt")
    report(rows, snaps, a.min)


if __name__ == "__main__":
    main()
