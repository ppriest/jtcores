# Xexex — Roadmap

**This roadmap is a proposal until the user approves it. No phase executes before that approval,
and a phase whose scope changes goes back for approval.**

## Context

Goal: an arcade core for Konami's Xexex (GX067), emulated by MAME's `konami/xexex.cpp` and the
devices it instantiates, built on jtframe in a fork of jtcores (`ppriest/jtcores`, branch `xexex`,
`cores/xexex`) so that one source tree builds for MiSTer and for the Analogue Pocket. One `.rbf`
per target, one `.mra` per set.

**Most of the board already exists as open RTL in jtcores; one chip exists nowhere.** Moo Mesa and
Bucky O'Hare run on the same hardware family, and jtcores carries a K054156/7 tilemap, the
K053246/7 sprites, the K053251 and K054338 mixers, the K053252 and the K054321. The K054539 comes
from `Arcade-KonamiGX_MiSTer`, because jtcores' own is a private submodule. What is new work:

1. **The K053250 LVC**, written from MAME's `k053250.cpp`. No RTL has been found for it in jtcores
   or furrtek's SiliconRE (whose Konami folder lists no 053250). Its rotated mode reads one pixel
   from each of 384 columns per scanline, which is the feasibility item below.
2. **The main CPU side**: `jtxexex_main` is moo's, with moo's address decoder. Xexex's memory map,
   control2, IRQ4/5/6 and the object DMA (`0x40` stride, every other word) replace it.
3. **The colour mixer**: the K053250 on K053251 input CI1, four sorted layers, per-tile alpha on
   layer 1 gated by control2 bit 9.
4. **The YM2151 and its gain**, which the K054539's register `0x13f` sets. The moo core never had
   the YM2151.

Everything else is integration with verification.

## Progress

