-- Real shared capture/control/leaderboard/wire path, with game APIs simulated.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now = 1790018000
local mapID, guild, faction = 1418, "Fortress Guild", "Alliance"
function time() return now end
function GetServerTime() return now end
function GetTime() return now - 1790016000 end
function GetGuildInfo() return guild end
function IsInInstance() return false end
function IsInGroup() return false end
function IsInRaid() return false end
function UnitIsDead() return false end
function UnitIsGhost() return false end
function UnitExists(unit) return unit == "player" end
function UnitGUID(unit) return unit == "player" and "Player-1-TEST" end
function UnitFactionGroup() return faction end
function UnitIsPlayer() return true end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return unpack(fields)
end
C_Map = {
    GetBestMapForUnit = function() return mapID end,
    GetMapInfo = function() return { parentMapID = 0 } end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.430, 0.308 end }
    end,
}
Overlord.ZoneControl = nil
Overlord.Fronts.ResolveFrontByOverlayMapID = function() return nil end
Overlord.Fronts.ResolveFrontByMapID = function() return nil end
Overlord.Fronts.Activate = function() end
Overlord.InActiveFront, Overlord.WaitingForSync, Overlord.InstanceSuspended = false, false, false
Overlord.IsInCatchUpPhase = function() return false end
Overlord.CanStartLocalCapture = function() return true end
Overlord.IsCaptureSyncGateActive = function() return false end
Overlord.IsCaptureSyncPending = function() return false end
Overlord.SaveState = function() end
Overlord.PlayerFaction = faction
OverlordDB = { lastResetTimestamp = 1789527600, config = {},
    guildKeeps = { badlands = { status = "held", ownerGuild = "Old Siege" } },
    guildKeepCutoffSnapshots = { large = { historical = true } },
    guildKeepSiegeWinAwards = { daily = 99 },
    outposts = { silverpine = { status = "neutral", updatedAt = now - 100 } },
}
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("Outpost.lua"))()
assert(loadfile("GuildKeep.lua"))()
assert(loadfile("OutpostControl.lua"))()
assert(loadfile("SyncStrategicSites.lua"))()
assert(loadfile("SyncOutpost.lua"))()
local op, gk, control, sync, lb = Overlord.Outpost, Overlord.GuildKeep,
    Overlord.OutpostControl, Overlord.Sync, Overlord.Leaderboard
local site = gk:GetSite("badlands")
assert(site == op:GetSite("badlands") and site.holdTimeRequired == 600)
assert(op:GetBaseHoldTimeRequired(op:GetSite("silverpine")) == 300)
local st = gk:GetState("badlands")
assert(st == op:GetState("badlands") and st.status == "neutral")
assert(not OverlordDB.guildKeeps and not OverlordDB.guildKeepCutoffSnapshots
    and not OverlordDB.guildKeepSiegeWinAwards, "Old siege storage survived migration")
assert(OverlordDB.outposts.silverpine.updatedAt == now - 100, "Existing outpost reset")
assert(not gk.IsSiegeWindowOpen and not lb.MaybeAwardGuildKeepDailyWins)
assert(not sync.AppendLeaderboardGuildKeepDailyProofsToSrQueue and not sync.OnReceiveGuildKeepState)
local count = 0
for key, keepSite in pairs(Overlord.GuildKeepSites) do
    count = count + 1
    assert(op:GetSite(key) == keepSite and keepSite.isFortress and keepSite.standaloneOpenWorld)
    assert(gk:ResolveSiteByMapID(keepSite.mapID) == keepSite)
end
assert(count == 5)
assert(gk:ShouldProjectPinOnMap(site, 1415) and not op:ShouldProjectOutpostPinOnMap(site, 1415),
    "Fortress gets two continent pins")
