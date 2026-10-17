-- Top Overlord ranks seen by other players (RankProof): a claim alone shows nothing; a badge
-- needs our own server reading (lifetime honorable kills) for the Glory, and weeks our own
-- ranking placed in the top that lie between two of our readings whose difference covers
-- what our ranking gave him. Forged weeks, forged totals, other characters under the same
-- name and foreign inspect answers prove nothing; everything stops in an instance.
local now, server = 1000, 1792483200 + 3 * 86400
GetTime = function() return now end
GetServerTime = function() return server end
IsInInstance = function() return false end
CreateFrame = nil
local timers = {}
-- Timers run in the order of their delays (a settle of 1 s before a timeout of 8 s).
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { d = delay, n = #timers, fn = fn } end,
    NewTicker = function() return { Cancel = function() end } end }
local function pump()
    while #timers > 0 do
        table.sort(timers, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.n < b.n end)
        table.remove(timers, 1).fn()
    end
end

local ME = "Hero Mine"
Overlord = {
    PlayerFaction = "Alliance",
    InstanceSuspended = false,
    L = {},
    GetCurrentLeaderboardSavedVarsPool = function() return "EU" end,
    GetCurrentCampaignStartTs = function() return 1792483200 end, -- Tuesday 2026-10-20 08:00 UTC
    SafeGetUnitName = function(_, unit) return unit end,
}
local denied = {}
Overlord.Sync = {
    CanonicalForeverName = function(_, name)
        if type(name) ~= "string" or not name:match("^%a+ %a+$") then return nil end
        return name
    end,
    GetPlayerFullName = function() return ME end,
    -- The game's case: a capital first, never two capitals in a row.
    HasForeverNameCase = function(_, name) return name:match("^%u") ~= nil and not name:find("%u%u") end,
    IsDeniedKillContributor = function(_, name) return denied[name] == true end,
}
OverlordDB = { config = {} }
assert(loadfile("Ranks.lua"))()
local R = Overlord.Ranks
local localRank = 0
R.GetState = function() return { rank = localRank } end
assert(loadfile("RankProof.lua"))()
local RP = Overlord.RankProof
-- (Every week of these tests needs his own word to be excused: the dated switch is tested apart.)
local savedWordFrom = RP.WORD_FROM
RP.WORD_FROM = RP.WEEK_REF

