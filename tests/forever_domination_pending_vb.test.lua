-- Run from the Forever root (Lua 5.1). Set global FOREVER_HEAD_DIR to a folder holding
-- HEAD copies of Core.lua/SyncDomination.lua/SyncVictoryBonus.lua to run against HEAD.
-- (1) A VB with victory proof but a lagging local DX total is kept and applied on the next DX.
-- (2) Domination seq / plausibility follow GetServerTime(), not a skewed local time().
assert(loadfile("tests/forever_beta_integration.test.lua"))()
local dir = FOREVER_HEAD_DIR
for _, f in ipairs({ "Core.lua", "SyncDomination.lua", "SyncVictoryBonus.lua" }) do
    assert(loadfile((dir and (dir .. "/") or "") .. f))()
end
local sync, net = Overlord.Sync, Overlord.BetaNetwork
local SKEW, server = 0, OverlordDB.lastResetTimestamp + 400000
time = function() return server + SKEW end
GetServerTime = function() return server end
C_Timer.After = function(_, f) f() end
IsInInstance = function() return false end
Overlord.InstanceSuspended = false; Overlord.InActiveFront = false
Overlord.Fronts.Registry = { f1 = { id = "f1", zones = { { id = "z1" }, { id = "z2" }, { id = "z3" }, { id = "z4" } } } }
Overlord.Fronts.activeFrontId = nil
local view = { z1 = "Alliance", z2 = "Alliance", z3 = "Horde", z4 = "Horde" }
Overlord.Fronts.GetZone = function(_, zid) return { owner = view[zid] } end
local function client(name)
    local db = { lastResetTimestamp = OverlordDB.lastResetTimestamp, frontDominationTime = {},
        dominationTime = { Alliance = 0, Horde = 0 }, frontVictories = {},
        dominationVictoryEvents = { byPool = {} }, config = {} }
    return { name = name, db = db }
end
local function use(c) OverlordDB = c.db; sync.GetPlayerFullName = function() return c.name end end
local function peer(name) net.peers[name:lower()] = { name = name, at = GetTime(), via = name, hops = 1 } end
local function dx(from, to)
    use(from); local out = {}
    for id, b in pairs(OverlordDB.frontDominationTime) do out[#out + 1] = sync:BuildDominationPayload(id, b) end
    use(to); peer(from.name)
    for _, p in ipairs(out) do sync:OnReceiveDomination(p, from.name, "BETA") end
end
local function victoryTotal(c) use(c); return (Overlord:GetDominationVictoryBonusTotals()) end

-- (1) emitter total 100000, late client 60000; TV proof first, then VB (2% of 100000)
local E, L = client("Emitter One"), client("Late Two")
local seq = math.floor(server / 120)
use(E); OverlordDB.frontDominationTime.f1 = { Alliance = 60000, Horde = 40000, scoreSeq = seq, scoreSource = "Emitter One" }
use(L); OverlordDB.frontDominationTime.f1 = { Alliance = 36000, Horde = 24000, scoreSeq = seq - 500, scoreSource = "Late Two" }
local vts = server - 30
local vb = assert(sync:BuildVictoryBonusPayload({ { frontId = "f1", faction = "Alliance", victoryTs = vts,
    rangeMaxTs = vts, bonusSeconds = 2000, totalAtApply = 100000,
    campaignEpoch = OverlordDB.lastResetTimestamp } }, OverlordDB.lastResetTimestamp, "global"))
use(L); peer("Emitter One")
sync:RecordVictoryBonusTransportEvidence("f1", "Alliance", vts, "Emitter One", "BETA")
sync:OnReceiveVictoryBonus(vb, "Emitter One", "BETA")
assert(victoryTotal(L) == 0, "VB must not apply while the local DX total is implausibly low")
dx(E, L)
assert(victoryTotal(L) == 2000, "VB with victory proof was lost instead of replayed on the next DX")

-- (2) client whose local clock is +6 min ahead; its snapshot must carry the server-time seq
local S, A = client("Sss Skewed"), client("Aaa Server")
SKEW = 360
use(S); Overlord:AccumulatePassiveDominationForInactiveFronts(120)
assert(S.db.frontDominationTime.f1.scoreSeq == math.floor(server / 120),
    "tick seq follows the skewed local clock instead of GetServerTime")
dx(S, A)
SKEW = 0
local b = A.db.frontDominationTime.f1
assert(b and b.Alliance + b.Horde == 480, "skewed client's DX was rejected by a correct-clock peer")


-- (3) strict: retries must not refresh the 2 h pending expiry (implausible VB, local victory record)
local clock = GetTime(); GetTime = function() return clock end
local function vbFor(ts, total)
    return assert(sync:BuildVictoryBonusPayload({ { frontId = "f1", faction = "Alliance", victoryTs = ts,
        rangeMaxTs = ts, bonusSeconds = math.floor(total * 0.02 + 0.5), totalAtApply = total,
        campaignEpoch = OverlordDB.lastResetTimestamp } }, OverlordDB.lastResetTimestamp, "global"))
end
local function lateClient()
    local c = client("Late Three"); use(c); peer("Emitter One")
    OverlordDB.frontDominationTime.f1 = { Alliance = 6000, Horde = 4000,
        scoreSeq = math.floor(server / 120), scoreSource = "Late Three" }
    return c
end
local C3 = lateClient()
OverlordDB.frontVictories.f1 = { faction = "Alliance", timestamp = server - 30 }
sync:OnReceiveVictoryBonus(vbFor(server - 30, 50000), "Emitter One", "BETA")
for _ = 1, 40 do clock = clock + 300; sync:RetryPendingVictoryBonusesAfterDomination() end -- 3.3 h
OverlordDB.frontDominationTime.f1 = { Alliance = 30000, Horde = 20000,
    scoreSeq = math.floor(server / 120), scoreSource = "Late Three" }
sync:RetryPendingVictoryBonusesAfterDomination()
assert(victoryTotal(C3) == 0, "DX-triggered retries refreshed the 2 h pending expiry")

-- (4) strict: historical-only implausible VBs are never queued, so they cannot evict a legit pending VB
clock = clock + 100000
local C4 = lateClient()
local legitTs = server - 40
sync:OnReceiveVictoryBonus(vbFor(legitTs, 10000), "Emitter One", "BETA") -- verified sender, no proof yet
for i = 1, 70 do
    clock = clock + 1
    sync:OnReceiveVictoryBonus(vbFor(server - 1000 - i * 901, 90000), "Emitter One", "BETA")
end
sync:RecordVictoryBonusTransportEvidence("f1", "Alliance", legitTs, "Emitter One", "BETA")
local applied = false
for _, ev in pairs(OverlordDB.dominationVictoryEvents.byPool.global.rawById or {}) do
    if ev.victoryTs == legitTs then applied = true end
end
assert(applied, "70 historical implausible VBs evicted a legitimate pending VB")

print("Forever domination: pending VB on implausible total, expiry, no historical queueing, server-time seq OK")
