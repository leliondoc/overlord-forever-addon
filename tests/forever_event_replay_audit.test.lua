-- Late-join event snapshots and idempotent domination bonus across the beta path.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("SyncDomination.lua"))()
assert(loadfile("SyncVictoryBonus.lua"))()

local sync, net = Overlord.Sync, Overlord.BetaNetwork
local campaign = OverlordDB.lastResetTimestamp
local frontId = "loch_modan"
Overlord.Fronts.Registry = Overlord.Fronts.Registry or {}
Overlord.Fronts.Registry[frontId] = { zones = { a = {}, b = {} } }
net.peers["bridge tester"] = {
    name = "Bridge Tester", at = GetTime(), via = "Bridge Tester", hops = 0,
}

-- DX is an absolute per-front snapshot: a late joiner adopts it once, then a
-- repeat cannot add time to the domination bar.
local source = { Alliance = 600, Horde = 400 }
local dx = assert(sync:BuildDominationPayload(frontId, source))
OverlordDB.frontDominationTime = {}
net.context = { origin = "Bridge Tester", hops = 0, kind = "DX", payload = dx }
sync:OnReceiveDomination(dx, "Bridge Tester", "BETA")
local bucket = assert(OverlordDB.frontDominationTime[frontId], "DX replay was lost")
assert(bucket.Alliance == 600 and bucket.Horde == 400, "DX replay changed absolute totals")
sync:OnReceiveDomination(dx, "Bridge Tester", "BETA")
assert(bucket.Alliance == 600 and bucket.Horde == 400, "DX replay added duplicate time")
net.context = nil

-- VB carries a durable event. A late joiner with the victory proof applies it;
-- a duplicate copy leaves the bonus unchanged.
local victoryTs = time() - 100
OverlordDB.frontVictories = {
    [frontId] = { faction = "Alliance", timestamp = victoryTs },
}
local vb = assert(sync:BuildVictoryBonusPayload({ {
    frontId = frontId, faction = "Alliance", victoryTs = victoryTs,
    rangeMaxTs = victoryTs, bonusSeconds = 20, totalAtApply = 1000,
    campaignEpoch = campaign,
} }, campaign, "global"))
Overlord.GetDominationTotals = function() return 600, 400 end
sync:OnReceiveVictoryBonus(vb, "Bridge Tester", "BETA")
local bonusA, bonusH = Overlord:GetDominationVictoryBonusTotals()
assert(bonusA == 20 and bonusH == 0, "VB replay did not restore the bonus")
sync:OnReceiveVictoryBonus(vb, "Bridge Tester", "BETA")
local againA, againH = Overlord:GetDominationVictoryBonusTotals()
assert(againA == 20 and againH == 0, "VB replay applied twice")
assert(sync:BuildTotalVictoryReplayPayload(frontId, OverlordDB.frontVictories[frontId]),
    "Recent TV is missing from late-join replay")

-- Minimal territorial SR includes every live/terminal objective, including
-- neutral outposts that clear an offline observer's stale assault.
local opStates = { "in_progress", "held", "neutral", "neutral", "held", "neutral", "in_progress" }
Overlord.OutpostSites = {}
local outpostRows = {}
for i, status in ipairs(opStates) do
    local key = "outpost" .. i
    Overlord.OutpostSites[key] = {}
    outpostRows[key] = { status = status, ownerGuild = status == "held" and "Empire" or "" }
end
Overlord.Outpost.GetState = function(_, key) return outpostRows[key] end
sync.BuildOutpostPayload = function(_, key) return key end
local queue = {}
sync:AppendOutpostToSrQueue(queue, true)
local seen = {}
for _, row in ipairs(queue) do
    assert(row.type == "OP", "Unexpected outpost replay type")
    seen[row.data] = true
end
for key in pairs(Overlord.OutpostSites) do
    assert(seen[key], "Minimal SR omitted outpost " .. key)
end
assert(#queue == 7, "Minimal SR duplicated or dropped an outpost")

-- Fortress sites participate in this same replay; the retired GK queue is gone.
for i = 1, 5 do
    local key = "keep" .. i
    Overlord.OutpostSites[key] = { isFortress = true }
    outpostRows[key] = { status = i % 2 == 0 and "in_progress" or "held", ownerGuild = "Empire" }
end
queue = {}
sync:AppendOutpostToSrQueue(queue, true)
seen = {}
for _, row in ipairs(queue) do
    assert(row.type == "OP", "Retired fortress replay type emitted")
    seen[row.data] = true
end
for key in pairs(Overlord.OutpostSites) do
    assert(seen[key], "Minimal SR omitted shared site " .. key)
end
assert(#queue == 12, "Minimal SR duplicated or dropped a shared site")
assert(sync.AppendGuildKeepToSrQueue == nil)
assert(net:IsUrgentPacket("TV", "x") and net:IsUrgentPacket("OC", "x"),
    "Terminal events lost priority under bridge pressure")
print("Forever event replay: DX/VB idempotence; TV and twelve shared sites queued")
