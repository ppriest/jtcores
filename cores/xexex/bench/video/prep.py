#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Graphics ROM images for bench/video, laid out as the SDRAM holds them (the .mra's
interleaves, release/mra): tiles.bin, 2 MB of 32-bit words, lvc.bin, 512 kB, and obj.bin, 4 MB of
64-bit words, each word little-endian. Written to $XEXEX_WORK/bench/video."""
import os
import sys
import zipfile
from pathlib import Path


def interleave(parts, width):
    """parts: [(data, byte lanes from the .mra map, right to left)]"""
    n = len(parts[0][0]) // len(parts[0][1])
    out = bytearray(n * width)
    for data, lanes in parts:
        k = len(lanes)
        for i in range(n):
            for j, lane in enumerate(lanes):
                out[i * width + lane] = data[i * k + j]
    return bytes(out)


def main():
    rompath = Path(sys.argv[1] if len(sys.argv) > 1 else "F:/Emulation/roms/MAME ROMs")
    here = Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex")) / "bench" / "video"
    here.mkdir(parents=True, exist_ok=True)
    z = zipfile.ZipFile(rompath / "xexex.zip")
    # map "0021": part byte 1 to lane 0, byte 2 to lane 1
    tiles = interleave([(z.read("067b14.1n"), [0, 1]), (z.read("067b13.2n"), [2, 3])], 4)
    obj = interleave([(z.read("067b12.17n"), [0, 1]), (z.read("067b11.19n"), [2, 3]),
                      (z.read("067b10.20n"), [4, 5]), (z.read("067b09.22n"), [6, 7])], 8)
    (here / "tiles.bin").write_bytes(tiles)
    (here / "obj.bin").write_bytes(obj)
    lvc = z.read("067b08.22f")                  # K053250, bytes as MAME's region
    (here / "lvc.bin").write_bytes(lvc)
    print(f"tiles.bin {len(tiles):#x}, obj.bin {len(obj):#x}, lvc.bin {len(lvc):#x} in {here}")


if __name__ == "__main__":
    main()