**Phase 4 in simulation: the K053250 matches MAME.** `hdl/jtxexex_lvc.v` draws it as `k053250.cpp` does, with accumulators where MAME multiplies and divides. bench/video against `scripts/video_model.py` (which matches MAME's snapshots): the layer is exact in all 54 captured states (attract, play, and `vstate-xexex_lvc` for the modes those miss: `05`, `21`, `51`, `81`, `85`, `89`, `90`, `e0`), and the OSD flip turns those frames 180 degrees exactly. Frames still differing from MAME differ in zoomed sprites (`MAME_KLUDGES.md`), sprite capture timing, or one palette-fade step. ROM bandwidth: rotated frames need up to 384 reads a line for some twenty lines (`scripts/lvc_bandwidth.py`); a 32-line ring and a walker/fetcher split keep them ahead up to 14 clocks a read in the bench, against jtframe's documented 9 on average at 48 MHz. On the board at `72f00bdfd` the layer draws in attract (`debug/hw/green_2.png`); stages 1, 4 and 6 are not compared yet.

Every board build before `72f00bdfd` showed green equal to blue: `ram_dsn` was undeclared in `jtxexex_game.v`, a 1-bit implicit net, so the palette saw UDS always active and each blue-only byte write also wrote green. The benches declare their own wiring and never showed it. `scripts/build_staged.py` now fails a build with an implicit net in the core's files (Quartus warning 10236).

**Phase 3 in progress.** Done in the RTL, not yet tried on the board:

| feature | how | evidence |
|---|---|---|
| flip screen | OSD, Video page (`CORE_OSD` on status bit 1, which `JTFRAME_OSD_FLIP` reads; jtframe's menu lists it only for vertical games): every layer renders line `ylast-Y` and reads its line buffer right to left; the game's own flip is a service-menu setting in EEPROM | bench/video: flipped equals unflipped rotated 180 degrees in 20 play states. On the board at `6ae3d75f6`: upright with the option Off (`debug/hw/p3_up.png`), turned over with it On (user) |
| inputs | `Shot,Flint` (`cfg/mame2mra.toml`, shmups.wiki and arcade-museum.com) | the generated `.mra` |
| pause | jtframe's P key and the button after Coin ("Core credits" in the `.mra`) drive `dip_pause`, the 68000's HALT | on the board at `9feaacd14`: two shots 14 s apart in pause identical, the picture moves after a second P (`debug/hw/p3_pause1.png`, `p3_pause2.png`, `p3_run.png`) |
| NVRAM and high scores | one 256-byte file: the EEPROM, then `hiram` with MAME hiscore.dat's two work-RAM areas (`hdl/jtxexex_hiscore.v`). Written when the player picks the OSD's "Save settings": jtframe's `hps_io.v` has no upload request, so no autosave (user's decision: jtframe unchanged) | bench/hiscore: both boots pass; MAME writes the default table at frame 517 and the restore test passes from then until play changes it (`scripts/mame/hstrace.lua`) |
| test switch | a button, as MAME's `PORT_SERVICE_NO_TOGGLE` and as the user found on the board (the game acts on its release): jtframe's test key, F2, with no OSD entry, as rungun | not tried since the change |
| CRT and HDMI options, audio | jtframe's own | not tried |
| game speed | fx68k from SDRAM, sharing it with the tile and object chips | on the board at `6ae3d75f6`, attract screenshots matched to MAME snapshots (`scripts/mame/snapseq.lua`, the board's black K053250 areas masked): 4690 frames in 86 s, 54.5 +- 0.6 frames a second against MAME's 54.07 |
| release build | `scripts/build_staged.py` passes `--nodbg` (`JTFRAME_RELEASE`) unless `--debug`; the debug build draws `debug_view` at the bottom of the screen | `ec13f5269` on the board: no overlay (`debug/hw/p3_rel1.png`) |
| `xexexj` main program | bench/main_video on `067jaa01/02`, 700 frames | before the first IRQ (frame 642) the 967,802 writes match MAME in order; after it 3 frames differ outside the stacks, the same tile-RAM and page-register writes across a frame boundary as `xexex` (5 frames), the vblank phase in `HACKS.md` (`scripts/compare_trace.py --frames`) |
| `xexexj` sound program | bench/snd_boot on `067jaa05.4e`, the 68000 side replayed from MAME | the Z80's 231,183 writes and 165,735 RAM and I/O reads match MAME in order over 600 frames (`scripts/compare_trace.py --z80`) |

Staged builds of the Phase 3 RTL (`9feaacd14` MiSTer, `1023203a6` Pocket; the same RTL):

| target | worst setup slack | ALMs | M10K |
|---|---|---|---|
| MiSTer, DE10-nano | +3.171 ns, TNS 0 | 21,695 / 41,910 (52 %) | 324 / 553 (59 %) |
| Pocket, 5CEBA4F23C8 | +1.406 ns, TNS 0 | 13,639 / 18,480 (74 %) | 244 / 308 (79 %) |

The Pocket has 64 M10K left for the K053250 (Phase 4). The first Pocket fit at `1023203a6` crashed in `quartus_fit` (access violation); the rerun passed.

**Phase 2 is done in simulation: bench/video renders 20 captured play states pixel-identical to `scripts/video_model.py`, and the three without the K053250 (frames 10000, 13000, 20000) to MAME's snapshots, except sprites MAME zooms per cell (`MAME_KLUDGES.md`, by the user's decision).** The tile layers are `hdl/jtxexex_tilemap.v`, the mixer `hdl/jtxexex_colmix.v` (MAME's `screen_update`), the sprites jtsimson_obj with an `XEXEX` parameter; visible height comes from the K053252 model (251 lines). Not compared: sprite shadows and the tile ROM window, neither used in 30000 frames of attract or play (`HACKS.md`); tile flip x goes with flip screen in Phase 3.

**Phase 1 is done: the main CPU and the sound CPU match MAME in simulation, and on the MiSTer the
game boots to its task loop with sound (heard by the user at `0103923ad`).** The video is still moo's.

- On the board (48 MHz build before `9d837fb7b`) both CPUs ran and the Z80 replied 0x80 then
  0x0F as in MAME, but the 68000 looped at 0x2db0, the self-test's halt, with no IRQ enabled
  (debug view, `st_where`). `bench/main_video` (the main CPU with the real video) found the
  failing test: tile RAM, addressed one bit off, and a palette half the size. Fixed in
  `9d837fb7b`; that bench now matches MAME's writes and reads in order to the first IRQ
  (frame 642), and after it differs only by the vblank phase (`HACKS.md`). On the board at `0103923ad` the 68000
  reaches the game's task loop at 0x1152 (debug view 0x91, A[14:8]=0x11, in three shots,
  `debug/hw/shot3_*.png`); the picture is the unfinished video's.

- `cores/xexex` is moo's HDL renamed, with Xexex's `cfg/`. `jtframe mra xexex` generates the four
  `.mra` files, each with its own EEPROM default.
- The K054539 is `gx_k054539.sv` from `Arcade-KonamiGX_MiSTer` `a16effa`, behind
  `jtxexex_k054539.v`; a smoke bench passes (`bench/k054539`).
- Staged builds at `60f48331d` (`build_staged.py`, worst setup slack over every game PLL output):

  | target | worst setup slack | ALMs | M10K |
  |---|---|---|---|
  | MiSTer, DE10-nano | +0.099 ns, TNS 0 | 18,328 / 41,910 (44 %) | 191 / 553 (35 %) |
  | Pocket, 5CEBA4F23C8 | +0.554 ns, TNS 0 | 9,897 / 18,480 (54 %) | 114 / 308 (37 %) |

  MiSTer's 20 worst paths into the 96 MHz clock are in jtframe's SDRAM controller
  (`scripts/report_worst_paths.tcl`).
- `jt05415x` timing changes (`cd91ab388`, `110f15b4e`, `fc83e8262`) were reverted with the module's
  removal from the core; they stay in history.

## Game scope

| set | region | differs from `xexex` in |
|---|---|---|
| `xexex` | Europe EAA | parent |
| `orius` | USA UAA | program, EEPROM default |
| `xexexa` | Asia AAA | program, EEPROM default |
| `xexexj` | Japan JAA | program, sound program, EEPROM default |

Loaded bytes and CRCs are in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md), "Sets".

