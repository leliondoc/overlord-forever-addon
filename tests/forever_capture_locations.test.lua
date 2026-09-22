-- Independent Vanilla ground references (Questie v10.0.0 classicNpcDB).
-- These checks test capture reach and map selection, not server terrain navigation.
Overlord = { L = { ZONE_NAMES = {} } }
Enum = { UIMapType = { Zone = 3, Continent = 2 } }
local now, currentMap, x, y = 10, 1417, 0, 0
local classicAvailable = true
local classic = { [1417]=true, [1432]=true, [1411]=true, [1440]=true }
function GetTime() return now end
function wipe(t) for k in pairs(t) do t[k] = nil end end
function CreateVector2D(x, y) return {x=x, y=y} end
C_Map = {
    GetMapInfo = function(id)
        if classic[id] and not classicAvailable then return nil end
        return {mapType=3, parentMapID=0}
    end,
    GetBestMapForUnit = function() return currentMap end,
    GetPlayerMapPosition = function(id)
        assert(id == Overlord.Fronts:GetMapID(), "Wrong coordinate frame")
        return {GetXY=function() return x/100, y/100 end}
    end,
    GetWorldPosFromMapPos = function(id, p) return 0, {x=p.x*1500,y=p.y*1000} end,
}
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local anchors = {
    {"stromgarde", 25.38, 58.36}, -- NPC 2584: Stromgarde Defender
    {"faldir", 32.28, 81.38}, -- NPC 2610: Shakes O'Breen
    {"witherbark", 62.55, 73.17}, -- NPC 2556: Witherbark Headhunter
    {"goshek", 61.88, 57.33}, -- NPC 2618: Hammerfall Peon
    {"dabyrie", 54.18, 38.09}, -- NPC 4481: Marcel Dabyrie
    {"refuge", 45.83, 47.56}, -- NPC 2700: Captain Nials
    {"highperch", 25.19, 40.13}, -- NPC 2559: Highland Strider
    {"newstead", 18.04, 47.22}, -- NPC 2560: Highland Thrasher
    {"hammerfell", 74.18, 33.96}, -- NPC 4954: Uttnar
    {"argorok", 27.43, 31.39}, -- NPC 2760: Burning Exile
    {"loch_alliance_capital", 35.10, 46.79}, -- NPC 2510: Mountaineer Ozmok
    {"loch_valley_of_kings", 22.07, 73.13}, -- NPC 1089: Mountaineer Cobbleflint
    {"loch_south_gate_pass", 18.18, 84.01}, -- NPC 3836: Mountaineer Pebblebitty
    {"loch_farstrider_lodge", 82.65, 64.11}, -- NPC 954: Kat Sampson
    {"loch_ironband", 69.11, 63.29}, -- NPC 1165: Stonesplinter Geomancer
    {"loch_silver_stream_mine", 35.41, 21.57}, -- NPC 1174: Tunnel Rat Geomancer
    {"loch_algaz_post", 24.74, 17.71}, -- NPC 1335: Mountaineer Yuttha
    {"loch_stonewrought_dam", 46.05, 13.61}, -- NPC 1093: Chief Engineer Hinderweir VII
    {"loch_the_loch", 63.56, 47.92}, -- NPC 6577: Bingles Blastenheimer
    {"loch_horde_capital", 68.93, 24.54}, -- NPC 1179: Mo'grosh Enforcer
    {"durotar_tiragarde_keep", 58.51, 57.50}, -- NPC 3128: Kul Tiras Sailor
    {"durotar_alliance_fleet", 52.08, 82.03}, -- NPC 3119: Kolkar Drudge
    {"durotar_senjin_village", 55.21, 74.78}, -- NPC 3297: Sen'jin Watcher
    {"durotar_razor_hill", 53.06, 42.48}, -- NPC 5953: Razor Hill Grunt
    {"durotar_deadeye_shore", 59.05, 24.24}, -- NPC 3100: Elder Mottled Boar
    {"durotar_southfury", 39.40, 36.54}, -- NPC 3099: Dire Mottled Boar
    {"durotar_spirit_rock", 44.63, 68.65}, -- NPC 11378: Foreman Thazz'ril
    {"durotar_thunder_ridge", 38.88, 25.27}, -- NPC 3131: Lightning Hide
    {"durotar_drygulch_ravine", 49.96, 27.56}, -- NPC 3115: Dustwind Harpy
    {"durotar_dranosh_blockade", 46.10, 13.77}, -- NPC 15012: Javnir Nashak
    {"ash_astranaar", 34.67, 48.84}, -- NPC 3845: Shindrell Swiftfire
    {"ash_iris_lake", 45.82, 43.25}, -- NPC 3780: Shadethicket Moss Eater
    {"ash_raynewood", 60.96, 51.84}, -- NPC 4054: Laughing Sister
    {"ash_night_run", 66.32, 52.56}, -- NPC 3758: Felmusk Satyr
    {"ash_bloodtooth_camp", 54.75, 79.62}, -- NPC 3696: Ran Bloodtooth
    {"ash_silverwind", 50.27, 66.04}, -- NPC 6087: Astranaar Sentinel
    {"ash_mystral_lake", 50.84, 75.08}, -- NPC 3897: Krolg
    {"ash_fallen_sky_lake", 65.88, 80.30}, -- NPC 3784: Shadethicket Bark Ripper
    {"ash_dor_danil", 71.91, 73.67}, -- NPC 12856: Ashenvale Outrunner
    {"ash_splintertree", 73.38, 61.02}, -- NPC 15131: Qeeju
}
local seen = {}
for _, a in ipairs(anchors) do
    local zone, front = Overlord.Fronts:GetZone(a[1])
    assert(zone, a[1])
    Overlord.Fronts.activeFrontId = front.id
    Overlord.ZoneDatabase = front.zones
    for alias in pairs(front.mapIDs) do
        currentMap = alias
        front.resolvedMapID = alias
        assert(Overlord.Fronts:GetMapID() == front.preferredMapID, "Retail alias selected")
        now, x, y = now + 1, a[2], a[3]
        local found = Overlord.Zones:GetCurrentPlayerZone()
        assert(found == zone, "Ground reference cannot capture " .. a[1] .. ": " .. tostring(found and found.id))
    end
    seen[a[1]] = true
end
local count = 0
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do
        assert(seen[zone.id], "Missing ground reference " .. zone.id)
        count = count + 1
    end
end
assert(count == 40)
classicAvailable = false
for _, front in pairs(Overlord.Fronts.Registry) do
    front.resolvedMapID = nil
    assert(front.mapIDs[Overlord.Fronts:GetMapID(front.id)], "Alias-only client lost its map")
end
print("Forever capture locations: 40 ground references, capture detection and preferred Vanilla maps OK")
