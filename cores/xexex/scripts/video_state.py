#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Video state and MAME's frame at chosen frames, for bench/video.

    python scripts/video_state.py xexex 1500,3000,4500 [--coin 600] [--tag _x]

Output $XEXEX_WORK/mame/vstate-<set><tag>/: state-<frame>.txt (scripts/mame/vstate.lua)
and snap-<frame>.png, MAME's frame drawn from that state.
"""
import argparse
import shutil

from mame_run import WORK, run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("frames")
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    frames = sorted(int(f) for f in a.frames.split(","))
    out = WORK / f"vstate-{a.game}{a.tag}"
    run(a.game, "vstate.lua", out, {"VS_FRAMES": ",".join(map(str, frames)), "VS_COIN": str(a.coin)})
    snaps = sorted((out / "snap").rglob("*.png"))
    if len(snaps) != len(frames):
        raise SystemExit(f"{len(snaps)} snapshots for {len(frames)} frames in {out / 'snap'}")
    for f, s in zip(frames, snaps):
        shutil.move(str(s), out / f"snap-{f}.png")
        print(f"frame {f}: {out / f'state-{f}.txt'}, {out / f'snap-{f}.png'}")


if __name__ == "__main__":
    main()
