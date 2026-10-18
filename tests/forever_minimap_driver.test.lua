-- Minimap capture-zone pins (2026-10-17, players reported them jittering).
-- While the player moves, the minimap background moves every rendered frame: the pins
-- follow one tick per quarter pixel of scrolling, 60 Hz at most (2026-10-18: a tick at
-- every frame recomputed the same half-pixel place about 60 times a second). A zoom
-- of the minimap (event MINIMAP_UPDATE_ZOOM) or a resize takes effect at the next frame,
-- position and circle size, instead of up to half a second later. Walking moves a pin by
-- about 0.02 px a frame: pins are placed to the half pixel, so a walking pin is placed
-- again only a few times a second.
-- Real MapMarkers.lua, stub frames. Run from the addon root with Lua 5.1.
local frames = {}
local methods = {}
local function frame(parent)
    local f = setmetatable({ parent = parent, shown = false, scripts = {}, hooks = {}, events = {},
        w = 0, h = 0, points = 0 }, { __index = methods })
    frames[#frames + 1] = f
    return f
end
function methods:GetParent() return self.parent end
function methods:SetScript(name, fn) self.scripts[name] = fn end
function methods:GetScript(name) return self.scripts[name] end
function methods:HookScript(name, fn) self.hooks[name] = self.hooks[name] or {}; table.insert(self.hooks[name], fn) end
function methods:RegisterEvent(name) self.events[name] = true end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:IsShown() return self.shown end
function methods:SetSize(w, h) self.w, self.h = w, h end
function methods:GetWidth() return self.w end
function methods:GetHeight() return self.h end
function methods:SetPoint(_, _, _, x, y) self.points = self.points + 1; self.x, self.y = x, y end
function methods:CreateTexture()
    local t = frame(self)
    self.regions = self.regions or {}
    self.regions[#self.regions + 1] = t
    return t
end
function methods:GetRegions() return unpack(self.regions or {}) end
function methods:SetSnapToPixelGrid(on) self.snap = on end
function methods:CreateMaskTexture() return frame(self) end
function methods:CreateFontString() return frame(self) end
function methods:GetFrameLevel() return 1 end
function methods:GetFrameStrata() return "MEDIUM" end
function methods:GetEffectiveScale() return 1 end
-- Any other method is a no-op; plain fields stay nil, as on a real frame.
setmetatable(methods, { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return function() end end
end })

function CreateFrame(_, _, parent) return frame(parent) end
C_Timer = { After = function() end }
Minimap = frame()
Minimap:SetSize(200, 200)
Minimap.shown = true
Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }),
    UI = { ResolveLocalizedFontPath = function(_, fallback) return fallback end } }
OverlordDB = { config = {} }
assert(loadfile("MapMarkers.lua"))()
local MM = Overlord.MapMarkers
-- Keeps, outposts, generals (other files): absent here, so no-ops.
setmetatable(MM, { __index = function() return function() end end })

-- One front zone 10 % east of the player, on a map 1000 yards wide.
local now = 100
function GetTime() return now end
local speed, radius = 7, 233
local px = 0.40
function GetUnitSpeed() return speed end
function GetCVar() return "0" end
function GetPlayerFacing() return 0 end
function CreateVector2D(x, y) return { x = x, y = y } end
C_Minimap = { GetViewRadius = function() return radius end }
C_Map = {
    GetBestMapForUnit = function() return 1433 end,
    GetPlayerMapPosition = function() return { GetXY = function() return px, 0.5 end } end,
    GetWorldPosFromMapPos = function(_, v) return 0, { x = v.x * 1000, y = v.y * 1000 } end,
    GetMapInfo = function() return nil end,
}
local zone = { id = "z1", center = { 50, 50 }, radius = 5, owner = "Alliance" }
Overlord.IsInitialized = true
Overlord.InActiveFront = true
Overlord.ZoneDatabase = { zone }
Overlord.Fronts = setmetatable({
    GetCurrentFront = function() return { id = "redridge", zones = { zone } } end,
    IsFrontMapID = function() return true end,
    GetMapID = function() return 1433 end,
    ResolveFrontByOverlayMapID = function() return { id = "redridge" } end,
}, { __index = function() return function() return nil end end })
Overlord.Zones = setmetatable({ IsZoneAttackable = function() return false end },
    { __index = function() return function() return nil end end })

