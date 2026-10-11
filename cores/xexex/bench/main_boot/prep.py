#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Images for the main_boot bench, from the set's zip: main.bin (the maincpu region as
the SDRAM holds it, 1.5 MB, 080000-0fffff filled with FF as the .mra does) and
eeprom.bin (MAME's default, doc/xexex.cpp:782). With a MAME trace as the third
argument, also k054321.txt: its K054321 reads in order, which the bench replays.
Written to $XEXEX_WORK/bench/main_boot."""
import os
import sys
import zipfile
from pathlib import Path

ROMS = {  # set: (program hi, program lo, data hi, data lo, eeprom)
    "xexex":  ("067eaa01.16d", "067eaa02.16f", "067b03.13d", "067b04.13f", "er5911.19b"),
    "xexexj": ("067jaa01.16d", "067jaa02.16f", "067b03.13d", "067b04.13f", "er5911.19b"),
}


def main():
    game = sys.argv[1] if len(sys.argv) > 1 else "xexex"
    rompath = Path(sys.argv[2] if len(sys.argv) > 2 else "F:/Emulation/roms/MAME ROMs")
    # next to the bench's build, off the shared E: volume (bench/run_verilator.sh)
    here = Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex")) / "bench" / "main_boot"
    here.mkdir(parents=True, exist_ok=True)
    parent = zipfile.ZipFile(rompath / "xexex.zip")
    own = rompath / f"{game}.zip"
    z = zipfile.ZipFile(own) if own.exists() else None   # else a merged set: <game>/ in xexex.zip

    def rd(name):
        for src, n in ((z, name), (parent, f"{game}/{name}"), (parent, name)):
            try:
                if src is not None:
                    return src.read(n)
            except KeyError:
                pass
        raise KeyError(name)

    ph, pl, dh, dl, ee = ROMS[game]
    inter = lambda h, l: bytes(b for pair in zip(rd(h), rd(l)) for b in pair)  # noqa: E731
    img = inter(ph, pl) + b"\xff" * 0x80000 + inter(dh, dl)
    assert len(img) == 0x180000
    (here / "main.bin").write_bytes(img)
    (here / "eeprom.bin").write_bytes(rd(ee))
    print(f"{game}: main.bin {len(img):#x} bytes, eeprom.bin {len(rd(ee))} bytes")
    if len(sys.argv) > 3:
        vals = []
        for ln in open(sys.argv[3]):
            if ln[0] == "#":
                continue
            _, rw, a, m, d, _, _ = ln.split()
            if rw == "R" and 0x0d6000 <= int(a, 16) < 0x0d6020:
                vals.append(d)
        (here / "k054321.txt").write_text("\n".join(vals) + "\n")
        print(f"k054321.txt: {len(vals)} reads")


if __name__ == "__main__":
    main()
