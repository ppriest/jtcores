-- Z80 program reads through a direct-mapped cache, for scripts/z80_cache.py.
--   ZC_SIZE    cache bytes (16384)
--   ZC_LINES   line sizes in bytes to model, comma-separated ("4,8")
--   ZC_SKIP, ZC_FRAMES, ZC_COIN   as write_timing (common.lua)
-- The Z80 reads 0000-7fff directly and 8000-bfff through the bank at f800
-- (xexex.cpp:612-618); the cache sees the ROM address. Output CORE_OUT/z80cache.txt:
--   reads N
--   line L misses N maxline M       M: the most misses in any one scanline
--   perline L c0,c1,...             scanlines with that many misses (0..63+)

local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local SIZE = tonumber(os.getenv("ZC_SIZE") or "16384")
local SKIP = tonumber(os.getenv("ZC_SKIP") or "600")
local FRAMES = tonumber(os.getenv("ZC_FRAMES") or "1800")
local COIN = tonumber(os.getenv("ZC_COIN") or "0")
local snd = manager.machine.devices[":audiocpu"].spaces["program"]

local caches = {}
for s in string.gmatch(os.getenv("ZC_LINES") or "4,8", "(%d+)") do
    local L = tonumber(s)
    caches[#caches + 1] = { L = L, n = SIZE // L, tag = {}, misses = 0, maxline = 0,
                            perline = {}, cur = -1, curn = 0 }
end

local bank, reads, counting = 0, 0, false
_G.__zc_bank = snd:install_write_tap(0xf800, 0xf800, "zc_bank",
    C.guard("bank", function(offset, data, mask) bank = data & 7 end))

local function close_line(c)
    if c.cur >= 0 then
        local k = math.min(c.curn, 63)
        c.perline[k] = (c.perline[k] or 0) + 1
        if c.curn > c.maxline then c.maxline = c.curn end
    end
end

_G.__zc_read = snd:install_read_tap(0x0000, 0xbfff, "zc_read",
    C.guard("read", function(offset, data, mask)
        if not counting then return end
        reads = reads + 1
        local a = offset < 0x8000 and offset or (bank * 0x4000 + (offset - 0x8000))
        local l = nil
        for _, c in ipairs(caches) do
            local ln = a // c.L
            local idx = ln % c.n
            if c.tag[idx] ~= ln then
                c.tag[idx] = ln
                c.misses = c.misses + 1
                l = l or math.floor(manager.machine.time:as_double() / C.line_period)
                if l ~= c.cur then close_line(c); c.cur = l; c.curn = 0 end
                c.curn = c.curn + 1
            end
        end
    end))

local n = 0
_G.__zc_frame = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    if n == SKIP then counting = true end
    if n == SKIP + FRAMES then
        local f = assert(io.open(C.out .. "/z80cache.txt", "w"))
        f:write(string.format("reads %d\nframes %d\nsize %d\nerrors %d\n", reads, FRAMES, SIZE, C.errors))
        for _, c in ipairs(caches) do
            close_line(c)
            f:write(string.format("line %d misses %d maxline %d\n", c.L, c.misses, c.maxline))
            local parts = {}
            for k = 0, 63 do parts[#parts + 1] = tostring(c.perline[k] or 0) end
            f:write(string.format("perline %d %s\n", c.L, table.concat(parts, ",")))
        end
        f:close()
        manager.machine:exit()
    end
end))
