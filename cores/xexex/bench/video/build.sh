#!/bin/bash
# Build bench/video and stage ccu.bin in $XEXEX_WORK/bench/video (tiles.bin and
# obj.bin come from prep.py). Under SIMULATION the generated jtk053252_mmr takes its
# reset values from ccu.bin, not from INIT; the game never writes register 8.
# Then: cd $XEXEX_WORK/bench/video && obj_dir/Vjtxexex_video <state.txt> [frames] [prefix]
set -e
J=E:/jtcores
B=${JTCORES_BUILD:-D:/jtcores-build}/mister   # for the jtframe-generated *_mmr.v
W=${XEXEX_WORK:-D:/jtcores-work/xexex}/bench/video
mkdir -p $W
# INIT of cores/rungun/hdl/jtk053252.v, register 0 first
printf '\x01\xff\x00\x21\x00\x37\x01\x00\x01\x07\x0c\x0e\x54\x00\x00\x00' > $W/ccu.bin
Y=""
for d in cores/xexex/hdl cores/simson/hdl cores/moo/hdl cores/riders/hdl cores/rungun/hdl \
         modules/jtframe/hdl \
         modules/jtframe/hdl/{ram,video,video/layouts,video/tilemap,clocking}; do
    Y="$Y -y $J/$d"
done
NO_RUN=1 bash "$(dirname "$0")/../run_verilator.sh" video jtxexex_video $J/cores/xexex/bench/video/public.vlt $Y \
    $B/cores/simson/hdl/jt053246_mmr.v \
    $J/cores/xexex/hdl/jtk053252_mmr.v \
    $J/cores/xexex/hdl/jtxexex_video.v
