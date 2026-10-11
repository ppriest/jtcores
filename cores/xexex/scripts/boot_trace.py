#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Log every access of a CPU from reset in MAME: the reference for the RTL's trace.

    python scripts/boot_trace.py xexex 200000                    # 68000
    python scripts/boot_trace.py xexex 200000 --cpu audiocpu     # Z80
    -> work/mame/boot-<set>-<cpu>/boot.trace: seq rw addr mask data frame line

scripts/compare_trace.py diffs an RTL trace against it.
"""
import argparse
from mame_run import WORK, run


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("n", type=int)
    ap.add_argument("--cpu", default="maincpu", choices=["maincpu", "audiocpu"])
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--norom", action="store_true", help="leave out program-ROM reads")
    ap.add_argument("--frames", type=int, default=0, help="also stop at this frame")
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    out = WORK / f"boot-{a.set}-{a.cpu}{a.tag}"
    run(a.set, "boottrace.lua", out, {"BT_CPU": ":" + a.cpu, "BT_N": str(a.n), "BT_COIN": str(a.coin),
                                     "BT_NOROM": "1" if a.norom else "0", "BT_FRAMES": str(a.frames),
                                     "BT_HI": "1fffff" if a.cpu == "maincpu" else "ffff"})
    path = out / "boot.trace"
    lines = path.read_text().splitlines()
    print(f"{path}: {len(lines) - 2} accesses; last: {lines[-2]}")


if __name__ == "__main__":
    main()
