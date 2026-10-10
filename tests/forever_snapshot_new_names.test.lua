-- The ranking snapshot (the attested copy every ranking pull and page is built from)
-- takes seconds to build, in slices. Since 1.0.12 a player learnt during the build
-- aborted the whole pass: while new players kept arriving (after a night away, at
-- launch) it never finished, and the client could neither pull nor serve ranking
-- pages ("no local snapshot"). The pass now walks frozen key lists: it finishes,
-- holds every player known when it started, and the newcomers wait for the next pass.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
assert(loadfile("Leaderboard.lua"))()
local lb = Overlord.Leaderboard
lb._storageBound = true
local timers, head = {}, 1
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local function drain(maxSteps)
    local steps = 0
    while head <= #timers and (not maxSteps or steps < maxSteps) do
        local callback = timers[head]
        timers[head], head = false, head + 1
        callback()
        steps = steps + 1
        assert(steps < 100000, "builders failed to converge")
    end
    if head > #timers then timers, head = {}, 1 end
    return steps
end
local function suffix(i)
    return string.char(97 + math.floor(i / 676) % 26, 97 + math.floor(i / 26) % 26, 97 + i % 26)
end
local zoneId
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zoneId = zoneId or zone.id end
end
assert(zoneId, "fixture: no zone in the registry")
local initial, zoned = {}, {}
for i = 1, 600 do
    local name = "Snap Play" .. suffix(i)
    initial[name] = 10 + i
    lb.kills[name] = 10 + i
    lb.captureCount[name] = i % 9 + 1
    if i % 60 == 0 then lb.captures[name] = { zoneId }; zoned[#zoned + 1] = name end
    lb.playerInfo[name] = { class = "PRIEST", faction = i % 2 == 0 and "Alliance" or "Horde", level = 60,
        locale = "enus", guild = "", guildAt = 0 }
end
lb:MarkDirty()
drain()
lb:EnsureNetworkHotIndexesPrepared()
drain()
assert(lb:EnsureNetworkHotIndexesPrepared() == true, "fixture: name index not ready")

local function newcomer(i)
    local name = "Late Comer" .. suffix(i)
    lb:SetPlayerInfo(name, "WARRIOR", "Alliance")
    lb:SetPlayerKills(name, 5 + i, true)
    return name
end
local function build(everySlices)
    local result, arrived, slices = nil, {}, 0
    lb._snapshotDirty = true
    lb:SnapshotCurrentCampaignBeforeReset(function(ok) result = ok end)
    while result == nil do
        local ran = drain(everySlices)
        slices = slices + ran
        if result == nil and everySlices then arrived[#arrived + 1] = newcomer(#arrived + 1000 * everySlices) end
        assert(ran > 0 or result ~= nil, "the snapshot pass stalled")
    end
    return result, arrived, slices
end

-- (1) A quiet pass, for reference.
local ok, _, quietSlices = build()
assert(ok == true, "a quiet snapshot pass failed: " .. tostring(lb._snapshotLastFailure))
assert(quietSlices > 20, "fixture: the pass is not sliced (" .. quietSlices .. " slices)")

-- (2) New players keep arriving, one every 5 slices, for the whole pass.
local arrived
ok, arrived = build(5)
assert(ok == true, "new players arriving during the pass aborted it: " .. tostring(lb._snapshotLastFailure))
assert(#arrived >= 4, "fixture: too few newcomers during the pass: " .. #arrived)
local snapshot = assert(OverlordDB.leaderboardSnapshot)
local seen, rows = {}, 0
for _, name in ipairs(snapshot.killOrder) do
    assert(not seen[name:lower()], "a player holds two ranking slots in the snapshot: " .. name)
    seen[name:lower()] = true
    rows = rows + 1
end
for name, kills in pairs(initial) do
    assert(snapshot.kills[name] == kills, "a player known before the pass is missing or wrong: " .. name
        .. " = " .. tostring(snapshot.kills[name]))
    assert(type(snapshot.playerInfo[name]) == "table" and snapshot.playerInfo[name].class == "PRIEST",
        "a kept player lost its metadata: " .. name)
    assert(snapshot.captureCount[name] == lb.captureCount[name], "a capture count is missing or wrong: " .. name)
end
assert(#zoned >= 5, "fixture: too few players with captured zones")
for _, name in ipairs(zoned) do
    assert(type(snapshot.captures[name]) == "table" and snapshot.captures[name][1] == zoneId,
        "a capturer's zones are missing from the snapshot: " .. name)
end
assert(lb._snapshotDirty == true, "newcomers left out of the pass did not keep the snapshot dirty")
-- (3) The next pass holds the newcomers too.
ok = build()
assert(ok == true)
snapshot = OverlordDB.leaderboardSnapshot
for _, name in ipairs(arrived) do
    assert((snapshot.kills[name] or 0) > 0, "a newcomer never entered the snapshot: " .. name)
end
for name, kills in pairs(initial) do assert(snapshot.kills[name] == kills, "the follow-up pass lost " .. name) end

-- (4) A hard change of the name index (key merge) still ends the pass.
local result
lb._snapshotDirty = true
lb:SnapshotCurrentCampaignBeforeReset(function(done) result = done end)
drain(10)
lb:MergeDuplicateLeaderboardKeysByDedup()
drain()
assert(result == false and tostring(lb._snapshotLastFailure):find("name index", 1, true),
    "a hard index change did not end the pass: " .. tostring(result) .. " / " .. tostring(lb._snapshotLastFailure))
print("Snapshot new names: the pass finishes while players keep arriving, keeps everyone known, newcomers next pass")
