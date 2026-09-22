-- A campaign-scoped removal must clear an existing replicated row and reject
-- stale copies without suppressing the player's next campaign.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local name = "Roxymigurdia Greyrat"
local sync, lb = Overlord.Sync, Overlord.Leaderboard
local timers = {}
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end

OverlordDB.campaignId = 20260922
assert(sync:IsDeniedKillContributor(name), "Current campaign row is not excluded")
lb.kills[name] = 998
OverlordDB.leaderboard.kills = lb.kills
OverlordDB.leaderboardScoreSanitizeVersion = 2
lb:EnsureLegacyScoreSanitized()
local attempts = 0
while OverlordDB.leaderboardScoreSanitizeVersion ~= 3 and #timers > 0 do
    attempts = attempts + 1
    assert(attempts < 20, "Score cleanup did not finish within its bounded slices")
    table.remove(timers, 1)()
end
assert(OverlordDB.leaderboardScoreSanitizeVersion == 3, "Score cleanup did not commit")
assert(lb.kills[name] == nil, "Existing score was not removed")
lb:RegisterKill(name, true)
lb:SetPlayerKills(name, 998, true)
assert(lb.kills[name] == nil, "An old peer restored the removed score")

OverlordDB.campaignId = 20260929
assert(not sync:IsDeniedKillContributor(name), "Player remained excluded next week")
assert(not sync:IsDeniedKillContributor("Unrelated Player"), "Another player's score was blocked")
print("Forever kill-row removal: current-week purge, stale relay rejection, next-week expiry OK")
