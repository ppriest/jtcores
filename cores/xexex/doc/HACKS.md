# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does. Each entry is added in the commit that introduces the hack and removed in the commit
that removes it. MAME's own guesses, reproduced on purpose, are in `MAME_KLUDGES.md`.

Severity: **visible** (a player or a verifier can see it), **latent** (no in-scope set produces the
input), **tooling** (the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| The K053250 is RAM and registers only | `hdl/jtxexex_main.v` `u_lvcram`, `lvc_regs` | The chip is Phase 4 | Phase 4 | the CPU side matches MAME's RAM test (bench/main_boot) | visible |
| The K053250 takes a frame's registers and line table 10 lines before its first line, and renders up to 32 lines ahead; the chip reads them as it draws each line | `hdl/jtxexex_lvc.v` | swapped frames need up to 384 ROM reads on some lines; working ahead averages them over the SDRAM | the chip's own timing, measured | bench/video: all 54 captured states match `scripts/video_model.py`, which matches MAME's frames; MAME draws a whole frame at line 256 | visible only when the game changes the registers or table mid-frame |
| K053250 ROM offsets wrap at 512 kB; MAME reads past the end of its unpacked ROM | `hdl/jtxexex_lvc.v` `srcnib` | a power-of-two wrap | — | no captured table reaches the end | latent |
| K053250 ROM readback ignores register 6 (MAME: byte 0x80000 * reg 6 + 0x800 * reg 7 + offset / 2, past the 512 kB ROM unless reg 6 is 0) | `hdl/jtxexex_lvc.v` `cpu_rom_a` | the ROM is 512 kB | — | no read of 1a0000 in 30000 frames of attract or play (`scripts/mame/romrd.lua`) | latent |
| K053250 ROM bandwidth checked against a bench model, not jtframe's controller: rotated frames stay ahead up to 14 clocks a read | `bench/video/tb.cpp` `LVC_LAT` | jtframe's SDRAM is not simulated here | the controller in simulation, or the board | jtframe `doc/sdram.md`: 9 clocks on average, 32 at most, at 48 MHz on MiSTer | visible if exceeded |
| The YM2151's level is K054539 register 0x13f's centre pan, fixed; other pan values are not modelled | `cfg/mem.yaml` `fm` | the game writes 0x13f only as 0x00 and 0x18, both centre in MAME's table (`k054539.cpp` 0x13f) | MAME's `sqrt(pan/14)` per side from the register | Z80 traces of `xexex` (4000 frames) and `xexexj` (600): writes of 0x00 and 0x18 only | latent |
| The K054539 sample ROM mirrors over 4 MB; the board has 3 MB, and the top 1 MB now reads the K053250 ROM | `hdl/jtxexex_k054539.v` `PCM_MASK` | `gx_k054539` wants a power-of-two mask | A mask of 3 MB with MAME's wrap, if a set reads there | unverified | latent |
| control2 bit 10 is stored and does nothing | `hdl/jtxexex_main.v` `ctrl2` | the boot toggles it (MAME trace, seq 24); `xexex.cpp` does not decode it; Moo's driver calls its bit 10 the watchdog | a watchdog, if the board has one there | unverified | latent |
| The K053252 model's vsync is 10 lines for VSW field 5; MAME's formula gives 6, so vblank is 37 lines (251 visible) against MAME's 33 (256) | `cores/rungun/hdl/jtk053252.v` `u_vscnt` | the counter loads `vswidth` uninverted and counts to 15; `u_hscnt` loads its width inverted. Kept: visible height comes from the chip model, not from MAME's screen (`MAME_KLUDGES.md`) | the board's vsync width, measured | bench/main_video LVBL log: falls at bench line 178, rises at 215 | visible |
| Tile VRAM holds 8 of the K056832's 16 pages: rows 0-3 of columns 0-1; column bit 1 mirrors | `hdl/jtxexex_tilemap.v` | Xexex lays its layers out in those 8 (boot register writes; every captured frame) | the board's VRAM size | bench/video/cmp_layers.py: all 19 captured frames match scripts/video_model.py | latent |
| Layers 3 pages tall or wide wrap as 4 | `hdl/jtxexex_tilemap.v` `hmask`, `wmask` | MAME takes the height modulo 768; a power of two needs no divider | a 768 modulo, if a set uses it | Xexex uses 1 and 2 pages (boot registers) | latent |
| The K054157's own flip x (register 0 bit 4) is not implemented; the OSD's flip screen turns the frame in the core instead | `hdl/jtxexex_tilemap.v` | the game sets it only from its service-menu flip, in EEPROM; register 0 bit 4 is clear in every captured frame | MAME's flipx path with register 0x3a, compared on a capture with the service-menu flip | the bench warns if it is set | latent |
| Sprite shadows add the K054338 deltas to the colour beneath; not checked against MAME | `hdl/jtxexex_colmix.v` | no frame to compare: no active sprite has shadow bits (word 6 bits 11-10) in 30000 frames of attract or of play, except frames 51-52 of the boot (`scripts/mame/shdscan.lua`) | a scene with shadows compared | unverified | latent |
| The palette dump (IOCTL) covers the first 1024 colours of 2048 | `hdl/jtxexex_colmix.v` `addr1b` | `jtriders_dump` gives the palette a 4 kB window | a larger dump window | tooling | tooling |
| Main-CPU benches replay MAME's K054321 reads in order; main_boot also models palette and tile RAM as plain RAM, main_video reads graphics ROMs as 0. bench/video's ROMs answer 4 clocks after an address settles | `bench/main_boot/tb.cpp`, `bench/main_video/tb.cpp` | the benches have no sound CPU | the whole-core bench | tooling | tooling |

## Removed

| What | Removed by | Replaced with |
|---|---|---|