- **In scope:** all four. One board, one map, one ROM layout.
- **First target:** `xexex`, the parent. `xexexj` second, for its different sound program.

## Hardware reality

In [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md), with file and line for every value: chips, clocks,
screen, memory map, control2, interrupts, object DMA, video composition, the K053250, sound, inputs,
and the differences from Moo.

## Clocks

jtframe fixes the clocks: the game and the SDRAM run on `clk` at 48 MHz, and every board clock is
a clock enable from it; this replaces the skill's search for a `clk_sys`.

| clock | enable | exact |
|---|---|---|
| pixel, 8 MHz | 48 MHz /6 (`jtframe_pxlcen`) | yes: 3072 clocks a line |
| 68000, 16 MHz | 48 MHz /3 | yes |
| Z80, 8 MHz | 48 MHz /6 | yes |
| YM2151, 4 MHz | 48 MHz /12 | yes |
| K054539, 18.432 MHz | 48 MHz x 48/125 | yes, a fractional enable (`mem.yaml` `18432k`); 48 kHz samples are 384 of its clocks |

The K053252 registers give 512 x 289 at 8 MHz (`captures/k053252.md`), so the line and frame
rates are the board's. Whether the 68000 needs to run ahead to recover SDRAM stalls is measured in
Phase 1.

## Memory plan

SDRAM at 48 MHz, from `cfg/macros.def` and `cfg/mem.yaml`:

| bank | start | contents | clients |
|---|---|---|---|
| 0 | `000000` | main ROM 1.5 MB (with the empty 512 KB) | 68000 |
| 1 | `180000` | Z80 ROM 128 KB, PCM 3 MB, LVC ROM 512 KB | Z80 through a 4 kB cache, K054539 (32-bit granules), K053250 |
| 2 | `520000` | tiles 2 MB | K054157 layers |
| 3 | `720000` | sprites 4 MB | K053246/7 |

Bank 1's worst line: the K053250's 384 random reads (rotated mode at high zoom), the Z80 cache's
misses, at most 24 in a scanline in MAME play (`scripts/z80_cache.py`), and the K054539's few
granules. jtframe documents an average of 9 clocks a read at 48 MHz on MiSTer
(`modules/jtframe/doc/sdram.md:245-255`), about 340 a line: short of the worst case. That figure
is simulated by jotego, not measured here; the open item "K053250 ROM bandwidth" says what closes
it.

Work RAM (64 kB) is in BRAM, as the board's two SRAMs: from SDRAM it made every access wait,
and jtframe's repayment of the lost phases could not keep up in the RAM test's write loops.

On-chip memory at `60f48331d`, before work RAM moved: 191 of 553 M10K on the DE10-nano, 114 of 308
on the Pocket.

