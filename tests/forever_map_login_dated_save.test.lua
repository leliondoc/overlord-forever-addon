-- 1.8.2 login map: a saved capture dated in this campaign is compared by its date
-- with the first map received, like a confirmed capture. Seen in game on 2026-10-10:
-- a /reload next to a neighbour that had missed two captures gave their older owners
-- back (a keep retaken at 11:57 returned to its 10:42 owner), and nothing repaired it.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
setmetatable(Overlord.L, { __index = function(_, key) return tostring(key) end })
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("ZoneCaptureLease.lua"))()
local sync = Overlord.Sync
local epoch = Overlord:GetCurrentCampaignStartTs()
OverlordDB.zones = {}
OverlordDB.frontVictories = {}
OverlordDB.frontTruceResetEpoch = {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RestoreZoneState()
Overlord.PrintNotification = function() end

local zones, byId = {}, {}
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zones[#zones + 1] = zone; byId[zone.id] = zone end
end
local function set(id, owner, at)
    local zone = assert(byId[id], id)
    zone.owner, zone.status, zone.capturedTime, zone.updatedAt = owner, "captured", at, at
    zone._loginSyncUnconfirmed = nil
end
local function save()
    OverlordDB.zones = {}
    for _, zone in ipairs(zones) do
        OverlordDB.zones[zone.id] = { owner = zone.owner, status = zone.status,
            capturedTime = zone.capturedTime, updatedAt = zone.updatedAt,
            killsCurrent = 0, holdTimeElapsed = 0 }
    end
end
local function login()
    for _, zone in ipairs(zones) do
        zone.owner, zone.capturedTime, zone.updatedAt, zone.status = nil, nil, nil, "locked"
    end
    Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
    Overlord:RequireCaptureSync("login")
    Overlord:RestoreZoneState()
end

-- Two zones of the active front, two of another front (another code path).
local elwynn, arathi = Overlord.Fronts:GetFront("elwynn"), Overlord.Fronts:GetFront("arathi")
local function branches(front)
    local out = {}
    for _, zone in ipairs(front.zones) do
        if zone.id ~= front.allianceCapitalId and zone.id ~= front.hordeCapitalId then out[#out + 1] = zone.id end
    end
    return out
end
local active, other = branches(elwynn), branches(arathi)
-- Recent events: the friendly-capture heal below only looks a few hours back.
local T1, T2, T3 = time() - 3000, time() - 2000, time() - 1000
assert(T1 > epoch, "Fixture clock before the campaign")

-- The neighbour's map: it missed our four later events and knows one we do not.
set(active[1], "Horde", T1); set(other[1], "Horde", T1)        -- we retook both at T2
set(active[2], "Alliance", T1); set(other[2], "Alliance", T1)  -- lost and retaken at T2
set(active[3], "Horde", T3); set(other[3], "Horde", T3)        -- news for us
local stale = sync:BuildZoneAllSnapshotPages(zones, "G")
assert(#stale > 0 and stale[1]:match("^@G%-"), "The neighbour served no global map")

-- Our save, then the login next to that neighbour.
set(active[1], "Alliance", T2); set(other[1], "Alliance", T2)
set(active[2], "Alliance", T2); set(other[2], "Alliance", T2)
set(active[3], "Alliance", T2); set(other[3], "Alliance", T2)
save()
login()
assert(byId[active[1]]._loginSyncUnconfirmed and byId[other[1]]._loginSyncUnconfirmed,
    "The login did not quarantine the saved map")
assert(sync:LoginSaveKeepsItsDate(byId[other[1]]), "A dated save of this campaign does not stand")
local complete = false
Overlord.MarkCaptureSyncReceived = function(_, full) complete = complete or full == true end
for _, page in ipairs(stale) do sync:OnReceiveZoneAll(page, "Stale Neighbour") end
assert(complete, "The login map was not counted as received")

for _, id in ipairs({ active[1], other[1] }) do
    local zone = byId[id]
    assert(zone.owner == "Alliance" and zone.capturedTime == T2,
        "An older owner replaced a newer saved capture at login: " .. id
        .. " " .. tostring(zone.owner) .. "@" .. tostring((zone.capturedTime or 0) - epoch))
end
for _, id in ipairs({ active[2], other[2] }) do
    assert(byId[id].owner == "Alliance" and byId[id].capturedTime == T2,
        "A saved capture date went backwards at login: " .. id)
end
for _, id in ipairs({ active[3], other[3] }) do
    assert(byId[id].owner == "Horde" and byId[id].capturedTime == T3,
        "A capture newer than the save was not learnt at login: " .. id)
end
for _, zone in ipairs(zones) do
    assert(not zone._loginSyncUnconfirmed, "Zone still waiting for the login map: " .. zone.id)
end

-- The map this client now serves carries the newer captures: the neighbour that
-- pulls it is repaired too (same handler, no quarantine there).
local mine = sync:BuildZoneAllSnapshotPages(zones, "G")
set(active[1], "Horde", T1); set(other[1], "Horde", T1)
set(active[2], "Alliance", T1); set(other[2], "Alliance", T1)
sync._lastAcceptedZaPayload = nil
for _, page in ipairs(mine) do sync:OnReceiveZoneAll(page, "Fresh Client") end
for _, id in ipairs({ active[1], other[1], active[2], other[2] }) do
    assert(byId[id].owner == "Alliance" and byId[id].capturedTime == T2,
        "The stale neighbour was not repaired by the newer map: " .. id)
end

-- A save without a date still yields to the first map (nothing to compare).
set(other[4], "Horde", T1)
local dated = sync:BuildZoneAllSnapshotPages(zones, "G")
byId[other[4]].owner, byId[other[4]].capturedTime, byId[other[4]].updatedAt = "Alliance", nil, 0
save()
login()
assert(not sync:LoginSaveKeepsItsDate(byId[other[4]]), "An undated save stands against a map")
sync._lastAcceptedZaPayload = nil
for _, page in ipairs(dated) do sync:OnReceiveZoneAll(page, "Dated Neighbour") end
assert(byId[other[4]].owner == "Horde" and byId[other[4]].capturedTime == T1,
    "An undated save was kept against a dated capture")

-- A live capture older than the save does not replace it either (other front).
set(other[5], "Alliance", T2)
save()
login()
sync._enemyFinalStats = nil
sync:OnReceiveCapture(other[5] .. ":Late Horde|WARRIOR:Horde:" .. T1 .. ":w1:Player-1-0000ABCD:120", "Late Horde")
assert(sync:GetEnemyCaptureFinalDiagnostics():find("C passed 1", 1, true),
    "The older capture was not a well-formed final: " .. sync:GetEnemyCaptureFinalDiagnostics())
assert(byId[other[5]].owner == "Alliance" and byId[other[5]].capturedTime == T2,
    "An older capture replaced a newer save during the login window")
-- A newer one is taken at once, as always.
sync:OnReceiveCapture(other[5] .. ":Late Horde|WARRIOR:Horde:" .. T3 .. ":w2:Player-1-0000ABCD:120", "Late Horde")
assert(byId[other[5]].owner == "Horde" and byId[other[5]].capturedTime == T3,
    "A capture newer than the save was refused during the login window")
-- A group mate's older map: its "ours since T1" does not take back a zone the save
-- knows lost at T2 (the friendly-capture heal is for a confirmed zone only).
local baseGetTime = GetTime
function GetTime() return baseGetTime() + 60 end
function IsInGroup() return true end
function IsInRaid() return false end
function UnitExists(unit) return unit == "party1" end
function UnitFactionGroup() return "Alliance" end
local baseUnitName = Overlord.SafeGetUnitName
function Overlord:SafeGetUnitName(unit, ...)
    if unit == "party1" then return "Stale Mate" end
    return baseUnitName(self, unit, ...)
end
assert(sync:SenderIsInOurGroup("Stale Mate"), "Fixture: the group mate is not seen in the party")
set(active[4], "Alliance", T1)
local mate = sync:BuildZoneAllSnapshotPages(zones, "G")
set(active[4], "Horde", T2)
save()
login()
sync._lastAcceptedZaPayload = nil
for _, page in ipairs(mate) do sync:OnReceiveZoneAll(page, "Stale Mate") end
assert(byId[active[4]].owner == "Horde" and byId[active[4]].capturedTime == T2,
    "A group mate's older map took back a zone the save knew lost: "
    .. tostring(byId[active[4]].owner) .. "@" .. tostring((byId[active[4]].capturedTime or 0) - epoch))
print("Forever login map: a dated save keeps the newer capture, learns newer ones, repairs the neighbour")
