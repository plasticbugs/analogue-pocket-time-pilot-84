-- Dump one frozen Time Pilot '84 machine state plus the MAME snapshot of
-- exactly that state.
--
-- Like Time Pilot, this game rewrites sprite RAM part way down the frame (MAME
-- forces update_partial on every sprite RAM write), so the frame MAME renders
-- is not a function of the sprite RAM you can read at the end of it.
--
-- Time Pilot froze the machine by parking the CPU in a jump-to-self. That does
-- not work here: setting PC through MAME's state interface does not redirect
-- MAME's 6809, and the slave runs away instead -- measurably so, advancing
-- exactly 0x2156 bytes a frame, which is NEG-direct through unmapped space at
-- six cycles per two bytes.
--
-- So the video STATE is frozen rather than the CPUs. Everything the renderer
-- reads is copied into Lua tables, and write taps then return those saved
-- values, cancelling any further change. The CPUs keep running and MAME keeps
-- doing its partial updates, but every slice it renders now draws the same
-- picture -- which is exactly the static frame a static renderer can be held
-- to. The dump is written from the same saved tables, so it cannot drift from
-- what was drawn.
--
-- usage: TP_FRAME=900 TP_TAG=0900 mame tp84 -autoboot_script tools/dumpstate.lua

local OUT    = os.getenv("TP_OUT")   or "artifacts"
local TARGET = tonumber(os.getenv("TP_FRAME") or "900")
local TAG    = os.getenv("TP_TAG")   or string.format("%04d", TARGET)
local MODE   = os.getenv("TP_MODE")  or "1p"

local mach   = manager.machine
local cpu1   = mach.devices[":cpu1"]
local sub    = mach.devices[":sub"]
local sp1    = cpu1.spaces["program"]
local sp2    = sub.spaces["program"]
local shares = mach.memory.shares

-- The LS259 bits are driver members, not a memory share, so track them by
-- watching the writes. flip X and flip Y are what the renderer needs.
local latch = {}
for i = 0, 7 do latch[i] = 0 end
sp1:install_write_tap(0x3000, 0x3007, "ls259", function(offset, data, mask)
    latch[offset & 7] = data & 1
    return data
end)

local ports = mach.ioport.ports
local function field(p, n) local q = ports[p]; return q and q.fields[n] or nil end
local coin  = field(":SYSTEM", "Coin 1")
local st1   = field(":SYSTEM", "1 Player Start")
local st2
do
    local p = ports[":SYSTEM"]
    if p then for name, f in pairs(p.fields) do if name:find("2 Player") then st2 = f end end end
end
local b1    = field(":P1", "P1 Button 1")
local b2    = field(":P1", "P1 Button 2")
local left  = field(":P1", "P1 Left")
local right = field(":P1", "P1 Right")

local frame, frozen_at = 0, nil
local function hold(f, on) if f then f:set_value(on and 1 or 0) end end

-- Everything the video model reads, and the taps that hold it still.
local FROZEN = {}
local REGIONS = {
    { name = "BGVIDEORAM",  share = ":bg_videoram",  len = 0x400, space = "cpu1", lo = 0x4000 },
    { name = "FGVIDEORAM",  share = ":fg_videoram",  len = 0x400, space = "cpu1", lo = 0x4400 },
    { name = "BGCOLORRAM",  share = ":bg_colorram",  len = 0x400, space = "cpu1", lo = 0x4800 },
    { name = "FGCOLORRAM",  share = ":fg_colorram",  len = 0x400, space = "cpu1", lo = 0x4c00 },
    { name = "SPRITERAM",   share = ":spriteram",    len = 0x60,  space = "sub",  lo = 0x67a0 },
    { name = "PALETTEBANK", share = ":palette_bank", len = 1,     space = "cpu1", lo = 0x2800 },
    { name = "SCROLLX",     share = ":scroll_x",     len = 1,     space = "cpu1", lo = 0x3c00 },
    { name = "SCROLLY",     share = ":scroll_y",     len = 1,     space = "cpu1", lo = 0x3e00 },
}

local function freeze()
    for _, r in ipairs(REGIONS) do
        local sh, t = shares[r.share], {}
        for i = 0, r.len - 1 do t[i] = sh:read_u8(i) end
        FROZEN[r.name] = t
        local sp = (r.space == "cpu1") and sp1 or sp2
        local lo, hi = r.lo, r.lo + r.len - 1
        sp:install_write_tap(lo, hi, "frz_" .. r.name, function(offset, data, mask)
            return t[(offset - lo) % r.len] or data
        end)
    end
    print(string.format("[tp84] video state frozen at frame %d  flipx=%d flipy=%d",
                        frame, latch[4], latch[5]))
end

local function dump()
    local f = assert(io.open(string.format("%s/state_%s.txt", OUT, TAG), "w"))
    f:write(string.format("frame %d\n", frozen_at))
    f:write(string.format("flipx %d\n", latch[4]))
    f:write(string.format("flipy %d\n", latch[5]))
    for _, r in ipairs(REGIONS) do
        f:write(r.name, "\n")
        local t, line = FROZEN[r.name], {}
        for i = 0, r.len - 1 do
            line[#line + 1] = string.format("%02x", t[i])
            if #line == 32 then f:write(table.concat(line), "\n"); line = {} end
        end
        if #line > 0 then f:write(table.concat(line), "\n") end
    end
    f:write("END\n")
    f:close()
    mach.video:snapshot()
    print(string.format("[tp84] dumped %s", TAG))
    mach:exit()
end

emu.register_frame_done(function()
    frame = frame + 1
    if frozen_at then
        if frame == frozen_at + 2 then dump() end
        return
    end
    if MODE == "2p" then
        hold(coin, (frame >= 600 and frame < 604) or (frame >= 620 and frame < 624))
        hold(st2,  frame >= 660 and frame < 664)
    else
        hold(coin, frame >= 600 and frame < 604)
        hold(st1,  frame >= 660 and frame < 664)
    end
    if frame > 700 then
        hold(b1, true)
        hold(b2, (frame // 30) % 4 == 0)
        hold(right, (frame // 60) % 2 == 0)
        hold(left,  (frame // 60) % 2 == 1)
    end
    if frame == TARGET then freeze(); frozen_at = frame end
end)

print("[tp84] dumpstate.lua armed for frame " .. TARGET)
