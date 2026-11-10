-- 2.4.0: defenders a capturer cannot see, captures that wait for each other, and a capture of the
-- other faction followed by its clock (ZoneDefense.lua, ZoneCaptureLease.lua).
-- Ashenvale, 2026-11-10: five defenders on Dor'danil, a capturer on another layer, a siege of
-- Splintertree cancelled again and again.
local mono, wall = 1000, 1800000000
function GetTime() return mono end
function time() return wall + math.floor(mono) end
function strsplit(sep, value)
    local fields, start = {}, 1
    while true do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1)
        start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return unpack(fields)
end
C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end,
    NewTimer = function() return { Cancel = function() end } end }
C_Map = { GetBestMapForUnit = function() return 1 end, GetPlayerMapPosition = function() return nil end }
function UnitExists() return false end
function UnitIsPlayer() return false end
function UnitFactionGroup() return nil end
function UnitGUID(unit) return unit == "player" and "Player-1-LOCALHERO" or nil end

local printed, sent, refreshes = {}, {}, 0
local blocked, friendly, visibleEnemy = false, 3, 0
local function point(id, owner, extra)
    local z = { id = id, name = id, status = "captured", owner = owner, capturedTime = wall - 500,
        updatedAt = wall - 500, holdTimeElapsed = 0, holdTimeRequired = 120, center = { 50, 50 }, radius = 5 }
    for k, v in pairs(extra or {}) do z[k] = v end
    return z
end
-- Our capital, two back points of ours, the other faction's capital (needs every other point).
local home, back, flank = point("home", "Alliance", { isCapital = true }), point("back", "Alliance"), point("flank", "Alliance")
local capital = point("zcapital", "Horde", { isCapital = true })
local zones = { home = home, back = back, flank = flank, zcapital = capital }
local prereqs = { home = {}, back = { "home" }, flank = { "home" }, zcapital = { "back", "flank" } }

Overlord = { PlayerFaction = "Alliance", L = {}, InActiveFront = true,
    UI = { RequestRefresh = function() end }, Shard = { currentShardID = 7 },
    ZoneDatabase = { home, back, flank, capital } }
