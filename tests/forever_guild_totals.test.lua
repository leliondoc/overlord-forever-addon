assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local me = Overlord.Sync:GetPlayerFullName()
local guild, inGuild = "French Guild", true
function GetGuildInfo() return guild end
function IsInGuild() return inGuild end
lb:SetPlayerGuild(me, guild, false, true, time())
guild = nil
lb:UpdateLocalPlayerGuild()
assert(lb.playerInfo[me].guild == "French Guild", "Loading guild API erased known membership")
inGuild = false
lb:UpdateLocalPlayerGuild()
assert(lb.playerInfo[me].guild == "", "Confirmed guild departure was ignored")

-- The same unavailable guild response must not emit an authoritative GI tombstone.
assert(loadfile("SyncResolution.lua"))()
Overlord.CommunityModeEnabled = true
Overlord.Sync.FindCommunityClub = function() return 1 end
function IsInInstance() return false end
function IsInGroup() return false end
function IsInRaid() return false end
function GetChannelName() return 1 end
local emitted = {}
Overlord.Sync.Send = function(_, kind, payload) emitted[#emitted + 1] = {kind, payload} end
Overlord.Sync.BroadcastToCommunity = function() end
inGuild = true
Overlord.Sync:BroadcastGuildIdentity(true)
assert(#emitted == 0, "Unknown membership was broadcast as a guild departure")
guild = "French Guild"
Overlord.Sync:BroadcastGuildIdentity(true)
assert(#emitted == 1 and emitted[1][1] == "GI", "Known membership was not broadcast")

-- Reproduce a third-party snapshot stealing a Horde player's score for another
-- guild. Exercise the real LK/GI/GY receivers, including stale sender timestamps.
function strsplit(separator, value)
    local parts, start = {}, 1
    while true do
        local at = value:find(separator, start, true)
        if not at then parts[#parts + 1] = value:sub(start); break end
        parts[#parts + 1] = value:sub(start, at - 1)
        start = at + #separator
    end
    return unpack(parts)
end
function UnitExists() return false end
local subject, peer = "Horde Member", "Alliance Peer"
local epoch = OverlordDB.lastResetTimestamp
local campaignId = Overlord:TimestampToCampaignId(epoch)
local stamp = time() - 100
lb.kills[subject] = 473
lb.playerInfo[subject] = { guild = "Horde Guild", guildAt = stamp, faction = "Horde", level = 20 }
local function receiveGuild(g, at, sender, faction)
    assert(Overlord.Sync:OnReceiveLeaderboardKills(table.concat({subject, 473, "PRIEST",
        faction or "Horde", epoch, "enus", g, at, "B" .. epoch, 20}, ":"),
        sender or peer, "WHISPER"), "Fixture LK was rejected before metadata merge")
end
receiveGuild("Alliance Guild", stamp + 50, peer, "Alliance")
assert(lb.playerInfo[subject].guild == "Horde Guild", "Peer reassigned a known guild")
assert(lb.playerInfo[subject].faction == "Horde", "Peer changed a known faction")
receiveGuild("", stamp + 60)
Overlord.Sync:OnReceiveGuildAnswer(subject .. "|~0@" .. (stamp + 70), peer, "WHISPER")
assert(lb.playerInfo[subject].guild == "Horde Guild", "Peer erased another player's guild")
assert(lb.kills[subject] == 473, "Guild protection changed the score")

-- An old relay tombstone cannot prevent recovery from a peer with the membership.
lb.playerInfo[subject].guild, lb.playerInfo[subject].guildAt = "", stamp + 60
receiveGuild("Horde Guild", stamp)
assert(lb.playerInfo[subject].guild == "Horde Guild", "Legacy false departure blocked recovery")

-- The owner can correct already polluted data even if its timestamp is older.
lb.playerInfo[subject].guild, lb.playerInfo[subject].guildAt = "Alliance Guild", stamp + 80
Overlord.Sync:OnReceiveGuildIdentity(table.concat({subject, "Horde Guild", campaignId, stamp}, ":"),
    subject, "WHISPER")
assert(lb.playerInfo[subject].guild == "Horde Guild", "Owner could not repair polluted guild")
assert(lb.playerInfo[subject].guildAt == stamp, "Relay date survived owner correction")
receiveGuild("Alliance Guild", stamp + 90)
assert(lb.playerInfo[subject].guild == "Horde Guild", "Relay undid owner correction")
for i = 1, 50 do
    receiveGuild(i % 2 == 0 and "Alliance Guild" or "", stamp + 100 + i)
    Overlord.Sync:OnReceiveGuildAnswer(subject .. "|~0@" .. (stamp + 100 + i), peer, "WHISPER")
end
local previousSnapshot = OverlordDB.leaderboardSnapshot
OverlordDB.leaderboardSnapshot = {
    campaignStart = epoch, scoreBucketEpoch = epoch, pool = "global",
    kills = { [subject] = 480 }, captures = {}, captureCount = {},
    playerInfo = { [subject] = { guild = "Alliance Guild", guildAt = stamp + 190, level = 20 } },
}
lb:RestoreFullLadderFromSnapshotIfNeeded()
OverlordDB.leaderboardSnapshot = previousSnapshot
assert(lb.kills[subject] == 480, "Repair blocked legitimate score recovery")
assert(lb.playerInfo[subject].guild == "Horde Guild", "Repeated relays or saved snapshot undid repair")

-- Genuine owner changes and departures still work. Relays cannot undo a departure,
-- including after aliases and the saved display indexes have been rebuilt.
receiveGuild("New Horde Guild", stamp + 10, subject)
assert(lb.playerInfo[subject].guild == "New Horde Guild", "Owner guild change was ignored")
Overlord.Sync:OnReceiveGuildIdentity(table.concat({subject, "", campaignId, stamp + 20}, ":"),
    subject, "WHISPER")
lb:HealPropagateGuildAcrossDedupAliases()
lb:RebuildDedupMetaIndex()
receiveGuild("Horde Guild", stamp + 95)
Overlord.Sync:OnReceiveGuildAnswer(subject .. "|Horde Guild", peer, "WHISPER")
assert(lb.playerInfo[subject].guild == "" and lb.playerInfo[subject].guildAuth,
    "Peer resurrected a confirmed departure")

-- ForceUpdateLocalPlayer also runs at login before GetGuildInfo has loaded.
guild, inGuild = nil, true
lb.playerInfo[me].guild, lb.playerInfo[me].guildAt = "French Guild", stamp
lb:ForceUpdateLocalPlayer(me, "PRIEST", "Horde")
assert(lb.playerInfo[me].guild == "French Guild", "Login erased unavailable guild metadata")

-- Prepare an actual sliced display cache with over 200 unrelated competitors.
local timers = {}
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local function drain()
    local count = 0
    while #timers > 0 do
        local callback = table.remove(timers, 1)
        callback()
        count = count + 1
        assert(count < 10000, "Display cache failed to converge")
    end
end
-- K packets must also retain known guild metadata during a temporary API outage.
guild = nil
lb.playerInfo[me].guild, lb.playerInfo[me].guildAt = "French Guild", time() - 1
lb.kills[me] = 1
lb:Save()
local killPayload
Overlord.Sync.SendKillBroadcast = function(_, payload) killPayload = payload end
Overlord.Sync.MaybeBroadcastLeaderboardRaceBeacon = function() end
Overlord.Sync:BroadcastKill("", 1, false)
drain()
assert(killPayload and killPayload:find(":French Guild:", 1, true),
    "Kill broadcast replaced a known guild with a departure")

lb.kills = { ["Guild Member"] = 620, ["Guild Member-Realm"] = 620 }
lb.playerInfo = { ["Guild Member"] = { guild = "French Guild", faction = "Horde" } }
for i = 1, 210 do
    local name = "Rival Player" .. string.char(65 + math.floor(i / 26), 65 + i % 26)
    lb.kills[name] = 1000 + i
    lb.playerInfo[name] = { guild = "Other Guild", faction = "Alliance" }
end
-- RebuildHotIndexes installs the real deduplicated indexes without replacing data.
assert(lb:RebuildNetworkHotIndexes())
lb:MarkDirty()
assert(lb:StartDisplayCacheBuild())
drain()
local cache = lb._displayCache
assert(cache and #cache.sortedKills == 211, "Full player display lost members or duplicated aliases")
local found
for _, row in ipairs(cache.sortedGuilds) do
    if row.guild == "French Guild" then found = row.kills end
end
assert(found == 620, "Guild members outside top 200 disappeared or aliases were double counted")
-- Revalidate already populated legacy records with the character itself; a GR
-- response from that character uses fresh Blizzard metadata in an owned GI.
local whispers = {}
Overlord.CommunityModeEnabled = false
Overlord.Sync.SendWhisper = function(_, kind, payload, target)
    whispers[#whispers + 1] = { kind, payload, target }
end
Overlord.BetaNetwork = {
    IsPeer = function(_, name) return name == "Guild Member" end,
    Send = function(_, kind, payload, target)
        whispers[#whispers + 1] = { kind, payload, target }
        return true
    end,
}
Overlord.Sync:MaybeRequestMissingGuild("Guild Member")
Overlord.Sync:MaybeRequestMissingGuild("Offline Member")
Overlord.Sync:FlushGuildRequests()
drain()
local requestedOwner = false
for _, packet in ipairs(whispers) do
    assert(packet[3] ~= "Offline Member", "Guild revalidation searched the mesh for an offline owner")
    if packet[1] == "GR" and packet[2]:find("Guild Member", 1, true) and packet[3] == "Guild Member" then
        assert(not requestedOwner, "Guild owner was queried twice in the same batch")
        requestedOwner = true
    end
end
assert(requestedOwner, "Known but unverified guild was never checked with its owner")
guild, inGuild = "French Guild", true
lb.playerInfo[me] = { guild = "Wrong Guild", guildAt = time() + 100 }
Overlord.Sync:OnReceiveGuildRequest(me, "Asking Peer", "WHISPER")
drain()
local answeredOwner = false
for _, packet in ipairs(whispers) do
    if packet[1] == "GI" and packet[3] == "Asking Peer" then
        local name, reportedGuild = strsplit(":", packet[2])
        assert(name == me and reportedGuild == "French Guild", "Owner repeated polluted saved metadata")
        answeredOwner = true
    end
end
assert(answeredOwner, "Owner did not answer GR with a verifiable identity")
-- Global-pool migration is another merge path. An old bucket with a later
-- relay timestamp must not steal an owner-confirmed guild or departure.
local mergeTarget = { kills = { [subject] = 10 }, playerInfo = {
    [subject] = { guild = "Horde Guild", guildAt = stamp, guildAuth = true },
} }
local mergeSource = { kills = { [subject] = 12 }, playerInfo = {
    [subject] = { guild = "Alliance Guild", guildAt = stamp + 500 },
} }
Overlord:MergeLeaderboardBucketInto(mergeTarget, mergeSource)
drain()
assert(mergeTarget.kills[subject] == 12
    and mergeTarget.playerInfo[subject].guild == "Horde Guild"
    and mergeTarget.playerInfo[subject].guildAuth == true,
    "Global-pool migration replaced an owner guild while merging scores")
mergeTarget.playerInfo[subject] = { guild = "", guildAt = stamp, guildAuth = true }
Overlord:MergeLeaderboardBucketInto(mergeTarget, mergeSource)
drain()
assert(mergeTarget.playerInfo[subject].guild == ""
    and mergeTarget.playerInfo[subject].guildAuth == true,
    "Global-pool migration resurrected a confirmed departure")
print("Forever guild totals: all members, dedup, unavailable API and genuine departures OK")
