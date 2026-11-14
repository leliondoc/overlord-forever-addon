-- ZoneDefense.lua (2.4.0): captures that wait for each other, and defenders a capturer cannot see.
--
-- 1. Two captures that forbid each other. A capture needs its prerequisites, and a point of ours
--    being captured by the other faction is not ours for that. Each side learns the other's
--    capture seconds late, so both could start, then cancel each other, again and again; and one
--    enemy stepping on a back point cancelled a siege of eight minutes. Now the capture that
--    began first goes on: ours waits, on hold, while the only thing that breaks its chain is a
--    capture that began after it (ChainHeldByYoungerWaves). It is cancelled as before when that
--    capture began first, or once it succeeds. Which one began first is read from the waves' ids
--    (CaptureLease WaveBeganAt: the server's second), the same on both clients.
--
-- 2. Defenders a capturer cannot see. A capture is pushed back by the defenders its capturer sees
--    (enemy nameplates, ZoneControl ScanNearbyPlayers). On Forever the same point exists on
--    several layers: a capturer alone on his layer took a point in two minutes while five
--    defenders stood on it on theirs, nobody able to see or stop him (Ashenvale, 2026-11-10).
--    * Always: a defender standing on a point of his faction that is being captured, with no
--      enemy in sight, is told so in the chat (once per NOTICE_GAP and point). Nothing is sent.
--    * Only with HOLDS_CAPTURES (off: see below): the defenders also say how many they are
--      ("ZD zone:wave:capturer:count:layer", a few of them, once per GAP seconds and wave); it
--      travels like the start of the capture did, back to the other faction, and nobody answers
--      it. The capturer's client counts them as enemies on the point for TTL seconds, never more
--      than his own side (the timer goes back at its plain pace at most), and a capture lost
--      that way is not started again for LOCK seconds.
--
--    HOLDS_CAPTURES is off because nothing proves that the author of a "ZD" stands on the point:
--    across factions only Battle.net friends are named by the game, every other name is written
--    by a relay. Anybody could stall the captures of the other faction from anywhere. Everything
--    else that crosses that way only changes what a map shows. Turning it on is a decision about
--    the game, not about the code.
--
-- Nothing here is sent or read inside an instance. Local only: no saved data.
Overlord = Overlord or {}
Overlord.ZoneDefense = Overlord.ZoneDefense or {}
local Defense = Overlord.ZoneDefense

Defense.HOLDS_CAPTURES = false
-- TTL: how long a report counts for the capturer. GAP: between two reports of one wave.
-- LOCK: no new capture of ours on a point just held against us by unseen defenders.
-- FIRST_WAIT + SPREAD: before the first report. SPEAKERS: how many of the defenders speak, on
-- average, in one round. NOTICE_GAP: between two chat lines about one point. MUTE_SEC: how long
-- the attack alerts of a capturer held back that way stay quiet after the last report (he tries
-- again every LOCK seconds while he stands there). SETTLE: how long a capture stays on hold after
-- the wave in its way ended in silence (its capture may be on its way: the map is asked once).
Defense.TTL, Defense.GAP, Defense.LOCK, Defense.MAX_COUNT = 45, 30, 120, 40
Defense.FIRST_WAIT, Defense.SPREAD, Defense.SPEAKERS = 1.5, 6, 3
Defense.NOTICE_GAP, Defense.MUTE_SEC, Defense.SETTLE = 300, 165, 30
Defense.HANDOVER = 10
Defense.stats = { said = 0, heard = 0, applied = 0, held = 0, frozen = 0, told = 0 }

local held = {}      -- capturer: zone id -> { count, at, seen }
local locks = {}     -- capturer: zone id -> { untilAt, layer }
local said = {}      -- defender: zone id -> { wave, firstAt, dueAt, heardAt }
local muted = {}     -- defending faction: zone id -> { key, untilAt }
local noticeAt = {}  -- "<role>|<zone id>" -> GetTime() of the last chat line

local function layerNow()
    return Overlord.Shard and tonumber(Overlord.Shard.currentShardID) or nil
end

local function zoneOf(zoneId)
    local zones, fronts = Overlord.Zones, Overlord.Fronts
    return (zones and zones.GetZone and zones:GetZone(zoneId))
        or (fronts and fronts.GetZone and (fronts:GetZone(zoneId))) or nil
end

local function noticeDue(role, zone)
    return GetTime() - (noticeAt[role .. "|" .. tostring(zone.id)] or -1e9) >= Defense.NOTICE_GAP
end

local function notice(role, zone, text)
    if not noticeDue(role, zone) then return false end
    noticeAt[role .. "|" .. tostring(zone.id)] = GetTime()
    if Overlord.PrintNotification then Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text) end
    return true
