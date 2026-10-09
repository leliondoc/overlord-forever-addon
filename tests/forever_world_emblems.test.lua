-- 1.8.0: on the world map, a large faction emblem over Kalimdor and over the Eastern
-- Kingdoms shows the faction that dominates the most fronts of that continent (no
-- emblem on a tie). Other maps never show it, an unchanged map is not repainted, and
-- nothing shows in an instance.
local maps = {
    [947] = { mapID = 947, mapType = 1, parentMapID = 946 },
    [1414] = { mapID = 1414, mapType = 2, parentMapID = 947 },
    [1415] = { mapID = 1415, mapType = 2, parentMapID = 947 },
}
local rects = { -- normalized rect of a map on the world map 947
    [1440] = { 0.15, 0.29, 0.32, 0.42 }, [1417] = { 0.79, 0.87, 0.29, 0.37 }, -- higher than Ashenvale
    [1414] = { 0.04, 0.40, 0.10, 0.98 }, [1415] = { 0.64, 1.00, 0.02, 0.98 },
}
local continentOf = { [1411] = "K", [1440] = "K", [1413] = "K", [1417] = "EK", [1429] = "EK", [1433] = "EK", [1424] = "EK" }

local clock, setPoints, created = 100, 0, 0
local function newFrame(parent)
    local f = { shown = true, parent = parent }
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:GetParent() return self.parent end
    function f:SetParent(p) self.parent = p end
    function f:SetFrameStrata() end
    function f:GetFrameStrata() return "HIGH" end
    function f:SetFrameLevel(l) self.level = l end
    function f:GetFrameLevel() return self.level or 10 end
    function f:SetSize(w) self.size = w end
    function f:ClearAllPoints() end
    function f:SetPoint(_, _, _, x, y) setPoints = setPoints + 1; self.x, self.y = x, y end
    function f:CreateTexture()
        local t = {}
        function t:SetAllPoints() end
        function t:SetAlpha() end
        function t:SetTexture(path) self.path = path end
        return t
    end
    return f
end
local canvas = { GetWidth = function() return 1000 end, GetHeight = function() return 666 end,
    GetEffectiveScale = function() return 1 end }
local parent = newFrame(nil)
parent.GetEffectiveScale = function() return 1 end

-- Owner of each front: fully held fronts are dominated (the real rule is in MapMarkers).
local fronts = {}
local function setFronts(list)
    local order, registry = {}, {}
    for i, f in ipairs(list) do
        local id = "f" .. i
        order[i] = id
        registry[id] = { id = id, mapID = f[1], owner = f[2] }
    end
    fronts.Order, fronts.Registry = order, registry
end
function fronts:GetMapID(id) return self.Registry[id] and self.Registry[id].mapID end

local e = setmetatable({}, { __index = _G })
e._G = e
e.GetTime = function() return clock end
e.C_Map = {
    GetMapInfo = function(id) return maps[id] end,
    GetMapRectOnMap = function(id, world)
        local r = world == 947 and rects[id]
        if r then return r[1], r[2], r[3], r[4] end
    end,
}
e.Overlord ={ IsInitialized = true, Fronts = fronts }
function e.Overlord:GetMapContinent(mapID) return continentOf[mapID] end
setfenv(assert(loadfile("MapWorldEmblems.lua")), e)()
local mm = e.Overlord.MapMarkers
function mm:GetWorldMapCanvas() return canvas, parent end
function mm:GetWorldMapOverlayPoint(_, _, x, yDown) return x, -yDown end
function mm.GetMapIconScale() return 1 end
function mm:GetDominantFaction(front) return front.owner end

