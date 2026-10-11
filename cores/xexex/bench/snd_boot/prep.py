#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Images for the snd_boot bench, from the set's zip: snd.bin (the Z80 program) and
pcm.bin (the K054539 samples), in $XEXEX_WORK/bench/snd_boot."""
import os
import sys
import zipfile
from pathlib import Path

SND = {"xexex": "067eaa05.4e", "xexexj": "067jaa05.4e"}


def main():
    game = sys.argv[1] if len(sys.argv) > 1 else "xexex"
    rompath = Path(sys.argv[2] if len(sys.argv) > 2 else "F:/Emulation/roms/MAME ROMs")
    # next to the bench's build, off the shared E: volume (bench/run_verilator.sh)
    here = Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex")) / "bench" / "snd_boot"
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

    (here / "snd.bin").write_bytes(rd(SND[game]))
    (here / "pcm.bin").write_bytes(rd("067b06.3e") + rd("067b07.1e"))
    print(f"{game}: snd.bin, pcm.bin")


if __name__ == "__main__":
    main()
