-- 1.8.2: a point taken by a group. The observer follows the timer of the first
-- player it heard; the capture is finished by another one (the first died or stepped
-- off and his release never arrived, as often across factions). Since 1.5.1 that
-- final and its retries were refused ("C otherCapturer"), the followed timer ran out
-- ("lease expiredWithoutFinal") and the point went back to its previous owner on the
-- observer's map for good: enemy captures seen in progress and never turning red.
-- Real Sync and capture lease code; only the clock is simulated.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
setmetatable(Overlord.L, { __index = function(_, key) return tostring(key) end })
Overlord.PlayerFaction = "Alliance"
-- The observer is alive, on foot, away from the points (no unit of the game around).
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
local timers = {}
C_Timer.After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end
C_Timer.NewTimer = function(delay, fn)
    local timer = { at = clock + delay, fn = fn, Cancel = function(self) self.cancelled = true end }
    timers[#timers + 1] = timer
    return timer
end
local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        wall, clock = wall + (timer.at - clock), timer.at
        if not timer.cancelled then timer.fn() end
    end
    wall, clock = wall + (stop - clock), stop
end
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig("Alliance")
Overlord:RestoreZoneState()
Overlord.PrintNotification = function() end
Overlord.SaveState = function() end
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zone._loginSyncUnconfirmed = nil end
end
if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived(true) end

local function zoneOf(id) return (select(1, Overlord.Fronts:GetZone(id))) end
local function set(id, owner, at)
    local zone = zoneOf(id)
    zone.owner, zone.status, zone.capturedTime, zone.updatedAt = owner, owner and "captured" or "locked", at, at
end
local function progress(id, code, who, wave, guid, hold)
    sync:OnReceiveZoneState(table.concat({ id, "in_progress", 0, hold, code, wall, 0, 120, who, 1, wave, guid }, ":"),
        who, "CHANNEL")
end
local function finalC(id, faction, who, wave, guid, at)
    sync:OnReceiveCapture(table.concat({ id, who .. "|WARRIOR", faction, at or wall, wave, guid, 120 }, ":"), who)
end
local function finalZS(id, code, who, wave, guid, at)
    sync:OnReceiveZoneState(table.concat({ id, "captured", 0, 0, code, at or wall, 0, 120, who, 1, wave, guid, 120 }, ":"),
        who, "CHANNEL")
end
local function counted(what) return sync:GetEnemyCaptureFinalDiagnostics():find(what, 1, true) ~= nil end

-- (1) Another front (the observer is elsewhere, as for most enemy captures). The
-- Alliance holds Go'Shek Farm; two Horde players step on it.
local T0 = wall
set("dabyrie", "Horde", T0 - 4000); set("goshek", "Alliance", T0 - 40000)
local goshek = zoneOf("goshek")
sync._enemyFinalStats = nil
progress("goshek", "H", "Horde Alpha", "wA", "Player-1-0000AAAA", 5)
assert(goshek.status == "in_progress" and goshek._remoteCaptureLease
    and goshek._remoteCaptureLease.originKey == "horde alpha", "fixture: the first player's timer is not followed")
advance(30)
progress("goshek", "H", "Horde Bravo", "wB", "Player-1-0000BBBB", 35)
assert(goshek._remoteCaptureLease.originKey == "horde alpha", "fixture: the second player's tick replaced the followed timer")
advance(85)
local takenAt = wall
finalC("goshek", "Horde", "Horde Bravo", "wB", "Player-1-0000BBBB")
assert(goshek.owner == "Horde" and goshek.status == "captured" and goshek.capturedTime == takenAt,
    "a point finished by another player of the group was not taken on the observer's map: "
    .. tostring(goshek.owner) .. "/" .. tostring(goshek.status))
assert(counted("C passed 1") and not counted("otherCapturer"), sync:GetEnemyCaptureFinalDiagnostics())
assert(not goshek._remoteCaptureLease, "the followed timer survived the capture")
-- Its retries, and the followed player's own late final, change nothing.
advance(6); finalC("goshek", "Horde", "Horde Bravo", "wB", "Player-1-0000BBBB", takenAt)
advance(10); finalC("goshek", "Horde", "Horde Alpha", "wA", "Player-1-0000AAAA", takenAt - 3)
assert(goshek.owner == "Horde" and goshek.capturedTime == takenAt, "a late copy moved the capture")
advance(300)
assert(goshek.owner == "Horde" and goshek.status == "captured" and goshek.capturedTime == takenAt
    and not counted("expiredWithoutFinal"), "the point went back to its previous owner after the capture")

-- (2) The same capture ending by its state message (ZS captured) instead of C.
set("witherbark", "Alliance", T0 - 40000)
local witherbark = zoneOf("witherbark")
advance(60)
progress("witherbark", "H", "Horde Alpha", "wA2", "Player-1-0000AAAA", 5)
assert(witherbark.status == "in_progress", "fixture: second point not under assault")
advance(115)
takenAt = wall
finalZS("witherbark", "H", "Horde Bravo", "wB2", "Player-1-0000BBBB")
assert(witherbark.owner == "Horde" and witherbark.status == "captured" and witherbark.capturedTime == takenAt,
    "a state final by another player of the group was refused")
assert(counted("ZS passed 1") and not counted("otherCapturer"), sync:GetEnemyCaptureFinalDiagnostics())

-- (3) On the front the observer stands on.
local own
for _, zone in ipairs(Overlord.Fronts:GetFront("elwynn").zones) do
    if zone.owner == "Alliance" and not zone.isCapital then own = zone; break end
end
if not own then
    for _, zone in ipairs(Overlord.Fronts:GetFront("elwynn").zones) do
        if not zone.isCapital then own = zone; break end
    end
    set(own.id, "Alliance", T0 - 40000)
    Overlord.Zones:UpdateAvailableZones()
end
own = Overlord.Zones:GetZone(own.id)
own.owner, own.status, own.capturedTime, own.updatedAt = "Alliance", "captured", T0 - 40000, T0 - 40000
advance(60)
progress(own.id, "H", "Horde Alpha", "wA3", "Player-1-0000AAAA", 5)
assert(own.status == "in_progress" and own._remoteCaptureLease, "fixture: the point of our front is not under assault")
advance(115)
takenAt = wall
finalC(own.id, "Horde", "Horde Bravo", "wB3", "Player-1-0000BBBB")
-- (an enemy point of our own front reads "available" or "locked": what we may attack)
assert(own.owner == "Horde" and own.status ~= "in_progress" and own.capturedTime == takenAt
    and not own._remoteCaptureLease,
    "on our own front, a point finished by another player of the group was not taken")

-- (4) A neutral point both factions fight for: we follow a Horde timer, an Alliance
-- player completes first. His final is a capture like any other.
local neutral = zoneOf("faldir")
neutral.owner, neutral.status, neutral.capturedTime, neutral.updatedAt = nil, "locked", nil, 0
set("stromgarde", "Alliance", T0 - 40000)
advance(60)
progress("faldir", "H", "Horde Alpha", "wA4", "Player-1-0000AAAA", 5)
advance(100)
takenAt = wall
finalC("faldir", "Alliance", "Ally Charlie", "wC4", "Player-1-0000CCCC")
assert(neutral.owner == "Alliance" and neutral.status == "captured" and neutral.capturedTime == takenAt,
    "the other faction's capture of a point was refused while a timer was followed there")

-- (4b) The followed player still counts afterwards. A Horde player starts on a neutral
-- point and we follow him; an Alliance player completes there first (taken, the
-- Horde timer closed here). When the Horde player completes afterwards, his final
-- is another capture: accepted, although his timer was closed here.
do
    local point = zoneOf("witherbark")
    point.owner, point.status, point.capturedTime, point.updatedAt = nil, "locked", nil, 0
    advance(60)
    progress("witherbark", "H", "Horde Delta", "wD", "Player-1-0000DDDD", 5)
    assert(point.status == "in_progress" and point._remoteCaptureLease, "fixture: the Horde timer is not followed")
    advance(3)
    local allyAt = wall
    finalC("witherbark", "Alliance", "Ally Echo", "wE", "Player-1-0000EEEE", allyAt)
    assert(point.owner == "Alliance" and point.capturedTime == allyAt and not point._remoteCaptureLease,
        "fixture: the other faction's capture was not taken")
    advance(118)
    local hordeAt = wall
    finalC("witherbark", "Horde", "Horde Delta", "wD", "Player-1-0000DDDD")
    assert(point.owner == "Horde" and point.capturedTime == hordeAt,
        "the followed player's own later capture was refused after another final closed his timer: "
        .. tostring(point.owner) .. "@" .. tostring((point.capturedTime or 0) - T0))
    -- A copy of that same final afterwards is a repeat: nothing moves.
    advance(5)
    finalC("witherbark", "Horde", "Horde Delta", "wD", "Player-1-0000DDDD", hordeAt)
    assert(point.owner == "Horde" and point.capturedTime == hordeAt)
end
-- The same when both captures end by their state message (ZS captured).
do
    local point = zoneOf("newstead")
    point.owner, point.status, point.capturedTime, point.updatedAt = nil, "locked", nil, 0
    advance(60)
    progress("newstead", "H", "Horde Delta", "wD2", "Player-1-0000DDDD", 5)
    assert(point.status == "in_progress" and point._remoteCaptureLease, "fixture: the Horde timer is not followed")
    advance(3)
    local allyAt = wall
    finalZS("newstead", "A", "Ally Echo", "wE2", "Player-1-0000EEEE", allyAt)
    assert(point.owner == "Alliance" and point.capturedTime == allyAt and not point._remoteCaptureLease,
        "fixture: the other faction's state final was not taken")
    advance(118)
    local hordeAt = wall
    finalZS("newstead", "H", "Horde Delta", "wD2", "Player-1-0000DDDD")
    assert(point.owner == "Horde" and point.capturedTime == hordeAt,
        "the followed player's own later state final was refused after another final closed his timer: "
        .. tostring(point.owner) .. "@" .. tostring((point.capturedTime or 0) - T0))
end

-- (4c) A capture older than the timer we follow on a point nobody holds here (we had
-- missed it, its retry reaches us during the assault): the assault stays shown.
-- Should it be given up, the point is nobody's again and any map teaches the
-- capture (see forever_zone_partial_merge 1d').
do
    local point = zoneOf("highperch")
    point.owner, point.status, point.capturedTime, point.updatedAt = nil, "locked", nil, 0
    advance(60)
    local missedAt = wall - 1
    progress("highperch", "H", "Horde Delta", "wD3", "Player-1-0000DDDD", 5)
    local lease = point._remoteCaptureLease
    assert(point.status == "in_progress" and lease, "fixture: the Horde timer is not followed")
    advance(3)
    finalC("highperch", "Alliance", "Ally Echo", "wE3", "Player-1-0000EEEE", missedAt)
    assert(point.status == "in_progress" and point._remoteCaptureLease == lease,
        "a capture older than the followed timer closed it")
    advance(117)
    local hordeAt = wall
    finalC("highperch", "Horde", "Horde Delta", "wD3", "Player-1-0000DDDD")
    assert(point.owner == "Horde" and point.status == "captured" and point.capturedTime == hordeAt,
        "the followed capture was lost after an older final of the other faction")
end

-- (5) Still refused: a final older than what the map holds.
finalC("faldir", "Horde", "Horde Bravo", "wB5", "Player-1-0000BBBB", takenAt - 50)
assert(neutral.owner == "Alliance" and neutral.capturedTime == takenAt, "an older final replaced a newer capture")
print("Forever group capture: a point finished by another player than the one followed is taken (C and ZS, "
    .. "own front and others, either faction); retries and older finals change nothing")
