-- Top ranks seen by others, through the real weekly archive: the walk of the finished week
-- keeps each faction's top 100 for RankProof (with whether the ranking was compared in
-- time), and a failing RankProof never stops the archive nor the ranks' own close.
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
local clock = GetServerTime()
GetServerTime = function() return clock end
Overlord.PrintNotification = function() end
OverlordCharDB = {}
assert(loadfile('RankLocales.lua'))()
assert(loadfile('Ranks.lua'))()
assert(loadfile('RankProof.lua'))()
-- (The fixture's weeks are older than the beta era: the era starts earlier here.)
Overlord.RankProof.ERA_BETA = Overlord.RankProof.WEEK_REF
local R, RP, lb = Overlord.Ranks, Overlord.RankProof, Overlord.Leaderboard
Overlord.GetCurrentCampaignStartTs = function() return OverlordDB.leaderboard.campaignStart end
local me, faction = Overlord.Sync:GetPlayerFullName(), Overlord.PlayerFaction
assert(me == 'Warrior Tester' and faction == 'Horde', 'fixture identity changed')
local function letters(index)
    local text = ''
    repeat
        text = string.char(97 + index % 26) .. text
        index = math.floor(index / 26)
    until index == 0
    return text
end

local function comparedAt(at)
    local pool = Overlord.GetCurrentLeaderboardSavedVarsPool and Overlord:GetCurrentLeaderboardSavedVarsPool()
    OverlordDB.ranksLadderSeenAt = { [type(pool) == 'string' and pool ~= '' and pool or '-'] = at }
end
local function playWeek()
    for key in pairs(lb.kills) do lb.kills[key] = nil end
    lb:AddKills(me, 150, false)
    lb.playerInfo[me] = lb.playerInfo[me] or {}
    lb.playerInfo[me].faction = faction
    lb.kills['Mate Leader'] = 2400
    lb.playerInfo['Mate Leader'] = { faction = faction }
    lb.kills['Mate Small'] = 300
    lb.playerInfo['Mate Small'] = { faction = faction }
    for index = 1, 300 do
        local ally, foe = 'Ally A' .. letters(index), 'Foe F' .. letters(index)
        lb.kills[ally] = 100 + index
        lb.playerInfo[ally] = { faction = faction }
        lb.kills[foe] = 100000 + index
        lb.playerInfo[foe] = { faction = 'Alliance' }
    end
    comparedAt(OverlordDB.leaderboard.campaignStart + 604800 - 3600)
end
local function closeWeek()
    local epoch = OverlordDB.leaderboard.campaignStart
    clock = epoch + 604800
    assert(lb:OpenAtomicWeeklyBucket(epoch, epoch + 604800, 20261013), 'the week did not close')
    pump()
    local marker = OverlordDB.pendingWeeklyArchive
    assert(marker == nil or (marker.archiveComplete == true and marker.bucket == nil), 'the archive did not complete')
    OverlordDB.pendingWeeklyArchive = nil
    return epoch
end

playWeek()
local week = RP:CurrentWeek()
local epoch = closeWeek()
assert(RP.WeekIndex(epoch) == week and RP:CurrentWeek() == week + 1, 'the week moved on')
local pool = RP:Pool()
local view = pool.close[week]
assert(view and view.f == 1, 'our close of the week is kept, ranking compared in time')
local count = 0
for _ in pairs(view.Horde) do count = count + 1 end
assert(count == RP.CLOSE_TOP and view.Horde['Mate Leader'] == 65536 + 2400, 'our faction top 100 is kept')
assert(view.Alliance['Foe F' .. letters(300)] == 65536 + 65535, 'the other faction top 100 too (kills capped)')
assert(RP:WeekOf(pool, 'Mate Leader', week, 'Horde') == 1, 'first of the faction with 2,400 kills: a first place')

-- A RankProof failing in every hook: the archive and the ranks' close still complete.
playWeek()
lb:AddKills(me, 150, false)
local keep = { RP.BeginClose, RP.OfferCloseRow, RP.FinishClose }
RP.OfferCloseRow = function() error('boom') end
local recBefore = OverlordDB.ranksByCharacter and OverlordDB.ranksByCharacter[me]
closeWeek()
RP.FinishClose = function() error('boom') end
RP.BeginClose = function() error('boom') end
playWeek()
closeWeek()
RP.BeginClose, RP.OfferCloseRow, RP.FinishClose = keep[1], keep[2], keep[3]
local rec = OverlordDB.ranksByCharacter and OverlordDB.ranksByCharacter[me]
assert(rec and recBefore and rec.lw and rec.lw > 0, 'the ranks close still ran')
print('Rank proof close: top 100 views of both factions, places by our ranking, failures contained OK')
