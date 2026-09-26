-- A late-campaign guild keep award pass (~28 siege slots x 6 keeps) took ~350 ms
-- in one frame (/ov perf). It must now run in bounded slices with the same result.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local timers = {}
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local clock = 0
debugprofilestop = function() return clock end
Overlord.WaitingForSync = false
Overlord.IsCaptureSyncPending = function() return false end
Overlord.GuildKeepSites = { fixture = {} }
Overlord.GuildKeep = {
    IsSiegeWindowClosedForToday = function() return false end,
    IsSiegeWindowOpen = function() return true end,
    GetServerSiegeDayKey = function() return "2026092612" end,
}
lb._guildKeepProofLedgerPrepared = true

local pairsList = {}
for i = 1, 30 do pairsList[i] = { dayKey = "day" .. i, siteKey = "fixture" } end
lb.CollectGuildKeepAwardRepairPairs = function() return pairsList end
local processed, perCall = {}, {}
lb.RunGuildKeepAwardRepairPairs = function(_, _, first, last)
    perCall[#perCall + 1] = last - first + 1
    for i = first, last do processed[#processed + 1] = i end
    clock = clock + 0.6 -- each pair costs 0.6 ms: two pairs fill the 1 ms slice
    return false
end

local function drain()
    local guard = 0
    while #timers > 0 do
        guard = guard + 1
        assert(guard < 200, "Award repair never finished")
        table.remove(timers, 1)()
    end
end

lb._gkAwardNextCheckAt = nil
assert(lb:MaybeAwardGuildKeepDailyWins() == false)
assert(#processed == 0, "Large repair ran synchronously in the ticker frame")
assert(lb._gkAwardRepairJob, "No sliced repair job started")
assert(lb:MaybeAwardGuildKeepDailyWins() == false and #processed == 0,
    "A second tick restarted the repair while one was running")
drain()
assert(#processed == 30, "Sliced repair skipped pairs: " .. #processed)
for i = 1, 30 do assert(processed[i] == i, "Pairs processed out of order") end
for _, count in ipairs(perCall) do assert(count == 1) end
assert(#perCall == 30 and not lb._gkAwardRepairJob)
assert(lb._gkAwardStable == true and lb._gkAwardStableDayKey == "2026092612",
    "Clean sliced pass did not mark the day stable")

-- A keep mutation during the pass must leave the day unstable for the next tick.
lb:InvalidateGuildKeepDailyAwardStable()
processed = {}
assert(lb:MaybeAwardGuildKeepDailyWins() == false and lb._gkAwardRepairJob)
table.remove(timers, 1)()
lb:InvalidateGuildKeepDailyAwardStable()
drain()
assert(#processed == 30)
assert(lb._gkAwardStable == false and lb._gkAwardNextCheckAt == nil,
    "A mutation during the pass was hidden for 30 s")

-- Closing the day awards each held keep (~10 ms each): one keep per frame too.
Overlord.GuildKeepSites = { a = {}, b = {}, c = {}, d = {}, e = {}, f = {} }
Overlord.GuildKeep.IsSiegeWindowClosedForToday = function() return true end
pairsList = {}
for i = 1, 20 do pairsList[i] = { dayKey = "day" .. i, siteKey = "a" } end
local awarded, awardSlices = {}, {}
lb.AwardHeldGuildKeepWinForSite = function(_, siteKey, dayKey)
    awarded[#awarded + 1] = siteKey .. "@" .. dayKey
    clock = clock + 10
    return siteKey == "c"
end
lb:InvalidateGuildKeepDailyAwardStable()
processed = {}
assert(lb:MaybeAwardGuildKeepDailyWins() == false and #awarded == 0)
while #timers > 0 do
    local before = #awarded
    table.remove(timers, 1)()
    awardSlices[#awardSlices + 1] = #awarded - before
end
assert(#processed == 20 and #awarded == 6, "Held keeps not all awarded: " .. #awarded)
for _, count in ipairs(awardSlices) do assert(count <= 1, "Several keeps awarded in one frame") end
assert(lb._gkAwardStable == false, "A changed award must not mark the day stable")
lb.AwardHeldGuildKeepWinForSite = function() return false end
Overlord.GuildKeep.IsSiegeWindowClosedForToday = function() return false end

-- Small repairs keep the previous synchronous behaviour.
pairsList = { { dayKey = "d1", siteKey = "fixture" }, { dayKey = "d2", siteKey = "fixture" } }
processed = {}
lb:InvalidateGuildKeepDailyAwardStable()
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 2 and #timers == 0 and not lb._gkAwardRepairJob,
    "Small repair should stay synchronous")
-- Sieges are every 6 h: once stable, the full pass only reruns when the siege
-- window changes, on a real mutation, or after the 10-minute safety net.
local now = 1000
GetTime = function() return now end
local windowOpen = true
Overlord.GuildKeep.IsSiegeWindowOpen = function() return windowOpen end
processed = {}
lb:InvalidateGuildKeepDailyAwardStable()
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 2 and lb._gkAwardStable == true, "Stable pass not recorded")
now = now + 31
processed = {}
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 0, "Full pass reran every 30 s without any siege change")
now = now + 31
windowOpen = false
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 2, "Siege end did not rerun the full pass")
now = now + 601
processed = {}
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 2, "Safety net did not rerun the full pass")
-- Receiving daily proofs (GH): reconciliation is deferred out of the network
-- handler, coalesced per keep (oldest slot wins) and runs the same days in order.
OverlordDB.guildKeepCutoffSnapshots = {
    ["2026092403"] = { north = {}, south = {} },
    ["2026092409"] = { north = {} },
    ["2026092415"] = { north = {}, south = {} },
    ["2026092421"] = { south = {} },
}
local expected = {}
local realReconcile = lb.ReconcileGuildKeepDailyAward
lb.ReconcileGuildKeepDailyAward = function(_, siteKey, dayKey)
    expected[#expected + 1] = siteKey .. "@" .. dayKey
    return false
end
lb:ReconcileGuildKeepDailyAwardsFromDay("north", "2026092409")
lb:ReconcileGuildKeepDailyAwardsFromDay("south", "2026092403")
local synchronous = expected
expected = {}
timers = {}
lb:RequestGuildKeepAwardsReconcileFromDay("north", "2026092415")
lb:RequestGuildKeepAwardsReconcileFromDay("south", "2026092403")
lb:RequestGuildKeepAwardsReconcileFromDay("north", "2026092409")
assert(#expected == 0, "Daily proof reconciled inside the network handler")
drain()
assert(table.concat(expected, ",") == table.concat(synchronous, ","),
    "Deferred reconcile differs: " .. table.concat(expected, ",") .. " vs " .. table.concat(synchronous, ","))
assert(not lb._gkReconcileScheduled and not lb._gkReconcilePending)
lb.ReconcileGuildKeepDailyAward = realReconcile
print("Forever guild keep awards: sliced late-campaign repair, single job, order, stability, small-pass sync and siege-driven rechecks, deferred GH reconcile OK")
