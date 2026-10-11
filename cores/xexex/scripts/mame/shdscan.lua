-- Frames whose sprite RAM has active entries with shadow bits (word 6 bits 11-10,
-- k053246_k053247_k055673.h non-GX path), written to CORE_OUT/shadow.txt as
-- "frame count". SS_LAST: last frame. SS_COIN: play stimulus from this frame.
local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local COIN = tonumber(os.getenv("SS_COIN") or "0")
local LAST = tonumber(os.getenv("SS_LAST") or "20000")
local d = manager.machine.devices[":maincpu"]
local spr = emu.item(d.items["0/:spriteram"])
local out = assert(io.open(C.out .. "/shadow.txt", "w"))
local n = 0
_G.__ss = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    local f = C.scr:frame_number()
    local c = 0
    for e = 0, 255 do
        local o = e * 0x40
        if spr:read(o) & 0x8000 ~= 0 and (spr:read(o + 12) >> 10) & 3 ~= 0 then c = c + 1 end
    end
    if c > 0 then out:write(string.format("%d %d\n", f, c)) end
    if f >= LAST then out:close(); manager.machine:exit() end
end))
