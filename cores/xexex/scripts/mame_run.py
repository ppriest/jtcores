#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared by the MAME capture scripts: paths, the Xexex region map, the MAME command line.

Paths come from the environment, then ~/.mister-core.env (MAME_DIR, MAME_EXE,
MAME_ROMPATH). Raw output goes to $XEXEX_WORK/mame (default D:/jtcores-work/xexex),
off the cores' shared E: volume.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

CORE = Path(__file__).resolve().parent.parent
LUA_DIR = CORE / "scripts" / "mame"
WORK = Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex")) / "mame"
NO_WINDOW = {"creationflags": 0x08000000} if os.name == "nt" else {}

# Main CPU map, xexex.cpp main_map (doc/xexex.cpp:565-607). Inclusive byte ranges.
REGIONS = {
    "spr":     (0x090000, 0x097fff),  # K053247 sprite RAM (object DMA source)
    "sprmir":  (0x098000, 0x09ffff),  # sprite RAM mirror
    "tile":    (0x180000, 0x183fff),  # K054157 tile RAM
    "vreg":    (0x0c0000, 0x0c003f),  # K054157 registers
    "vregb":   (0x0d8000, 0x0d8007),  # K054157 B registers
    "objreg":  (0x0c2000, 0x0c2007),  # K053246 registers
    "lvcram":  (0x0c6000, 0x0c6fff),  # K053250 RAM, the half its DMA copies
    "lvcram2": (0x0c7000, 0x0c7fff),  # K053250 RAM, upper half
    "lvcreg":  (0x0c8000, 0x0c800f),  # K053250 registers
    "k054338": (0x0ca000, 0x0ca01f),
    "k053251": (0x0cc000, 0x0cc01f),
    "k053252": (0x0d0000, 0x0d001f),
    "pal":     (0x1b0000, 0x1b1fff),
    "ctrl2":   (0x0de000, 0x0de001),
}

# Driver screen (xexex.cpp:705): vblank from line 256 of 289.
VTOTAL, VBSTART = 289, 256


def _env_file():
    env = {}
    p = Path(os.environ.get("MISTER_CORE_ENV") or Path.home() / ".mister-core.env")
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')
    return env


def setting(key, default):
    return os.environ.get(key) or _env_file().get(key) or default


def taps(names=None):
    """REGIONS -> "name:lo:hi,..." for the Lua side."""
    return ",".join(f"{n}:{lo:x}:{hi:x}" for n, (lo, hi) in REGIONS.items()
                    if names is None or n in names)


def run(game, lua, out_dir, env, timeout=7200):
    """Run MAME headless with scripts/mame/<lua> under run.lua. Returns the process.

    nvram and cfg go to out_dir so the user's MAME state is neither read nor changed:
    every run boots from the set's EEPROM default.
    """
    mame_dir = Path(setting("MAME_DIR", "C:/Emulation/Emulators/MAME"))
    exe = mame_dir / setting("MAME_EXE", "mame.exe")
    rompath = setting("MAME_ROMPATH", "F:/Emulation/roms/MAME ROMs")
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "lua_error.txt").unlink(missing_ok=True)
    for d in ("snap", "nvram", "cfg"):
        shutil.rmtree(out_dir / d, ignore_errors=True)
    cmd = [str(exe), game, "-nodebug", "-nowindow", "-video", "none", "-sound", "none",
           "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
           "-autoboot_script", str(LUA_DIR / "run.lua"), "-rompath", rompath,
           "-nvram_directory", str(out_dir / "nvram"), "-cfg_directory", str(out_dir / "cfg"),
           "-snapshot_directory", str(out_dir / "snap"), "-snapview", "native"]
    full = dict(os.environ, CORE_SCRIPT=str(LUA_DIR / lua), CORE_OUT=out_dir.as_posix(), **env)
    p = subprocess.run(cmd, cwd=str(mame_dir), env=full, capture_output=True, text=True,
                       timeout=timeout, **NO_WINDOW)
    err = out_dir / "lua_error.txt"
    if err.exists():
        sys.exit(f"{game}: Lua failed: {err.read_text().strip()}")
    return p
