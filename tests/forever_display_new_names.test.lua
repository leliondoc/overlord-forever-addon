-- The ranking window's view is built in slices (seconds on a large ladder). A player
-- learnt during the build used to abort it, like the snapshot pass: while new players
-- kept arriving the window stayed frozen on its last view, or empty without one. The
-- build now walks frozen key lists: it publishes, keeps every player known when it
-- started, and the newcomers are in the next view.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
assert(loadfile("Leaderboard.lua"))()
local lb = Overlord.Leaderboard
lb._storageBound = true
lb.DISPLAY_CACHE_MIN_REBUILD_SEC = 0
function IsInInstance() return false end
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
local total = { Alliance = 0, Horde = 0 }
local initial = {}
for i = 1, 600 do
    local name = "View Play" .. suffix(i)
    local faction = i % 2 == 0 and "Alliance" or "Horde"
    initial[name] = 10 + i
    total[faction] = total[faction] + 10 + i
    lb.kills[name] = 10 + i
    lb.playerInfo[name] = { class = "PRIEST", faction = faction, level = 60, locale = "enus",
        guild = "View Guild " .. (i % 5), guildAt = time(), guildAuth = true }
end
lb:MarkMetaDirty()
lb:MarkDirty()
drain()
lb:EnsureNetworkHotIndexesPrepared()
drain()
assert(lb:EnsureNetworkHotIndexesPrepared() == true, "fixture: name index not ready")

local arrivals = 0
local function scoredNewcomer()
    arrivals = arrivals + 1
    local name = "Late View" .. suffix(arrivals)
    lb:SetPlayerInfo(name, "WARRIOR", "Alliance")
    lb:SetPlayerKills(name, 5000 + arrivals, true)
    return name
end
local function stranger()
    arrivals = arrivals + 1
    -- Seen on a nameplate, no score: in no view, but a new name for the index.
    lb:SetPlayerInfo("Seen Only" .. suffix(arrivals), "MAGE", "Horde")
end
local function build(everySlices)
    local scored = {}
    assert(lb:StartDisplayCacheBuild(), "the view build did not start")
    local state = lb._displayCacheBuildPending
    local slices = 0
    while lb._displayCacheBuildPending == state do
        local ran = drain(everySlices)
        slices = slices + ran
        if lb._displayCacheBuildPending == state and everySlices then
            if #scored % 2 == 0 then scored[#scored + 1] = scoredNewcomer() else stranger(); scored[#scored + 1] = false end
        end
        assert(ran > 0 or lb._displayCacheBuildPending ~= state, "the view build stalled")
    end
    return scored, slices
end

-- (1) A quiet build, for reference.
local _, quietSlices = build()
local quiet = assert(lb._displayCache)
assert(quiet.ready and #quiet.sortedKills == 600, "a quiet view build did not publish 600 rows")
assert(quietSlices > 20, "fixture: the view build is not sliced (" .. quietSlices .. " slices)")
assert(quiet.alliKills == total.Alliance and quiet.hordeKills == total.Horde, "quiet faction totals are wrong")

-- (2) Players keep arriving, one every 5 slices (scored, then a nameplate stranger).
lb:MarkDirty()
local scored = build(5)
local view = assert(lb._displayCache)
assert(view ~= quiet and view.ready, "players arriving during the build kept the window on its old view")
local seen, withScore = {}, 0
for _, row in ipairs(view.sortedKills) do
    assert(not seen[row.name:lower()], "a player holds two rows of the view: " .. row.name)
    seen[row.name:lower()] = row.kills
end
for name, kills in pairs(initial) do
    assert(seen[name:lower()] == kills, "a player known before the build is missing or wrong: " .. name)
end
for _, name in ipairs(scored) do if name then withScore = withScore + 1 end end
assert(withScore >= 3, "fixture: too few scored newcomers during the build: " .. withScore)
-- Totals never count a player twice nor miss one known at the start.
assert(view.hordeKills == total.Horde, "the Horde total moved although no Horde score arrived: " .. view.hordeKills)
assert(view.alliKills >= total.Alliance, "the Alliance total lost known players: " .. view.alliKills)
-- (3) The next view holds every scored newcomer.
assert(view.epoch ~= lb._displayCacheEpoch, "a view built before the newcomers passes as current")
build()
view = lb._displayCache
seen = {}
for _, row in ipairs(view.sortedKills) do seen[row.name] = row.kills end
local expectedAlliance = total.Alliance
for _, name in ipairs(scored) do
    if name then
        assert((seen[name] or 0) > 0, "a scored newcomer never entered the view: " .. name)
        expectedAlliance = expectedAlliance + seen[name]
    end
end
assert(view.alliKills == expectedAlliance and view.hordeKills == total.Horde,
    "totals after the newcomers are wrong: " .. view.alliKills .. " / " .. view.hordeKills)

-- (4) A hard change of the name index still ends the build without publishing.
lb:MarkDirty()
local before = lb._displayCache
assert(lb:StartDisplayCacheBuild())
drain(10)
lb:MergeDuplicateLeaderboardKeysByDedup()
local tail = drain()
assert(tail <= 3, "a view build went on across a name index reset (" .. tail .. " slices)")
assert(lb._displayCache == before, "a view built across a name index reset was published")
print("Display new names: the view publishes while players keep arriving, keeps everyone known, newcomers next view")
