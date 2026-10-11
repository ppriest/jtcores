#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render each active sprite of a state alone, in scripts/video_model.py and in
bench/video, and list the sprites whose pixels differ, with their eight words.

    python bench/video/iso_sprites.py state.txt [workdir]"""
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

WORK = Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex"))
EXE = WORK / "bench" / "video" / "obj_dir" / "Vjtxexex_video.exe"
MODEL = Path(__file__).resolve().parents[2] / "scripts" / "video_model.py"


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2] if len(sys.argv) > 2 else WORK / "iso") / src.stem
    out.mkdir(parents=True, exist_ok=True)
    lines = src.read_text().splitlines(True)
    w = {}
    for ln in lines:
        t = ln.split()
        if t and t[0] == "W" and "090000" <= t[1] < "098000":
            w[(int(t[1], 16) - 0x90000) // 2] = int(t[2], 16)
    act = [e for e in range(256) if w.get(e * 0x40, 0) & 0x8000]
    for e in act:
        keep = []
        for ln in lines:
            t = ln.split()
            if t and t[0] == "W" and "090000" <= t[1] < "098000":
                a = (int(t[1], 16) - 0x90000) // 2
                if a % 0x40 == 0 and a // 0x40 != e:
                    t[2] = "%04X" % (int(t[2], 16) & 0x7fff)
                    ln = " ".join(t) + "\n"
            keep.append(ln)
        st = out / f"only{e}.txt"
        st.write_text("".join(keep), newline="\n")
        subprocess.run([sys.executable, str(MODEL), str(st), "--sprites", "--out", str(out / f"m{e}")],
                       capture_output=True, check=True)
        subprocess.run([str(EXE), str(st), "3", str(out / f"r{e}")], cwd=EXE.parent.parent,
                       capture_output=True, check=True)
        m = np.array(Image.open(out / f"m{e}" / "mix.png").convert("RGB")).astype(int)
        r = np.array(Image.open(out / f"r{e}-2.ppm").convert("RGB")).astype(int)
        n = int(np.any(m[:r.shape[0]] != r, -1).sum())
        if n:
            words = " ".join(f"{w.get(e * 0x40 + 2 * k, 0):04X}" for k in range(8))
            print(f"sprite {e}: {n} pixels differ  [{words}]")


if __name__ == "__main__":
    main()