end

-- Is this lease a capture by the other faction of a point our map gives to ours?
local function enemyWaveOverOurs(zone)
    local remote = zone and zone._remoteCaptureLease
    local mine = Overlord.PlayerFaction
    if not remote or zone.holdAuthorityLocal or zone.status ~= "in_progress" or not mine
        or remote.owner == mine or type(remote.base) ~= "table" or remote.base.owner ~= mine then
        return nil
    end
    return remote
end

-- A wave id as CaptureLease writes them or as an older client did: short, no separator of ours.
local function saneWave(wave)
    return type(wave) == "string" and #wave >= 1 and #wave <= 48 and wave:match("^[%w_]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Defenders
-- ---------------------------------------------------------------------------

local function hashFrac(text)
    local net = Overlord.Relay
    return net and net.HashFrac and net.HashFrac(text) or math.random()
end

function Defense:Spread(wave)
    local sync = Overlord.Sync
    local me = sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    return hashFrac(tostring(me):lower() .. "|" .. tostring(wave)) * self.SPREAD
end

-- Once a second for the point the player stands on (ZoneControl:Update).
function Defense:TickDefender(zone)
    if not zone or Overlord.InstanceSuspended then return false end
    local remote = enemyWaveOverOurs(zone)
    if not remote or not remote.waveId or not remote.originName then
        if zone and said[zone.id] and not zone._remoteCaptureLease then said[zone.id] = nil end
        return false
    end
    local control, sync = Overlord.ZoneControl, Overlord.Sync
    if not control or not sync or control:IsPlayerInNonCaptureStateForSync() then return false end
    local now = GetTime()
    local L = Overlord.L or {}
    if not self.HOLDS_CAPTURES then
        -- Told, nothing more: a few seconds after the capture began (its capturer may walk into
        -- sight), and only with no enemy at all in sight (one in sight is fought on the spot).
        if not noticeDue("defender", zone) or now - (tonumber(remote.openedAt) or now) < self.FIRST_WAIT + self.SPREAD then
            return false
        end
        -- "Another layer" is only said when it is known: the capturer's layer, told with his
        -- capture, and ours, both read from the game, differ. An attacker out of nameplate range,
        -- stealthed, or one whose layer nobody told is not said to be elsewhere.
        local theirs, ours = tonumber(zone.zsRelayCapturerShard), layerNow()
        if not theirs or not ours or theirs == ours then return false end
        control:ScanNearbyPlayers(zone)
        local scan = control.GetCachedScan and control:GetCachedScan() or nil
        if scan and (tonumber(scan.visibleEnemy) or 0) > 0 then return false end
        local lease = Overlord.CaptureLease
        if notice("defender", zone, string.format(
            L.DEFENSE_UNSEEN_ATTACKER_INFO or "%s: %s is capturing from another layer, where you cannot see or stop each other. Join their layer to fight for the point.",
            zone.name or zone.id, lease and lease.DisplayName and lease:DisplayName(remote.originName) or "?")) then
            self.stats.told = self.stats.told + 1
        end
        return false
    end
    if not sync.BroadcastToRelay or not saneWave(remote.waveId) then return false end
    local row = said[zone.id]
    if not row or row.wave ~= remote.waveId then
        local first = now + self.FIRST_WAIT + self:Spread(remote.waveId)
        row = { wave = remote.waveId, firstAt = first, dueAt = first }
        said[zone.id] = row
    end
    if now < row.dueAt then return false end
    if row.heardAt and now - row.heardAt < self.GAP then
        row.dueAt = row.heardAt + self.GAP + self:Spread(remote.waveId)
        return false
    end
    local count = math.max(1, math.min(tonumber((control:ScanNearbyPlayers(zone))) or 1, self.MAX_COUNT))
    -- A few of those standing here speak in each round, the same draw for nobody twice: without
    -- the channel most of them do not hear each other in time to keep quiet.
    local round = math.floor((now - row.firstAt) / self.GAP)
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    row.dueAt = row.firstAt + (round + 1) * self.GAP
    if hashFrac(tostring(me):lower() .. "|" .. remote.waveId .. "|" .. round) >= self.SPEAKERS / count then
        return false
    end
    local payload = table.concat({ zone.id, remote.waveId, remote.originName, count, layerNow() or 0 }, ":")
    row.heardAt = now
    sync:BroadcastToRelay("ZD", payload)
    self.stats.said = self.stats.said + 1
    self:Mute(zone, remote)
    -- A capturer in sight is fought on the spot: nothing to explain.
    local scan = control.GetCachedScan and control:GetCachedScan() or nil
    if not scan or (tonumber(scan.visibleEnemy) or 0) == 0 then
        notice("defender", zone, string.format(
            L.DEFENSE_UNSEEN_ATTACKER or "%s: %s is capturing from where you cannot see them (another layer). Your presence still counts: %d defender(s) reported.",
            zone.name or zone.id, Overlord.CaptureLease and Overlord.CaptureLease:DisplayName(remote.originName) or "?", count))
    end
    return true
