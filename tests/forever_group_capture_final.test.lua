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
    sync:OnReceiveZoneState(sync:WithFrontMark(id, table.concat({ id, "in_progress", 0, hold, code, wall, 0, 120, who, 1, wave, guid }, ":")),
        who, "CHANNEL")
end
local function finalC(id, faction, who, wave, guid, at)
    sync:OnReceiveCapture(sync:WithFrontMark(id, table.concat({ id, who .. "|WARRIOR", faction, at or wall, wave, guid, 120 }, ":")), who)
end
local function finalZS(id, code, who, wave, guid, at)
    sync:OnReceiveZoneState(sync:WithFrontMark(id, table.concat({ id, "captured", 0, 0, code, at or wall, 0, 120, who, 1, wave, guid, 120 }, ":")),
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

-- (4d) A final that could only cancel the assault we follow is refused: the point
-- "captured" by the faction that already holds it, or the followed wave's own name
-- used for the other faction (it would also close the real capturer's wave). The
-- assault stays shown and its real final is then taken.
do
    set("refuge", "Alliance", T0 - 40000)
    local point = zoneOf("refuge")
    advance(60)
    progress("refuge", "H", "Horde Delta", "wD4", "Player-1-0000DDDD", 5)
    local lease = point._remoteCaptureLease
    assert(point.status == "in_progress" and lease, "fixture: the Horde assault is not followed")
    advance(3)
    finalC("refuge", "Alliance", "Mallory Forger", "wM", "Player-1-0000FFFF")
    assert(point.status == "in_progress" and point._remoteCaptureLease == lease,
        "a final for the faction already holding the point cancelled the assault")
    finalC("refuge", "Alliance", "Horde Delta", "wD4", "Player-1-0000DDDD")
    assert(point.status == "in_progress" and point._remoteCaptureLease == lease,
        "the followed wave's name used for the other faction cancelled the assault")
    finalZS("refuge", "A", "Horde Delta", "wD4", "Player-1-0000DDDD")
    assert(point.status == "in_progress" and point._remoteCaptureLease == lease,
        "the same forged final as a state message cancelled the assault")
    advance(115)
    local hordeAt = wall
    finalC("refuge", "Horde", "Horde Delta", "wD4", "Player-1-0000DDDD")
    assert(point.owner == "Horde" and point.status == "captured" and point.capturedTime == hordeAt,
        "the real capture was refused after a forged final: " .. tostring(point.owner) .. "/" .. tostring(point.status))
end

-- On a point nobody holds too: the followed wave's own name for the other faction is
-- refused, while another player's capture for that faction still counts (4).
do
    local point = zoneOf("argorok")
    point.owner, point.status, point.capturedTime, point.updatedAt = nil, "locked", nil, 0
    advance(60)
    progress("argorok", "H", "Horde Delta", "wD5", "Player-1-0000DDDD", 5)
    local lease = point._remoteCaptureLease
    assert(point.status == "in_progress" and lease, "fixture: the Horde assault on a free point is not followed")
    advance(3)
    finalC("argorok", "Alliance", "Horde Delta", "wD5", "Player-1-0000DDDD")
    assert(point.status == "in_progress" and point._remoteCaptureLease == lease,
        "on a free point, the followed wave's name used for the other faction cancelled the assault")
    advance(2)
    local allyAt = wall
    finalC("argorok", "Alliance", "Ally Echo", "wE5", "Player-1-0000EEEE")
    assert(point.owner == "Alliance" and point.capturedTime == allyAt,
        "another player's capture of a free point for the other faction was refused")
end

-- (5) Still refused: a final older than what the map holds.
finalC("faldir", "Horde", "Horde Bravo", "wB5", "Player-1-0000BBBB", takenAt - 50)
assert(neutral.owner == "Alliance" and neutral.capturedTime == takenAt, "an older final replaced a newer capture")

-- 2.3.0: on another front a final is compared with the capture under the assault, as its
-- state final is and as C is on our own front. A point taken by a group: the player we
-- follow ticks once more after another one completed. The C was compared with that tick:
-- taken when it came first, refused when the tick came first (the point then went back to
-- its defender when the followed timer ran out).
do
    local function assault(id, who, wave, guid)
        set(id, "Alliance", wall - 5000)
        local point = zoneOf(id)
        point._remoteCaptureLease = nil
        advance(60)
        progress(id, "H", who, wave, guid, 5)
        assert(point.status == "in_progress" and point._remoteCaptureLease, "fixture: the assault on " .. id .. " is not followed")
        for i = 1, 9 do advance(10); progress(id, "H", who, wave, guid, 5 + 10 * i) end
        advance(10)
        return point
    end
    -- The final first, then the followed player's last tick.
    local point = assault("goshek", "Horde Xray", "wX1", "Player-1-0000F0A1")
    local takenAt = wall - 1
    finalC("goshek", "Horde", "Horde Yankee", "wY1", "Player-1-0000F0A2", takenAt)
    progress("goshek", "H", "Horde Xray", "wX1", "Player-1-0000F0A1", 105)
    assert(point.owner == "Horde" and point.status == "captured" and point.capturedTime == takenAt,
        "fixture: the final heard before the last tick was not taken: " .. tostring(point.status))
    -- The tick first, then the final: the same capture.
    point = assault("refuge", "Horde Victor", "wV1", "Player-1-0000F0A3")
    takenAt = wall - 1
    progress("refuge", "H", "Horde Victor", "wV1", "Player-1-0000F0A3", 105)
    finalC("refuge", "Horde", "Horde Zulu", "wZ1", "Player-1-0000F0A4", takenAt)
    assert(point.owner == "Horde" and point.status == "captured" and point.capturedTime == takenAt
        and not point._remoteCaptureLease,
        "on another front, a final dated before the followed player's last tick was refused: "
        .. tostring(point.owner) .. "/" .. tostring(point.status))
end

-- 2.3.0: on the front we stand on, the state final of such a capture is compared with the
-- capture under the assault too, as C is there. Compared with the followed player's last
-- tick, it was refused unless our view of his timer had already reached its end.
do
    own.owner, own.status, own.capturedTime, own.updatedAt = "Alliance", "captured", wall - 5000, wall - 5000
    own._remoteCaptureLease = nil
    advance(60)
    progress(own.id, "H", "Horde Tango", "wT9", "Player-1-0000F0A5", 5)
    assert(own.status == "in_progress" and own._remoteCaptureLease, "fixture: the point of our front is not under assault")
    for i = 1, 10 do advance(10); progress(own.id, "H", "Horde Tango", "wT9", "Player-1-0000F0A5", 5 + 10 * i) end
    local takenAt = wall - 1
    finalZS(own.id, "H", "Horde Sierra", "wS9", "Player-1-0000F0A6", takenAt)
    assert(own.owner == "Horde" and own.status ~= "in_progress" and own.capturedTime == takenAt
        and not own._remoteCaptureLease,
        "on our own front, a state final dated before the followed player's last tick was refused: "
        .. tostring(own.owner) .. "/" .. tostring(own.status))
end

-- 2.1.1: nobody on a point hears the others when only the guild carries the news, so a capture of
-- our side, said there by its author, ends a wave of our own there, even dated before our last
-- tick. Real receive paths and lease rule; the lane is only asked where this copy was heard.
do
    local fromAuthor = true
    Overlord.GuildLane = { IsActive = function() return true end, HeardHere = function() return fromAuthor end,
        HeardFromAuthor = function() return fromAuthor end,
        KeepFollowing = function() return nil end, WaveClock = function() return nil end,
        ProvesWave = function() return false end, NoteWaveClosed = function() end }
    -- On the front we stand on: nobody captures anywhere else.
    local onFront
    for _, zone in ipairs(Overlord.Fronts:GetFront("elwynn").zones) do
        if zone.id ~= own.id and not zone.isCapital then onFront = zone.id; break end
    end
    local function localWave(id)
        local point = Overlord.Zones:GetZone(id)
        point.owner, point.status, point.capturedTime, point.holdTimeElapsed = "Alliance", "in_progress", nil, 30
        point.isHolding, point.holdAuthorityLocal, point.holdStartTime = true, true, clock - 30
        point._remoteCaptureLease = nil
        Overlord.CaptureLease:BeginLocal(point)
        advance(20)
        point.updatedAt = wall -- our own tick of this very second
        return point
    end
    advance(600)
    local point = localWave(onFront)
    local dated = wall - 3
    finalZS(onFront, "A", "Ally Mate", "wM1", "Player-1-0000F001", dated)
    assert(point.status == "captured" and point.owner == "Alliance" and point.capturedTime == dated,
        "a final ZS dated before our last tick did not end our wave: " .. tostring(point.status))
    assert(point.holdAuthorityLocal == nil and not point.isHolding, "our wave survived the final ZS: " .. tostring(point.holdAuthorityLocal) .. "/" .. tostring(point.isHolding))
    -- Told any other way, other waves' finals leave ours alone, as they always did: anybody can
    -- whisper one, with any name.
    fromAuthor = false
    advance(600)
    point = localWave(onFront)
    finalZS(onFront, "A", "Ally Mate", "wM2", "Player-1-0000F001", wall - 3)
    assert(point.status == "in_progress" and point.holdAuthorityLocal == true,
        "a final of another wave, told outside the guild, ended ours")
    -- Said in the guild by its author, it ends ours: that wave has no ticks for us.
    fromAuthor = true
    dated = wall - 2
    finalZS(onFront, "A", "Ally Mate", "wM3", "Player-1-0000F001", dated)
    assert(point.status == "captured" and point.capturedTime == dated and point.holdAuthorityLocal == nil,
        "a final heard in the guild did not end our wave")
    -- As a C too.
    advance(600)
    point = localWave(onFront)
    dated = wall - 3
    finalC(onFront, "Alliance", "Ally Mate", "wM4", "Player-1-0000F001", dated)
    assert(point.status == "captured" and point.capturedTime == dated and point.holdAuthorityLocal == nil,
        "a C dated before our last tick did not end our wave: " .. tostring(point.status))
    Overlord.GuildLane = nil
end

-- 2.1.1: every client keeps the latest date. The followed player finishing seconds after another
-- player of the same side has a later date to tell, although that other final closed the timer
-- followed here; a repeat or an earlier copy still moves nothing.
do
    local point = zoneOf("highperch")
    point.owner, point.status, point.capturedTime, point.updatedAt = nil, "locked", nil, 0
    point._remoteCaptureLease = nil
    advance(600)
    progress("highperch", "A", "Ally Foxtrot", "wF1", "Player-1-0000F00A", 5)
    assert(point.status == "in_progress" and point._remoteCaptureLease, "fixture: the allied wave is not followed")
    advance(100)
    local firstAt = wall
    finalC("highperch", "Alliance", "Ally Golf", "wF2", "Player-1-0000F00B")
    assert(point.owner == "Alliance" and point.capturedTime == firstAt and not point._remoteCaptureLease,
        "fixture: the other final was not taken")
    advance(2)
    local laterAt = wall
    finalC("highperch", "Alliance", "Ally Foxtrot", "wF1", "Player-1-0000F00A", laterAt)
    assert(point.capturedTime == laterAt, "the later date of the followed player was refused: " .. tostring(point.capturedTime - firstAt))
    advance(1)
    finalC("highperch", "Alliance", "Ally Foxtrot", "wF1", "Player-1-0000F00A", firstAt - 5)
    assert(point.capturedTime == laterAt, "an earlier copy moved the date")
    -- As a state final too.
    local other = zoneOf("newstead")
    other.owner, other.status, other.capturedTime, other.updatedAt = nil, "locked", nil, 0
    other._remoteCaptureLease = nil
    advance(60)
    progress("newstead", "A", "Ally Hotel", "wF3", "Player-1-0000F00C", 5)
    assert(other.status == "in_progress" and other._remoteCaptureLease, "fixture: the second allied wave is not followed")
    advance(100)
    firstAt = wall
    finalZS("newstead", "A", "Ally India", "wF4", "Player-1-0000F00D", firstAt)
    assert(other.capturedTime == firstAt and not other._remoteCaptureLease, "fixture: the other state final was not taken")
    advance(2)
    laterAt = wall
    finalZS("newstead", "A", "Ally Hotel", "wF3", "Player-1-0000F00C", laterAt)
    assert(other.capturedTime == laterAt, "the later state final of the followed player was refused")
end
-- 2.1.1: told in the guild, a capture has no ticks. What they would have proved before it counts
-- for its author is then the time between its start and its final, both said by that author.
do
    function GetChannelName() return 5 end
    function securecall(fn, ...) return fn(...) end
    C_Club = C_Club or { GetSubscribedClubs = function() return {} end }
    Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
    C_Timer.NewTicker = C_Timer.NewTicker or function() return {} end
    assert(loadfile("SyncRelay.lua"))()
    assert(loadfile("SyncGuild.lua"))()
    local lane = Overlord.GuildLane
    local fromAuthor = true
    lane.HeardHere = function() return true end
    lane.HeardFromAuthor = function() return fromAuthor end
    local credits = {}
    local realAdd = Overlord.Leaderboard.AddPlayerCapture
    Overlord.Leaderboard.AddPlayerCapture = function(self, name, ...)
        credits[name] = (credits[name] or 0) + 1
        return realAdd(self, name, ...)
    end
    local function start(id, who, wave, guid)
        local point = zoneOf(id)
        point.owner, point.status, point.capturedTime, point.updatedAt = nil, "locked", nil, 0
        point._remoteCaptureLease = nil
        advance(600)
        progress(id, "A", who, wave, guid, 2)
        assert(point.status == "in_progress" and point._remoteCaptureLease, "fixture: the wave is not followed")
        return point
    end
    -- Start and final from their author, long enough apart: it counts at once, once.
    local point = start("highperch", "Ally Kilo", "wK1", "Player-1-0000F00E")
    advance(100)
    finalC("highperch", "Alliance", "Ally Kilo", "wK1", "Player-1-0000F00E")
    assert(point.owner == "Alliance" and credits["Ally Kilo"] == 1, "the capture did not count: " .. tostring(credits["Ally Kilo"]))
    finalZS("highperch", "A", "Ally Kilo", "wK1", "Player-1-0000F00E", point.capturedTime)
    assert(credits["Ally Kilo"] == 1, "its state final counted it again")
    -- The state final alone says as much.
    point = start("newstead", "Ally Lima", "wL1", "Player-1-0000F00F")
    advance(100)
    finalZS("newstead", "A", "Ally Lima", "wL1", "Player-1-0000F00F")
    assert(point.owner == "Alliance" and credits["Ally Lima"] == 1, "the state final did not count")
    -- Too soon after its start: taken, not counted.
    point = start("highperch", "Ally Mike", "wM7", "Player-1-0000F010")
    advance(20)
    finalC("highperch", "Alliance", "Ally Mike", "wM7", "Player-1-0000F010")
    assert(point.owner == "Alliance" and not credits["Ally Mike"], "a capture 20 s after its start counted")
    -- A start somebody else repeated proves nothing.
    fromAuthor = false
    point = start("newstead", "Ally November", "wN1", "Player-1-0000F011")
    fromAuthor = true
    advance(100)
    finalC("newstead", "Alliance", "Ally November", "wN1", "Player-1-0000F011")
    assert(point.owner == "Alliance" and not credits["Ally November"], "a capture counted on a repeated start")
    -- Neither does a final somebody else repeats.
    point = start("highperch", "Ally Oscar", "wO1", "Player-1-0000F012")
    advance(60)
    Overlord.Relay.context = { hops = 1, origin = "Ally Oscar" }
    assert(not sync:CanCreditDirectCapture("Ally Oscar", "Ally Oscar", "highperch", "Alliance"),
        "a repeated final counted")
    Overlord.Relay.context = nil
    -- Nor the wave of somebody else, nor the other side.
    assert(not sync:CanCreditDirectCapture("Ally Papa", "Ally Papa", "highperch", "Alliance"), "another player's wave counted")
    assert(not lane:ProvesWave("Ally Oscar", "highperch", "Horde", 45, 30), "the wave counted for the other side")
    assert(not lane:ProvesWave("Ally Oscar", "not-a-zone", "Alliance", 45, 30), "a site that is no zone")
    assert(sync:CanCreditDirectCapture("Ally Oscar", "Ally Oscar", "highperch", "Alliance"), "the wave itself did not count")
    -- One wave, one capture: not again once the time between two credits has passed, closed or not.
    advance(61)
    assert(point._remoteCaptureLease, "fixture: the wave should still be followed")
    assert(not sync:CanCreditDirectCapture("Ally Oscar", "Ally Oscar", "highperch", "Alliance"), "a wave counted twice")
    Overlord.CaptureLease:Complete(point)
    assert(not sync:CanCreditDirectCapture("Ally Oscar", "Ally Oscar", "highperch", "Alliance"), "a closed wave counted twice")
    assert(lane.closedWaves["highperch"].base == nil, "a closed wave keeps what it proves, not the zone's snapshot")
    -- Somebody else's final closes the wave seconds before its author's own: it still counts for
    -- that author, once, and for nobody else.
    point = start("newstead", "Ally Quebec", "wQ1", "Player-1-0000F013")
    advance(100)
    finalC("newstead", "Alliance", "Ally Romeo", "wR1", "Player-1-0000F014")
    assert(point.owner == "Alliance" and not point._remoteCaptureLease and not credits["Ally Romeo"],
        "fixture: the other final did not close the wave")
    advance(4)
    finalC("newstead", "Alliance", "Ally Quebec", "wQ1", "Player-1-0000F013")
    assert(credits["Ally Quebec"] == 1, "the wave's author lost the capture to the order of the finals")
    assert(not credits["Ally Romeo"], "the other player was credited")
    advance(2)
    finalC("newstead", "Alliance", "Ally Quebec", "wQ1", "Player-1-0000F013")
    assert(credits["Ally Quebec"] == 1, "a later final of the same wave counted again")
    -- As a state final too, and only that long.
    point = start("highperch", "Ally Sierra", "wS1", "Player-1-0000F015")
    advance(100)
    finalC("highperch", "Alliance", "Ally Tango", "wT1", "Player-1-0000F016")
    advance(4)
    finalZS("highperch", "A", "Ally Sierra", "wS1", "Player-1-0000F015")
    assert(credits["Ally Sierra"] == 1, "the state final of the wave's author did not count")
    point = start("newstead", "Ally Uniform", "wU1", "Player-1-0000F017")
    advance(100)
    finalC("newstead", "Alliance", "Ally Victor", "wV1", "Player-1-0000F018")
    advance(lane.CLOSED_WAVE_SEC + 1)
    finalC("newstead", "Alliance", "Ally Uniform", "wU1", "Player-1-0000F017")
    assert(point.owner == "Alliance" and not credits["Ally Uniform"], "a wave closed long ago still proved something")
    -- A wave given up proves nothing: only a completed one is kept.
    point = start("highperch", "Ally Whiskey", "wW1", "Player-1-0000F019")
    advance(100)
    Overlord.CaptureLease:ExpireRemote(point, "timeout")
    assert(not sync:CanCreditDirectCapture("Ally Whiskey", "Ally Whiskey", "highperch", "Alliance"),
        "a wave given up proved a capture")
    Overlord.Leaderboard.AddPlayerCapture = realAdd
    Overlord.GuildLane = nil
end
print("Forever group capture: a point finished by another player than the one followed is taken (C and ZS, "
    .. "own front and others, either faction); retries and older finals change nothing")
