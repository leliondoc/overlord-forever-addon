-- Fronts:GetMapID is called thousands of times a minute (minimap, HUD, sync):
-- a validated map is remembered per front and recomputed only when the front's
-- resolved map changes, or while map data is not ready yet.
Overlord = { L = setmetatable({ ZONE_NAMES = setmetatable({}, { __index = function(_, k) return k end }) },
    { __index = function(_, k) return k end }) }
local calls, valid = 0, true
C_Map = { GetMapInfo = function(id) calls = calls + 1; return valid and { mapType = 3, mapID = id } or nil end }
Enum = Enum or {}; Enum.UIMapType = Enum.UIMapType or { Zone = 3, Continent = 2, World = 1, Cosmic = 0, Dungeon = 4, Micro = 5, Orphan = 6 }
assert(loadfile("Fronts.lua"))()
local fronts = Overlord.Fronts
local front = { id = "cachefront", preferredMapID = 1234, mapIDs = { [1234] = true } }
fronts.Registry = fronts.Registry or {}
fronts.Registry.cachefront = front
assert(fronts:GetMapID("cachefront") == 1234)
for _ = 1, 50 do assert(fronts:GetMapID("cachefront") == 1234) end
assert(calls == 1, "Front map id recomputed on every call: " .. calls)
front.resolvedMapID = 999
fronts:GetMapID("cachefront")
assert(calls == 2, "Cached map id ignored a change of resolved map")
-- Map data not ready: never cache a guessed fallback.
local late = { id = "latefront", mapIDs = { [55] = true } }
fronts.Registry.latefront = late
valid, calls = false, 0
fronts:GetMapID("latefront"); fronts:GetMapID("latefront")
assert(calls >= 2, "An unvalidated fallback map was cached")
valid = true
assert(fronts:GetMapID("latefront") == 55)
-- Preferred map not ready yet: a valid fallback is used but never frozen; the
-- preferred map wins as soon as it becomes available.
local ready = false
C_Map = { GetMapInfo = function(id)
    if id == 700 and not ready then return nil end
    return { mapType = 3, mapID = id }
end }
local pref = { id = "preffront", preferredMapID = 700, mapIDs = { [701] = true } }
fronts.Registry.preffront = pref
assert(fronts:GetMapID("preffront") == 701, "Fallback map not used while the preferred map was missing")
ready = true
assert(fronts:GetMapID("preffront") == 700, "A temporary fallback map was frozen over the preferred one")
print("Front map id cache: one C_Map lookup per front, invalidated on map change, no cached guess OK")
