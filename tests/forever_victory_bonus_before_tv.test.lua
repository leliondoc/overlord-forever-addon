-- A fresh VB may overtake its TV on different network routes. It must wait
-- without awarding a bonus, then apply exactly once after the TV proof.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("SyncDomination.lua"))()
assert(loadfile("SyncVictoryBonus.lua"))()

local sync, net = Overlord.Sync, Overlord.BetaNetwork
local frontId = "test_bonus_front"
local victoryTs = time() - 30
Overlord.Fronts.Registry[frontId] = { zones = { a = {} } }
OverlordDB.frontVictories = {}
Overlord.GetDominationTotals = function() return 600, 400 end
net.peers["bridge tester"] = {
    name = "Bridge Tester", at = GetTime(), via = "Bridge Tester", hops = 0,
}
local vb = assert(sync:BuildVictoryBonusPayload({ {
    frontId = frontId, faction = "Alliance", victoryTs = victoryTs,
    rangeMaxTs = victoryTs, bonusSeconds = 20, totalAtApply = 1000,
    campaignEpoch = OverlordDB.lastResetTimestamp,
} }, OverlordDB.lastResetTimestamp, "global"))

local beforeA, beforeH = Overlord:GetDominationVictoryBonusTotals()
sync:OnReceiveVictoryBonus(vb, "Bridge Tester", "BETA")
local pendingA, pendingH = Overlord:GetDominationVictoryBonusTotals()
assert(pendingA == beforeA and pendingH == beforeH,
    "VB before TV earned credit without victory proof")

-- The same path used by production TV records proof and retries queued VB.
sync:RecordVictoryBonusTransportEvidence(
    frontId, "Alliance", victoryTs, "Bridge Tester", "BETA")
local afterA, afterH = Overlord:GetDominationVictoryBonusTotals()
assert(afterA == beforeA + 20 and afterH == beforeH,
    "Validated TV did not replay a pending fresh VB")
sync:OnReceiveVictoryBonus(vb, "Bridge Tester", "BETA")
sync:RecordVictoryBonusTransportEvidence(
    frontId, "Alliance", victoryTs, "Bridge Tester", "BETA")
local duplicateA, duplicateH = Overlord:GetDominationVictoryBonusTotals()
assert(duplicateA == afterA and duplicateH == afterH,
    "Duplicate VB/TV awarded a second victory bonus")

-- TV proof can arrive before the territorial DX that makes totalAtApply
-- plausible. The candidate must survive that failed retry and apply on DX.
local lateFront = "test_late_dx_front"
Overlord.Fronts.Registry[lateFront] = { zones = { a = {} } }
local lateTs = victoryTs + 1
local lateVb = assert(sync:BuildVictoryBonusPayload({ {
    frontId = lateFront, faction = "Horde", victoryTs = lateTs,
    rangeMaxTs = lateTs, bonusSeconds = 200, totalAtApply = 10000,
    campaignEpoch = OverlordDB.lastResetTimestamp,
} }, OverlordDB.lastResetTimestamp, "global"))
Overlord.GetDominationTotals = function() return 0, 0 end
sync:OnReceiveVictoryBonus(lateVb, "Bridge Tester", "BETA")
sync:RecordVictoryBonusTransportEvidence(
    lateFront, "Horde", lateTs, "Bridge Tester", "BETA")
local beforeDxA, beforeDxH = Overlord:GetDominationVictoryBonusTotals()
assert(beforeDxA == afterA and beforeDxH == afterH,
    "VB passed plausibility before territorial DX")
Overlord.GetDominationTotals = function() return 6000, 4000 end
local dxFront = "test_other_territory_front"
Overlord.Fronts.Registry[dxFront] = { zones = { a = {} } }
local dx = assert(sync:BuildDominationPayload(dxFront, {
    Alliance = 6000, Horde = 4000,
}))
sync:OnReceiveDomination(dx, "Bridge Tester", "BETA")
local afterDxA, afterDxH = Overlord:GetDominationVictoryBonusTotals()
assert(afterDxA == afterA and afterDxH == afterH + 200,
    "Another front's DX did not retry the already-proved pending VB")

-- Repeated unproven copies must not refresh the bounded pending lifetime.
local expiredFront = "test_expired_bonus_front"
Overlord.Fronts.Registry[expiredFront] = { zones = { a = {} } }
local expiredTs = victoryTs + 2
local expiredVb = assert(sync:BuildVictoryBonusPayload({ {
    frontId = expiredFront, faction = "Alliance", victoryTs = expiredTs,
    rangeMaxTs = expiredTs, bonusSeconds = 20, totalAtApply = 1000,
    campaignEpoch = OverlordDB.lastResetTimestamp,
} }, OverlordDB.lastResetTimestamp, "global"))
local originalGetTime = GetTime
local clock = originalGetTime()
sync:OnReceiveVictoryBonus(expiredVb, "Bridge Tester", "BETA")
GetTime = function() return clock + 7199 end
sync:OnReceiveVictoryBonus(expiredVb, "Bridge Tester", "BETA")
GetTime = function() return clock + 7201 end
sync:RecordVictoryBonusTransportEvidence(
    expiredFront, "Alliance", expiredTs, "Bridge Tester", "BETA")
local expiredA, expiredH = Overlord:GetDominationVictoryBonusTotals()
assert(expiredA == afterDxA and expiredH == afterDxH,
    "A duplicate VB extended pending storage beyond its two-hour bound")
GetTime = originalGetTime

-- Many DX packets while 64 pending candidates are being sliced must share a
-- single scheduled retry worker. A TV arriving mid-pass still gets its retry.
local originalAfter = C_Timer.After
local callbacks, peakCallbacks = {}, 0
C_Timer.After = function(_, callback)
    callbacks[#callbacks + 1] = callback
    peakCallbacks = math.max(peakCallbacks, #callbacks)
end
local burstTs = victoryTs + 3
for i = 1, 64 do
    local front = "test_burst_bonus_" .. i
    Overlord.Fronts.Registry[front] = { zones = { a = {} } }
    local payload = assert(sync:BuildVictoryBonusPayload({ {
        frontId = front, faction = "Alliance", victoryTs = burstTs,
        rangeMaxTs = burstTs, bonusSeconds = 20, totalAtApply = 1000,
        campaignEpoch = OverlordDB.lastResetTimestamp,
    } }, OverlordDB.lastResetTimestamp, "global"))
    sync:OnReceiveVictoryBonus(payload, "Bridge Tester", "BETA")
end
sync:RetryPendingVictoryBonusesAfterDomination()
for _ = 1, 14 do sync:RetryPendingVictoryBonusesAfterDomination() end
assert(#callbacks == 1 and peakCallbacks == 1,
    "A DX burst spawned multiple pending-VB retry callback chains")
sync:RecordVictoryBonusTransportEvidence(
    "test_burst_bonus_32", "Alliance", burstTs, "Bridge Tester", "BETA")
local steps = 0
while #callbacks > 0 do
    steps = steps + 1
    assert(steps < 200, "Pending-VB retry worker failed to settle")
    local callback = table.remove(callbacks, 1)
    callback()
end
local burstA, burstH = Overlord:GetDominationVictoryBonusTotals()
assert(burstA == afterDxA + 20 and burstH == afterDxH,
    "TV arriving during the sliced retry was lost")
C_Timer.After = originalAfter

print("Forever victory bonus: VB before TV, late DX, dedup, expiry and one retry worker OK")
