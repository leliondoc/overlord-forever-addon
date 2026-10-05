-- Persistent conquest: after the 15-minute truce the conquered zones keep their owner,
-- only the fallen capital rises again and is protected against the winner (Retail model).
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
Overlord.L.FRONT_CAPITAL_RELEASED = "%s released until %s"
Overlord.L.CAPITAL_PROTECTED_UNTIL = "Protected until %s"
Overlord.L.CAPITAL_PROTECTED_SHORT = "Protected %s"
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
Overlord.PrintNotification = function() end
local broadcasts = {}
sync.BroadcastFrontTruceEndReset = function(_, frontId, epoch)
    broadcasts[#broadcasts + 1] = { frontId = frontId, epoch = epoch }
end

OverlordDB.zones, OverlordDB.frontVictories = {}, {}
OverlordDB.frontTruceResetEpoch, OverlordDB.frontCapitalImmuneFrom = {}, {}
Overlord.Fronts:Activate("elwynn")
zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RequireCaptureSync("login")
Overlord:RestoreZoneState()
local allZones = {}
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do
        zone._loginSyncUnconfirmed = nil
        allZones[#allZones + 1] = zone
    end
end
local elwynn = Overlord.Fronts:GetFront("elwynn")
local hordeCap = Overlord.Fronts:GetZone(elwynn.hordeCapitalId, "elwynn")
local allianceCap = Overlord.Fronts:GetZone(elwynn.allianceCapitalId, "elwynn")
local branches = {}
for _, zone in ipairs(elwynn.zones) do
    if zone.id ~= hordeCap.id and zone.id ~= allianceCap.id then branches[#branches + 1] = zone end
end
assert(#branches >= 2, "Elwynn needs branch zones")

local function winFront(victoryTs)
    zones:SetVictoryCooldown("elwynn", "Alliance", victoryTs)
    zones:ForceSyncFrontToWinner("elwynn", "Alliance", victoryTs, true)
end

-- 1. Victory, then the truce ends on this client: release, not reset.
local V = clock
winFront(V)
assert(select(1, zones:IsOnVictoryCooldown("elwynn")), "Victory truce did not start")
clock = V + 899
zones:TryExpireFrontTruces()
assert(#broadcasts == 0 and hordeCap.owner == "Alliance", "Truce ended early")
clock = V + 901
zones:TryExpireFrontTruces()
local E = V + 900
assert(#broadcasts == 1 and broadcasts[1].epoch == E, "Release was not broadcast once at the truce epoch")
assert(hordeCap.owner == "Horde" and hordeCap.capturedTime == E and hordeCap.updatedAt == E,
    "The fallen capital did not rise again at the epoch")
for _, zone in ipairs(branches) do
    assert(zone.owner == "Alliance", "Conquest lost on " .. zone.id)
    assert(zone.capturedTime == E and zone.updatedAt == E, "Kept zone not restamped: " .. zone.id)
    local part = sync:BuildZoneAllSnapshotPart(zone, false)
    local _, code, ts = strsplit(":", part)
    assert(code == "A" and tonumber(ts) == E, "ZA would carry a pre-epoch clock for " .. zone.id)
end
assert(allianceCap.owner == "Alliance" and allianceCap.capturedTime == E,
    "Winner capital must carry the epoch too")
assert(OverlordDB.frontTruceResetEpoch.elwynn == E and not OverlordDB.frontVictories.elwynn,
    "Release bookkeeping missing")

-- 2. Only the fallen capital is protected (six hours); the losers may retake everything,
-- the winner's capital included.
local immune, remaining, untilTs, protectedFaction = zones:GetFrontCapitalImmunity("elwynn")
assert(immune and protectedFaction == "Horde" and untilTs == E + zones:GetCapitalImmunitySeconds()
    and remaining > 0, "The fallen capital is not protected after the release")
assert(zones:GetCapitalImmunitySeconds() == 6 * 3600, "Protection is not six hours")
assert(select(1, zones:IsCapitalImmune(hordeCap.id)), "The fallen capital must be protected")
assert(not select(1, zones:IsCapitalImmune(allianceCap.id)), "The winner's capital must stay open")
assert(not sync:ShouldRejectImmuneCapitalChange(allianceCap.id, "Horde", "in_progress", "ZS"),
    "The losers cannot besiege the winner's capital during the protection")
assert(zones:GetCapitalProtectionLabel(allianceCap.id, "elwynn") == nil,
    "The winner's capital shows a protection label")
assert(not select(1, zones:IsCapitalImmune(branches[1].id)), "A branch must never be protected")
zones:UpdateAvailableZones()
assert(not zones:IsZoneAvailable(hordeCap.id) and hordeCap.status == "locked",
    "Winner can besiege a protected capital")
assert(zones:GetCapitalProtectionLabel(hordeCap.id, "elwynn") == "Protected until "
    .. date("%H:%M", untilTs), "Protected capital label missing")

-- 3. Receive gates: no siege, no foreign owner, no C on a protected capital.
assert(sync:ShouldRejectImmuneCapitalChange(hordeCap.id, "Alliance", "captured", "ZA"))
assert(sync:ShouldRejectImmuneCapitalChange(hordeCap.id, "Alliance", "in_progress", "ZS"))
assert(sync:ShouldRejectImmuneCapitalChange(hordeCap.id, "Horde", "captured", "C"))
assert(not sync:ShouldRejectImmuneCapitalChange(hordeCap.id, "Horde", "captured", "ZA"),
    "The native owner must still converge by ZA")
assert(not sync:ShouldRejectImmuneCapitalChange(branches[1].id, "Horde", "in_progress", "ZS"),
    "Branches must stay contestable during the protection")

-- 4. A 1.5.2 client did the full reset: its neutral entries at the same epoch never
-- wipe the conquest, and its batch still delivers its fresher zones elsewhere.
local ash = Overlord.Fronts:GetFront("ashenvale")
local ashBranch
for _, zone in ipairs(ash.zones) do
    if not zones:GetBaseZoneFixedOwner(zone.id) then ashBranch = zone break end
end
local saved = {}
local function snapshot()
    for _, zone in ipairs(allZones) do
        saved[zone] = { owner = zone.owner, status = zone.status,
            capturedTime = zone.capturedTime, updatedAt = zone.updatedAt }
    end
end
local function restore()
    for zone, s in pairs(saved) do
        zone.owner, zone.status = s.owner, s.status
        zone.capturedTime, zone.updatedAt = s.capturedTime, s.updatedAt
    end
end
clock = E + 300
snapshot()
for _, zone in ipairs(branches) do
    zone.owner, zone.status, zone.capturedTime, zone.updatedAt = nil, "locked", nil, E
end
ashBranch.owner, ashBranch.status = "Horde", "captured"
ashBranch.capturedTime, ashBranch.updatedAt = E + 60, E + 60
local oldPages = sync:BuildZoneAllSnapshotPages(allZones, "G")
restore()
for _, page in ipairs(oldPages) do sync:OnReceiveZoneAll(page, "Old Tester") end
for _, zone in ipairs(branches) do
    assert(zone.owner == "Alliance", "A 1.5.2 neutral snapshot wiped the conquest on " .. zone.id)
end
assert(ashBranch.owner == "Horde" and ashBranch.capturedTime == E + 60,
    "The rest of the old client's batch was refused")

-- 5. A forged or old-version siege of the protected capital is skipped, not the batch.
snapshot()
hordeCap.owner, hordeCap.status = "Alliance", "captured"
hordeCap.capturedTime, hordeCap.updatedAt = E + 120, E + 120
ashBranch.owner, ashBranch.capturedTime, ashBranch.updatedAt = "Alliance", E + 130, E + 130
local forgedPages = sync:BuildZoneAllSnapshotPages(allZones, "G")
restore()
for _, page in ipairs(forgedPages) do sync:OnReceiveZoneAll(page, "Forger Tester") end
assert(hordeCap.owner == "Horde" and hordeCap.capturedTime == E, "Protected capital was taken by ZA")
assert(ashBranch.owner == "Alliance" and ashBranch.capturedTime == E + 130,
    "The forged capital entry blocked the whole snapshot")

-- 6. The old victory is never announced again from a map still painted by the winner.
local shown = 0
Overlord.UI = Overlord.UI or {}
Overlord.UI.ShowVictoryScreen = function() shown = shown + 1 end
Overlord.UI.RequestRefresh = function() end
Overlord.InActiveFront = true
local keep = { owner = hordeCap.owner, ct = hordeCap.capturedTime, up = hordeCap.updatedAt }
hordeCap.owner, hordeCap.capturedTime, hordeCap.updatedAt = "Alliance", V, V
sync:CheckTotalVictoryFromSync()
assert(shown == 0, "Victory screen shown again during the protection")
clock = E + zones:GetCapitalImmunitySeconds() + 10
sync:CheckTotalVictoryFromSync()
assert(shown == 0, "The released victory was announced again after the protection")
hordeCap.owner, hordeCap.capturedTime, hordeCap.updatedAt = keep.owner, keep.ct, keep.up

-- 6b. Counter-victory during the protection: the losers take the winner's capital.
clock = E + 3600
snapshot()
for _, zone in ipairs(elwynn.zones) do
    zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Horde", "captured", clock - 60, clock - 60
end
allianceCap.capturedTime, allianceCap.updatedAt = clock, clock
assert(select(1, zones:IsCapitalImmune(hordeCap.id)), "Protection should still run during the counter-attack")
sync:CheckTotalVictoryFromSync()
assert(shown == 1, "The losers' counter-victory was refused during the protection")
assert(OverlordDB.frontVictories.elwynn and OverlordDB.frontVictories.elwynn.faction == "Horde",
    "Counter-victory not recorded")
restore()
zones:ClearFrontVictory("elwynn")
sync:ResetVictoryFlagForFront("elwynn")
shown = 0
clock = E + zones:GetCapitalImmunitySeconds() + 10
Overlord.InActiveFront = false

-- 7. Protection over: the enemy capital opens again for the faction holding the rest.
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")), "Protection never ends")
for _, zone in ipairs(elwynn.zones) do
    if zone ~= hordeCap then zone.owner, zone.status = "Alliance", "captured" end
end
zones:TryExpireFrontTruces()
zones:UpdateAvailableZones()
assert(zones:IsZoneAvailable(hordeCap.id), "Capital stays closed after the protection")
assert(not sync:ShouldRejectImmuneCapitalChange(hordeCap.id, "Alliance", "in_progress", "ZS"),
    "Siege still refused after the protection")

-- 8. Release learnt by ZA before this client's own tick: protection, no rebroadcast.
broadcasts = {}
local V2 = clock
winFront(V2)
local E2 = V2 + 900
clock = E2 + 5
hordeCap.owner, hordeCap.status, hordeCap.capturedTime, hordeCap.updatedAt = "Horde", "locked", E2, E2
for _, zone in ipairs(branches) do zone.capturedTime, zone.updatedAt = E2, E2 end
zones:TryExpireFrontTruces()
assert(#broadcasts == 0, "A release already on the network was broadcast again")
assert(OverlordDB.frontTruceResetEpoch.elwynn == E2 and select(1, zones:GetFrontCapitalImmunity("elwynn")),
    "A release received by ZA gave no protection")

-- 9. Login with a saved victory map still in quarantine: release locally, silently.
clock = E2 + zones:GetCapitalImmunitySeconds() + 100
local V3 = clock
winFront(V3)
for _, zone in ipairs(elwynn.zones) do zone._loginSyncUnconfirmed = true end
clock = V3 + 2000
zones:TryExpireFrontTruces()
for _, zone in ipairs(elwynn.zones) do zone._loginSyncUnconfirmed = nil end
assert(#broadcasts == 0, "Login release must not broadcast")
assert(hordeCap.owner == "Horde" and branches[1].owner == "Alliance",
    "Login treated a real victory as a phantom one")
assert(OverlordDB.frontTruceResetEpoch.elwynn == V3 + 900, "Login release epoch is wrong")

-- 10. Weekly reset clears every protection.
zones:ClearFrontVictories()
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")), "Weekly reset kept the protection")

-- 11. A domination journal victory protects only when the local map carries its release:
-- a lone (forged or old-version) VB must never lock a front.
local journalTs = clock - 1000
local journalEpoch = journalTs + 900
Overlord.GetLatestDominationVictoryForFront = function(_, frontId)
    if frontId == "elwynn" then return journalTs, "Alliance" end
end
hordeCap.owner, hordeCap.status, hordeCap.capturedTime = "Horde", "locked", campaign
for _, zone in ipairs(branches) do zone.owner, zone.capturedTime = "Horde", campaign + 10 end
allianceCap.capturedTime = campaign
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")), "A lone journal victory locked the front")
hordeCap.capturedTime = journalEpoch
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")),
    "A capital clock alone must not corroborate a journal victory")
branches[1].owner, branches[1].capturedTime = "Alliance", journalEpoch
assert(select(1, zones:GetFrontCapitalImmunity("elwynn")),
    "A release received by ZA plus the journal gave no protection")
Overlord.GetLatestDominationVictoryForFront = nil

-- 12. A victory from the previous campaign is never released into the new week.
broadcasts = {}
zones:SetVictoryCooldown("elwynn", "Alliance", campaign - 600)
assert(not zones:ApplyFrontTruceEndReset("elwynn", campaign + 300, false),
    "Last week's victory was released into the new campaign")
zones:TryExpireFrontTruces()
assert(#broadcasts == 0, "Last week's victory was broadcast as a release")
zones:ClearFrontVictories()

-- 13. Inside an instance nothing is released, printed or broadcast; it waits for the exit.
local printed = {}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
local V4 = clock
winFront(V4)
clock = V4 + 1000
Overlord.InstanceSuspended = true
zones:TryExpireFrontTruces()
assert(#broadcasts == 0 and #printed == 0 and hordeCap.owner == "Alliance",
    "Truce end ran inside an instance")
Overlord.InstanceSuspended = false
zones:TryExpireFrontTruces()
assert(#broadcasts == 1 and #printed == 1 and hordeCap.owner == "Horde",
    "Truce end did not run after leaving the instance")
assert(printed[1]:find(date("%H:%M", V4 + 900 + zones:GetCapitalImmunitySeconds()), 1, true),
    "Release chat line lacks the protection end time")

-- 14. Login long after the protection ended: release silently, no past "until" time.
zones:ClearFrontVictories()
broadcasts, printed = {}, {}
local V5 = clock + 100
clock = V5
winFront(V5)
clock = V5 + 900 + zones:GetCapitalImmunitySeconds() + 600
zones:TryExpireFrontTruces()
assert(hordeCap.owner == "Horde" and #printed == 0, "Late login printed an expired protection time")
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")), "Late login revived an expired protection")

-- 15. Late joiner learns a HORDE release from the network (ZA first, then FR): after a
-- release both capitals are native at the epoch, so the winner must come from the
-- victory trace or the conquered zones, never from the capitals.
local function hordeReleasedMap(epoch)
    for _, zone in ipairs(elwynn.zones) do
        zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Horde", "captured", epoch, epoch
        zone._loginSyncUnconfirmed = nil
    end
    allianceCap.owner = "Alliance"
end
for _, mode in ipairs({ "journal", "pruned" }) do
    zones:ClearFrontVictories()
    local HV = clock + 100
    clock = HV + 1000
    local HE = HV + 900
    hordeReleasedMap(HE)
    if mode == "journal" then
        Overlord.GetLatestDominationVictoryForFront = function(_, frontId)
            if frontId == "elwynn" then return HV, "Horde" end
        end
    else
        Overlord.GetLatestDominationVictoryForFront = nil
        OverlordDB.frontTruceResetEpoch.elwynn = HV
    end
    sync:OnReceiveFrontTruceEndReset("elwynn:" .. HE, "Late Tester", "CHANNEL")
    local lateImmune, _, _, lateProtected = zones:GetFrontCapitalImmunity("elwynn")
    assert(lateImmune and lateProtected == "Alliance",
        "Late joiner (" .. mode .. ") protected the winner's capital after a Horde victory")
    assert(select(1, zones:IsCapitalImmune(allianceCap.id))
        and not select(1, zones:IsCapitalImmune(hordeCap.id)), "Wrong capital protected (" .. mode .. ")")
end
Overlord.GetLatestDominationVictoryForFront = nil

-- 16. One SR response sends FR before the VB journal: the FR cannot be proven yet,
-- stays pending, and is replayed once the journal knows the victory (no new packet).
zones:ClearFrontVictories()
local PV = clock + 100
clock = PV + 1500
local PE = PV + 900
hordeReleasedMap(PE)
-- Fighting went on after the release: no conquered zone carries the epoch any more.
for _, zone in ipairs(branches) do zone.capturedTime, zone.updatedAt = PE + 300, PE + 300 end
sync:OnReceiveFrontTruceEndReset("elwynn:" .. PE, "Late Tester", "CHANNEL")
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")), "FR without proof applied a protection")
-- A future-dated FR (clock ahead or forged) never evicts the genuine pending one.
sync:OnReceiveFrontTruceEndReset("elwynn:" .. (clock + 200), "Forger Tester", "CHANNEL")
Overlord.GetLatestDominationVictoryForFront = function(_, frontId)
    if frontId == "elwynn" then return PV, "Horde" end
end
sync:RetryPendingTruceReleases()
local pendImmune, _, _, pendFaction = zones:GetFrontCapitalImmunity("elwynn")
assert(pendImmune and pendFaction == "Alliance", "Pending FR was not proven once the journal arrived")
Overlord.GetLatestDominationVictoryForFront = nil

-- 17. An FR that never gets its proof stays inert and is forgotten after the protection.
zones:ClearFrontVictories()
local UE = clock - 100
sync:OnReceiveFrontTruceEndReset("elwynn:" .. UE, "Unproven Tester", "CHANNEL")
sync:RetryPendingTruceReleases()
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")), "Unproven FR applied a protection")
clock = UE + zones:GetCapitalImmunitySeconds() + 10
sync:RetryPendingTruceReleases()
Overlord.GetLatestDominationVictoryForFront = function(_, frontId)
    if frontId == "elwynn" then return UE - 900, "Horde" end
end
sync:RetryPendingTruceReleases()
assert(not select(1, zones:GetFrontCapitalImmunity("elwynn")), "Expired pending FR came back")
Overlord.GetLatestDominationVictoryForFront = nil
print("Forever capital release: conquest kept, capital released and protected, old clients and forged sieges OK")
