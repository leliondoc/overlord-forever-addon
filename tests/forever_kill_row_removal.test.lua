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
OverlordDB.leaderboardsByPool = { global = { kills = { [name] = 998 } } }
OverlordDB.leaderboardSnapshot = {
    campaignStart = OverlordDB.lastResetTimestamp,
    scoreBucketEpoch = OverlordDB.lastResetTimestamp,
    kills = { [name] = 998 },
}
OverlordDB.leaderboardScoreSanitizeVersion = 3
lb:EnsureLegacyScoreSanitized()
local attempts = 0
while OverlordDB.leaderboardScoreSanitizeVersion ~= 5 and #timers > 0 do
    attempts = attempts + 1
    assert(attempts < 20, "Score cleanup did not finish within its bounded slices")
    table.remove(timers, 1)()
end
assert(OverlordDB.leaderboardScoreSanitizeVersion == 5, "Score cleanup did not commit")
assert(lb.kills[name] == nil, "Existing score was not removed")
assert(OverlordDB.leaderboardsByPool.global.kills[name] == nil,
    "Pooled score was not removed")
assert(OverlordDB.leaderboardSnapshot.kills[name] == nil,
    "Snapshot score was not removed")
OverlordDB.leaderboardSnapshot.kills[name] = 998
lb:RestoreFullLadderFromSnapshotIfNeeded()
assert(lb.kills[name] == nil, "A stale snapshot restored the removed score")
lb:RegisterKill(name, true)
lb:SetPlayerKills(name, 998, true)
assert(lb.kills[name] == nil, "An old peer restored the removed score")

-- 2026-09-22 : row forged through a spoofed BetaNetwork origin, and its guild.
local forged, forgedGuild = "Asmon Gold", "OLYMPUS RUSSIA"
assert(sync:IsDeniedKillContributor(forged), "Forged row is not excluded this week")
lb.kills[forged] = 4999
lb.playerInfo[forged] = { class = "", faction = "Horde", factionAt = 0, locale = "",
    guild = forgedGuild, pool = "global" }
local function hasForgedGuild()
    for _, row in ipairs(lb:GetSortedGuildKills()) do
        if row.guild == forgedGuild then return true end
    end
    return false
end
assert(hasForgedGuild(), "Fixture did not place the forged guild in the guild column")
OverlordDB.leaderboardScoreSanitizeVersion = 4
lb:EnsureLegacyScoreSanitized()
attempts = 0
while OverlordDB.leaderboardScoreSanitizeVersion ~= 5 and #timers > 0 do
    attempts = attempts + 1
    assert(attempts < 20, "Forged row cleanup did not finish within its bounded slices")
    table.remove(timers, 1)()
end
assert(lb.kills[forged] == nil, "Existing forged score was not removed on upgrade")
assert(not hasForgedGuild(), "Forged guild stayed in the guild column")
strsplit = strsplit or function(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
sync:OnReceiveLeaderboardKills(forged .. ":4999:WARRIOR:Horde:" .. OverlordDB.campaignId
    .. ":enus:" .. forgedGuild .. ":0:B" .. OverlordDB.lastResetTimestamp .. ":60",
    "Some Peer", "WHISPER")
assert(lb.kills[forged] == nil, "An old peer relayed the forged score back")

OverlordDB.campaignId = 20260929
assert(not sync:IsDeniedKillContributor(name), "Player remained excluded next week")
assert(not sync:IsDeniedKillContributor("Unrelated Player"), "Another player's score was blocked")
print("Forever kill-row removal: current-week purge, stale relay rejection, next-week expiry OK")
