-- Log every write to the WL_TAPS ranges: frame, scanline, address, data, mask, PC.
--   WL_TAPS    "name:hexlo:hexhi,..."
--   WL_FRAMES  frames to run, then exit
--   WL_COIN    play stimulus from this frame (0 = attract)
-- Output CORE_OUT/writes.log. Lines starting '#' are comments; '# screen' lines
-- record the screen geometry at start and whenever it changes.

local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local FRAMES = tonumber(os.getenv("WL_FRAMES") or "600")
local COIN = tonumber(os.getenv("WL_COIN") or "0")
local scr, prog = C.scr, C.prog
local cpu = manager.machine.devices[":maincpu"]

local log = assert(io.open(C.out .. "/writes.log", "w"))
log:write(string.format("# vtotal %d (time_until_pos), refresh %.6f\n", C.vtotal, scr.refresh))
log:write("# frame\tline\taddr\tdata\tmask\tpc\n")
if #C.inputs_missing > 0 then log:write("# inputs missing: " .. table.concat(C.inputs_missing, ", ") .. "\n") end

local function geom()
    return string.format("%dx%d refresh %.6f", scr.width, scr.height, scr.refresh)
end
local last_geom = geom()
log:write("# screen " .. last_geom .. "\n")

_G.__wl = {}
for spec in string.gmatch(os.getenv("WL_TAPS") or "", "([^,]+)") do
    local name, lo, hi = spec:match("^([^:]+):(%x+):(%x+)$")
    _G.__wl[#_G.__wl + 1] = prog:install_write_tap(tonumber(lo, 16), tonumber(hi, 16), "wl_" .. name,
        C.guard("tap " .. name, function(offset, data, mask)
            log:write(string.format("%d\t%d\t%06X\t%04X\t%04X\t%06X\n", scr:frame_number(),
                C.cur_line(), offset, data & 0xffff, mask & 0xffff, cpu.state["PC"].value))
        end))
end

local n = 0
_G.__wl_frame = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    local g = geom()
    if g ~= last_geom then
        log:write(string.format("# screen %s from frame %d\n", g, scr:frame_number()))
        last_geom = g
    end
    if n >= FRAMES then
        log:write(string.format("# end frame %d, lua errors %d\n", scr:frame_number(), C.errors))
        log:close()
        manager.machine:exit()
    end
end))
