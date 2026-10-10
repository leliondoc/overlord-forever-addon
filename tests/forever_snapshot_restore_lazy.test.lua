-- The login restore of the saved ladder snapshot normalizes a saved field only when
-- the live row can take it. On a normal login the snapshot is a subset of the live
-- bucket: walking up to 6,500 entries through every normalizer took tens of ms in
-- one frame. Writes are unchanged.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local sync = Overlord.Sync
local epoch = OverlordDB.lastResetTimestamp
local calls = 0
local normalizeClass = lb.NormalizeClassTokenForDisplay
lb.NormalizeClassTokenForDisplay = function(...) calls = calls + 1; return normalizeClass(...) end
local normalizeRace = sync.NormalizeRaceFileToken
sync.NormalizeRaceFileToken = function(...) calls = calls + 1; return normalizeRace(...) end

local function complete(i)
    return { class = "PRIEST", race = "Human", raceSex = 2, raceAt = 100, locale = "enUS",
        guild = "Guild " .. (i % 7), guildAt = 1000 + i, guildAuth = (i % 2 == 0) or nil,
        pool = "global", level = 20 + (i % 40), faction = "Alliance", factionAt = 50 }
end
local function restore(snapInfo)
    OverlordDB.leaderboardSnapshot = {
        campaignStart = epoch, scoreBucketEpoch = epoch, pool = "global",
        kills = {}, captures = {}, captureCount = {}, playerInfo = snapInfo,
    }
    return lb:RestoreFullLadderFromSnapshotIfNeeded()
end

-- (1) The usual login: every saved entry already in the live bucket, nothing to take.
lb.playerInfo = {}
local snapInfo = {}
for i = 1, 2000 do
    local name = "Member" .. i .. "-Realm"
    lb.playerInfo[name] = complete(i)
    snapInfo[name] = complete(i)
end
assert(restore(snapInfo) == false, "a snapshot already in the live bucket wrote something")
assert(calls == 0, "complete live rows still went through the normalizers: " .. calls)

-- (2) Empty live fields still take the saved values, normalized.
local name = "Member1-Realm"
local live = lb.playerInfo[name]
live.class, live.race, live.locale, live.pool, live.level = "", nil, "", "", 0
snapInfo[name] = { class = "priest", race = "human", raceSex = 3, raceAt = 77,
    locale = "frFR", pool = "EU", level = 33, guild = live.guild, guildAt = live.guildAt }
assert(restore(snapInfo) == true, "an empty live row took nothing from the snapshot")
assert(live.class == "PRIEST" and live.race == "Human" and live.raceSex == 3 and live.raceAt == 77
    and live.locale == "frfr" and live.pool == "global" and live.level == 33,
    "an empty live field was not filled from the snapshot")

-- (3) Same guild name and date: an owner-attested saved record still beats a plain one.
name = "Member3-Realm"
live = lb.playerInfo[name]
live.guildAuth = nil
snapInfo[name] = complete(3)
snapInfo[name].guildAuth = true
assert(restore(snapInfo) == true and live.guildAuth == true,
    "an attested saved guild record lost to the same plain record")
-- (4) A newer saved guild still wins; a raw-equal one never does.
name = "Member5-Realm"
live = lb.playerInfo[name]
snapInfo[name] = complete(5)
snapInfo[name].guild, snapInfo[name].guildAt = " Newer|Guild ", live.guildAt + 10
snapInfo[name].guildAuth = live.guildAuth
assert(restore(snapInfo) == true and live.guild == "NewerGuild" and live.guildAt == snapInfo[name].guildAt,
    "a newer saved guild did not win: " .. tostring(live.guild))
snapInfo[name].guild = live.guild
assert(restore(snapInfo) == false, "a raw-equal saved guild record wrote something")
print("Snapshot restore: complete live rows skip the normalizers, empty fields and newer guilds still taken")
