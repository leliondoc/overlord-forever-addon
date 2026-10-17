Overlord = { L = { OUTPOST_ANADORA_NAME = "Anad'Ora Moonwell" }, InActiveFront = false }
local now, mapID, x, y = 10, 1444, 58.1, 44.9
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
local site = assert(op:GetSite("anadora"))
assert(op:GetDisplayName(site) == "Anad'Ora Moonwell")
assert(site.standaloneOpenWorld and not site.frontId)
assert(op:ResolveSiteByMapID(1444) == site and op:ResolveSiteByMapID(69) == site)
assert(#op:GetSitesOnMap(1444) == 1 and #op:GetSitesOnMap(69) == 1)
-- Shown on the Kalimdor continent map like the other Kalimdor outposts.
assert(op:ShouldProjectOutpostPinOnMap(site, 1414) and op:ShouldProjectOutpostPinOnMap(site, 12),
    "Anad'Ora Moonwell is not projected on Kalimdor")
assert(not op:ShouldProjectOutpostPinOnMap(site, 1444), "Detail map must not project its own pin")
-- Before the entrance of Dire Maul, Feralas (Classic map).
assert(op:IsPlayerInOutpostGeometry(site), "Standalone capture requires an active front")
now, x = now + 1, 60.7
assert(not op:IsPlayerInOutpostGeometry(site), "Capture square extends too far")
now, mapID, x = now + 1, 1439, 58.1
assert(not op:IsPlayerInOutpostGeometry(site), "Darkshore activates Anad'Ora Moonwell")
print("Forever Anad'Ora Moonwell: Feralas map aliases, standalone display and capture geometry OK")
