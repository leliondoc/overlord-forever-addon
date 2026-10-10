-- Regression: (1) a ZA whose entries are merely OLDER than local state is skipped
-- per entry instead of failing the whole atomic batch; (3) the C relay retry lands
-- outside the relay's 2 s send coalescing, so the relay really re-sends it.
-- Run from the addon root with Lua 5.1: dofile("tests/forever_zone_partial_merge.test.lua")
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
Overlord.L.SYNC_CAPTURED_ENEMY_BY = "Captured by %s"
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

-- (1c) 1.8.2: a taken capital is an entry like any other, ordered by its capture
-- date. The whole map used to be refused whenever its final view held a taken capital
-- next to a zone of that front not owned by the conqueror (here: a zone we retook,
-- which the sender missed). Two sides that each missed captures of the other then
-- refused every map of the other, on every front (2026-10-10, Durotar: Arathi and
-- everything else stayed apart).
local front = Overlord.Fronts:GetFront("elwynn")
local ac, hc = front.allianceCapitalId, front.hordeCapitalId
for _, z in ipairs(front.zones) do
    if z.id ~= ac and z.id ~= hc then set(z.id, "Horde", EPOCH + (z.id == X and 100 or 3000)) end
end
set(ac, "Horde", EPOCH + 3000)
set(Y, "Horde", EPOCH + 2950) -- news on another front, in the same map
local sweepPages = snapshot()
set(ac, "Alliance", EPOCH + 50)
set(X, "Alliance", EPOCH + 2000)
set(Y, "Alliance", EPOCH + 500)
local victoriesBefore = OverlordDB.frontVictories and OverlordDB.frontVictories.elwynn
deliver(sweepPages)
assert(state(Y) == "Horde@" .. (EPOCH + 2950),
    "a taken capital next to a zone we retook made the whole map be refused: " .. state(Y))
assert(state(ac) == "Horde@" .. (EPOCH + 3000), "the capture of a capital, newer than what we held, was not learnt: " .. state(ac))
assert(state(X) == "Alliance@" .. (EPOCH + 2000), "our newer capture was replaced by the map's older owner: " .. state(X))
assert((OverlordDB.frontVictories and OverlordDB.frontVictories.elwynn) == victoriesBefore,
    "a capital learnt from a map started a victory")
-- The other way round: we hold the taken capital and a zone we retook (what a client
-- that heard the capture live holds). A neighbour's map without either still merges,
-- and our own map is accepted by a neighbour that knows neither.
set(Y, "Horde", EPOCH + 3100)
set(ac, "Alliance", EPOCH + 50); set(X, "Horde", EPOCH + 100)
local neighbourPages = snapshot()                  -- the neighbour: old capital, old X, fresh Y
set(ac, "Horde", EPOCH + 3000); set(X, "Alliance", EPOCH + 2000); set(Y, "Alliance", EPOCH + 500)
local oursPages = snapshot()                       -- ours: taken capital, X retaken, stale Y
deliver(neighbourPages)
assert(state(Y) == "Horde@" .. (EPOCH + 3100), "a client holding a taken capital refused its neighbours' maps: " .. state(Y))
assert(state(ac) == "Horde@" .. (EPOCH + 3000) and state(X) == "Alliance@" .. (EPOCH + 2000),
    "an older map replaced the capital or the zone we hold")
set(ac, "Alliance", EPOCH + 50); set(X, "Horde", EPOCH + 100); set(Y, "Horde", EPOCH + 3100)
deliver(oursPages)
assert(state(ac) == "Horde@" .. (EPOCH + 3000) and state(X) == "Alliance@" .. (EPOCH + 2000)
    and state(Y) == "Horde@" .. (EPOCH + 3100), "the map of a client holding a taken capital was refused by its neighbour")
-- Back to a plain front for the sections below.
set(ac, "Alliance", EPOCH + 50)

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

