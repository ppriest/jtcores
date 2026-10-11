-- Reads of the tile ROM window (190000-191fff) and the K053250 ROM window
-- (1a0000-1a1fff): per frame with any, "frame tile lvc" in CORE_OUT/romrd.txt.
-- RR_LAST: last frame. RR_COIN: play stimulus from this frame.
local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local COIN = tonumber(os.getenv("RR_COIN") or "0")
local LAST = tonumber(os.getenv("RR_LAST") or "20000")
local out = assert(io.open(C.out .. "/romrd.txt", "w"))
local nt, nl = 0, 0
_G.__rr1 = C.prog:install_read_tap(0x190000, 0x191fff, "rr_tile", C.guard("t", function(o, d, m) nt = nt + 1 end))
_G.__rr2 = C.prog:install_read_tap(0x1a0000, 0x1a1fff, "rr_lvc", C.guard("l", function(o, d, m) nl = nl + 1 end))
local n = 0
_G.__rr = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    local f = C.scr:frame_number()
    if nt + nl > 0 then out:write(string.format("%d %d %d\n", f, nt, nl)) end
    nt, nl = 0, 0
    if f >= LAST then out:close(); manager.machine:exit() end
end))
