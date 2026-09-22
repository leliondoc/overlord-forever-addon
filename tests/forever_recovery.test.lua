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
local other = {bucket={kills={['Remote Player']=7}}, resetEpoch=epoch}
OverlordDB.leaderboardPreviousCampaigns = {us=other}
assert(lb:OpenAtomicWeeklyBucket(epoch, epoch + 604800, 20260923))
local backup = OverlordDB.leaderboardPreviousCampaigns.global
assert(backup and backup.bucket.kills['Player Number1'] == 1, 'Lower ranks lost')
assert(backup.bucket.captureCount['Player Number200'] == 1)
assert(backup.bucket.playerInfo['Player Number1'].guild == 'Recovery Guild', 'Metadata lost')
assert(backup.bucket.captures['Player Number1'][1] == 'loch_valley_of_kings')
assert(OverlordDB.leaderboardPreviousCampaigns.us == other, 'Cross-region archive modified')
assert(next(lb.kills) == nil, 'Previous campaign was added to new scores')
lb.kills['New Player'] = 2
assert(backup.bucket.kills['New Player'] == nil, 'Recovery table aliases current campaign')
lb:OpenAtomicWeeklyBucket(epoch, epoch + 604800, 20260923)
assert(OverlordDB.leaderboardPreviousCampaigns.global == backup, 'Repeated reset overwrote checkpoint')

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
assert(lb.kills['New Player'] == 2 and backup.bucket.kills['Player Number1'] == 1)
print('Forever recovery: complete previous campaign, metadata, region isolation, idempotence and read-only diagnosis OK')