end

-- Tests and the bench: the same as the constant, and the relay carries "ZD" or not with it.
function Defense:SetHoldsCaptures(on)
    self.HOLDS_CAPTURES = on == true
    local net = Overlord.Relay
    if net and net.CarryZoneDefense then net:CarryZoneDefense(self.HOLDS_CAPTURES) end
end

function Defense:Mute(zone, remote)
    muted[zone.id] = { key = remote.originKey, untilAt = GetTime() + self.MUTE_SEC }
end

-- Sync TryPrintEnemyCapturingAlert: an attacker our defenders hold back unseen tries again every
-- LOCK seconds for as long as he stands there; said once, not every time. Ends MUTE_SEC after the
-- last report: defenders who left no longer hold anything.
function Defense:AlertMuted(zone, capturerName)
    local row = zone and muted[zone.id]
    if not row then return false end
    if GetTime() >= row.untilAt then
        muted[zone.id] = nil
        return false
    end
    local sync = Overlord.Sync
    local key = sync and sync.GetCaptureContributorDedupKey and sync:GetCaptureContributorDedupKey(capturerName) or nil
    return key ~= nil and key == row.key
end

-- ---------------------------------------------------------------------------
-- A report heard ("ZD"): zone:wave:capturer:count:layer
-- ---------------------------------------------------------------------------