local frames = {}
e.CreateFrame = function(_, _, p)
    created = created + 1
    local f = newFrame(p)
    frames[#frames + 1] = f
    return f
end
-- Emblems by continent (Kalimdor on the left half of the map, EK on the right).
local function shown()
    local out = {}
    for _, f in ipairs(frames) do
        if f.shown then
            out[f.x < 500 and "K" or "EK"] = f.logo.path:match("Timer\\(%a+)%-Logo")
        end
    end
    return out
end

-- EK: 3 Alliance fronts, 1 Horde. Kalimdor: 2 Horde, 1 Alliance.
setFronts({ { 1417, "Alliance" }, { 1429, "Alliance" }, { 1433, "Alliance" }, { 1424, "Horde" },
    { 1411, "Horde" }, { 1440, "Horde" }, { 1413, "Alliance" } })
mm:RefreshWorldEmblems(947, true, true)
local s = shown()
assert(s.EK == "Alliance" and s.K == "Horde", "world emblems: EK " .. tostring(s.EK) .. ", K " .. tostring(s.K))
-- Placed over the reference zones (Ashenvale, Arathi) at one shared height (mean of the
-- two), sized from the canvas width.
for _, f in ipairs(frames) do
    assert(f.size == 90, "emblem size " .. tostring(f.size))
    if f.x < 500 then
        assert(f.x == 220 and f.y == -233, ("Kalimdor emblem at %s,%s"):format(f.x, f.y))
    else
        assert(f.x == 830 and f.y == -233, ("EK emblem at %s,%s"):format(f.x, f.y))
    end
    assert(f.level == parent:GetFrameLevel() + 2, "emblem not under the other map pins")
end

-- Unchanged map: no repaint at each driver tick.
local before = setPoints
for _ = 1, 20 do mm:RefreshWorldEmblems(947, false, false) end
assert(setPoints == before, "world emblems repainted without a layout or content change")

-- Tie on a continent: no emblem there.
setFronts({ { 1417, "Alliance" }, { 1424, "Horde" }, { 1411, "Horde" } })
mm:RefreshWorldEmblems(947, false, true)
s = shown()
assert(s.EK == nil and s.K == "Horde", "a tied continent kept an emblem")
-- Nothing dominated anywhere: no emblem at all.
setFronts({ { 1417, nil }, { 1411, nil } })
mm:RefreshWorldEmblems(947, false, true)
s = shown()
assert(s.EK == nil and s.K == nil, "emblem shown with no dominated front")

-- Another map (continent, zone): hidden, and no frame is created there.
setFronts({ { 1417, "Alliance" }, { 1411, "Horde" } })
mm:RefreshWorldEmblems(947, false, true)
assert(shown().EK == "Alliance")
local createdBefore = created
for _, mapID in ipairs({ 1415, 1414, 1429, 1440 }) do
    mm:RefreshWorldEmblems(mapID, true, true)
    s = shown()
    assert(s.EK == nil and s.K == nil, "emblem shown on map " .. mapID)
end
assert(created == createdBefore, "frames created off the world map")
-- Back to the world map: painted again (the driver's map change forces a layout).
mm:RefreshWorldEmblems(947, true, true)
assert(shown().EK == "Alliance" and shown().K == "Horde", "world emblems not repainted")
-- Hidden from outside (map closed, display mode): repainted at the next tick.
mm:HideWorldEmblems()
mm:RefreshWorldEmblems(947, false, false)
assert(shown().EK == "Alliance", "emblems hidden from outside never came back")

-- Instance: nothing.
e.Overlord.InstanceSuspended = true
mm:RefreshWorldEmblems(947, true, true)
s = shown()
assert(s.EK == nil and s.K == nil, "emblem shown in an instance")
e.Overlord.InstanceSuspended = nil

-- Map data not readable yet: no emblem, and the lookup is retried at most every 30 s.
setfenv(assert(loadfile("MapWorldEmblems.lua")), e)()
mm = e.Overlord.MapMarkers
local saved = maps
local lookups = 0
maps = setmetatable({}, { __index = function() lookups = lookups + 1 end })
for _ = 1, 10 do mm:RefreshWorldEmblems(947, true, true) end
assert(lookups <= 4, "world map looked up " .. lookups .. " times while unresolved")
maps = saved
clock = 131
frames = {}
mm:RefreshWorldEmblems(947, true, true)
assert(shown().EK == "Alliance", "world map never resolved once the map data loaded")

print("World emblems: dominant faction per continent, tie, other maps, no idle repaint, instance OK")
