-- 1.7 conquest: after the 15-minute truce nothing returns. The fallen capital stays with
-- its conqueror until its own faction retakes it ("Capital liberated"); a faction can
-- always attack its own capital; a new victory on a front only counts 6 h after the last.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
Overlord.L.FRONT_TRUCE_ENDED_KEPT = "%s truce over, conquest kept"
Overlord.L.FRONT_CAPITAL_LIBERATED = "Liberated %s (%s)"
Overlord.L.FRONT_VICTORY_TOO_SOON = "%s too soon until %s"
Overlord.L.TOTAL_VICTORY_MSG = "%s won a front"
Overlord.L.VICTORY_FACTION_ALLIANCE, Overlord.L.VICTORY_FACTION_HORDE = "Alliance", "Horde"
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local sync, zones = Overlord.Sync, Overlord.Zones
local campaign = Overlord:GetCurrentCampaignStartTs()
local clock = campaign + 200000
time = function() return clock end
GetServerTime = function() return clock end
Overlord.InstanceSuspended = false
Overlord.SaveState = function() end
Overlord.MarkDirty = function() end
local printed = {}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
local broadcasts = {}
local realBroadcastFR = sync.BroadcastFrontTruceEndReset
sync.BroadcastFrontTruceEndReset = function(_, frontId, epoch)
    broadcasts[#broadcasts + 1] = { frontId = frontId, epoch = epoch }
end
-- Domination journal stub: a timestamp, or { timestamp, faction }.
local journal = nil
Overlord.GetLatestDominationVictoryForFront = function()
    if type(journal) == "table" then return journal[1], journal[2] end
    return journal
end

OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RequireCaptureSync("login")
Overlord:RestoreZoneState()
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zone._loginSyncUnconfirmed = nil end
end
local elwynn = Overlord.Fronts:GetFront("elwynn")
local hordeCap = Overlord.Fronts:GetZone(elwynn.hordeCapitalId, "elwynn")
local allianceCap = Overlord.Fronts:GetZone(elwynn.allianceCapitalId, "elwynn")
local branches = {}
for _, zone in ipairs(elwynn.zones) do
    if zone.id ~= hordeCap.id and zone.id ~= allianceCap.id then branches[#branches + 1] = zone end
end
assert(#branches >= 2, "Elwynn needs branch zones")
local function winFront(faction, victoryTs)
    zones:SetVictoryCooldown("elwynn", faction, victoryTs)
    zones:ForceSyncFrontToWinner("elwynn", faction, victoryTs, true)
end

-- 1. Victory, then the truce ends: every zone stays Alliance, the Horde capital included.
local V = clock
winFront("Alliance", V)
clock = V + 901
printed = {}
zones:TryExpireFrontTruces()
local E = V + 900
assert(OverlordDB.frontTruceResetEpoch.elwynn == E, "Truce end not recorded")
assert(OverlordDB.frontVictories.elwynn == nil, "Victory record kept after the truce")
assert(hordeCap.owner == "Alliance" and hordeCap.status ~= "in_progress", "The fallen capital was given back")
assert(hordeCap.capturedTime == E + 1, "Fallen capital not stamped one second after the epoch: "
    .. tostring(hordeCap.capturedTime) .. " vs " .. E)
for _, zone in ipairs(branches) do
    assert(zone.owner == "Alliance" and zone.capturedTime == E, zone.id .. " not kept at the epoch")
end
assert(allianceCap.owner == "Alliance" and allianceCap.capturedTime == E, "Winner's capital not at the epoch")
assert(#broadcasts == 1 and broadcasts[1].epoch == E, "FR not announced once")
assert(#printed == 1 and printed[1]:find("conquest kept", 1, true), "Truce-end line missing")
assert(zones.IsCapitalImmune == nil and zones.GetCapitalProtectionLabel == nil, "Protection API still present")
assert(zones:LocalStateShowsKeptConquest("elwynn", "Alliance", E), "Kept conquest not recognised")
assert(zones:KeptConquestWinnerFromMap("elwynn", E) == "Alliance")
assert(zones:IsKeptCapitalStamp("elwynn", hordeCap), "Kept capital stamp not recognised")
-- A second tick changes nothing.
zones:TryExpireFrontTruces()
assert(#broadcasts == 1 and hordeCap.capturedTime == E + 1)

-- 2. The kept map never yields a new victory, even on a client that knows nothing of it
-- (no truce record, no journal): a kept capital is never a fresh capture.
OverlordDB.frontTruceResetEpoch.elwynn = nil
Overlord.InActiveFront = true
sync:ResetVictoryFlagForFront("elwynn")
sync:CheckTotalVictoryFromSync()
assert(OverlordDB.frontVictories.elwynn == nil, "A late joiner derived a victory from the kept map")
OverlordDB.frontTruceResetEpoch.elwynn = E

-- 3. Victory spacing (rule b): the same victory stays valid, another counts from V + 6 h.
local spacing = zones:GetVictorySpacingSeconds()
assert(spacing == 6 * 3600)
assert(zones:IsFrontVictoryAllowed("elwynn", V), "The same victory must stay valid")
local ok, from = zones:IsFrontVictoryAllowed("elwynn", V + 3 * 3600)
assert(not ok and from == V + spacing, "A victory 3 h later was allowed")
assert(zones:IsFrontVictoryAllowed("elwynn", V + spacing), "A victory 6 h later was refused")
assert(zones:IsFrontVictoryAllowed("arathi", V + 60), "Spacing leaked to another front")
-- The journal alone (truce record lost) keeps the same spacing.
OverlordDB.frontTruceResetEpoch.elwynn = nil
journal = V
assert(not zones:IsFrontVictoryAllowed("elwynn", V + 3600), "The journal does not space victories")
journal = campaign - 100 -- previous week: nothing retained
assert(zones:IsFrontVictoryAllowed("elwynn", V + 3600), "A previous-week victory still spaced this week")
journal = nil
OverlordDB.frontTruceResetEpoch.elwynn = E

-- 4. A faction can always attack its own capital: every front gives each native capital an
-- empty prerequisite list (checked here on all fronts, the Alliance and the Horde).
for frontId, front in pairs(Overlord.Fronts.Registry) do
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local capId = faction == "Alliance" and front.allianceCapitalId or front.hordeCapitalId
        local list = front.prereqs and front.prereqs[faction] and front.prereqs[faction][capId]
        assert(type(list) == "table" and #list == 0, frontId .. ": " .. faction .. " capital needs prerequisites")
    end
end
assert(zones:FactionMeetsPrereqsForZoneCapture(hordeCap.id, "Horde"),
    "The Horde cannot retake its own capital while the Alliance holds everything")
assert(not zones:FactionMeetsPrereqsForZoneCapture(branches[1].id, "Horde")
    or zones:GetPrereqZoneIdsForAttacker(branches[1].id, "Horde"),
    "Prerequisites vanished for ordinary zones")
-- From the Alliance side: our own capital held by the Horde becomes available at once.
allianceCap.owner, allianceCap.status, allianceCap.capturedTime = "Horde", "locked", clock - 30
zones:_DoUpdateAvailableZones(true)
assert(allianceCap.status == "available", "Our captured capital is not available to retake: "
    .. tostring(allianceCap.status))
assert(zones:IsZoneAvailable(allianceCap.id), "IsZoneAvailable refuses our own capital")
allianceCap.owner, allianceCap.status, allianceCap.capturedTime = "Alliance", "captured", E

-- 5. "Capital liberated": once, for everyone, when a faction retakes its capital.
printed = {}
zones:CheckCapitalLiberations() -- learns the current owners, says nothing
assert(#printed == 0, "Liberation line printed without a change")
clock = clock + 600
-- A map entry alone (one ZA, no capture seen live) changes the map but prints nothing:
-- one forged page made every client announce a liberation.
hordeCap.owner, hordeCap.status, hordeCap.capturedTime = "Horde", "captured", clock - 5
zones:CheckCapitalLiberations()
assert(#printed == 0, "A liberation seen only on a ZA map was announced")
hordeCap.owner, hordeCap.capturedTime = "Alliance", E + 1
zones:CheckCapitalLiberations()
-- Seen live (the capture's C/ZS, or this client's own capture): announced.
sync:NoteLiveZoneTraffic(hordeCap.id)
hordeCap.owner, hordeCap.status, hordeCap.capturedTime = "Horde", "captured", clock - 5
zones:CheckCapitalLiberations()
assert(#printed == 1 and printed[1]:find("Liberated", 1, true), "Liberation line missing")
zones:CheckCapitalLiberations()
assert(#printed == 1, "Liberation line repeated")
-- A capital handed back long ago (login, weekly reset) is not a liberation.
hordeCap.owner, hordeCap.capturedTime = "Alliance", clock - 50
zones:CheckCapitalLiberations()
hordeCap.owner, hordeCap.capturedTime = "Horde", campaign
zones:CheckCapitalLiberations()
assert(#printed == 1, "An old hand-back was announced as a liberation")
-- The weekly reset seen live hands a kept capital back at the campaign start: not a liberation.
hordeCap.owner, hordeCap.capturedTime = "Alliance", clock - 50
zones:CheckCapitalLiberations()
local savedClock = clock
clock = campaign + 10
assert(Overlord:GetCurrentCampaignStartTs() == campaign, "Test clock moved the campaign")
hordeCap.owner, hordeCap.capturedTime = "Horde", campaign
zones:CheckCapitalLiberations()
assert(#printed == 1, "The live weekly reset was announced as a liberation")
clock = savedClock

-- 6. The Alliance retakes the Horde capital 1 h after the liberation (V + ~1.3 h): the
-- map changes, but no victory before V + 6 h; after that it is a normal victory.
OverlordDB.frontVictories.elwynn = nil
sync:ResetVictoryFlagForFront("elwynn")
clock = V + 5000
hordeCap.owner, hordeCap.status, hordeCap.capturedTime = "Alliance", "captured", clock - 2
sync:CheckTotalVictoryFromSync()
assert(OverlordDB.frontVictories.elwynn == nil, "A retake within 6 h became a victory")
hordeCap.owner, hordeCap.capturedTime = "Horde", clock
clock = V + spacing + 600
Overlord.UI = Overlord.UI or {}
Overlord.UI.ShowVictoryScreen = function() end
Overlord.UI.RequestRefresh = Overlord.UI.RequestRefresh or function() end
-- The map alone (the capital C, no TV) is not a victory: a too-soon retake looks the same.
hordeCap.owner, hordeCap.status, hordeCap.capturedTime = "Alliance", "captured", clock - 2
sync:CheckTotalVictoryFromSync()
assert(OverlordDB.frontVictories.elwynn == nil, "The map alone made a victory without the capturer's TV")
-- The capturer's TV heard before the capital's C waits for the map, then the map proves it.
hordeCap.owner, hordeCap.capturedTime = "Horde", V + 5000
local realAfterTV = C_Timer.After
C_Timer.After = function() end
sync:OnReceiveTotalVictory("Alliance:" .. (clock - 2) .. ":0:0:elwynn", "Capturer Tester", "CHANNEL")
C_Timer.After = realAfterTV
assert(OverlordDB.frontVictories.elwynn == nil, "A TV without the capital on the map opened a truce")
hordeCap.owner, hordeCap.status, hordeCap.capturedTime = "Alliance", "captured", clock - 2
sync:CheckTotalVictoryFromSync()
assert(OverlordDB.frontVictories.elwynn and OverlordDB.frontVictories.elwynn.timestamp == clock - 2,
    "A retake 6 h later was not a victory")

-- 7. Weekly reset clears the old protection record too.
OverlordDB.frontCapitalImmuneFrom = { elwynn = { from = 1, faction = "Horde" } }
zones:ClearFrontVictories()
assert(OverlordDB.frontCapitalImmuneFrom == nil, "Old protection record survived the weekly reset")
-- 8. A victory from the previous campaign never ends a truce in the new week.
broadcasts = {}
zones:SetVictoryCooldown("elwynn", "Alliance", campaign - 600)
assert(not zones:ApplyFrontTruceEndReset("elwynn", campaign + 300, false),
    "Last week's victory ended a truce in the new campaign")
zones:TryExpireFrontTruces()
assert(#broadcasts == 0, "Last week's victory was broadcast")
zones:ClearFrontVictories()

-- 9. Inside an instance nothing happens, printed or broadcast; it waits for the exit.
printed = {}
local V4 = clock + 100
clock = V4
winFront("Alliance", V4)
clock = V4 + 1000
Overlord.InstanceSuspended = true
zones:TryExpireFrontTruces()
assert(#broadcasts == 0 and #printed == 0 and OverlordDB.frontTruceResetEpoch.elwynn == nil,
    "Truce end ran inside an instance")
Overlord.InstanceSuspended = false
zones:TryExpireFrontTruces()
assert(#broadcasts == 1 and #printed == 1 and hordeCap.owner == "Alliance"
    and hordeCap.capturedTime == V4 + 901, "Truce end did not run after leaving the instance")

-- 10. Login long after the truce: applied silently, no stale chat line, no broadcast.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
local V5 = clock + 100
clock = V5
winFront("Alliance", V5)
clock = V5 + 7200
zones:TryExpireFrontTruces()
assert(OverlordDB.frontTruceResetEpoch.elwynn == V5 + 900 and hordeCap.capturedTime == V5 + 901,
    "Late truce end not applied")
assert(#printed == 0 and #broadcasts == 0, "A late truce end was printed or re-broadcast")

-- Map of a HORDE victory whose truce ended at epoch: all Horde, the Alliance capital kept.
local function hordeKeptMap(epoch)
    for _, zone in ipairs(elwynn.zones) do
        zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Horde", "captured", epoch, epoch
        zone._loginSyncUnconfirmed = nil
    end
    allianceCap.capturedTime, allianceCap.updatedAt = epoch + 1, epoch + 1
end

-- 11. Late joiner learns a HORDE truce end from the network (ZA first, then FR): the
-- winner comes from the victory trace (journal or pruned record) and the map agrees.
for _, mode in ipairs({ "journal", "pruned" }) do
    zones:ClearFrontVictories()
    local HV = clock + 100
    clock = HV + 1000
    local HE = HV + 900
    hordeKeptMap(HE)
    if mode == "journal" then
        journal = { HV, "Horde" }
    else
        journal = nil
        OverlordDB.frontTruceResetEpoch.elwynn = HV
    end
    sync:OnReceiveFrontTruceEndReset("elwynn:" .. HE, "Late Tester", "CHANNEL")
    assert(OverlordDB.frontTruceResetEpoch.elwynn == HE, "Late joiner (" .. mode .. ") ignored a proven FR")
    assert(allianceCap.owner == "Horde" and allianceCap.capturedTime == HE + 1,
        "Late joiner (" .. mode .. ") gave the capital back")
end
journal = nil

-- 12. One SR response sends FR before the VB journal: the FR cannot be proven yet,
-- stays pending, and is replayed once the journal knows the victory (no new packet).
zones:ClearFrontVictories()
local PV = clock + 100
clock = PV + 1500
local PE = PV + 900
hordeKeptMap(PE)
for _, zone in ipairs(branches) do zone.capturedTime, zone.updatedAt = PE + 300, PE + 300 end
sync:OnReceiveFrontTruceEndReset("elwynn:" .. PE, "Late Tester", "CHANNEL")
assert(OverlordDB.frontTruceResetEpoch.elwynn == nil, "FR without proof was applied")
-- A future-dated FR (clock ahead or forged) never evicts the genuine pending one.
sync:OnReceiveFrontTruceEndReset("elwynn:" .. (clock + 200), "Forger Tester", "CHANNEL")
journal = { PV, "Horde" }
sync:RetryPendingTruceReleases()
assert(OverlordDB.frontTruceResetEpoch.elwynn == PE, "Pending FR was not proven once the journal arrived")
journal = nil

-- 13. An FR that never gets its proof stays inert and is forgotten after 6 h.
zones:ClearFrontVictories()
local UE = clock - 100
sync:OnReceiveFrontTruceEndReset("elwynn:" .. UE, "Unproven Tester", "CHANNEL")
sync:RetryPendingTruceReleases()
assert(OverlordDB.frontTruceResetEpoch.elwynn == nil, "Unproven FR was applied")
clock = UE + zones:GetVictorySpacingSeconds() + 10
sync:RetryPendingTruceReleases()
-- The slot itself is gone: back inside the window with full proof, nothing is replayed.
clock = UE + 60
hordeKeptMap(UE)
journal = { UE - 900, "Horde" }
sync:RetryPendingTruceReleases()
assert(not OverlordDB.frontTruceResetEpoch.elwynn, "An expired pending FR was kept and replayed")
journal = nil
clock = UE + zones:GetVictorySpacingSeconds() + 10

-- 14. Hillsbrad follows the same rule now: after the truce the fallen town stays taken.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
local hb = Overlord.Fronts:GetFront("hillsbrad")
local southshore = select(1, Overlord.Fronts:GetZone(hb.allianceCapitalId, "hillsbrad"))
local tarren = select(1, Overlord.Fronts:GetZone(hb.hordeCapitalId, "hillsbrad"))
local HBV = clock + 100
clock = HBV
southshore.owner, southshore.status, southshore.capturedTime, southshore.updatedAt = "Alliance", "captured", HBV - 300, HBV - 300
southshore._loginSyncUnconfirmed, tarren._loginSyncUnconfirmed = nil, nil
zones:SetVictoryCooldown("hillsbrad", "Alliance", HBV)
zones:ForceSyncFrontToWinner("hillsbrad", "Alliance", HBV, true)
clock = HBV + 901
zones:TryExpireFrontTruces()
assert(tarren.owner == "Alliance" and tarren.capturedTime == HBV + 901, "Tarren Mill was given back after the truce")
assert(#broadcasts == 1 and #printed == 1 and printed[1]:find("conquest kept", 1, true),
    "Hillsbrad truce end not announced like the other fronts")

-- 15. Truce-end herd: every client ends the truce at the same second, one announcer is
-- enough. The announce waits 3-25 s and is cancelled once the same FR was heard.
local fired, timersFR = {}, {}
local realAfter = C_Timer.After
C_Timer.After = function(delay, fn) timersFR[#timersFR + 1] = { delay = delay, fn = fn } end
local savedSend = { sync.SendToGroup, sync.SendToChannel, sync.BroadcastToRelay, sync.BroadcastFrontZoneSnapshot }
sync.SendToGroup = function(_, kind) fired[#fired + 1] = "group:" .. kind end
sync.SendToChannel = function(_, kind) fired[#fired + 1] = "channel:" .. kind end
sync.BroadcastToRelay = function(_, kind) fired[#fired + 1] = "relay:" .. kind end
sync.BroadcastFrontZoneSnapshot = function() fired[#fired + 1] = "za" end
local realCaptureSyncPending = Overlord.IsCaptureSyncPending
Overlord.IsCaptureSyncPending = function() return false end
local herdEpoch = clock - 30
OverlordDB.frontTruceResetEpoch.elwynn = herdEpoch
realBroadcastFR(sync, "elwynn", herdEpoch)
assert(#fired == 0 and #timersFR == 1, "Truce-end announce was not deferred")
assert(timersFR[1].delay >= 3 and timersFR[1].delay <= 25, "Announce delay outside 3-25 s")
sync:OnReceiveFrontTruceEndReset("elwynn:" .. herdEpoch, "Faster Peer", "CHANNEL")
timersFR[1].fn()
assert(#fired == 0, "Truce end re-announced although the network already carried it")
OverlordDB.frontTruceResetEpoch.redridge = herdEpoch
realBroadcastFR(sync, "redridge", herdEpoch)
sync:OnReceiveFrontTruceEndReset("redridge:" .. (herdEpoch + 5), "Forger Peer", "CHANNEL")
timersFR[2].fn()
assert(#fired == 4, "Unheard truce end was not announced once (FR group/channel/relay + ZA)")
timersFR[2].fn()
assert(#fired == 4, "Truce end announced twice by the same client")
sync.SendToGroup, sync.SendToChannel, sync.BroadcastToRelay, sync.BroadcastFrontZoneSnapshot =
    savedSend[1], savedSend[2], savedSend[3], savedSend[4]
Overlord.IsCaptureSyncPending = realCaptureSyncPending
C_Timer.After = realAfter

-- 16. Pending slots (one per sender, four per front): newer unproven FRs from three
-- senders, one of them sending several, cannot evict the genuine one.
zones:ClearFrontVictories()
local GV = clock + 50
clock = GV + 1500
local GE = GV + 900
hordeKeptMap(GE)
for _, zone in ipairs(branches) do zone.capturedTime, zone.updatedAt = GE + 300, GE + 300 end
sync:OnReceiveFrontTruceEndReset("elwynn:" .. GE, "Genuine Peer", "CHANNEL")
for i = 1, 5 do
    local name = (i % 2 == 0) and "FORGER PEER" or "Forger Peer"
    sync:OnReceiveFrontTruceEndReset("elwynn:" .. (clock - 60 + i), name, "CHANNEL")
end
for i = 1, 2 do
    sync:OnReceiveFrontTruceEndReset("elwynn:" .. (clock - 30 + i), "Forger " .. i, "CHANNEL")
end
journal = { GV, "Horde" }
sync:RetryPendingTruceReleases()
assert(OverlordDB.frontTruceResetEpoch.elwynn == GE, "A newer unproven FR evicted the genuine pending one")
journal = nil
-- 17. Forged packets on a kept conquest: an FR at epoch + 900 "proven" by the kept capital
-- (epoch + 1) would slide the 6 h window forever; a VF at the kept stamp would reopen a
-- 15-minute truce. Neither changes anything.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
journal = nil
local FV = clock + 100
clock = FV
winFront("Alliance", FV)
local FE = FV + 900
clock = FE + 60
zones:TryExpireFrontTruces()
assert(OverlordDB.frontTruceResetEpoch.elwynn == FE and hordeCap.capturedTime == FE + 1,
    "Forged-packet fixture: truce end not applied")
clock = FE + 1000
sync:OnReceiveFrontTruceEndReset("elwynn:" .. (FE + 901), "Forger Tester", "CHANNEL")
sync:RetryPendingTruceReleases()
assert(OverlordDB.frontTruceResetEpoch.elwynn == FE, "A forged FR moved the truce end")
assert(hordeCap.capturedTime == FE + 1, "A forged FR restamped the kept capital")
sync:OnReceiveVictoryFaction((FE + 1) .. ":A:elwynn")
assert(OverlordDB.frontVictories.elwynn == nil, "A VF at the kept stamp reopened a truce")
-- The finished victory itself, replayed late, does not come back either.
sync:OnReceiveVictoryFaction(FV .. ":A:elwynn")
assert(OverlordDB.frontVictories.elwynn == nil, "A finished victory was resurrected by a late VF")
-- 18. A client with the kept map but no trace of the victory (no record, no truce end,
-- no journal) gets a TV at the kept stamp: no new victory, no truce.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
journal = nil
local TE = clock + 100
clock = TE + 120
hordeKeptMap(TE)
OverlordDB.frontTruceResetEpoch.elwynn = nil
sync:OnReceiveTotalVictory("Horde:" .. (TE + 1) .. ":0:0:elwynn", "Forger Tester", "CHANNEL")
assert(OverlordDB.frontVictories.elwynn == nil, "A TV at the kept stamp opened a truce")
assert(not zones:IsOnVictoryCooldown(), "A TV at the kept stamp put the front on truce")

-- Same traceless client: a VF and an SR header at the kept stamp, and an SR header
-- dated "now" (the map alone would support it), open nothing either.
sync:OnReceiveVictoryFaction((TE + 1) .. ":H:elwynn")
assert(OverlordDB.frontVictories.elwynn == nil, "A VF at the kept stamp opened a truce")
sync:OnSyncRequest("Forger Tester", "Horde:" .. tostring(Overlord.Version or "") .. ":" .. (TE + 1) .. ":H:elwynn:T", "CHANNEL")
sync:OnSyncRequest("Forger Tester", "Horde:" .. tostring(Overlord.Version or "") .. ":" .. clock .. ":H:elwynn:T", "CHANNEL")
assert(OverlordDB.frontVictories.elwynn == nil, "An SR header reopened a truce on a kept conquest")
assert(not zones:IsOnVictoryCooldown(), "An SR header put a kept conquest on truce")
-- A client still holding the victory record (its 30 s tick has not run yet) gets a VT
-- at the kept stamp: the record keeps the real victory time.
local HV = TE - 900
OverlordDB.frontVictories.elwynn = { timestamp = HV, faction = "Horde" }
clock = TE + 10
sync:OnReceiveVictoryTimestamp((TE + 1) .. ":elwynn")
assert(OverlordDB.frontVictories.elwynn.timestamp == HV, "A VT at the kept stamp moved the victory")
zones:ClearFrontVictories()

-- 19. A late joiner gets the map of a too-soon retake (the Alliance retook the Horde
-- capital 10 min ago, under 6 h after its victory, so nobody counted it) before the
-- journal: the map alone is not a victory. A fresh capture still is.
broadcasts, printed = {}, {}
journal = nil
local savedInFront = Overlord.InActiveFront
Overlord.InActiveFront = true
local RT = clock + 100
clock = RT + 600
for _, zone in ipairs(elwynn.zones) do
    zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", RT - 3000, RT - 3000
    zone._loginSyncUnconfirmed = nil
end
hordeCap.capturedTime, hordeCap.updatedAt = RT, RT
OverlordDB.frontTruceResetEpoch.elwynn = nil
sync:CheckTotalVictoryFromSync()
assert(OverlordDB.frontVictories.elwynn == nil, "A late joiner turned a too-soon retake into a victory")
-- The same map with the victory in the journal is a victory (late joiner, real one).
local realNear = Overlord.GetDominationVictoryEventNear
Overlord.GetDominationVictoryEventNear = function(_, frontId, faction, ts)
    if frontId == "elwynn" and faction == "Alliance" and ts == RT then return { victoryTs = RT } end
end
sync:CheckTotalVictoryFromSync()
assert(OverlordDB.frontVictories.elwynn and OverlordDB.frontVictories.elwynn.timestamp == RT,
    "A journal-backed victory was not derived from the map")
Overlord.GetDominationVictoryEventNear = realNear
zones:ClearFrontVictories()
Overlord.InActiveFront = savedInFront

-- 20. The defenders start retaking their capital a few seconds after the epoch, before
-- this client's 30 s truce tick: the truce still ends (epoch recorded, front restamped,
-- the capital's stable base kept one second after), it is not pruned as a phantom.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
journal = nil
local LV = clock + 100
clock = LV
winFront("Alliance", LV)
local LE = LV + 900
clock = LE + 20
hordeCap._localCaptureBase = { id = hordeCap.id, owner = "Alliance", status = "captured",
    capturedTime = hordeCap.capturedTime, updatedAt = hordeCap.updatedAt }
hordeCap.status = "in_progress"
zones:TryExpireFrontTruces()
assert(OverlordDB.frontTruceResetEpoch.elwynn == LE,
    "A liberation started before the tick pruned the truce end: " .. tostring(OverlordDB.frontTruceResetEpoch.elwynn))
assert(hordeCap._localCaptureBase.capturedTime == LE + 1, "The capital's stable base was not kept at epoch + 1")
for _, zone in ipairs(branches) do assert(zone.capturedTime == LE, zone.id .. " not restamped at the epoch") end
assert(#printed == 1 and printed[1]:find("conquest kept", 1, true), "Truce-end line missing")
hordeCap.status, hordeCap._localCaptureBase = "captured", nil
-- The defenders already retook it before the tick: a liberation after a real truce end.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
local LV2 = clock + 100
clock = LV2
winFront("Alliance", LV2)
local LE2 = LV2 + 900
clock = LE2 + 25
hordeCap.owner, hordeCap.status, hordeCap.capturedTime, hordeCap.updatedAt = "Horde", "captured", LE2 + 3, LE2 + 3
zones:TryExpireFrontTruces()
assert(OverlordDB.frontTruceResetEpoch.elwynn == LE2, "A liberation before the tick pruned the truce end")
assert(hordeCap.owner == "Horde" and hordeCap.capturedTime == LE2 + 3, "The liberated capital was given back")
for _, zone in ipairs(branches) do assert(zone.capturedTime == LE2, zone.id .. " not restamped at the epoch") end
-- A peer's truce-end ZA arrived first (zones at the epoch, capital base at epoch + 1),
-- then the liberation started, all before this client's tick and the FR: still a truce end.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
local LV3 = clock + 100
clock = LV3
winFront("Alliance", LV3)
local LE3 = LV3 + 900
clock = LE3 + 15
for _, zone in ipairs(branches) do zone.capturedTime, zone.updatedAt = LE3, LE3 end
allianceCap.capturedTime, allianceCap.updatedAt = LE3, LE3
hordeCap._localCaptureBase = { id = hordeCap.id, owner = "Alliance", status = "captured",
    capturedTime = LE3 + 1, updatedAt = LE3 + 1 }
hordeCap.status = "in_progress"
zones:TryExpireFrontTruces()
assert(OverlordDB.frontTruceResetEpoch.elwynn == LE3,
    "A base already restamped by the truce end was taken for a phantom: " .. tostring(OverlordDB.frontTruceResetEpoch.elwynn))
hordeCap.status, hordeCap._localCaptureBase = "captured", nil
-- A capital that never fell (its own faction since before the epoch) is still a phantom.
zones:ClearFrontVictories()
local PV = clock + 100
clock = PV
winFront("Alliance", PV)
hordeCap.owner, hordeCap.capturedTime, hordeCap.updatedAt = "Horde", PV - 600, PV - 600
clock = PV + 930
zones:TryExpireFrontTruces()
assert(OverlordDB.frontTruceResetEpoch.elwynn == PV, "A victory whose capital never fell ended a truce")
zones:ClearFrontVictories()

-- 21. During the truce, a forged map entry moves the captured capital one second later
-- (the kept-capital signature): refused, so truce holders never re-serve it and late
-- joiners still get the victory.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
local FV2 = clock + 100
clock = FV2
winFront("Alliance", FV2)
clock = FV2 + 60
local forged = { { id = hordeCap.id, owner = "Alliance", status = "captured",
    capturedTime = FV2 + 2, updatedAt = FV2 + 2 } }
local forgedPages = sync:BuildZoneAllSnapshotPages(forged, "P")
assert(forgedPages and #forgedPages > 0, "fixture: no forged ZA page")
for _, page in ipairs(forgedPages) do sync:OnReceiveZoneAll(page, "Forger Tester") end
assert(hordeCap.capturedTime == FV2, "A forged in-truce restamp of the capital was applied: "
    .. tostring(hordeCap.capturedTime) .. " vs " .. FV2)
-- A VT, a VF or an SR header for the same victory never moves its time forward, and the
-- restamp window does not follow a moved record: the same forgery after them still fails.
sync:OnReceiveVictoryTimestamp((FV2 + 1) .. ":elwynn")
sync:OnReceiveVictoryFaction((FV2 + 3) .. ":A:elwynn")
sync:OnSyncRequest("Forger Tester", "Alliance:" .. tostring(Overlord.Version or "") .. ":" .. (FV2 + 4) .. ":A:elwynn:T", "CHANNEL")
assert(OverlordDB.frontVictories.elwynn.timestamp == FV2, "The same victory's time was moved forward: "
    .. tostring(OverlordDB.frontVictories.elwynn.timestamp))
OverlordDB.frontVictories.elwynn.timestamp = FV2 + 1 -- even if a record moved anyway
local forged2 = { { id = hordeCap.id, owner = "Alliance", status = "captured",
    capturedTime = FV2 + 1, updatedAt = FV2 + 1 } }
for _, page in ipairs(sync:BuildZoneAllSnapshotPages(forged2, "P")) do sync:OnReceiveZoneAll(page, "Forger Two") end
assert(hordeCap.capturedTime == FV2, "A moved victory record let the forged restamp through")
OverlordDB.frontVictories.elwynn.timestamp = FV2
-- The same page after the truce end (epoch + 1, the real kept stamp) is accepted.
clock = FV2 + 960
zones:TryExpireFrontTruces()
assert(hordeCap.capturedTime == FV2 + 901, "fixture: truce end not applied")
zones:ClearFrontVictories()

print("Capital kept: no release, own capital always attackable, liberation line, 6 h victory spacing, FR proofs, herd and forged packets OK")
