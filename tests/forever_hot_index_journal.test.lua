-- Perf audit 2026-10-01: the sliced network index rebuild aborted whenever a kill
-- arrived during the pass, so in big fights it restarted every 5 s and never
-- finished. Kills arriving mid-pass are now journaled and replayed: the pass must
-- complete, and the published index must equal one computed from scratch after
-- every update. Real resets (merges, sanitize) must still abort it.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb, sync = Overlord.Leaderboard, Overlord.Sync

local function upvalue(fn, wanted)
    for i = 1, 200 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
    end
    error("missing upvalue " .. wanted)
end
local function dk(name)
    local key = sync:GetCaptureContributorDedupKey(name) or name
    return key:lower()
end
local function expectedKillIndex()
    local index = {}
    for name, count in pairs(lb.kills) do
        local key = dk(name)
        if count > (index[key] or 0) then index[key] = count end
    end
    return index
end
local function sameIndex(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false, k end end
    for k, v in pairs(b) do if a[k] ~= v then return false, k end end
    return true
end

-- 300 players with kills, indexes built once.
local function playerName(i) return "Fighter Number" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26) % 26) end
for i = 1, 300 do lb:SetPlayerKills(playerName(i), i, true) end
assert(lb:RebuildNetworkHotIndexes(), "Fixture: initial rebuild failed")

-- Force the full path (as after a source change) and run it sliced.
local function slicedRebuild(betweenSlices)
    lb._networkHotKillsSource = nil
    local slice = 0
    local co = coroutine.create(function()
        return lb:RebuildNetworkHotIndexes(function()
            slice = slice + 1
            if slice % 25 == 0 then coroutine.yield() end
        end)
    end)
    local resumes, ok, result = 0
    repeat
        ok, result = coroutine.resume(co)
        assert(ok, tostring(result))
        resumes = resumes + 1
        if coroutine.status(co) ~= "dead" then betweenSlices(resumes) end
    until coroutine.status(co) == "dead"
    return result, resumes
end

-- 1. Kills raised, new players added and AddKills during the pass: still completes.
local nextNew = 1000
local completed, resumes = slicedRebuild(function(step)
    lb:SetPlayerKills(playerName(step), 5000 + step, true)       -- raise an existing row
    lb:SetPlayerKills(playerName(nextNew), 7 + step, true)       -- insert during traversal
    nextNew = nextNew + 1
    lb:AddKills(playerName(150), 1)
end)
assert(resumes > 5, "Fixture: the pass was not sliced")
assert(completed == true, "A kill during the pass aborted the rebuild")
local published = upvalue(lb.RebuildNetworkHotIndexes, "dedupKillMaxIndex")
local same, key = sameIndex(published, expectedKillIndex())
assert(same, "Published kill index differs from a scratch rebuild at " .. tostring(key))

-- 2. Only the meta index cold (new player rows): meta-only pass, kills mid-pass
--    do not abort it, and the score index stays the live, up-to-date one.
lb:MarkMetaDirty()
local metaSlices = 0
local metaCo = coroutine.create(function()
    return lb:RebuildNetworkHotIndexes(function()
        metaSlices = metaSlices + 1
        if metaSlices % 25 == 0 then coroutine.yield() end
    end)
end)
local okMeta, metaResult
repeat
    okMeta, metaResult = coroutine.resume(metaCo)
    assert(okMeta, tostring(metaResult))
    if coroutine.status(metaCo) ~= "dead" then lb:AddKills(playerName(42), 1) end
until coroutine.status(metaCo) == "dead"
assert(metaResult == true and lb._dedupMetaIndex, "Meta-only pass aborted by kills")
assert(upvalue(lb.RebuildNetworkHotIndexes, "dedupKillMaxIndex") == published,
    "Meta-only pass replaced the incrementally maintained kill index")
same, key = sameIndex(published, expectedKillIndex())
assert(same, "Live kill index missed a kill during the meta pass at " .. tostring(key))

-- 1.7.1 CPU: the same race re-dated (v7 LK row, then the dated LR row) patches the
-- hot index entry instead of dropping the whole index; a new race still drops it.
do
    local name = playerName(7)
    local base = (GetServerTime and GetServerTime() or time()) - 5000
    lb:SetPlayerRace(name, "Orc", 2, true, base)
    lb:RebuildDedupMetaIndex()
    local index = lb._dedupMetaIndex
    assert(type(index) == "table" and index[dk(name)] and index[dk(name)].race == "Orc", "fixture: race not indexed")
    lb:SetPlayerRace(name, "Orc", 2, true, base + 100)
    assert(lb._dedupMetaIndex == index, "a re-dated race dropped the hot index")
    assert(index[dk(name)].raceAt >= base + 100, "the index entry was not re-dated")
    assert(lb.playerInfo[name].raceAt == base + 100, "the stored race date did not move")
    lb:SetPlayerRace(name, "Troll", 2, true, base + 200)
    assert(lb._dedupMetaIndex == nil, "a changed race kept a stale index")
    lb:RebuildDedupMetaIndex()
end

-- 3. A pass that stalls more than 5 minutes loses its journal to the next pass
--    and must not publish (it would miss the kills it no longer journals).
local realGetTime = GetTime
local clock = 1000
GetTime = function() return clock end
local stalled = slicedRebuild(function(step)
    if step == 2 then
        clock = clock + 400
        assert(lb:RebuildNetworkHotIndexes(), "Fixture: overlapping pass failed")
    end
end)
GetTime = realGetTime
assert(stalled == false, "A pass whose journal expired was published")

-- 4. A real reset during the pass (duplicate-key merge) still aborts it.
local aborted = slicedRebuild(function(step)
    if step == 2 then lb:MergeDuplicateLeaderboardKeysByDedup() end
end)
assert(aborted == false, "A key merge during the pass was published")
local h = lb:GetHotIndexStats()
assert(h.completed >= 2 and h.metaOnly >= 1 and h.abortedOther >= 2,
    string.format("rebuild counters wrong: %d full, %d meta, %d other", h.completed, h.metaOnly, h.abortedOther))

print("Hot index journal: kills mid-pass replayed, rebuild completes, merges still abort")
