-- Video state at chosen frames, for bench/video: a snapshot PNG and, in
-- CORE_OUT/state-<frame>.txt, the writes that rebuild that state through the CPU bus.
--   VS_FRAMES  frames (MAME frame_number) to capture, comma-separated; exits after the last
--   VS_COIN    play stimulus from this frame (0 = attract)
--
-- Registers come from write taps since boot: the last value written to each byte,
-- which is what the chips hold (the K053246 keeps no save items in this MAME). Tile
-- pages and the palette come from save items in the frame notifier, after MAME has
-- drawn the frame from them (at line 256, xexex.cpp:705).
--
-- Sprite RAM is taken as the object DMA copied it for the frame drawn: the DMA of the
-- frame before. MAME runs the DMA at line 256 and raises IRQ4 straight after
-- (xexex.cpp interrupt), so the IRQ4 vector fetch sees what the DMA saw. With that
-- copy, scripts/video_model.py matches MAME's frames 13000 and 20000 of play exactly;
-- with the sprite RAM of the capture frame it does not.
--
-- state-<frame>.txt: one write a line, "W addr data mask" in hex, word addressed as the
-- 68000 bus. Tile pages are "P page" then 4096 words at 180000; bench/video sets
-- register 0x32 for the page itself.
--
-- The K053250 keeps two line tables the CPU cannot write (k053250.cpp m_buffer). "D" is a
-- DMA strobe (register 4 bit 1 falling: RAM 0c6000-0c6fff to buffer[page], then flip the
-- page). From reset (page 0) the state writes the displayed table, D, the other table, D,
-- so that buffer 0 is displayed as in MAME, then the CPU's RAM as it is.

local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local COIN = tonumber(os.getenv("VS_COIN") or "0")
local scr, prog = C.scr, C.prog
local devs = manager.machine.devices

local want, last = {}, 0
for f in string.gmatch(os.getenv("VS_FRAMES") or "", "(%d+)") do
    f = tonumber(f); want[f] = true; if f > last then last = f end
end

-- register byte images, from writes since boot
local REGS = {
    { 0x0c0000, 0x0c003f },  -- K054157 (VACSET)
    { 0x0c2000, 0x0c2007 },  -- K053246 (OBJSET1)
    { 0x0c8000, 0x0c800f },  -- K053250, low bytes
    { 0x0ca000, 0x0ca01f },  -- K054338
    { 0x0cc000, 0x0cc01f },  -- K053251, low bytes
    { 0x0d0000, 0x0d001f },  -- K053252, low bytes
    { 0x0d8000, 0x0d8007 },  -- K054157 B (VSCCS)
    { 0x0de000, 0x0de001 },  -- control2
}
local reg = {}     -- byte address -> value
_G.__vs = {}
for _, r in ipairs(REGS) do
    _G.__vs[#_G.__vs + 1] = prog:install_write_tap(r[1], r[2], string.format("vs_%x", r[1]),
        C.guard("tap", function(offset, data, mask)
            if mask & 0xff00 ~= 0 then reg[offset]     = (data >> 8) & 0xff end
            if mask & 0x00ff ~= 0 then reg[offset + 1] = data & 0xff end
        end))
end

local function item(tag, name)
    local d = devs[tag]
    local idx = d and d.items and d.items[name]
    assert(idx, "no save item " .. tag .. " " .. name)
    return emu.item(idx)
end
local vram = item(":k056832", "0/m_videoram")
local pal  = item(":maincpu", "0/:palette")
local spr  = item(":maincpu", "0/:spriteram")
local lram = item(":k053250", "0/m_ram")      -- 0x3000 words: CPU RAM, then the buffers
local lpage = item(":k053250", "0/m_page")

-- sprite RAM at the IRQ4 of the frame before each capture
local dma_spr = {}
local before = {}
for f in pairs(want) do before[f - 1] = true end
_G.__vs_irq = prog:install_read_tap(0x70, 0x71, "vs_irq4", C.guard("irq4", function(offset, data, mask)
    local f = scr:frame_number()
    if before[f] and not dma_spr[f] then
        local t = {}
        for i = 0, 16383 do t[i] = spr:read(i) end
        dma_spr[f] = t
    end
end))

local function dump(f)
    local out = assert(io.open(string.format("%s/state-%d.txt", C.out, f), "w"))
    out:write(string.format("# xexex frame %d, line %d\n", f, C.cur_line()))
    for page = 0, 15 do
        local nz = false
        for i = 0, 4095 do if vram:read(page * 4096 + i) ~= 0 then nz = true; break end end
        if nz then
            out:write(string.format("P %d\n", page))
            for i = 0, 4095 do
                out:write(string.format("W %06X %04X FFFF\n", 0x180000 + 2 * i, vram:read(page * 4096 + i)))
            end
        end
    end
    for i = 0, 4095 do out:write(string.format("W %06X %04X FFFF\n", 0x1b0000 + 2 * i, pal:read(i))) end
    local t = assert(dma_spr[f - 1], "no IRQ4 in the frame before " .. f)
    for i = 0, 16383 do out:write(string.format("W %06X %04X FFFF\n", 0x090000 + 2 * i, t[i])) end
    local pg = lpage:read(0)
    for _, b in ipairs({ pg, 1 - pg }) do
        for i = 0, 0x7ff do
            out:write(string.format("W %06X %04X FFFF\n", 0x0c6000 + 2 * i, lram:read(0x2000 + 0x800 * b + i)))
        end
        out:write("D\n")
    end
    for i = 0, 0xfff do out:write(string.format("W %06X %04X FFFF\n", 0x0c6000 + 2 * i, lram:read(i))) end
    -- registers last, in address order; control2 and the K054157 page register after
    -- the RAMs they would otherwise disturb
    local addrs = {}
    for a in pairs(reg) do if a % 2 == 0 or reg[a - 1] == nil then addrs[#addrs + 1] = a - a % 2 end end
    table.sort(addrs)
    local done = {}
    for _, a in ipairs(addrs) do
        if not done[a] then
            done[a] = true
            local hi, lo = reg[a], reg[a + 1]
            local mask = (hi and 0xff00 or 0) | (lo and 0x00ff or 0)
            out:write(string.format("W %06X %04X %04X\n", a, ((hi or 0) << 8) | (lo or 0), mask))
        end
    end
    out:close()
    manager.machine.video:snapshot()
end

local n = 0
_G.__vs_frame = emu.add_machine_frame_notifier(C.guard("frame", function()
    n = n + 1
    C.stimulus(n, COIN)
    local f = scr:frame_number()
    if want[f] then dump(f) end
    if f >= last then manager.machine:exit() end
end))
