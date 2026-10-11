#!/bin/bash
# Build bench/main_video and stage its inputs in $XEXEX_WORK/bench/main_video:
# main.bin, eeprom.bin and k054321.txt from main_boot's prep.py, the fx68k microcode,
# and ccu.bin. Under SIMULATION the generated jtk053252_mmr takes its reset values from
# ccu.bin, not from INIT; without it register 8 is 0 and the frame is 33 lines.
# Then: cd $XEXEX_WORK/bench/main_video && obj_dir/Vmainvid 1000000000 rtl.trace 10000000000 5 1 700
set -e
J=E:/jtcores
B=${JTCORES_BUILD:-D:/jtcores-build}/mister   # for the jtframe-generated *_mmr.v
W=${XEXEX_WORK:-D:/jtcores-work/xexex}/bench
mkdir -p $W/main_video
cp -f $W/main_boot/{main.bin,eeprom.bin,k054321.txt} $W/main_video/
cp -f $J/modules/fx68k/hdl/{microrom.mem,nanorom.mem} $W/main_video/
# INIT of cores/rungun/hdl/jtk053252.v, register 0 first
printf '\x01\xff\x00\x21\x00\x37\x01\x00\x01\x07\x0c\x0e\x54\x00\x00\x00' > $W/main_video/ccu.bin
Y=""
for d in cores/xexex/hdl cores/simson/hdl cores/moo/hdl cores/riders/hdl cores/rungun/hdl \
         modules/fx68k/hdl/verilator modules/jteeprom/hdl \
         modules/jtframe/hdl modules/jtframe/hdl/{cpu,ram,video,video/layouts,video/tilemap,clocking}; do
    Y="$Y -y $J/$d"
done
FX=$J/modules/fx68k/hdl/verilator
NO_RUN=1 bash "$(dirname "$0")/../run_verilator.sh" main_video mainvid -DJTFRAME_MCLK=48000000 \
    $J/cores/xexex/bench/main_video/public.vlt $Y \
    $B/cores/simson/hdl/jt053246_mmr.v \
    $J/cores/xexex/hdl/jtk053252_mmr.v \
    $FX/fx68k.sv $FX/fx68kAlu.sv $FX/uaddrPla.sv $J/cores/xexex/bench/main_video/mainvid.v
