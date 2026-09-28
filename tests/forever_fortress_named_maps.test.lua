-- 1.1.4 regression: fortress zone maps on Forever can be named sub-maps whose
-- uiMapID is not listed (1.1.3 matched them by name), and a listed ID may not
-- exist in this client. Pins disappeared on the zone map and the capture had no
-- geometry map. Reuse the full fortress fixture, then simulate Forever maps.
assert(loadfile("tests/forever_fortress_outpost.test.lua"))()
local op, gk = Overlord.Outpost, Overlord.GuildKeep
local maps = {
    [56] = { name = "Wetlands", parentMapID = 1415 },
    [9437] = { name = "Les Paluns", parentMapID = 1415 },          -- named Forever sub-map
    [9901] = { name = "Camp Narache", parentMapID = 9907 },        -- starter camp under Mulgore
    [9907] = { name = "Mulgore", parentMapID = 1414 },
    [9950] = { name = "Some Other Zone", parentMapID = 1415 },
}
local playerMap = 9437
C_Map.GetMapInfo = function(id) return maps[id] end                -- 1437 absent here
C_Map.GetBestMapForUnit = function() return playerMap end

local wetlands = gk:GetSite("wetlands")
assert(wetlands and wetlands.isFortress, "Wetlands fortress fixture missing")

-- Zone map by name: the pin path resolves the site and treats it as its detail map.
assert(gk:ResolveSiteByMapID(9437) == wetlands, "Named Forever sub-map did not resolve the fortress")
assert(gk:IsKeepSiteDisplayMap(9437, wetlands), "Named sub-map is not the fortress display map")
assert(not gk:IsKeepSiteDisplayMap(9950, wetlands), "Unrelated map matched the fortress")
-- Name matching applies to the map itself only, never through a parent.
local mulgore = gk:GetSite("mulgore")
if mulgore then
    assert(not gk:IsKeepSiteDisplayMap(9901, mulgore), "Starter camp matched its parent zone fortress")
    assert(gk:IsKeepSiteDisplayMap(9907, mulgore), "Mulgore map by name not recognized")
end

-- Geometry: the player's named map is used when it is the site's map ...
assert(op:GetGeometryMapID(wetlands) == 9437, "Capture geometry ignored the player's named map")
-- ... otherwise the first listed map that exists in this client (1437 is absent).
playerMap = 9950
assert(op:GetGeometryMapID(wetlands) == 56, "Capture geometry kept a map ID missing on this client")

-- World-map dispatch: a fortress zone map must not be claimed by the outpost
-- branch (which skips fortresses and comes first), or no pin is drawn at all.
-- This was the in-game 1.1.4 symptom on Les Paluns.
for _, id in ipairs({ 56, 1437, 9437 }) do
    assert(not op:IsStandaloneOpenWorldDisplayMap(id),
        "Fortress zone map " .. id .. " was dispatched to the outpost renderer")
end
local standaloneChecked = 0
for _, site in pairs(Overlord.OutpostSites) do
    if site.standaloneOpenWorld and not site.isFortress then
        assert(op:IsStandaloneOpenWorldDisplayMap(site.mapID),
            "Standalone outpost map " .. tostring(site.mapID) .. " lost its outpost renderer")
        standaloneChecked = standaloneChecked + 1
    end
end
assert(standaloneChecked > 0, "No standalone outpost fixture checked")

-- Outposts keep their ID-only behavior (no name matching introduced for them).
for key, site in pairs(Overlord.OutpostSites) do
    if not site.isFortress and site.mapNameNeedles then
        maps[9800] = { name = site.mapNameNeedles[1], parentMapID = 0 }
        assert(not op:IsOutpostSiteDisplayMap(9800, site) or op:IsOutpostSiteDisplayMap(site.mapID, site),
            "Outpost " .. key .. " changed display matching")
        break
    end
end
print("Forever fortress named maps: named sub-map pins, no parent match, geometry on existing map OK")