-- Only what the minimap driver needs; everything else of the module is out of scope here.
local ok, err = pcall(MM.InitializeMinimap, MM)
assert(ok, "minimap init failed: " .. tostring(err))
local driver
for _, f in ipairs(frames) do
    if f.events.PLAYER_STARTED_MOVING then driver = f end
end
assert(driver and driver.scripts.OnUpdate, "minimap driver not found")
assert(driver.events.MINIMAP_UPDATE_ZOOM, "the minimap zoom event is not listened to")
driver:Show()

local function tick(dt) now = now + dt; driver.scripts.OnUpdate(driver, dt) end
-- The zone pin: the frame whose SetPoint is driven by the player's position.
tick(0.6) -- first tick: full refresh, pins created and placed
local pin
for _, f in ipairs(frames) do
    if f.parent == Minimap and f.points > 0 and f ~= driver then pin = f end
end
assert(pin, "no zone pin placed on the minimap")

-- Moving at 144 Hz: the pin moves at 60 Hz at most, not at every frame (CPU).
local before = pin.points
for i = 1, 30 do
    px = px + 0.0005
    tick(1 / 144)
end
assert(pin.points - before >= 1 and pin.points - before <= 13,
    ("pin moved %d times in 30 frames at 144 Hz"):format(pin.points - before))
