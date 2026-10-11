-- Every access of one CPU from reset, for scripts/boot_trace.py (the reference the
-- RTL's trace is compared against). Adapted from the mister-arcade-core skill's
-- boottrace.lua.
--   BT_CPU     ":maincpu" or ":audiocpu"
--   BT_N       accesses to log, then exit
--   BT_HI      top address of the space, hex
--   BT_COIN    play stimulus from this frame (0: none)
--   BT_NOROM   1: leave out program-ROM reads (see is_rom)
--   BT_FRAMES  stop at this frame too (0: only BT_N)
-- Output CORE_OUT/boot.trace: seq rw addr mask data frame line
-- Frame counts MAME's frame notifier (vblank start, line 256); line from common.lua.

local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local CPU = os.getenv("BT_CPU") or ":maincpu"
local N = tonumber(os.getenv("BT_N") or "100000")
local HI = tonumber(os.getenv("BT_HI") or "ffffff", 16)
local COIN = tonumber(os.getenv("BT_COIN") or "0")
local NOROM = os.getenv("BT_NOROM") == "1"
local FRAMES = tonumber(os.getenv("BT_FRAMES") or "0")
local space = manager.machine.devices[CPU].spaces["program"]
local W = CPU == ":maincpu" and 4 or 2
-- program ROM: the 68000's two ranges, the Z80's 0000-bfff (bank included)
local function is_rom(a)
    -- the vector table is kept: an interrupt's vector fetch is how it shows in the trace
    if CPU == ":maincpu" then return (a >= 0x100 and a < 0x80000) or (a >= 0x100000 and a < 0x180000) end
    return a < 0xc000
end

local f = assert(io.open(C.out .. "/boot.trace", "w"))
f:write("# " .. CPU .. " accesses from reset: seq rw addr mask data frame line\n")
local fmt = "%d %s %06X %0" .. W .. "X %0" .. W .. "X %d %d\n"
local n, frame, done = 0, 0, false

local function finish()
    if done then return end
    done = true
    f:write(string.format("# %d logged, errors %d\n", n, C.errors))
    f:close()
    manager.machine:exit()
end

local function tap(rw)
    return C.guard("tap " .. rw, function(offset, data, mask)
        if done then return end
        if NOROM and rw == "R" and is_rom(offset) then return end
        n = n + 1
        f:write(string.format(fmt, n, rw, offset, mask, data, frame, C.cur_line()))
        if n >= N then finish() end
    end)
end

_G.__bt_r = space:install_read_tap(0, HI, "bt_r", tap("R"))
_G.__bt_w = space:install_write_tap(0, HI, "bt_w", tap("W"))
_G.__bt_f = emu.add_machine_frame_notifier(C.guard("frame", function()
    frame = frame + 1
    C.stimulus(frame, COIN)
    if FRAMES > 0 and frame >= FRAMES then finish() end
end))
