-- Late-join event snapshots and idempotent victory / wood events across the beta path (v2 bar).
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

-- 1.2.1: the legacy zone-time domination (DX) is gone: no receiver, no producer, no buckets.
assert(sync.OnReceiveDomination == nil and sync.BroadcastDomination == nil
    and sync.BuildDominationPayload == nil, "A legacy DX receiver or producer survived")
assert(Overlord.GetDominationTotals == nil, "The frozen zone-time totals are still loaded")
assert(Overlord:GetDominationBarScore() == 50, "A fresh week is not 50/50")

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
local winsA, winsH = Overlord:GetDominationVictoryCounts()
assert(winsA == 1 and winsH == 0, "VB replay did not restore the victory")
sync:OnReceiveVictoryBonus(vb, "Bridge Tester", "BETA")
local againA, againH = Overlord:GetDominationVictoryBonusTotals()
assert(againA == 20 and againH == 0, "VB replay applied twice")
winsA, winsH = Overlord:GetDominationVictoryCounts()
assert(winsA == 1 and winsH == 0, "VB replay counted the victory twice")
assert(select(1, Overlord:GetDominationBarScore()) == 51, "One Alliance victory must be +1 on the bar")
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
    -- A neutral that clears a stale assault is a dated abandon: an undated neutral
    -- can never override in_progress/held (Outpost:ApplyRemoteState).
    outpostRows[key] = { status = status, ownerGuild = status == "held" and "Empire" or "",
        updatedAt = status == "neutral" and 1790016000 or nil }
end
-- A site that never changed state carries no information and is not replayed.
Overlord.OutpostSites.untouched = {}
outpostRows.untouched = { status = "neutral", ownerGuild = "" }
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
    if key ~= "untouched" then assert(seen[key], "Minimal SR omitted outpost " .. key) end
end
assert(not seen.untouched, "Minimal SR replayed a never-touched neutral site")
assert(#queue == 7, "Minimal SR duplicated or dropped an outpost")
Overlord.OutpostSites.untouched, outpostRows.untouched = nil, nil

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
print("Forever event replay: DX ignored, VB idempotence; TV and twelve shared sites queued")
