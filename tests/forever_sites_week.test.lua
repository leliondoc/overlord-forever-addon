-- Leaderboard "Capturers and rivalries" view: read only from the signed keep and
-- outpost capture ledger (no packet). Capturers are counted per character, keeps and
-- outposts apart; a rivalry is two successive captures of one site by guilds of
-- opposite factions ("A took from B"), never a same-faction change.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now = 1790018000
function time() return now end
function GetServerTime() return now end
function GetTime() return now - 1790016000 end
function GetGuildInfo() return "Lions" end
function IsInInstance() return false end
function UnitFactionGroup() return "Alliance" end
Overlord.PlayerFaction = "Alliance"
Overlord.PrintNotification = function() end
OverlordDB = { lastResetTimestamp = 1789527600, config = {}, outposts = {} }
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Outpost.lua"))()
local lb = Overlord.Leaderboard

local keep, outpost
for key, site in pairs(Overlord.OutpostSites) do
    if site.isFortress == true then
        if not keep or key < keep then keep = key end
    elseif not outpost or key < outpost then
        outpost = key
    end
end
assert(keep and outpost, "Need one keep and one outpost site")

local function take(site, guild, faction, ago, capturer)
    local ok = lb:RecordOutpostCapture(site, guild, faction, now - ago, "global", capturer)
    assert(ok, "Capture refused: " .. site .. " " .. guild)
end
take(keep, "Lions", "Alliance", 5000, "Arthas-Realm")
take(keep, "Orcs", "Horde", 4000, "Thrall-Realm")
take(keep, "Lions", "Alliance", 3000, "Arthas-Realm")
take(outpost, "Orcs", "Horde", 2000, "Thrall-Realm")
take(outpost, "Wolves", "Horde", 1000, "Rexxar-Realm")

local stats = lb:GetOutpostWeeklyStats()
local c = stats.capturers
assert(#c == 3, "Three capturers expected, got " .. #c)
-- Same total (2): more keeps first, then the name.
assert(c[1].name == "Arthas-Realm" and c[1].keeps == 2 and c[1].outposts == 0)
assert(c[2].name == "Thrall-Realm" and c[2].keeps == 1 and c[2].outposts == 1)
assert(c[3].name == "Rexxar-Realm" and c[3].total == 1)

local r = stats.rivalries
assert(#r == 2, "Two rivalries expected (Orcs > Lions, Lions > Orcs), got " .. #r)
local seen = {}
for _, row in ipairs(r) do seen[row.taker .. ">" .. row.victim] = row.count end
assert(seen["Orcs>Lions"] == 1 and seen["Lions>Orcs"] == 1, "Wrong rivalries")
assert(seen["Wolves>Orcs"] == nil, "A same-faction change is not a rivalry")

-- Cached until the ledger changes, then rebuilt, at most every 3 s (a catch-up
-- burst keeps the previous view for a moment instead of rebuilding per event).
assert(lb:GetOutpostWeeklyStats() == stats, "Stats should be cached")
take(keep, "Orcs", "Horde", 500, "Thrall-Realm")
local held, late = lb:GetOutpostWeeklyStats()
assert(held == stats and late == true, "A rebuild within 3 s keeps the previous stats and says so")
-- 2.6.0: past the interval the rebuild runs in slices (C_Timer.After(0) steps); the view
-- keeps the previous stats until it is done, then reads the new ones.
local pending = {}
C_Timer.After = function(_, fn) pending[#pending + 1] = fn end
local function runTimers()
    for _ = 1, 1000 do
        local fns = pending
        pending = {}
        if #fns == 0 then return end
        for _, fn in ipairs(fns) do fn() end
    end
    error("the sliced rebuild never ended")
end
now = now + 5
local waiting, isLate = lb:GetOutpostWeeklyStats()
assert(waiting == stats and isLate == true, "A rebuild past the interval runs in slices, previous stats meanwhile")
assert(lb:GetOutpostWeeklyStats() == stats, "A second read while the rebuild runs starts no other one")
runTimers()
local after = lb:GetOutpostWeeklyStats()
assert(after ~= stats and after.rivalries[1].taker == "Orcs" and after.rivalries[1].count == 2,
    "A new capture must update the rivalries")
assert(after.capturers[1].name == "Thrall-Realm" and after.capturers[1].total == 3)

-- Same content as a build in one block, sliced to one operation per slice.
do
    local whole = lb:BuildOutpostWeeklyStats(lb:GetOutpostCaptureCountsTable())
    local slices = 0
    local co = coroutine.create(function()
        return lb:BuildOutpostWeeklyStats(lb:GetOutpostCaptureCountsTable(), function()
            slices = slices + 1
            coroutine.yield()
        end)
    end)
    local ok, sliced
    repeat ok, sliced = coroutine.resume(co); assert(ok, sliced) until coroutine.status(co) == "dead"
    assert(slices > 3, "the build did not yield")
    assert(#sliced.capturers == #whole.capturers and #sliced.rivalries == #whole.rivalries, "sliced build differs")
    for i, cap in ipairs(whole.capturers) do
        local s = sliced.capturers[i]
        assert(s.name == cap.name and s.total == cap.total and s.keeps == cap.keeps, "sliced capturers differ")
    end
    for i, riv in ipairs(whole.rivalries) do
        local s = sliced.rivalries[i]
        assert(s.taker == riv.taker and s.victim == riv.victim and s.count == riv.count, "sliced rivalries differ")
    end
end

-- A capture recorded while a rebuild runs: published with the stamp of its start, so the
-- next read past the interval builds again and shows it.
do
    take(outpost, "Lions", "Alliance", 300, "Arthas-Realm")
    now = now + 5
    local _, lateAgain = lb:GetOutpostWeeklyStats()
    assert(lateAgain == true, "a stale cache was not rebuilt")
    take(keep, "Wolves", "Horde", 200, "Rexxar-Realm")
    runTimers()
    now = now + 5
    local _, still = lb:GetOutpostWeeklyStats()
    assert(still == true, "a capture heard during the rebuild was taken as already counted")
    runTimers()
    local final = lb:GetOutpostWeeklyStats()
    local rexxar
    for _, cap in ipairs(final.capturers) do if cap.name == "Rexxar-Realm" then rexxar = cap end end
    assert(rexxar and rexxar.total == 2 and rexxar.keeps == 1, "the capture heard during the rebuild is missing")
end
print("Sites week: capturers per character, cross-faction rivalries, cache by ledger OK")
