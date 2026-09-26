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

-- Small repairs keep the previous synchronous behaviour.
pairsList = { { dayKey = "d1", siteKey = "fixture" }, { dayKey = "d2", siteKey = "fixture" } }
processed = {}
lb:InvalidateGuildKeepDailyAwardStable()
lb:MaybeAwardGuildKeepDailyWins()
assert(#processed == 2 and #timers == 0 and not lb._gkAwardRepairJob,
    "Small repair should stay synchronous")
print("Forever guild keep awards: sliced late-campaign repair, single job, order, stability and small-pass sync OK")
