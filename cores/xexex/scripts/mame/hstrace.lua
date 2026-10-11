-- The hiscore areas of MAME's hiscore.dat for xexex (85000, 0x63 bytes, start 00 end 1c;
-- 80057, 3 bytes, start 00 end 30): per frame where the sentinel test result changes,
-- "frame pass b85000 b85062 b80057 b80059" in CORE_OUT/hstrace.txt. HS_LAST: last frame.
local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local LAST = tonumber(os.getenv("HS_LAST") or "3000")
local COIN = tonumber(os.getenv("HS_COIN") or "0")
local out = assert(io.open(C.out .. "/hstrace.txt", "w"))
local last, n = nil, 0
_G.__hs = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    local f = C.scr:frame_number()
    local a, b, c, d = C.prog:read_u8(0x85000), C.prog:read_u8(0x85062), C.prog:read_u8(0x80057), C.prog:read_u8(0x80059)
    local pass = (a == 0 and b == 0x1c and c == 0 and d == 0x30) and 1 or 0
    local key = string.format("%d %02x %02x %02x %02x", pass, a, b, c, d)
    if key ~= last then out:write(string.format("%d %s\n", f, key)); last = key end
    if f >= LAST then out:close(); manager.machine:exit() end
end))