function Defense:OnReport(payload, sender)
    if not self.HOLDS_CAPTURES or Overlord.InstanceSuspended or type(payload) ~= "string" then return false end
    local zoneId, wave, capturer, rawCount = strsplit(":", payload)
    local count = tonumber(rawCount)
    if not zoneId or not saneWave(wave) or not capturer or capturer == "" or #capturer > 60
        or not count or count < 1 or count ~= math.floor(count) then return false end
    count = math.min(count, self.MAX_COUNT)
    local zone = zoneOf(zoneId)
    if not zone then return false end
    self.stats.heard = self.stats.heard + 1
    local sync, mine, now = Overlord.Sync, Overlord.PlayerFaction, GetTime()
    -- Our own capture of a point the other faction held when it began. Whatever wave the report
    -- names: several of us may have begun one, and theirs is the one the defenders heard of.
    if zone.holdAuthorityLocal and zone.isHolding and zone.status == "in_progress" and zone.owner == mine
        and zone.previousOwner ~= nil and zone.previousOwner ~= mine
        and sync and sync.IsSenderLocalPlayer and not sync:IsSenderLocalPlayer(sender) then
        -- The defenders of one round (several may speak) count once, by their highest number;
        -- a later round says how many are left.
        local row = held[zone.id]
        if row and now - row.at < self.GAP / 2 then count = math.max(count, row.count) end
        held[zone.id] = { count = count, at = now, seen = row and row.seen or nil }
        self.stats.applied = self.stats.applied + 1
        return true
    end
    -- A capture we follow over a point of ours: somebody of our side holds it.
    local remote = enemyWaveOverOurs(zone)
    if remote and remote.waveId == wave then
        self:Mute(zone, remote)
        local row = said[zone.id]
        if row and row.wave == wave then row.heardAt = now end
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The capturer
-- ---------------------------------------------------------------------------

-- ZoneControl:UpdateHoldTimer, each second on the point: defenders reported on it, counted as
-- enemies. Never more than our own side: unseen, they push the timer back at its plain pace at
-- most (a number nobody can check must not empty a siege in seconds).
function Defense:UnseenDefenders(zone, seen, friends)
    local row = zone and held[zone.id]
    if not row or not self.HOLDS_CAPTURES then return 0 end
    if GetTime() - row.at > self.TTL then
        held[zone.id] = nil
        return 0
    end
    seen = tonumber(seen) or 0
    row.seen = seen
    if row.count > seen and zone.holdAuthorityLocal then
        local L = Overlord.L or {}
        notice("capturer", zone, string.format(
            L.DEFENSE_UNSEEN_DEFENDERS or "%s: %d defender(s) you cannot see hold this point (another layer). Your capture is pushed back while they stay; join their layer to fight them.",
            zone.name or zone.id, row.count))
    end
    return math.min(row.count, math.max(seen, tonumber(friends) or 1, 1))
end

-- Our capture just fell back to nothing (ZoneControl): held by defenders we could not see? Not
-- when we saw as many enemies as were reported: that fight was fought on the spot.
function Defense:NoteWaveFailed(zone)
    local row = zone and held[zone.id]
    if not row or not self.HOLDS_CAPTURES or GetTime() - row.at > self.TTL then return false end
    held[zone.id] = nil
    if row.count <= (tonumber(row.seen) or 0) then return false end
    locks[zone.id] = { untilAt = GetTime() + self.LOCK, layer = layerNow() }
    self.stats.held = self.stats.held + 1
    return true
end

-- Our capture was pushed back to nothing with allies standing on the point (ZoneControl): one of
-- them takes it over on our release; ours is not started again for HANDOVER seconds, long enough
-- to hear his and follow it. A wait already running (unseen defenders) is kept.
function Defense:NoteHandOver(zone)
    if not zone or self:IsLocked(zone) then return false end
    locks[zone.id] = { untilAt = GetTime() + self.HANDOVER, layer = layerNow() }
    return true
end

-- ZoneControl:CheckPlayerPosition: not started again at once. Another layer is another fight.
function Defense:IsLocked(zone)
    local row = zone and locks[zone.id]
    if not row then return false end
    local layer = layerNow()
    if GetTime() >= row.untilAt or (layer ~= nil and row.layer ~= nil and layer ~= row.layer) then
        locks[zone.id] = nil
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Two captures that forbid each other
-- ---------------------------------------------------------------------------

