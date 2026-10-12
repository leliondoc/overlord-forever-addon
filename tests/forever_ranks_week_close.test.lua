-- Overlord Rank through the real ladder: the real credit paths of Leaderboard.lua feed
-- the glory and the week's own count, and the real weekly archive walks the finished
-- week in slices while the place of each character of the account is counted along
-- the way. A broken rank module never stops a kill, a capture or the archive.
assert(loadfile('tests/forever_leaderboard.test.lua'))()
local timers = {}
C_Timer.After = function(_, fn) timers[#timers + 1] = fn end
local function pump()
    local guard = 0
    while #timers > 0 do
        guard = guard + 1
        assert(guard < 100000, 'the weekly archive never finishes')
        table.remove(timers, 1)()
    end
end
-- The fixture's clock is fixed; here the weeks go by.
local clock = GetServerTime()
GetServerTime = function() return clock end
local lines = {}
Overlord.PrintNotification = function(_, text) lines[#lines + 1] = text end
assert(loadfile('RankLocales.lua'))()
assert(loadfile('Ranks.lua'))()
local R, lb = Overlord.Ranks, Overlord.Leaderboard
local me = Overlord.Sync:GetPlayerFullName()
local faction = Overlord.PlayerFaction
assert(me == 'Warrior Tester' and faction == 'Horde', 'fixture identity changed')
local enemy = 'Alliance'
-- Forever names hold letters only: a row with a digit is refused by the ladder's own
-- name rule and would not count.
local function letters(index)
    local text = ''
    repeat
        text = string.char(97 + index % 26) .. text
        index = math.floor(index / 26)
    until index == 0
    return text
end
assert(not Overlord.Sync:IsDeniedKillContributor('Ally Aa'), 'fixture names must be valid')

-- The ladder's real credit paths: only what this client counted itself reaches the
-- ranks, a record is born empty, and the week's own count follows the local kills.
lb.kills[me] = 40
lb.captureCount[me] = 9
lb:RegisterKill(me)
lb:AddKills(me, 4, false)
local rec = OverlordDB.ranksByCharacter and OverlordDB.ranksByCharacter[me]
assert(rec and rec.k == 5 and lb.kills[me] == 45, 'five local kills, five glory, whatever the row held')
assert(rec.wk == 5 and rec.we == OverlordDB.leaderboard.campaignStart and rec.f == faction,
    'the week count, its week and the faction are kept')
lb:AddKills(me, 50, true)
lb:RegisterKill(me, true)
lb:RegisterKill('Ally Aa')
lb:AddPlayerCapture(me, 'loch_valley_of_kings', true)
assert(rec.k == 5 and rec.c == 0 and rec.wk == 5, 'rows received from the network credit nothing')
lb:AddPlayerCapture(me, 'loch_valley_of_kings')
assert(rec.c == 1 and rec.wk == 5, 'a local capture is credited, apart from the week count')
-- (Five kills and one capture: a first rank only if a capture is worth ten or more.)
local firstRank = 5 + R.GLORY_PER_CAPTURE >= R.TIERS[1].glory
assert(#lines == (firstRank and 1 or 0), 'a rank is announced when its glory is reached, not before')
Overlord.InstanceSuspended = true
lb:AddKills(me, 3, false)
Overlord.InstanceSuspended = false
assert(rec.k == 5, 'nothing credited in an instance')
-- A rank module that throws must never stop a kill from being counted and returned.
local keep = R.CreditLocal
R.CreditLocal = function() error('boom') end
local total = lb:RegisterKill(me)
assert(type(total) == 'number' and total == lb.kills[me], 'the ladder survives a failing rank credit')
R.CreditLocal = keep

-- The date at which this ranking's kills were last compared in full (kept per ranking).
local function comparedAt(at)
    local pool = Overlord.GetCurrentLeaderboardSavedVarsPool and Overlord:GetCurrentLeaderboardSavedVarsPool()
    OverlordDB.ranksLadderSeenAt = { [type(pool) == 'string' and pool ~= '' and pool or '-'] = at }
end

-- A week of the ladder: our kills counted here (count), allies above that count,
-- enemies far above, weaker allies below.
local function playWeek(count, alliesAbove)
    for key in pairs(lb.kills) do lb.kills[key] = nil end
    lb:AddKills(me, count, false)
    lb.playerInfo[me] = lb.playerInfo[me] or {}
    lb.playerInfo[me].faction = faction
    -- The first week already holds the five kills credited above.
    local score = rec.wk
    for index = 1, 400 do
        local ally, foe = 'Ally A' .. letters(index), 'Foe F' .. letters(index)
        lb.kills[ally] = index <= alliesAbove and score + index or math.max(1, score - 1 - index % 250)
        lb.playerInfo[ally] = { faction = faction }
        lb.kills[foe] = 100000 + index
        lb.playerInfo[foe] = { faction = enemy }
    end
    comparedAt(OverlordDB.leaderboard.campaignStart + 604800 - 3600)
end
local function closeWeek()
    local epoch = OverlordDB.leaderboard.campaignStart
    -- The reset is processed at the reset: the clock is then the start of the new week.
    clock = epoch + 604800
    assert(lb:OpenAtomicWeeklyBucket(epoch, epoch + 604800, 20261013), 'the week did not close')
    pump()
    -- The reset's other steps (Leaderboard:Reset, Core) are not run here: they are
    -- what clears a completed marker.
    local marker = OverlordDB.pendingWeeklyArchive
    assert(marker == nil or (marker.archiveComplete == true and marker.bucket == nil),
        'the archive did not complete')
    OverlordDB.pendingWeeklyArchive = nil
    return epoch
end

-- Eighth of the faction among 800 rows, ranking seen up to date an hour before the reset.
lines = {}
playWeek(300, 7)
local glory = rec.k
local epoch = closeWeek()
assert(rec.t and rec.t[100] == 1 and rec.t[25] == 1 and rec.t[10] == 1 and rec.t[3] == nil,
    'eighth of the faction: top 100, 25 and 10')
assert(rec.k == glory and rec.lw == epoch, 'the week is marked, the glory untouched')
assert(#lines >= 1 and lines[#lines]:find('8') and lines[#lines]:find('10'), 'a line with the place')
local history = 0
for _, entry in pairs(OverlordDB.history or {}) do
    history = history + 1
    assert(entry.kills['Foe F' .. letters(400)] == 100400, 'the archive itself is intact')
end
assert(history == 1, 'one archived week')

-- Next week: our own row raised by somebody else gives nothing (the count is local),
-- a row of a refused name is not somebody above, and an alt of the account that
-- played the week is placed although another character is logged in.
-- (The alt's record is born the way the addon makes one: a record written by hand
-- carries no seal and would be set aside.)
local realName = Overlord.Sync.GetPlayerFullName
Overlord.Sync.GetPlayerFullName = function() return 'Mage Tester' end
R:CreditLocal('kills', 10)
Overlord.Sync.GetPlayerFullName = realName
local alt = OverlordDB.ranksByCharacter['Mage Tester']
alt.f = enemy
playWeek(300, 1)
lb.kills[me] = 99999
alt.we, alt.wk = OverlordDB.leaderboard.campaignStart, 200000
lb.kills['Mage Tester'] = 1
lb.playerInfo['Mage Tester'] = { faction = faction }
lb.kills['Cheat3r Row'] = 999999
lb.playerInfo['Cheat3r Row'] = { faction = faction }
lines = {}
closeWeek()
assert(rec.t[100] == 2 and rec.t[3] == 1 and rec.t[10] == 2,
    'second behind one real ally: the raised row and the refused row count for nothing')
assert(alt.t and alt.t[3] == 1, 'the alt that played the week is first of its faction')
assert(#lines == 1 and lines[1]:find('2'), 'only the logged character is told')
assert(OverlordDB.ranksByCharacter['Ally Aa'] == nil, 'no record for a character that is not ours')
OverlordDB.ranksByCharacter['Mage Tester'] = nil

-- Next week: a ranking last seen up to date three days before the reset is not counted.
playWeek(300, 0)
comparedAt(OverlordDB.leaderboard.campaignStart + 604800 - 3 * 86400)
closeWeek()
assert(rec.t[100] == 2 and rec.t[3] == 1, 'a stale ranking gives no placement')
assert(#lines == 1, 'and nothing is said about it in the chat: ' .. tostring(lines[2]))

-- A kill credited after the reset and before the archive's probes are built: it
-- belongs to the new week, and the finished week is still placed from its own count.
-- (In the game the archive starts inside the reset itself; the probes are rebuilt
-- later only when the archive is resumed after a reload, a logout or a crash. The
-- fixture's deferred start stands for that resumed archive.)
playWeek(1500, 0)
local firstBefore, finishedEpoch = rec.t[1] or 0, OverlordDB.leaderboard.campaignStart
clock = finishedEpoch + 604800
assert(lb:OpenAtomicWeeklyBucket(finishedEpoch, finishedEpoch + 604800, 20261013), 'the week did not close')
lb:RegisterKill(me)
assert(rec.we ~= finishedEpoch and rec.wk == 1 and rec.pe == finishedEpoch and rec.pk == 1500,
    'the kill opens the new week and the finished week keeps its count: ' .. tostring(rec.wk) .. ' ' .. tostring(rec.pk))
pump()
assert((rec.t[1] or 0) == firstBefore + 1 and rec.lw == finishedEpoch,
    'the finished week was lost to a kill credited before its close')
OverlordDB.pendingWeeklyArchive = nil

-- A rank module that throws on every call: the archive still completes.
playWeek(300, 0)
local probed = 0
R.ProbeWeekRow = function() probed = probed + 1; error('boom') end
R.FinishWeekClose = function() error('boom') end
closeWeek()
assert(probed == 1, 'a failing probe is dropped after its first error, got ' .. probed)
R.BeginWeekClose = function() error('boom') end
playWeek(300, 0)
closeWeek()
history = 0
for _ in pairs(OverlordDB.history or {}) do history = history + 1 end
assert(history == 6 and rec.t[100] == 3, 'six weeks archived, nothing credited by the broken module')
print('Forever ranks: real credit paths, place counted along the real weekly archive, archive safe OK')
