-- Guild convergence across factions (EMPIRE 36k vs 71k): a client never sees the
-- other faction's direct K, so second-hand guild info must follow Retail's rule
-- (newest date wins) instead of freezing the first value received. Strong records
-- (confirmed by the character, or from a solicited catch-up page) stay protected.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local now = (GetServerTime and GetServerTime()) or time()
local function merge(name, guild, at, auth, snapshot)
    return lb:MergeLeaderboardKillMetadata(name, 60, "WARRIOR", "Alliance", "enus",
        guild, at, true, nil, nil, nil, auth == true, snapshot == true)
end
local function guildOf(name)
    local info = lb:GetPlayerInfo(name)
    return info and info.guild or ""
end

-- Second-hand vs second-hand: the newest date wins, in either arrival order.
merge("Weak Tester", "Wrong Guild", now - 200)
assert(guildOf("Weak Tester") == "Wrong Guild")
merge("Weak Tester", "Right Guild", now - 50)
assert(guildOf("Weak Tester") == "Right Guild", "Newer second-hand guild stayed frozen: " .. guildOf("Weak Tester"))
merge("Weak Tester", "Wrong Guild", now - 200)
assert(guildOf("Weak Tester") == "Right Guild", "Older second-hand guild overwrote a newer one")

-- A second-hand departure (empty guild) never clears a guild.
merge("Weak Tester", "", now - 10)
assert(guildOf("Weak Tester") == "Right Guild", "Second-hand departure cleared the guild")

-- A guild confirmed by the character itself cannot be overwritten second-hand.
merge("Owner Tester", "Owner Guild", now - 300, true)
merge("Owner Tester", "Forged Guild", now - 5)
assert(guildOf("Owner Tester") == "Owner Guild", "Second-hand info overwrote an owner-confirmed guild")

-- Same for a guild from a solicited catch-up page.
merge("Replica Tester", "Page Guild", now - 300, false, true)
merge("Replica Tester", "Forged Guild", now - 5)
assert(guildOf("Replica Tester") == "Page Guild", "Second-hand info overwrote a catch-up page guild")
-- ... while a newer catch-up page still corrects it.
merge("Replica Tester", "Newer Page Guild", now - 2, false, true)
assert(guildOf("Replica Tester") == "Newer Page Guild", "Newer catch-up page lost to an older one")

-- Guild answers (GY) follow the same rule through ShouldAcceptSyncedGuild.
assert(lb:ShouldAcceptSyncedGuild("Weak Tester", "Even Newer Guild", now - 1),
    "Newer second-hand guild answer refused")
assert(not lb:ShouldAcceptSyncedGuild("Weak Tester", "Stale Guild", now - 400),
    "Older second-hand guild answer accepted")
assert(not lb:ShouldAcceptSyncedGuild("Owner Tester", "Forged Guild", now),
    "Guild answer accepted over an owner-confirmed guild")
assert(not lb:ShouldAcceptSyncedGuild("Replica Tester", "Forged Guild", now),
    "Guild answer accepted over a catch-up page guild")
assert(lb:ShouldAcceptSyncedGuild("Unknown Tester", "First Guild", 0), "Unknown guild could not be filled")
print("Guild weak LWW: newest second-hand guild wins, strong records protected, no second-hand departures")
