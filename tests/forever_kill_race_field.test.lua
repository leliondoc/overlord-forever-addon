-- Races had holes on Forever: communities (which gave every member's race) are off,
-- leaving the weekly race beacon and the slow LR catch-up. The owner's K now carries
-- its race and sex at most every 10 minutes, in the 13-field layout every client
-- (1.3.4 included) still parses. ~10 bytes, dropped first if the K is too long.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local s = Overlord.Sync
local EPOCH = 1789527600

-- 1. With a race: 13 fields, parsed back as race + sex, bucket and level intact.
local withRace = s:BuildKillBroadcastPayload("Grok Smash", "", 120, "WARRIOR", "Horde", EPOCH,
    "Iron Wolves", "enus", 0, EPOCH, 30, "Orc", 2)
assert(withRace, "fixture: no K built")
local name, _, kills, class, faction, epoch, guild, loc, _, race, sex, bucket, level =
    s:ParseKillPayload(withRace)
assert(name == "Grok Smash" and kills == "120" and class == "WARRIOR" and faction == "Horde")
assert(guild == "Iron Wolves" and loc == "enus")
assert(race == "Orc" and sex == 2, "race not parsed back: " .. tostring(race) .. "/" .. tostring(sex))
assert(bucket and bucket:match("^B%d+$") and tonumber(level) == 30, "bucket/level shifted by the race fields")

-- 2. Without a race: the usual 11-field K, unchanged.
local plain = s:BuildKillBroadcastPayload("Grok Smash", "", 120, "WARRIOR", "Horde", EPOCH,
    "Iron Wolves", "enus", 0, EPOCH, 30)
local _, _, _, _, _, _, _, _, _, race2, _, bucket2, level2 = s:ParseKillPayload(plain)
assert(race2 == "" and bucket2 and tonumber(level2) == 30, "plain K changed")
assert(#withRace - #plain <= 12, "race costs more than ~10 bytes: " .. (#withRace - #plain))

-- 3. Too long with the race: the race is dropped first, the score still goes out.
local longGuild = string.rep("G", 24)
local longName = "Averyveryverylongname Withaverylongsurname"
local fallback = s:BuildKillBroadcastPayload(longName, string.rep("z", 120), 120, "WARRIOR", "Horde",
    EPOCH, longGuild, "enus", 0, EPOCH, 30, "Orc", 2)
assert(fallback and #fallback <= 250, "oversized K not shrunk")
-- 4. Skyborne (Forever's ninth race, a token per faction): carried like any race,
-- and stored for its owner when his K is received.
local sky = s:BuildKillBroadcastPayload("Sky Walker", "", 40, "MAGE", "Alliance", EPOCH,
    "", "engb", 0, EPOCH, 30, "SkyborneAlliance", 3)
local _, _, _, _, _, _, _, _, _, skyRace, skySex = s:ParseKillPayload(sky)
assert(skyRace == "Skyborne" and skySex == 3, "Skyborne race not carried in K: " .. tostring(skyRace))
s:OnReceiveKill(sky, "Sky Walker")
local skyInfo = Overlord.Leaderboard.playerInfo["Sky Walker"]
assert(skyInfo and skyInfo.race == "Skyborne", "Skyborne race not stored from its owner's K: "
    .. tostring(skyInfo and skyInfo.race))
print("K race field: 13-field layout parsed back, ~10 bytes, dropped first when too long, Skyborne carried")
