Overlord = { L = { OUTPOST_SILVERPINE_NAME = "Savix Chapel" }, InActiveFront = false }
local now, mapID, x, y = 10, 1421, 61.8, 64.4
function GetTime() return now end
C_Map = {
    GetBestMapForUnit = function() return mapID end,
    GetMapInfo = function() return { parentMapID = 0 } end,
    GetPlayerMapPosition = function(id)
        assert(id == 1421)
        return { GetXY = function() return x / 100, y / 100 end }
    end,
}
assert(loadfile("Outpost.lua"))()
local op = Overlord.Outpost
local site = assert(op:GetSite("silverpine"))
assert(op:GetDisplayName(site) == "Savix Chapel")
assert(site.standaloneOpenWorld and not site.frontId)
assert(op:ResolveSiteByMapID(1421) == site and op:ResolveSiteByMapID(21) == site)
assert(#op:GetSitesOnMap(1421) == 1 and #op:GetSitesOnMap(21) == 1)
assert(op:IsPlayerInOutpostGeometry(site), "Standalone capture requires an active front")
now, x = now + 1, 65
assert(not op:IsPlayerInOutpostGeometry(site), "Capture square extends too far")
now, mapID, x = now + 1, 1417, 61.8
assert(not op:IsPlayerInOutpostGeometry(site), "Another map activates Savix Chapel")
print("Forever Savix Chapel: map aliases, standalone display and capture geometry OK")
