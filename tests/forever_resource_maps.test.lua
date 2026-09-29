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
local function visit(resource, mapID)
    now, currentMap = now + 1, mapID
    x, y = resource.center[1], resource.center[2]
    assert(z:ResourceMatchesMap(resource, mapID), "Marker map filter rejected " .. resource.id)
    assert(z:IsResourceMapContext(mapID), "Resource ticker disabled on " .. mapID)
    local found = z:GetCurrentPlayerMine()
    assert(found == resource, "Harvesting failed for " .. resource.id .. " on " .. mapID)
    now, x, y = now + 1, 0, 0
    found = z:GetCurrentPlayerMine()
    assert(found == nil, "Resource detected outside circle")
end
local expected = { azurelode = 1424, darrow = 1424, elemgorge = 1421,
    stonessplinter = 1432, jasperlode = 1429 }
for _, resource in ipairs(Overlord.MineDatabase) do
    assert(resource.mapID == expected[resource.id], "Continent projection uses a Retail map")
    for mapID in pairs(resource.mapIDs) do visit(resource, mapID) end
end
now, currentMap, x, y = now + 1, 99999, 28.0, 57.0
assert(z:GetCurrentPlayerMine().id == "azurelode", "Mine submap ancestry broke")
-- 1.2.0: the wood system is gone; no forest map may enable harvesting or the resource ticker.
assert(#Overlord.WoodDatabase == 0, "A forest is still defined")
for _, mapID in ipairs({ 56, 1437, 63, 1440 }) do
    assert(not z:IsWoodMapID(mapID), "Forest map still recognised: " .. mapID)
end
assert(z:GetCurrentPlayerWoodZone() == nil, "Wood harvesting zone still detected")
assert(not z:IsResourceMapContext(99998), "Unrelated map enabled resource ticker")
print("Forever resource maps: all 5 mines, no forest, map aliases, harvesting boundaries and cave ancestry OK")
