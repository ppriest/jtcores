-- Per-frame K053250 state as MAME draws it, for scripts/k053250_survey.py.
--   SV_FRAMES  frames to run
--   SV_COIN    play stimulus from this frame (0 = attract)
--   SV_SNAPS   max automatic snapshots: one at the first drawn frame of each new
--              (reg4 & 0xfd) value, then one every SV_EVERY frames
--   SV_EVERY   periodic snapshot interval (0 = none)
--
-- Mirrors k053250.cpp: the CPU writes RAM at 0c6000; a falling edge of reg 4
-- bit 1 copies the first 0x1000 bytes into buffer[page] and flips page (once a
-- frame); draw() reads buffer[page]. RAM is shadowed from the write tap, the
-- two buffers are kept here. At each frame notifier (after MAME's draw at line
-- 256) the lines draw() would fetch for the visible area are walked with the
-- same offsets and rejections, and their zoom words (packet word 2) summarised.
--
-- Output CORE_OUT/k053250.txt, one line a frame:
--   frame ctrl sx sy drawn zmin zmax z40 dmas dmaline
-- ctrl = reg 4 at draw time; sx/sy = regs 0-1 / 2-3 (signed); drawn = lines not
-- rejected; z40 = drawn lines with zoom 0x40; dmaline = line of the last DMA
-- this frame (-1 none). '# snap N frame F' records each snapshot.

local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local FRAMES = tonumber(os.getenv("SV_FRAMES") or "3000")
local COIN = tonumber(os.getenv("SV_COIN") or "0")
local MAXSNAP = tonumber(os.getenv("SV_SNAPS") or "0")
local EVERY = tonumber(os.getenv("SV_EVERY") or "0")
local scr = C.scr

-- Screen visible area (set_raw: x 40-423, y 0-255) and the chip offsets (xexex.cpp:722).
local MINX, MAXX, MINY, MAXY, OFFX, OFFY = 40, 423, 0, 255, -5, -16

local ram, buf, regs = {}, {{}, {}}, {}
for i = 0, 0x7ff do ram[i] = 0; buf[1][i] = 0; buf[2][i] = 0 end
for i = 0, 15 do regs[i] = 0 end
local page, dma_frame = 1, -1
local dmas, dmaline = 0, -1

local out = assert(io.open(C.out .. "/k053250.txt", "w"))
out:write("# frame ctrl sx sy drawn zmin zmax z40 dmas dmaline\n")

_G.__sv = {}
_G.__sv[1] = C.prog:install_write_tap(0x0c6000, 0x0c6fff, "sv_ram", C.guard("ram", function(offset, data, mask)
    local i = (offset - 0x0c6000) >> 1
    ram[i] = (ram[i] & ~mask & 0xffff) | (data & mask)
end))
_G.__sv[2] = C.prog:install_write_tap(0x0c8000, 0x0c800f, "sv_reg", C.guard("reg", function(offset, data, mask)
    if mask & 0xff == 0 then return end
    local r, v = (offset - 0x0c8000) >> 1, data & 0xff
    if r == 4 and (v & 2) == 0 and (regs[4] & 2) ~= 0 then
        local f = scr:frame_number()
        if f ~= dma_frame then
            dma_frame = f
            local b = buf[page]
            for i = 0, 0x7ff do b[i] = ram[i] end
            page = 3 - page
            dmas = dmas + 1
            dmaline = C.cur_line()
        end
    end
    regs[r] = v
end))

local function s16(v) return (v >= 0x8000) and (v - 0x10000) or v end

local function survey()
    local b = buf[page]
    local ctrl = regs[4]
    local sx = s16((regs[0] << 8) | regs[1])
    local sy = s16((regs[2] << 8) | regs[3])
    local swap, fx, fy = (ctrl & 1) == 0, (ctrl & 8) ~= 0, (ctrl & 0x10) ~= 0
    local adv, offs, first, last = 4, 0, 0, 0
    if not swap then
        first, last, offs = MINY, MAXY, sy - OFFY
        if fy then adv = -4; offs = offs + MAXY end
    else
        first, last, offs = MINX, MAXX, sx - OFFX
        if fy then offs = offs - 5 end
        if fx then adv = -4; offs = offs + MAXX end
    end
    offs = ((offs * 4) & 0x7ff) + first * adv
    local drawn, zmin, zmax, z40 = 0, 0xffff, -1, 0
    for _ = first, last do
        offs = offs & 0x7ff
        local color = b[offs]
        if color ~= 0xffff then
            local o = b[offs + 1]
            if (color & 0xff) ~= 0 or o ~= 0 then
                local z = b[offs + 2]
                drawn = drawn + 1
                if z < zmin then zmin = z end
                if z > zmax then zmax = z end
                if z == 0x40 then z40 = z40 + 1 end
            end
        end
        offs = offs + adv
    end
    if drawn == 0 then zmin, zmax = -1, -1 end
    return ctrl, sx, sy, drawn, zmin, zmax, z40
end

local n, nsnap, seen = 0, 0, {}
_G.__sv_frame = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    local f = scr:frame_number()
    local ctrl, sx, sy, drawn, zmin, zmax, z40 = survey()
    out:write(string.format("%d %02x %d %d %d %d %d %d %d %d\n", f, ctrl, sx, sy, drawn, zmin, zmax, z40, dmas, dmaline))
    dmas, dmaline = 0, -1
    local key = ctrl & 0xfd
    local snap = false
    if drawn > 0 and not seen[key] then seen[key] = true; snap = true end
    if EVERY > 0 and n % EVERY == 0 then snap = true end
    if snap and nsnap < MAXSNAP then
        manager.machine.video:snapshot()
        out:write(string.format("# snap %d frame %d ctrl %02x\n", nsnap, f, ctrl))
        nsnap = nsnap + 1
    end
    if n >= FRAMES then
        out:write(string.format("# end, lua errors %d\n", C.errors))
        out:close()
        manager.machine:exit()
    end
end))
