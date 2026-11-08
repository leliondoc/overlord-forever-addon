-- 2.2.2: on one ruleset every client ends with the same map, whatever the order of
-- the copies it receives.
-- (a) The friendly-capture heal (TryHealStaleEnemyOwnerFromFriendlyCapture) never
--     compared the ally capture with the enemy capture it replaced: a late relayed copy
--     of an older ally capture overwrote a newer enemy capture on the clients where the
--     heal's trust test held (sender in our group, or two allies and no enemy on the
--     disk), every other client kept the enemy capture.
-- (b) On the active front, a different-owner capture ZS was compared with updatedAt,
--     on an inactive front, in C and in ZA with the capture date. updatedAt rises with
--     no new capture (a direct revert, a same-owner merge) and is 0 after a /reload:
--     two clients receiving the same two copies in different orders kept different
--     owners. Real Sync, Zones and lease code; finals carry the real modern claim.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
setmetatable(Overlord.L, { __index = function(_, key) return tostring(key) end })
Overlord.PlayerFaction = "Alliance"
UnitIsDead = UnitIsDead or function() return false end
UnitIsDeadOrGhost = UnitIsDeadOrGhost or function() return false end
UnitIsGhost = UnitIsGhost or function() return false end
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("ZoneCaptureLease.lua"))()
local sync = Overlord.Sync
local clock, wall = 1000, time()
function GetTime() return clock end
function time() return wall end
function GetServerTime() return wall end
Overlord.ServerNow = function() return wall end
C_Timer.After = function() end
C_Timer.NewTimer = function() return { Cancel = function() end } end
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig("Alliance")
Overlord:RestoreZoneState()
Overlord.PrintNotification = function() end
Overlord.SaveState = function() end
sync.BroadcastZoneState = function() end
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zone._loginSyncUnconfirmed = nil end
end
if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived(true) end

local function upvalue(fn, wanted)
    for index = 1, 255 do
        local key, value = debug.getupvalue(fn, index)
        if key == nil then break end
        if key == wanted then return value end
    end
    error("missing upvalue " .. wanted)
end
local heal = upvalue(sync.OnReceiveZoneState, "TryHealStaleEnemyOwnerFromFriendlyCapture")

local ID = "elwynn_goldshire"
local zone = Overlord.Zones:GetZone(ID)
assert(zone and not zone.isCapital, "fixture: " .. ID .. " is not a plain point of the active front")
local B = wall - 4000 -- every date of this test is B + seconds, inside the campaign

local function reset(fields)
    for _, key in ipairs({ "status", "owner", "capturedTime", "updatedAt", "previousOwner", "isHolding",
        "holdAuthorityLocal", "holdTimeElapsed", "isContested", "isPaused", "holdStartTime",
        "_loginSyncUnconfirmed", "_captureFinalUnattested", "_remoteCaptureLease", "lastZSSender",
        "zsRelayCapturerName", "zsOfficialCapturerName" }) do
        zone[key] = nil
    end
    for key, value in pairs(fields) do zone[key] = value end
    zone.holdTimeRequired = 120
end
local function view() return tostring(zone.status) .. "/" .. tostring(zone.owner) .. "/" .. tostring(zone.capturedTime) end

-- (a) The heal itself. Trusted here: two allies and no enemy on the disk.
local realPlayerZone, realScan = Overlord.Zones.GetCurrentPlayerZone, Overlord.ZoneControl.ScanNearbyPlayers
Overlord.Zones.GetCurrentPlayerZone = function() return zone end
Overlord.ZoneControl.ScanNearbyPlayers = function() return 2, 0 end
-- A late copy of an ally capture older than the enemy capture: no heal.
reset({ status = "captured", owner = "Horde", capturedTime = B + 1100, updatedAt = B + 1150 })
assert(heal(zone, "captured", "Alliance", B + 1000, "Ally-Realm") == false,
    "a late ally capture older than the enemy capture overwrote it")
