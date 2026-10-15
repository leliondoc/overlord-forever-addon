-- The truce after a victory is retired from a date (2.0.2, Zones.TRUCELESS_FROM: the
-- weekly reset of Tuesday 2026-10-20, 08:00 UTC, since 2.0.3). A victory dated from then on opens no
-- truce: the front is the winner's at once, the fallen capital takes its kept stamp at
-- once (victory + 1 s) and the loser may take points back at once; the 6 hours between two
-- victories of a front stay. Before that date nothing changes (every other truce test runs
-- before it). Why a date: on the bench of 86 clients, clients without the truce next to
-- clients that still had it held two maps for 25 minutes after a victory, then a
-- legitimate capture was erased everywhere; all on the same rule, one map. From the same
-- day a client that does not say it runs the rule ("~t0" in its presence) is left out of
-- the map exchange.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.FRONT_TRUCE_ENDED_KEPT = "%s truce over, conquest kept"
Overlord.L.FRONT_CAPITAL_LIBERATED = "Liberated %s (%s)"
Overlord.L.FRONT_VICTORY_TOO_SOON = "%s too soon until %s"
Overlord.L.TOTAL_VICTORY_MSG = Overlord.L.TOTAL_VICTORY_MSG or "%s total victory"
Overlord.L.TOTAL_VICTORY_FRONT_MSG = Overlord.L.TOTAL_VICTORY_FRONT_MSG or "%s total victory on %s"
Overlord.L.VICTORY_FACTION_ALLIANCE = Overlord.L.VICTORY_FACTION_ALLIANCE or "Alliance"
Overlord.L.VICTORY_FACTION_HORDE = Overlord.L.VICTORY_FACTION_HORDE or "Horde"
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local sync, zones = Overlord.Sync, Overlord.Zones
sync.MAP_LAYOUT_VERSION = "0.0.0" -- the stated versions below are about the truce; the 2.0.3 layout floor has its own test
local campaign = Overlord:GetCurrentCampaignStartTs()
local clock = campaign + 200000
time = function() return clock end
GetServerTime = function() return clock end
Overlord.InstanceSuspended = false
Overlord.SaveState = function() end
Overlord.MarkDirty = function() end
local printed = {}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
local sent = {}
for _, name in ipairs({ "Send", "SendToGroup", "SendToChannel", "BroadcastToRelay", "SendWhisper" }) do
    sync[name] = function(_, kind) sent[#sent + 1] = kind end
end
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
local function before(ts)
    for i, zone in ipairs(elwynn.zones) do
        zone.owner, zone.status = zone.id == hordeCap.id and "Horde" or "Alliance", "captured"
        zone.capturedTime, zone.updatedAt = ts - 5000 + i, ts - 5000 + i
    end
end

-- 1. The date: a Tuesday, 08:00 UTC, one week after the reset of 2026-10-13 (2.0.3; 2.0.2
-- had 2026-10-27). One second before it the truce is whole; from it on there is none.
local FROM = zones.TRUCELESS_FROM
assert(FROM == 1792483200 and FROM % 604800 == 460800, "The date is not the weekly reset of 2026-10-20: " .. tostring(FROM))
assert(not zones:IsTruceRetired(FROM - 1) and zones:GetVictoryCooldownSeconds(FROM - 1) == 900,
    "The truce is gone before its date")
assert(zones:IsTruceRetired(FROM) and zones:GetVictoryCooldownSeconds(FROM) == 0, "The truce is still there at its date")
assert(clock < FROM and not zones:IsTruceRetired() and zones:GetVictoryCooldownSeconds() == 900,
    "Test setup: the clock of the test suite is past the date")

-- 2. Control, the truce in force (the date is ahead): fifteen minutes, capital at the
-- moment of the victory.
local V0 = clock
before(V0)
zones:SetVictoryCooldown("elwynn", "Alliance", V0)
zones:ForceSyncFrontToWinner("elwynn", "Alliance", V0, true)
assert(select(1, zones:IsOnVictoryCooldown("elwynn")), "Control: no truce before the date")
assert(hordeCap.capturedTime == V0, "Control: the fallen capital was stamped as kept during the truce")
zones:ClearFrontVictories()

-- 3. The date is behind us. A victory: no truce, at once, in both orders of the two
-- calls a victory makes.
zones.TRUCELESS_FROM = clock - 5000
assert(zones:IsTruceRetired() and zones:GetVictoryCooldownSeconds() == 0)
for _, order in ipairs({ "record-then-repaint", "repaint-then-record" }) do
    zones:ClearFrontVictories()
    clock = clock + 30000
    local V = clock
    before(V)
    printed, sent = {}, {}
    if order == "record-then-repaint" then
        zones:SetVictoryCooldown("elwynn", "Alliance", V)
        zones:ForceSyncFrontToWinner("elwynn", "Alliance", V, true)
    else
        zones:ForceSyncFrontToWinner("elwynn", "Alliance", V, true)
        zones:SetVictoryCooldown("elwynn", "Alliance", V)
    end
    assert(not select(1, zones:IsOnVictoryCooldown("elwynn")), order .. ": a truce opened")
    assert(not select(1, zones:IsFrontOnTruce(branches[1].id, "elwynn")), order .. ": the front is closed to captures")
    assert(hordeCap.owner == "Alliance" and hordeCap.capturedTime == V + 1,
        order .. ": the fallen capital did not take its kept stamp at once: " .. tostring(hordeCap.capturedTime - V))
    for _, zone in ipairs(branches) do
        assert(zone.owner == "Alliance" and zone.capturedTime == V, order .. ": " .. zone.id .. " not at the victory's moment")
    end
    assert(zones:IsKeptCapitalStamp("elwynn", hordeCap), order .. ": the kept stamp is not recognised")
    -- The next 30 s tick only files the victory: same map, no line, nothing sent.
    clock = V + 7
    local mapBefore = {}
    for _, zone in ipairs(elwynn.zones) do mapBefore[zone.id] = tostring(zone.owner) .. "@" .. tostring(zone.capturedTime) end
    zones:TryExpireFrontTruces()
    assert(OverlordDB.frontVictories.elwynn == nil, order .. ": the victory record was kept")
    assert(OverlordDB.frontTruceResetEpoch.elwynn == V, order .. ": the victory was not filed at its own moment: "
        .. tostring(OverlordDB.frontTruceResetEpoch.elwynn))
    for _, zone in ipairs(elwynn.zones) do
        assert(mapBefore[zone.id] == tostring(zone.owner) .. "@" .. tostring(zone.capturedTime),
            order .. ": the tick changed " .. zone.id)
    end
    assert(#printed == 0, order .. ": a truce end was printed although there was no truce: " .. tostring(printed[1]))
    assert(#sent == 0, order .. ": something was sent")
    zones:TryExpireFrontTruces()
    assert(OverlordDB.frontTruceResetEpoch.elwynn == V and hordeCap.capturedTime == V + 1, order .. ": a second tick moved something")
    -- The loser takes a point back two minutes later: nothing repaints it afterwards.
    branches[1].owner, branches[1].capturedTime, branches[1].updatedAt = "Horde", V + 130, V + 130
    clock = V + 200
    zones:TryExpireFrontTruces()
    assert(branches[1].owner == "Horde" and branches[1].capturedTime == V + 130, order .. ": a retaken point was repainted")
    assert(not select(1, zones:IsOnVictoryCooldown("elwynn")))
    -- Six hours between two victories of the front, as before.
    assert(not select(1, zones:IsFrontVictoryAllowed("elwynn", V + 3600)), order .. ": a second victory counts within 6 h")
    assert(not select(1, zones:IsFrontVictoryAllowed("elwynn", V + zones:GetVictorySpacingSeconds() - 300)),
        order .. ": the 6 hours are counted from fifteen minutes before the victory")
    assert(select(1, zones:IsFrontVictoryAllowed("elwynn", V + zones:GetVictorySpacingSeconds() + 1)),
        order .. ": a victory 6 h later is refused")
    -- A truce end stated by a client that still runs the truce (victory + 15 min) is not read.
    clock = V + 905
    sync:OnReceiveFrontTruceEndReset("elwynn:" .. (V + 900), "Older Client", "CHANNEL")
    assert(OverlordDB.frontTruceResetEpoch.elwynn == V and hordeCap.capturedTime == V + 1,
        order .. ": an older client's truce end moved the conquest")
end
print("Truce retired: no truce from the date on, kept stamp at once, 6 h spacing kept, older truce ends not read")

-- 3b. A client that gets the repainted front (a neighbour's answer: capital at V + 1, the
-- points at V) before the victory itself still believes the victory: the kept stamp of a
-- truce-less victory is its own. A truce end's kept stamp still is not a victory.
do
    zones:ClearFrontVictories()
    OverlordDB.frontTruceResetEpoch = {}
    OverlordDB.lastVictoryTimestamp, OverlordDB.lastVictoryFaction, OverlordDB.lastVictoryFrontId = nil, nil, nil
    clock = clock + 30000
    local V = clock
    before(V)
    for _, zone in ipairs(elwynn.zones) do zone.owner, zone.capturedTime, zone.updatedAt = "Alliance", V, V end
    hordeCap.capturedTime, hordeCap.updatedAt = V + 1, V + 1
    assert(zones:IsKeptCapitalStamp("elwynn", hordeCap) and not zones:IsKeptCapitalAfterTruce("elwynn", hordeCap),
        "A truce-less victory's own stamp was read as a truce end's")
    clock = V + 20
    assert(sync:RemoteVictoryProven("elwynn", "Alliance", V), "The victory was not proven on the repainted front")
    sync:OnReceiveTotalVictory("Alliance:" .. V .. ":0:0:elwynn", "Alliance Mate", "CHANNEL")
    assert(tonumber(OverlordDB.lastVictoryTimestamp) == V and OverlordDB.lastVictoryFrontId == "elwynn",
        "A client that got the repainted front first did not believe the victory: " .. tostring(OverlordDB.lastVictoryTimestamp))
    -- The loser takes a point back ten seconds after the victory, inside the minute that
    -- holds back states in flight from before it: no truce, so it is not held back there
    -- (the fixture's capture then stops further on, at its claim check: counted "legacy";
    -- held back by the guard, nothing is counted).
    sync:MarkPostVictorySyncGuard("elwynn")
    local function final(key) return (sync._enemyFinalStats or {})[key] or 0 end
    local legacy0, stale0 = final("C legacy"), final("C stale")
    local q = branches[1]
    sync:OnReceiveCapture(table.concat({ q.id, "Horde Alpha|WARRIOR", "Horde", V + 10, "wQ", "Player-1-0000AAAA", 120 }, ":"),
        "Horde Alpha")
    assert(final("C legacy") == legacy0 + 1, "A loser capture right after a truce-less victory was held back by the guard")
    -- A state from before the victory, in flight, is still held back by it.
    local r = branches[2]
    sync:OnReceiveCapture(table.concat({ r.id, "Horde Beta|WARRIOR", "Horde", V - 30, "wR", "Player-1-0000BBBB", 120 }, ":"),
        "Horde Beta")
    assert(final("C legacy") == legacy0 + 1 and final("C stale") == stale0 and r.owner == "Alliance",
        "A capture from before the victory went past the guard")
    -- Filed at the next tick; after a /reload (the session's delivered list is gone) the
    -- same announcement, replayed by a neighbour, is not believed a second time.
    zones:TryExpireFrontTruces()
    assert(OverlordDB.frontTruceResetEpoch.elwynn == V and OverlordDB.lastVictoryTimestamp == nil, "The victory was not filed")
    assert(zones:IsKeptCapitalAfterTruce("elwynn", hordeCap), "A filed truce-less victory's stamp reads as a new victory")
    -- What map answers replay for 15 min (a client that missed the announcement).
    local fv, fw = zones:GetFiledTrucelessVictory("elwynn")
    assert(fv == V and fw == "Alliance", "The filed truce-less victory is not read from the map: " .. tostring(fv) .. " " .. tostring(fw))
    sync:GetPriv().totalVictoryDeliveredAt = {}
    local printedBefore = #printed
    sync:OnReceiveTotalVictory("Alliance:" .. V .. ":0:0:elwynn", "Alliance Mate", "CHANNEL")
    assert(OverlordDB.lastVictoryTimestamp == nil and #printed == printedBefore,
        "A filed victory was believed again after a reload: " .. tostring(printed[#printed]))
    -- Kept stamp of a truce that ended after the date (victory before it): still kept.
    local E = zones.TRUCELESS_FROM + 600
    hordeCap.capturedTime = E + 1
    for _, zone in ipairs(branches) do zone.capturedTime = E end
    assert(zones:IsKeptCapitalAfterTruce("elwynn", hordeCap), "A truce end just after the date was read as a victory")
end
print("Truce retired: a front repainted before the victory still lets the victory be believed")

-- 3c. A client that learns the victory late (a Battle.net bridge, a battleground): the loser
-- took a point back two minutes after it, legitimately. The victory is still believed and
-- that point is kept; what is dated before the victory is repainted.
do
    zones:ClearFrontVictories()
    OverlordDB.frontTruceResetEpoch = {}
    OverlordDB.lastVictoryTimestamp, OverlordDB.lastVictoryFaction, OverlordDB.lastVictoryFrontId = nil, nil, nil
    clock = clock + 30000
    local V = clock
    before(V)
    for _, zone in ipairs(elwynn.zones) do zone.owner, zone.capturedTime, zone.updatedAt = "Alliance", V, V end
    hordeCap.capturedTime, hordeCap.updatedAt = V + 1, V + 1
    local q, old, retaken = branches[1], branches[2], branches[3]
    q.owner, q.capturedTime, q.updatedAt = "Horde", V + 130, V + 130
    retaken.owner, retaken.capturedTime, retaken.updatedAt = "Alliance", V + 300, V + 300
    old.owner, old.capturedTime, old.updatedAt = "Horde", V - 4000, V - 4000
    clock = V + 1500
    assert(not zones:LocalStateSupportsVictoryTruce("elwynn", "Alliance", V),
        "A point the loser held from before the victory was set aside")
    old.owner, old.capturedTime, old.updatedAt = "Alliance", V, V
    assert(zones:LocalStateSupportsVictoryTruce("elwynn", "Alliance", V),
        "The loser's capture after a truce-less victory kept a late learner from believing it")
    sync:OnReceiveTotalVictory("Alliance:" .. V .. ":0:0:elwynn", "Alliance Friend", "CHANNEL")
    assert(tonumber(OverlordDB.lastVictoryTimestamp) == V, "A late learner did not believe the truce-less victory")
    assert(q.owner == "Horde" and q.capturedTime == V + 130, "The late learner's repaint erased the loser's capture")
    assert(retaken.owner == "Alliance" and retaken.capturedTime == V + 300,
        "The late learner's repaint lowered the date of a point retaken after the victory")
    assert(hordeCap.owner == "Alliance" and hordeCap.capturedTime == V + 1, "The fallen capital lost its stamp")
    -- Before the date the rule is unchanged: inside the truce such a capture is repainted.
    local saved = zones.TRUCELESS_FROM
    zones.TRUCELESS_FROM = V + 1
    zones:ForceSyncFrontToWinner("elwynn", "Alliance", V, true)
    assert(q.owner == "Alliance" and q.capturedTime == V, "With a truce, a capture inside it was kept by the repaint")
    zones.TRUCELESS_FROM = saved
end
print("Truce retired: a late learner believes the victory and keeps the loser's later captures")

-- 3d. The announcement waits (this map cannot prove it yet), then a neighbour's repainted
-- front arrives (capital at V + 1, points at V): the map check files the victory at its own
-- moment, not at the capital's kept stamp (else every late learner moved the dates on).
do
    zones:ClearFrontVictories()
    OverlordDB.frontTruceResetEpoch = {}
    OverlordDB.lastVictoryTimestamp, OverlordDB.lastVictoryFaction, OverlordDB.lastVictoryFrontId = nil, nil, nil
    sync:GetPriv().totalVictoryDeliveredAt, sync:GetPriv().totalVictoryAnnounced = {}, {}
    clock = clock + 30000
    local V = clock
    before(V)
    clock = V + 20
    sync:OnReceiveTotalVictory("Alliance:" .. V .. ":0:0:elwynn", "Alliance Mate", "CHANNEL")
    assert(OverlordDB.lastVictoryTimestamp == nil, "A victory was believed without its proof")
    for _, zone in ipairs(elwynn.zones) do
        zone.owner, zone.status, zone.capturedTime, zone.updatedAt = "Alliance", "captured", V, V
    end
    hordeCap.capturedTime, hordeCap.updatedAt = V + 1, V + 1
    Overlord.InActiveFront = true
    sync:CheckTotalVictoryFromSync()
    Overlord.InActiveFront = false
    assert(tonumber(OverlordDB.lastVictoryTimestamp) == V,
        "The map check filed the victory at another moment: " .. tostring(OverlordDB.lastVictoryTimestamp))
    assert(hordeCap.capturedTime == V + 1 and branches[1].capturedTime == V,
        "The map check moved the dates on: " .. tostring(hordeCap.capturedTime - V) .. ", " .. tostring(branches[1].capturedTime - V))
end
print("Truce retired: a waiting announcement proven by the map is filed at the victory's own moment")

-- 4. A record left behind by another order of events is filed too (never a truce).
zones:ClearFrontVictories()
clock = clock + 30000
local V4 = clock
before(V4)
zones:ForceSyncFrontToWinner("elwynn", "Alliance", V4, true)
OverlordDB.frontTruceResetEpoch.elwynn = V4
zones:SetVictoryCooldown("elwynn", "Alliance", V4)
zones:TryExpireFrontTruces()
assert(OverlordDB.frontVictories.elwynn == nil, "A victory already filed kept its record")

-- 5. The map exchange: from the same day, a neighbour whose presence does not say "~t0"
-- is outside it; before that day nobody is.
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
local frames = 1000
function GetTime() return frames end
C_Timer = { After = function() end, NewTicker = function() return {} end }
function IsInInstance() return false end
function IsInGroup() return false end
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
Overlord.RelayEnabled = true
function sync:GetChannelId() return 5 end
function sync:GetPlayerFullName() return "Abri Bridger" end
function sync:GetBetaBNetTargets() return {} end
sync.OnAddonMessage = function() end
local asked = {}
function sync:SendSyncRequest(opts) asked[#asked + 1] = opts and opts.betaTarget; return true end
local serial = 0
local function presence(name, payload)
    serial = serial + 1
    frames, clock = frames + 130, clock + 130 -- a later presence, by both clocks
    return net:Receive("eu|r" .. serial .. "|" .. time() .. "|*|" .. name .. "|NH|" .. payload, name, "CHANNEL")
end
local OLD = "2.0.1~m1~o1~z0000zz1zzzzzzz~l9~ld~lr~lp6"
-- (2.0.3, layout cut: the updated neighbour also says the map layout of this build; the
-- older one, which says neither, is outside the map exchange from install.)
local NEW = "2.0.2~t0~y" .. net.LocalMapLayout() .. "~m1~o1~z0000zz2zzzzzzz~l9~ld~lr~lp6"
-- Our own presence says the mark, where older readers still find theirs.
local queued
local realQueue = net.Queue
net.Queue = function(_, packet) queued = packet; return true end
net:Send("NH", tostring(Overlord.Version or ""))
net.Queue = realQueue
assert(queued and queued.payload:find("~t0~y" .. net.LocalMapLayout() .. "~m", 1, true) and queued.payload:match("~l9~ld~lr~lp6$"),
    "Our presence does not say the mark: " .. tostring(queued and queued.payload))
-- Before the day: both neighbours are in the exchange.
zones.TRUCELESS_FROM = clock + 100000 -- the day is ahead
asked = {}
presence("Olda Client", OLD)
assert(#asked == 0, "An older client (no map layout) was asked for its map before the day")
presence("Newa Client", NEW)
assert(net:IsOutdatedMapPeer("Olda Client") and not net:IsOutdatedMapPeer("Newa Client"),
    "Before the day: an older client (no map layout) is in the map exchange, or an updated one is out")
assert(not sync:IsOutdatedMapPeer("Olda Client", "2.0.1"), "A 2.0.1 request is refused before the day")
-- From the day on: the one without the mark is out, by its presence or by the version
-- its request states; a stated 2.0.2 is in even before its new presence is heard.
zones.TRUCELESS_FROM = clock - 100 -- the day has come
asked = {}
net.requested, net.requestOrder, net.pullWindow, net.mapDiffs = nil, nil, nil, nil -- as if never asked
presence("Olda Client", OLD)
assert(#asked == 0, "A client that still runs the truce was asked for its map")
presence("Newa Client", NEW)
assert(asked[1] == "Newa Client", "An updated neighbour with another map is no longer asked")
assert(net:IsOutdatedMapPeer("Olda Client"), "A client that still runs the truce stays in the map exchange")
assert(not net:IsOutdatedMapPeer("Newa Client"), "An updated client is left out of the map exchange")
assert(sync:IsOutdatedMapPeer("Olda Client", "2.0.1"), "A 2.0.1 request is still answered after the day")
assert(not sync:IsOutdatedMapPeer("Olda Client", "2.0.2"), "A request that states 2.0.2 is refused on an old presence")
-- A neighbour never heard: it may be a client that still runs the truce, whose map pages
-- would bring its re-dated front in blind. Out too, until its presence says the mark.
assert(net:IsOutdatedMapPeer("Neva Heard") and sync:IsOutdatedMapPeer("Neva Heard"),
    "A neighbour never heard is in the map exchange after the day")
assert(sync:IsOutdatedMapPeer("Neva Heard", "2.0.1"), "A never-heard 2.0.1 request is answered after the day")
presence("Neva Heard", NEW)
assert(not net:IsOutdatedMapPeer("Neva Heard"), "A neighbour whose presence says the mark stays out")
-- The login burst from that day: no broadcast (its answers would come from neighbours not
-- heard yet, and be thrown away); one request per wave to a neighbour heard as updated.
do
    local timers, catchups = {}, 0
    local realAfter, realGate = C_Timer.After, Overlord.IsLoginCaptureSyncGateActive
    local realPeriodic, realHistory, realCatchup = sync.SchedulePeriodicMapCatchup,
        sync.ScheduleLoginLeaderboardHistoryCatchUp, sync.SendLoginCatchupSync
    C_Timer.After = function(delay, fn) timers[#timers + 1] = { delay, fn } end
    Overlord.IsLoginCaptureSyncGateActive = function() return true end
    sync.SchedulePeriodicMapCatchup, sync.ScheduleLoginLeaderboardHistoryCatchUp = function() end, function() end
    sync.SendLoginCatchupSync = function() catchups = catchups + 1 end
    asked = {}
    sync:StartLoginCaptureSyncBurst()
    for _, timer in ipairs(timers) do
        if timer[1] == 0.25 or timer[1] == 2.5 or timer[1] == 6.5 or timer[1] == 12.0 then timer[2]() end
    end
    local targets = {}
    for i = 1, #asked do
        assert(asked[i] ~= nil, "A login wave was broadcast after the day")
        assert(asked[i] ~= "Olda Client", "A login wave asked a client that still runs the truce")
        assert(not targets[asked[i]], "A login wave asked the same neighbour twice")
        targets[asked[i]] = true
    end
    assert(targets["Newa Client"] and targets["Neva Heard"], "The login waves did not ask the updated neighbours")
    assert(catchups == 1, "The last wave lost its point-to-point catch-up")
    -- Drawn at random among the neighbours heard as updated (players logging in together
    -- hear the same presences: the first names of a sorted list served them all).
    local seen = {}
    for _ = 1, 40 do
        local name = sync:PickLoginMapPeer({})
        if name then seen[name] = true end
    end
    assert(seen["Newa Client"] and seen["Neva Heard"] and not seen["Olda Client"],
        "The login neighbour is not drawn at random among the updated ones")
    C_Timer.After, Overlord.IsLoginCaptureSyncGateActive = realAfter, realGate
    sync.SchedulePeriodicMapCatchup, sync.ScheduleLoginLeaderboardHistoryCatchUp, sync.SendLoginCatchupSync =
        realPeriodic, realHistory, realCatchup
end
assert(not sync:IsOutdatedMapPeer("Newa Client", "2.0.1"), "A client that says the mark is refused on its stated version")
-- A presence heard once keeps what it said (an instance, two lost presences): ten minutes
-- later the updated neighbour is still in, the older one still out.
frames = frames + 600
assert(not net:IsOutdatedMapPeer("Newa Client"), "An updated neighbour was put out ten minutes after its presence")
assert(net:IsOutdatedMapPeer("Olda Client"), "An older client came back into the map exchange once its presence aged")
frames = frames - 600
assert(sync:IsOutdatedMapPeer("Olda Client", "1.6.3") and sync:IsOutdatedMapPeer("Newa Client", "1.6.3"),
    "The floor of 1.7.0 moved")
zones.TRUCELESS_FROM = clock + 100000 -- the day is ahead again
assert(not net:IsOutdatedMapPeer("Ever Unknown"), "A neighbour never heard is out of the map exchange before the day")
zones.TRUCELESS_FROM = nil
assert(net:IsOutdatedMapPeer("Olda Client") and not net:IsOutdatedMapPeer("Ever Unknown") and not zones:IsTruceRetired(),
    "nil does not mean never (an older client stays out by its map layout)")
print("Truce retired: from the same day a client that still runs the truce is outside the map exchange")
