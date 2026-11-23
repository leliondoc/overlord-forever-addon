-- 2026-11-21: "Thoradin's Wall is now available" printed three times in a row. The zone
-- flickered available -> locked -> available with nothing really changed: a Horde wave on
-- its prerequisite (Refuge in_progress) that failed, or a siege of the zone itself that
-- was cancelled. The line is said once per opening; a real loss of the prerequisite, a
-- capture of the zone or a truce opens it anew.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
Overlord.L.ZONE_NOW_AVAILABLE = "%s available"
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local zones = Overlord.Zones
local campaign = Overlord:GetCurrentCampaignStartTs()
local clock = campaign + 200000
time = function() return clock end
GetServerTime = function() return clock end
Overlord.InstanceSuspended = false
Overlord.SaveState = function() end
Overlord.MarkDirty = function() end
local printed = {}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
for _, name in ipairs({ "Send", "SendToGroup", "SendToChannel", "BroadcastToRelay", "SendWhisper" }) do
    Overlord.Sync[name] = function() end
end

OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("arathi")
zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RequireCaptureSync("login")
Overlord:RestoreZoneState()
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zone._loginSyncUnconfirmed = nil; zone.name = zone.id end
end
Overlord.InActiveFront = true

local function zoneOf(id) return (select(1, Overlord.Fronts:GetZone(id, "arathi"))) end
local refuge, wall = zoneOf("refuge"), zoneOf("newstead")
assert(refuge and wall, "Arathi zones missing")
wall.name = "Wall"
local function own(z, owner, status)
    z.owner, z.status, z.capturedTime, z.updatedAt = owner, status or "captured", clock, clock
end
local function pass() clock = clock + 5; zones:_DoUpdateAvailableZones(false) end
local function count()
    local n = 0
    for _, line in ipairs(printed) do if line:find("Wall available", 1, true) then n = n + 1 end end
    return n
end

-- The Alliance holds Refuge: the Wall opens, once.
own(refuge, "Alliance")
wall.owner, wall.status, wall.capturedTime = nil, "locked", nil
pass()
assert(wall.status == "available", "Wall not opened: " .. tostring(wall.status))
assert(count() == 1, "Opening not announced once: " .. count())
pass()
assert(count() == 1, "A quiet pass announced again")

-- (a) A Horde wave on Refuge: the Wall closes while it lasts, the wave fails, no new line.
for _ = 1, 3 do
    own(refuge, "Horde", "in_progress")
    pass()
    assert(wall.status == "locked", "The Wall stayed open under a siege of Refuge")
    own(refuge, "Alliance")
    pass()
    assert(wall.status == "available", "The Wall did not reopen")
end
assert(count() == 1, "A failed wave on Refuge announced the Wall again: " .. count())

-- (b) A siege of the Wall itself, cancelled: no new line.
for _ = 1, 3 do
    wall.owner, wall.status = "Alliance", "in_progress"
    pass()
    wall.owner, wall.status = nil, "locked"
    pass()
    assert(wall.status == "available", "The Wall did not reopen after a cancelled siege")
end
assert(count() == 1, "A cancelled siege announced the Wall again: " .. count())

-- A quarantined Refuge (login) is a short wait too.
refuge._loginSyncUnconfirmed = true
local realBlocked = Overlord.IsLoginZoneGameplayBlocked
Overlord.IsLoginZoneGameplayBlocked = function() return true end
pass()
assert(wall.status == "locked", "A quarantined prerequisite opened the Wall")
refuge._loginSyncUnconfirmed = nil
Overlord.IsLoginZoneGameplayBlocked = realBlocked
pass()
assert(wall.status == "available" and count() == 1, "The login quarantine announced the Wall again")

-- (c) The Horde really takes Refuge, the Alliance takes it back: the Wall opens anew.
own(refuge, "Horde")
pass()
assert(wall.status == "locked", "The Wall stayed open with Refuge lost")
own(refuge, "Alliance")
pass()
assert(count() == 2, "A real reopening was not announced: " .. count())

-- (d) The Alliance takes the Wall, the Horde takes it back: a new opening, announced.
own(wall, "Alliance")
pass()
assert(count() == 2, "Our capture announced the Wall")
wall.owner, wall.status, wall.capturedTime = nil, "locked", nil
pass()
assert(count() == 3, "The Wall open again after its capture was not announced: " .. count())

-- A silent opening (login pass) counts as said: a later flicker stays quiet.
own(refuge, "Horde")
pass()
own(refuge, "Alliance")
clock = clock + 5
zones:_DoUpdateAvailableZones(true)
assert(wall.status == "available" and count() == 3, "A silent pass printed")
own(refuge, "Horde", "in_progress")
pass()
own(refuge, "Alliance")
pass()
assert(count() == 3, "A flicker after a silent opening was announced")

print("Available alert: once per opening, not on a failed siege or a quarantine")
