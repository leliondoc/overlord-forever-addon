-- Perf audit 2026-10-01: every PvP kill by a guilded groupmate re-confirmed the same
-- guild, re-dated it and invalidated the dedup meta index, so the network index
-- rebuild never finished during raids. An unchanged first-hand guild is now
-- re-dated at most once a minute; a different guild still applies at once.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local clock = 1790020000
local realTime = time
time = function() return clock end

local name = "Ally Tester"
lb:SetPlayerGuild(name, "Iron Wolves", false, true, clock)
local row = lb.playerInfo[name]
assert(row and row.guild == "Iron Wolves" and row.guildAuth, "Fixture: guild not stored")
local datedAt = row.guildAt

local dirty = 0
local markMetaDirty = lb.MarkMetaDirty
lb.MarkMetaDirty = function(self, ...) dirty = dirty + 1; return markMetaDirty(self, ...) end
local patch = lb.PatchDedupMetaGuildForPlayer
local patched = 0
lb.PatchDedupMetaGuildForPlayer = function(self, ...) patched = patched + 1; return patch(self, ...) end

-- 1. Same guild re-confirmed by kills within the minute: nothing touched.
for i = 1, 10 do
    clock = clock + 5
    lb:SetPlayerGuild(name, "Iron Wolves", false, true, clock)
end
assert(row.guildAt == datedAt, "Unchanged guild was re-dated within the minute")
assert(dirty == 0 and patched == 0, "Unchanged guild invalidated the meta index")

-- 2. After a minute, one refresh of the date.
clock = clock + 60
lb:SetPlayerGuild(name, "Iron Wolves", false, true, clock)
assert(row.guildAt == clock, "First-hand guild date never refreshed")
assert(patched == 1, "Expected exactly one meta patch")

-- 3. A different guild applies immediately.
clock = clock + 5
lb:SetPlayerGuild(name, "Stone Bears", false, true, clock)
assert(row.guild == "Stone Bears", "A guild change was held back")

lb.MarkMetaDirty, lb.PatchDedupMetaGuildForPlayer = markMetaDirty, patch
print("Guild re-confirmation: at most once a minute, changes applied at once")
local realServerTime = GetServerTime
GetServerTime = function() return clock end

-- 4. Same rule on the received-K path (MergeLeaderboardKillMetadata): an owner's K
--    re-dates its unchanged guild every broadcast; within a minute it is a no-op.
local owner = "Kill Owner"
lb:MergeLeaderboardKillMetadata(owner, 30, "WARRIOR", "Alliance", nil, "Iron Wolves", clock, true,
    nil, nil, 0, true)
local ownerRow = lb.playerInfo[owner]
assert(ownerRow and ownerRow.guild == "Iron Wolves" and ownerRow.guildAuth, "fixture: owner guild not stored")
local ownerAt = ownerRow.guildAt
dirty = 0
lb.MarkMetaDirty = function(self, ...) dirty = dirty + 1; return markMetaDirty(self, ...) end
for i = 1, 5 do
    clock = clock + 5
    lb:MergeLeaderboardKillMetadata(owner, 30, "WARRIOR", "Alliance", nil, "Iron Wolves", clock, true,
        nil, nil, 0, true)
end
assert(ownerRow.guildAt == ownerAt and dirty == 0, "K re-dated an unchanged guild within the minute")

-- 5. Own race re-observed at every kill: re-dated at most hourly.
IsInGroup = IsInGroup or function() return false end
IsInRaid = IsInRaid or function() return false end
lb:SetPlayerRace(owner, "Orc", 2, false, clock)
local raceAt = lb.playerInfo[owner].raceAt
dirty = 0
for i = 1, 5 do
    clock = clock + 5
    lb:SetPlayerRace(owner, "Orc", 2, false, clock)
end
assert(lb.playerInfo[owner].raceAt == raceAt and dirty == 0, "own race re-dated at every kill")
lb.MarkMetaDirty, time, GetServerTime = markMetaDirty, realTime, realServerTime
print("Guild/race re-confirmation from kills: no meta churn within the window")
