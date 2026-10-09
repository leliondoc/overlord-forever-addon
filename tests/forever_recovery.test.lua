-- Reuse the real capture/save/login fixture, then exercise a real bucket rollover.
assert(loadfile('tests/forever_leaderboard.test.lua'))()
local lb = Overlord.Leaderboard
local epoch = OverlordDB.lastResetTimestamp
for i = 1, 200 do
    local name = 'Player Number' .. i
    lb.kills[name] = i
    lb.captureCount[name] = 1
    lb.captures[name] = {'loch_valley_of_kings'}
    lb.playerInfo[name] = {guild='Recovery Guild', faction='Alliance', race='Dwarf'}
end
lb:Save()
-- 1.8.0: the finished week is no longer copied (an old copy is dropped too); its
-- top 100 stays in the compact history.
OverlordDB.leaderboardPreviousCampaigns = {us={bucket={kills={['Remote Player']=7}}, resetEpoch=epoch}}
assert(lb:OpenAtomicWeeklyBucket(epoch, epoch + 604800, 20260923))
assert(OverlordDB.leaderboardPreviousCampaigns == nil, 'A copy of the finished week was kept')
assert(next(lb.kills) == nil, 'Previous campaign was added to new scores')
lb.kills['New Player'] = 2
lb:OpenAtomicWeeklyBucket(epoch, epoch + 604800, 20260923)
assert(OverlordDB.leaderboardPreviousCampaigns == nil, 'A repeated reset kept a copy')

-- Diagnostics work before initialization and in instances, without changing saves.
SlashCmdList = {}
local lines = {}
Overlord.PrintNotification = function(_, s) lines[#lines+1] = s end
Overlord.IsInitialized, Overlord.InstanceSuspended = false, true
Overlord.SavedVariablesLoadedAtLogin = true
Overlord.SavedVariablesCampaignAtLogin = epoch
OverlordDB.history = { old = {campaignStart=epoch, kills={A=27}, captureCounts={A=13}} }
assert(loadfile('Commands.lua'))()
SlashCmdList.OVERLORD('persistence')
assert(#lines == 4 and lines[1]:find('true') and lines[4]:find('27 kills, 13 captures'))
assert(lb.kills['New Player'] == 2)
print('Forever recovery: finished week in the compact history only, idempotent reset and read-only diagnosis OK')
