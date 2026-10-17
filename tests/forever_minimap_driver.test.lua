-- Minimap capture-zone pins (2026-10-17, players reported them jittering).
-- While the player moves, the minimap background moves every rendered frame: the pins
-- follow at 60 Hz at most (every frame cost 2.4 times the work at 144 Hz). A zoom
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
-- pin stays within a quarter pixel of its place plus the frames between two 60 Hz ticks,
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
assert(worst <= 0.25 + 3 * 0.021 + 1e-9, ("walking pace: pin %.3f px off its place"):format(worst))
assert(pin.points - before >= 1 and pin.points - before <= 5, "walking pace: SetPoint count " .. (pin.points - before))
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

print("Minimap driver: 60 Hz while moving, zoom and resize at the next frame OK")
