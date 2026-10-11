# Xexex — hardware notes

Konami GX067, 1991. Everything here is read from MAME unless it says otherwise. Line numbers refer
to the copies in this folder (`xexex.cpp`, `k053250.cpp`), taken from `E:\mame` at `a2d0f76268e`
(`mame0289-661`; its one local commit touches only `konamigx_v.cpp`). `moo.cpp` means
`src/mame/konami/moo.cpp` at the same commit.

## Sets

All four are one board, one memory map and one ROM layout. `xexex.cpp:755-885`.

| set | region | program `01`/`02` | sound `05` | EEPROM default CRC | MAME flags |
|---|---|---|---|---|---|
| `xexex` (parent) | Europe EAA | `067eaa01/02` | `067eaa05` `0e33d6ec` | `155624cc` | IMPERFECT_GRAPHICS, NO_COCKTAIL |
| `orius` | USA UAA | `067uaa01/02` | `067uaa05` `0e33d6ec` | `547ee4e4` | same |
| `xexexa` | Asia AAA | `067aaa01/02` | `067eaa05` `0e33d6ec` | `051c14c6` | same |
| `xexexj` | Japan JAA | `067jaa01/02` | `067jaa05` `2f4dd0a8` | `79a79c7b` | same |

Only the program pair, the Japanese sound program and the EEPROM default differ; every graphics,
LVC and sample ROM is shared. MAME's EEPROM default exists "to prevent game booting upside down
with error" (`xexex.cpp:782`), so each set's `.mra` has to deliver its own.

Loaded bytes per set:

| region | bytes | contents |
|---|---|---|
| `maincpu` | 1 MB loaded into a 1.5 MB region | `000000-07ffff` program, `100000-17ffff` data; `080000-0fffff` is empty |
| `audiocpu` | 128 KB | Z80, 8 banks of 16 KB |
| `k056832` | 2 MB | tiles, 4 bpp, two 16-bit ROMs as 32 bits |
| `k053246` | 4 MB | sprites, four 16-bit ROMs as 64 bits |
| `k053250` | 512 KB | LVC pixels, 4 bpp packed two to a byte |
| `k054539` | 3 MB | PCM samples |
| `eeprom` | 128 B | ER5911 default |

10.6 MB loaded; the jtframe SDRAM layout is 11.1 MB with the program gap.

## CPUs and clocks

One 32 MHz crystal for the logic and one 18.432 MHz for the K054539 (`xexex.cpp:32-33`).

| part | clock | source |
|---|---|---|
| 68000 | 16 MHz, 32/2 | `xexex.cpp:692` |
| Z80 | 8 MHz, 32/4 | `xexex.cpp:696` |
| YM2151 | 4 MHz, 32/8 | `xexex.cpp:735` |
| K053252 (CCU) | 8 MHz, 32/4 | `xexex.cpp:726` |
| pixel clock | 8 MHz | `xexex.cpp:705` |
| K054539 | 18.432 MHz | `xexex.cpp:741` |

`config.set_maximum_quantum(1920 Hz)` (`xexex.cpp:699`) is an emulation setting.

## Screen

`set_raw(32 MHz/4, 512, 40, 424, 289, 0, 256)`, "from CCU" (`xexex.cpp:705`): 384 x 256 visible,
512 x 289 total, 15.625 kHz, 54.07 Hz. The PCB notes give HSync 15.367 kHz and VSync 54.0657 Hz
(`xexex.cpp:72-75`). The VSync agrees with 289 lines at 15.625 kHz; the HSync does not agree with
512 clocks at 8 MHz. The totals are to be taken from the K053252 registers the game writes, captured
in MAME (roadmap, Phase 0).

Offsets MAME applies: K053252 `set_offsets(40, 0)` (`:726`), K053246 `(-48, 32)` (`:719`),
K053250 `(-5, -16)` (`:722`), K054157 layers X `-2, 2, 4, 6`, Y `+16` (`:306-309`).

## Main CPU memory map

`xexex.cpp:565-607`. All accesses 16-bit unless marked.

