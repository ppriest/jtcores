# scripts

## MAME capture

Headless MAME runs driven by Lua autoboot scripts, adapted from the `mister-arcade-core` skill's
`write_timing.py` / `wtiming.lua` / `run.lua`. Results in `doc/captures/`.

MAME comes from `MAME_DIR`, `MAME_EXE`, `MAME_ROMPATH` (environment, then `~/.mister-core.env`).
Each run gets its own nvram and cfg folders, cleared first, so it boots from the set's EEPROM
default and leaves the user's MAME state alone. Raw output goes to `$XEXEX_WORK/mame/<tool>-<set><tag>/` (default `D:/jtcores-work/xexex`),
snapshots in its `snap/`.

| file | does |
|---|---|
| `mame_run.py` | paths, the region map from `xexex.cpp` `main_map` (`REGIONS`), the MAME command line |
| `write_timing.py` | writes per region by scanline, over N frames: the video-write sweep |
| `write_log.py` | every write to chosen regions: frame, line, address, data, mask, PC; `--summary` per address |
| `k053250_survey.py` | K053250 reg 4, scroll, drawn lines and zoom range per frame; runs, modes, snapshots |
| `mame/run.lua` | wrapper that turns a Lua syntax or runtime error into `lua_error.txt` |
| `mame/common.lua` | scanline, guarded callbacks, play stimulus |
| `mame/wtiming.lua`, `mame/wlog.lua`, `mame/k053250.lua` | the three taps |

```
python scripts/write_timing.py xexex --skip 600 --frames 1800
python scripts/write_timing.py xexex --coin 600 --skip 1500 --frames 1800 --tag _play
python scripts/write_log.py xexex --regions k053252 --frames 600
python scripts/k053250_survey.py xexex --frames 120000 --coin 600 --tag _play
```

`--reuse` re-prints a previous run.

Things that bite:

- MAME's Lua screen binding has no `vpos()`/`hpos()`/`visible_area`. The line comes from
  `time_until_pos(0)` (`common.lua`); vtotal comes out as the driver's 289.
- An error inside a tap or frame notifier is swallowed by MAME. Every callback goes through
  `C.guard`, which writes the first error to `lua_error.txt`; `mame_run.run` exits on it.
- Taps and notifiers are kept in globals, or they are collected and stop firing.
- A frame, in every log, runs from MAME's frame notifier at vblank start (line 256) to the next.
- `--coin N`: coin every 300 frames from N, Start 150 frames after each, fire auto-pulsed, stick
  cycling. A coin at frame 600 of boot was not registered (the one at 900 was). Play continues on
  credits; with 120000 frames it reaches scene 5.
- The K053250 survey rebuilds the chip's two line buffers from the RAM writes and the reg-4 DMA
  edge, the same way `k053250.cpp` does; the displayed buffer is the one before the latest DMA.
