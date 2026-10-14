-- The pace of a map difference that answers do not repair (2.0.2).
-- A neighbour whose presence says another map is pulled; if our map does not change
-- (the answer was lost, or it holds a keep capture our ranking cannot accept) the same
-- difference is asked again on a doubling pace: upper branch (it holds something we lack)
-- 1, 2, 4, 8, 16, then every 30 min (was every 10 min for ever); lower branch (it lacks
-- something of ours) after 5 min, then 10, 20, 40, then every 60 min per asker, and on a
-- busy channel the draw of askers thins out with the difference's age (it was about 4
-- pulls every 10 min for ever). A Battle.net friend
-- keeps 10 min, our only way to the other faction's map. 64 differences are remembered
-- (at 16, a seventeenth evicted the oldest, asked again at once). A new difference is
-- still asked at once.
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
C_Timer = { After = function() end, NewTicker = function() return {} end }
function GetTime() return 1000 end
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
function Overlord.Sync:GetPlayerFullName() return "Abri Bridger" end
assert(net.MAP_DIFF_ROWS == 64, "Not 64 differences remembered")

-- Walks one difference: the moments it is asked, the caller stamping each pull as
-- SyncRelay's presence handler does. Returns the gaps between two pulls.
local function gaps(digest, sum, peerDigest, peerSum, friend, pulls)
    local out, last, t = {}, nil, 5000
    while #out < pulls - 1 and t < 5000 + 40000 do
        local row = net:MapDiffDue(digest, sum, peerDigest, peerSum, "Walk Tester", t, friend)
        if row then
            if last then out[#out + 1] = t - last end
            last = t
            row.at, row.tries, row.learned = t, row.tries + 1, row.learnedSeen or row.learned
        end
        t = t + 10
    end
    return out
end
local function same(got, want, what)
    local ok = #got == #want
    for i = 1, #want do ok = ok and math.abs(got[i] - want[i]) <= 10 end
    assert(ok, what .. ": got " .. table.concat(got, ",") .. ", want " .. table.concat(want, ","))
end
-- Upper branch: it holds something we lack (its sum is not lower).
same(gaps(1, 100, 501, 200, false, 8), { 60, 120, 240, 480, 960, 1800, 1800 }, "Upper branch pace")
-- Lower branch: it lacks something of ours (each asker's own pace; enough askers that
-- the draw keeps every client in).
net.MAP_DIFF_ASKERS = 24
same(gaps(1, 100, 777, 50, false, 5), { 600, 1200, 2400, 3600 }, "Lower branch pace")
net.MAP_DIFF_ASKERS = 4
-- Each time the ranking learns the capturer of a claim it had refused (unknown, or under
-- another guild), a slowed difference is asked again within 10 min; otherwise 30.
do
    local generation = 0
    Overlord.Sync.GetLearnedCapturerGeneration = function() return generation end
    local row = net:MapDiffDue(1, 100, 1601, 200, "Learn Tester", 60000)
    row.at, row.tries = 60000, 7
    assert(net:MapDiffDue(1, 100, 1601, 200, "Learn Tester", 60000 + 700) == nil, "A slowed difference came back after 10 min")
    generation = 1
    local again = net:MapDiffDue(1, 100, 1601, 200, "Learn Tester", 60000 + 710)
    assert(again ~= nil, "A difference whose refused capturer the ranking learnt waited 30 min")
    -- Held back by the budget or the origin gap (not sent, so not stamped): still due.
    assert(net:MapDiffDue(1, 100, 1601, 200, "Learn Tester", 60000 + 715) ~= nil, "A pull held back lost the shorter wait")
    again.at, again.tries, again.learned = 60000 + 710, 8, again.learnedSeen
    assert(net:MapDiffDue(1, 100, 1601, 200, "Learn Tester", 60000 + 710 + 700) == nil,
        "The same learnt capturer shortened the wait twice")
    Overlord.Sync.GetLearnedCapturerGeneration = nil
end
-- A Battle.net friend keeps 10 min on both branches.
same(gaps(1, 100, 901, 200, true, 7), { 60, 120, 240, 480, 600, 600 }, "Friend upper pace")
same(gaps(1, 100, 1201, 50, true, 4), { 600, 600, 600 }, "Friend lower pace")
-- The lower branch waits five minutes from first sight.
do
    local first = net:MapDiffDue(1, 100, 3333, 50, "First Tester", 90000)
    assert(first == nil, "A neighbour behind us was pulled at first sight")
    assert(net:MapDiffDue(1, 100, 3333, 50, "First Tester", 90000 + 290) == nil, "Pulled before five minutes")
    assert(net:MapDiffDue(1, 100, 3333, 50, "First Tester", 90000 + 301) ~= nil, "Not pulled after five minutes")
end
-- A new difference goes out at once, behind a slowed one.
do
    local slowed = net:MapDiffDue(1, 100, 4444, 200, "Slow Tester", 100000)
    slowed.at, slowed.tries = 100000, 6
    assert(net:MapDiffDue(1, 100, 4444, 200, "Slow Tester", 100000 + 700) == nil, "The slowed difference came back after 10 min")
    assert(net:MapDiffDue(1, 100, 5555, 200, "New Tester", 100000 + 700) ~= nil, "A new difference waited behind a slowed one")
end
-- Bounded at 64, the one seen longest ago gives way.
net.mapDiffs = nil
for i = 1, 64 + 10 do net:MapDiffDue(1, 100, 10000 + i, 200, "Row Tester", 200000 + i) end
local rows = 0
for key in pairs(net.mapDiffs) do rows = rows + 1 end
assert(rows == 64, "Not bounded at 64: " .. rows)
assert(net.mapDiffs[(10000 + 1 - 1) % 2147483647] == nil and net.mapDiffs[(10000 + 74 - 1) % 2147483647] ~= nil,
    "Eviction did not drop the difference seen longest ago")

-- A busy channel: 80 neighbours hear a neighbour that never catches up (its presence every
-- minute). In its first 20 min about MAP_DIFF_ASKERS of them pull it every 10 min, as
-- before; from the hour on, about a sixth of that (it stayed 4 every 10 min for ever).
do
    local realCount, realName = net.CountDirectPeers, Overlord.Sync.GetPlayerFullName
    net.CountDirectPeers = function() return 80 end
    local tables, current = {}, nil
    Overlord.Sync.GetPlayerFullName = function() return current end
    local early, late, T0 = 0, 0, 300000
    for t = T0, T0 + 3 * 3600, 60 do
        for c = 1, 80 do
            current = "Hearer Number" .. c
            net.mapDiffs = tables[c]
            local row = net:MapDiffDue(1, 100, 6161, 50, "Lagging Neighbour", t)
            tables[c] = net.mapDiffs
            if row then
                row.at, row.tries, row.learned = t, row.tries + 1, row.learnedSeen or row.learned
                if t - T0 < 1200 then early = early + 1 elseif t - T0 >= 3600 then late = late + 1 end
            end
        end
    end
    net.CountDirectPeers, Overlord.Sync.GetPlayerFullName, net.mapDiffs = realCount, realName, nil
    -- 15 min of pulls from minute 5 at about 4 per 10 min; 2 h of tail at about 4 per hour.
    assert(early >= 3 and early <= 14, "The first 20 min were not paced as before: " .. early)
    assert(late <= 16, "A neighbour that never catches up is still pulled about 4 times every 10 min: " .. late)
    print("Map difference pace (80 neighbours): " .. early .. " pulls in the first 20 min, " .. late .. " over the last 2 h")
end
print("Map difference pace: doubling to 30 min (60 min behind), friends 10 min, new differences at once, 64 remembered")