assert(view() == "captured/Horde/" .. (B + 1100), "a refused heal touched the zone: " .. view())
-- Same second: the deterministic tie-break of every other capture merge decides.
local tieAt = B + 1100
if sync:DeterministicCaptureTieOwner(ID, tieAt) == "Alliance" then tieAt = tieAt + 1 end
reset({ status = "captured", owner = "Horde", capturedTime = tieAt, updatedAt = tieAt + 50 })
assert(heal(zone, "captured", "Alliance", tieAt, "Ally-Realm") == false,
    "a same-second ally capture beat the enemy capture against the tie-break")
-- A genuinely stale enemy owner (its capture older than ours, updatedAt bumped): healed.
reset({ status = "captured", owner = "Horde", capturedTime = B + 900, updatedAt = B + 1150 })
assert(heal(zone, "captured", "Alliance", B + 1000, "Ally-Realm") == true,
    "a stale enemy owner older than the ally capture was not healed")
assert(view() == "captured/Alliance/" .. (B + 1000) and zone.updatedAt == B + 1000, view())
-- Login save without a usable date: still healed (nothing to defend).
reset({ status = "captured", owner = "Horde", capturedTime = 0, updatedAt = 0, _loginSyncUnconfirmed = true })
assert(heal(zone, "captured", "Alliance", B + 1000, "Ally-Realm") == true,
    "an undated login save blocked the heal")
Overlord.Zones.GetCurrentPlayerZone, Overlord.ZoneControl.ScanNearbyPlayers = realPlayerZone, realScan

-- (b) Whole OnReceiveZoneState, the same copies in both orders.
local mark = sync:GetFrontMark(ID)
assert(mark, "fixture: no front mark")
local run = 0
local function finalZS(code, who, at)
    sync:OnReceiveZoneState(table.concat({ ID, "captured", 0, 0, code, at, 0, 120, who, 1,
        "w" .. run .. (who:gsub("%W", "")), "Player-1-0000" .. string.format("%04d", run), 120 }, ":") .. ":~f" .. mark, who, "CHANNEL")
end
local function revertZS(who, at)
    -- The direct end of the lease this client follows (same sender), as a capturer leaving sends it.
    zone._remoteCaptureLease = zone._remoteCaptureLease
        or { directValidated = true, lastRemoteTs = 0, originName = who, originKey = who }
    sync:OnReceiveZoneState(table.concat({ ID, "available", 0, 0, "N", at, 0, 120 }, ":") .. ":~f" .. mark, who, "CHANNEL")
end

-- One client: a starting state, then copies; the result once the deferred
-- availability pass has run (the map a player sees).
local function client(start, copies)
    run = run + 1
    clock = clock + 10000
    reset(start)
    for _, copy in ipairs(copies) do copy() end
    Overlord.Zones:_DoUpdateAvailableZones(true)
    return view(), tostring(zone.owner) .. "/" .. tostring(zone.capturedTime)
end
local function both(name, start, first, second)
    local a, owned = client(start(), { first, second })
    local b = client(start(), { second, first })
    assert(a == b, name .. ": the two orders end apart: " .. a .. " vs " .. b)
    return owned
end
local function pair(name, startA, startB, copies)
    local a, owned = client(startA, copies)
    local b = client(startB, copies)
    assert(a == b, name .. ": two clients end apart: " .. a .. " vs " .. b)
    return owned
end

-- (b1) Y's final at 1195 and Z's direct revert at 1200 of a Horde siege on our point.
local got = both("final vs revert",
    function() return { status = "in_progress", owner = "Horde", previousOwner = "Alliance",
        capturedTime = B + 500, updatedAt = B + 1190, holdTimeElapsed = 60 } end,
    function() finalZS("H", "Horde Y-Realm", B + 1195) end,
    function() revertZS("Horde Z-Realm", B + 1200) end)