## Component reuse map

| block | plan | source |
|---|---|---|
| 68000 | as is | `modules/fx68k` (submodule) through `jtframe_m68k`, GPL-3 |
| Z80 | as is | `jtframe_sysz80` (`modules/jtframe/hdl/cpu/jtframe_z80.v`), GPL-3-or-later wrapper |
| K054156/K054157 | new: `hdl/jtxexex_tilemap.v`, from MAME's k056832 | `modules/jt05415x` was planned and not used (below) |
| K053246/K053247 | port; DMA stride and word selection for Xexex | `cores/simson/hdl/jt053246*.sv`, `jtsimson_obj.v`, GPL-3-or-later |
| K053251 | port | `cores/simson/hdl/jtcolmix_053251.v` |
| K054338 | port | `cores/moo/hdl/jt054338.v` |
| K053252 | port | `cores/rungun/hdl/jtk053252.v` |
| K054321 | as is | `cores/riders/hdl/jt054321.v` |
| K054539 | as is, behind an adapter | `Arcade-KonamiGX_MiSTer/rtl/sound/gx_k054539.sv` `a16effa`, GPL-3-or-later, written from MAME's `k054539.cpp`; adapter `hdl/jtxexex_k054539.v` |
| YM2151 | as is | `modules/jt51` (submodule), GPL-3 |
| ER5911 EEPROM | as is | `modules/jteeprom/hdl/jt5911.sv` |
| **K053250** | **written from MAME** | `doc/k053250.cpp` |
| main decoder, control2, IRQs, object DMA | rewritten from `xexex.cpp` | replaces moo's `jtxexex_main.v` |
| colour mixer | rewritten from `xexex.cpp` `screen_update` | replaces moo's `jtxexex_colmix.v` |

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no
PCB here. Each inherited guess goes in `doc/MAME_KLUDGES.md` when it is implemented. Known ones:
the K053250 `0x500` fold and flipped-rotated corrections, the 256 us DMA-end delay, the object DMA
done by the driver, control2 bit 9 "under investigation", the layer and chip offsets.

**Not MAME's idle skip.** `waitskip_r` (`xexex.cpp:453-462`) is an emulator speed hack; the board
has plain work RAM there.

**Where a vendored module and MAME disagree, record it and keep the module.** Disagreements go in
`doc/MAME_KLUDGES.md`.

