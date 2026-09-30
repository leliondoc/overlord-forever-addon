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

local sync, net = Overlord.Sync, Overlord.BetaNetwork
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
sync.BroadcastToCommunity = function(_, kind, payload, _, _, _, extras)
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
-- An hour-old victory that will exist only in the journal (TV replays stop after 2 h).
server = S - 18000
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
sameBar(everyone, 51, "second Alliance victory on f1 (truce elapsed)")
do
    local vA, vH = counts(H1)
    assert(vA == 2 and vH == 1, "Horde client counts " .. vA .. "/" .. vH .. " victories, expected 2/1")
end

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
    sync:OnSyncRequest(requester.name, "Alliance:0.0.1::::" .. mode, "WHISPER")
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

print("Forever domination v2: bar = 50 +/- victories, no wood, relay/BNet convergence, replay, old clients OK")
