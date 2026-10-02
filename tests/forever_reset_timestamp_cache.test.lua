-- /ov perf (2026-10-02): GetLastResetTimestamp allocated a date("!*t") table on
-- every call (~30 calls/s from the sync handlers, the largest garbage source).
-- Within the cached reset's week it now returns the cache without building a date,
-- and still moves to the next reset as soon as the week is over.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
-- That fixture stubs GetLastResetTimestamp with a fixed date: reload the real one.
assert(loadfile("Core.lua"))()
local WEEK = 7 * 24 * 3600
local clock = 1790100000
local realServerTime, realDate = GetServerTime, date
GetServerTime = function() return clock end
local dateCalls = 0
date = function(...) dateCalls = dateCalls + 1; return realDate(...) end

local first = Overlord:GetLastResetTimestamp()
assert(first > 0 and first <= clock and clock - first < WEEK, "fixture: reset not in the last week")
dateCalls = 0
for _ = 1, 50 do
    clock = clock + 30
    assert(Overlord:GetLastResetTimestamp() == first, "reset moved inside its own week")
end
assert(dateCalls == 0, "date() rebuilt on the hot path: " .. dateCalls .. " calls")

-- Just past the end of that week: the next reset, exactly one week later.
clock = first + WEEK + 5
local nextReset = Overlord:GetLastResetTimestamp()
assert(nextReset == first + WEEK, string.format("next week's reset wrong: first=%d next=%d now=%d time()=%d",
    first, nextReset, clock, time()))
GetServerTime, date = realServerTime, realDate
print("Reset timestamp: cached within its week without date(), next week on time")
