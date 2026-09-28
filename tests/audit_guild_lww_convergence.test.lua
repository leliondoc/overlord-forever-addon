-- LK guild metadata must converge after the same admitted page rows, regardless
-- of which peer supplied them first. Use the real leaderboard merge method.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local name = "Convergence Member"
local now = time()

local function offer(guild, at, owner, snapshot)
    lb:MergeLeaderboardKillMetadata(name, 20, "PRIEST", "Alliance",
        "enus", guild, at, true, "", 0, 0, owner == true, snapshot == true)
end

local function replay(firstGuild, firstAt, secondGuild, secondAt)
    lb.playerInfo[name] = nil
    lb:MarkMetaDirty()
    offer(firstGuild, firstAt, false, true)
    offer(secondGuild, secondAt, false, true)
    return lb.playerInfo[name].guild
end

assert(replay("Guild X", now - 200, "Guild Y", now - 100) == "Guild Y",
    "A newer relay guild did not replace an older relay guild")
assert(replay("Guild Y", now - 100, "Guild X", now - 200) == "Guild Y",
    "Relay guild depended on page order")

local tieFirst = replay("Guild X", now - 100, "Guild Y", now - 100)
local tieReverse = replay("Guild Y", now - 100, "Guild X", now - 100)
assert(tieFirst == tieReverse, "Equal-timestamp relay guilds depended on page order")

local function strongTie(firstGuild, firstAuth, secondGuild, secondAuth)
    lb.playerInfo[name] = {
        class = "PRIEST", level = 20, faction = "Alliance",
        guild = firstGuild, guildAt = now - 100,
        guildAuth = firstAuth or nil, guildReplica = not firstAuth or nil,
    }
    offer(secondGuild, now - 100, secondAuth, not secondAuth)
    return lb.playerInfo[name].guild
end
assert(strongTie("Guild X", true, "Guild Y", false)
    == strongTie("Guild Y", false, "Guild X", true),
    "Owner/replica conflict at equal date depended on arrival order")
assert(strongTie("Guild X", true, "", false) == ""
    and strongTie("", false, "Guild X", true) == "",
    "Equal-date owner/replica departure did not win in both orders")
lb.playerInfo[name] = {
    class = "PRIEST", level = 20, faction = "Alliance",
    guild = "", guildAt = now - 100, guildReplica = true,
}
lb:SetPlayerGuild(name, "Guild X", true, true, now - 100, true)
assert(lb.playerInfo[name].guild == "",
    "An equal-date owned GY resurrected a replicated departure")
lb.playerInfo[name].guild = "Guild X"
assert(lb:ClearPlayerGuild(name, true, true, now - 100)
    and lb.playerInfo[name].guild == "",
    "An equal-date owned departure did not beat replicated membership")

-- A known faction cannot be rewritten by a cross-faction LK hint. The source
-- player is the only sender whose K/GI/LK may confirm a membership or departure.
lb.playerInfo[name] = {
    class = "PRIEST", level = 20, faction = "Horde",
    guild = "Horde Guild", guildAt = now - 200,
}
lb:MergeLeaderboardKillMetadata(name, 20, "PRIEST", "Alliance",
    "enus", "Alliance Guild", now - 100, true, "", 0, 0, false)
assert(lb.playerInfo[name].guild == "Horde Guild"
    and lb.playerInfo[name].faction == "Horde",
    "A cross-faction LK hint replaced known metadata")

lb.playerInfo[name].faction = "Alliance"
offer("Owner Guild", now - 200, true)
offer("Relay Guild", now - 50, false)
assert(lb.playerInfo[name].guild == "Owner Guild" and lb.playerInfo[name].guildAuth,
    "A relay replaced a verified owner guild")
offer("Stale Owner Guild", now - 300, true)
assert(lb.playerInfo[name].guild == "Owner Guild", "A stale owner event won")
offer("", now - 40, true)
assert(lb.playerInfo[name].guild == "" and lb.playerInfo[name].guildAuth,
    "An owner departure was not retained as an authoritative tombstone")
offer("Relay Guild", now - 20, false)
assert(lb.playerInfo[name].guild == "", "A relay resurrected an owner departure")
offer("Rejoined Guild", now - 10, true)
assert(lb.playerInfo[name].guild == "Rejoined Guild", "A newer owner event was ignored")

-- Requested snapshot pages may carry a later owner membership or departure
-- while the source character is offline. A stale owner replay must not undo it.
lb.playerInfo[name] = {
    class = "PRIEST", level = 20, faction = "Alliance",
    guild = "Old Owner Guild", guildAt = now - 200, guildAuth = true,
}
offer("New Snapshot Guild", now - 100, false, true)
assert(lb.playerInfo[name].guild == "New Snapshot Guild"
    and lb.playerInfo[name].guildReplica and not lb.playerInfo[name].guildAuth,
    "A requested newer snapshot failed to update an old owner register")
