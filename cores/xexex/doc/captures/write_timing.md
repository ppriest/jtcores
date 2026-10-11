# Video-write sweep, MAME

Raw tables and per-line histograms: `write_timing_mame.txt`. MAME 0.289. Lines are MAME's: vblank
256-288 of 289; a frame runs from line 256 to line 255. Scanline from `time_until_pos` (vtotal
came out 289).

```
python scripts/write_timing.py xexex --skip 600 --frames 1800                            # attract
python scripts/write_timing.py xexex --coin 600 --skip 1500 --frames 1800 --tag _play    # play, scene 1
python scripts/write_timing.py xexex --skip 600 --frames 50000 --tag _attract_long
python scripts/write_timing.py xexex --coin 600 --skip 1500 --frames 100000 --tag _play_long
python scripts/write_log.py xexex --regions vreg,vregb,objreg,lvcreg,ctrl2,k053251,k054338,k053252 \
    --frames 3300 --coin 600 --tag _play --summary --from 1500                            # per register
python scripts/write_log.py xexex --regions spr,objreg,lvcreg,ctrl2 --frames 4000 --coin 600 --tag _objdma
```

Play stimulus (`scripts/mame/common.lua`): a coin every 300 frames, Start 150 frames after each,
fire auto-pulsed, stick cycling. The 1800-frame play run is scene 1; the 100000-frame run reaches
scenes 1-4 on continues (snapshots in `work/mame/k053250-xexex_p120k/snap`, same stimulus).
`orius` and `xexexa` gave tables identical to `xexex`; `xexexj` differs in detail (below).

## Per region (xexex)

"99%" = the shortest run of lines holding 99% of the region's writes.

| region | attract 1800 | play 1800 (scene 1) | play 100000 | notes |
|---|---|---|---|---|
| `spr` 090000 | 47/frame, 99% in 263-190, 9.6% vblank | 457/frame, 272-192, 5.3% vblank | 689/frame, 265-194, 8.6% | whole frame. None in lines 256-260, and none after the game sets K053246 reg 5 bit 4 in that frame (frames 1500-3999, `_objdma` log) |
| `sprmir` 098000 | 0 | 0 | 0 | never written |
| `tile` 180000 | 108/frame, 241-109, 44.7% vblank | 1343/frame, 30-176, 0.7% vblank | 98/frame, 263-206, 26.1% | written in active display in play |
| `vreg` 0c0000 | 97.5% vblank | 62.8% vblank | 78.1% | see registers below |
| `vregb` 0d8000 | 260 | 260-263 | 260-263 | once a frame, vblank |
| `objreg` 0c2000 | 88.4% vblank | 67.9% vblank | 71.2% | see registers |
| `lvcram` 0c6000-0c6fff | 2 frames written | 592/frame, 275-30, 30.7% vblank | 115/frame, 267-70, 35.2% | from vblank into the top of the frame; attract 50000: 263-143 |
| `lvcram2` 0c7000-0c7fff | 0 | 0 | 0 | never written |
| `lvcreg` 0c8000 | 95.2% vblank | 86.6% vblank | 88.0% | see registers |
| `k054338` 0ca000 | 51 frames, 262-264 | 0 | 4015 frames, 79-190 | rare |
| `k053251` 0cc000 | 3 writes/reg, lines 131, 231, 11 | 0 | 15 frames | scene changes only |
| `k053252` 0d0000 | 258 | 257-262 | 257-262 | reg `0e` (INT1 ack) once a frame |
| `pal` 1b0000 | 125/frame, 226-40, 57% vblank | 135/frame, 257-262, 100% vblank | 152/frame, 257-108, 88.5% | |
| `ctrl2` 0de000 | 5/frame, 91.8% vblank | 84.7% vblank | 86.3% | see registers |

## Per register, play (frames 1500-3299)

| address | register | per frame | lines |
|---|---|---|---|
| `0c0000`, `0c0020`-`0c002e` | K054157 reg 0, scroll | once | 260-264 |
| `0c0032` | K054157 reg `0x19`, tile-RAM page for the CPU window | ~8 | anywhere (19% vblank); PCs `010ee2`/`010dba` at lines 31-54 while tile RAM is written |
| `0d8000` | K054157 B reg 0 | once | 260-263 |
| `0c2000` | K053246 regs 0-1 | once | 261-264 |
| `0c2002` | K053246 regs 2-3 | once | end of the game loop, 102-10 |
| `0c2004` (low byte) | K053246 reg 5 | 3 | `0x20` (object DMA off) at 262-263; `0x30` (on) at the end of the game loop |
| `0c8000`-`0c8006` | K053250 regs 0-3, scroll | once | 261-264 |
| `0c8008` | K053250 reg 4 | 2 | bit 1 set at 263; cleared at the end of the game loop: that edge is the DMA |
| `0de000` | control2 | ~5 | `0x0840` (IRQ5 on) at the end of the game loop; EEPROM strobes at 262-263 |
| `0d001c` | K053252 reg `0e` | once | 257-262 |

"End of the game loop" is one point per frame where the program writes `0c2004`=`0x30`,
`0c8008` bit 1 clear and control2 `0x0840` (PCs `004b1e`, `004b44`, `004b90`), with `0c2002`
(PC `005290`) on the same line in the frames inspected. Its line in
play: 96-230 or about 272 (`_objdma` log, 2500 frames); K053250 DMA edge from
`k053250.md`: attract mostly 264-283, play mostly 276-277 and 130-160, full range 0-288.

## Attract vs play (play wins)

- **Tile RAM**: attract writes 44.7% in vblank; play writes it in active display (lines 30-176 in
  scene 1, 0.7% in vblank), through a page register also rewritten mid-frame.
- **End-of-loop registers** (K053246 regs 2-3 and 5, K053250 reg 4, control2): attract has them
  near vblank (88-95%); play has them anywhere from line ~96 to ~280.
- **Palette**: attract spreads across 226-40; play scene 1 is all in 257-262, 88.5% in vblank over
  100000 frames.
- **Sprite RAM**: both write across the whole frame. `xexexj` play: 0.4% in vblank, 11-156.
- Once-a-frame scroll registers (K054157, K053246 0-1, K053250 0-3, B reg 0) are at 260-264 in
  every run.

Coverage: attract 1800 frames starts at frame 600 (intro and title only; `lvcram` written in 2
frames); the 50000-frame attract run covers the demo loop (scenes 1, 2, 4 and a mechanical scene,
see `k053250.md`). Play: scenes 1-4 over 100000 frames, by continues; later scenes not reached in the sweep.
