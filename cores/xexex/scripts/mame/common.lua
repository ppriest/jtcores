-- Shared by the capture scripts: scanline, play stimulus, guarded callbacks.
-- Load with: local C = dofile(dir .. "common.lua")
--
-- MAME's Lua screen binding has no vpos()/hpos(). The line is derived from
-- time_until_pos(0): elapsed time since line 0, divided by the line period.
-- vtotal comes out as the driver's 289.

local C = {}
local mach = manager.machine
C.scr = mach.screens[":screen"]
C.prog = mach.devices[":maincpu"].spaces["program"]
C.out = os.getenv("CORE_OUT") or "."

local scr = C.scr
C.frame_period = 1.0 / scr.refresh
for _ = 1, 64 do
    local d = scr:time_until_pos(1) - scr:time_until_pos(0)
    if d > 0 and (C.line_period == nil or d < C.line_period) then C.line_period = d end
end
C.vtotal = math.floor(C.frame_period / C.line_period + 0.5)

-- Line the beam is on now (floor: a write late in line L counts as L).
function C.cur_line()
    local e = (C.frame_period - scr:time_until_pos(0)) / C.line_period
    return math.floor(e + 1e-6) % C.vtotal
end

-- Callback errors inside taps and notifiers are swallowed by MAME. guard()
-- records the first one in lua_error.txt, which mame_run.py reads back.
C.errors = 0
function C.guard(what, fn)
    return function(...)
        local ok, r = pcall(fn, ...)
        if not ok then
            C.errors = C.errors + 1
            if C.errors == 1 then
                local f = io.open(C.out .. "/lua_error.txt", "w")
                if f then f:write(what .. ": " .. tostring(r) .. "\n"); f:close() end
            end
            return nil
        end
        return r
    end
end

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end

-- Play stimulus from frame `coin` (0 = attract): a coin every 300 frames and
-- Start 150 frames after each, so credits pile up and continues are taken
-- (a coin in the first boot frames is ignored by the game); fire auto-pulsed,
-- button 2 now and then, the stick cycling up / centre / down / centre with
-- right held half the time.
local IN = {}
for _, n in ipairs({"Coin 1", "1 Player Start", "P1 Up", "P1 Down", "P1 Right",
                    "P1 Button 1", "P1 Button 2"}) do IN[n] = field(n) end
C.inputs_missing = {}
for _, n in ipairs({"Coin 1", "1 Player Start", "P1 Up", "P1 Down", "P1 Right",
                    "P1 Button 1", "P1 Button 2"}) do
    if not IN[n] then C.inputs_missing[#C.inputs_missing + 1] = n end
end

local function set(n, v) if IN[n] then IN[n]:set_value(v and 1 or 0) end end

function C.stimulus(n, coin)
    if coin <= 0 or n < coin then return end
    local t = n - coin
    set("Coin 1", t % 300 < 8)
    set("1 Player Start", t % 300 >= 150 and t % 300 < 158)
    if t < 158 then return end
    local ph = (n // 30) % 4
    set("P1 Up", ph == 0)
    set("P1 Down", ph == 2)
    set("P1 Right", (n // 120) % 2 == 0)
    set("P1 Button 1", n % 8 < 4)
    set("P1 Button 2", n % 240 < 4)
end

return C
