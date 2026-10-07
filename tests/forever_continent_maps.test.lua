-- 1.7.0: continent maps are resolved from fixed reference zones, not from the front the
-- player stands in. A player on a Kalimdor front took Kalimdor for the Eastern
-- Kingdoms (no domination logos on the EK map), and Kalimdor was looked up through a
-- Retail-only map id (no domination logos on the Classic Kalimdor map).
local CONTINENT, ZONE = 2, 3
local maps = {
    [947] = { mapID = 947, name = "Azeroth", mapType = 1, parentMapID = 946 },
    [1414] = { mapID = 1414, name = "Kalimdor", mapType = CONTINENT, parentMapID = 947 },
    [1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = CONTINENT, parentMapID = 947 },
    [1411] = { mapID = 1411, name = "Durotar", mapType = ZONE, parentMapID = 1414 },
    [1440] = { mapID = 1440, name = "Ashenvale", mapType = ZONE, parentMapID = 1414 },
    [1429] = { mapID = 1429, name = "Elwynn Forest", mapType = ZONE, parentMapID = 1415 },
    [1417] = { mapID = 1417, name = "Arathi Highlands", mapType = ZONE, parentMapID = 1415 },
}
local function load(activeFrontMap)
    local e = setmetatable({}, { __index = _G })
    e._G = e
    e.Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = CONTINENT, Zone = ZONE } }
    e.C_Map = { GetMapInfo = function(id) return maps[id] end }
    e.GetTime = function() return 100 end
    e.Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }),
        Fronts = { GetMapID = function() return activeFrontMap end, Order = {}, Registry = {} },
        Zones = { IsActiveFrontMapID = function() return false end },
        UI = { ResolveLocalizedFontPath = function(_, path) return path end } }
    e.CreateFrame = function() return setmetatable({}, { __index = function() return function() end end }) end
    setfenv(assert(loadfile("MapMarkers.lua")), e)()
    return e.Overlord.MapMarkers
end

for _, activeFrontMap in ipairs({ 1440, 1411, 1429, false }) do
    local mm = load(activeFrontMap or nil)
    local label = "active front " .. tostring(activeFrontMap)
    assert(mm:ResolveKalimdorMapID() == 1414, label .. ": Kalimdor = " .. tostring(mm:ResolveKalimdorMapID()))
    assert(mm:ResolveEKMapID() == 1415, label .. ": EK = " .. tostring(mm:ResolveEKMapID()))
    assert(mm:IsEKMap(1415) and not mm:IsEKMap(1414), label .. ": EK map test")
    assert(mm:IsKalimdorMap(1414) and not mm:IsKalimdorMap(1415), label .. ": Kalimdor map test")
    assert(mm:IsEKMap(1429) and mm:IsKalimdorMap(1440), label .. ": zones under their continent")
end
-- Map data not readable yet (loading): nothing is cached as "not a continent", and the
-- lookup is retried at most every 30 s, then succeeds.
local saved = maps
maps = {}
local clock = 100
local e = setmetatable({}, { __index = _G })
e._G = e
e.Enum = { UIMapType = { Continent = CONTINENT, Zone = ZONE } }
local lookups = 0
e.C_Map = { GetMapInfo = function(id) lookups = lookups + 1; return maps[id] end }
e.GetTime = function() return clock end
e.Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }),
    Fronts = { GetMapID = function() return nil end, Order = {}, Registry = {} },
    Zones = { IsActiveFrontMapID = function() return false end },
    UI = { ResolveLocalizedFontPath = function(_, path) return path end } }
e.CreateFrame = function() return setmetatable({}, { __index = function() return function() end end }) end
setfenv(assert(loadfile("MapMarkers.lua")), e)()
local mm = e.Overlord.MapMarkers
assert(not mm:IsEKMap(1415) and not mm:IsKalimdorMap(1414), "unknown maps read as continents")
local afterFirst = lookups
for _ = 1, 50 do mm:IsEKMap(1415); mm:IsKalimdorMap(1414) end
assert(lookups == afterFirst, "unresolved continents were looked up again before 30 s")
-- The same map asked repeatedly on its own while unresolved: no "false" is cached for it.
for _ = 1, 3 do assert(not mm:IsEKMap(1415)) end
maps = saved
clock = 131
assert(mm:IsEKMap(1415), "the EK map stayed cached as not-a-continent")
for _ = 1, 3 do assert(mm:IsEKMap(1415)) end
assert(mm:IsKalimdorMap(1414), "continents not found once the maps loaded")

-- Same for Kalimdor asked alone first.
maps = {}
clock = 1000
setfenv(assert(loadfile("MapMarkers.lua")), e)()
mm = e.Overlord.MapMarkers
for _ = 1, 3 do assert(not mm:IsKalimdorMap(1414)) end
maps = saved
clock = 1031
assert(mm:IsKalimdorMap(1414), "the Kalimdor map stayed cached as not-a-continent")
-- A reference zone filed under the other continent never makes Kalimdor the EK: the
-- next reference zone decides.
maps = setmetatable({ [1429] = { mapID = 1429, name = "Elwynn Forest", mapType = ZONE, parentMapID = 1414 } },
    { __index = saved })
clock = 2000
setfenv(assert(loadfile("MapMarkers.lua")), e)()
mm = e.Overlord.MapMarkers
assert(mm:ResolveKalimdorMapID() == 1414 and mm:ResolveEKMapID() == 1415,
    "EK resolved to " .. tostring(mm:ResolveEKMapID()))
maps = saved
print("Continent maps: EK and Kalimdor resolved the same from any front, Classic ids OK")
