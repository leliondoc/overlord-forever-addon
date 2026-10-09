-- Regression: (1) a ZA whose entries are merely OLDER than local state is skipped
-- per entry instead of failing the whole atomic batch; (3) the C relay retry lands
-- outside the relay's 2 s send coalescing, so the relay really re-sends it.
-- Run from the addon root with Lua 5.1: dofile("tests/forever_zone_partial_merge.test.lua")
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local sync = Overlord.Sync
local EPOCH = Overlord:GetCurrentCampaignStartTs()
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RequireCaptureSync("login")
Overlord:RestoreZoneState()
Overlord.SaveState = function() end
local zones = {}
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zone.name = zone.name or zone.id; zones[#zones + 1] = zone end
end
Overlord:MarkCaptureSyncReceived(true)
for _, z in ipairs(zones) do z._loginSyncUnconfirmed = nil end

local function zoneOf(id) return (select(1, Overlord.Fronts:GetZone(id))) end
local function set(id, owner, ct)
    local z = zoneOf(id)
    z.owner, z.status, z.capturedTime, z.updatedAt = owner, owner and "captured" or "locked", ct, ct
end
local function state(id) local z = zoneOf(id); return (z.owner or "N") .. "@" .. tostring(z.capturedTime or 0) end
local function snapshot()
    local pages, count = sync:BuildZoneAllSnapshotPages(zones, "G")
    assert(count > 1 and pages[1]:match("^@G%-"), "not a complete global snapshot")
    return pages
end
-- A sender is limited to 4 snapshots per 10 s: use a fresh sender name each time.
local senders = 0
local function deliver(pages)
    senders = senders + 1
    for _, p in ipairs(pages) do sync:OnReceiveZoneAll(p, "Peer Sender" .. string.rep("x", senders)) end
end
local X, Y = "elwynn_goldshire", "ash_iris_lake"

-- (1a) Each side missed a different re-capture. Sender view first, then receiver view.
set(X, "Horde", EPOCH + 300); set(Y, "Horde", EPOCH + 1900)          -- sender: stale X, fresh Y
local senderPages = snapshot()
set(X, "Alliance", EPOCH + 2000); set(Y, "Alliance", EPOCH + 500)    -- receiver: fresh X, stale Y
deliver(senderPages)
assert(state(X) == "Alliance@" .. (EPOCH + 2000), "A stale entry overwrote newer local state: " .. state(X))
assert(state(Y) == "Horde@" .. (EPOCH + 1900),
    "One stale entry rejected the whole snapshot; fresh entry Y not merged: " .. state(Y))

-- (1b) Every entry stale: nothing changes.
set(X, "Alliance", EPOCH + 2000); set(Y, "Horde", EPOCH + 1900)
local before = state(X) .. state(Y)
set(X, "Horde", EPOCH + 300); set(Y, "Alliance", EPOCH + 500)
local stalePages = snapshot()
set(X, "Alliance", EPOCH + 2000); set(Y, "Horde", EPOCH + 1900)
deliver(stalePages)
assert(state(X) .. state(Y) == before, "All-stale snapshot changed local state")

-- (1c) Guard kept: enemy capital captured in the snapshot while a prerequisite entry is
-- stale (local newer, still ours) must NOT flip the capital (final view is not a full sweep).
local front = Overlord.Fronts:GetFront("elwynn")
local ac, hc = front.allianceCapitalId, front.hordeCapitalId
for _, z in ipairs(front.zones) do
    if z.id ~= ac and z.id ~= hc then set(z.id, "Horde", EPOCH + (z.id == X and 100 or 3000)) end
end
set(ac, "Horde", EPOCH + 3000)
local sweepPages = snapshot()
set(ac, "Alliance", EPOCH + 50)
set(X, "Alliance", EPOCH + 2000)
deliver(sweepPages)
assert(zoneOf(ac).owner == "Alliance", "Capital flipped although a prerequisite stayed ours")

-- (1d) Neutral variant: the sender never heard of the capture (N) while it knows the
-- other one; the receiver has the reverse. Both must merge (N is skipped, not fatal).
local function setN(id, ts)
    local z = zoneOf(id)
    z.owner, z.status, z.capturedTime, z.updatedAt, z.previousOwner = nil, "locked", nil, ts, nil
end
setN(X, EPOCH); set(Y, "Horde", EPOCH + 1900)                        -- sender: X neutral, Y fresh
local neutralPages = snapshot()
set(X, "Alliance", EPOCH + 2000); setN(Y, EPOCH)                     -- receiver: X fresh, Y neutral
deliver(neutralPages)
assert(state(X) == "Alliance@" .. (EPOCH + 2000), "Neutral entry erased a newer local capture: " .. state(X))
assert(state(Y) == "Horde@" .. (EPOCH + 1900),
    "Unproven neutral entry rejected the whole snapshot; fresh Y not merged: " .. state(Y))

-- (1e) An unproven N with a FRESHER timestamp than the local capture (no reset proof)
-- must never be applied over it, yet must not veto the other fresh entries.
setN(X, EPOCH + 5000); set(Y, "Horde", EPOCH + 2500)
local freshNeutralPages = snapshot()
set(X, "Alliance", EPOCH + 2000); set(Y, "Alliance", EPOCH + 500)
deliver(freshNeutralPages)
assert(state(X) == "Alliance@" .. (EPOCH + 2000), "Unproven fresh N was applied over a local capture: " .. state(X))
assert(state(Y) == "Horde@" .. (EPOCH + 2500), "Unproven fresh N vetoed the rest of the snapshot: " .. state(Y))

-- (3) C relay re-send. Real Relay, fake clock, one Battle.net bridge friend.
function GetChannelName() return 0 end
securecall = securecall or function(fn, ...) return fn(...) end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
WOW_PROJECT_ID = 1
local bridge = { gameAccountID = 123, characterName = "Bridge Tester", clientProgram = "WoW",
    wowProjectID = 18, factionName = "Horde", isInCurrentRegion = true, isOnline = true }
function BNGetNumFriends() return 1 end
C_BattleNet = { GetGameAccountInfoByID = function() return bridge end,
    GetFriendNumGameAccounts = function() return 1 end, GetFriendGameAccountInfo = function() return bridge end }
local clock, timers = 1000, {}
GetTime = function() return clock end
C_Timer.After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end
assert(loadfile("ZoneCaptureLease.lua"))()
assert(loadfile("SyncRelay.lua"))()
Overlord.RelayEnabled, Overlord.CommunityModeEnabled = true, false
Overlord.InActiveFront, Overlord.InstanceSuspended = true, false
local relayed = {}
function sync:SendToBNet(_, _, data)
    if data:find("|C|" .. X .. ":", 1, true) then relayed[#relayed + 1] = clock - 1000 end
    return true
end
function sync:SendToGroup() return false end
function sync:SendToChannel() return false end
function sync:GetChannelId() return nil end
function UnitClass() return "Warrior", "WARRIOR" end
function UnitGUID() return "Player-1-ABCDEF01" end
local zone = Overlord.Zones:GetZone(X)
Overlord.CaptureLease:BeginLocal(zone)
zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", time(), time()
sync:BroadcastCapture(X, 120)
while true do
    table.sort(timers, function(a, b) return a.at < b.at end)
    local t = timers[1]
    if not t or t.at > 1010 then break end
    table.remove(timers, 1); clock = t.at
    assert(pcall(t.fn))
end
assert(#relayed >= 2, "C was sent " .. #relayed .. " time(s) on the relay: the retry was coalesced away")
for i = 2, #relayed do
    assert(relayed[i] - relayed[1] > 2.0, "Relay retry inside the 2 s coalescing window")
end
-- The other faction only gets the final through BNet bridges: one late relay
-- copy (+20 s) while the zone still holds this capture.
local function runTimersUntil(limit)
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if not t or t.at > limit then break end
        table.remove(timers, 1); clock = t.at
        assert(pcall(t.fn))
    end
end
local beforeLate = #relayed
runTimersUntil(1050)
local late = {}
for i = beforeLate + 1, #relayed do late[#late + 1] = relayed[i] end
assert(#late == 1 and late[1] >= 20,
    "late C relay copy missing, early or repeated: " .. table.concat(late, ","))
-- A recapture in between cancels the late copy of the old final.
timers, relayed = {}, {}
zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", time(), time()
sync:BroadcastCapture(X, 120)
runTimersUntil(clock + 10)
zone.owner, zone.capturedTime = "Horde", time() + 20
local beforeRetake = #relayed
runTimersUntil(clock + 60)
assert(#relayed == beforeRetake, "a late C copy was sent after the zone was retaken")
-- A newer capture of the same zone by us also cancels the old copy.
timers, relayed = {}, {}
zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", time(), time()
sync:BroadcastCapture(X, 120)
runTimersUntil(clock + 10)
zone.capturedTime = time() + 15
beforeRetake = #relayed
runTimersUntil(clock + 60)
assert(#relayed == beforeRetake, "a late C copy was sent for an older capture of the zone")
-- While we already hold another capture, the copy is skipped (a terminal could
-- evict our siege-start ZS from a saturated relay queue).
timers, relayed = {}, {}
zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", time(), time()
sync:BroadcastCapture(X, 120)
runTimersUntil(clock + 10)
local busy
for _, other in ipairs(Overlord.ZoneDatabase or {}) do
    if other ~= zone then busy = other; break end
end
assert(busy, "no second zone on the active front for the busy-capture case")
busy.holdAuthorityLocal, busy.status = true, "in_progress"
beforeRetake = #relayed
runTimersUntil(clock + 60)
assert(#relayed == beforeRetake, "a late C copy was sent while we held another capture")
busy.holdAuthorityLocal, busy.status = nil, "locked"
-- Each relay copy floods the whole relay: with a busy relay queue an ordinary point
-- keeps its immediate copy and retry but skips the late one; a capital always sends it.
local realSummary = Overlord.Relay.GetQueueSummary
Overlord.Relay.GetQueueSummary = function() return { total = 40 } end
timers, relayed = {}, {}
zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", time(), time()
sync:BroadcastCapture(X, 120)
runTimersUntil(clock + 10)
beforeRetake = #relayed
runTimersUntil(clock + 60)
assert(#relayed == beforeRetake, "a late C copy of an ordinary point was sent on a busy relay")
zone.isCapital = true
timers, relayed = {}, {}
zone.capturedTime, zone.updatedAt = time() + 1, time() + 1
local realRequirement = Overlord.CaptureLease.NormalizeCaptureRequirement
Overlord.CaptureLease.NormalizeCaptureRequirement = function() return 480 end
sync:BroadcastCapture(X, 480)
runTimersUntil(clock + 10)
beforeRetake = #relayed
runTimersUntil(clock + 60)
assert(#relayed == beforeRetake + 1, "a capital lost its late C copy on a busy relay")
Overlord.CaptureLease.NormalizeCaptureRequirement = realRequirement
zone.isCapital = nil
-- Catch-up and state lanes (SR pages, VB) do not make the relay hot: with a quiet
-- urgent/bulk queue the late copy of an ordinary point is still sent.
Overlord.Relay.GetQueueSummary = function() return { total = 40, catchup = 24, state = 12 } end
timers, relayed = {}, {}
zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", time() + 2, time() + 2
sync:BroadcastCapture(X, 120)
runTimersUntil(clock + 10)
beforeRetake = #relayed
runTimersUntil(clock + 60)
assert(#relayed == beforeRetake + 1, "catch-up/state backlog suppressed the late copy of an ordinary point")
Overlord.Relay.GetQueueSummary = realSummary
print("Forever zone partial merge: stale entries skipped per entry, guards kept, C relay retried beyond coalescing OK")
