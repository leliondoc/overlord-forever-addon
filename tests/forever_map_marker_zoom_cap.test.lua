-- Continent markers sized from the map (front domination logos, projected keeps and
-- outposts, world emblems) grow with the zoom. Blizzard's map zooms every map from 1 to
-- 2.14 times its fitted size (client data, read 2026-10-17); a map addon can zoom a
-- continent far deeper. Past the native maximum these markers stop growing; up to it,
-- nothing changes. Their positions never use the cap.
-- Real MapMarkers.lua, stub frames. Run from the addon root with Lua 5.1.
local methods = {}
local function frame(parent)
    return setmetatable({ parent = parent, strata = "MEDIUM", level = 1 }, { __index = methods })
end
function methods:GetParent() return self.parent end
function methods:GetFrameStrata() return self.strata end
function methods:GetFrameLevel() return self.level end
setmetatable(methods, { __index = function(_, name)
    if name:match("^Set") or name:match("^Register") or name == "Hide" or name == "Show"
        or name == "ClearAllPoints" then return function() end end
end })
function CreateFrame(_, _, parent) return frame(parent) end
C_Timer = { After = function() end }
Minimap = frame()
Overlord = { L = {}, UI = { ResolveLocalizedFontPath = function(_, fallback) return fallback end } }
OverlordDB = { config = {} }
assert(loadfile("MapMarkers.lua"))()
local MM = Overlord.MapMarkers
local cap = MM.CapMarkerScaleRatio
assert(type(cap) == "function", "the marker zoom cap is missing")

-- Blizzard's map canvas (1002 x 668) in a 1000 x 700 map window: fitted by its width.
local scale = 1
local canvas = { GetWidth = function() return 1002 end, GetHeight = function() return 668 end,
    GetEffectiveScale = function() return scale end }
local viewport = frame()
function viewport:GetWidth() return 1000 end
function viewport:GetHeight() return 700 end
local parent = frame(viewport)
function parent:GetEffectiveScale() return 1 end
local fit = 1000 / 1002

local function near(a, b) return math.abs(a - b) < 1e-9 end
-- Every native zoom step (1, 1.57, 2.14) keeps its ratio.
for _, zoom in ipairs({ 0.5, 1, 1.57, 2.14 }) do
    assert(near(cap(canvas, parent, fit * zoom), fit * zoom), "native zoom " .. zoom .. " was capped")
end
-- Deeper: the ratio stays at the native maximum (plus its rounding margin).
for _, zoom in ipairs({ 3, 10, 40 }) do
    assert(near(cap(canvas, parent, fit * zoom), fit * 2.15), "zoom " .. zoom .. " not capped")
end
-- A window fitted by its height: the fit follows the height.
function viewport:GetHeight() return 400 end
assert(near(cap(canvas, parent, 10), 400 / 668 * 2.15), "height-fitted window: wrong cap")
function viewport:GetHeight() return 700 end
-- No map window yet (layer not attached), or no size: unchanged.
assert(cap(canvas, frame(nil), 10) == 10, "capped without a map window")
assert(cap(canvas, nil, 10) == 10, "capped without a layer")
local empty = frame()
function empty:GetWidth() return 0 end
function empty:GetHeight() return 0 end
assert(cap(canvas, frame(empty), 10) == 10, "capped with an empty map window")

-- The domination logo (also the projected keep/outpost size): unchanged at native zoom,
-- held at its native maximum deeper.
scale = fit * 2.14
local nativeMax = MM:GetEKDominanceLogoSizeFor(canvas, parent)
assert(near(nativeMax, 1002 * 0.032 * fit * 2.14 * MM.GetMapIconScale()), "native logo size changed")
scale = fit * 12
local deep = MM:GetEKDominanceLogoSizeFor(canvas, parent)
assert(deep < nativeMax * 1.01, ("logo still grows past the native zoom: %.1f vs %.1f"):format(deep, nativeMax))

-- The world emblem: same rule, its position keeps the true ratio.
local placed = {}
local wf = setmetatable({}, { __index = _G })
wf._G = wf
wf.Overlord = Overlord
wf.GetTime = function() return 100 end
wf.C_Map = {
    GetMapInfo = function(id) return ({ [1414] = { parentMapID = 947 }, [1415] = { parentMapID = 947 } })[id] end,
    GetMapRectOnMap = function(id)
        if id == 1417 then return 0.7, 0.9, 0.2, 0.4 end
        if id == 1440 then return 0.1, 0.3, 0.2, 0.4 end
    end,
}
Overlord.IsInitialized = true
Overlord.Fronts = { Order = { "f1" }, Registry = { f1 = { id = "f1" } }, GetMapID = function() return 1417 end }
function Overlord:GetMapContinent() return "EK" end
setfenv(assert(loadfile("MapWorldEmblems.lua")), wf)()
function MM:GetWorldMapCanvas() return canvas, parent end
function MM:GetDominantFaction() return "Alliance" end
function MM:GetWorldMapOverlayPoint(_, _, x, yDown) placed.x, placed.y = x, yDown return x, -yDown end
function MM.NewFrame(_, p)
    local f = frame(p)
    function f:SetSize(w) self.size = w end
    function f:CreateTexture() return setmetatable({}, { __index = function() return function() end end }) end
    function f:Show() end
    return f
end
-- The emblem frame, caught at its creation (it is reused afterwards).
local lastFrame
local newFrame = MM.NewFrame
function MM.NewFrame(t, p) lastFrame = newFrame(t, p) return lastFrame end
local function emblemSize()
    MM:HideWorldEmblems()
    MM:RefreshWorldEmblems(947, true, true)
end
scale = fit * 2.14
emblemSize()
assert(lastFrame, "no world emblem painted")
local emblemNative = lastFrame.size
assert(emblemNative == math.floor(1002 * 0.09 * fit * 2.14 * MM.GetMapIconScale() + 0.5), "native emblem size changed")
scale = fit * 12
emblemSize()
assert(lastFrame.size <= emblemNative + 1, "world emblem still grows past the native zoom")
assert(near(placed.x, 0.8 * 1002), "emblem position moved by the size cap")

print("forever_map_marker_zoom_cap: ok")
