Overlord = { L = { OUTPOST_LESI_BEAR_CAVE_NAME = "Lesi Bear Cave" }, InActiveFront = false }
local now, mapID, x, y = 10, 1439, 43.4, 45.8
function GetTime() return now end
C_Map = {
    GetBestMapForUnit = function() return mapID end,
    GetMapInfo = function() return { parentMapID = 0 } end,
    GetPlayerMapPosition = function(id)
        assert(id == mapID)
        return { GetXY = function() return x / 100, y / 100 end }
    end,
}
assert(loadfile("Outpost.lua"))()
local op = Overlord.Outpost
local site = assert(op:GetSite("lesi_bear_cave"))
assert(op:GetDisplayName(site) == "Lesi Bear Cave")
assert(site.standaloneOpenWorld and not site.frontId)
assert(op:ResolveSiteByMapID(1439) == site and op:ResolveSiteByMapID(62) == site)
assert(#op:GetSitesOnMap(1439) == 1 and #op:GetSitesOnMap(62) == 1)
-- Lunaclaw's cave, Darkshore (Classic map).
assert(op:IsPlayerInOutpostGeometry(site), "Standalone capture requires an active front")
now, x = now + 1, 46
assert(not op:IsPlayerInOutpostGeometry(site), "Capture square extends too far")
now, mapID, x = now + 1, 1440, 43.4
assert(not op:IsPlayerInOutpostGeometry(site), "Ashenvale activates Lesi Bear Cave")
print("Forever Lesi Bear Cave: Darkshore map aliases, standalone display and capture geometry OK")
