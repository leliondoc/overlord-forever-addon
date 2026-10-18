-- 2.0.3: a point the player's faction can take now shows in yellow, an ordinary one with
-- the Warfronts barracks (crossed swords) lifted to yellow by a second ADD layer
-- (Zones:IsZoneAttackable, GetZoneMapIconAtlas, ApplyZoneMapIcon). Capitals keep their hall.
-- Read from the owners on any front: the "available" status is only kept for the front the
-- player stands on (a map of another front first showed no yellow at all).
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local Z, F = Overlord.Zones, Overlord.Fronts

-- 1. Which points are attackable, on a front that is not the active one (Hillsbrad, the
-- Alliance holds Southshore and the Western Strand; statuses left stale on purpose).
local front = F:GetFront("hillsbrad")
assert(front and front.zones and #front.zones == 10, "fixture: no Hillsbrad front")
local byId = {}
for _, zone in ipairs(front.zones) do
    byId[zone.id] = zone
    zone.owner, zone.status = "Horde", "locked"
end
byId.hillsbrad_southshore.owner, byId.hillsbrad_southshore.status = "Alliance", "captured"
byId.hillsbrad_western_strand.owner, byId.hillsbrad_western_strand.status = "Alliance", "captured"
local savedTruce = Z.IsFrontOnTruce
Z.IsFrontOnTruce = function() return false, 0 end
assert(Z:IsZoneAttackable(byId.hillsbrad_fields), "the point after our Western Strand is not attackable")
assert(Z:IsZoneAttackable(byId.hillsbrad_nethander), "the point after our capital is not attackable")
assert(not Z:IsZoneAttackable(byId.hillsbrad_internment_camp), "a point two steps ahead reads attackable")
assert(not Z:IsZoneAttackable(byId.hillsbrad_western_strand), "our own point reads attackable")
assert(not Z:IsZoneAttackable(byId.hillsbrad_tarren_mill), "the enemy capital reads attackable with points left")
-- A neutral point is attackable too; one in progress is not.
byId.hillsbrad_fields.owner = nil
assert(Z:IsZoneAttackable(byId.hillsbrad_fields), "a neutral open point is not attackable")
byId.hillsbrad_fields.status = "in_progress"
assert(not Z:IsZoneAttackable(byId.hillsbrad_fields), "a point in progress reads attackable")
byId.hillsbrad_fields.owner, byId.hillsbrad_fields.status = "Horde", "locked"
-- A prerequisite of ours still waiting for the login sync does not open the next point.
byId.hillsbrad_western_strand._loginSyncUnconfirmed = true
assert(not Z:IsZoneAttackable(byId.hillsbrad_fields), "a prerequisite under login sync opened the next point")
byId.hillsbrad_western_strand._loginSyncUnconfirmed = nil
-- The enemy capital once every other point is ours.
for _, zone in ipairs(front.zones) do
    if zone.id ~= "hillsbrad_tarren_mill" then zone.owner, zone.status = "Alliance", "captured" end
end
assert(Z:IsZoneAttackable(byId.hillsbrad_tarren_mill), "the enemy capital is not attackable with every point ours")
-- Truce: given by the caller, or read here.
assert(not Z:IsZoneAttackable(byId.hillsbrad_tarren_mill, true), "a point of a front on truce reads attackable")
Z.IsFrontOnTruce = function() return true, 60 end
assert(not Z:IsZoneAttackable(byId.hillsbrad_tarren_mill), "the truce is not read when the caller does not know it")
Z.IsFrontOnTruce = savedTruce
assert(not Z:IsZoneAttackable({ id = "not_a_point", owner = "Horde", status = "available" }), "an unknown point reads attackable")

-- 2. The icon: barracks for an attackable ordinary point only.
local enemy = { id = "hillsbrad_fields", status = "captured", owner = "Horde" }
assert(Z:GetZoneMapIconAtlas(enemy, true, true) == Z.OBJECTIVE_ATTACK_ATLAS, "no barracks on an attackable point")
assert(Z:GetZoneMapIconAtlas(enemy, true, false) == Z.OBJECTIVE_HORDE_ATLAS, "the barracks shows on a point not attackable")
assert(Z:GetZoneMapIconAtlas(byId.hillsbrad_tarren_mill, true, true) ~= Z.OBJECTIVE_ATTACK_ATLAS, "a capital lost its hall")
assert(Z:GetZoneMapIconAtlas({ id = "x", status = "in_progress" }, false, true) ~= Z.OBJECTIVE_ATTACK_ATLAS,
    "a point in progress shows the barracks")

-- 3. The texture: yellow tint, and the ADD layer shown with it and hidden after it.
local function texture()
    local t = { shown = false }
    function t:SetTexCoord() end
    function t:SetVertexColor(r, g, b) self.r, self.g, self.b = r, g, b end
    function t:SetAtlas(atlas) self.atlas = atlas; return true end
    function t:SetBlendMode(mode) self.blend = mode end
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    return t
end
local icon, glow = texture(), texture()
Z:ApplyZoneMapIcon(icon, Z.OBJECTIVE_ATTACK_ATLAS, glow)
assert(icon.atlas == Z.OBJECTIVE_ATTACK_ATLAS and icon.r == Z.ATTACK_COLOR[1] and icon.b == Z.ATTACK_COLOR[3],
    "the barracks is not tinted yellow")
assert(glow.shown and glow.blend == "ADD" and glow.atlas == Z.OBJECTIVE_ATTACK_ATLAS, "the second layer is missing")
Z:ApplyZoneMapIcon(icon, Z.OBJECTIVE_HORDE_ATLAS, glow)
assert(not glow.shown and icon.r == 1 and icon.g == 1 and icon.b == 1, "the yellow outlived the attack icon")
Z:ApplyZoneMapIcon(icon, Z.OBJECTIVE_ATTACK_ATLAS)
assert(icon.g == Z.ATTACK_COLOR[2], "the tint needs the second layer")

-- The display order of a front is built once per faction (the panel and the HUD ask for it
-- several times a second): the same list again, the same zones, the order of each side.
local order1 = Z:GetDisplayOrderForFront("hillsbrad")
assert(#order1 == 10 and order1[1] == F:GetZone(front.displayOrder.Alliance[1], "hillsbrad"),
    "display order: not the front's Alliance order")
assert(Z:GetDisplayOrderForFront("hillsbrad") == order1, "display order: rebuilt at every call")
Overlord.PlayerFaction = "Horde"
local hordeOrder = Z:GetDisplayOrderForFront("hillsbrad")
assert(hordeOrder ~= order1 and hordeOrder[1] == F:GetZone(front.displayOrder.Horde[1], "hillsbrad"),
    "display order: the other faction kept the first one's list")
Overlord.PlayerFaction = "Alliance"
assert(Z:GetDisplayOrderForFront("hillsbrad")[1] == order1[1], "display order: back to the Alliance order")

print("Attackable points: read from owners on any front, capital last, truce, yellow barracks, second layer, display order once OK")
