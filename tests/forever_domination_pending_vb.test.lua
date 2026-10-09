-- Run from the Forever root (Lua 5.1). Set global FOREVER_HEAD_DIR to a folder holding
-- HEAD copies of Core.lua/SyncDomination.lua/SyncVictoryBonus.lua to run against HEAD.
-- v2 bar: the victory count never depends on DX totals. What remains of the pending queue is
-- the evidence rule: a VB from a verified sender without TV/local proof waits (bounded, 2 h).
-- (1) A VB with proof counts at once, even when totalAtApply is far above any local total.
-- (2) A proof-less VB is kept, applies on its TV proof, and never earns credit before it.
-- (3) Retries never refresh the 2 h pending expiry.
-- (4) Trusted historical replays apply directly and cannot evict a legitimate pending VB.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
local dir = FOREVER_HEAD_DIR
for _, f in ipairs({ "Core.lua", "SyncDomination.lua", "SyncVictoryBonus.lua" }) do
    assert(loadfile((dir and (dir .. "/") or "") .. f))()
end
local sync, net = Overlord.Sync, Overlord.Relay
local server = OverlordDB.lastResetTimestamp + 400000
time = function() return server end
GetServerTime = function() return server end
C_Timer.After = function(_, f) f() end
IsInInstance = function() return false end
Overlord.InstanceSuspended = false; Overlord.InActiveFront = false
Overlord.Fronts.Registry = { f1 = { id = "f1", zones = { { id = "z1" }, { id = "z2" }, { id = "z3" }, { id = "z4" } } } }
Overlord.Fronts.activeFrontId = nil
local function client(name)
    local db = { lastResetTimestamp = OverlordDB.lastResetTimestamp, frontDominationTime = {},
        dominationTime = { Alliance = 0, Horde = 0 }, frontVictories = {},
        dominationVictoryEvents = { byPool = {} }, config = {} }
    return { name = name, db = db }
end
local function use(c) OverlordDB = c.db; sync.GetPlayerFullName = function() return c.name end end
local function peer(name) net.peers[name:lower()] = { name = name, at = GetTime(), via = name, hops = 1 } end
local function wins(c) use(c); return (Overlord:GetDominationVictoryCounts()) end
local function vbFor(ts, total, frontId)
    return assert(sync:BuildVictoryBonusPayload({ { frontId = frontId or "f1", faction = "Alliance", victoryTs = ts,
        rangeMaxTs = ts, bonusSeconds = math.floor(total * 0.02 + 0.5), totalAtApply = total,
        campaignEpoch = OverlordDB.lastResetTimestamp } }, OverlordDB.lastResetTimestamp, "global"))
end

-- (1) local victory record + VB with a huge totalAtApply: counted immediately, no DX needed
local L1 = client("Late One"); use(L1); peer("Emitter One")
OverlordDB.frontVictories.f1 = { faction = "Alliance", timestamp = server - 30 }
sync:OnReceiveVictoryBonus(vbFor(server - 30, 5000000), "Emitter One", "BETA")
assert(wins(L1) == 1, "VB with a large totalAtApply was refused instead of counting one victory")
assert(select(1, Overlord:GetDominationBarScore()) == 51, "One victory must move the bar by exactly 1")

-- (2) proof-less VB waits, then applies once when the TV proof arrives
local L2 = client("Late Two"); use(L2); peer("Emitter One")
local vts = server - 31 -- distinct per scenario: transport evidence is process-wide
sync:OnReceiveVictoryBonus(vbFor(vts, 100000), "Emitter One", "BETA")
assert(wins(L2) == 0, "A VB earned credit before any victory proof")
sync:RecordVictoryBonusTransportEvidence("f1", "Alliance", vts, "Emitter One", "BETA")
assert(wins(L2) == 1, "A proof-less VB was lost instead of applying on its TV proof")

-- (3) retries must not refresh the 2 h pending expiry
local clock = GetTime(); GetTime = function() return clock end
local L3 = client("Late Three"); use(L3); peer("Emitter One")
sync:OnReceiveVictoryBonus(vbFor(server - 32, 50000), "Emitter One", "BETA")
for _ = 1, 40 do clock = clock + 300; sync:RetryPendingVictoryBonusForVictory() end -- 3.3 h
sync:RecordVictoryBonusTransportEvidence("f1", "Alliance", server - 32, "Emitter One", "BETA")
assert(wins(L3) == 0, "Retries refreshed the 2 h pending expiry")

-- (4) trusted historical replays apply directly and cannot evict a legitimate pending VB
clock = clock + 100000
local L4 = client("Late Four"); use(L4); peer("Emitter One")
local legitTs = server - 40
sync:OnReceiveVictoryBonus(vbFor(legitTs, 10000), "Emitter One", "BETA") -- verified sender, no proof yet
-- One front per replay: 1.7 counts one victory per front per 6 h.
for i = 1, 70 do
    clock = clock + 1
    Overlord.Fronts.Registry["h" .. i] = { id = "h" .. i, zones = { { id = "h" .. i .. "z" } } }
    sync:OnReceiveVictoryBonus(vbFor(server - 1000 - i * 901, 90000, "h" .. i), "Emitter One", "BETA")
end
assert(wins(L4) == 70, "Trusted historical VB replays were not all counted")
sync:RecordVictoryBonusTransportEvidence("f1", "Alliance", legitTs, "Emitter One", "BETA")
assert(wins(L4) == 71, "70 historical VBs evicted a legitimate pending VB")

print("Forever domination: DX-independent VB count, proof wait, pending expiry, historical replay OK")
