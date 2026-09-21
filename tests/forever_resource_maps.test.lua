-- Load production zone detection; simulate both client map-ID families.
Overlord = { L = {} }
local now, currentMap, x, y = 100, 0, 0, 0
function GetTime() return now end
function wipe(t) for k in pairs(t) do t[k] = nil end end
C_Map = {
    GetBestMapForUnit = function() return currentMap end,
    GetMapInfo = function(id) return { parentMapID = id == 99999 and 1424 or 0 } end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return x / 100, y / 100 end }
    end,
}
assert(loadfile("Zones.lua"))()
local z = Overlord.Zones
local function visit(resource, mapID, wood)
    now, currentMap = now + 1, mapID
    x, y = resource.center[1], resource.center[2]
    assert(z:ResourceMatchesMap(resource, mapID), "Marker map filter rejected " .. resource.id)
    assert(z:IsResourceMapContext(mapID), "Resource ticker disabled on " .. mapID)
    local found = wood and z:GetCurrentPlayerWoodZone() or z:GetCurrentPlayerMine()
    assert(found == resource, "Harvesting failed for " .. resource.id .. " on " .. mapID)
    now, x, y = now + 1, 0, 0
    found = wood and z:GetCurrentPlayerWoodZone() or z:GetCurrentPlayerMine()
    assert(found == nil, "Resource detected outside circle")
end
local expected = { azurelode = 1424, darrow = 1424, elemgorge = 1421,
    stonessplinter = 1432, jasperlode = 1429, wetlands_forest = 1437 }
for _, db in ipairs({ Overlord.MineDatabase, Overlord.WoodDatabase }) do
    for _, resource in ipairs(db) do
        assert(resource.mapID == expected[resource.id], "Continent projection uses a Retail map")
        for mapID in pairs(resource.mapIDs) do visit(resource, mapID, resource.id == "wetlands_forest") end
    end
end
now, currentMap, x, y = now + 1, 99999, 34.4, 72.2
assert(z:GetCurrentPlayerMine().id == "azurelode", "Mine submap ancestry broke")
assert(not z:IsResourceMapContext(99998), "Unrelated map enabled resource ticker")
print("Forever resource maps: all 5 mines, forest, Classic/Retail aliases, harvesting boundaries and cave ancestry OK")
