-- Count writes to video regions by scanline, for scripts/write_timing.py.
--   WT_TAPS    "name:hexlo:hexhi,..."
--   WT_SKIP    frames to run before counting (boot)
--   WT_FRAMES  frames to count
--   WT_COIN    play stimulus from this frame (0 = attract); see common.lua
--   WT_SNAPS   frames (counted from boot) to snapshot, comma-separated; the last
--              counted frame is always snapped
-- Output CORE_OUT/wtiming.txt:
--   vtotal N / frames N / errors N
--   hist <region> c0,...,c(vtotal-1)   writes per line
--   last <region> ...                  frames whose last write fell on that line
--   nfr  <region> N                    frames with at least one write

local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local SKIP = tonumber(os.getenv("WT_SKIP") or "600")
local FRAMES = tonumber(os.getenv("WT_FRAMES") or "1800")
local COIN = tonumber(os.getenv("WT_COIN") or "0")
local snaps = {}
for s in string.gmatch(os.getenv("WT_SNAPS") or "", "(%d+)") do snaps[tonumber(s)] = true end

local names, hist, lastl, nfr, frame_last = {}, {}, {}, {}, {}
local counting = false
_G.__wt = {}
for spec in string.gmatch(os.getenv("WT_TAPS") or "", "([^,]+)") do
    local name, lo, hi = spec:match("^([^:]+):(%x+):(%x+)$")
    names[#names + 1] = name
    hist[name], lastl[name], nfr[name] = {}, {}, 0
    _G.__wt[#_G.__wt + 1] = C.prog:install_write_tap(tonumber(lo, 16), tonumber(hi, 16), "wt_" .. name,
        C.guard("tap " .. name, function(offset, data, mask)
            if counting then
                local l = C.cur_line()
                hist[name][l] = (hist[name][l] or 0) + 1
                frame_last[name] = l
            end
        end))
end

local n = 0
_G.__wt_frame = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    if snaps[n] then manager.machine.video:snapshot() end
    if n == SKIP then counting = true end
    if counting then
        for name, l in pairs(frame_last) do
            lastl[name][l] = (lastl[name][l] or 0) + 1
            nfr[name] = nfr[name] + 1
        end
        frame_last = {}
    end
    if n == SKIP + FRAMES then
        manager.machine.video:snapshot()
        local f = assert(io.open(C.out .. "/wtiming.txt", "w"))
        f:write(string.format("vtotal %d\nframes %d\nerrors %d\n", C.vtotal, FRAMES, C.errors))
        if #C.inputs_missing > 0 then
            f:write("# inputs missing: " .. table.concat(C.inputs_missing, ", ") .. "\n")
        end
        for _, name in ipairs(names) do
            for _, kind in ipairs({"hist", "last"}) do
                local t, parts = (kind == "hist") and hist[name] or lastl[name], {}
                for l = 0, C.vtotal - 1 do parts[#parts + 1] = tostring(t[l] or 0) end
                f:write(kind .. " " .. name .. " " .. table.concat(parts, ",") .. "\n")
            end
            f:write(string.format("nfr %s %d\n", name, nfr[name]))
        end
        f:close()
        manager.machine:exit()
    end
end))