assert(#op:GetSitesOnMap(site.mapID) == 0, "Fortress gets two detail pins")
assert(gk:GetKeepMapIconAtlas(st, site) == "Warfronts-BaseMapIcons-Empty-MainHall")
local sent = {}
for _, method in ipairs({ "Send", "SendToChannel", "BroadcastToRelay" }) do
    sync[method] = function(_, kind, data) sent[#sent + 1] = { kind, data }; return true end
end
-- First capture outside any former siege window.
control:StartHold("badlands", st, site)
assert(st.status == "in_progress" and st.holdTimeRequired == 600)
now = now + 599
control:UpdateHoldTimer("badlands", st, site, 599, true)
assert(st.status == "in_progress", "Fortress finished at outpost speed")
now = now + 1
control:UpdateHoldTimer("badlands", st, site, 1, true)
assert(st.status == "held" and st.expiresAt == 0)
assert(gk:GetKeepMapIconAtlas(st, site) == "Warfronts-BaseMapIcons-Alliance-MainHall")
local row = assert(lb:GetOutpostCaptureCountRow("badlands", guild, "global"))
assert(row.count == 1)
lb:RecordOutpostCapture("badlands", guild, faction, now, "global")
assert(row.count == 1, "Duplicate capture increased rank")
local keeps = lb:GetSortedGuildKeeps()
assert(#keeps == 1 and keeps[1].wins == 1 and keeps[1].keepSiteKey == "badlands"
    and keeps[1].currentlyHeld and keeps[1].keepAtlas:find("MainHall"))
assert(#lb:GetSortedOutposts() == 0, "Fortress leaked into the outpost ranking column")
local foundState, foundCapture = false, false
for _, message in ipairs(sent) do
    assert(message[1] ~= "GK" and message[1] ~= "GC" and message[1] ~= "GA"
        and message[1] ~= "GH" and message[1] ~= "G7", "Retired wire protocol emitted")
    if message[1] == "OP" then foundState = true end
    if message[1] == "OC" then foundCapture = true end
end
assert(foundState and foundCapture, "Shared state/capture broadcasts missing")
-- Reload preserves the new state and count; cleanup must not run as a reset.
op:RestoreOutposts()
assert(op:GetState("badlands").ownerGuild == guild and row.count == 1)
assert(not OverlordDB.guildKeeps)
-- The opposing guild can capture immediately, using the same duration/decay rule.
guild, faction, Overlord.PlayerFaction = "Enemy Guild", "Horde", "Horde"
assert(op:CanPlayerStartCapture(st))
control:StartHold("badlands", st, site)
now = now + 120
control:UpdateHoldTimer("badlands", st, site, 120, true)
local progress = st.holdTimeElapsed
now = now + 10
control:UpdateHoldTimer("badlands", st, site, 10, false)
assert(st.holdTimeElapsed < progress and st.status == "in_progress", "Leaving fortress does not decay")
control:RevertCapture("badlands", st)
assert(st.status == "held" and st.ownerGuild == "Fortress Guild", "Abandon lost the previous owner")
now = now + 86401
op:TickMaintenance()
assert(st.status == "held" and st.ownerGuild == "Fortress Guild", "Shared permanent ownership rule changed")
assert(lb:GetOutpostCaptureCountRow("badlands", "Fortress Guild", "global").count == 1)
print("Fortresses: shared capture/decay/ownership, reload, ranking separation, icons, migration and OP/OC wire OK")

-- A fresh observer receives the very same OP/LOC wire, including the 600 s rule.
local heldPayload = assert(sync:BuildOutpostPayload("badlands"))
sent = {}
sync:BroadcastLeaderboardOutpostCount("badlands", "Fortress Guild", "Alliance", 1, st.claimedAt)
local countPayload
for _, message in ipairs(sent) do if message[1] == "LOC" then countPayload = message[2] end end
assert(countPayload, "Shared capture count was not sent")
local campaign = OverlordDB.lastResetTimestamp
OverlordDB = { lastResetTimestamp = campaign, config = {}, fortressOutpostSchema = 1 }
op:EnsureDB()
local observed = op:GetState("badlands")
sync:OnReceiveOutpostState(heldPayload, "Remote Defender", "CHANNEL")
assert(observed.status == "held" and observed.ownerGuild == "Fortress Guild",
    "Observer did not receive fortress through OP")
assert(observed.holdTimeRequired == 600, "Receiver lost fortress capture duration")
sync:OnReceiveOutpostState(heldPayload, "Remote Defender", "CHANNEL")
sync:OnReceiveLeaderboardOutpostCount(countPayload, "Remote Defender", "CHANNEL")
sync:OnReceiveLeaderboardOutpostCount(countPayload, "Remote Defender", "CHANNEL")
assert(lb:GetOutpostCaptureCountRow("badlands", "Fortress Guild", "global").count == 1,
    "OP/LOC replay inflated fortress captures")
assert(#lb:GetSortedGuildKeeps() == 1 and #lb:GetSortedOutposts() == 0)
assert(not op:IsRecaptureTerminalAllowed(observed, observed.claimedAt + 300, site),
    "Fortress terminal accepted at the outpost duration")
assert(op:IsRecaptureTerminalAllowed(observed, observed.claimedAt + 600, site))
op:ResetOutpostsForCampaign()
assert(op:GetState("badlands").status == "neutral")
assert(#lb:GetSortedGuildKeeps() == 0, "Campaign reset retained fortress captures")
print("Fortress remote OP/LOC replay, terminal timing and campaign reset OK")

-- Map/minimap tooltips and the fortress HUD must expire remote observations
-- like the shared engine, without inventing a neutral/captured network event.
local tooltipSite = gk:GetSite("wetlands")
local tooltipState = op:GetState("wetlands")
tooltipState.status, tooltipState.ownerGuild, tooltipState.ownerFaction = "in_progress", "Attack Guild", "Horde"
tooltipState.holdTimeElapsed, tooltipState.holdTimeRequired = 300, 600
tooltipState.updatedAt = now
local observedAt = now
local function activeTooltip()
    return gk:IsKeepCaptureInProgress(tooltipState, "wetlands")
end
assert(activeTooltip(), "Fresh fortress assault hidden")
assert(gk:GetKeepCaptureMapLabel(tooltipState, "wetlands"), "Fresh capture label missing")
assert(not gk:IsKeepNeutralForDisplay(tooltipState, "wetlands"))
now = observedAt + 330
assert(activeTooltip(), "Fortress observation expired before remaining time plus buffer")
now = now + 1
assert(not activeTooltip(), "Expired fortress still appears to be capturing in tooltip/HUD")
assert(not gk:GetKeepCaptureMapLabel(tooltipState, "wetlands"), "Expired capture label remained visible")
assert(gk:IsKeepNeutralForDisplay(tooltipState, "wetlands"), "Expired unowned site lacks neutral presentation")
tooltipState.previousOwnerGuild, tooltipState.previousOwnerFaction = "Defender Guild", "Alliance"
assert(not gk:IsKeepNeutralForDisplay(tooltipState, "wetlands"), "Expired assault hid its previous defender")
assert(gk:GetKeepDisplayTenant(tooltipState, "wetlands") == "Defender Guild")
assert(tooltipState.status == "in_progress" and tooltipState.updatedAt == observedAt,
    "Presentation mutated the remote gameplay state")
tooltipState.updatedAt = now
assert(activeTooltip(), "Fresh heartbeat did not restore capture presentation")
tooltipState.updatedAt = now - 3600
tooltipState.holdAuthorityLocal, tooltipState.isHolding = true, true
assert(activeTooltip(), "Local authoritative capture expired like a remote observation")
tooltipState.isHolding, tooltipState.isPaused = false, true
assert(activeTooltip(), "Local paused capture disappeared")
op:ResetOutpostsForCampaign()
print("Fortress presentation: remote expiry, defender/neutral fallback, fresh heartbeat and local authority OK")

-- 1.5.1: the player who took an outpost is kept with the held state (never shown,
-- never required yet); a name that would break the wire format is refused.
do
    op:ResetOutpostsForCampaign()
    local st = op:GetState("silverpine")
    assert(op:CompleteCapture("silverpine", "Named Guild", "Alliance", nil, nil, true, "Capper Tester"),
        "fixture capture refused")
    assert(st.heldCapturerName == "Capper Tester", "the capturer was not kept with the held state")
    assert(op:NormalizeHeldCapturerName("Bad:Name") == nil and op:NormalizeHeldCapturerName("X") == nil,
        "an unsafe capturer name was accepted")
    op:ResetOutpostsForCampaign()
    assert(op:GetState("silverpine").heldCapturerName == nil, "the capturer survived the campaign reset")
end
print("Outpost held capturer: kept on capture, sanitized, cleared at reset")
