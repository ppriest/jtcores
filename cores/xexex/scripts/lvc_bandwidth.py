#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""K053250 ROM reads a screen line needs, from captured states (scripts/video_state.py),
through scripts/video_model.py's draw(): per line, the distinct 32-bit ROM words its
pixels read, and the words a one-word cache per column would still miss (rotated mode
walks each column down the lines). Prints the worst line of each state.

    python scripts/lvc_bandwidth.py state.txt [state.txt ...]"""
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import video_model as vm   # noqa: E402


def main():
    rom = np.frombuffer((Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex")) / "bench" / "video"
                         / "lvc.bin").read_bytes(), np.uint8)
    for path in sys.argv[1:]:
        st = vm.State(path)
        vm.LVC_SRC = np.full((vm.H, vm.W), -1, np.int64)
        vm.render_lvc(st, rom)
        src = vm.LVC_SRC
        word = np.where(src >= 0, src >> 3, -1)          # 8 nibbles a 32-bit word
        rows = [len(set(word[y][word[y] >= 0].tolist())) for y in range(vm.H)]
        miss = [0] * vm.H
        for y in range(vm.H):
            cur, prev = word[y], word[y - 1] if y else np.full(vm.W, -2)
            miss[y] = int(((cur >= 0) & (cur != prev)).sum())
        y1 = int(np.argmax(rows))
        y2 = int(np.argmax(miss))
        print(f"{Path(path).name}: reg4 {st.lvc_regs[4]:02x}, distinct words: worst line {y1} {rows[y1]}, "
              f"column cache misses: worst line {y2} {miss[y2]}")


if __name__ == "__main__":
    main()