**The K054156/7 is `jtxexex_tilemap.v`, not `jt05415x`** (user's decision, after Phase 3). `jt05415x`
is the scan half of the pair only: per layer it outputs a tile code and the raw attribute byte every
4 pixels (`jt05415x.v` output stage), without the row within the tile, the pixel phase, attribute
decoding or pixels; Moo, its only user, does not render correct layers from it. Its RAMs also hold 4
pages and Xexex uses 8. Extending it means writing the rendering half; the tilemap already does that,
pixel-exact to MAME.

**Every approximation of this core's own goes in `doc/HACKS.md`** in the commit it lands. The first
entries: the missing YM2151, the PCM ROM mirrored over 4 MB where the board has 3.

**Built on jtframe, in a jtcores fork.** jtframe only builds cores at `cores/<name>` inside a jtcores
tree. The project documents live in `cores/xexex/doc/`. Nothing outside `cores/xexex` changes except
where jtframe itself needs a fix, and those are separate commits that could go upstream.

**Windows build.** `jtcore` runs from Git Bash with Quartus 20.1 (MiSTer and Pocket). The
requirements found so far are in the project memory and will go into `doc/WORKFLOW.md`: MSYS-style
`JTROOT`, `--nolinter`, LF checkouts, `jtframe mmr -m` for shared modules jtcore leaves out (none now). Every compile takes the
machine-wide `hwlock`.

**Line-based rendering, as the board.** The K053250 already works a line at a time from a
double-buffered table; the sprites and tilemaps are jtframe's line engines. No frame buffer: the
driver shows none.

**No multiplies or divides in the video path.** The K053250 zoom is a 6-bit fixed-point step,
accumulated.

**Licence: GPL-3.0-or-later**, as jtcores and `Arcade-KonamiGX_MiSTer`.

**Deployed file names follow the machine's rule:** `jtxexex_3000000N.rbf` from 30000001 on the
MiSTer, and `<rbf>jtxexex</rbf>` in the `.mra`.

## Phased roadmap

**Phase 0 — Toolchain, measurements, and the gate.** Nothing after it starts until each criterion
is answered in place.

1. **A staged build.** — Met: `scripts/build_staged.py` builds a worktree of `HEAD` per target in
   `<repo>-build/<target>`, writes `BUILT_COMMIT`, and reports the game clock's slack. On Windows it
   copies in the jtframe binary and `reverse_bits.exe` (built once with MSYS2's gcc), generates the
   shared modules' registers, and runs `jtcore --nolinter` from Git Bash with Quartus 20.1.
2. **The Pocket target builds, with its fit.** — Met: 47 % ALMs, 109 of 308 M10K, timing met
   (Progress). `build_staged.py` at `8c4ffa564` runs end to end and writes
   `release/pocket/raw/Cores/jotego.jtxexex/jtxexex.rbf_r`, game clock +3.232 ns.
3. **The MiSTer timing failure.** — Met: `jt05415x` wrapped the scroll sum to the layer with 16
   unrolled compare-and-subtract steps per axis in one clock (`jt05415x.v`, before `cd91ab388`).
   No other jtcores core uses the module, so no upstream build had timed it. It then took the page
   number modulo the span from a table; `bench/wrap_eq` showed identical results for all 131,072
   cases; the game clock went from -10.817 ns to +3.629 ns. Both went with `jt05415x` when the core stopped using it
   (`jtxexex_tilemap.v`, below).
4. **MAME captures.** — Met, `xexex` fully, the other sets in part (`captures/`, `scripts/README.md`):
   - K053252: the game writes the same registers in every set; they give 512 x 289 at 8 MHz,
     54.0657 Hz, as `set_raw` (`captures/k053252.md`).
   - Write sweep, attract and play (`captures/write_timing.md`): tile RAM is written in active
     display in play and the palette mostly in vblank; sprite RAM is not written between line 256
     and the object DMA; scroll registers once a frame at lines 260-264.
   - K053250 (`captures/k053250.md`): width modes 0, 1, 2, 4, 7; rotated in 19012 of 120000 attract
     frames and 21379 of 120000 play frames; zoom words up to `0x7f0`. Scene 4 is rotated mode `e0`
     on all 384 columns, with the largest zoom above `0x400` in 7987 frames. **The column cache
     does not help there**: a source step of 16 pixels or more a line needs a new ROM word per
     column per line, 384 random reads a line. See the open item "K053250 ROM bandwidth".
   - Not reached: MAME's named stage 5-7 cases. Play reached scene 5.
5. **A simulation harness.** — Met: Verilator 5.050 from MSYS2 (`bench/run_verilator.sh`, which
   re-runs itself under MSYS2's shell and builds at -O2 for MSYS2's GCC 16.2). Benches live in
   `bench/`: jtcores' `.gitignore` ignores `sim/` and `ver/`.
6. **The skill's scripts mapped to jtframe.** — Partly met: `deploy.py`, `hw.py`, `coretools.py`
   and `identity.py` are copied from the skill (`b1ee26a`) and read the staged build, jtframe's
   `release/mra` and CORENAME; the device file is `jtxexex_NNNNNNNN.rbf` from 30000001. A dry run
   refuses a missing or failed build. Deployed `94c9c60eb` as
   `/media/fat/_Arcade/cores/jtxexex_30000001.rbf` with the four `.mra` files in `_Arcade/_Xexex`;
   not launched. Open: the probe path (`debug_bus`, SignalTap), and `hw.py` against the device.

**Phase 1 — Main CPU, memory map and sound CPU.**

The main decoder, control2, IRQs and object DMA from `xexex.cpp`; the Z80 side with the K054321,
the K054539 adapter and the YM2151 (jt51). Exit criteria: the 68000 boot trace of `xexex` matches
MAME access by access, video stubbed to MAME's values; the Z80's register writes match MAME's for
the attract sequence; the K054539 adapter has a bench fed from those writes.

**Phase 2 — Video without the K053250.**

The K054157 at Xexex's offsets, the K053246/7 with the Xexex DMA, the K053251 with five inputs,
the K054338 (background, shadows, per-tile alpha on layer 1), the palette. The timing failure is
fixed here if Phase 0 did not. Exit criteria: frames pixel-identical to MAME for scenes without
the K053250 layer, in simulation, from captured state.

**Phase 3 — MiSTer bring-up.**

Deploy, boot and play `xexex` on the DE10-nano, with the standard feature set, each through jtframe's
own mechanism where it has one: DIPs page (Xexex has none; the OSD shows only what applies), inputs
with the game's button names, Pause suspending the 68000, flip screen from the OSD through one path
checked against the unflipped frame rotated 180 degrees, CRT and HDMI options, hiscore, NVRAM with
each set's EEPROM default. Exit criteria: `xexex` and `xexexj` boot and play, K053250 layer absent.

**Phase 4 — The K053250.**

Normal and rotated modes, flips, the width modes, the double-buffered table and its DMA, the ROM
readback, the column cache. Bench from MAME captures of stages in each mode (`k053250.cpp:247-272`
names them). Exit criteria: pixel-identical to MAME on those captures; on hardware, stages 1, 4 and
6 play without artefacts MAME does not have.

**Phase 5 — Sound.**

YM2151 gain from K054539 register `0x13f`; mixing levels from `xexex.cpp:735-751`; judged by ear on
hardware, since MAME is not the oracle for sound timing.

**Phase 6 — Analogue Pocket.**

The Pocket target builds, fits and plays, with the controls and options that apply there.

**Phase 7 — Accuracy and the rest.**

All four sets on both targets, `doc/MAME_KLUDGES.md` and `doc/HACKS.md` current, and a decision on
offering the core upstream to jtcores.

**Phase 8 — Savestates.** Optional. The RAMs are written with borrowable ports from Phase 1 so it
stays possible.

## Verification strategy

- **MAME is a reference generator driven from scripts**: boot traces, register-write logs, VRAM and
  register dumps at known frames.
- **Every module has a bench fed from a MAME capture before it goes on hardware.**
- **`.mra` files are generated** by `jtframe mra` from `doc/mame.xml`.
- **Hardware claims cite evidence**: a screenshot path, a probe readout, a log line.

## Open items

~~**Where `jtframe` gets each set's EEPROM default.**~~ Closed: MAME's `eeprom` region renamed
`nvram` in `mame2mra.toml` becomes `.mra` ROM index 2 per set, with `<nvram size="128">` from
`JTFRAME_IOCTL_RD` (`b0693d208`).

~~**The screen totals.**~~ Closed: the K053252 registers give 512 x 289 at 8 MHz, 15.625 kHz and
54.0657 Hz (`captures/k053252.md`); the PCB note's 15.367 kHz HSync fits neither.

**K053250 ROM bandwidth, at 48 MHz.** Rotated mode at high zoom needs one random ROM read per
pixel, 384 a line; jtframe's documented latency gives about 340 reads a line per bank at 48 MHz
(`modules/jtframe/doc/sdram.md:245-255`). The SDRAM ran at 96 MHz for it (`517caeb38`) and was
put back to 48 MHz (`144bba388`): the core did not run on the MiSTer at 96 MHz, nothing needs the
bandwidth until the K053250 exists, and the standing rule is to make the design fit at the system
clock (48 MHz SDRAM, no DDR) rather than double the SDRAM. Phase 4 measures the controller with
this core's clients and optimises: the LVC ROM's bank, caching per column, what else shares it.
The Z80 program stays behind its 4 kB cache.

~~**The interrupt vectors.**~~ Closed: read from the ROM (`HARDWARE_NOTES.md`, "Interrupts").

**`<mameversion>` in the `.mra` files reads `0282`**, from jtcores' `doc/mame.xml`, while the Xexex
entries came from 0.289. The ROMs are identical between the two.

**Button names.** From the manual or another source; MAME only says buttons 1 and 2.

## Next steps

1. ~~User review of this roadmap and [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md).~~ Approved.
2. Phase 0 item 4: the MAME captures.
3. ~~The user's decision on the K053250 ROM bandwidth.~~ Option 1, built and timed on both targets.
4. Phase 0 item 6: the probe path and `hw.py`, when a launch is wanted.
5. ~~Phase 1.~~ Done.
6. ~~Phase 2.~~ Done in simulation; on the board at `9760a4e58` tiles and sprites show, background black (no K053250).
7. Phase 3: approved; the high-score check on the board is left.
8. Phase 4: approved, in simulation done; the board next.
