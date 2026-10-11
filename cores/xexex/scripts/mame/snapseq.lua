-- A snapshot every SS_STEP frames from SS_FROM to SS_TO, attract mode, for matching
-- board screenshots to MAME frames (game speed). CORE_OUT/snapseq.txt lists the frame
-- of each snapshot, in the order MAME numbers the files.
local dir = os.getenv("CORE_SCRIPT"):match("^(.*[/\\])")
local C = dofile(dir .. "common.lua")
local FROM = tonumber(os.getenv("SS_FROM") or "600")
local TO   = tonumber(os.getenv("SS_TO") or "6000")
local STEP = tonumber(os.getenv("SS_STEP") or "4")
local out = assert(io.open(C.out .. "/snapseq.txt", "w"))
_G.__ss = emu.add_machine_frame_notifier(C.guard("frame", function()
    local f = C.scr:frame_number()
    if f >= FROM and (f - FROM) % STEP == 0 then
        manager.machine.video:snapshot()
        out:write(f, "\n")
    end
    if f >= TO then out:close(); manager.machine:exit() end
end))
