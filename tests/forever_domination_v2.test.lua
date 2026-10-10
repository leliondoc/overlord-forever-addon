-- Run from the Forever root (Lua 5.1). Weekly domination bar v2 (1.2.0):
--   alliancePct = clamp(50 + (victoriesA - victoriesH), 0, 100)
-- The wood system was removed in 1.2.0: wood messages from old clients never move the bar.
-- Real clients (two per faction, a late joiner, a reload) share one process; the transport is a
-- bus that captures what the production senders emit and hands it, unmodified, to the production
-- receivers of every other client (duplicate copies from several routes included).
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("SyncDomination.lua"))()
assert(loadfile("SyncVictoryBonus.lua"))()
-- Ressources.lua builds its HUD frames at load: give it permissive frame stubs, then restore.
local function frameStub()
    return setmetatable({}, { __index = function(self) return function() return self end end })
end
local savedCreateFrame, savedUIParent = CreateFrame, UIParent
CreateFrame = function() return frameStub() end
UIParent = frameStub()
assert(loadfile("Ressources.lua"))()
CreateFrame, UIParent = savedCreateFrame, savedUIParent

local sync, net = Overlord.Sync, Overlord.Relay
local campaign = OverlordDB.lastResetTimestamp
local S = campaign + 400000
local server, clock = S, 5000
time = function() return server end
GetServerTime = function() return server end
GetTime = function() return clock end
IsInInstance = function() return false end
IsInGroup = function() return false end
IsInRaid = function() return false end
Overlord.InstanceSuspended, Overlord.InActiveFront = false, false
Overlord.IsInitialized = true
Overlord.PrintNotification = function() end
Overlord.PlayAddonSound = function() end
Overlord.SaveState = function() end
Overlord.MarkDirty = function() end
Overlord.L.TOTAL_VICTORY_MSG = "%s won a front"
Overlord.L.VICTORY_FACTION_ALLIANCE, Overlord.L.VICTORY_FACTION_HORDE = "Alliance", "Horde"
C_Timer.After = function(_, fn) fn() end
Overlord.Fronts.Registry = {}
for _, id in ipairs({ "f1", "f2", "f3", "f4" }) do
    Overlord.Fronts.Registry[id] = { id = id, zones = { { id = id .. "a" }, { id = id .. "b" } } }
end
Overlord.Fronts.activeFrontId = nil
Overlord.Fronts.GetFront = function(_, id) return Overlord.Fronts.Registry[id] end
Overlord.Fronts.GetCurrentFront = function() return nil end
-- Truce bookkeeping the TV receiver leans on (the victory record is the local proof).
Overlord.Zones.SetVictoryCooldown = function(_, frontId, faction, ts)
    OverlordDB.frontVictories[frontId] = { faction = faction, timestamp = ts }
end
Overlord.Zones.ForceSyncFrontToWinner = function() end
-- 1.4.2: a TV applies only with local proof (the enemy capital captured at +/- 5 s of its
-- timestamp) or from a group member. The bus carries no C packets: model the capital as
-- captured when a TV reaches a client, as the relayed capital C does in the real network.
local capitals = {}
Overlord.Zones.LocalStateSupportsVictoryTruce = function() return true end
Overlord.Fronts.GetEnemyCapitalId = function(_, _, frontId) return frontId .. "-capital" end
Overlord.Fronts.GetZone = function(_, zoneId) return capitals[zoneId] end

local function newClient(name, faction)
    return { name = name, faction = faction, db = {
        lastResetTimestamp = campaign, frontDominationTime = {}, dominationTime = { Alliance = 0, Horde = 0 },
        frontVictories = {}, dominationVictoryEvents = { byPool = {} }, config = {}, wood = 0 } }
end
local A1, A2 = newClient("Alliance One", "Alliance"), newClient("Alliance Two", "Alliance")
local H1, H2 = newClient("Horde One", "Horde"), newClient("Horde Two", "Horde")
local everyone = { A1, A2, H1, H2 }
local current
local function use(c)
    current = c
    OverlordDB = c.db
    Overlord.PlayerFaction = c.faction
    sync.GetPlayerFullName = function() return c.name end
    return c