function Overlord:PrintNotification(text) printed[#printed + 1] = text end
Overlord.ServerNow = function() return wall + mono end
Overlord.Sync = {
    GetCaptureContributorDedupKey = function(_, name) return type(name) == "string" and name ~= "" and name:lower() or nil end,
    CaptureContributorMatchesSender = function(self, a, b)
        return self:GetCaptureContributorDedupKey(a) == self:GetCaptureContributorDedupKey(b)
    end,
    GetPlayerFullName = function() return "Local Hero" end,
    IsSenderLocalPlayer = function(_, name) return name == "Local Hero" end,
    BroadcastToRelay = function(_, kind, payload) sent[#sent + 1] = kind .. ":" .. payload; return 1 end,
    OnRemoteCaptureLeaseEnded = function() end,
}
Overlord.Zones = {
    GetZone = function(_, id) return zones[id] end,
    GetBaseZoneFixedOwner = function() return nil end,
    GetCurrentPlayerZone = function() return nil end,
    GetMapAspectRatio = function() return 1 end,
    GetPrereqZoneIdsForAttacker = function(_, id) return prereqs[id] end,
    UpdateAvailableZones = function() refreshes = refreshes + 1 end,
}
Overlord.Fronts = {
    Order = { "test" },
    GetFront = function() return { zones = Overlord.ZoneDatabase } end,
    GetZone = function(_, id) return zones[id], { id = "test" } end,
    GetMapID = function() return 1 end,
    GetEnemyCapitalId = function() return "zcapital" end,
}
Overlord.ZoneControl = {
    IsPlayerInNonCaptureStateForSync = function() return blocked end,
    ScanNearbyPlayers = function() return friendly, 0 end,
    GetCachedScan = function() return { visibleEnemy = visibleEnemy } end,
}
dofile("ZoneCaptureLease.lua")
dofile("ZoneDefense.lua")
local Lease, Defense = Overlord.CaptureLease, Overlord.ZoneDefense
assert(Lease and Defense, "the modules did not load")

-- A capture of `zone` by the other faction, as Sync materialises it.
local function enemyWave(zone, capturer, wave, hold, sender)
    local decision = Lease:ValidateProgress(zone.id, "Horde", capturer, wave, wall + mono - 0, hold, 0, 120, 3, sender or capturer)
    assert(decision, "fixture: the capturer's progress was refused")
    assert(Lease:AdoptRemote(zone, "Horde", capturer, decision), "fixture: the lease was not opened")
    zone.status, zone.owner, zone.previousOwner, zone.holdTimeElapsed = "in_progress", "Horde", "Alliance", hold
    return zone._remoteCaptureLease
end
local function restore(zone, owner)
    Lease:ExpireRemote(zone, "release")
    zone._remoteCaptureLease = nil
    zone.status, zone.owner, zone.previousOwner, zone.holdTimeElapsed = "captured", owner, nil, 0
    zone.holdAuthorityLocal, zone.isHolding, zone._localCaptureWaveId, zone._localCaptureOpenedAt = nil, nil, nil, nil
    zone._chainFrozen = nil
end

-- ---------------------------------------------------------------------------
-- A capture of the other faction is followed by its clock
-- ---------------------------------------------------------------------------
do
    local lease = enemyWave(back, "Hugo Sky", "wclock", 5)
    assert(lease.toldLive == true, "a wave heard as it began must count as told live")
    assert(lease.startedTs == wall + 1000 - 5, "the wave's start on the server's clock: " .. tostring(lease.startedTs))
    assert(Lease:FollowedByClock(back), "a wave of the other faction is followed by its clock")
    -- Its clock ends at 1000 + 120 - 5 = 1115, and two minutes of overtime.
    mono = 1160
    assert(not Lease:MaybeExpire(back), "160 s of silence ended a wave inside its overtime")
    mono = 1234
    assert(not Lease:MaybeExpire(back), "ended before its clock and two minutes")
    mono = 1236
    assert(Lease:MaybeExpire(back), "past its clock and two minutes, still followed")
    assert(back.status == "captured" and back.owner == "Alliance", "the point did not go back to its owner")
    -- Told again along the way (a siege): the clock runs from that word.
    mono = 2000
    lease = enemyWave(back, "Hugo Sky", "wbeat", 5)
    mono = 2060
    local later = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", "wbeat", wall + 2060, 20, 0, 120, 3, "Hugo Sky")
    assert(later and Lease:AdoptRemote(back, "Horde", "Hugo Sky", later), "a later word of the same wave was refused")
    -- 2060 + 120 - 20 = 2160, and two minutes: 2280. Silence alone (150 s at 2210) proves nothing.
    mono = 2215
    assert(not Lease:MaybeExpire(back), "150 s after its last word ended a wave whose clock still runs")
    mono = 2281
    assert(Lease:MaybeExpire(back), "a wave told again must still end with its clock")
    -- A wave of our own faction keeps the rule it had (15 s past its clock when never renewed).
    mono = 3000
    local ally = Lease:ValidateProgress(flank.id, "Alliance", "Ally Mate", "wally", wall + 3000, 5, 0, 120, 3, "Ally Mate")
    assert(ally and Lease:AdoptRemote(flank, "Alliance", "Ally Mate", ally), "fixture: ally wave")
    flank.status = "in_progress"
    assert(not Lease:FollowedByClock(flank), "a wave of our own faction is not under the new rule")
    mono = 3000 + 120 - 5 + 16
    assert(Lease:MaybeExpire(flank), "our own faction's wave lost its short grace")
    restore(flank, "Alliance")
    restore(back, "Alliance")
    mono = 4000
end

-- ---------------------------------------------------------------------------
-- Defenders a capturer cannot see: told by default, counted only when switched on
-- ---------------------------------------------------------------------------
local draw, asked = 0, 0
Overlord.Relay = { HashFrac = function() return draw end }
Overlord.Sync.SendSyncRequest = function() asked = asked + 1 end
do
    Defense:_Reset()
    sent, printed = {}, {}
    assert(Defense.HOLDS_CAPTURES == false, "unseen defenders hold captures without anybody having decided so")
    enemyWave(back, "Hugo Sky", "wdef", 3)
    assert(not Defense:TickDefender(back) and #printed == 0, "told before the capturer could walk into sight")
    mono = mono + Defense.FIRST_WAIT + Defense.SPREAD + 0.1
    visibleEnemy = 2
    assert(not Defense:TickDefender(back) and #printed == 0, "a chat line for an attacker in plain sight")
    visibleEnemy = 0
    -- "Another layer" is said only when both layers are known and differ (ours is 7).
    back.zsRelayCapturerShard = nil
    assert(not Defense:TickDefender(back) and #printed == 0, "another layer was said of an attacker whose layer nobody told")
    back.zsRelayCapturerShard = 7
    assert(not Defense:TickDefender(back) and #printed == 0, "another layer was said of an attacker of our own layer, out of sight")
    Overlord.Shard.currentShardID = nil
    back.zsRelayCapturerShard = 9
    assert(not Defense:TickDefender(back) and #printed == 0, "another layer was said without knowing ours")
    Overlord.Shard.currentShardID = 7
    assert(not Defense:TickDefender(back) and #sent == 0, "a report left although unseen defenders hold nothing")
    assert(#printed == 1 and printed[1]:find("Hugo Sky", 1, true) and printed[1]:find("another layer", 1, true),
        "the defender was not told that the capturer is on another layer: " .. tostring(printed[1]))
    mono = mono + 60
    Defense:TickDefender(back)
    assert(#printed == 1 and #sent == 0, "the chat line is said once per point, and nothing is sent")
    assert(not Defense:OnReport("back:wdef:Hugo Sky:4:7", "Ally Mate") and not Defense:AlertMuted(back, "Hugo Sky"),
        "a report was read although unseen defenders hold nothing")
    blocked = true
    Defense:_Reset()
    printed = {}
    assert(not Defense:TickDefender(back) and #printed == 0, "a player who cannot hold a point was told")
    blocked = false
    restore(back, "Alliance")

    -- Switched on: the defenders say how many they are.
    Defense:SetHoldsCaptures(true)
    Defense:_Reset()
    sent, printed = {}, {}
    local lease = enemyWave(back, "Hugo Sky", "wdef2", 3)
    assert(not Defense:TickDefender(back) and #sent == 0, "a report left before its turn")
    mono = mono + Defense.FIRST_WAIT + Defense.SPREAD + 0.1
    assert(Defense:TickDefender(back), "a defender standing on the point said nothing")
    local firstSaid = mono
    assert(#sent == 1 and sent[1] == "ZD:back:wdef2:Hugo Sky:3:7", "the report: " .. tostring(sent[1]))
    assert(#printed == 1 and printed[1]:find("Hugo Sky", 1, true) and printed[1]:find("3", 1, true),
        "the defender was not told that an unseen capturer is held: " .. tostring(printed[1]))
    assert(Defense:AlertMuted(back, "Hugo Sky") and not Defense:AlertMuted(back, "Jack Sky")
        and not Defense:AlertMuted(flank, "Hugo Sky"), "the attack alerts of that capturer on that point go quiet, no other")
    -- One report per GAP, whoever says it.
    mono = firstSaid + 10
    assert(not Defense:TickDefender(back) and #sent == 1, "a second report inside the gap")
    mono = firstSaid + 20
    assert(Defense:OnReport("back:wdef2:Hugo Sky:4:7", "Ally Mate"), "a report of a group mate was not heard")
    mono = firstSaid + Defense.GAP + 1
    assert(not Defense:TickDefender(back) and #sent == 1, "we spoke although a group mate just did")
    mono = firstSaid + 20 + Defense.GAP + 0.1
    assert(Defense:TickDefender(back) and #sent == 2, "the next turn never came")
    assert(#printed == 1, "the chat line is said once, not at every report")
    -- The alerts come back MUTE_SEC after the last report: defenders who left hold nothing.
    mono = mono + Defense.MUTE_SEC - 1
    assert(Defense:AlertMuted(back, "Hugo Sky"), "the alerts came back early")
    mono = mono + 2
    assert(not Defense:AlertMuted(back, "Hugo Sky"), "the alerts of a capturer stayed quiet for good")
    -- Many defenders: a few of them speak in each round, on a draw each makes alone.
    restore(back, "Alliance")
    Defense:_Reset()
    sent, friendly, draw = {}, 500, 0.5
    enemyWave(back, "Hugo Sky", "wmany", 3)
    Defense:TickDefender(back)
    mono = mono + 10
    assert(not Defense:TickDefender(back) and #sent == 0, "every defender of a crowd spoke")
    draw = 0.01
    mono = mono + Defense.GAP
    assert(Defense:TickDefender(back) and sent[1] == "ZD:back:wmany:Hugo Sky:" .. Defense.MAX_COUNT .. ":7",
        "an unbounded count, or nobody of a crowd spoke: " .. tostring(sent[1]))
    friendly, draw = 3, 0
    -- Not able to hold a point (dead, mounted, stealthed, unflagged), or inside an instance: nothing.
    restore(back, "Alliance")
    Defense:_Reset()
    sent, blocked = {}, true
    lease = enemyWave(back, "Hugo Sky", "wdef3", 3)
    Defense:TickDefender(back)
    mono = mono + 10
    assert(not Defense:TickDefender(back) and #sent == 0, "a player who cannot hold a point reported")
    blocked, Overlord.InstanceSuspended = false, true
    assert(not Defense:TickDefender(back) and #sent == 0, "a report left from inside an instance")
    assert(not Defense:OnReport("back:wdef3:Hugo Sky:4:7", "Ally Mate"), "a report was read inside an instance")
    Overlord.InstanceSuspended = nil
    -- Only for a point of ours under a capture of the other faction.
    lease.base.owner = nil
    Defense:TickDefender(back)
    mono = mono + 10
    assert(not Defense:TickDefender(back) and #sent == 0, "a report for a point that was nobody's")
    lease.base.owner = "Alliance"
    restore(back, "Alliance")
    assert(not Defense:TickDefender(back) and #sent == 0, "a report without any capture to hold back")
end

-- ---------------------------------------------------------------------------
-- The capturer counts them (switched on)
-- ---------------------------------------------------------------------------
do
    Defense:_Reset()
    printed = {}
    -- Our own capture of a point the other faction holds.
    local target = capital
    target.status, target.owner, target.previousOwner = "in_progress", "Alliance", "Horde"
    target.isHolding, target.holdAuthorityLocal, target._localCaptureWaveId, target._localCaptureOpenedAt = true, true, "wmine", mono
    assert(Defense:UnseenDefenders(target, 0, 1) == 0, "defenders out of nowhere")
    for _, bad in ipairs({ "zcapital:w bad:Hugo Sky:5:3", "zcapital:wmine:Local Hero:0:3", "zcapital:wmine:Local Hero:x:3",
        "zcapital:wmine:Local Hero:2.5:3", "nowhere:wmine:Local Hero:5:3", "zcapital:wmine", "",
        "zcapital:" .. string.rep("w", 60) .. ":Local Hero:5:3", "zcapital::Local Hero:5:3" }) do
        assert(not Defense:OnReport(bad, "Enemy One"), "a report that is not ours to take was taken: " .. bad)
    end
    assert(not Defense:OnReport("zcapital:wmine:Local Hero:5:3", "Local Hero"), "our own word counted against us")
    assert(Defense:UnseenDefenders(target, 0, 1) == 0, "a refused report was counted")
    -- Whatever wave of ours on this point the defenders heard of (several of us may have begun one).
    assert(Defense:OnReport("zcapital:wother:Ally Mate:5:3", "Enemy One"), "the report of the defenders was refused")
    assert(Defense:UnseenDefenders(target, 1, 8) == 5, "the defenders were not counted")
    assert(#printed == 1 and printed[1]:find("5", 1, true), "the capturer was not told why his capture goes back")
    -- Never more than our own side: a number nobody can check pushes the timer at its plain pace.
    assert(Defense:UnseenDefenders(target, 1, 2) == 2 and Defense:UnseenDefenders(target, 0, 0) == 1,
        "unseen defenders counted for more than our own side")
    assert(Defense:UnseenDefenders(target, 6, 2) == 5 and #printed == 1, "nothing to say when we see more than were reported")
    -- Several speakers of one round count once, by the highest number; a later round replaces it.
    Defense:OnReport("zcapital:wmine:Local Hero:2:3", "Enemy Two")
    assert(Defense:UnseenDefenders(target, 0, 8) == 5, "a second speaker of the same round lowered the count")
    mono = mono + Defense.GAP / 2 + 1
    Defense:OnReport("zcapital:wmine:Local Hero:2:3", "Enemy Two")
    assert(Defense:UnseenDefenders(target, 0, 8) == 2, "defenders who left were still counted at the next round")
    mono = mono + Defense.GAP
    Defense:OnReport("zcapital:wmine:Local Hero:900:3", "Enemy Two")
    assert(Defense:UnseenDefenders(target, 0, 100) == Defense.MAX_COUNT, "the count is bounded on arrival too")
    -- Only while it is fresh.
    mono = mono + Defense.TTL + 1
    assert(Defense:UnseenDefenders(target, 0, 8) == 0, "an old report still counted")
    -- A point that was nobody's when our capture began is nobody's to defend.
    target.previousOwner = nil
    assert(not Defense:OnReport("zcapital:wmine:Local Hero:5:3", "Enemy One"), "defenders of a point that was nobody's")
    target.previousOwner = "Horde"
    -- Held back that way: not started again at once, unless we changed layer.
    assert(not Defense:NoteWaveFailed(target) and not Defense:IsLocked(target), "a capture lost for another reason is not locked")
    Defense:OnReport("zcapital:wmine:Local Hero:5:3", "Enemy One")
    Defense:UnseenDefenders(target, 5, 8)
    assert(not Defense:NoteWaveFailed(target) and not Defense:IsLocked(target),
        "a fight lost against enemies in plain sight locked the point")
    Defense:OnReport("zcapital:wmine:Local Hero:5:3", "Enemy One")
    Defense:UnseenDefenders(target, 0, 8)
    assert(Defense:NoteWaveFailed(target) and Defense:IsLocked(target), "a capture held back by unseen defenders started again at once")
    mono = mono + Defense.LOCK - 1
    assert(Defense:IsLocked(target), "the wait ended early")
    mono = mono + 2
    assert(not Defense:IsLocked(target), "the wait never ends")
    Defense:OnReport("zcapital:wmine:Local Hero:5:3", "Enemy One")
    Defense:UnseenDefenders(target, 0, 8)
    Defense:NoteWaveFailed(target)
    Overlord.Shard.currentShardID = 8
    assert(not Defense:IsLocked(target), "on another layer the fight is another one")
    Overlord.Shard.currentShardID = 7
    -- Switched off: nothing counts.
    Defense:OnReport("zcapital:wmine:Local Hero:5:3", "Enemy One")
    Defense:SetHoldsCaptures(false)
    assert(Defense:UnseenDefenders(target, 0, 8) == 0 and not Defense:NoteWaveFailed(target), "switched off, a report still counted")
    restore(target, "Horde")
end

-- ---------------------------------------------------------------------------
-- Two captures that forbid each other: the first one goes on
-- ---------------------------------------------------------------------------
do
    Defense:_Reset()
    printed, refreshes = {}, 0
    mono = 10000
    local siege = capital
    local function ourSiege(openedAt)
        siege.status, siege.owner, siege.previousOwner = "in_progress", "Alliance", "Horde"
        siege.isHolding, siege.holdAuthorityLocal, siege._localCaptureWaveId, siege._localCaptureOpenedAt = true, true, "wsiege", openedAt
    end
    ourSiege(mono)
    assert(not Defense:ChainHeldByYoungerWaves(siege), "nothing breaks the chain: nothing to wait for")
    -- A back point is being captured by the other faction, 60 s after our siege began.
    mono = 10060
    enemyWave(back, "Hugo Sky", "wyoung", 0)
    local held, blocker = Defense:ChainHeldByYoungerWaves(siege)
    assert(held and blocker == back, "a capture begun after ours cancelled it instead of making it wait")
    Defense:SetFrozen(siege, true, blocker)
    assert(Defense:IsFrozen(siege) and #printed == 1 and printed[1]:find("back", 1, true), "the wait is not said")
    Defense:SetFrozen(siege, true, blocker)
    assert(#printed == 1, "the wait is said once")
    -- The other capture fails: ours goes on, and the map is looked at again.
    restore(back, "Alliance")
    siege.status, siege.owner, siege.previousOwner = "in_progress", "Alliance", "Horde"
    siege.isHolding, siege.holdAuthorityLocal, siege._localCaptureWaveId, siege._localCaptureOpenedAt = true, true, "wsiege", 10000
    siege._chainFrozen = "wsiege"
    refreshes, asked = 0, 0
    assert(Defense:IsFrozen(siege) and refreshes == 1 and siege._chainFrozen == nil,
        "the second it stops waiting the map must be looked at first")
    assert(not Defense:IsFrozen(siege) and asked == 0, "our capture stayed on hold after the other one failed")
    -- The wave in the way ended in silence (no release, no capture heard): its capture may be on
    -- its way. The map is asked once and ours waits SETTLE seconds more.
    mono = 10070
    enemyWave(back, "Hugo Sky", "wsilent", 0)
    Defense:SetFrozen(siege, true, back)
    assert(Defense:IsFrozen(siege), "fixture: on hold again")
    Lease:ExpireRemote(back, "timeout")
    back.status, back.owner, back.previousOwner = "captured", "Alliance", nil
    asked = 0
    assert(Defense:IsFrozen(siege) and asked == 1, "a silent end took our capture off hold at once, or the map was not asked")
    mono = mono + Defense.SETTLE - 1
    assert(Defense:IsFrozen(siege) and asked == 1, "the wait after a silent end ended early, or the map was asked twice")
    mono = mono + 2
    assert(Defense:IsFrozen(siege) and siege._chainFrozen == nil, "the wait after a silent end never ends")
    assert(not Defense:IsFrozen(siege), "off hold")
    back._remoteLeaseExpiredReason, back._remoteLeaseExpiredAt = nil, nil
    -- Which began first is read from the ids of the waves, the same second on both clients
    -- (not from what each one saw, a second of difference apart).
    do
        local function id(at) return string.format("w%x_1_1", wall + at) end
        siege._localCaptureWaveId, siege._localCaptureOpenedAt = id(10000), 10007.9
        mono = 10100
        local tick = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", id(10001), wall + 10100, 20, 0, 120, 3, "Hugo Sky")
        assert(tick and Lease:AdoptRemote(back, "Horde", "Hugo Sky", tick), "fixture: a wave whose first word came late")
        back.status, back.owner, back.previousOwner = "in_progress", "Horde", "Alliance"
        assert(back._remoteCaptureLease.startedTs == wall + 10080, "fixture: what we saw says it began at 10080")
        assert(Defense:ChainHeldByYoungerWaves(siege), "its id says 10001, ours 10000: ours is first")
        siege._localCaptureWaveId = id(10002)
        assert(not Defense:ChainHeldByYoungerWaves(siege), "its id says 10001, ours 10002: ours is not first")
        restore(back, "Alliance")
        siege.status, siege.owner, siege.previousOwner = "in_progress", "Alliance", "Horde"
        siege.isHolding, siege.holdAuthorityLocal, siege._localCaptureWaveId, siege._localCaptureOpenedAt = true, true, "wsiege", 10000
    end
    -- The other side of the same rule: a capture of the other faction whose chain only our own
    -- captures in progress break is one that waits; our map misses nothing (no catch-up asked).
    do
        local theirs = { id = "theirs", status = "in_progress", owner = "Horde" }
        prereqs.theirs = { "back", "flank" }
        back.owner, flank.owner = "Horde", "Horde"
        assert(not Defense:ChainBrokenOnlyByOurWaves(theirs, "Horde"), "a whole chain is not a broken one")
        back.status, back.owner = "in_progress", "Alliance"
        assert(Defense:ChainBrokenOnlyByOurWaves(theirs, "Horde"), "a chain broken by our own capture in progress")
        flank.owner = "Alliance"
        assert(not Defense:ChainBrokenOnlyByOurWaves(theirs, "Horde"), "a point of ours for good is a real difference between the maps")
        assert(not Defense:ChainBrokenOnlyByOurWaves(theirs, "Alliance"), "only for a capture of the other faction")
        back.status, back.owner, flank.owner, prereqs.theirs = "captured", "Alliance", "Alliance", nil
    end
    -- A capture that began before ours: ours was the one that should not have started.
    mono = 10100
    local decision = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", "wold", wall + 10100, 150, 0, 120, 3, "Hugo Sky")
    assert(decision and Lease:AdoptRemote(back, "Horde", "Hugo Sky", decision), "fixture: older wave")
    back.status, back.owner, back.previousOwner = "in_progress", "Horde", "Alliance"
    assert(back._remoteCaptureLease.startedTs == wall + 10100 - 150, "fixture: start of the older wave")
    assert(not Defense:ChainHeldByYoungerWaves(siege), "a capture older than ours must still cancel ours")
    restore(back, "Alliance")
    -- The same second: the same answer on both clients, by the point's name ("back" comes first).
    ourSiege(10200)
    mono = 10200
    enemyWave(back, "Hugo Sky", "wtie", 0)
    assert(not Defense:ChainHeldByYoungerWaves(siege), "a tie must go to the same capture on both sides")
    restore(back, "Alliance")
    enemyWave(flank, "Hugo Sky", "wtie2", 0)
    flank.id = "zzflank"
    assert(Defense:ChainHeldByYoungerWaves(siege), "a tie must go to the same capture on both sides (the other way)")
    flank.id = "flank"
    restore(flank, "Alliance")
    -- A point really lost breaks the chain for good; so does anything else in the way.
    ourSiege(10200)
    mono = 10300
    enemyWave(back, "Hugo Sky", "wyoung2", 0)
    flank.owner = "Horde"
    assert(not Defense:ChainHeldByYoungerWaves(siege), "a point taken by the other faction is not something to wait for")
    flank.owner = "Alliance"
    assert(Defense:ChainHeldByYoungerWaves(siege), "fixture: only the young wave is in the way")
    -- Only for a capture we hold ourselves.
    siege.holdAuthorityLocal = nil
    assert(not Defense:ChainHeldByYoungerWaves(siege), "a capture we only follow is not ours to hold")
    siege.holdAuthorityLocal = true
    -- A mark left by an earlier capture of the point is not this one's.
    siege._chainFrozen = "wearlier"
    assert(not Defense:IsFrozen(siege) and siege._chainFrozen == nil, "an old mark froze a new capture")
    restore(back, "Alliance")
    restore(siege, "Horde")
end

-- ---------------------------------------------------------------------------
-- One timer per point: of two captures of one faction, the first one is followed
-- ---------------------------------------------------------------------------
do
    Defense:_Reset()
    mono = 20000
    local function wave(at, tail) return string.format("w%x_%x_1", wall + at, tail or 1) end
    -- The id says when the wave began, the same for everybody.
    assert(Lease:WaveBeganAt(wave(20000)) == wall + 20000 and Lease:WaveBeganAt("wlegacy") == nil
        and Lease:WaveBeganAt(nil) == nil, "the start of a wave is read from its id")
    assert(Lease:IsElderWave(wave(20000), "bob", wave(20001), "alice"), "the earlier wave is the elder")
    assert(not Lease:IsElderWave(wave(20001), "alice", wave(20000), "bob"), "the later wave is not")
    assert(Lease:IsElderWave(wave(20000), "alice", wave(20000), "bob")
        and not Lease:IsElderWave(wave(20000), "bob", wave(20000), "alice"), "the same second: by the name of the capturer, one way only")
    assert(not Lease:IsElderWave("wlegacy", "alice", wave(20000), "bob")
        and not Lease:IsElderWave(wave(19000), "alice", "wlegacy", "bob")
        and not Lease:IsElderWave(wave(19000), "alice", wave(20000), "alice"), "an id without a date, or one capturer, decides nothing")

    -- We hold a capture; an ally heard first-hand holds one that began a second before.
    local target = capital
    local function ourWave(at)
        restore(target, "Horde")
        target.status, target.owner, target.previousOwner, target.holdTimeElapsed = "in_progress", "Alliance", "Horde", 12
        target.isHolding, target.holdAuthorityLocal = true, true
        target._localCaptureWaveId, target._localCaptureOpenedAt = wave(at, 2), mono - 12
        target._localCaptureBase = { status = "captured", owner = "Horde", capturedTime = wall - 500, updatedAt = wall - 500,
            holdTimeElapsed = 0, holdTimeRequired = 120 }
    end
    -- (As the game shows it for a group mate standing inside the disc with us.)
    local function allyTick(name, began, hold, tail, away)
        local tick = Lease:ValidateProgress(target.id, "Alliance", name, wave(began, tail), wall + mono, hold, 0, 120, 3, name)
        if tick and not away then tick.physicalPresenceGuid = "Player-1-" .. name:upper() end
        return tick
    end
    ourWave(20001)
    mono = 20013
    local elder = allyTick("Ally Mate", 20000, 13)
    assert(elder, "fixture: the tick of the ally")
    assert(not Lease:YieldToElderWave(target, "Alliance", "Ally Mate", elder, false) and target.holdAuthorityLocal == true,
        "a name written by a relay made us give up our capture")
    -- Nor a capturer who does not stand on the point with us (a guild mate on another layer, a
    -- late copy): our capture runs, his word is no reason to give it up.
    local elsewhere = allyTick("Ally Mate", 20000, 13, nil, true)
    assert(not Lease:YieldToElderWave(target, "Alliance", "Ally Mate", elsewhere, true) and target.holdAuthorityLocal == true,
        "we gave up our capture for a capturer who is not on the point with us")
    -- Nor from a shorter capture of ours (a gold attack spent on it), nor over a Barricade.
    target.holdTimeRequired = 60
    assert(not Lease:YieldToElderWave(target, "Alliance", "Ally Mate", elder, true), "a gold attack was thrown away by yielding")
    target.holdTimeRequired = 120
    target._captureBarrierCommitted = true
    assert(not Lease:YieldToElderWave(target, "Alliance", "Ally Mate", elder, true), "yielded over a Barricade already raised")
    target._captureBarrierCommitted = nil
    assert(Lease:YieldToElderWave(target, "Alliance", "Ally Mate", elder, true), "we kept our own timer next to an elder one")
    assert(target.holdAuthorityLocal == nil and target._localCaptureWaveId == nil and target.isHolding == true
        and target.status == "in_progress" and target.owner == "Alliance", "after yielding we stand on the point as a co-capturer")
    assert(target._remoteCaptureLease and target._remoteCaptureLease.waveId == wave(20000)
        and target.zsOfficialCapturerName == "Ally Mate" and target.holdTimeElapsed == 13, "we do not follow the timer of the elder")
    assert(target._remoteCaptureLease.base.owner == "Horde" and target._remoteCaptureLease.base.status == "captured",
        "the state of the point under the capture was lost")
    assert(Lease._IsTombstoned(target.id, "local hero", wave(20001, 2)), "our own wave is over")
    -- Ours began first: his is the one that yields, on his client.
    ourWave(20000)
    local younger = allyTick("Ally Mate", 20001, 5)
    assert(not Lease:YieldToElderWave(target, "Alliance", "Ally Mate", younger, true) and target.holdAuthorityLocal == true,
        "the first capture gave way to a later one")
    -- The same second: the name decides ("ally mate" comes before "local hero").
    ourWave(20000)
    assert(Lease:YieldToElderWave(target, "Alliance", "Ally Mate", allyTick("Ally Mate", 20000, 12, 7), true), "the same second, by name")
    ourWave(20000)
    assert(not Lease:YieldToElderWave(target, "Alliance", "Zed Mate", allyTick("Zed Mate", 20000, 12), true), "the same second, the other way")
    -- A made-up id: older than the hour, or a timer further on than its age allows.
    ourWave(20001)
    for _, forged in ipairs({ allyTick("Ally Mate", 20000 - 4000, 13), allyTick("Ally Mate", 20000, 60) }) do
        assert(forged and not Lease:YieldToElderWave(target, "Alliance", "Ally Mate", forged, true), "a made-up elder wave was believed")
    end
    -- Never to a capture of the other faction, nor when we only follow one.
    assert(not Lease:YieldToElderWave(target, "Horde", "Hugo Sky", elder, true), "yielded to the other faction")
    target.holdAuthorityLocal = nil
    assert(not Lease:YieldToElderWave(target, "Alliance", "Ally Mate", elder, true), "nothing of ours to yield")
    restore(target, "Horde")

    -- Those who only follow switch to the elder wave too, whichever they heard first; never back.
    mono = 21000
    local first = Lease:ValidateProgress(back.id, "Horde", "Jack Sky", wave(21001), wall + 21002, 1, 0, 120, 3, "Jack Sky")
    assert(first and Lease:AdoptRemote(back, "Horde", "Jack Sky", first), "fixture: the younger wave heard first")
    back.status, back.owner, back.previousOwner = "in_progress", "Horde", "Alliance"
    mono = 21003
    local second = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", wave(21000), wall + 21003, 3, 0, 120, 3, "Hugo Sky")
    -- Only on the capturer's own word: the origin of a relayed word is written by its relay.
    assert(not Lease:AdoptRemote(back, "Horde", "Hugo Sky", second) and back._remoteCaptureLease.originKey == "jack sky",
        "a word through a relay took the place of the capture followed")
    second.firstHand = true
    local adopted, opened = Lease:AdoptRemote(back, "Horde", "Hugo Sky", second)
    assert(adopted and opened and back._remoteCaptureLease.originKey == "hugo sky", "a follower kept the later of two captures")
    back.status, back.owner, back.previousOwner = "in_progress", "Horde", "Alliance"
    mono = 21006
    local again = Lease:ValidateProgress(back.id, "Horde", "Jack Sky", wave(21001), wall + 21006, 5, 0, 120, 3, "Jack Sky")
    assert(not (again and Lease:AdoptRemote(back, "Horde", "Jack Sky", again)) and back._remoteCaptureLease.originKey == "hugo sky",
        "a follower went back to the later capture")
    -- Its timer goes up between two ticks: said for the display of the co-capturers.
    mono = 21008
    local up = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", wave(21000), wall + 21008, 8, 0, 120, 3, "Hugo Sky")
    assert(Lease:AdoptRemote(back, "Horde", "Hugo Sky", up) and back._remoteCaptureLease.rising == true, "a rising timer is not marked")
    mono = 21013
    local down = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", wave(21000), wall + 21013, 4, 0, 120, 3, "Hugo Sky")
    assert(Lease:AdoptRemote(back, "Horde", "Hugo Sky", down) and back._remoteCaptureLease.rising == false, "a falling timer is marked rising")
    assert(back._remoteCaptureLease.retold == nil, "words of its first 45 s are not a siege told again")
    -- An older word of the elder wave never takes the lease (a late copy of a wave that ended).
    restore(back, "Alliance")
    mono = 21100
    local live = Lease:ValidateProgress(back.id, "Horde", "Jack Sky", wave(21091), wall + 21100, 9, 0, 120, 3, "Jack Sky")
    assert(live and Lease:AdoptRemote(back, "Horde", "Jack Sky", live), "fixture: the wave that runs")
    back.status, back.owner, back.previousOwner = "in_progress", "Horde", "Alliance"
    local stale = Lease:ValidateProgress(back.id, "Horde", "Kurt Sky", wave(21050), wall + 21090, 40, 0, 120, 3, "Kurt Sky")
    assert(not (stale and Lease:AdoptRemote(back, "Horde", "Kurt Sky", stale)) and back._remoteCaptureLease.originKey == "jack sky",
        "an older word of an elder wave took the lease of the wave that runs")
    -- A made-up id (older than the hour, or a timer further on than its age allows) takes
    -- nobody's place: an id is written by its sender.
    mono = 21101
    local tooOld = Lease:ValidateProgress(back.id, "Horde", "Kurt Sky", wave(21100 - 4000), wall + 21101, 5, 0, 120, 3, "Kurt Sky")
    local tooFar = Lease:ValidateProgress(back.id, "Horde", "Kurt Sky", wave(21080), wall + 21101, 60, 0, 120, 3, "Kurt Sky")
    assert(tooOld and tooFar, "fixture: the made-up waves")
    tooOld.firstHand, tooFar.firstHand = true, true
    assert(not Lease:AdoptRemote(back, "Horde", "Kurt Sky", tooOld) and back._remoteCaptureLease.originKey == "jack sky",
        "a wave older than the hour took the place of the capture followed")
    assert(not Lease:AdoptRemote(back, "Horde", "Kurt Sky", tooFar) and back._remoteCaptureLease.originKey == "jack sky",
        "a wave further on than its age allows took the place of the capture followed")
    -- The release of an elder wave ends the one we follow only when both began in the same
    -- instant and ours was never heard again (it gave way in silence). A wave that ticks, a
    -- takeover, a capture begun later are alive.
    assert(Lease:ReceiveRelease(back.id .. ":" .. wave(21050) .. ":Kurt Sky", "Kurt Sky") and back._remoteCaptureLease ~= nil,
        "the release of a wave begun long before ended a capture that runs")
    assert(Lease:ReceiveRelease(back.id .. ":" .. wave(21090) .. ":Ivan Sky", "Ivan Sky") and back._remoteCaptureLease == nil,
        "the release of the elder of two waves begun together left the other one on the map")
    back.status, back.owner, back.previousOwner = "captured", "Alliance", nil
    mono = 21200
    live = Lease:ValidateProgress(back.id, "Horde", "Jack Sky", wave(21191), wall + 21200, 9, 0, 120, 3, "Jack Sky")
    assert(live and Lease:AdoptRemote(back, "Horde", "Jack Sky", live), "fixture: a wave that runs")
    back.status, back.owner, back.previousOwner = "in_progress", "Horde", "Alliance"
    mono = 21205
    local tick = Lease:ValidateProgress(back.id, "Horde", "Jack Sky", wave(21191), wall + 21205, 14, 0, 120, 3, "Jack Sky")
    assert(Lease:AdoptRemote(back, "Horde", "Jack Sky", tick), "fixture: heard again")
    assert(Lease:ReceiveRelease(back.id .. ":" .. wave(21190) .. ":Ivan Sky", "Ivan Sky") and back._remoteCaptureLease ~= nil,
        "a wave heard again since its start was ended by the release of another one")
    restore(back, "Alliance")
    -- A siege told again while it runs (a word of its later time), then silent, ends before its
    -- eight minutes; its first words alone never start that count.
    mono = 22000
    local siegeTick = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", wave(22000), wall + 22000, 5, 0, 120, 3, "Hugo Sky")
    assert(siegeTick and Lease:AdoptRemote(back, "Horde", "Hugo Sky", siegeTick), "fixture")
    back.status, back.owner, back.previousOwner = "in_progress", "Horde", "Alliance"
    mono = 22060
    local later = Lease:ValidateProgress(back.id, "Horde", "Hugo Sky", wave(22000), wall + 22060, 65, 0, 120, 3, "Hugo Sky")
    assert(Lease:AdoptRemote(back, "Horde", "Hugo Sky", later) and back._remoteCaptureLease.retold == true, "a word of its later time")
    restore(back, "Alliance")

    -- A capture pushed back to nothing with allies on the point: left to one of them for a moment.
    assert(Defense:NoteHandOver(capital) and Defense:IsLocked(capital), "our capture started again in the same second")
    mono = mono + Defense.HANDOVER + 1
    assert(not Defense:IsLocked(capital), "the hand-over wait never ends")
end

-- ---------------------------------------------------------------------------
-- Relief: a player standing on the point carries the capture on when its capturer gives way
-- ---------------------------------------------------------------------------
do
    Defense:_Reset()
    mono = 30000
    local target = capital
    -- A point that is no capital (a Barricade told by ticks is read there).
    local outpost = point("zoutpost", "Horde")
    zones.zoutpost, prereqs.zoutpost = outpost, {}
    local function wave(at, tail) return string.format("w%x_%x_1", wall + at, tail or 1) end
    local function reliefWave(at, tail) return string.format("w%x_%x_1r", wall + at, tail or 1) end

    -- A relief says so in its id, and when its capturer began to stand on the point.
    local plain, dated = Lease:NewWaveId(), Lease:NewWaveId(wall + mono - 40)
    assert(not Lease:IsReliefWave(plain) and Lease:WaveBeganAt(plain) == wall + mono, "a capture's id changed")
    assert(Lease:IsReliefWave(dated) and Lease:WaveBeganAt(dated) == wall + mono - 40, "a relief does not say when it began: " .. dated)
    assert(Lease:WaveBeganAt(Lease:NewWaveId(wall + mono + 50)) == wall + mono
        and Lease:WaveBeganAt(Lease:NewWaveId(wall + mono - 4000)) == wall + mono, "a relief dated from the future, or from before the hour")
    assert(not Lease:IsElderWave(wave(29990), "zed", dated, "abel") and Lease:IsElderWave(dated, "abel", wave(29990), "zed")
        and Lease:IsElderWave(dated, "abel", wave(30001), "zed"), "a relief has no place among the captures of a point")
    assert(not Lease:IsReliefWave("wlegacy") and not Lease:IsReliefWave(nil) and not Lease:IsReliefWave("wr"), "anything is a relief")

    -- The members of our raid as the game shows them: on the disc, off it, or without a position.
    local members, here = {}, true
    local kept = { UnitExists, UnitIsPlayer, UnitFactionGroup, UnitGUID, C_Map.GetPlayerMapPosition, Overlord.Zones.GetCurrentPlayerZone }
    local function member(unit)
        local index = type(unit) == "string" and tonumber(unit:match("^raid(%d+)$"))
        return index and members[index] or nil
    end
    local function place(index, name, at, flags)
        members[index] = name and { name = name, at = at, dead = flags and flags.dead, offline = flags and flags.offline } or nil
    end
    UnitExists = function(unit) return member(unit) ~= nil end
    UnitIsPlayer = UnitExists
    UnitFactionGroup = function(unit) return member(unit) and "Alliance" or nil end
    UnitGUID = function(unit)
        if unit == "player" then return "Player-1-LOCALHERO" end
        local m = member(unit)
        return m and ("Player-1-" .. (m.name:upper():gsub(" ", ""))) or nil
    end
    GetUnitName = function(unit) local m = member(unit); return m and m.name or nil end
    UnitIsDead = function(unit) local m = member(unit); return m ~= nil and m.dead == true end
    UnitIsConnected = function(unit) local m = member(unit); return not (m and m.offline) end
    IsInRaid = function() return true end
    C_Map.GetPlayerMapPosition = function(_, unit)
        local m = member(unit)
        if m and m.at == "on" then return { GetXY = function() return 0.5, 0.5 end } end
        if m and m.at == "off" then return { GetXY = function() return 0.9, 0.9 end } end
    end
    local standOn = target
    Overlord.Zones.GetCurrentPlayerZone = function() return here and standOn or nil end

    -- A word of an ally's capture of a point, as Sync applies it.
    local function followOn(zone, name, id, hold, required)
        local tick = Lease:ValidateProgress(zone.id, "Alliance", name, id, wall + mono, hold, 0, required or 120, 3, name)
        -- (Words of the group: the capturer's own.)
        if tick then tick.firstHand = true end
        if not tick or not Lease:AdoptRemote(zone, "Alliance", name, tick) then return nil end
        zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
        zone.holdTimeElapsed, zone.isHolding = hold, true
        return zone._remoteCaptureLease
    end
    local function follow(name, id, hold) return followOn(target, name, id, hold) end
    local function stand(from, to) for at = from, to do mono = at; Lease:NoteStanding(target) end end
    local function fresh()
        restore(target, "Horde")
        target._standSince, target._standSeenAt, target._reliefSince = nil, nil, nil
    end

    -- The time stood on the point: counted second by second, lost with a break.
    fresh()
    assert(Lease:StandingSeconds(target) == nil, "stood before standing")
    stand(30000, 30010)
    assert(Lease:StandingSeconds(target) == 10, "ten seconds stood: " .. tostring(Lease:StandingSeconds(target)))
    mono = 30014
    assert(Lease:StandingSeconds(target) == nil, "a break of four seconds is still standing")
    stand(30014, 30016)
    assert(Lease:StandingSeconds(target) == 2, "the time stood before a break was kept")

    -- When does a capturer give way? He is a member of our group and says he is off the point.
    fresh()
    local A = wave(30100)
    place(1, "Ally Mate", "on")
    mono = 30110
    assert(follow("Ally Mate", A, 10), "fixture: the ally's capture")
    Lease:NoteFirstHand(target)
    assert(not Lease:ShouldRelieve(target), "one word of a capture is no reason to take it")
    mono = 30115; follow("Ally Mate", A, 15); Lease:NoteFirstHand(target)
    assert(not Lease:ShouldRelieve(target), "a capture that runs was taken over")
    place(1, "Ally Mate", "off")
    mono = 30120; follow("Ally Mate", A, 18); Lease:NoteFirstHand(target, true)
    local lease = target._remoteCaptureLease
    assert(lease.away == true and Lease:ShouldRelieve(target), "a capturer gone from the point keeps a capture nobody carries")
    -- A copy of that same state (a witness whisper, his answer to a map request) is no news:
    -- it neither counts as a tick nor takes back what he said.
    local ticks = lease.firstHandTicks
    Lease:NoteFirstHand(target)
    assert(lease.firstHandTicks == ticks and lease.away == true, "a copy of a state counted as a tick, or cleared what it said")
    -- He says so, but the game shows him standing on the disc (his position, on any layer).
    place(1, "Ally Mate", "on")
    assert(not Lease:ShouldRelieve(target), "a capturer whom the game shows on the point was relieved")
    -- No position to judge by (another map): his word is enough.
    place(1, "Ally Mate", nil)
    assert(Lease:ShouldRelieve(target), "a capturer who says he left, without a position, keeps his capture")
    -- Dead on the disc.
    place(1, "Ally Mate", "on", { dead = true })
    assert(Lease:ShouldRelieve(target), "a dead capturer keeps a capture nobody carries")
    -- Not a member of our group: never, whatever he says and however long his silence.
    place(1, nil)
    assert(not Lease:ShouldRelieve(target), "the capture of a player outside our group was taken over")
    place(1, "Ally Mate", "off")
    -- His last word came through a relay: nothing is decided on it.
    mono = 30127; follow("Ally Mate", A, 17)
    assert(not Lease:ShouldRelieve(target), "a relayed word decided a relief")
    -- His timer goes down by his own ticks and he does not say he left: enemies push him back
    -- where he stands. A contest, not an absence, even if we cannot see him (another layer).
    mono = 30130; follow("Ally Mate", A, 14); Lease:NoteFirstHand(target)
    assert(lease.rising == false and lease.lastHold == 14 and lease.away == nil and not Lease:ShouldRelieve(target),
        "a capturer pushed back by enemies was relieved (a contest dodged)")
    -- Silence of a capturer whose ticks came: only when the game itself shows him gone.
    mono = 30135; follow("Ally Mate", A, 20); Lease:NoteFirstHand(target)
    assert(not Lease:ShouldRelieve(target), "fixture: it runs again")
    mono = 30135 + Lease.RELIEF_SILENCE - 1
    assert(not Lease:ShouldRelieve(target), "a tick or two late is silence")
    mono = 30135 + Lease.RELIEF_SILENCE + 1
    assert(Lease:ShouldRelieve(target), "a capturer gone silent and standing off the point keeps his capture")
    place(1, "Ally Mate", "on")
    assert(not Lease:ShouldRelieve(target), "a silent capturer standing on the point (out of sight, or his ticks late) was relieved")
    place(1, "Ally Mate", nil)
    assert(not Lease:ShouldRelieve(target), "a silent capturer without a position was relieved on no evidence")
    place(1, "Ally Mate", nil, { offline = true })
    assert(Lease:ShouldRelieve(target), "a disconnected capturer keeps a capture nobody carries")
    place(1, "Ally Mate", "off")
    -- Never over a Barricade we validated.
    lease.barrierCommitted = true
    assert(not Lease:ShouldRelieve(target), "a relief would shed a Barricade")
    lease.barrierCommitted = nil
    assert(Lease:ShouldRelieve(target), "fixture: relievable again")
    -- Nor over one only his ticks tell of (we did not see the defender raise it).
    standOn = outpost
    mono = 30180
    assert(followOn(outpost, "Ally Mate", wave(30170), 10, 180), "fixture: a capture under a Barricade")
    Lease:NoteFirstHand(outpost)
    mono = 30185; followOn(outpost, "Ally Mate", wave(30170), 15, 180); Lease:NoteFirstHand(outpost, true)
    assert(outpost._remoteCaptureLease.toldRequired == 180 and outpost._remoteCaptureLease.away == true,
        "fixture: the ticks tell the longer hold: " .. tostring(outpost._remoteCaptureLease.toldRequired))
    assert(not Lease:ShouldRelieve(outpost), "a relief would shed a Barricade its capturer's ticks told of")
    outpost._standSince, outpost._standSeenAt = mono - 30, mono
    assert(not Lease:TakeOverStanding(outpost), "a capture under a told Barricade was taken over")
    Lease:ExpireRemote(outpost, "release")
    outpost._remoteCaptureLease, outpost.status, outpost.owner, outpost.isHolding = nil, "captured", "Horde", nil
    standOn = target
    -- Never a capture of the other faction.
    mono = 30200
    enemyWave(back, "Hugo Sky", wave(30200), 5)
    Lease:NoteFirstHand(back, true)
    mono = 30201
    assert(not Lease:ShouldRelieve(back), "the other faction's capture was to be relieved")
    restore(back, "Alliance")

    -- Whose turn: members of the group standing on the point go by name, a step apart.
    place(2, "Abel One", "on"); place(3, "Zed Last", "on")
    mono = 30210
    assert(Lease:StandingRank(target) == 1, "rank among those standing: " .. Lease:StandingRank(target))
    target._standSince, target._standSeenAt, target._reliefSince = nil, nil, nil
    assert(Lease:ShouldRelieve(target) and not Lease:ReliefDue(target), "a relief by a player who does not stand on the point")
    -- (We stood through the capture: our own time covers what the timer shows.)
    target._standSince, target._standSeenAt = 30100, 30209
    stand(30210, 30210)
    assert(not Lease:ReliefDue(target), "the second in line went first")
    stand(30211, 30211)
    assert(not Lease:ReliefDue(target), "the second in line went within the step")
    stand(30212, 30212)
    assert(Lease:ReliefDue(target), "the second in line never goes")
    place(2, nil); place(3, nil)
    target._reliefSince = nil
    stand(30213, 30215)
    assert(Lease:StandingRank(target) == 0 and Lease:ReliefDue(target), "the first in line waits")
    -- Came late, or came back (stood for less time than the timer shows): taking the capture
    -- over would set it back. After the whole line, whatever the name; still, in the end.
    target._standSince, target._standSeenAt, target._reliefSince = nil, nil, nil
    stand(30216, 30216)
    assert(not Lease:ReliefDue(target), "a late comer set the capture back at once")
    stand(30217, 30223)
    assert(not Lease:ReliefDue(target), "a late comer went before those who stood through the capture could")
    stand(30224, 30224)
    assert(Lease:ReliefDue(target), "a late comer never carries on a capture nobody else does")

    -- The relief itself: from what the timer showed, never from more than the time we stood.
    fresh()
    A = wave(30300)
    mono = 30310; follow("Ally Mate", A, 10); Lease:NoteFirstHand(target)
    assert(not Lease:TakeOverStanding(target), "a relief without standing on the point")
    stand(30318, 30330)
    mono = 30330; follow("Ally Mate", A, 30); Lease:NoteFirstHand(target, true)
    local lastTs = target._remoteCaptureLease.lastRemoteTs
    target._remoteCaptureLease.barrierCommitted = true
    assert(not Lease:TakeOverStanding(target), "a relief over a Barricade")
    target._remoteCaptureLease.barrierCommitted = nil
    local took, hold, previous = Lease:TakeOverStanding(target)
    assert(took and hold == 12 and previous == "Ally Mate", "stood 12 s under a timer at 30: " .. tostring(hold))
    assert(target.holdAuthorityLocal == true and target.isHolding == true and target._remoteCaptureLease == nil
        and target.holdTimeElapsed == 12 and target.holdTimeRequired == 120 and target.status == "in_progress"
        and target.owner == "Alliance" and target.zsOfficialCapturerName == "Local Hero", "the relief is not our capture")
    assert(Lease:IsReliefWave(target._localCaptureWaveId) and Lease:WaveBeganAt(target._localCaptureWaveId) == wall + 30318,
        "the relief is not dated from when we began to stand: " .. tostring(target._localCaptureWaveId))
    assert(Lease._IsTombstoned(target.id, "ally mate", A, lastTs), "a late copy of the relieved capture would take the point back")
    -- Stood longer than the timer showed: nothing is added to it.
    fresh()
    A = wave(30400)
    stand(30380, 30410)
    mono = 30410; follow("Ally Mate", A, 10); Lease:NoteFirstHand(target)
    stand(30411, 30420)
    mono = 30420; follow("Ally Mate", A, 20); Lease:NoteFirstHand(target, true)
    took, hold = Lease:TakeOverStanding(target)
    assert(took and hold == 20 and target.holdTimeElapsed == 20, "a relief went further than the capture it relieves: " .. tostring(hold))

    -- A capture of ours given up to an elder one: the time we stood is what it earned, not its
    -- age (pushed back for a while, its timer says less).
    fresh()
    mono = 30500
    target.status, target.owner, target.previousOwner, target.holdTimeElapsed = "in_progress", "Alliance", "Horde", 12
    target.isHolding, target.holdAuthorityLocal = true, true
    target._localCaptureWaveId, target._localCaptureOpenedAt = wave(30460, 2), mono - 40
    target._localCaptureBase = { status = "captured", owner = "Horde", capturedTime = wall - 500, updatedAt = wall - 500,
        holdTimeElapsed = 0, holdTimeRequired = 120 }
    local elder = Lease:ValidateProgress(target.id, "Alliance", "Ally Mate", wave(30455), wall + mono, 20, 0, 120, 3, "Ally Mate")
    elder.physicalPresenceGuid = "Player-1-ALLYMATE"
    assert(Lease:YieldToElderWave(target, "Alliance", "Ally Mate", elder, true), "fixture: we give way to the elder capture")
    assert(Lease:StandingSeconds(target) == 12, "a capture 40 s old with 12 s on its timer stood " .. tostring(Lease:StandingSeconds(target)))

    -- Those who watch (members of the group away from the point): told first-hand that the
    -- capturer is away, they follow the capture carried on, from no further than his stood.
    here = false
    fresh()
    A = wave(31000)
    mono = 31010; follow("Ally Mate", A, 10); Lease:NoteFirstHand(target)
    mono = 31015; follow("Ally Mate", A, 15); Lease:NoteFirstHand(target)
    mono = 31020; follow("Ally Mate", A, 12); Lease:NoteFirstHand(target)
    -- (Begun within two seconds of the relieved one, as a mate who stepped on the point with
    -- its capturer: the very case in which a release ends a silent younger capture.)
    local B = wave(31001, 7)
    mono = 31021
    assert(not follow("Other Mate", B, 13) and target._remoteCaptureLease.originKey == "ally mate",
        "a timer going down alone (a contest) let another capture take its place")
    mono = 31022; follow("Ally Mate", A, 11); Lease:NoteFirstHand(target, true)
    mono = 31023
    assert(not follow("Other Mate", B, 60) and target._remoteCaptureLease.originKey == "ally mate",
        "a capture far ahead of the relieved one took its place")
    assert(follow("Other Mate", B, 14) and target._remoteCaptureLease.originKey == "other mate",
        "a capture carried on was not followed")
    mono = 31024
    assert(not follow("Ally Mate", A, 9) and target._remoteCaptureLease.originKey == "other mate",
        "the relieved capture took the point back while the relief runs")
    -- The relief went silent and the relieved capturer ticks again (he came back before he
    -- heard of it, and the relief gave way to him): his capture is followed again.
    mono = 31034
    assert(follow("Ally Mate", A, 19) and target._remoteCaptureLease.originKey == "ally mate",
        "a capturer who came back left us on the timer of a relief nobody holds")
    -- The release of the relieved capture does not end the relief.
    fresh()
    A = wave(31100)
    mono = 31110; follow("Ally Mate", A, 10); Lease:NoteFirstHand(target)
    mono = 31115; follow("Ally Mate", A, 15); Lease:NoteFirstHand(target, true)
    mono = 31116
    assert(follow("Other Mate", wave(31101, 7), 14), "fixture: the relief is followed")
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate") and target._remoteCaptureLease ~= nil
        and target._remoteCaptureLease.originKey == "other mate", "the release of the relieved capture ended the relief")
    -- The relieved capturer is seen back on the point: his capture is followed again at once.
    here = true
    fresh()
    A = wave(31200)
    place(1, "Ally Mate", "on")
    mono = 31210; follow("Ally Mate", A, 10); Lease:NoteFirstHand(target)
    mono = 31215; follow("Ally Mate", A, 15); Lease:NoteFirstHand(target, true)
    mono = 31216
    assert(follow("Other Mate", wave(31201, 7), 14), "fixture: the relief is followed")
    mono = 31219
    assert(follow("Ally Mate", A, 16) and target._remoteCaptureLease.originKey == "ally mate",
        "a capturer seen back on the point did not get his followers back")
    place(1, "Ally Mate", "off")
    here = false

    -- Those who only hold the relieved capture's clock know a relief by its id.
    fresh()
    A = wave(32000)
    mono = 32005; follow("Ally Mate", A, 5)
    mono = 32035
    assert(not follow("Other Mate", wave(32003, 7), 33), "another capture begun later took the clock of the first")
    assert(not follow("Other Mate", reliefWave(32003, 8), 80), "a relief far ahead of the clock it relieves")
    -- Through a relay, a relief dated before the capture it relieves is no relief of it.
    local early = Lease:ValidateProgress(target.id, "Alliance", "Other Mate", reliefWave(31980, 8), wall + mono, 33, 0, 120, 3, "Other Mate")
    assert(early and not Lease:AdoptRemote(target, "Alliance", "Other Mate", early) and target._remoteCaptureLease.originKey == "ally mate",
        "a relief dated before the capture it relieves took its place")
    -- A name from a packet, for a chat line: no colour, link or texture code, no line break, 48 bytes.
    assert(Lease:DisplayName("Hugo Sky|cFFFF0000red|r") == "Hugo Sky" and Lease:DisplayName("A|Hlink|h") == "A"
        and Lease:DisplayName("Two\nLines") == "Two" and Lease:DisplayName(nil) == "?" and Lease:DisplayName("|T1|t") == "?"
        and #Lease:DisplayName(string.rep("x", 300)) == 48 and Lease:DisplayName("\195\137lodie Sky") == "\195\137lodie Sky",
        "a name from a packet reaches the chat with its codes")
    assert(follow("Other Mate", reliefWave(32001, 9), 33) and target._remoteCaptureLease.originKey == "other mate",
        "a relief was not followed by those who hold the clock of the relieved capture")
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate") and target._remoteCaptureLease ~= nil,
        "the release of the relieved capture ended a relief followed by its id")
    -- Of two reliefs heard, the elder is followed, as of any two captures (not the last heard).
    mono = 32037
    assert(not follow("Third Mate", reliefWave(32002, 4), 34) and target._remoteCaptureLease.originKey == "other mate",
        "a younger relief took the place of the one followed")
    assert(follow("First Mate", reliefWave(32000, 4), 34) and target._remoteCaptureLease.originKey == "first mate",
        "the elder of two reliefs was not followed")
    -- A capture that ticks is not replaced because an id says "relief": only when it is silent.
    fresh()
    A = wave(32100)
    mono = 32105; follow("Ally Mate", A, 5)
    mono = 32110; follow("Ally Mate", A, 10)
    mono = 32113
    assert(not follow("Other Mate", reliefWave(32101, 9), 11) and target._remoteCaptureLease.originKey == "ally mate",
        "an id saying relief took the place of a capture that ticks")
    mono = 32120
    assert(follow("Other Mate", reliefWave(32101, 9), 18) and target._remoteCaptureLease.originKey == "other mate",
        "a relief was not followed over a capture gone silent")

    -- The other side: we left the point of our capture, a member of our group standing on it
    -- carries it on.
    local grouped = {}
    Overlord.Sync.SendToGroup = function(_, kind, payload) grouped[#grouped + 1] = kind .. ":" .. payload; return true end
    local function ourCapture(at)
        fresh()
        target.status, target.owner, target.previousOwner, target.holdTimeElapsed = "in_progress", "Alliance", "Horde", 30
        target.isHolding, target.holdAuthorityLocal = true, true
        target._localCaptureWaveId, target._localCaptureOpenedAt = wave(at, 2), mono - 30
        target._localCaptureBase = { status = "captured", owner = "Horde", capturedTime = wall - 500, updatedAt = wall - 500,
            holdTimeElapsed = 0, holdTimeRequired = 120 }
    end
    local function word(name, id, hold)
        return Lease:ValidateProgress(target.id, "Alliance", name, id, wall + mono, hold, 0, 120, 3, name)
    end
    place(4, "Other Mate", "on")
    mono = 33040
    ourCapture(33000)
    local relief = word("Other Mate", reliefWave(33005, 9), 28)
    assert(relief, "fixture: the relief's word")
    assert(not Lease:YieldAwayWave(target, "Alliance", "Other Mate", relief, false) and target.holdAuthorityLocal == true,
        "a name written by a relay made us give up our capture")
    here = true
    assert(not Lease:YieldAwayWave(target, "Alliance", "Other Mate", relief, true), "we gave up a capture we stand on")
    here = false
    target._captureBarrierCommitted = true
    assert(not Lease:YieldAwayWave(target, "Alliance", "Other Mate", relief, true), "gave way over a Barricade")
    target._captureBarrierCommitted = nil
    -- Any other capture of the point is not carrying ours on: one begun before ours, one begun
    -- after it (a guild mate's on another layer), a relief by a player outside our group.
    local older = word("Other Mate", wave(32990, 4), 28)
    assert(older and not Lease:YieldAwayWave(target, "Alliance", "Other Mate", older, true) and target.holdAuthorityLocal == true,
        "a capture begun before ours passed for its relief")
    local younger = word("Other Mate", wave(33020, 4), 15)
    assert(younger and not Lease:YieldAwayWave(target, "Alliance", "Other Mate", younger, true) and target.holdAuthorityLocal == true,
        "we gave up our capture for another one begun while we were off the point")
    local stranger = word("Far Stranger", reliefWave(33005, 3), 28)
    assert(stranger and not Lease:YieldAwayWave(target, "Alliance", "Far Stranger", stranger, true) and target.holdAuthorityLocal == true,
        "we gave up our capture to a relief by a player outside our group")
    local relayed = #sent
    assert(Lease:YieldAwayWave(target, "Alliance", "Other Mate", relief, true), "we kept a capture we left while an ally carries it on")
    assert(target.holdAuthorityLocal == nil and target._localCaptureWaveId == nil and target.isHolding == false
        and target._remoteCaptureLease and target._remoteCaptureLease.originKey == "other mate"
        and target.zsOfficialCapturerName == "Other Mate" and target.status == "in_progress", "we do not follow the relief")
    assert(#grouped == 1 and grouped[1] == "ZR:" .. target.id .. ":" .. wave(33000, 2) .. ":Local Hero" and #sent == relayed,
        "the capture given up is released to the group, and to the group only: " .. tostring(grouped[1]) .. " / " .. (#sent - relayed))
    assert(Lease._IsTombstoned(target.id, "local hero", wave(33000, 2)), "a late copy of our capture given up would come back")
    -- A relief dated before our capture (its capturer stood on the point under the capture
    -- that ours relieved) is one all the same.
    mono = 33140
    ourCapture(33100)
    relief = word("Other Mate", reliefWave(33080, 9), 28)
    assert(relief and Lease:YieldAwayWave(target, "Alliance", "Other Mate", relief, true)
        and target._remoteCaptureLease.originKey == "other mate", "a relief dated before our capture was not followed")

    -- The capturer's own release (he left the front, logged out): the capture goes on from the
    -- time we stood there; without it, from nothing as before.
    here = true
    fresh()
    A = wave(34000)
    mono = 34010; follow("Ally Mate", A, 10)
    target._standSince, target._standSeenAt = 33995, 34009
    stand(34010, 34030)
    mono = 34030; follow("Ally Mate", A, 30)
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate"), "fixture: his release")
    assert(target.holdAuthorityLocal == true and target.holdTimeElapsed == 30 and Lease:IsReliefWave(target._localCaptureWaveId),
        "his release handed the capture over from " .. tostring(target.holdTimeElapsed))
    -- We stood there for less time than his timer shows: not at once (somebody may have stood
    -- through it), then from our own time.
    fresh()
    A = wave(34050)
    mono = 34060; follow("Ally Mate", A, 10)
    stand(34060, 34080)
    mono = 34080; follow("Ally Mate", A, 30)
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate") and target.holdAuthorityLocal ~= true
        and target._remoteCaptureLease and target._remoteCaptureLease.releasedAt, "a late comer took the released capture at once")
    stand(34081, 34085)
    assert(not Lease:ReliefDue(target), "a late comer went before the line")
    -- (Standing on, his own time comes within three seconds of the timer: nothing to lose.)
    stand(34086, 34087)
    assert(Lease:ReliefDue(target), "a late comer never takes a released capture")
    took, hold = Lease:TakeOverStanding(target)
    assert(took and hold == 27, "a late comer carries the capture on from his own time: " .. tostring(hold))
    fresh()
    A = wave(34100)
    mono = 34110; follow("Ally Mate", A, 10)
    mono = 34130; follow("Ally Mate", A, 30)
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate"), "fixture: his release")
    assert(target.holdAuthorityLocal == true and target.holdTimeElapsed == 0 and not Lease:IsReliefWave(target._localCaptureWaveId),
        "a hand-over without the time stood did not start from nothing")

    -- One player at a time: not the first in line, we keep the released capture on screen for
    -- our turn, follow whoever takes it first, and let it go if nobody does.
    fresh()
    place(2, "Abel One", "on")
    A = wave(34200)
    mono = 34210; follow("Ally Mate", A, 10)
    target._standSince, target._standSeenAt = 34200, 34209
    stand(34210, 34230)
    mono = 34230; follow("Ally Mate", A, 30)
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate"), "fixture: his release")
    assert(target.holdAuthorityLocal ~= true and target._remoteCaptureLease and target._remoteCaptureLease.releasedAt == mono
        and target.status == "in_progress", "the second in line took the capture at once")
    assert(Lease:ShouldRelieve(target) and not Lease:ReliefDue(target), "the second in line did not wait his turn")
    -- The first in line is heard: his capture is followed, whatever its id.
    mono = 34231
    assert(follow("Abel One", wave(34212, 5), 20) and target._remoteCaptureLease.originKey == "abel one"
        and target._remoteCaptureLease.releasedAt == nil, "the capture taken by the first in line was not followed")
    -- Nobody is heard: our turn comes.
    fresh()
    A = wave(34300)
    mono = 34310; follow("Ally Mate", A, 10)
    target._standSince, target._standSeenAt = 34300, 34309
    stand(34310, 34330)
    mono = 34330; follow("Ally Mate", A, 30)
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate"), "fixture: his release")
    stand(34331, 34331)
    assert(not Lease:ReliefDue(target), "our turn came at once")
    stand(34332, 34332)
    assert(not Lease:ReliefDue(target), "our turn came within the step")
    stand(34333, 34333)
    assert(Lease:ReliefDue(target), "our turn never comes")
    took, hold = Lease:TakeOverStanding(target)
    assert(took and hold == 30 and Lease:IsReliefWave(target._localCaptureWaveId)
        and Lease._IsTombstoned(target.id, "ally mate", A), "our turn: the capture goes on from " .. tostring(hold))
    -- We left the point before our turn: the released capture does not stay on the map.
    fresh()
    A = wave(34400)
    mono = 34410; follow("Ally Mate", A, 10)
    target._standSince, target._standSeenAt = 34400, 34409
    stand(34410, 34430)
    mono = 34430; follow("Ally Mate", A, 30)
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate") and target._remoteCaptureLease, "fixture: kept for our turn")
    mono = 34445
    assert(not Lease:MaybeExpire(target) and target._remoteCaptureLease, "a capture kept for the last in line was dropped before his turn")
    mono = 34449
    assert(Lease:MaybeExpire(target) and target._remoteCaptureLease == nil, "a released capture nobody took stayed on the map")
    -- Over a Barricade nobody waits: the hand-over starts from nothing at once, as it always
    -- did (waiting, nobody could take it and the timer stayed on a capture nobody held).
    fresh()
    A = wave(34500)
    mono = 34510; follow("Ally Mate", A, 10)
    target._standSince, target._standSeenAt = 34500, 34509
    stand(34510, 34530)
    mono = 34530; follow("Ally Mate", A, 30)
    target._remoteCaptureLease.barrierCommitted = true
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate") and target.holdAuthorityLocal == true
        and target.holdTimeElapsed == 0 and not Lease:IsReliefWave(target._localCaptureWaveId),
        "a capture under a Barricade, released, was kept for a turn nobody can take")
    place(2, nil)

    -- The network report (/ov network) says what these rules did since login.
    local report = Defense:GetDiagnostics()
    assert(Lease.stats.relieved == 5 and Lease.stats.handedOn == 2 and Lease.stats.yielded >= 1,
        "reliefs are not counted: " .. Lease.stats.relieved .. "/" .. Lease.stats.handedOn .. "/" .. Lease.stats.yielded)
    assert(report:find("5 carried on by us after the capturer left", 1, true)
        and report:find("2 of ours carried on by a group mate;", 1, true)
        and report:find(Lease.stats.yielded .. " of ours given to the first capture of the point", 1, true)
        and report:find("not counted (switch off)", 1, true), "the report does not say what the capture rules did: " .. report)

    -- The rule switched off (RELIEF_ON): no time stood is counted, so nothing is carried on,
    -- a hand-over starts from nothing as before, and no capture of ours is given up.
    Lease.RELIEF_ON = false
    fresh()
    A = wave(35000)
    mono = 35010; follow("Ally Mate", A, 10); Lease:NoteFirstHand(target)
    stand(35010, 35030)
    mono = 35030; follow("Ally Mate", A, 30); Lease:NoteFirstHand(target, true)
    assert(Lease:StandingSeconds(target) == nil and not Lease:ReliefDue(target) and not Lease:TakeOverStanding(target),
        "switched off, a capture was carried on")
    mono = 35032
    assert(not follow("Other Mate", reliefWave(35012, 3), 30) and target._remoteCaptureLease.originKey == "ally mate",
        "switched off, a relief was followed")
    assert(Lease:ReceiveRelease(target.id .. ":" .. A .. ":Ally Mate", "Ally Mate") and target.holdAuthorityLocal == true
        and target.holdTimeElapsed == 0 and not Lease:IsReliefWave(target._localCaptureWaveId), "switched off, a hand-over did not start from nothing")
    here = false
    mono = 35140
    ourCapture(35100)
    relief = word("Other Mate", reliefWave(35105, 9), 28)
    assert(relief and not Lease:YieldAwayWave(target, "Alliance", "Other Mate", relief, true) and target.holdAuthorityLocal == true,
        "switched off, we gave up our capture")
    Lease.RELIEF_ON = true

    fresh()
    zones.zoutpost, prereqs.zoutpost = nil, nil
    UnitExists, UnitIsPlayer, UnitFactionGroup, UnitGUID, C_Map.GetPlayerMapPosition, Overlord.Zones.GetCurrentPlayerZone = unpack(kept, 1, 6)
    GetUnitName, IsInRaid, UnitIsDead, UnitIsConnected, Overlord.Sync.SendToGroup = nil, nil, nil, nil, nil
end

-- Every language has the six lines, with their slots.
do
    local files = { "Locales.lua", "GuideLocales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua" }
    local function slots(text) local n = 0 for _ in text:gmatch("%%[sd]") do n = n + 1 end return n end
    for _, loc in ipairs({ "enUS", "frFR", "esES", "deDE", "ruRU", "ptBR", "zhCN" }) do
        local kept = Overlord
        Overlord = { L = {} }
        GetLocale = function() return loc end
        for _, file in ipairs(files) do assert(loadfile(file))() end
        local L = Overlord.L
        assert(type(L.DEFENSE_UNSEEN_ATTACKER) == "string" and slots(L.DEFENSE_UNSEEN_ATTACKER) == 3, loc .. ": DEFENSE_UNSEEN_ATTACKER")
        assert(type(L.DEFENSE_UNSEEN_ATTACKER_INFO) == "string" and slots(L.DEFENSE_UNSEEN_ATTACKER_INFO) == 2
            and string.format(L.DEFENSE_UNSEEN_ATTACKER_INFO, "Z", "N"), loc .. ": DEFENSE_UNSEEN_ATTACKER_INFO")
        assert(type(L.DEFENSE_UNSEEN_DEFENDERS) == "string" and slots(L.DEFENSE_UNSEEN_DEFENDERS) == 2, loc .. ": DEFENSE_UNSEEN_DEFENDERS")
        assert(type(L.CAPTURE_ON_HOLD) == "string" and slots(L.CAPTURE_ON_HOLD) == 2, loc .. ": CAPTURE_ON_HOLD")
        assert(string.format(L.DEFENSE_UNSEEN_ATTACKER, "Z", "N", 3) and string.format(L.DEFENSE_UNSEEN_DEFENDERS, "Z", 3)
            and string.format(L.CAPTURE_ON_HOLD, "Z", "B"), loc .. ": a line does not format")
        assert(type(L.CAPTURE_RELIEVED) == "string" and slots(L.CAPTURE_RELIEVED) == 2 and string.format(L.CAPTURE_RELIEVED, "Z", "N"),
            loc .. ": CAPTURE_RELIEVED")
        assert(type(L.CAPTURE_HANDED_ON) == "string" and slots(L.CAPTURE_HANDED_ON) == 2 and string.format(L.CAPTURE_HANDED_ON, "Z", "N"),
            loc .. ": CAPTURE_HANDED_ON")
        if loc ~= "enUS" then
            local english = { L = {} }
            Overlord, GetLocale = english, function() return "enUS" end
            for _, file in ipairs(files) do assert(loadfile(file))() end
            assert(L.CAPTURE_ON_HOLD ~= english.L.CAPTURE_ON_HOLD
                and L.DEFENSE_UNSEEN_ATTACKER_INFO ~= english.L.DEFENSE_UNSEEN_ATTACKER_INFO
                and L.CAPTURE_RELIEVED ~= english.L.CAPTURE_RELIEVED and L.CAPTURE_HANDED_ON ~= english.L.CAPTURE_HANDED_ON,
                loc .. ": a line is still in English")
        end
        Overlord = kept
    end
end

print("Zone defense: first capture goes on, one timer per point, relief by a player standing on the point, enemy capture followed by its clock, unseen defenders told (counted only when switched on) OK")