-- When a wave began, on the server's clock: its id says it (the same second on every client,
-- kept through a /reload). An id of an older shape: what this client saw of it.
local function waveBegan(waveId, fallback)
    local lease = Overlord.CaptureLease
    local began = lease and lease.WaveBeganAt and lease:WaveBeganAt(waveId) or nil
    return began or (fallback and math.floor(fallback)) or nil
end

local function ownWaveStart(zone)
    local opened = tonumber(zone._localCaptureOpenedAt)
    local seen = opened and ((Overlord.ServerNow and Overlord.ServerNow() or time()) - (GetTime() - opened)) or nil
    return waveBegan(zone._localCaptureWaveId, seen)
end

-- Is `ours` (a capture begun at ownStart) the first of the two? The same answer on both clients:
-- the earlier second, then the point's name.
local function oursIsFirst(ours, ownStart, theirs, theirStart)
    if ownStart ~= theirStart then return ownStart < theirStart end
    return tostring(ours.id) < tostring(theirs.id)
end

-- The points a capture of `zone` by `faction` needs: its prerequisites, every point for the other
-- faction's capital. nil when the map does not say.
local function chainPoints(zone, faction)
    local zones = Overlord.Zones
    local prereqs = zones and zones.GetPrereqZoneIdsForAttacker and zones:GetPrereqZoneIdsForAttacker(zone.id, faction)
    if not prereqs then return nil end
    local points, known = {}, {}
    for _, id in ipairs(prereqs) do
        local point = zones:GetZone(id)
        if point and not known[point] then points[#points + 1] = point; known[point] = true end
    end
    local capital = Overlord.Fronts and Overlord.Fronts.GetEnemyCapitalId and Overlord.Fronts:GetEnemyCapitalId(faction)
    if zone.id == capital then
        for _, point in ipairs(Overlord.ZoneDatabase or {}) do
            if point ~= zone and not known[point] then points[#points + 1] = point; known[point] = true end
        end
    end
    return points
end

-- Zones:_DoUpdateAvailableZones, for a capture of ours whose chain is broken: true when every
-- point that breaks it is a point of ours under a capture of the other faction that began after
-- ours. Then that capture is the one that should not have started: ours waits for its end.
function Defense:ChainHeldByYoungerWaves(zone)
    local mine = Overlord.PlayerFaction
    if not zone or not mine or not zone.holdAuthorityLocal or zone.owner ~= mine
        or zone.status ~= "in_progress" then return false end
    local ownStart, points = ownWaveStart(zone), chainPoints(zone, mine)
    if not ownStart or not points then return false end
    local blocker
    for _, point in ipairs(points) do
        if not (point.owner == mine and point.status ~= "in_progress") then
            local remote = enemyWaveOverOurs(point)
            local started = remote and waveBegan(remote.waveId, tonumber(remote.startedTs))
            if not started or not oursIsFirst(zone, ownStart, point, started) then return false end
            blocker = blocker or point
        end
    end
    if not blocker then return false end
    return true, blocker
end

-- SyncAux RequestPrereqMismatchCatchup: a capture by `owner` (the other faction) whose chain our
-- map shows broken only by captures of our own faction in progress is one that waits for them (the
-- rule above, on its client): its map misses nothing, there is nothing to ask.
function Defense:ChainBrokenOnlyByOurWaves(zone, owner)
    local mine = Overlord.PlayerFaction
    if not zone or not mine or not owner or owner == mine then return false end
    local points = chainPoints(zone, owner)
    if not points then return false end
    local ours = false
    for _, point in ipairs(points) do
        if not (point.owner == owner and point.status ~= "in_progress") then
            if not (point.status == "in_progress" and point.owner == mine) then return false end
            ours = true
        end
    end
    return ours
end

-- Zones: our capture now waits (true) or not (false). Says it once.
function Defense:SetFrozen(zone, frozen, blocker)
    if not zone then return end
    if not frozen then
        zone._chainFrozen, zone._chainSettleUntil = nil, nil
        return
    end
    -- (Kept per wave: a mark left by an earlier capture of the point is not this one's.)
    local wave = zone._localCaptureWaveId or true
    if zone._chainFrozen ~= wave then
        zone._chainFrozen, zone._chainSettleUntil = wave, nil
        self.stats.frozen = self.stats.frozen + 1
        local L = Overlord.L or {}
        notice("frozen", zone, string.format(
            L.CAPTURE_ON_HOLD or "%s: capture on hold while %s is under attack. It resumes if that attack fails.",
            zone.name or zone.id, blocker and (blocker.name or blocker.id) or "?"))
    end
end

-- Did a wave in the way of this capture just end in silence (no release, no capture heard)?
local function blockerEndedInSilence(zone)
    local now = GetTime()
    for _, point in ipairs(chainPoints(zone, Overlord.PlayerFaction) or {}) do
        if point._remoteLeaseExpiredReason == "timeout" and point._remoteLeaseExpiredOwner ~= Overlord.PlayerFaction
            and now - (tonumber(point._remoteLeaseExpiredAt) or -1e9) < Defense.SETTLE then return true end
    end
    return false
end

-- ZoneControl:UpdateHoldTimer: does our capture still wait? Looked at again every second, so a
-- map change that nobody announced cannot leave it on hold. The second it stops waiting it still
-- waits: the map is looked at first (a chain really lost cancels it there).
function Defense:IsFrozen(zone)
    if not zone or not zone._chainFrozen then return false end
    if zone._chainFrozen ~= (zone._localCaptureWaveId or true) then
        zone._chainFrozen, zone._chainSettleUntil = nil, nil
        return false
    end
    if self:ChainHeldByYoungerWaves(zone) then
        zone._chainSettleUntil = nil
        return true
    end
    -- The wave in the way is gone. In silence: its capture may be on its way (the other faction's
    -- last words cross once): the map is asked, and ours waits SETTLE seconds more.
    local now = GetTime()
    if not zone._chainSettleUntil and blockerEndedInSilence(zone) then
        zone._chainSettleUntil = now + self.SETTLE
        local sync = Overlord.Sync
        if sync and sync.SendSyncRequest then pcall(sync.SendSyncRequest, sync, { criticalChannel = true }) end
    end
    if zone._chainSettleUntil and now < zone._chainSettleUntil then return true end
    zone._chainFrozen, zone._chainSettleUntil = nil, nil
    if Overlord.Zones and Overlord.Zones.UpdateAvailableZones then Overlord.Zones:UpdateAvailableZones() end
    return true
end

-- /ov network and tests.
-- One line of the network report (Commands.lua): what the capture rules of 2.4.0 did since
-- login. After an evening on a busy front it says whether each of them was met in play.
function Defense:GetDiagnostics()
    local s = self.stats
    local lease = Overlord.CaptureLease
    local l = lease and lease.stats or {}
    return string.format("Captures since login: %d put on hold (a point they need attacked after they began), "
        .. "%d of ours given to the first capture of the point (one timer), %d carried on by us after the capturer left, "
        .. "%d of ours carried on by a group mate%s; told %d times of an attacker we cannot see (another layer); "
        .. "unseen defenders %s: %d reports said, %d heard, %d counted, %d captures held back.",
        s.frozen, tonumber(l.yielded) or 0, tonumber(l.relieved) or 0, tonumber(l.handedOn) or 0,
        (lease and lease.RELIEF_ON == false) and " (carrying on switched off)" or "",
        s.told, self.HOLDS_CAPTURES and "counted" or "not counted (switch off)",
        s.said, s.heard, s.applied, s.held)
end

function Defense:_Reset()
    held, locks, said, muted, noticeAt = {}, {}, {}, {}, {}
    for key in pairs(self.stats) do self.stats[key] = 0 end
end

function Defense._Peek()
    return held, locks, said, muted
end

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["ZoneDefense.lua"] = function() return { Defense = Defense, held = held, locks = locks, said = said, muted = muted, noticeAt = noticeAt } end
