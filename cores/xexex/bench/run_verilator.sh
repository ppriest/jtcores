#!/bin/bash
# Build and run one Verilator bench: bench/run_verilator.sh <bench> <top> <rtl files...>
# Run it from the bench's work folder afterwards: $XEXEX_WORK/bench/<bench>/obj_dir/V<top>
# From Git Bash or MSYS2; uses MSYS2's MinGW64 Verilator, g++ and make.
# Re-executes under MSYS2's bash: in Git Bash /mingw64 is Git's own, and its
# libstdc++ does not match MSYS2's g++.
set -e
M=${MSYS2_ROOT:-/e/msys64}
SELF="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)/$(basename "$0")"
if [ "$MSYSTEM" != MINGW64 ] || ! command -v verilator_bin >/dev/null 2>&1; then
    exec env MSYSTEM=MINGW64 CHERE_INVOKING=1 "$M/usr/bin/bash.exe" -lc 'exec bash "$@"' _ "$SELF" "$@"
fi
BENCH=$1; TOP=$2; shift 2
SIM=$(cd "$(dirname "$0")" && pwd)
export VERILATOR_ROOT=$(cygpath -m /mingw64/share/verilator)   # verilator_bin is native: a Windows path
# builds, images and outputs go to $XEXEX_WORK/bench/<bench>, off the shared E: volume;
# the bench runs from there and finds its files there
WORK=${XEXEX_WORK:-D:/jtcores-work/xexex}/bench/$BENCH
mkdir -p "$WORK"
cp -f "$SIM/$BENCH/tb.cpp" "$WORK/"
cd "$WORK"
[ -n "$KEEP_OBJ" ] || rm -rf obj_dir
# OPT_FAST/OPT_GLOBAL -O2: MSYS2's GCC 16.2 cannot link -Os code that moves a
# std::string (Arcade-KonamiGX_MiSTer scripts/run_verilator.sh)
verilator_bin --cc --exe --build -j 8 -O3 -DSIMULATION -Wno-fatal -Wno-lint -Wno-style \
    --no-assert-case --top-module "$TOP" \
    -MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_GLOBAL=-O2 "$@" tb.cpp > build.log 2>&1 \
    || { tail -30 build.log; exit 1; }
[ -n "$NO_RUN" ] || ./obj_dir/V$TOP