assert(got == "Horde/" .. (B + 1195), "final vs revert: " .. got)
-- Same on a point nobody held: the revert leaves it neutral, the capture still wins.
got = both("final vs revert, neutral point",
    function() return { status = "in_progress", owner = "Horde", capturedTime = 0, updatedAt = B + 1190,
        holdTimeElapsed = 60 } end,
    function() finalZS("H", "Horde Y-Realm", B + 1195) end,
    function() revertZS("Horde Z-Realm", B + 1200) end)
assert(got == "Horde/" .. (B + 1195), "final vs revert, neutral point: " .. got)

-- (b2) After a /reload (updatedAt 0, save kept with its date) a late relayed ally capture
-- at 1000 against the saved Horde capture at 1100: the client that did not reload keeps
-- Horde, so must the one that did.
local function lateAlly() finalZS("A", "Ally Q-Realm", B + 1000) end
got = pair("late ally capture after a /reload",
    { status = "captured", owner = "Horde", capturedTime = B + 1100, updatedAt = B + 1100 },
    { status = "captured", owner = "Horde", capturedTime = B + 1100, updatedAt = 0, _loginSyncUnconfirmed = true },
    { function()
        if zone._loginSyncUnconfirmed then
            assert(sync:LoginSaveKeepsItsDate(zone), "fixture: the saved capture has no campaign date")
        end
        lateAlly()
    end })
assert(got == "Horde/" .. (B + 1100), "a late ally capture beat the saved newer enemy capture: " .. got)

-- (b3) A same-owner merge raised updatedAt past the date of a newer enemy capture: the
-- client with the raised updatedAt ends like the one without.
got = pair("newer capture vs raised updatedAt",
    { status = "captured", owner = "Alliance", capturedTime = B + 1000, updatedAt = B + 1000 },
    { status = "captured", owner = "Alliance", capturedTime = B + 1000, updatedAt = B + 1300 },
    { function() finalZS("H", "Horde Y-Realm", B + 1200) end })
assert(got == "Horde/" .. (B + 1200), "a newer enemy capture lost: " .. got)
-- Same second as the held capture: the tie-break decides, not updatedAt.
local tie = B + 1000
if sync:DeterministicCaptureTieOwner(ID, tie) ~= "Horde" then tie = tie + 1 end
got = pair("same-second capture vs raised updatedAt",
    { status = "captured", owner = "Alliance", capturedTime = tie, updatedAt = tie },
    { status = "captured", owner = "Alliance", capturedTime = tie, updatedAt = tie + 300 },
    { function() finalZS("H", "Horde Y-Realm", tie) end })
assert(got == "Horde/" .. tie, "same-second capture against the tie-break: " .. got)
-- 2.3.0: each client settles that tie by itself. The copy it sent of the result carried no
-- wave of its own (every client refuses such a final as legacy), on the group, the channel,
-- the relay and Battle.net: one wasted broadcast per client that lost the tie.
do
    local stub, sent = sync.BroadcastZoneState, 0
    sync.BroadcastZoneState = function(_, z) if z == zone then sent = sent + 1 end end
    pair("same-second capture, no copy sent",
        { status = "captured", owner = "Alliance", capturedTime = tie, updatedAt = tie },
        { status = "captured", owner = "Alliance", capturedTime = tie, updatedAt = tie + 300 },
        { function() finalZS("H", "Horde Y-Realm", tie) end })
    sync.BroadcastZoneState = stub
    assert(sent == 0, "a tie-break settled here was broadcast again: " .. sent .. " copies")
end
-- An older enemy capture still loses, whatever updatedAt says.
got = pair("older enemy capture",
    { status = "captured", owner = "Alliance", capturedTime = B + 1000, updatedAt = B + 1000 },
    { status = "captured", owner = "Alliance", capturedTime = B + 1000, updatedAt = B + 1300 },
    { function() finalZS("H", "Horde Y-Realm", B + 900) end })
assert(got == "Alliance/" .. (B + 1000), "an older enemy capture took the point: " .. got)

print("Zone heal and order: older ally copies never heal, same map in both orders OK")
