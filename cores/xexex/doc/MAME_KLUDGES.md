# MAME kludges this core reproduces

The core follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"). This file lists
each of MAME's guesses that touches an in-scope set, what the core does, and what would settle it,
and where a vendored module disagrees with MAME and was kept. The core's own approximations are in
`HACKS.md`.

References are to `doc/xexex.cpp` and `doc/k053250.cpp`, copied from `E:\mame` at `a2d0f76268e`.
Every set is `MACHINE_IMPERFECT_GRAPHICS | MACHINE_NO_COCKTAIL`.

**Core:** *copies*, *differs* (how and why), *not yet* (the part is not written), *n/a*.

## CPU and timing

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Idle skip | `xexex.cpp:453-462`: reads of `080014` at PC `1158` suspend the 68000 until the next scanline | differs: not reproduced, an emulator speed hack. The reference traces come from a MAME 0.289 build with `XE_SKIPIDLE 0` (`D:/build/mame-noskip`, a worktree of `E:/mame`), which polls as the board does | — |
| Object DMA end | `xexex.cpp:167`, `:551-554`: IRQ5 256 us after line 256, "Increase XE_DMADELAY if emulation runs faster than the original" | differs: IRQ5 at the end of `jt053246_dma`'s copy, whose own comment gives 297.5 us at 16-bit speed | a capture of the IRQ5 time on a board |
| Object DMA done by the driver | `xexex.cpp:410-441`, "TODO: implement sprite dma" | copies: `jt053246_dma` with `XEXEX` copies the 256 entries and words MAME's `object_dma` does, in the frame's vblank | — |
| Screen geometry | `xexex.cpp:705`: `set_raw(8 MHz, 512, 40, 424, 289, 0, 256)`, "from CCU" | differs: blanking and sync come from the K053252 registers through `jtk053252`; 251 visible lines (`HACKS.md`) | the board's vsync and vblank, measured |

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Sprite zoom by cell | `k053246_k053247_k055673.h` `k053247_draw_yxloop_gx`: each 16x16 cell is drawn as its own zoomed tile, start and size rounded per cell | differs: `jt053246_scan` and `jtframe_objdraw` step one accumulator across the whole sprite, so zoomed sprites pick some source rows and columns one off from MAME's (frame 11000 sprite 139: 191 pixels, `bench/video/iso_sprites.py`). Unzoomed sprites match: of 20 play states, every frame without zoomed sprites is pixel-exact against scripts/video_model.py, and frames 10000, 13000 and 20000 (no K053250) against MAME (bench/video/cmp_frame.py) | the board's output for a zoomed sprite |
| K053250 `0x500` scroll fold | `k053250.cpp:377-379`, "scavenged from old code" | copies (`jtxexex_lvc.v`, width mode 4) | — |
| K053250 flipped rotated-mode corrections of -2 and -5 | `k053250.cpp:314-320`, tuned against the stage 1 and 5 bosses | copies (`jtxexex_lvc.v` frame setup) | — |
| control2 bit 9 turns off layer 1's alpha | `xexex.cpp:478-479`, "under investigation" | not yet: Phase 2 (the bit is decoded to `alpha_off`) | — |

## Sound

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Mono mix | `xexex.cpp:743-750`: each K054539 and YM2151 output routed to both speakers; its notes list a stereo output (CN5, `:49`) and "mono/stereo softdip has no effect" (`:125`) | differs, by the user's decision: each chip's left and right kept, as the board's stereo output; MAME's levels kept (YM2151 0.456 of the K054539) | the board's output, heard |

## Vendored modules that disagree with MAME

`cores/simson` sprite chip parameters Xexex sets, each because the picture is wrong without it (bench/video against MAME's snapshots; images in `debug/cmp/`):

| Parameter | What it does | Without it |
|---|---|---|
| `LARGE_DMA` | 256 entries every 0x40 words of a 32 kB object RAM | the DMA reads the wrong words |
| `ZSORT8` | sorts on all 8 z bits, descending | sprites with z over 0x80 are lost (attract 41200, play 7000) |
| `NO_LEFT_WRAP` | no shift for sprites starting left of the screen | sprites crossing the left edge are cut or missing (play 9000, 10000) |
| `ROM_WINDOW` | RAM reads ignore OBJCHA; Xexex's ROM readback has its own window | sprite RAM reads return ROM data |
| `HFIX` (0) | jtframe_objdraw's read-out fix off | the OSD flip's right-to-left read is overridden |
| `VTOP`, `BOTTOM` | the line window the scan runs in | the default fits about 234 lines; Xexex shows 251 |


| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| `jt05415x` | K054156/7 as a K056832 subset (`xexex.cpp:87`) | follows silicon where MAME and the die differ (`modules/jt05415x/README.md`) | silicon-derived | recorded per case as they show |