| address | device | notes |
|---|---|---|
| `000000-07ffff` | program ROM | |
| `080000-08ffff` | work RAM, 64 KB | `080014` read is MAME's idle skip (`:570-572`), not hardware |
| `090000-097fff` | sprite RAM, 32 KB | the list the object DMA copies from |
| `098000-09ffff` | sprite RAM mirror | |
| `0c0000-0c003f` | K054157 registers | write only (reads under `XE_DEBUG`) |
| `0c2000-0c2007` | K053246 registers | write only |
| `0c4000-0c4001` | K053246 sprite ROM readback | |
| `0c6000-0c7fff` | K053250 line RAM, 8 KB window | read/write |
| `0c8000-0c800f` | K053250 registers | read/write, low byte |
| `0ca000-0ca01f` | K054338 registers | write only |
| `0cc000-0cc01f` | K053251 registers | low byte |
| `0d0000-0d001f` | K053252 registers | low byte, read/write |
| `0d4000-0d4001` | sound IRQ | write: Z80 IRQ, HOLD_LINE (`:493-496`) |
| `0d6000-0d601f` | K054321 main side | low byte |
| `0d8000-0d8007` | K054157 B registers (VSCCS) | write only |
| `0da000` / `0da002` | P1 / P2 | |
| `0dc000` / `0dc002` | SYSTEM / EEPROM, service | |
| `0de000-0de001` | control2 | read/write |
| `100000-17ffff` | data ROM | |
| `180000-183fff` | K054157 tile RAM, 16 KB | |
| `190000-191fff` | K054157 tile ROM readback | |
| `1a0000-1a1fff` | K053250 ROM readback | byte at `0x80000*reg6 + 0x800*reg7 + offset/2` (`k053250.cpp:457`) |
| `1b0000-1b1fff` | palette RAM | 2048 x xRGB888, 32 bits per entry |

### control2 (`0de000`)

`xexex.cpp:465-480`:

| bit | function |
|---|---|
| 0, 1, 2 | EEPROM data, chip select, clock |
| 5 | IRQ6 enable |
| 6 | IRQ5 enable |
| 8 | K053246 sprite ROM readback (OBJCHA) |
| 9 | 1: no alpha on K054157 layer 1 (MAME: "under investigation") |
| 11 | IRQ4 enable (the comment says watchdog; the code uses it as the IRQ4 enable, `:559`) |

## Interrupts

`xexex.cpp:512-561`, all HOLD_LINE:

| level | source | when | enable |
|---|---|---|---|
| 4 | vblank | line 256 | control2 bit 11 |
| 5 | object DMA end | 256 us after line 256 (`XE_DMADELAY`, `:167`), and only if the K053246 has its IRQ enabled | control2 bit 6 |
| 6 | test mode | line 0 | control2 bit 5 |

Vectors, from `067eaa01/02`: SSP `090000` (the top of work RAM), reset PC `001000`; IRQ4 `0052c0`,
IRQ5 `004a14`, IRQ6 `004856`. IRQ1-3, the spurious interrupt and the exception vectors all point
at `001000`, so an interrupt on levels 1-3 would restart the game; IRQ7 is `ffffffff`.

In MAME's run of `xexex` the program first takes an interrupt at frame 642: IRQ4 at line 256 and
IRQ5 four lines later, 256 us after the DMA starts (`scripts/boot_trace.py`, vector fetches).

## Object DMA

Done by the driver on the K053246's behalf (`xexex.cpp:410-441`, "TODO: implement sprite dma"),
at line 256 when the K053246 IRQ is enabled:

- 256 source entries in sprite RAM, `0x40` words apart;
- an entry is copied when its word 0 has bit 15 set;
- the copy takes words 0, 2, 4, ... 14 of the entry into 8 consecutive words of the K053247's own
  RAM. The board does not wire A1, A5 and A6 to the K053247 (`:382-384`);
- the unused tail of the K053247 list has word 0 cleared.

Moo does the same with a `0x80`-word stride, 8 contiguous words and a Z mask (`moo.cpp:416-445`).

## Video

### Chips

| chip | role | MAME config |
|---|---|---|
| K054156 + K054157 | 4 tilemap layers | K056832 at 4 bpp (`:712-715`), described as a superset (`:87`) |
| K053246A + K053247A | sprites | `NORMAL_PLANE_ORDER, -48, 32` (`:717-720`) |
| K053250 | line-based layer ("LVC", PCB label "road generator") | `-5, -16` (`:722`) |
| K053251 | priority encoder | `:724` |
| K054338 | background colour, shadows and highlights, alpha | `:728` |
| K053252 | video timing, interrupts | `:726` |
| 054573 x3, 054574 | DACs | not emulated |

### Composition (MAME `screen_update`, `xexex.cpp:312-378`)

1. The K053251 gives palette bases: CI0 sprites, CI1 the K053250, CI2-CI4 tilemap layers 1-3.
   Layer 0's base is fixed at `0x70`.
2. The K053250 and layers 1-3 are sorted by K053251 priority (CI1-CI4) and drawn back to front
   over the K054338's solid background, each writing its bit into the priority bitmap.
3. Layer 1 is drawn without its alpha tiles when alpha is on (control2 bit 9 clear).
4. Sprites are drawn with a mask from their priority field against the four sorted priorities
   (`:266-284`): five bands.
5. Layer 1's alpha tiles are drawn at the K054338's alpha level (`set_alpha_level(1)`).
6. Layer 0 is drawn on top of everything.