end
local function peer(name) net.peers[name:lower()] = { name = name, at = GetTime(), via = name, hops = 1 } end
for _, c in ipairs(everyone) do peer(c.name) end
for _, name in ipairs({ "Late Joiner", "Old Client", "Reloaded Client" }) do peer(name) end

-- Bus ---------------------------------------------------------------------------------
local outbox, history, emitted = {}, {}, { TV = 0, VB = 0, WB = 0, DX = 0 }
local function emit(kind, payload)
    local row = { kind = kind, payload = payload, from = current }
    outbox[#outbox + 1] = row
    history[#history + 1] = row
    emitted[kind] = (emitted[kind] or 0) + 1
end
for _, m in ipairs({ "Send", "SendToGroup", "SendToChannel", "SendToBNetFriends", "RelayToEnemyBridge" }) do
    sync[m] = function(_, kind, payload) emit(kind, payload); return true end
end
sync.BroadcastToRelay = function(_, kind, payload, _, _, _, extras)
    emit(kind, payload)
    for _, extra in ipairs(extras or {}) do emit(extra.type, extra.payload) end
    return true
end
local function receive(to, fromName, kind, payload)
    use(to)
    peer(fromName) -- relay peers must stay fresh as the fake clock advances
    if kind == "VB" then sync:OnReceiveVictoryBonus(payload, fromName, "BETA")
    elseif kind == "WB" then
        assert(sync.OnReceiveDominationBoost == nil, "The wood boost receiver is still loaded")
    elseif kind == "DX" then
        -- 1.2.1: an old client's DX has no receiver any more (not dispatched, not relayed).
        assert(sync.OnReceiveDomination == nil, "The legacy DX receiver is still loaded")
    elseif kind == "TV" then
        -- Each client has its own "already announced" state; the harness shares one process.
        sync:ResetVictoryFlag()
        local _, ts, _, _, fid = strsplit(":", payload)
        capitals[fid .. "-capital"] = { capturedTime = tonumber(ts) }
        sync:OnReceiveTotalVictory(payload, fromName, "BETA")
    end
end
-- Deliver everything emitted so far to every other client. Relays emitted while delivering are
-- delivered too; a converging protocol must go quiet within a few rounds (no ping-pong).
local function pump(recipients)
    local rounds = 0
    while #outbox > 0 do
        rounds = rounds + 1
        assert(rounds <= 4, "Domination messages kept re-emitting (relay loop)")
        local out = outbox
        outbox = {}
        for _, row in ipairs(out) do
            for _, to in ipairs(recipients or everyone) do
                if to ~= row.from then receive(to, row.from.name, row.kind, row.payload) end
            end
        end
    end
end
local function bar(c) use(c); return (Overlord:GetDominationBarScore()) end
local function sameBar(list, expected, label)
    for _, c in ipairs(list) do
        assert(bar(c) == expected, label .. ": " .. c.name .. " shows " .. tostring(bar(c)) .. ", expected " .. expected)
    end
end
local function counts(c)
    use(c)
    local _, _, vA, vH, extra = Overlord:GetDominationBarScore()
    assert(extra == nil, "The bar still returns wood counters")
    return vA, vH
end

-- 0. Fresh week: 50/50 on every client, as fractions too.
sameBar(everyone, 50, "fresh week")
use(A1)
local fa, fh = Overlord:GetDominationDisplayFractions()
assert(fa == 0.5 and fh == 0.5, "Fresh bar is not 50/50")

-- 1. Victories -----------------------------------------------------------------------------
local function victory(c, frontId, faction, ts)
    use(c)
    OverlordDB.frontVictories[frontId] = { faction = faction, timestamp = ts }
    assert(Overlord:TryGrantVictoryDominationBonus(frontId, faction, ts, true) == true,
        "Local victory was not journaled")
    local vb = assert(sync:BuildVictoryBonusPayloadForVictory(frontId, faction, ts), "No VB for the local victory")
    local tv = faction .. ":" .. ts .. ":0:0:" .. frontId
    -- BroadcastTotalVictory fan-out: TV precedes VB on every route; duplicate copies per route.
    emit("TV", tv); emit("VB", vb); emit("TV", tv); emit("VB", vb)
end
-- An old victory that will exist only in the journal (TV replays stop after 2 h); more
-- than 6 h before the next one on f1 (1.7: one victory per front per 6 h).
server = S - 25000
victory(A1, "f1", "Alliance", server)
assert(bar(A1) == 51, "A local victory must move the bar by +1 at once")
pump()
sameBar(everyone, 51, "Alliance victory")
server = S
victory(H2, "f2", "Horde", S - 50)
assert(bar(H2) == 50, "A Horde victory must move the Alliance bar by -1 at once")
pump()
sameBar(everyone, 50, "Horde victory")
victory(A1, "f1", "Alliance", S - 60)
pump()
sameBar(everyone, 51, "second Alliance victory on f1 (6 h elapsed)")
do
    local vA, vH = counts(H1)
    assert(vA == 2 and vH == 1, "Horde client counts " .. vA .. "/" .. vH .. " victories, expected 2/1")
end
-- 1.7.0 spacing from its release day only (a fixed constant shared by every client):
-- victories recorded under 1.6.x earlier that week keep the 15-minute spacing.
local since = sync._VictorySpacingSince
assert(since and since >= 1791331200, "spacing start missing or before the 1.7.0 release day")
assert(sync._VictorySpacingFor(since - 1) == 900, "a 1.6.x victory was re-scored with the 6 h spacing")
assert(sync._VictorySpacingFor(since) == 6 * 3600, "the 6 h spacing does not start at the 1.7.0 release")

-- 1b. Evidence rule: a VB alone (its TV lost) does not count; the TV alone (VB lost) does.
do
    local ts = S - 200
    use(A2)
    local vb = assert(sync:BuildVictoryBonusPayload({ { frontId = "f4", faction = "Alliance", victoryTs = ts,
        rangeMaxTs = ts, bonusSeconds = 50, totalAtApply = 2500, campaignEpoch = campaign } }, campaign, "global"))
    receive(H1, "Alliance Two", "VB", vb)
    assert(bar(H1) == 51, "A VB without any victory proof moved the bar")
    -- (the proof-less VB stays queued: it is not counted until its TV shows up)
    local tsTv = S - 201
    receive(H1, "Alliance Two", "TV", "Alliance:" .. tsTv .. ":0:0:f3") -- TV whose VB was lost
    assert(bar(H1) == 52, "A validated TV alone did not journal its victory")
    local lateVb = assert(sync:BuildVictoryBonusPayload({ { frontId = "f3", faction = "Alliance", victoryTs = tsTv,
        rangeMaxTs = tsTv, bonusSeconds = 50, totalAtApply = 2500, campaignEpoch = campaign } }, campaign, "global"))
    receive(H1, "Alliance Two", "VB", lateVb) -- the late VB merges on the same victory
    assert(bar(H1) == 52, "The late VB counted the TV's victory twice")
    receive(H1, "Alliance Two", "TV", "Alliance:" .. ts .. ":0:0:f4") -- now the pending VB has its proof
    assert(bar(H1) == 53, "The queued VB did not apply once its TV arrived")
    -- Undo for the rest of the scenario: H1 forgets this victory and re-learns the real history.
    H1.db.dominationVictoryEvents = { byPool = {} }
    H1.db.frontVictories = {}
    for _, row in ipairs(history) do
        if row.kind == "VB" or row.kind == "TV" then receive(H1, row.from.name, row.kind, row.payload) end
    end
    assert(bar(H1) == 51, "H1 did not recover its victories from the replayed history")
end

-- 2. No wood: the spend API, the wood set and the WB producer are gone ---------------------
assert(Overlord.Ressources.SpendWoodDominationBoost == nil, "The wood spend is still available")
assert(Overlord.RecordDominationWoodEvent == nil and Overlord.GetDominationWoodCounts == nil,
    "The wood domination set is still loaded")
assert(sync.BroadcastDominationBoost == nil and sync.AppendWoodBoostToSrQueue == nil,
    "A WB producer is still loaded")
sameBar(everyone, 51, "no wood")
assert(emitted.DX == 0, "A DX was emitted (no producer may emit DX any more)")
assert(sync.BroadcastDomination == nil and #outbox == 0, "A DX producer is still loaded")

-- 3. Old (<= 1.1.10) clients -----------------------------------------------------------------
-- Their DX and WB are ignored; their TV/VB count.
do
    local dxSeq = math.floor(S / 120)
    local dx = string.format("500000:300000:%d:f1:%d:Old Client:global:0:0:11", campaign, dxSeq)
    for _, c in ipairs(everyone) do receive(c, "Old Client", "DX", dx) end
    sameBar(everyone, 51, "old client's DX must not move the bar")
    for _, c in ipairs(everyone) do
        assert(next(c.db.frontDominationTime) == nil, c.name .. " merged an old client's DX into its buckets")
    end
    local oldWood = string.format("H:0.6100:%d:wood_resource:_:global:H-OldClient-%d-9999999-4242:0.01", campaign, S)
    for _, c in ipairs(everyone) do receive(c, "Old Client", "WB", oldWood) end
    sameBar(everyone, 51, "old client's WB must not move the bar")
    local ts = S - 40
    local oldVb = string.format("%d:global:A,f3,%d,%d,180000,9000000", campaign, ts, ts)
    for _, c in ipairs(everyone) do
        receive(c, "Old Client", "TV", "Alliance:" .. ts .. ":0:0:f3")
        receive(c, "Old Client", "VB", oldVb)
    end
    sameBar(everyone, 52, "old client's TV+VB (huge totalAtApply)")
end
-- 52 = 50 + (3 - 1)
for _, c in ipairs(everyone) do
    local vA, vH = counts(c)
    assert(vA == 3 and vH == 1, c.name .. " counts " .. vA .. "/" .. vH)
end

-- 4. Duplicates from several senders and routes count once ---------------------------------------
do
    local senders = { "Alliance One", "Horde One", "Old Client" }
    for round = 1, 2 do
        for _, row in ipairs(history) do
            for _, c in ipairs(everyone) do
                if c ~= row.from then receive(c, senders[(round % #senders) + 1], row.kind, row.payload) end
            end
        end
    end
    sameBar(everyone, 52, "history replayed twice from other senders")
end

-- 5. Late joiner, replay paging, reload ------------------------------------------------------------
local LJ = newClient("Late Joiner", "Alliance")
local RELOADED = newClient("Reloaded Client", "Horde")
local function reloadModule() assert(loadfile("SyncVictoryBonus.lua"))() end
local function copy(v)
    if type(v) ~= "table" then return v end
    local r = {}
    for k, x in pairs(v) do r[k] = copy(x) end
    return r
end
-- Production SR responder: real OnSyncRequest, tickers run to completion, replies captured.
local tickers = {}
C_Timer.NewTicker = function(_, fn)
    local t = { fn = fn }
    t.Cancel = function() t.dead = true end
    tickers[#tickers + 1] = t
    return t
end
local function askSR(responder, requester, mode)
    reloadModule() -- per-client module state (the VB SR cache is process-wide in this harness)
    use(responder)
    sync._vbSrCursor = responder.vbCursor
    local whispers = {}
    sync.SendWhisper = function(_, kind, data, target)
        whispers[#whispers + 1] = { kind = kind, data = data, target = target }
        return true
    end
    clock = clock + 1000 -- responder and per-sender cooldowns
    sync:OnSyncRequest(requester.name, "Alliance:" .. Overlord.Version .. "::::" .. mode, "WHISPER")
    for _ = 1, 2000 do
        local live = false
        for _, t in ipairs(tickers) do
            if not t.dead then live = true; t.fn() end
        end
        if not live then break end
    end
    tickers = {}
    responder.vbCursor = sync._vbSrCursor
    local wb = 0
    for _, w in ipairs(whispers) do
        if w.kind == "WB" then wb = wb + 1 end
        if w.kind == "VB" or w.kind == "WB" or w.kind == "TV" then
            receive(requester, responder.name, w.kind, w.data)
        end
    end
    return wb, whispers
end
sameBar({ LJ }, 50, "late joiner before catch-up")
local wb1 = askSR(A1, LJ, "T")
assert(wb1 == 0, "An SR reply still replays wood (WB), got " .. wb1)
do
    local vA, vH = counts(LJ)
    assert(vA == 3 and vH == 1, "VB replay did not restore all four victories on the late joiner")
end
sameBar({ LJ }, 52, "late joiner after one reply")
-- Another responder (other faction, other cursor) only ever adds the same ids: union, no drift.
askSR(H1, LJ, "T"); askSR(H1, LJ, "T")
sameBar({ LJ }, 52, "late joiner after a second responder")
-- A reloaded client: SavedVariables round trip loses nothing, and lost journals heal by replay.
RELOADED.db = copy(H2.db)
sameBar({ RELOADED }, 52, "reloaded client (SavedVariables round trip)")
RELOADED.db.dominationVictoryEvents = { byPool = {} }
sameBar({ RELOADED }, 50, "client that lost its victory journal")
askSR(A2, RELOADED, "T")
sameBar({ RELOADED }, 52, "client that lost its victory journal, healed by SR replay")

-- 6. Previous weeks never count -----------------------------------------------------------------------
do
    local prev = campaign - 604800
    for _, c in ipairs(everyone) do
        receive(c, "Old Client", "VB", string.format("%d:global:H,f4,%d,%d,50,2500", prev, S - 30, S - 30))
        receive(c, "Old Client", "VB", string.format("%d:global:H,f4,%d,%d,50,2500", campaign,
            campaign - 1000, campaign - 1000))
    end
    sameBar(everyone, 52, "previous-week events")
    -- A client that never ran its reset still holds last week's journals: they are ignored.
    local stale = newClient("Stale Client", "Alliance")
    stale.db.dominationVictoryEvents = { byPool = { global = { epoch = prev, rawCount = 1, count = 1, revision = 2,
        byEventId = { ["front-victory-f1-1"] = { faction = "Alliance", frontId = "f1", victoryTs = prev,
            eventId = "front-victory-f1-1" } }, totals = { Alliance = 50, Horde = 0 } } } }
    sameBar({ stale }, 50, "stale previous-week journals")
end

-- 7. Compatibility with clients <= 1.1.10 ------------------------------------------------------------------
do
    -- A victory emitted by a v2 client carries a totalAtApply an old receiver accepts:
    -- bonus == 2% of it and totalAtApply <= their total + tolerance (max(2400 * fronts, 5%)).
    local oldTotal = 1000000
    use(A1)
    outbox = {}
    victory(A1, "f4", "Alliance", S - 30)
    local vb
    for _, row in ipairs(outbox) do if row.kind == "VB" then vb = row.payload end end
    assert(vb, "No VB emitted for the compatibility victory")
    local _, _, body = strsplit(":", vb, 3)
    local _, front, _, _, bonus, total = strsplit(",", body, 6)
    bonus, total = tonumber(bonus), tonumber(total)
    assert(front == "f4" and bonus == math.floor(total * 0.02 + 0.5) and bonus > 0,
        "VB bonusSeconds is not 2% of totalAtApply: " .. body)
    assert(total == 2500, "VB totalAtApply must be the fixed plausible value, got " .. total)
    assert(total <= oldTotal + math.max(4 * 2400, math.floor(oldTotal * 0.05)),
        "VB totalAtApply is implausible for an old receiver")
    outbox = {}
    -- Any client emits the same fixed value (the legacy zone-time is gone).
    local fresh = newClient("Fresh Emitter", "Horde")
    use(fresh)
    assert(Overlord:GetLegacyDominationTotalForVB() == 2500, "Legacy total floor changed")
end

-- 8. Upgrade from 1.1.10/1.1.11: leftover wood ledgers never count.
do
    local upgraded = newClient("Upgraded Client", "Alliance")
    upgraded.db.dominationBoostEvents = {
        [campaign .. ":A:A-Seed-" .. (S - 100) .. "-1-1111"] = 1,
        [campaign .. ":H:H-Seed-" .. (S - 300) .. "-3-3333"] = 1,
    }
    upgraded.db.dominationWoodEvents = { epoch = campaign, ids = { Alliance = { ["A-S-1-1-1"] = S },
        Horde = {} }, count = { Alliance = 1, Horde = 0 }, revision = 1 }
    sameBar({ upgraded }, 50, "leftover wood ledgers")
end

-- 9. A total victory of last week relayed just after the weekly reset is ignored:
-- it must not repaint the new week's front nor journal a victory.
do
    local savedServer, savedStart = server, Overlord.GetCurrentCampaignStartTs
    server = campaign + 60
    Overlord.GetCurrentCampaignStartTs = function() return campaign end
    local fresh = newClient("Fresh Week", "Horde")
    local repainted = false
    local savedForce = Overlord.Zones.ForceSyncFrontToWinner
    Overlord.Zones.ForceSyncFrontToWinner = function() repainted = true end
    receive(fresh, "Alliance Two", "TV", "Alliance:" .. (campaign - 60) .. ":0:0:f2")
    assert(not repainted and fresh.db.frontVictories.f2 == nil,
        "A previous-week total victory was applied after the weekly reset")
    sameBar({ fresh }, 50, "previous-week TV after the reset")
    receive(fresh, "Alliance Two", "TV", "Alliance:" .. (campaign + 30) .. ":0:0:f2")
    assert(fresh.db.frontVictories.f2 ~= nil, "A current-week total victory was refused")
    Overlord.Zones.ForceSyncFrontToWinner = savedForce
    Overlord.GetCurrentCampaignStartTs, server = savedStart, savedServer
end

-- 10. 1.3.6 (live: Alliance 49/38 vs Horde 48/39): a victory the other faction never
-- saw live reaches it through a direct opposite-faction Battle.net friend's state
-- pull, then spreads on that faction's own replay. Only the friend's own faction
-- is sent, and only what that friend has not had yet.
do
    server = S + 3600
    local missedTs = S + 100
    victory(A2, "f4", "Alliance", missedTs)
    pump({ A1, A2 }) -- nobody of the Horde online
    local a1A, a1H = counts(A1)
    local h1A, h1H = counts(H1)
    assert(h1A == a1A - 1 and h1H == a1H, "fixture: the Horde should have missed one victory")

    use(A1)
    sync:AppendVictoryBonusToSrQueue({}, true, false) -- projects A1's journal
    local queue = {}
    local sent = sync:AppendOwnFactionVictoriesForEnemyFriend(queue, "horde one")
    assert(sent > 0 and #queue == sent, "No victory offered to the opposite-faction friend")
    for _, row in ipairs(queue) do
        assert(row.type == "VB", "Unexpected packet kind " .. tostring(row.type))
        local events = row.data:match("^%d+:[^:]+:(.*)$")
        for part in events:gmatch("[^|]+") do
            assert(part:sub(1, 2) == "A,", "A Horde victory was sent to a Horde friend: " .. part)
        end
    end
    assert(sync:AppendOwnFactionVictoriesForEnemyFriend({}, "horde one") == 0,
        "The same journal was resent to the same friend")

    for _, row in ipairs(queue) do receive(H1, "Alliance One", "VB", row.data) end
    local n1A, n1H = counts(H1)
    assert(n1A == a1A and n1H == a1H, "Horde friend still counts " .. n1A .. "/" .. n1H
        .. " after the pull, expected " .. a1A .. "/" .. a1H)

    -- The friend's own faction then learns it through its usual replay.
    use(H1)
    local replay = {}
    sync:AppendVictoryBonusToSrQueue(replay, false, true)
    for _, row in ipairs(replay) do receive(H2, "Horde One", "VB", row.data) end
    sameBar({ A1, A2, H1, H2 }, bar(A1), "cross-faction victory catch-up")

    -- A later victory: the next pull carries only the last packet onward (on f5: f2's
    -- previous victory is under 6 h old).
    server = S + 7200
    Overlord.Fronts.Registry.f5 = { id = "f5", zones = { { id = "f5a" } } }
    victory(A1, "f5", "Alliance", S + 3700)
    pump({ A1, A2 })
    use(A1)
    sync:AppendVictoryBonusToSrQueue({}, true, false)
    local delta = {}
    sync:AppendOwnFactionVictoriesForEnemyFriend(delta, "horde one")
    assert(#delta >= 1 and #delta <= 2, "A new victory resent the whole journal: " .. #delta .. " packets")
    for _, row in ipairs(delta) do receive(H1, "Alliance One", "VB", row.data) end
    assert(bar(H1) == bar(A1), "The new victory did not reach the Horde friend")

    -- Delta rule (audit 1.3.6): resend from the first packet that changed, so a
    -- victory learnt late that lands mid-journal is not skipped.
    local first = sync.FirstChangedVictoryPacket
    assert(first(sync, { "p1", "p2", "p3" }, { "p1", "p2", "p3" }) == nil, "Unchanged journal resent")
    assert(first(sync, { "p1", "p2", "p3" }, { "p1", "p2", "p3x" }) == 3, "New victory: last packet")
    assert(first(sync, { "p1", "p2", "p3" }, { "p1", "p2", "p3", "p4" }) == 4, "Grown journal")
    assert(first(sync, { "p1", "p2", "p3" }, { "p1", "p2x", "p3x" }) == 2,
        "A mid-journal change was not resent from its packet")
    assert(first(sync, { "p1", "p2", "p3" }, { "p1x", "p2", "p3" }) == 1, "First packet change")

    -- A long journal, then an older victory learnt late (it lands mid-journal):
    -- resent from the packet it falls in, not only the last packet (audit 1.3.6).
    local base = S - 300000
    local function pastVictory(frontId, ts)
        Overlord.Fronts.Registry[frontId] = Overlord.Fronts.Registry[frontId]
            or { id = frontId, zones = { { id = frontId .. "a" } } }
        server = ts; victory(A1, frontId, "Alliance", ts); server = S + 7200
    end
    for i = 1, 16 do pastVictory("g" .. i, base + i * 7200) end
    outbox = {}
    use(A1)
    sync:AppendVictoryBonusToSrQueue({}, true, false)
    local full = {}
    sync:AppendOwnFactionVictoriesForEnemyFriend(full, "horde two")
    assert(#full >= 3, "fixture: journal too short to test a mid-journal change (" .. #full .. ")")
    for _, row in ipairs(full) do receive(H2, "Alliance One", "VB", row.data) end
    pastVictory("g8b", base + 8 * 7200 + 3600)
    outbox = {}
    use(A1)
    sync:AppendVictoryBonusToSrQueue({}, true, false)
    local late = {}
    sync:AppendOwnFactionVictoriesForEnemyFriend(late, "horde two")
    assert(#late >= 1 and #late < #full + 1, "Late victory: " .. #late .. " packets of " .. #full)
    local beforeLate = counts(H2)
    local carried = false
    for _, row in ipairs(late) do
        if row.data:find("A,g8b," .. (base + 8 * 7200 + 3600) .. ",", 1, true) then carried = true end
        receive(H2, "Alliance One", "VB", row.data)
    end
    assert(carried, "The late-learnt older victory was not resent")
    local afterLate = counts(H2)
    assert(afterLate == beforeLate + 1, "Horde friend went from " .. beforeLate .. " to " .. afterLate
        .. " Alliance victories, expected exactly one more")
    -- A full direct response already replays everything: only recorded, nothing added.
    pastVictory("g20", base + 20 * 7200)
    outbox = {}
    use(A1)
    sync:AppendVictoryBonusToSrQueue({}, true, false)
    assert(sync:AppendOwnFactionVictoriesForEnemyFriend({}, "horde two", true) == 0)
    assert(sync:AppendOwnFactionVictoriesForEnemyFriend({}, "horde two") == 0,
        "recordOnly did not record what the full response carried")
end

print("Forever domination v2: bar = 50 +/- victories, no wood, relay/BNet convergence, replay, old clients OK")