local units = {}
Overlord.Sync.CanonicalForeverNameFromUnit = function(_, unit) return units[unit] and units[unit].name end
UnitExists = function(unit) return units[unit] ~= nil end
UnitIsPlayer = function(unit) return units[unit] ~= nil end
UnitIsUnit = function(a, b) return a == b end
UnitFactionGroup = function(unit) return units[unit] and units[unit].faction end
UnitGUID = function(unit) return units[unit] and units[unit].guid end
UnitAffectingCombat = function() return false end
InCombatLockdown = function() return false end
CanInspect = function(unit) return units[unit] ~= nil end
CheckInteractDistance = function() return true end
IsInGroup = function() return true end
IsInRaid = function() return true end
local notified = {}
NotifyInspect = function(unit) notified[#notified + 1] = unit end
local honor, today = 0, 0
GetInspectHonorData = function() return today, 0, 0, 0, honor, 0, 3, 0, 0 end

local week = RP:CurrentWeek()
assert(week and RP.WeekIndex(1792483200 + 30 * 3600) == week and RP.WeekIndex(1792483200 - 30 * 3600) == week,
    "the week index must absorb the ladder's slack")
assert(RP.WeekIndex(1792483200 + RP.WEEK_SEC) == week + 1, "the next reset is the next week")
local function letters(index)
    local text = ""
    repeat
        text = string.char(97 + index % 26) .. text
        index = math.floor(index / 26)
    until index == 0
    return text
end

-- 1. Presence: only a top rank is said; a neighbour's claim is kept, not believed.
assert(RP:PresenceToken() == "", "below rank 11 the presence says nothing more")
localRank = 13
assert(RP:PresenceToken() == "~q13", "our own top rank is claimed")
localRank = 0
RP:OnPresence("Top Claimer", "15")
local pool = RP:Pool()
assert(pool.claims["Top Claimer"] and pool.claims["Top Claimer"].r == 15, "a claim is kept")
assert(RP:GetBadgeRank("Top Claimer") == 0, "a claim alone shows no badge")
RP:OnPresence("Low Claimer", "7")
assert(pool.claims["Low Claimer"] == nil, "a rank below 11 is no claim")
RP:OnPresence("Top Claimer", nil)
assert(pool.claims["Top Claimer"] and pool.claims["Top Claimer"].r == 15,
    "a presence without the token is no news (a rank is for life)")
RP:OnPresence("tOP cLAIMER", "15")
assert(pool.claims["tOP cLAIMER"] == nil, "a name in another case is no claim")
RP:OnPresence(ME, "15")
assert(pool.claims[ME] == nil, "our own name is never a claim")
localRank = 12
assert(RP:GetBadgeRank(ME) == 0, "our own name carries no badge (the sheet shows our rank)")
localRank = 0

-- 2. Weekly close: our view of each faction's top 100.
local function closeSession(weekStart, f, rows)
    local session = { week = RP.WeekIndex(weekStart), f = f, Alliance = {}, Horde = {} }
    local info = {}
    for name, row in pairs(rows) do info[name] = { faction = row[2] } end
    for name, row in pairs(rows) do RP:OfferCloseRow(session, name, row[1], info) end
    return session
end
local rows = { ["Mate Near"] = { 1200, "Alliance" }, ["Banned Guy"] = { 99999, "Alliance" },
    ["Foe Best"] = { 5000, "Horde" } }
denied["Banned Guy"] = true
for index = 1, 150 do rows["Filler " .. letters(index)] = { 10 + index, "Alliance" } end
local session = closeSession(1792483200, 1, rows)
assert(#session.Alliance == RP.CLOSE_TOP and session.Alliance[1].n == "Mate Near"
    and session.Alliance[1].k == 1200, "the faction's top 100, most kills first, names set aside left out")
for index = 2, #session.Alliance do
    assert(session.Alliance[index - 1].k >= session.Alliance[index].k, "the top 100 stays sorted")
end
RP:FinishClose(session)
assert(pool.close[week] and pool.close[week].f == 1 and pool.close[week].Alliance["Mate Near"] == 65536 + 1200
    and pool.close[week].Horde["Foe Best"] == 65536 + 5000, "both factions kept for the week, place and kills")
assert(RP:WeekOf(pool, "Mate Near", week, "Alliance") == 1, "first of our faction this week")
assert(RP:TopFor(1, 1200, 1) == 1 and RP:TopFor(1, 900, 1) == 3, "a first place needs 1,000 kills")
assert(RP:TopFor(2, 1200, 1) == 3 and RP:TopFor(2, 1200, 0) == 10,
    "a top 3 needs the ranking compared in the week's last day (Ranks' rule), a top 10 only a presence")
assert(RP:TopFor(1, 1200, 0) == 10 and RP:TopFor(40, 600, 0) == 100, "the wider tops on a close played in time")
assert(RP:TopFor(2, 1200, -1) == nil and RP:TopFor(40, 600, -1) == nil,
    "a close made after the week was over places nobody")
assert(RP:TopFor(40, 99, 1) == nil, "a week counts from 100 kills")

-- 3. Proof: weeks from our own closes, counted by the server between two of our readings.
-- (Readings far apart around a week are allowed here; their limit is tested in 3b.)
local cur = RP:CurrentWeek()
local savedBracket = RP.BRACKET_WEEKS
RP.BRACKET_WEEKS = 99
local function wipe()
    pool.close, pool.vw, pool.shown, pool.rd, pool.gd, pool.low = {}, {}, {}, {}, {}, {}
    pool.dw, pool.gf, pool.cw = {}, {}, {}
    RP.Invalidate()
end
-- Our close of a week: the rows given (name -> { place, kills }).
local function ourClose(weekIndex, rowsByName, flag)
    local view = {}
    for name, row in pairs(rowsByName) do view[name] = row[1] * 65536 + row[2] end
    pool.close[weekIndex] = { f = flag or 1, Alliance = view, Horde = {}, c = { Alliance = {}, Horde = {} } }
end
local function cutAt(weekIndex, cuts) pool.close[weekIndex].c.Alliance = cuts end
local function reading(name, weekIndex, lifetime, t)
    pool.rd[name] = pool.rd[name] or {}
    pool.rd[name][weekIndex] = { l = lifetime, t = t or 0, a = server + (weekIndex - cur) * RP.WEEK_SEC,
        ss = weekIndex }
    RP.Invalidate(name)
end
local function claim(name, rank)
    RP:OnPresence(name, rank)
    RP.Invalidate(name)
end
-- Every week of the era closed by us (nothing unseen).
local function closeEra()
    for w = RP:Era(), cur - 1 do
        if not pool.close[w] then ourClose(w, {}) end
    end
end

wipe()
claim("Dragon Lord", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Dragon Lord"] = { 31, 600 } }) end
closeEra()
assert(RP:GetBadgeRank("Dragon Lord") == 0, "no server reading: no badge")
reading("Dragon Lord", cur - 1, 78000)
assert(RP:GetBadgeRank("Dragon Lord") == 0, "one reading after the weeks: the server did not say when they were made")
reading("Dragon Lord", cur - 6, 76000)
assert(RP:GetBadgeRank("Dragon Lord") == 11, "three top 100 weeks between two readings that cover them: rank 11")
assert(pool.shown["Dragon Lord"] and pool.shown["Dragon Lord"].r == 11, "a rank fully proven is kept")
-- The server counted 1,000 between two readings where our ranking gave 1,800: contradiction.
wipe()
claim("Dragon Lord", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Dragon Lord"] = { 31, 600 } }) end
closeEra()
reading("Dragon Lord", cur - 6, 78000)
reading("Dragon Lord", cur - 1, 79000)
assert(RP:GetBadgeRank("Dragon Lord") == 0, "1,800 claimed, 1,000 counted by the server: nothing proven")
-- Doubt is remembered: a later reading of the same week does not clear it.
reading("Dragon Lord", cur - 1, 79600, 200)
assert(RP:GetBadgeRank("Dragon Lord") == 0 and pool.dw["Dragon Lord"], "the weeks caught stay doubtful")
-- Today's kills count for him in that test (the lifetime may not hold them yet).
wipe()
claim("Today Lord", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Today Lord"] = { 31, 600 } }) end
closeEra()
reading("Today Lord", cur - 6, 78000)
reading("Today Lord", cur - 1, 79600, 200)
assert(RP:GetBadgeRank("Today Lord") == 11, "1,600 plus today's 200 covers 1,800: proven")
-- Weeks after our last reading wait for the next one.
wipe()
claim("Dragon Lord", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Dragon Lord"] = { 31, 600 } }) end
closeEra()
reading("Dragon Lord", cur - 7, 76000)
reading("Dragon Lord", cur - 6, 76500)
assert(RP:GetBadgeRank("Dragon Lord") == 0, "weeks after our last reading are not counted yet")
-- Everything our ranking gave him must fit in the server's lifetime count.
wipe()
claim("Inflated", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Inflated"] = { 31, 30000 } }) end
closeEra()
reading("Inflated", cur - 6, 20000)
reading("Inflated", cur - 1, 80000)
assert(RP:GetBadgeRank("Inflated") == 0, "90,000 kills on our ranking, 60,000 counted by the server: nothing proven")
wipe()
claim("Low Anchor", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Low Anchor"] = { 31, 600 } }) end
closeEra()
reading("Low Anchor", cur - 6, 58000)
reading("Low Anchor", cur - 1, 60000)
assert(RP:GetBadgeRank("Low Anchor") == 0, "a server count below 75 % of the Glory: no badge")
wipe()
claim("Two Weeks", "11")
for w = cur - 5, cur - 4 do ourClose(w, { ["Two Weeks"] = { 31, 600 } }) end
closeEra()
reading("Two Weeks", cur - 6, 78000)
reading("Two Weeks", cur - 1, 80000)
assert(RP:GetBadgeRank("Two Weeks") == 0, "two weeks in our top 100 and every week of the era seen: not enough")
-- The claim caps the badge; our close's place sets the top.
wipe()
claim("Real Ten", "13")
for w = cur - 5, cur - 3 do ourClose(w, { ["Real Ten"] = { 6, 900 } }) end
closeEra()
reading("Real Ten", cur - 6, 78000)
reading("Real Ten", cur - 1, 81000)
assert(RP:GetBadgeRank("Real Ten") == 13, "sixth three times: rank 13")
claim("Real Ten", "12")
assert(RP:GetBadgeRank("Real Ten") == 13, "a lower claim never takes away the rank shown (an older client, a second computer)")
claim("Real Ten", nil)
assert(RP:GetBadgeRank("Real Ten") == 13 and pool.claims["Real Ten"].r == 12, "a presence without a rank is no news: the claim stays")
pool.shown["Real Ten"] = nil
RP.Invalidate("Real Ten")
assert(RP:GetBadgeRank("Real Ten") == 12, "never more than the claim, beyond a rank shown before")
pool.shown["Real Ten"] = { r = 13, at = server }
claim("Real Ten", "12")
-- A rank fully proven stays when its weeks leave our data, and a contradiction found later
-- drops the weeks, not the rank shown (a forged ladder row could otherwise erase it).
claim("Real Ten", "13")
for w = cur - 5, cur - 3 do pool.close[w] = nil end
pool.vw["Real Ten"] = nil
RP.Invalidate("Real Ten")
assert(RP:GetBadgeRank("Real Ten") == 13, "a rank shown once is kept (ranks are for life)")
for w = cur - 5, cur - 3 do ourClose(w, { ["Real Ten"] = { 6, 900 } }) end
reading("Real Ten", cur - 6, 80900)
assert(RP:GetBadgeRank("Real Ten") == 13 and not (pool.vw["Real Ten"] and next(pool.vw["Real Ten"])),
    "doubtful weeks dropped, the rank shown stays")

-- 4. Overlord (15), and closes made after the week was over.
wipe()
claim("True King", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["True King"] = { 1, 5000 } }) end
closeEra()
reading("True King", cur - 7, 120000)
reading("True King", cur - 1, 147000)
assert(RP:GetBadgeRank("True King") == 15, "five first places counted by the server: Overlord")
claim("Short King", "15")
for w = cur - 6, cur - 2 do pool.close[w].Alliance["Short King"] = 2 * 65536 + 4900 end
reading("Short King", cur - 7, 80000)
reading("Short King", cur - 1, 106000)
assert(RP:GetBadgeRank("Short King") == 14, "a lifetime below 75 % of Overlord's Glory: Sovereign at most")
wipe()
claim("Played King", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["Played King"] = { 1, 5000 } }, 0) end
closeEra()
reading("Played King", cur - 7, 120000)
reading("Played King", cur - 1, 147000)
assert(RP:GetBadgeRank("Played King") == 13,
    "first on closes played but not compared in the week's last day: top 10 weeks, Crown Prince")
wipe()
claim("Stale King", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["Stale King"] = { 1, 5000 } }, -1) end
closeEra()
reading("Stale King", cur - 7, 120000)
reading("Stale King", cur - 1, 147000)
assert(RP:GetBadgeRank("Stale King") == 0,
    "first only on closes made after the weeks were over: nothing proven, and nothing to complete")
-- Five forged first places: the ladder says 5,000 kills a week, the server counted 1,000.
wipe()
claim("Forged First", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["Forged First"] = { 1, 5000 } }) end
closeEra()
reading("Forged First", cur - 7, 120000)
reading("Forged First", cur - 1, 121000)
assert(RP:GetBadgeRank("Forged First") == 0, "weeks the server did not count are never shown")
-- A veteran read once, then five first places declared: no reading after them, nothing.
wipe()
claim("Late Forger", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["Late Forger"] = { 1, 5000 } }) end
closeEra()
reading("Late Forger", cur - 7, 130000)
assert(RP:GetBadgeRank("Late Forger") == 0, "weeks declared after our only reading prove nothing")
reading("Late Forger", cur - 1, 131000)
assert(RP:GetBadgeRank("Late Forger") == 0, "and the next reading finds them doubtful")

-- 4b. Other weeks complete a rank, never start one.
local savedEra = RP.ERA_BETA
RP.ERA_BETA = server - 12 * RP.WEEK_SEC
assert(RP:Era() == cur - 12, "the era starts twelve weeks ago in this test")
wipe()
claim("Old King", "15")
-- We closed only the last three weeks; he was first in one of them.
ourClose(cur - 3, { ["Old King"] = { 2, 4000 } })
ourClose(cur - 2, { ["Old King"] = { 1, 5000 } })
cutAt(cur - 2, { 5000, 4000, 2500, 1500, 700 })
ourClose(cur - 1, { ["Old King"] = { 2, 4500 } })
reading("Old King", cur - 4, 140000)
reading("Old King", cur, 155000)
assert(RP:GetBadgeRank("Old King") == 15,
    "first once under our eyes, nine weeks we did not see, the server holds four more first places: Overlord")
assert(pool.shown["Old King"] and pool.shown["Old King"].r == 15,
    "a rank shown is kept for life, a rank completed by other weeks too")
claim("Never First", "15")
pool.close[cur - 2].Alliance["Never First"] = 3 * 65536 + 3900
reading("Never First", cur - 4, 140000)
reading("Never First", cur, 150000)
assert(RP:GetBadgeRank("Never First") == 14,
    "never first in our closes: never shown Overlord, Sovereign at most (third once, the rest unseen)")
-- His top weeks seen before our first reading complete a rank (their kills are in the count).
claim("Early King", "15")
for w = cur - 7, cur - 4 do ourClose(w, { ["Early King"] = { 1, 5000 } }) end
pool.close[cur - 2].Alliance["Early King"] = 1 * 65536 + 5001
reading("Early King", cur - 3, 130000)
reading("Early King", cur, 136000)
assert(RP:GetBadgeRank("Early King") == 15, "one first place proven, four seen before our first reading: Overlord")
assert(pool.shown["Early King"] and pool.shown["Early King"].r == 15, "kept for life once shown")
-- Every week of the era seen: the missing weeks cannot come from anywhere.
pool.close[cur - 7], pool.close[cur - 6], pool.close[cur - 5], pool.close[cur - 4] = nil, nil, nil, nil
closeEra()
RP.Invalidate()
pool.shown["Old King"] = nil
RP.Invalidate()
assert(RP:GetBadgeRank("Old King") == 14,
    "(forgetting what was shown) every week of the era seen: three top 3 weeks prove Sovereign, one first place is no Overlord")
-- The server must hold the missing weeks at the fewest kills our closes saw for that top.
wipe()
claim("Thin King", "15")
ourClose(cur - 2, { ["Thin King"] = { 1, 5000 } })
cutAt(cur - 2, { 5000, 4000, 2500, 1500, 700 })
ourClose(cur - 5, { ["Thin King"] = { 30, 50000 } })
ourClose(cur - 4, { ["Thin King"] = { 30, 50000 } })
reading("Thin King", cur - 6, 13000)
reading("Thin King", cur - 1, 115000)
assert(RP:GetBadgeRank("Thin King") == 14,
    "105,000 seen of 115,000: 10,000 left, not four first places of 5,000 (two top 3 weeks of 4,000 fit)")
reading("Thin King", cur - 1, 130000)
assert(RP:GetBadgeRank("Thin King") == 15, "25,000 left: four first places of 5,000 fit")
-- Weeks after our last reading: the server's count could not hold them yet.
wipe()
claim("Late King", "15")
ourClose(cur - 2, { ["Late King"] = { 1, 5000 } })
cutAt(cur - 2, { 5000, 4000, 2500, 1500, 700 })
reading("Late King", cur - 9, 150000)
assert(RP:GetBadgeRank("Late King") == 0, "a top week after our only reading opens nothing")
reading("Late King", cur - 1, 156000)
assert(RP:GetBadgeRank("Late King") == 15, "read again: proven, and the unseen weeks before the reading complete it")
-- Weeks after our last reading never complete a rank, nor do weeks at a wider top.
wipe()
claim("After King", "15")
ourClose(cur - 7, { ["After King"] = { 1, 5000 } })
for w = cur - 5, cur - 2 do ourClose(w, { ["After King"] = { 1, 5000 } }) end
closeEra()
reading("After King", cur - 8, 120000)
reading("After King", cur - 6, 126000)
assert(RP:GetBadgeRank("After King") == 0, "one first place proven, four declared after our last reading: nothing")
wipe()
claim("Wide King", "15")
for w = cur - 7, cur - 4 do ourClose(w, { ["Wide King"] = { 5, 3000 } }) end
ourClose(cur - 2, { ["Wide King"] = { 1, 5000 } })
closeEra()
reading("Wide King", cur - 3, 130000)
reading("Wide King", cur - 1, 136000)
assert(RP:GetBadgeRank("Wide King") == 13,
    "one first place proven, four top 10 weeks before our first reading: Crown Prince, never Overlord")
-- A week proven earlier, now before our oldest kept reading, counts once.
wipe()
claim("Trim King", "15")
for w = cur - 9, cur - 7 do ourClose(w, { ["Trim King"] = { 1, 5000 } }) end
closeEra()
reading("Trim King", cur - 10, 120000)
reading("Trim King", cur - 6, 136000)
assert(RP:GetBadgeRank("Trim King") < 15, "three first places proven, every week seen: no Overlord")
pool.rd["Trim King"][cur - 10] = nil
reading("Trim King", cur - 4, 137000)
assert(RP:GetBadgeRank("Trim King") < 15, "the oldest reading trimmed: the same three weeks are not counted twice")
-- The kills a top took are read only on closes that can tell that top.
wipe()
claim("Cut King", "15")
ourClose(cur - 6, { ["Cut King"] = { 40, 60000 } })
ourClose(cur - 5, { ["Cut King"] = { 40, 60000 } })
ourClose(cur - 3, {}, 0)
cutAt(cur - 3, { 1500, 1400, 1000, 600, 200 })
ourClose(cur - 2, { ["Cut King"] = { 1, 5000 } })
cutAt(cur - 2, { 5000, 4000, 2500, 1500, 700 })
reading("Cut King", cur - 7, 2000)
reading("Cut King", cur, 139000)
assert(RP:GetBadgeRank("Cut King") == 14,
    "14,000 left: four first places at 5,000 do not fit; the 1,500 seen on a close not compared does not count")
-- A faction's view that nobody of that faction played on the last day places nobody.
wipe()
claim("Side King", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Side King"] = { 31, 600 } }, 0) end
closeEra()
reading("Side King", cur - 6, 76000)
reading("Side King", cur - 1, 78000)
assert(RP:GetBadgeRank("Side King") == 11, "three top 100 weeks played on the last day: rank 11")
for w = cur - 5, cur - 3 do pool.close[w].ff = { Alliance = -1, Horde = 0 } end
pool.vw["Side King"], pool.shown["Side King"] = nil, nil
RP.Invalidate()
assert(RP:GetBadgeRank("Side King") == 0, "the same weeks seen only from the other side: nothing proven")
-- A week closed without telling his place counts his kills once, not twice.
wipe()
claim("Once King", "15")
ourClose(cur - 9, { ["Once King"] = { 40, 50000 } })
ourClose(cur - 8, { ["Once King"] = { 40, 50000 } })
ourClose(cur - 5, { ["Once King"] = { 40, 20000 } }, -1)
ourClose(cur - 3, { ["Once King"] = { 1, 5000 } })
cutAt(cur - 3, { 5000, 4000, 2500, 1500, 700 })
reading("Once King", cur - 10, 10000)
reading("Once King", cur - 4, 134000)
reading("Once King", cur - 2, 140000)
assert(RP:GetBadgeRank("Once King") == 15, "the 20,000 of a week we could not place are not charged twice")
-- A full claim table drops a claim without a rank shown before one with.
local savedMax = RP.CLAIMS_MAX
RP.CLAIMS_MAX = 3
pool.claims = {
    ["Shown Old"] = { r = 11, at = server - 300, f = "Alliance" },
    ["Read Only"] = { r = 11, at = server - 200, f = "Alliance" },
    ["Shown New"] = { r = 11, at = server - 100, f = "Alliance" },
}
pool.rd["Shown Old"], pool.rd["Read Only"], pool.rd["Shown New"] = {}, {}, {}
pool.shown["Shown Old"], pool.shown["Shown New"] = { r = 11, at = server }, { r = 11, at = server }
RP:OnPresence("Fresh Claim", "12")
assert(pool.claims["Read Only"] == nil and pool.claims["Shown Old"] and pool.claims["Fresh Claim"],
    "the claim without a rank shown goes first")
RP.CLAIMS_MAX = savedMax
-- His fear: a player who really finished first five times, one of his ranking rows inflated
-- by someone else, is never refused his Overlord.
wipe()
claim("Griefed King", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["Griefed King"] = { 1, 5000 } }) end
pool.close[cur - 4].Alliance["Griefed King"] = 1 * 65536 + 30000
closeEra()
reading("Griefed King", cur - 7, 120000)
reading("Griefed King", cur - 5, 125100)
reading("Griefed King", cur - 3, 135200)
reading("Griefed King", cur - 1, 145300)
assert(RP:GetBadgeRank("Griefed King") < 15,
    "until we hear his own word for the inflated week, that week waits (neither counted nor held against him)")
-- His own word (first-hand, in his presence): 5,000 for that week, what the server counted.
local function b36(n)
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    if n == 0 then return "0" end
    while n > 0 do local d = n % 36 out = digits:sub(d + 1, d + 1) .. out n = (n - d) / 36 end
    return out
end
local function say(name, rank, week, kills) RP:OnPresence(name, rank .. "." .. b36(week) .. "-" .. b36(kills)) end
for w = cur - 6, cur - 2 do say("Griefed King", 15, w, 5000) end
assert(pool.ow["Griefed King"] and pool.ow["Griefed King"][cur - 4] == 5000, "his word is kept per week")
assert(RP:GetBadgeRank("Griefed King") == 15,
    "his own word says 5,000, as the server counted: the 30,000 row is someone else's, he stays Overlord")
-- A liar: his own word for those weeks goes beyond what the server counted.
wipe()
pool.ow, pool.lw = {}, {}
claim("Liar King", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["Liar King"] = { 1, 5000 } }) end
reading("Liar King", cur - 7, 120000)
reading("Liar King", cur - 5, 125100)
reading("Liar King", cur - 3, 126000)
reading("Liar King", cur - 1, 136200)
for w = cur - 6, cur - 2 do say("Liar King", 15, w, 5000) end
assert(RP:GetBadgeRank("Liar King") == 0, "he said 10,000 for two weeks the server counted 900: refused, and nothing completes his rank")
assert(pool.lw["Liar King"] and pool.lw["Liar King"][cur - 4], "his lie is remembered")
pool.rd["Liar King"][cur - 5], pool.rd["Liar King"][cur - 7] = nil, nil
RP.Invalidate("Liar King")
assert(RP:GetBadgeRank("Liar King") == 0, "the readings that caught him trimmed: still refused, nothing completes")
-- A doubtful week from a reading of the running week, without his word: it waits.
wipe()
pool.ow, pool.lw = {}, {}
claim("Pend King", "11")
ourClose(cur - 5, { ["Pend King"] = { 31, 600 } })
ourClose(cur - 4, { ["Pend King"] = { 31, 600 } })
ourClose(cur - 2, { ["Pend King"] = { 31, 3000 } })
closeEra()
reading("Pend King", cur - 6, 80000)
reading("Pend King", cur - 3, 81300)
reading("Pend King", cur, 81400)
assert(RP:GetBadgeRank("Pend King") == 0, "a doubtful week without his word completes nothing")
say("Pend King", 11, cur - 2, 100)
assert(RP:GetBadgeRank("Pend King") == 11, "his word (100) fits: the 3,000 row was someone else's, it completes his rank")
-- A doubtful week remembered, its readings gone, without his word: it still waits.
wipe()
pool.ow, pool.lw = {}, {}
claim("Memo King", "11")
ourClose(cur - 6, { ["Memo King"] = { 31, 600 } })
ourClose(cur - 5, { ["Memo King"] = { 31, 600 } })
ourClose(cur - 3, { ["Memo King"] = { 31, 3000 } })
closeEra()
reading("Memo King", cur - 7, 80000)
reading("Memo King", cur - 4, 81300)
reading("Memo King", cur - 2, 81400)
assert(RP:GetBadgeRank("Memo King") == 0 and pool.dw["Memo King"] and pool.dw["Memo King"][cur - 3], "doubt remembered")
pool.rd["Memo King"][cur - 7], pool.rd["Memo King"][cur - 4] = nil, nil
RP.Invalidate("Memo King")
assert(RP:GetBadgeRank("Memo King") == 0, "its readings gone, the remembered doubtful week still waits for his word")
-- A doubtful week never refuses a rank the other weeks complete.
wipe()
claim("Half King", "15")
ourClose(cur - 5, { ["Half King"] = { 1, 5000 } })
cutAt(cur - 5, { 5000, 4000, 2500, 1500, 700 })
ourClose(cur - 3, { ["Half King"] = { 50, 4000 } })
reading("Half King", cur - 6, 139000)
reading("Half King", cur - 4, 145000)
reading("Half King", cur - 2, 148800)
assert(RP:GetBadgeRank("Half King") == 15,
    "one first place proven: a doubtful week elsewhere refuses him nothing (the other weeks complete it)")
-- 3b. Readings far apart prove nothing: the server's growth of quiet weeks cannot be poured
-- into one declared top week. Readings at most three weeks apart around a week prove it.
RP.BRACKET_WEEKS = savedBracket
wipe()
claim("Pour King", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Pour King"] = { 31, 600 } }) end
closeEra()
reading("Pour King", cur - 6, 76000)
reading("Pour King", cur - 1, 78000)
assert(RP:GetBadgeRank("Pour King") == 0, "readings five weeks apart: the weeks between are unverified")
reading("Pour King", cur - 5, 76650)
reading("Pour King", cur - 4, 77300)
reading("Pour King", cur - 3, 77950)
reading("Pour King", cur - 2, 77980)
assert(RP:GetBadgeRank("Pour King") == 11, "read every other week: each top week between close readings")
-- A row inflated later never undoes weeks proven before (each stretch is judged on its own).
ourClose(cur - 1, { ["Pour King"] = { 1, 30000 } })
reading("Pour King", cur, 78100)
assert(RP:GetBadgeRank("Pour King") == 11 and pool.vw["Pour King"] and pool.vw["Pour King"][cur - 5],
    "the inflated week is doubtful, the weeks proven before stay")
-- A row moved to the other side's view still counts against the server.
wipe()
claim("Side Mover", "11")
for w = cur - 5, cur - 3 do ourClose(w, { ["Side Mover"] = { 31, 600 } }) end
pool.close[cur - 4].Horde = { ["Side Mover"] = 1 * 65536 + 30000 }
closeEra()
reading("Side Mover", cur - 6, 76000)
reading("Side Mover", cur - 4, 76700)
reading("Side Mover", cur - 2, 77900)
local sideProven, sideDoubt = RP:Evidence(pool, "Side Mover", "Alliance")
assert(sideDoubt[cur - 4] and not sideProven[cur - 4],
    "30,000 kills shown on the other side are still judged against the server: that week is not proven")
-- A name our ranking knows only on the other side has no badge; a damaged entry shows none.
wipe()
claim("Real Ten", "13")
for w = cur - 5, cur - 3 do ourClose(w, { ["Real Ten"] = { 6, 900 } }) end
closeEra()
reading("Real Ten", cur - 6, 78000)
reading("Real Ten", cur - 4, 79000)
reading("Real Ten", cur - 2, 81000)
assert(RP:GetBadgeRank("Real Ten") == 13, "rank 13")
pool.gf["Real Ten"] = "Horde"
assert(RP:GetBadgeRank("Real Ten") == 0, "read on the other side (an account with both): no badge on this one")
pool.gf["Real Ten"] = "Alliance"
assert(RP:GetBadgeRank("Real Ten") == 13, "read on our side: the badge")
pool.vw["Damaged Entry"] = { [cur - 3] = "x" }
pool.shown["Damaged Entry"] = nil
claim("Damaged Entry", "11")
reading("Damaged Entry", cur - 1, 80000)
reading("Damaged Entry", cur - 4, 79000)
assert(RP:GetBadgeRank("Damaged Entry") == 0, "a damaged saved entry gives no badge and no error")
-- A tie group at the 100th place too big to keep is left out whole, in any order.
local function capClose(order)
    local session = { week = 1, f = 1, Alliance = {}, Horde = {} }
    local rows, info = {}, {}
    for i = 1, 90 do rows[#rows + 1] = { "Best " .. letters(i), 2000 - i } end
    for i = 1, 200 do rows[#rows + 1] = { "Flood " .. letters(i), 900 } end
    rows[#rows + 1] = { "Below Flood", 800 }
    for _, row in ipairs(rows) do info[row[1]] = { faction = "Alliance" } end
    for i = 1, #rows do
        local row = rows[order and (#rows + 1 - i) or i]
        RP:OfferCloseRow(session, row[1], row[2], info)
    end
    return session
end
local capA, capB = capClose(false), capClose(true)
assert(#capA.Alliance == 90 and #capB.Alliance == 90, "the oversized tie group and what lies below it are left out")
assert(capA.Alliance[90].n == capB.Alliance[90].n, "the same names in any order")
-- A close made by an update installed during the week: the side closing it is taken.
local savedWindow2 = R.GetWeekCloseWindow
R.GetWeekCloseWindow = function() return 1792483200 - RP.WEEK_SEC, false, 1792483200 end
pool.on, pool.onSince = nil, nil
local upgraded = RP:BeginClose({ resetEpoch = 1792483200, archiveEpoch = 1792483200 - RP.WEEK_SEC })
assert(upgraded.ff.Alliance == 0 and upgraded.ff.Horde == -1, "stamps unknown: our side counts as played")
R.GetWeekCloseWindow = savedWindow2
-- A new era (the launch) starts from nothing.
pool.era = RP:Era() - 4
RP:CheckEra(pool)
assert(next(pool.rd) == nil and next(pool.close) == nil and next(pool.claims) == nil and pool.era == RP:Era(),
    "what was read and closed in the beta does not follow into the launch")
RP:CheckEra(pool)
assert(pool.era == RP:Era(), "the same era twice wipes nothing more")
RP.BRACKET_WEEKS = 99
pool.era = nil -- (this test moves the era's start; the real one never moves)
-- A week from before the era, closed after it moved (the beta's last week at the launch),
-- is not kept.
local beforeEra = { week = RP:Era() - 1, f = 1, Alliance = {}, Horde = {} }
RP:OfferCloseRow(beforeEra, "Old Hero", 3000, { ["Old Hero"] = { faction = "Alliance" } })
RP:FinishClose(beforeEra)
assert(pool.close[RP:Era() - 1] == nil and pool.cw[RP:Era() - 1] == nil, "a close from before the era is not kept")
-- Doubt stays when the readings that caught it are trimmed away.
wipe()
claim("Caught King", "13")
for w = cur - 6, cur - 4 do ourClose(w, { ["Caught King"] = { 5, 3000 } }) end
ourClose(cur - 2, { ["Caught King"] = { 5, 3000 } })
closeEra()
reading("Caught King", cur - 7, 90000)
reading("Caught King", cur - 3, 91000)
reading("Caught King", cur - 1, 94500)
assert(RP:GetBadgeRank("Caught King") == 0,
    "9,000 on our ranking, 1,000 on the server, his own word not heard yet: those weeks wait")
for w = cur - 6, cur - 4 do say("Caught King", 13, w, 300) end
assert(RP:GetBadgeRank("Caught King") == 13,
    "his own word (300 a week) fits the server: the rows were inflated by someone else, they complete his rank")
assert(pool.dw["Caught King"] and pool.dw["Caught King"][cur - 5],
    "9,000 on the rows, 1,000 counted: those rows are doubtful (his word, not the rows, places the weeks)")
-- A week we closed stays known after its close is pruned: it never turns into a week we
-- did not see.
wipe()
for w = RP:Era(), cur - 1 do pool.cw[w] = { f = 1 } end
assert(RP:UnseenWeeks(pool, "Alliance", nil, cur, 1) == 0, "weeks closed long ago are still weeks we saw")
pool.cw[cur - 3] = { f = 0 }
assert(RP:UnseenWeeks(pool, "Alliance", nil, cur, 1) == 1 and RP:UnseenWeeks(pool, "Alliance", nil, cur, 10) == 0,
    "a week closed without the comparison cannot tell a first place")
-- Doubt from a reading of the week still running is not remembered: its next reading in
-- the same week replaces it.
wipe()
claim("Open King", "13")
ourClose(cur - 2, { ["Open King"] = { 5, 3000 } })
closeEra()
reading("Open King", cur - 3, 90000)
reading("Open King", cur, 90200)
assert(RP:GetBadgeRank("Open King") == 0 and pool.dw["Open King"] == nil, "doubt from this week's reading is not kept")
assert(not (pool.vw["Open King"] or {})[cur - 2], "nor is the week proven while it is doubtful")
reading("Open King", cur, 93500)
RP:GetBadgeRank("Open King")
assert(pool.vw["Open King"] and pool.vw["Open King"][cur - 2] == 10, "read again this week: the week is proven")
-- A reading is evaluated at once: proven weeks never depend on a row being painted.
wipe()
claim("Quiet King", "13")
ourClose(cur - 2, { ["Quiet King"] = { 5, 3000 } })
closeEra()
pool.rd["Quiet King"] = { [cur - 3] = { l = 90000, t = 0, a = server - 3 * RP.WEEK_SEC } }
RP:StoreReading("Quiet King", 93500, 0, "Player-1-QK")
assert(pool.vw["Quiet King"] and pool.vw["Quiet King"][cur - 2] == 10, "the week is kept as soon as it is read")
-- Also for a player who claims nothing yet (his top weeks come long before his rank).
wipe()
ourClose(cur - 2, { ["Future King"] = { 5, 3000 } })
closeEra()
RP:FinishClose({ week = cur - 2, f = 1, Alliance = { { n = "Future King", k = 3000 } }, Horde = {} })
pool.rd["Future King"] = { [cur - 3] = { l = 90000, t = 0, a = server - 3 * RP.WEEK_SEC } }
RP:StoreReading("Future King", 93500, 0, "Player-1-FK")
assert(pool.claims["Future King"] == nil and pool.vw["Future King"] and pool.vw["Future King"][cur - 2],
    "a top week of a player without a claim is kept when he is read")
-- A variant spelling of a name never overwrites its best row in a close.
local plainCanon = Overlord.Sync.CanonicalForeverName
Overlord.Sync.CanonicalForeverName = function(sync, name)
    return plainCanon(sync, type(name) == "string" and (name:match("^(.-)%-") or name) or name)
end
local variant = { week = cur - 1, f = 1, Alliance = { { n = "Best Name", k = 3000 }, { n = "Best Name-Xy", k = 500 } }, Horde = {} }
RP:FinishClose(variant)
Overlord.Sync.CanonicalForeverName = plainCanon
assert(pool.close[cur - 1].Alliance["Best Name"] == 65536 + 3000, "the best row of the name is kept")
pool.era = nil

RP.ERA_BETA = savedEra
wipe()
claim("True King", "15")
for w = cur - 6, cur - 2 do ourClose(w, { ["True King"] = { 1, 5000 } }) end
closeEra()
reading("True King", cur - 7, 120000)
reading("True King", cur - 1, 147000)
assert(RP:GetBadgeRank("True King") == 15, "Overlord again for the next sections")

local function fresh(name, claimRank)
    pool.rd[name], pool.shown[name] = nil, nil
    RP:OnPresence(name, claimRank)
    RP.Invalidate(name)
end

-- 5. Readings come from our own inspect only, checked against foreign answers.
local cw = RP:CurrentWeek()
fresh("Read Me", "11")
units.target = { name = "Read Me", faction = "Alliance", guid = "Player-1-RM" }
units.mouseover = { name = "True King", faction = "Alliance", guid = "Player-1-TK" }
assert(RP:TryInspect("target") == nil and #notified == 1 and notified[1] == "target", "a claimant is inspected")
assert(RP:TryInspect("mouseover") == "busy" and #notified == 1, "one inspect at a time")
honor, today = 85000, 12
RP:OnInspectReady("Player-1-RM")
RP:OnInspectHonor()
pump()
assert(pool.rd["Read Me"] and pool.rd["Read Me"][cw].l == 85000 and pool.rd["Read Me"][cw].t == 12,
    "the reading is kept with today's kills")
now = now + 10
assert(RP:TryInspect("mouseover") == "wait", "thirty seconds between two inspects")
now = now + 30
assert(RP:TryInspect("mouseover") == nil and #notified == 2, "the next claimant is inspected")
honor = 999999
RP:OnInspectReady("Player-1-OTHER")
RP:OnInspectReady("Player-1-TK")
RP:OnInspectHonor()
pump()
assert(pool.rd["True King"][cw] == nil, "an answer spoiled by another inspect is never kept")
now = now + 40
units.focus = { name = "True King", faction = "Alliance", guid = "Player-1-TK" }
InspectFrame = { IsShown = function() return true end }
assert(RP:TryInspect("focus") == "wait", "a failed read is tried again after five minutes only")
now = now + RP.INSPECT_RETRY
assert(RP:TryInspect("focus") == "busy", "never while the player inspects someone himself")
InspectFrame = nil
honor = 0
assert(RP:TryInspect("focus") == nil, "inspected")
RP:OnInspectReady("Player-1-TK")
RP:OnInspectHonor()
pump()
assert(pool.rd["True King"][cw] == nil, "a lifetime count of 0 is no reading")
now = now + RP.INSPECT_RETRY + 1
units.target2 = { name = "Read Me", faction = "Horde", guid = "Player-1-X" }
assert(RP:TryInspect("target2") == "faction", "another faction is never inspected")
units.stranger = { name = "Not Claiming", faction = "Alliance", guid = "Player-1-NC" }
assert(RP:TryInspect("stranger") == "unit", "a player without a claim is never inspected")
-- The honor data may come with the inspect's answer: read at the answer.
honor = 147000
assert(RP:TryInspect("focus") == nil, "inspected again")
RP:OnInspectHonor()
RP:OnInspectReady("Player-1-TK")
pump()
assert(pool.rd["True King"][cw] and pool.rd["True King"][cw].l == 147000,
    "honor data that came just before our answer is read at the answer")
-- A unit gone meanwhile does not spoil an answer carrying his GUID.
now = now + RP.INSPECT_AGAIN + 100
units.target = { name = "Read Me", faction = "Alliance", guid = "Player-1-RM" }
assert(RP:TryInspect("target") == nil, "inspected")
RP:OnInspectReady("Player-1-RM")
units.target = nil
honor = 86000
RP:OnInspectHonor()
pump()
assert(pool.rd["Read Me"][cw].l == 86000, "kept although the target changed")

-- A client that can ask for the honor data: the update before the answer is enough when no
-- other follows the request; an update after it must agree.
now = now + RP.INSPECT_AGAIN + 100
RequestInspectHonorData = function() end
units.target = { name = "Read Me", faction = "Alliance", guid = "Player-1-RM" }
honor = 86500
assert(RP:TryInspect("target") == nil, "inspected")
RP:OnInspectHonor()
RP:OnInspectReady("Player-1-RM")
pump()
assert(pool.rd["Read Me"][cw].l == 86500, "honor data before the answer is kept although nothing followed the request")
now = now + RP.INSPECT_AGAIN + 100
assert(RP:TryInspect("target") == nil, "inspected")
honor = 86600
RP:OnInspectHonor()
RP:OnInspectReady("Player-1-RM")
honor = 99999
RP:OnInspectHonor()
pump()
assert(pool.rd["Read Me"][cw].l == 86500, "two different honor counts for one answer: nothing kept")
-- Honor data that changed by the end of the wait (another addon's inspect) is not kept.
now = now + RP.INSPECT_AGAIN + 100
assert(RP:TryInspect("target") == nil, "inspected")
honor = 86700
RP:OnInspectHonor()
RP:OnInspectReady("Player-1-RM")
honor = 55555
pump()
assert(pool.rd["Read Me"][cw].l == 86500, "changed during the wait: nothing kept")
-- The game's own inspect left waiting (never answered) holds ours ten seconds only.
now = now + RP.INSPECT_AGAIN + 100
InspectFrame = { IsShown = function() return false end, unit = "focus" }
assert(RP:TryInspect("target") == "busy", "the game's inspect in flight")
now = now + 11
assert(RP:TryInspect("target") == nil, "never answered: ours goes after ten seconds")
RP:EndInspect()
-- The game sends another inspect meanwhile: busy again for its own wait.
now = now + RP.INSPECT_AGAIN + 100
units.focus = { name = "Other Wait", faction = "Alliance", guid = "Player-1-OW" }
assert(RP:TryInspect("target") == "busy", "a new game inspect: busy again")
units.focus = { name = "True King", faction = "Alliance", guid = "Player-1-TK" }
-- Never the player the game's inspect waits for: our answer would open its window.
now = now + RP.INSPECT_AGAIN + 100
InspectFrame.unit = "target"
assert(RP:TryInspect("target") == "busy", "the player the game waits for")
now = now + 11
assert(RP:TryInspect("target") == "busy", "still never him, however long it waits")
InspectFrame = nil
RequestInspectHonorData = nil

-- 6. Readings: another character under the same name starts afresh; a lower reading needs a
-- second one from another session.
fresh("Guid Claim", "11")
RP:StoreReading("Guid Claim", 90000, 10, "Player-1-A")
assert(pool.rd["Guid Claim"][cw].l == 90000, "first reading kept")
pool.shown["Guid Claim"] = { r = 11, at = server, g = "Player-1-A" }
RP:StoreReading("Guid Claim", 50000, 0, "Player-1-B")
assert(pool.rd["Guid Claim"][cw].l == 50000 and pool.gd["Guid Claim"] == "Player-1-B"
    and pool.shown["Guid Claim"] == nil, "another character under the same name: old readings and badge go")
RP:StoreReading("Guid Claim", 40000, 0, "Player-1-B")
assert(pool.rd["Guid Claim"][cw].l == 50000 and pool.low["Guid Claim"], "a lower reading is held apart")
RP:StoreReading("Guid Claim", 41000, 0, "Player-1-B")
assert(pool.rd["Guid Claim"][cw].l == 50000, "a second lower one from the same session changes nothing")
pool.low["Guid Claim"].ss = "older session"
RP:StoreReading("Guid Claim", 41000, 0, "Player-1-B")
assert(pool.rd["Guid Claim"][cw].l == 50000, "a second lower one from the same week changes nothing")
pool.low["Guid Claim"].w, pool.low["Guid Claim"].ss = cw - 1, "older session"
RP:StoreReading("Guid Claim", 41000, 0, "Player-1-B")
assert(pool.rd["Guid Claim"][cw].l == 41000, "confirmed from another session: the higher reading was not his")

-- A nameplate never shows a badge for another character than the one we read.
C_NamePlate = { GetNamePlateForUnit = function() return nil end, GetNamePlates = function() return {} end }
pool.gd["True King"] = "Player-1-TK"
units.nameplate1 = { name = "True King", faction = "Alliance", guid = "Player-1-TK" }
assert(RP:UnitBadge(pool, "nameplate1") == 15, "his own nameplate shows his badge")
units.nameplate2 = { name = "True King", faction = "Alliance", guid = "Player-2-NEW" }
assert(RP:UnitBadge(pool, "nameplate2") == 0 and pool.shown["True King"] == nil and pool.rd["True King"] == nil,
    "another character under his name: no badge, and what we knew of the name goes")

-- 7. Sampling: group mates and nameplates are tried on the 30 s tick.
now = now + RP.INSPECT_AGAIN + 100
units.target = nil
units.raid1 = { name = "Read Me", faction = "Alliance", guid = "Player-1-RM" }
local before = #notified
RP:SampleUnits()
assert(#notified == before + 1 and notified[#notified] == "raid1", "a group mate due for a reading is inspected")
RP:EndInspect()
-- Claimants come first; another candidate only when no claimant is due, and never from a
-- nameplate or the mouse alone.
RP:FinishClose(closeSession(1792483200 - RP.WEEK_SEC, 1, { ["Cand Only"] = { 500, "Alliance" } }))
now = now + RP.INSPECT_AGAIN + 100
units.raid1 = nil
units.nameplate5 = { name = "Cand Only", faction = "Alliance", guid = "Player-1-CO" }
units.nameplate6 = { name = "Read Me", faction = "Alliance", guid = "Player-1-RM" }
C_NamePlate = { GetNamePlateForUnit = function() return nil end, GetNamePlates = function()
    return { { namePlateUnitToken = "nameplate5" }, { namePlateUnitToken = "nameplate6" } }
end }
before = #notified
RP:OnPlate("nameplate5")
assert(#notified == before, "a nameplate alone never spends the inspect on a player without a claim")
RP:SampleUnits()
assert(#notified == before + 1 and notified[#notified] == "nameplate6", "the claimant is read first")
RP:EndInspect()
now = now + RP.INSPECT_GAP + 1
RP:SampleUnits()
assert(#notified == before + 2 and notified[#notified] == "nameplate5", "then the other candidate")
RP:EndInspect()
-- A free claim (nobody of our top, never read) never takes the slot from a nameplate.
now = now + RP.INSPECT_AGAIN + 100
RP:OnPresence("Free Claim", "15")
units.nameplate7 = { name = "Free Claim", faction = "Alliance", guid = "Player-1-FC" }
before = #notified
RP:OnPlate("nameplate7")
assert(#notified == before, "a claim with nothing behind it waits for the tick's second pass")

-- 8. Instance: nothing heard, inspected or shown.
Overlord.InstanceSuspended = true
RP:OnPresence("Insta Claim", "15")
assert(pool.claims["Insta Claim"] == nil, "nothing read in an instance")
assert(RP:GetBadgeRank("True King") == 0, "no badge in an instance")
now = now + 100
assert(RP:TryInspect("raid1") == "instance", "no inspect in an instance")
Overlord.InstanceSuspended = false

-- 9. Bounds: claims and readings are capped.
for index = 1, RP.CLAIMS_MAX + 20 do RP:OnPresence("Many " .. letters(index), "11") end
local claimCount = 0
for _ in pairs(pool.claims) do claimCount = claimCount + 1 end
assert(claimCount <= RP.CLAIMS_MAX, "claims are capped")
for index = 1, RP.READ_KEYS + 30 do
    pool.rd["Reader " .. letters(index)] = { [cw] = { l = 1, t = 0, a = server - index, ss = 1 } }
end
RP:Prune(pool)
local readCount = 0
for _ in pairs(pool.rd) do readCount = readCount + 1 end
assert(readCount <= RP.READ_KEYS, "readings are capped")
print("Rank proof: claims, server anchor, weeks by our closes judged by the server, unseen weeks, "
    .. "contradictions, kept ranks, inspect guards, GUIDs, sampling, instance cut, bounds OK")

-- 10b. Ties at the 100th place: every client keeps the whole tie group, whatever the order.
local function tieClose(order)
    local session = { week = 1, f = 1, Alliance = {}, Horde = {} }
    local info, names = {}, {}
    for i = 1, 95 do names[#names + 1] = { "Top " .. letters(i), 1000 - i } end
    for i = 1, 12 do names[#names + 1] = { "Tie " .. letters(i), 140 } end
    names[#names + 1] = { "Low Guy", 100 }
    for _, row in ipairs(names) do info[row[1]] = { faction = "Alliance" } end
    for i = 1, #names do
        local row = names[order == "reverse" and (#names + 1 - i) or i]
        RP:OfferCloseRow(session, row[1], row[2], info)
    end
    local kept = {}
    for _, row in ipairs(session.Alliance) do kept[row.n] = true end
    return session, kept
end
local forward, keptA = tieClose("forward")
local backward, keptB = tieClose("reverse")
assert(#forward.Alliance == 107 and #backward.Alliance == 107 and not keptA["Low Guy"], "the whole tie group is kept")
for name in pairs(keptA) do assert(keptB[name], "the same names whatever the order: " .. name) end
-- Kul Tiran rows belong to the Alliance by their race (the addon stores "KulTiran").
local kul = { week = 1, f = 1, Alliance = {}, Horde = {} }
RP:OfferCloseRow(kul, "Kul Sailor", 900, { ["Kul Sailor"] = { faction = "Horde", race = "KulTiran" } })
assert(#kul.Alliance == 0 and #kul.Horde == 1, "a row sits in its label's view only, whatever its race says")
local kul2 = { week = 1, f = 1, Alliance = {}, Horde = {} }
RP:OfferCloseRow(kul2, "Kul Sailor", 900, { ["Kul Sailor"] = { race = "KulTiran" } })
assert(#kul2.Alliance == 0 and #kul2.Horde == 0, "no label, no place")

-- 10c. A faction's view of a close places anyone only if a character of that faction played
-- the week's last day (an account with characters on both sides), unless the ranking was
-- compared in full.
local savedWindow = R.GetWeekCloseWindow
local weekEndTs = 1792483200
R.GetWeekCloseWindow = function() return weekEndTs - RP.WEEK_SEC, false end
pool.on = { Alliance = { a = weekEndTs - 3600 }, Horde = { a = weekEndTs - 5 * 86400 } }
local dual = RP:BeginClose({ resetEpoch = weekEndTs, archiveEpoch = weekEndTs - RP.WEEK_SEC })
assert(dual and dual.ff.Alliance == 0 and dual.ff.Horde == -1, "the side not played on the last day places nobody")
R.GetWeekCloseWindow = function() return weekEndTs - RP.WEEK_SEC, true end
dual = RP:BeginClose({ resetEpoch = weekEndTs, archiveEpoch = weekEndTs - RP.WEEK_SEC })
assert(dual.ff.Alliance == 1 and dual.ff.Horde == 0,
    "compared in full: both sides for the wider tops, a top 3 or a first only on the side we played")
R.GetWeekCloseWindow = savedWindow
pool.on = nil
RP:NoteOnline()
assert(pool.on and pool.on.Alliance and pool.on.Alliance.a == server and pool.on.Horde == nil,
    "the presence stamp is kept for our faction only")

-- 10. The side of a row is its label (set once, by the first word heard of a name), as Ranks.
local raced = { week = 1, f = 1, Alliance = {}, Horde = {} }
RP:OfferCloseRow(raced, "Horde Rival", 3000, { ["Horde Rival"] = { faction = "Alliance", race = "Orc" } })
RP:OfferCloseRow(raced, "Unknown Race", 2000, { ["Unknown Race"] = { faction = "Alliance", race = "" } })
assert(#raced.Horde == 0 and #raced.Alliance == 2,
    "rows sit in their label's view, as the holder's own rank places them: a race rewritten later moves nobody")
-- 11. A name claimed anew after its claim was gone: the rank shown waits for the character.
RP:OnPresence("Rename Hero", "11")
pool.shown["Rename Hero"] = { r = 11, at = server }
pool.gd["Rename Hero"] = "Player-1-RH"
RP.Invalidate("Rename Hero")
assert(RP:GetBadgeRank("Rename Hero") == 11, "a kept rank")
pool.claims["Rename Hero"] = nil -- not heard for four weeks
RP:OnPresence("Rename Hero", "15")
assert(RP:GetBadgeRank("Rename Hero") == 11, "claimed anew at least at the rank shown: shown at once")
pool.claims["Rename Hero"] = nil
pool.shown["Rename Hero"].r = 13
RP:OnPresence("Rename Hero", "12")
assert(RP:GetBadgeRank("Rename Hero") == 0, "claimed anew below the rank shown: it waits for the character")
pool.shown["Rename Hero"].r = 11
units.nameplate3 = { name = "Rename Hero", faction = "Alliance", guid = "Player-1-RH" }
assert(RP:UnitBadge(pool, "nameplate3") == 11, "the same character seen: the kept rank is back")
-- Seen in person within the day: presences without a rank are the same player on a
-- computer without his rank data, never a reused name.
RP:OnPresence("Rename Hero", nil)
RP:OnPresence("Rename Hero", nil)
RP:OnPresence("Rename Hero", nil)
assert(RP:GetBadgeRank("Rename Hero") == 11, "seen today: his presences without a rank hide nothing")
-- The name taken by a player who claims nothing: a single presence without a rank is no
-- news, three in a row hide the kept rank until the character we read is seen again.
local savedServer = server
server = server + 2 * 86400
pool.claims["Rename Hero"].at = server
RP:OnPresence("Rename Hero", nil)
RP:OnPresence("Rename Hero", nil)
assert(RP:GetBadgeRank("Rename Hero") == 11, "two presences without a rank change nothing")
RP:OnPresence("Rename Hero", "15")
RP:OnPresence("Rename Hero", nil)
RP:OnPresence("Rename Hero", nil)
assert(RP:GetBadgeRank("Rename Hero") == 11, "a presence with the rank starts the count again")
RP:OnPresence("Rename Hero", nil)
assert(RP:GetBadgeRank("Rename Hero") == 0, "three in a row: another character, the kept rank waits")
RP:OnPresence("Rename Hero", "14")
assert(RP:GetBadgeRank("Rename Hero") == 11, "his rank said again, even another one: the wait from presences without it ends")
RP:OnPresence("Rename Hero", nil)
RP:OnPresence("Rename Hero", nil)
RP:OnPresence("Rename Hero", nil)
assert(RP:GetBadgeRank("Rename Hero") == 0, "three in a row again")
assert(RP:UnitBadge(pool, "nameplate3") == 11, "the character we read is seen: back")
-- A claim not heard for four weeks shows nothing; said again, it shows again; said again
-- lower than the rank shown, it waits until we see the character we read.
server = server + RP.CLAIM_QUIET + 86400
assert(RP:GetBadgeRank("Rename Hero") == 0, "four weeks of silence: no badge (the name may have changed hands)")
RP:OnPresence("Rename Hero", "15")
assert(RP:GetBadgeRank("Rename Hero") == 11, "his rank said again: the badge is back")
server = server + RP.CLAIM_QUIET + 86400
pool.claims["Rename Hero"].seen = nil
RP:OnPresence("Rename Hero", "11")
assert(RP:GetBadgeRank("Rename Hero") == 11, "the same rank as shown: back")
server = server + RP.CLAIM_QUIET + 86400
pool.shown["Rename Hero"].r = 13
RP.Invalidate("Rename Hero")
RP:OnPresence("Rename Hero", "12")
assert(RP:GetBadgeRank("Rename Hero") == 0, "after a silence, a lower rank than the one shown waits")
assert(RP:UnitBadge(pool, "nameplate3") == 13, "seen: back, at the rank shown before (a rank is for life)")
pool.shown["Rename Hero"].r = 11
server = savedServer
print("Rank proof: race-based factions and renamed claims OK")

-- 12. On a nameplate the badge sits where the name's text starts (Blizzard often centres the
-- text in a field as wide as the bar); without a name, left of the health bar.
local points = {}
CreateFrame = function(_, _, parent)
    local f = { parent = parent, shown = false }
    function f:SetSize() end
    function f:CreateTexture() return { SetAllPoints = function() end, SetTexture = function() end } end
    function f:GetParent() return self.parent end
    function f:SetParent(p) self.parent = p end
    function f:ClearAllPoints() end
    function f:SetPoint(...) points[#points + 1] = { ... } end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    return f
end
local nameText = { IsShown = function() return true end, GetStringWidth = function() return 60 end,
    GetWidth = function() return 120 end, GetJustifyH = function() return "CENTER" end }
local unitFrame = { name = nameText, healthBar = {} }
C_NamePlate.GetNamePlateForUnit = function() return { UnitFrame = unitFrame } end
RP:ShowPlate("nameplate9", 15)
local last = points[#points]
assert(last[1] == "RIGHT" and last[2] == nameText and last[3] == "LEFT" and last[4] == 28,
    "a centred name: the badge 2 px left of its text")
nameText.GetJustifyH = function() return "LEFT" end
RP:ShowPlate("nameplate9", 15)
assert(points[#points][4] == -2, "a name written from the left: the badge 2 px left of the field")
unitFrame.name = nil
RP:ShowPlate("nameplate9", 15)
last = points[#points]
assert(last[2] == unitFrame.healthBar and last[4] == -3, "no name: left of the health bar")
Overlord.MostWanted = { SKULL_SIZE = 16, skulls = { nameplate9 = { IsShown = function() return true end } } }
RP:ShowPlate("nameplate9", 15)
assert(points[#points][4] == -21, "with the Nemesis skull there: left of the skull")
Overlord.MostWanted = nil
CreateFrame = nil
print("Rank proof: nameplate badge placed at the start of the name OK")

-- 13. /ov proof: counts, then the target's proof and a diagnostic read.
local said = {}
Overlord.PrintNotification = function(_, text) said[#said + 1] = text end
units.target = { name = "Read Me", faction = "Alliance", guid = "Player-1-RM" }
now = now + RP.INSPECT_AGAIN + 100
RP:HandleCommand()
local joined = table.concat(said, "\n")
assert(joined:find("claims %d+") and joined:find("Read Me: claim 11, readings %d+")
    and joined:find("weeks proven top 1/3/10/25/100 %d+/%d+/%d+/%d+/%d+"), joined)
RP:EndInspect()
print("Rank proof: /ov proof report OK")

-- 14. Wiring: the instance hooks in Core.lua, the archive hooks in Leaderboard.lua, events
-- dropped in an instance and back after it, and the event dispatch.
local function source(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end
local core, board = source("Core.lua"), source("Leaderboard.lua")
assert(core:find("RankProof.OnInstanceSuspend", 1, true) and core:find("RankProof.OnInstanceResume", 1, true),
    "Core.lua suspends and resumes RankProof")
assert(board:find("RankProof.BeginClose", 1, true) and board:find("RankProof.OfferCloseRow", 1, true)
    and board:find("RankProof.FinishClose", 1, true), "the weekly archive feeds RankProof")
local registered = {}
RP.frame = {
    RegisterEvent = function(_, event) registered[event] = true end,
    UnregisterEvent = function(_, event) registered[event] = nil end,
}
RP:RegisterLiveEvents(true)
assert(registered.NAME_PLATE_UNIT_ADDED and registered.INSPECT_READY and registered.UPDATE_MOUSEOVER_UNIT,
    "live events registered")
RP:OnInstanceSuspend()
assert(next(registered) == nil, "nothing listened to in an instance")
RP:OnInstanceResume()
assert(registered.PLAYER_TARGET_CHANGED and registered.NAME_PLATE_UNIT_REMOVED, "back after the instance")
local dispatched = {}
local savedReady, savedHonor = RP.OnInspectReady, RP.OnInspectHonor
RP.OnInspectReady = function(_, guid) dispatched.ready = guid end
RP.OnInspectHonor = function() dispatched.honor = true end
RP:OnEvent("INSPECT_READY", "Player-1-XY")
RP:OnEvent("INSPECT_HONOR_UPDATE")
assert(dispatched.ready == "Player-1-XY" and dispatched.honor, "inspect events reach their handlers")
RP.OnInspectReady, RP.OnInspectHonor = savedReady, savedHonor
RP.frame = nil
print("Rank proof: wiring OK")

-- 15. Players of the other faction: their ranks from our own closes alone (every kill and
-- every top week our ranking gave them), as the Nemesis skull reads that ranking.
local savedEraBeta = RP.ERA_BETA
RP.ERA_BETA = RP.WEEK_REF
pool.ls, pool.lsWeek = {}, nil
local function enemyWeek(weekIndex, rows, flag)
    local horde = {}
    for _, row in ipairs(rows) do horde[#horde + 1] = { n = row[1], k = row[2] } end
    table.sort(horde, function(a, b) return a.k > b.k end)
    RP:FinishClose({ week = weekIndex, f = flag or 1, Alliance = {}, Horde = horde })
end
for i = 1, 5 do enemyWeek(cur - 20 + i, { { "Foe King", 30000 }, { "Foe Low", 900 } }) end
assert(RP:EnemyRank(pool, "Foe King", "Horde") == 15, "five first places and 150,000 kills in our closes: Overlord")
assert(RP:EnemyRank(pool, "Foe Low", "Horde") == 0, "second five times with 4,500 kills: no rank (Glory not reached)")
enemyWeek(cur - 20 + 5, { { "Foe King", 30000 } })
assert(pool.ls.Horde["Foe King"].k == 150000 and pool.ls.Horde["Foe King"][1] == 5, "a week is counted once")
for i = 6, 8 do enemyWeek(cur - 20 + i, { { "Foe Played", 30000 } }, 0) end
for i = 9, 11 do enemyWeek(cur - 20 + i, { { "Foe Played", 30000 } }, 0) end
assert(RP:EnemyRank(pool, "Foe Played", "Horde") == 13,
    "first on closes not compared: top 10 weeks, Crown Prince, never Sovereign or Overlord")
-- Shown in the ranking (our ranking labels him Horde) and on his nameplate.
Overlord.Leaderboard = { GetPlayerInfo = function(_, who) return who == "Foe King" and { faction = "Horde" } or nil end }
assert(RP:GetBadgeRank("Foe King") == 15, "his ranking row carries the badge")
Overlord.Leaderboard = nil
units.enemy1 = { name = "Foe King", faction = "Horde", guid = "Player-2-FK" }
assert(RP:UnitBadge(pool, "enemy1") == 15, "his nameplate carries the badge")
Overlord.InstanceSuspended = true
assert(RP:UnitBadge(pool, "enemy1") == 0, "never in an instance")
Overlord.InstanceSuspended = false
-- The rank never shows more than his Glory: kills short of the whole Glory, no rank.
for i = 12, 14 do enemyWeek(cur - 20 + i, { { "Foe Short", 26000 } }) end
assert(RP:EnemyRank(pool, "Foe Short", "Horde") == 0, "78,000 kills: below rank 10's 100,000 Glory, no top rank")
-- A name the ranking set aside shows nothing.
denied["Foe King"] = true
RP.Invalidate()
assert(RP:EnemyRank(pool, "Foe King", "Horde") == 0, "set aside: no badge")
denied["Foe King"] = nil
RP.Invalidate()
-- A week dated beyond the current one is no real close.
local before15 = pool.lsWeek
enemyWeek(cur + 30, { { "Foe King", 30000 } })
assert(pool.lsWeek == before15 and pool.ls.Horde["Foe King"].k == 150000, "a week from the future changes nothing")
-- A player of our faction never takes this path, whatever label the ranking holds.
pool.claims["Foe King"] = { r = 15, at = server, f = "Alliance" }
Overlord.Leaderboard = { GetPlayerInfo = function(_, who) return who == "Foe King" and { faction = "Horde" } or nil end }
RP.Invalidate()
assert(RP:GetBadgeRank("Foe King") == 0, "a claimant labelled on the other side: our own proof only (none here)")
units.ally9 = { name = "Foe King", faction = "Alliance", guid = "Player-1-FK" }
assert(RP:UnitBadge(pool, "ally9") == 0, "on his nameplate too")
Overlord.Leaderboard = nil
pool.claims["Foe King"] = nil
RP.Invalidate()
RP.ERA_BETA = savedEraBeta
pool.era = nil
print("Rank proof: ranks of the other faction OK")

-- 16. Our own word in our presence: one week in turn, from our own rank record (server
-- counter deltas), never the ranking's row.
local function b36w(n)
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    if n == 0 then return "0" end
    while n > 0 do local d = n % 36 out = digits:sub(d + 1, d + 1) .. out n = (n - d) / 36 end
    return out
end
local savedEra16 = RP.ERA_BETA
RP.ERA_BETA = RP.WEEK_REF
local savedRecord, savedCharDB = R.GetRecord, OverlordCharDB
OverlordCharDB = {}
localRank = 13
R.GetRecord = function() return { we = 1792483200, wk = 1234, pe = 1792483200 - RP.WEEK_SEC, pk = 999 } end
local wk = RP.WeekIndex(1792483200)
local said = {}
for i = 1, 3 do
    said[i] = RP:PresenceToken()
    assert(RP:PresenceToken() == said[i], "the same presence interval says the same week (a repeat stays identical)")
    now = now + 120
end
local first, second = "~q13." .. b36w(wk) .. "-" .. b36w(1234), "~q13." .. b36w(wk - 1) .. "-" .. b36w(999)
assert(said[1] ~= said[2] and said[3] == said[1] and (said[1] == first or said[1] == second)
    and (said[2] == first or said[2] == second), "each presence interval says one week of our own count, in turn: "
    .. table.concat(said, " "))
R.GetRecord = function() return { we = 1792483200, wk = 1500 } end
RP:PresenceToken()
assert(OverlordCharDB.rankWord[wk] == 1500 and OverlordCharDB.rankWord[wk - 1] == 999, "our log keeps every week said")
for w = 1, 70 do OverlordCharDB.rankWord[wk - 30 - w] = 100 end
RP:PresenceToken()
local logged = 0
for _ in pairs(OverlordCharDB.rankWord) do logged = logged + 1 end
assert(logged == RP.WORD_WEEKS, "our log keeps the most recent weeks (" .. logged .. ")")
localRank = 0
assert(RP:PresenceToken() == "", "below rank 11, nothing")
R.GetRecord, OverlordCharDB = savedRecord, savedCharDB

-- His word as heard: highest per week, never a week to come, bounded; a malformed token
-- is no claim.
pool.ow = {}
RP:OnPresence("Word Hero", "12." .. b36w(cur - 2) .. "-" .. b36w(800))
RP:OnPresence("Word Hero", "12." .. b36w(cur - 2) .. "-" .. b36w(700))
assert(pool.claims["Word Hero"].r == 12 and pool.ow["Word Hero"][cur - 2] == 800, "the highest word of a week is kept")
RP:OnPresence("Word Hero", "12." .. b36w(cur + 3) .. "-" .. b36w(5000))
assert(pool.ow["Word Hero"][cur + 3] == nil, "never a week to come")
for w = 1, 70 do RP:OnPresence("Word Hero", "12." .. b36w(cur - w) .. "-" .. b36w(100 + w)) end
local heard = 0
for _ in pairs(pool.ow["Word Hero"]) do heard = heard + 1 end
assert(heard == RP.WORD_WEEKS, "sixty weeks of his word at most (" .. heard .. ")")
RP:OnPresence("Bad Word", "15.zz")
RP:OnPresence("Bad Word", "15.-5")
assert(pool.claims["Bad Word"] == nil, "a malformed token is no claim")
RP.ERA_BETA = savedEra16
print("Rank proof: own word said and heard OK")

-- 17. Own word, the audit's cases.
local savedEraAll = RP.ERA_BETA
RP.ERA_BETA = RP.WEEK_REF
-- A true low word never keeps the place of an inflated row: the week counts at his word's top.
wipe()
pool.ow, pool.lw = {}, {}
claim("Low Word", "15")
local crowd = { ["Low Word"] = { 1, 30000 } }
for i = 1, 10 do crowd["Crowd " .. letters(i)] = { i + 1, 3000 } end
ourClose(cur - 4, crowd)
reading("Low Word", cur - 5, 100000)
reading("Low Word", cur - 3, 100200)
say("Low Word", 15, cur - 4, 150)
local lowProven, lowDoubt, _, _, lowUnverified = RP:Evidence(pool, "Low Word", "Alliance")
assert(lowDoubt[cur - 4] and (lowProven[cur - 4] or lowUnverified[cur - 4]) == 25,
    "his word (150) is eleventh in that close: the week counts as a top 25, not the first place of the row")
-- A reading that lags the server never makes an honest player a liar for good.
wipe()
pool.ow, pool.lw = {}, {}
claim("Lag King", "11")
ourClose(cur - 4, { ["Lag King"] = { 31, 5000 } })
reading("Lag King", cur - 5, 100000)
reading("Lag King", cur - 3, 100100)
say("Lag King", 11, cur - 4, 5000)
RP:GetBadgeRank("Lag King")
assert(pool.lw["Lag King"] == nil, "a word beyond a single newest reading is not yet a lie for good")
reading("Lag King", cur - 1, 105500)
RP:GetBadgeRank("Lag King")
assert(pool.lw["Lag King"] == nil, "the next reading catches up: never a liar")
-- A word a little beyond the server (a few hours of kills not yet in the count) is no lie.
wipe()
pool.ow, pool.lw = {}, {}
claim("Near King", "11")
ourClose(cur - 4, { ["Near King"] = { 31, 5000 } })
reading("Near King", cur - 5, 100000)
reading("Near King", cur - 3, 104800)
say("Near King", 11, cur - 4, 5000)
local nearLied = select(8, RP:Evidence(pool, "Near King", "Alliance"))
assert(not nearLied[cur - 4], "5,000 said, 4,800 counted: within the margin, no lie")
-- Our word is logged before rank 11 (the weeks that make a top rank come before it).
local savedRecord17, savedCharDB17, savedEra17 = R.GetRecord, OverlordCharDB, RP.ERA_BETA
OverlordCharDB, RP.ERA_BETA = {}, RP.WEEK_REF
R.GetRecord = function() return { we = 1792483200, wk = 2500 } end
localRank = 0
assert(RP:PresenceToken() == "" and OverlordCharDB.rankWord[RP.WeekIndex(1792483200)] == 2500,
    "below rank 11 nothing is said, but the week is logged")
R.GetRecord, OverlordCharDB, RP.ERA_BETA = savedRecord17, savedCharDB17, savedEra17
-- A word for a week before the era is not kept.
RP.ERA_BETA = savedEraAll
pool.ow = {}
RP:OnPresence("Era Hero", "12." .. b36w(cur - 5) .. "-" .. b36w(900))
assert(pool.ow["Era Hero"] == nil, "a word from before the era is ignored")
RP.ERA_BETA = RP.WEEK_REF
-- Before the dated switch, a doubtful week without his word is excused as before.
wipe()
pool.ow, pool.lw = {}, {}
claim("Old Switch", "11")
ourClose(cur - 5, { ["Old Switch"] = { 31, 600 } })
ourClose(cur - 4, { ["Old Switch"] = { 31, 600 } })
ourClose(cur - 2, { ["Old Switch"] = { 31, 3000 } })
closeEra()
reading("Old Switch", cur - 6, 80000)
reading("Old Switch", cur - 3, 81300)
reading("Old Switch", cur, 81400)
assert(RP:GetBadgeRank("Old Switch") == 0, "after the switch: waits for his word")
RP.WORD_FROM = RP.ERA_LAUNCH
RP.Invalidate()
assert(RP:GetBadgeRank("Old Switch") == 11, "before the switch: excused without his word")
RP.WORD_FROM = RP.WEEK_REF
RP.ERA_BETA = savedEraAll
pool.era = nil
print("Rank proof: own word audit cases OK")

-- 18. Ranks are never lost.
local savedEra18 = RP.ERA_BETA
RP.ERA_BETA = RP.WEEK_REF
-- A rename: what we knew follows the character (his GUID).
wipe()
pool.ow, pool.lw = {}, {}
pool.gd["Old Name"], pool.rd["Old Name"] = "Player-1-RN", { [cur - 3] = { l = 90000, t = 0, a = server } }
pool.shown["Old Name"] = { r = 13, at = server }
claim("New Name", "13")
RP:StoreReading("New Name", 91000, 0, "Player-1-RN")
assert(pool.shown["New Name"] and pool.shown["New Name"].r == 13 and pool.gd["Old Name"] == nil
    and RP:GetBadgeRank("New Name") == 13, "renamed: his badge follows him")
-- A rank shown is never aged out.
pool.shown["New Name"].at = server - 3 * 52 * RP.WEEK_SEC
RP:Prune(pool)
assert(pool.shown["New Name"], "three years without a sighting: still kept")
-- A name the ranking set aside shows no badge.
denied["New Name"] = true
RP.Invalidate()
assert(RP:GetBadgeRank("New Name") == 0, "set aside: no badge")
denied["New Name"] = nil
-- A rival inflating every row of his never keeps him from starting a rank: his word proves.
wipe()
pool.ow, pool.lw = {}, {}
claim("Inflated Hero", "11")
for w = cur - 6, cur - 2 do ourClose(w, { ["Inflated Hero"] = { 31, 9000 } }) end
closeEra()
for w = cur - 7, cur - 1 do reading("Inflated Hero", w, 80000 + (w - cur + 7) * 700) end
for w = cur - 6, cur - 2 do say("Inflated Hero", 11, w, 650) end
assert(RP:GetBadgeRank("Inflated Hero") == 11, "every row inflated by another, his word fits: Dragon Lord")
-- A word judged short by a lagging reading and cleared by the next one is no lie at all.
wipe()
pool.ow, pool.lw = {}, {}
claim("Clear King", "11")
ourClose(cur - 4, { ["Clear King"] = { 31, 5000 } })
reading("Clear King", cur - 5, 100000)
reading("Clear King", cur - 3, 100100)
reading("Clear King", cur - 2, 105500)
say("Clear King", 11, cur - 4, 5000)
local clearLied = select(8, RP:Evidence(pool, "Clear King", "Alliance"))
assert(not clearLied[cur - 4], "the reading of the very next week clears it: no lie")
-- A reading weeks later never clears it: the kills made since would pay for the lie.
pool.rd["Clear King"][cur - 2] = nil
reading("Clear King", cur, 107000)
local farLied = select(8, RP:Evidence(pool, "Clear King", "Alliance"))
assert(farLied[cur - 4], "a later reading three weeks on does not clear the lie")
-- Another character under a holder's name: the holder's proof is set aside, and comes back
-- when we meet him again, under any name.
pool.park = {}
pool.gd["Park Hero"], pool.shown["Park Hero"] = "Player-1-PH", { r = 14, at = server }
pool.vw["Park Hero"] = { [cur - 3] = 3 }
units.parkUnit = { name = "Park Hero", faction = "Alliance", guid = "Player-1-OTHER" }
RP:SameCharacter(pool, "Park Hero", "parkUnit")
assert(pool.shown["Park Hero"] == nil and pool.park["Player-1-PH"], "another character: the holder's proof is set aside")
claim("Park Renamed", "14")
RP:StoreReading("Park Renamed", 120000, 0, "Player-1-PH")
assert(pool.shown["Park Renamed"] and pool.shown["Park Renamed"].r == 14 and pool.park["Player-1-PH"] == nil,
    "met again under a new name: his rank is back")
RP.ERA_BETA = savedEra18
pool.era = nil
print("Rank proof: ranks never lost OK")

-- 19. A lie is never paid for by the kills of a week he kept silent about.
local savedEra19 = RP.ERA_BETA
RP.ERA_BETA = RP.WEEK_REF
wipe()
pool.ow, pool.lw = {}, {}
claim("Silent King", "15")
ourClose(cur - 3, { ["Silent King"] = { 1, 3000 } })
ourClose(cur - 2, { ["Silent King"] = { 40, 1500 } })
reading("Silent King", cur - 4, 100000)
reading("Silent King", cur - 2, 101000)
reading("Silent King", cur - 1, 103000)
say("Silent King", 15, cur - 3, 3000)
local silentProven, _, _, _, _, _, _, silentLied = RP:Evidence(pool, "Silent King", "Alliance")
assert(silentLied[cur - 3] and not silentProven[cur - 3],
    "3,000 said, 1,000 counted, the next week's kills unsaid: the lie stands, the first place is not proven")
RP.ERA_BETA = savedEra19
pool.era = nil
print("Rank proof: silent week OK")

-- 20. A word within the lie margin but beyond the rows' slack is no lie, yet proves nothing alone.
local savedEra20 = RP.ERA_BETA
RP.ERA_BETA = RP.WEEK_REF
wipe()
pool.ow, pool.lw = {}, {}
claim("Loose King", "15")
ourClose(cur - 3, { ["Loose King"] = { 1, 3000 } })
reading("Loose King", cur - 4, 100000)
reading("Loose King", cur - 2, 102800)
say("Loose King", 15, cur - 3, 3000)
local looseProven, looseDoubt, _, _, looseUnverified, _, _, looseLied = RP:Evidence(pool, "Loose King", "Alliance")
assert(looseDoubt[cur - 3] and not looseLied[cur - 3], "2,800 counted for 3,000 said: doubtful, not a lie")
assert(not looseProven[cur - 3] and looseUnverified[cur - 3],
    "his word too loose to prove the week: it only completes a rank")
RP.ERA_BETA = savedEra20
pool.era = nil
print("Rank proof: loose word OK")

-- 21. The same for a lie about a reading's own week: the next week's unsaid kills never pay it.
local savedEra21 = RP.ERA_BETA
RP.ERA_BETA = RP.WEEK_REF
wipe()
pool.ow, pool.lw = {}, {}
claim("Hush King", "15")
ourClose(cur - 3, { ["Hush King"] = { 1, 3000 } })
ourClose(cur - 2, { ["Hush King"] = { 40, 3000 } })
reading("Hush King", cur - 5, 100000)
reading("Hush King", cur - 3, 100000)
reading("Hush King", cur - 2, 101000)
reading("Hush King", cur - 1, 104000)
say("Hush King", 15, cur - 3, 3000)
local _, _, _, _, _, _, _, hushLied = RP:Evidence(pool, "Hush King", "Alliance")
assert(hushLied[cur - 3], "3,000 said for a week the server counted 1,000 in: the unsaid week after never clears it")
RP.ERA_BETA = savedEra21
pool.era = nil
print("Rank proof: hushed reading week OK")

-- 22. Only a holder's proof is set aside: a plain name taken over never fills the park.
pool.park = {}
pool.gd["Plain Nobody"] = "Player-1-PN"
reading("Plain Nobody", cur - 2, 500)
RP:ForgetCharacter(pool, "Plain Nobody")
assert(next(pool.park) == nil and pool.rd["Plain Nobody"] == nil, "nothing shown: forgotten, not parked")
print("Rank proof: park holders only OK")