-- (1d') 1.8.2: a zone nobody holds on our map takes any dated capture, whatever its
-- own last update. We missed a capture; later an assault was given up there (or a
-- neutral entry was merged from someone who missed it too): the zone's last update
-- is newer than the capture, which every map then failed to teach us, for good.
do
    local W = "ash_stardust"
    set(X, "Horde", EPOCH + 1500); set(W, "Horde", EPOCH + 1500)       -- the neighbour: both captured
    local holderPages = snapshot()
    setN(X, EPOCH + 4000); setN(W, EPOCH + 4000)                        -- ours: touched since, nobody holds them
    deliver(holderPages)
    assert(state(X) == "Horde@" .. (EPOCH + 1500), "a capture older than an assault given up on our front was never learnt: " .. state(X))
    assert(state(W) == "Horde@" .. (EPOCH + 1500), "a capture older than an assault given up on another front was never learnt: " .. state(W))
    set(X, "Alliance", EPOCH + 2000); set(W, "Alliance", EPOCH + 500)
end

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

-- (1d'') The same for a late live final, on another front: its date is older than
-- the last update of a zone nobody holds here.
do
    local W = "ash_stardust"
    setN(W, EPOCH + 4000)
    sync:OnReceiveCapture(W .. ":Late Capper|WARRIOR:Horde:" .. (EPOCH + 1600) .. ":wlate:Player-1-0000ABCD:120", "Late Capper")
    assert(state(W) == "Horde@" .. (EPOCH + 1600),
        "a final older than the zone's last update was refused on a zone nobody holds: " .. state(W)
        .. " / " .. tostring(sync.GetEnemyCaptureFinalDiagnostics and sync:GetEnemyCaptureFinalDiagnostics()))
    set(W, "Alliance", EPOCH + 500)
end

-- (1g) 1.8.2: the map of a client from before 1.7.0 is not taken (update required);
-- the same map from an updated neighbour is.
do
    set(Y, "Horde", EPOCH + 2800)
    local pages = snapshot()
    set(Y, "Alliance", EPOCH + 500)
    local realRelay, stats = Overlord.Relay, {}
    Overlord.Relay = { stats = stats, IsOutdatedMapPeer = function(_, name) return name == "Old Client" end }
    for _, page in ipairs(pages) do sync:OnReceiveZoneAll(page, "Old Client") end
    assert(state(Y) == "Alliance@" .. (EPOCH + 500), "the map of a client from before 1.7.0 was taken: " .. state(Y))
    assert(stats.outdatedMaps == #pages, "map pages of a client from before 1.7.0 were not counted")
    deliver(pages)
    assert(state(Y) == "Horde@" .. (EPOCH + 2800), "the same map from an updated neighbour was refused: " .. state(Y))
    Overlord.Relay = realRelay
    set(Y, "Alliance", EPOCH + 500)
end

-- (1f) An orange zone whose stable base differs from the sender's entry (the receiver
-- missed a capture there) no longer rejects the whole map: that zone keeps its wave,
-- every other entry still merges and the map counts as received.
do
    local Z = "elwynn_eastvale"
    local function orange(z)
        local lease = { owner = "Horde", originKey = "bob tester", waveId = "w1",
            base = { owner = "Alliance", status = "captured", capturedTime = EPOCH + 800, updatedAt = EPOCH + 800 } }
        z._remoteCaptureLease, z.status, z.owner, z.previousOwner = lease, "in_progress", "Horde", "Alliance"
        return lease
    end
    for _, senderZ in ipairs({ EPOCH + 1200, EPOCH + 600 }) do -- newer, then older than the base
        set(Z, "Alliance", senderZ); set(Y, "Horde", EPOCH + 2600)
        local pages = snapshot()
        set(Z, "Alliance", EPOCH + 800); set(Y, "Alliance", EPOCH + 500)
        local z = zoneOf(Z)
        local lease = orange(z)
        sync._lastFullZaAt = nil
        deliver(pages)
        assert(state(Y) == "Horde@" .. (EPOCH + 2600),
            "one disputed orange zone rejected the whole map (" .. (senderZ - EPOCH) .. "): " .. state(Y))
        assert(z.status == "in_progress" and z._remoteCaptureLease == lease
            and lease.base.capturedTime == EPOCH + 800, "the disputed orange zone lost its wave")
        assert(sync._lastFullZaAt, "an accepted map was not recorded")
        z._remoteCaptureLease = nil
        set(Z, "Alliance", EPOCH + 800)
    end
    -- 1.8.2: the sender still holds the attacker as owner at an older date (it missed
    -- the capture made since, on which the attacker is now back). That entry is a
    -- stale one: the wave and the capture under it stay. It used to "prove" the
    -- assault impossible (target already the attacker's): the wave was closed and
    -- the zone went back to the attacker at the old date.
    do
        set(Z, "Horde", EPOCH + 300); set(Y, "Horde", EPOCH + 2650)
        local pages = snapshot()
        set(Z, "Alliance", EPOCH + 800); set(Y, "Alliance", EPOCH + 500)
        local z = zoneOf(Z)
        local lease = orange(z)
        deliver(pages)
        assert(state(Y) == "Horde@" .. (EPOCH + 2650), "the rest of the map was not merged: " .. state(Y))
        assert(z.status == "in_progress" and z._remoteCaptureLease == lease
            and lease.base.owner == "Alliance" and lease.base.capturedTime == EPOCH + 800,
            "an older owner in a neighbour's map replaced the capture under a followed assault: "
            .. tostring(z.status) .. " " .. tostring(z.owner) .. "@" .. tostring((z.capturedTime or 0) - EPOCH))
        z._remoteCaptureLease = nil
        set(Z, "Alliance", EPOCH + 800)
    end
    -- The same validated map again within 30 s is not parsed again, but it still
    -- counts as a complete map just received (the pulls on presence wait for it).
    set(Y, "Horde", EPOCH + 2700)
    local again = snapshot()
    set(Y, "Alliance", EPOCH + 500)
    deliver(again)
    assert(state(Y) == "Horde@" .. (EPOCH + 2700), "fixture: the map was not accepted")
    local skippedBefore = Overlord.Relay and Overlord.Relay.stats.zaIdenticalSkipped or 0
    sync._lastFullZaAt = nil
    deliver(again)
    assert(sync._lastFullZaAt, "an identical map received again was not recorded")
    assert(not Overlord.Relay or (Overlord.Relay.stats.zaIdenticalSkipped or 0) == skippedBefore + 1,
        "fixture: the second copy was parsed again")
end
print("Partial merge: a disputed orange zone keeps its wave and the rest of the map merges")

-- (1g) A truce guard refuses one entry (stamped before the front's truce-end epoch,
-- yet fresher than local), not the whole map: the guarded zone keeps its local value,
-- other fronts still merge.
do
    local savedEpochs = OverlordDB.frontTruceResetEpoch
    set(X, "Horde", EPOCH + 300); set(Y, "Horde", EPOCH + 1900)
    local pages = snapshot()
    set(X, "Alliance", EPOCH + 200); set(Y, "Alliance", EPOCH + 500)
    OverlordDB.frontTruceResetEpoch = { elwynn = EPOCH + 1000 }
    deliver(pages)
    assert(state(X) == "Alliance@" .. (EPOCH + 200), "the truce guard let a pre-truce entry in: " .. state(X))
    assert(state(Y) == "Horde@" .. (EPOCH + 1900), "one truce-guarded entry rejected the whole map: " .. state(Y))
    -- Same refused entry on an orange zone (the loser besieging it): nothing of it is
    -- applied through the lease plan; the zone keeps its wave and base.
    set(X, "Horde", EPOCH + 300); set(Y, "Horde", EPOCH + 2100)
    pages = snapshot()
    set(X, "Alliance", EPOCH + 200); set(Y, "Alliance", EPOCH + 500)
    local zx = zoneOf(X)
    local lease = { owner = "Horde", originKey = "bob tester", waveId = "w2",
        base = { owner = "Alliance", status = "captured", capturedTime = EPOCH + 200, updatedAt = EPOCH + 200 } }
    zx._remoteCaptureLease, zx.status, zx.owner, zx.previousOwner = lease, "in_progress", "Horde", "Alliance"
    local commitPlan = Overlord.CaptureLease.CommitRemoteStablePlan
    Overlord.CaptureLease.CommitRemoteStablePlan = function(lease_, plan)
        assert(type(plan) == "table", "an unplanned lease mark reached the commit: " .. tostring(plan))
        return commitPlan(lease_, plan)
    end
    deliver(pages)
    Overlord.CaptureLease.CommitRemoteStablePlan = commitPlan
    assert(zx._remoteCaptureLease == lease and zx.status == "in_progress" and lease.base.capturedTime == EPOCH + 200,
        "a truce-refused entry was applied to an orange zone through the lease plan")
    assert(state(Y) == "Horde@" .. (EPOCH + 2100), "the rest of the map did not merge: " .. state(Y))
    zx._remoteCaptureLease = nil
    set(X, "Alliance", EPOCH + 200)
    OverlordDB.frontTruceResetEpoch = savedEpochs
end
print("Partial merge: a truce-refused entry on an orange zone keeps its wave")

-- (1h) The other per-entry refusals on an orange zone (an unproven N from a peer that
-- never learnt the capture, a flip held while the zone is followed live) keep the
-- wave too, and no longer get the whole map rejected.
do
    local function orangeX()
        local zx = zoneOf(X)
        local lease = { owner = "Horde", originKey = "bob tester", waveId = "w3",
            base = { owner = "Alliance", status = "captured", capturedTime = EPOCH + 2000, updatedAt = EPOCH + 2000 } }
        zx._remoteCaptureLease, zx.status, zx.owner, zx.previousOwner = lease, "in_progress", "Horde", "Alliance"
        return zx, lease
    end
    local commitPlan = Overlord.CaptureLease.CommitRemoteStablePlan
    Overlord.CaptureLease.CommitRemoteStablePlan = function(lease_, plan)
        assert(type(plan) == "table", "an unplanned lease mark reached the commit: " .. tostring(plan))
        return commitPlan(lease_, plan)
    end
    local cases = {
        { "unproven N", function() setN(X, EPOCH + 5000) end, function() end },
        { "held flip", function() set(X, "Alliance", EPOCH + 3000) end, function()
            sync:GetPriv().zaFlipClaims[X] = nil
            sync:NoteLiveZoneTraffic(X)
        end },
    }
    for i, case in ipairs(cases) do
        case[2](); set(Y, "Horde", EPOCH + 2600 + i)
        local pages = snapshot()
        set(X, "Alliance", EPOCH + 2000); set(Y, "Alliance", EPOCH + 500)
        local zx, lease = orangeX()
        case[3]()
        sync._lastFullZaAt = nil
        deliver(pages)
        assert(state(Y) == "Horde@" .. (EPOCH + 2600 + i),
            "an orange zone's " .. case[1] .. " rejected the whole map: " .. state(Y))
        assert(zx._remoteCaptureLease == lease and zx.status == "in_progress"
            and lease.base.owner == "Alliance" and lease.base.capturedTime == EPOCH + 2000,
            "an orange zone's " .. case[1] .. " closed or rebased its wave")
        assert(sync._lastFullZaAt, "the map with an orange zone's " .. case[1] .. " was not recorded")
        assert(i ~= 2 or sync:GetPriv().zaFlipClaims[X], "the flip was not held (vacuous case)")
        zx._remoteCaptureLease = nil
        set(X, "Alliance", EPOCH + 2000)
    end
    sync:GetPriv().zaFlipClaims[X] = nil
    Overlord.CaptureLease.CommitRemoteStablePlan = commitPlan
end
print("Partial merge: an unproven N or a held flip on an orange zone keeps its wave, the map merges")

-- (1i) A flip confirmed by the 5-minute cap arrives in a map the dry run refuses (we are
-- capturing another zone ourselves): the confirmation is kept, and the next accepted
-- map applies the flip at once instead of holding it for another 5 minutes.
do
    set(X, "Horde", EPOCH + 3000); set(Y, "Horde", EPOCH + 2700)
    local pages = snapshot()
    set(X, "Alliance", EPOCH + 2000); set(Y, "Alliance", EPOCH + 500)
    sync:NoteLiveZoneTraffic(X)
    local claims = sync:GetPriv().zaFlipClaims
    claims[X] = { owner = "Horde", ct = EPOCH + 3000, sender = "seed", firstAt = GetTime() - 301, at = GetTime() - 301 }
    local firstAt = claims[X].firstAt
    local zy = zoneOf(Y)
    zy.status, zy.isHolding, zy.holdAuthorityLocal, zy.owner = "in_progress", true, true, "Alliance"
    deliver(pages)
    assert(state(X) == "Alliance@" .. (EPOCH + 2000), "a map refused by the dry run applied a flip: " .. state(X))
    assert(claims[X] and claims[X].firstAt == firstAt, "a refused map consumed the flip's confirmation")
    set(Y, "Alliance", EPOCH + 500)
    zy.isHolding, zy.holdAuthorityLocal = false, nil
    deliver(pages)
    assert(state(X) == "Horde@" .. (EPOCH + 3000), "the confirmed flip was held again: " .. state(X))
    assert(claims[X] == nil, "an applied flip kept its claim")
    set(X, "Alliance", EPOCH + 2000); set(Y, "Alliance", EPOCH + 500)
end
print("Partial merge: a flip confirmation survives a map refused while we capture elsewhere")
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

-- (4) Map content stamp (~z): an orange zone counts by the stable base our map serves
-- for it, and the stamp says exactly what the map (ZA) would serve.
do
    local function b36(n, width)
        local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
        repeat local r = n % 36; out = digits:sub(r + 1, r + 1) .. out; n = math.floor(n / 36) until n == 0
        return string.rep("0", (width or 0) - #out) .. out
    end
    -- Rebuilt from the served map itself: every owned entry of the global snapshot.
    local function served()
        local sum, digest, newest = 0, 0, 0
        for _, page in ipairs(snapshot()) do
            for entry in page:match("|(.*)$"):gmatch("[^,]+") do
                local id, code, _, ct = strsplit(":", entry)
                if code == "A" or code == "H" then
                    ct = math.floor(tonumber(ct) or 0)
                    local text, hash = id .. code .. ct, 5381
                    for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 2147483647 end
                    sum, digest, newest = sum + ct, (digest + hash) % 2147483647, math.max(newest, ct)
                end
            end
        end
        return "~m" .. b36(newest) .. "~o0~z" .. b36(digest, 6) .. b36(sum), newest
    end
    local _, newest = served()
    newest = newest + 1000
    local z = zoneOf(Y)
    z.owner, z.status, z.capturedTime, z.updatedAt = "Horde", "captured", newest, newest
    local calm = served()
    z._remoteCaptureLease = { owner = "Alliance", originKey = "carl tester", waveId = "w9",
        base = { owner = "Horde", status = "captured", capturedTime = newest, updatedAt = newest } }
    z.status, z.owner, z.previousOwner = "in_progress", "Alliance", "Horde"
    assert(served() == calm, "fixture: the served map changed under a siege")
    local pulls = {}
    local realRequest = sync.SendSyncRequest
    sync.SendSyncRequest = function(_, opts) pulls[#pulls + 1] = opts and opts.betaTarget; return true end
    local function presence(who, stamp)
        Overlord.Relay:Receive("global|stamp-" .. who:gsub(" ", "") .. "|" .. time() .. "|*|" .. who
            .. "|NH|1.8.2" .. stamp .. "~l9~ld~lr~lp6", who, "CHANNEL")
    end
    sync._lastFullZaAt = nil
    clock = clock + 10 -- (own stamp cached 5 s)
    local skipped = Overlord.Relay.stats.mapPullsNoNews or 0
    presence("Stamp Same", calm)
    assert(#pulls == 0 and (Overlord.Relay.stats.mapPullsNoNews or 0) == skipped + 1,
        "a siege on a capture changed what our presence says of the map (useless pull)")
    -- Our own presence says the same thing as the map we serve.
    local queued, realQueue = nil, Overlord.Relay.Queue
    Overlord.Relay.Queue = function(_, packet) if packet.kind == "NH" then queued = packet end; return true end
    Overlord.Relay:Send("NH", tostring(Overlord.Version or ""))
    Overlord.Relay.Queue = realQueue
    assert(queued and queued.payload:find(calm .. "~l9~ld~lr~lp6", 1, true),
        "own presence does not say what the served map holds: " .. tostring(queued and queued.payload))
    -- A neighbour that also holds a capture we lack is pulled.
    set("elwynn_goldshire", "Horde", newest + 1)
    local richer = served()
    set("elwynn_goldshire", "Alliance", EPOCH + 2000)
    presence("Stamp Newer", richer)
    assert(pulls[1] == "Stamp Newer", "a neighbour holding a capture we lack was not pulled")
    -- No base under the siege: the overlay is never counted, the zone counts for nothing.
    z._remoteCaptureLease = nil
    z.capturedTime = newest + 500
    clock = clock + 10
    presence("Stamp Base", calm)
    assert(pulls[2] == "Stamp Base", "an in-progress zone without a base counted in the map stamp")
    -- A final shown before the network confirmed it: the map serves the confirmed
    -- base, and the stamp says what the map serves (a neighbour that holds our map
    -- was otherwise pulled again and again for as long as the final stayed unconfirmed).
    z.owner, z.status, z.capturedTime, z.updatedAt = "Alliance", "captured", newest + 900, newest + 900
    z._captureFinalUnattested = true
    z._captureFinalConfirmedBase = { owner = "Horde", status = "captured", capturedTime = newest, updatedAt = newest }
    local confirmed = served()
    clock = clock + 310 -- (own stamp cached 5 s; one pull per neighbour and 5 min)
    local pullsBefore = #pulls
    presence("Stamp Confirmed", confirmed)
    assert(#pulls == pullsBefore, "an unconfirmed final changed what our presence says of the served map")
    -- An owner without a capture date is served at its last update: counted the same.
    z._captureFinalUnattested, z._captureFinalConfirmedBase = nil, nil
    z.owner, z.status, z.capturedTime, z.updatedAt = "Horde", "captured", nil, newest + 40
    local undated = served()
    clock = clock + 10
    presence("Stamp Undated", undated)
    assert(#pulls == pullsBefore, "an owner without a capture date was not counted as the map serves it")
    sync.NoteFullMapReceived(sync, nil) -- a map without a sender (tests, old paths) is noted without error
    sync.SendSyncRequest = realRequest
    z.owner, z.status, z.capturedTime, z.updatedAt, z.previousOwner = "Alliance", "captured", EPOCH + 500, EPOCH + 500, nil
end
print("Map stamp: an orange zone counts by its stable base, never by its overlay")
