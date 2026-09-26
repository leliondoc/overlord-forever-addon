-- A late-campaign guild keep award pass (~28 siege slots x 6 keeps) took ~350 ms
-- in one frame (/ov perf). It must run in bounded, low-priority steps with the same
-- result, and only once at login then once per finished siege (every 6 h).
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local timers = {}
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local clock = 0
debugprofilestop = function() return clock end
local now = 1000
GetTime = function() return now end
Overlord.WaitingForSync = false
Overlord.IsCaptureSyncPending = function() return false end
Overlord.GuildKeepSites = { fixture = {} }
-- lastClosedSlot drives the signature: it only changes when a siege finishes.
local lastClosedSlot, closedToday = "2026092609", false
Overlord.GuildKeep = {
    IsSiegeWindowClosedForToday = function() return closedToday end,
    IsSiegeWindowOpen = function() return not closedToday end,
    GetServerSiegeDayKey = function() return "2026092612" end,
    ComputeServerSiegeDayKey = function() return lastClosedSlot end,
}
lb._guildKeepProofLedgerPrepared = true

local pairsList = {}
for i = 1, 30 do pairsList[i] = { dayKey = "day" .. i, siteKey = "fixture" } end
lb.CollectGuildKeepAwardRepairPairs = function() return pairsList end
local processed, perCall = {}, {}
lb.RunGuildKeepAwardRepairPairs = function(_, _, first, last)
    perCall[#perCall + 1] = last - first + 1
    for i = first, last do processed[#processed + 1] = i end
    clock = clock + 0.6
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

-- Login: one full pass, sliced one step at a time, in order.
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

-- Between sieges: no full pass, neither on a timer nor on keep mutations
-- (received proofs already reconcile their keep in a targeted way).
processed = {}
for _ = 1, 4 do
    now = now + 900
    lb:InvalidateGuildKeepDailyAwardStable()
    lb:MaybeAwardGuildKeepDailyWins()
end
assert(#processed == 0 and #timers == 0, "Full pass reran between two sieges")

-- A siege finishes: exactly one new full pass, and each held keep is awarded one
-- step at a time.
Overlord.GuildKeepSites = { a = {}, b = {}, c = {}, d = {}, e = {}, f = {} }
closedToday, lastClosedSlot = true, "2026092615"
pairsList = {}
for i = 1, 20 do pairsList[i] = { dayKey = "day" .. i, siteKey = "a" } end
local awarded, awardSlices = {}, {}
lb.AwardHeldGuildKeepWinForSite = function(_, siteKey, dayKey)
    awarded[#awarded + 1] = siteKey .. "@" .. dayKey
    return siteKey == "c"
end
now = now + 31
processed = {}
assert(lb:MaybeAwardGuildKeepDailyWins() == false and #awarded == 0)
while #timers > 0 do
    local before = #awarded
    table.remove(timers, 1)()
    awardSlices[#awardSlices + 1] = #awarded - before
end
assert(#processed == 20 and #awarded == 6, "Held keeps not all awarded: " .. #awarded)
for _, count in ipairs(awardSlices) do assert(count <= 1, "Several keeps awarded in one step") end
now = now + 31
processed = {}
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 0, "The same finished siege triggered a second full pass")
lb.AwardHeldGuildKeepWinForSite = function() return false end

-- A siege that finishes during a pass starts one more pass afterwards.
lastClosedSlot = "2026092621"
now = now + 31
processed = {}
lb:MaybeAwardGuildKeepDailyWins()
table.remove(timers, 1)()
lastClosedSlot = "2026092703"
drain()
now = now + 31
lb:MaybeAwardGuildKeepDailyWins()
drain()
assert(#processed == 40, "Siege finished during the pass was not processed: " .. #processed)

-- Small repairs keep the synchronous path.
pairsList = { { dayKey = "d1", siteKey = "fixture" }, { dayKey = "d2", siteKey = "fixture" } }
processed = {}
lb:RequestFullGuildKeepAwardPass()
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 2 and #timers == 0 and not lb._gkAwardRepairJob,
    "Small repair should stay synchronous")

-- Lowest priority: nothing starts or runs in combat; it resumes afterwards.
local inCombat = true
InCombatLockdown = function() return inCombat end
pairsList = {}
for i = 1, 20 do pairsList[i] = { dayKey = "c" .. i, siteKey = "fixture" } end
processed = {}
lb:RequestFullGuildKeepAwardPass()
assert(lb:MaybeAwardGuildKeepDailyWins() == false and not lb._gkAwardRepairJob,
    "A keep award pass started during combat")
inCombat = false
lb:MaybeAwardGuildKeepDailyWins()
assert(lb._gkAwardRepairJob)
inCombat = true
for _ = 1, 3 do table.remove(timers, 1)() end
assert(#processed == 0, "Keep award work ran during combat")
inCombat = false
drain()
assert(#processed == 20 and not lb._gkAwardRepairJob, "Pass did not resume after combat")
InCombatLockdown = nil

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
print("Forever guild keep awards: login + per-siege full passes only, sliced steps, order, combat postponement, deferred GH reconcile OK")