offer("Old Owner Guild", now - 200, true)
offer("Raw Relay Guild", now - 50, false)
assert(lb.playerInfo[name].guild == "New Snapshot Guild",
    "A stale owner or unsolicited relay undid the requested snapshot")
offer("", now - 150, false, true)
assert(lb.playerInfo[name].guild == "New Snapshot Guild",
    "An older snapshot departure won")
offer("", now - 40, false, true)
assert(lb.playerInfo[name].guild == "" and lb.playerInfo[name].guildReplica,
    "A requested newer departure was not applied")
offer("Old Owner Guild", now - 200, true)
offer("Raw Relay Guild", now - 20, false)
assert(lb.playerInfo[name].guild == "",
    "An old owner replay or raw relay resurrected a snapshot departure")
offer("Current Owner Guild", now - 10, true)
assert(lb.playerInfo[name].guild == "Current Owner Guild"
    and lb.playerInfo[name].guildAuth and not lb.playerInfo[name].guildReplica,
    "A genuinely newer owner membership failed to replace a snapshot")

-- Persisting the replica marker is required across reloads and alias rebuilds.
lb.playerInfo[name] = {
    class = "PRIEST", level = 20, faction = "Alliance",
    guild = "Snapshot Guild", guildAt = now - 30, guildReplica = true,
}
lb:RebuildDedupMetaIndex()
assert(lb._dedupMetaIndex[name:lower()].guildReplica == true,
    "Dedup rebuild discarded accepted snapshot provenance")
lb:SetPlayerInfo(name, "PRIEST", "Alliance", "enus")
assert(lb.playerInfo[name].guildReplica == true,
    "Unrelated metadata refresh discarded snapshot provenance")
lb:SetPlayerGuild(name, "Stale Owner Guild", true, true, now - 200, true)
assert(lb.playerInfo[name].guild == "Snapshot Guild" and lb.playerInfo[name].guildReplica,
    "A stale owned GY update replaced a newer requested snapshot")
assert(not lb:ClearPlayerGuild(name, true, true, now - 200),
    "A stale owned departure replaced a newer requested snapshot")
assert(lb.playerInfo[name].guild == "Snapshot Guild", "Stale owner departure changed membership")
local alias = name .. "-Realm"
assert(Overlord.Sync:GetCaptureContributorDedupKey(alias)
    == Overlord.Sync:GetCaptureContributorDedupKey(name),
    "Alias fixture did not share an identity")
lb.playerInfo[name] = {
    class = "PRIEST", level = 20, faction = "Alliance",
    guild = "Old Owner Guild", guildAt = now - 200, guildAuth = true,
}
lb.playerInfo[alias] = {
    class = "PRIEST", level = 20, faction = "Alliance",
    guild = "Snapshot Guild", guildAt = now - 30, guildReplica = true,
}
lb:HealPropagateGuildAcrossDedupAliases()
lb:RebuildDedupMetaIndex()
assert(lb.playerInfo[name].guild == "Snapshot Guild"
    and lb.playerInfo[name].guildReplica == true
    and lb._dedupMetaIndex[name:lower()].guild == "Snapshot Guild",
    "Alias repair resurrected an older owner register")
lb.playerInfo[alias] = nil

-- A persisted snapshot is another order of arrival for the same relay register.
-- It must not reintroduce a different guild after LK page convergence.
local oldSnapshot = OverlordDB.leaderboardSnapshot
local epoch = OverlordDB.lastResetTimestamp
lb.kills[name] = 20
lb.playerInfo[name] = {
    class = "PRIEST", level = 20, faction = "Alliance",
    guild = "Guild X", guildAt = now - 200,
}
OverlordDB.leaderboardSnapshot = {
    campaignStart = epoch, scoreBucketEpoch = epoch, pool = "global",
    kills = { [name] = 20 }, captures = {}, captureCount = {},
    playerInfo = { [name] = { guild = "Guild Y", guildAt = now - 100, level = 20 } },
}
lb:RestoreFullLadderFromSnapshotIfNeeded()
assert(lb.playerInfo[name].guild == "Guild Y",
    "A newer snapshot register failed to converge with LK")
lb.playerInfo[name] = {
    class = "PRIEST", level = 20, faction = "Alliance",
    guild = "Old Owner Guild", guildAt = now - 200, guildAuth = true,
}
OverlordDB.leaderboardSnapshot.playerInfo[name] = {
    guild = "", guildAt = now - 40, guildReplica = true, level = 20,
}
lb:RestoreFullLadderFromSnapshotIfNeeded()
assert(lb.playerInfo[name].guild == "" and lb.playerInfo[name].guildReplica,
    "Reload lost a newer requested departure to an old owner register")
OverlordDB.leaderboardSnapshot = oldSnapshot

print("Guild LK relay LWW, owner precedence, tombstones and snapshot convergence OK")