Tile colour byte (`:286-297`): bits 5-2 the colour, bit 0 the alpha flag, bit 1 used but unknown.
The palette has shadows and highlights enabled (`:709-710`); `update_all_shadows` comes from the
K054338.

MAME's own list of what is wrong (`xexex.cpp:122-133`): the K053250 one-frame glitch at the stage 1
boss, the stage 3 intro alpha, a darker stage 4 boss, stage 5 far layer shaking, Elaine's ending
masking, the intro alpha, cocktail scroll, music fade-out.

### K053250 (LVC)

`k053250.cpp`, 459 lines, the only chip here with no open RTL.

- **Memory.** 12 KB of RAM (`:31`), of which the CPU sees 8 KB. A falling edge of register 4 bit 1
  copies the first 4 KB into one of two display buffers and swaps them (`:416-426`, `:433-443`).
- **Line table.** 512 packets of four words, wrapping at 4 KB (`:343-353`):
  0 colour (`0xffff` skips the line; bits 4-0 select one of 32 16-colour palettes), 1 ROM offset in
  256-pixel units, 2 zoom (`0x40` is 1:1, `0x20` doubles, `0x80` halves), 3 signed scroll. A packet
  with colour and offset both 0 is skipped too (`:359`).
- **Source.** 4 bpp pixels from the 512 KB ROM, high nibble first (`:18-27`).
- **Registers.** 0-1 X scroll, 2-3 Y scroll, 4 control, 6-7 ROM readback page (`:219-221`, `:457`).
- **Control register 4** (`:229-282`): bit 0 clear swaps X and Y; bit 3 flips X; bit 4 flips Y;
  bit 2 turns off source clipping; bits 7-5 select the source width: 0 is 256 with a 256-line
  virtual screen, 1 is 512, 4 is 256 with a scroll fold at `0x500`, everything else 1024.
  Modes 2 (title) and 7 (stage 4) are commented as seen but not decoded (`:271-272`).
- **Rotated mode.** With X and Y swapped, the table describes columns: each packet is one output
  column, and every output scanline takes one pixel from each of the 384 columns (`:305-341`).
  The driver's change log credits this mode with fixing stage 1 and stage 7 (`xexex.cpp:114-119`).
- **Guesswork in MAME:** the `0x500` fold, "scavenged from old code" (`:377-379`); corrections of
  `-2` and `-5` in flipped rotated mode, tuned against the stage 1 and 5 bosses (`:314-320`).

Also in Metamorphic Force (`mystwarr.cpp:1075`) and, twice, Over Drive (`overdriv.cpp:496-497`).

## Sound

Z80 map, `xexex.cpp:610-619`:

| address | device |
|---|---|
| `0000-7fff` | ROM |
| `8000-bfff` | ROM bank, 8 x 16 KB, from `f800` bits 2-0 |
| `c000-dfff` | RAM, 8 KB |
| `e000-e22f` | K054539 |
| `ec00-ec01` | YM2151 |
| `f000-f003` | K054321 sound side |
| `f800` | bank register |

- The Z80's only interrupt is the IRQ the main CPU raises at `0d4000`. The K054539 timer is not
  connected (no `timer_handler` in the machine config), so the Z80 has no NMI.
- The YM2151's two outputs go through four volume filters whose gain the K054539 sets
  (`ym_set_mixing`, `:503-510`): a write to K054539 register `0x13f`, the pan of its analog input,
  calls back with `pantab[pan]` and `pantab[0xe - pan]` (`k054539.cpp:384-389`), scaled by 71/55.
- Mixing: the YM2151 at 0.2 into the filters, the K054539 at 0.4 into both speakers from each
  output (`:735-751`).
- MAME notes: "mono/stereo softdip has no effect", "Music fadeout isn't working" (`:125`, `:133`).

## Inputs

`xexex.cpp:622-651`. Two players, `KONAMI16_LSB(n, IPT_UNKNOWN, START)`: four directions,
buttons 1 and 2, start (`konamipt.h:217-255`). SYSTEM: two coins, two service inputs. EEPROM port:
EEPROM data and ready, a service switch. No DIP switches; the settings live in the EEPROM.

## Against Moo Mesa and Bucky O'Hare

MAME describes those as "the final Xexex hardware games" and wrote their driver from this one
(`moo.cpp:8-12`). The CPUs, clocks, sound hardware and all video chips except the K053250 are the
same. Moo differs in: the K053990 protection DMA instead of the K053250 (`moo.cpp:520-545`); Bucky
adds a K054000; work, sprite and tile RAM at other addresses (Bucky's are close to Xexex's); a
`0x80`-word DMA stride; IRQ4 and IRQ5 swapped (vblank is IRQ5, DMA end IRQ4, `moo.cpp:447-466`);
three sorted tilemap layers with no line layer; 384 x 224 at a nominal 60 Hz rather than a raw
CCU timing; 16 sound banks; four players and DIP switches.
