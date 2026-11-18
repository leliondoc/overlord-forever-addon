-- Tanaris, the eighth front: 10 points on the Classic map 1446 (alias 71), the Alliance
-- capital at Lost Rigger Cove (east coast), the Horde one in Thistleshrub Valley (west),
-- Gnome against Goblin portraits, its outpost at Broken Pillar. Real Fronts, Zones, UIShared and Outpost code.

-- 1. The front: maps, capitals, routes, capture circles.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local F, Z = Overlord.Fronts, Overlord.Zones
local front = assert(F:GetFront("tanaris"), "no Tanaris front")
assert(F.Order[#F.Order] == "tanaris", "Tanaris is not the last front of the panel order")
assert(front.preferredMapID == 1446 and front.mapIDs[1446] and front.mapIDs[71], "Tanaris map ids")
assert(#front.zones == 10, "Tanaris is a 10-point front")
assert(front.allianceCapitalId == "tanaris_lost_rigger" and front.hordeCapitalId == "tanaris_thistleshrub")
local byId = {}
for _, zone in ipairs(front.zones) do byId[zone.id] = zone end
assert(byId.tanaris_lost_rigger.isCapital and byId.tanaris_thistleshrub.isCapital, "capitals not flagged")
assert(not byId.tanaris_watchers.isCapital, "the Valley of the Watchers is no longer a capital")
assert(byId.tanaris_lost_rigger.status == "captured", "the Alliance capital does not start held")
assert(byId.tanaris_lost_rigger.center[1] == 72.7 and byId.tanaris_lost_rigger.center[2] == 44.9)
assert(byId.tanaris_thistleshrub.center[1] == 29.5 and byId.tanaris_thistleshrub.center[2] == 66.0)
-- Widest front map (6,900 yards): radii 3.5 and 4.5, Ashenvale's circles on the ground.
local scale = F.CaptureRadiusScale
for id, zone in pairs(byId) do
    local nominal = zone.isCapital and 4.5 or 3.5
    assert(math.abs(zone.radius - nominal * scale) < 1e-9, id .. " radius " .. tostring(zone.radius))
end
-- No two circles touch (aspect 2/3: Tanaris is 6,900 x 4,600 yards).
local ar = 4600 / 6900
for i = 1, #front.zones do
    for j = i + 1, #front.zones do
        local a, b = front.zones[i], front.zones[j]
        local dx, dy = a.center[1] - b.center[1], (a.center[2] - b.center[2]) * ar
        assert(math.sqrt(dx * dx + dy * dy) > a.radius + b.radius, a.id .. " touches " .. b.id)
    end
end
-- Nothing on the unreachable south (mountains and Land's End Beach, below 80 % of the map).
for id, zone in pairs(byId) do
    assert(zone.center[2] + zone.radius / ar < 80, id .. " reaches the unreachable south")
end

-- The map resolves from both ids and from the name, not from the neighbours.
for _, mapID in ipairs({ 1446, 71 }) do
    assert(F:ResolveFrontByMapID(mapID) == front, "map " .. mapID .. " is not Tanaris")
end
local names = { [9001] = "Tanaris", [9002] = "Un'Goro Crater", [9003] = "Thousand Needles", [9004] = "Танарис" }
local getMapInfo = C_Map.GetMapInfo
C_Map.GetMapInfo = function(id)
    if names[id] then return { name = names[id], mapType = 3, parentMapID = 0 } end
    return getMapInfo and getMapInfo(id)
end
assert(F:ResolveFrontByMapID(9001) == front and F:ResolveFrontByMapID(9004) == front, "Tanaris not found by name")
assert(F:ResolveFrontByMapID(9002) == nil and F:ResolveFrontByMapID(9003) == nil, "a neighbour reads as Tanaris")
C_Map.GetMapInfo = getMapInfo

-- Routes: the Alliance opens both branches from its capital; the Horde capital needs the
-- end of both; the Horde walks them backwards.
for id in pairs(byId) do
    if id ~= front.allianceCapitalId then byId[id].owner, byId[id].status = "Horde", "captured" end
end
byId.tanaris_lost_rigger.owner = "Alliance"
assert(Z:IsZoneAttackable(byId.tanaris_waterspring) and Z:IsZoneAttackable(byId.tanaris_southbreak),
    "the two points after the Alliance capital are not attackable")
assert(not Z:IsZoneAttackable(byId.tanaris_sandsorrow), "a point two steps ahead reads attackable")
for _, id in ipairs({ "tanaris_waterspring", "tanaris_sandsorrow", "tanaris_noxious_lair", "tanaris_dunemaul" }) do
    byId[id].owner = "Alliance"
end
assert(not Z:IsZoneAttackable(byId.tanaris_thistleshrub), "the Horde capital opens with one route only")
for _, id in ipairs({ "tanaris_southbreak", "tanaris_gaping_chasm", "tanaris_eastmoon", "tanaris_watchers" }) do
    byId[id].owner = "Alliance"
end
assert(Z:IsZoneAttackable(byId.tanaris_thistleshrub), "the Horde capital stays closed with both routes held")
local horde = front.prereqs.Horde
assert(#horde.tanaris_thistleshrub == 0 and #horde.tanaris_lost_rigger == 2, "Horde start and goal")
assert(horde.tanaris_dunemaul[1] == "tanaris_thistleshrub" and horde.tanaris_watchers[1] == "tanaris_thistleshrub")
-- The Horde rules are the exact mirror of the Alliance ones.
local alliance = front.prereqs.Alliance
for id, needs in pairs(alliance) do
    for _, need in ipairs(needs) do
        local back = false
        for _, h in ipairs(horde[need]) do back = back or h == id end
        assert(back, need .. " does not lead back to " .. id .. " for the Horde")
    end
end

-- Capture circles: every centre captures its own point on the front's map.
local mx, my = 0, 0
C_Map.GetBestMapForUnit = function() return 1446 end
C_Map.GetPlayerMapPosition = function() return { GetXY = function() return mx / 100, my / 100 end } end
C_Map.GetWorldPosFromMapPos = function(_, p) return 0, { x = p.x * 6900, y = p.y * 4600 } end
F.activeFrontId = front.id
Overlord.ZoneDatabase = front.zones
local clock = 100
GetTime = function() return clock end
for id, zone in pairs(byId) do
    clock = clock + 1
    mx, my = zone.center[1], zone.center[2]
    local found = Z:GetCurrentPlayerZone()
    assert(found == zone, "the centre of " .. id .. " captures " .. tostring(found and found.id))
end

-- Featured front art and names.
assert(F:GetFeaturedFrontArtPath("tanaris") == "Interface\\QuestionFrame\\Answer-WarBoard-Classic-Tanaris.blp")
local heads = front.panelHeads

-- 2. Portraits: Gnome for the Alliance, Goblin for the Horde, from the Classic sheet of
-- the character creation (the client's sheet holds both, row 1 and row 2).
assert(heads.Alliance == "GNOME_MALE" and heads.Horde == "GOBLIN_MALE" and heads.HordeIcon == nil)
CreateFrame = function() return {} end
C_Texture = { GetAtlasInfo = function() return nil end }
Overlord = { Sync = { NormalizeRaceFileToken = function(_, race) return race end } }
assert(loadfile("UIShared.lua"))()
local function newTexture()
    local t = {}
    function t:SetTexture(file) self.file = file end
    function t:SetAtlas(atlas) self.atlas = atlas end
    function t:SetTexCoord(l, r, top, b) self.coords = { l, r, top, b } end
    function t:SetVertexColor() end
    function t:Show() self.shown = true end
    return t
end
local function sameCoords(c, want)
    for i = 1, 4 do if math.abs(c[i] - want[i]) > 1e-9 then return false end end
    return true
end
local gnome, goblin = newTexture(), newTexture()
assert(Overlord.UI.SetClassicRaceIcon(gnome, heads.Alliance, false), "no Gnome portrait")
assert(Overlord.UI.SetClassicRaceIcon(goblin, heads.Horde, false), "no Goblin portrait")
assert(gnome.file == goblin.file and gnome.file:find("UI%-CharacterCreate%-Races"), "not the Classic sheet")
assert(sameCoords(gnome.coords, { 0.25, 0.375, 0, 0.25 }), "the Alliance portrait is not the Gnome")
assert(sameCoords(goblin.coords, { 0.625, 0.75, 0.25, 0.5 }), "the Horde portrait is not the Goblin")

-- 3. The outpost: Broken Pillar, in the middle of the Abyssal Sands, off both routes.
Overlord = { L = { OUTPOST_TANARIS_NAME = "Broken Pillar" }, InActiveFront = false }
assert(loadfile("Outpost.lua"))()
local op = Overlord.Outpost
local site = assert(op:GetSite("tanaris"), "no Tanaris outpost")
assert(site.frontId == "tanaris" and not site.standaloneOpenWorld, "the outpost is not the front's")
assert(op:GetDisplayName(site) == "Broken Pillar")
local onFront = false
for _, s in pairs(op:GetSitesForFront("tanaris")) do onFront = onFront or s == site end
assert(onFront, "the outpost is not listed for its front")
assert(site.mapID == 1446 and site.mapIDs[71] and site.regionalMapIDs[1414], "outpost maps")
for id, zone in pairs(byId) do
    local dx, dy = zone.center[1] - site.center[1], (zone.center[2] - site.center[2]) * ar
    assert(math.sqrt(dx * dx + dy * dy) > zone.radius + site.halfSize * 1.5, "the outpost touches " .. id)
end
print("Forever Tanaris: 10 points, routes, capture circles, Gnome and Goblin portraits, Broken Pillar outpost OK")