assert(pin.regions and #pin.regions > 0, "zone pin has no texture")
-- Walking pace (7 yd/s at 144 Hz, about 0.02 px a frame): placed to the half pixel, the
-- pin stays within a quarter pixel of its place plus a quarter pixel of scrolling per tick,
-- and is placed again only a few times a second (CPU), far fewer than the frames.
local pxPerYard = 100 / 233
local worst = 0
before = pin.points
for i = 1, 60 do
    px = px + 7 / 144 / 1000
    tick(1 / 144)
    local exact = (50 - px * 100) * 10 * pxPerYard
    if i > 3 then worst = math.max(worst, math.abs(pin.x - exact)) end
end
-- (Half-pixel placement, plus at most one tick of scrolling: a quarter pixel, plus the
-- frames of a tick's reliquat.)
assert(worst <= 0.25 + 0.25 + 3 * 0.021 + 1e-9, ("walking pace: pin %.3f px off its place"):format(worst))
assert(pin.points - before >= 1 and pin.points - before <= 5, "walking pace: SetPoint count " .. (pin.points - before))

-- Walking pace: the driver ticks with the scrolling (a quarter pixel a tick), not at
-- every frame. 3 px/s here (7 yd/s, 100 px for 233 yd): about 12 ticks a second.
local reads = 0
local bestMap = C_Map.GetBestMapForUnit
C_Map.GetBestMapForUnit = function(...) reads = reads + 1; return bestMap(...) end
local function ticksIn(seconds)
    reads = 0
    for i = 1, math.floor(seconds * 144) do
        px = px + speed / 144 / 1000
        tick(1 / 144)
    end
    return reads
end
local walking = ticksIn(1)
assert(walking >= 8 and walking <= 16, "walking pace: " .. walking .. " ticks in a second")
-- Faster (a flying mount) or a closer zoom: the pace follows, still 60 Hz at most.
speed = 30
local flying = ticksIn(1)
assert(flying > walking * 3 and flying <= 61, "flying pace: " .. flying .. " ticks in a second")
speed = 7
-- Turning with a rotating minimap: every frame, 60 Hz at most (pins sweep around it).
local rotate, facingNow = "1", 0
GetCVar = function() return rotate end
GetPlayerFacing = function() facingNow = facingNow + 0.01; return facingNow end
tick(0.6) -- full refresh: the rotation setting is read
local turning = ticksIn(1)
assert(turning >= 50 and turning <= 61, "turning pace: " .. turning .. " ticks in a second")
-- Walking straight with a rotating minimap: every frame too (a turn would only be seen at
-- the next tick, and the edge pins sweep far faster than the scrolling: 2.0.5's pace).
GetPlayerFacing = function() return facingNow end
local straight = ticksIn(1)
assert(straight >= 50 and straight <= 61, "rotating minimap, walking: " .. straight .. " ticks in a second")
GetCVar = function() return "0" end
GetPlayerFacing = function() return 0 end
tick(0.6)
-- The game may hand the speed back as a secret value: it cannot be compared (an error
-- at every tick stopped the pins, reported 2026-10-18). Read as unknown: ticks as if
-- moving, 60 Hz, as 2.0.5 did. (A table stands for it: comparing one raises an error.)
local secret = {}
local unitSpeed = GetUnitSpeed
GetUnitSpeed = function() return secret end
local okSecret, secretTicks = pcall(ticksIn, 1)
assert(okSecret, "secret speed: " .. tostring(secretTicks))
assert(secretTicks >= 50 and secretTicks <= 61, "secret speed pace: " .. secretTicks .. " ticks in a second")
GetUnitSpeed = unitSpeed
tick(0.6)
-- A hidden facing (rotating minimap): no error, the last facing is kept, every frame.
GetCVar = function() return "1" end
GetPlayerFacing = function() return secret end
local okFacing, facingTicks = pcall(function() tick(0.6); return ticksIn(0.5) end)
assert(okFacing, "secret facing: " .. tostring(facingTicks))
assert(facingTicks >= 25, "secret facing pace: " .. facingTicks .. " ticks in half a second")
GetCVar = function() return "0" end
GetPlayerFacing = function() return 0 end
tick(0.6)
-- A hidden position: no error, and nothing disappears: the pin stays where it was, then
-- follows again once the position can be read.
local shownBefore, xBefore = pin.shown, pin.x
local mapPosition = C_Map.GetPlayerMapPosition
C_Map.GetPlayerMapPosition = function() return { GetXY = function() return secret, secret end } end
local okPos, errPos = pcall(function() tick(0.6); px = px + 0.01; tick(0.6) end)
assert(okPos, "secret position: " .. tostring(errPos))
assert(pin.shown == shownBefore and pin.x == xBefore, "a hidden position moved or hid the pin")
C_Map.GetPlayerMapPosition = mapPosition
tick(0.6)
assert(pin.shown and pin.x ~= xBefore, "the pin did not follow the position again")
C_Map.GetBestMapForUnit = bestMap
-- Standing still with a forced refresh: no SetPoint for a pin that did not move.
speed = 0
tick(0.6)
before = pin.points
tick(0.6)
assert(pin.points == before, "a still pin is placed again")
speed = 7

-- Stopped, then the minimap zooms in: next frame, new position and new circle size.
speed = 0
tick(1 / 144)
tick(0.6)
local x0, w0 = pin.x, pin.w
radius = 116.5 -- twice as close
driver.scripts.OnEvent(driver, "MINIMAP_UPDATE_ZOOM")
tick(1 / 144)
assert(math.abs(pin.x - x0 * 2) < 1, ("pin not moved by the zoom at once: %s -> %s"):format(x0, pin.x))
assert(pin.w > w0 * 1.5, ("circle not resized by the zoom at once: %s -> %s"):format(w0, pin.w))

-- Resized minimap: same (a little later, the forced refreshes are spaced 0.1 s apart).
local function resize(size)
    Minimap:SetSize(size, size)
    for _, fn in ipairs(Minimap.hooks.OnSizeChanged or {}) do fn(Minimap, size, size) end
end
now = now + 0.2
local x1 = pin.x
resize(100)
tick(1 / 144)
assert(math.abs(pin.x - x1 / 2) < 1, ("pin not moved by the resize at once: %s -> %s"):format(x1, pin.x))
-- A resize at every frame (Edit Mode drag): at most one forced refresh per 0.1 s, and the
-- last size is applied within 0.1 s.
local x2 = pin.x
resize(200)
local frames = 0
while math.abs(pin.x - x2 * 2) >= 1 and frames < 30 do
    tick(1 / 144)
    frames = frames + 1
end
assert(frames <= 15, "resize burst: last size applied after " .. frames .. " frames")

print("Minimap driver: pace follows the scrolling, zoom and resize at the next frame OK")
