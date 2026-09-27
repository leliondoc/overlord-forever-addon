-- Exercise production entry points and the real leaderboard, without any club.
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 0 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
-- Real Forever beta: the client still reports WOW_PROJECT_ID = 1 (Retail) while
-- Battle.net reports Forever friends as project 18.
WOW_PROJECT_ID = 1
local bnetGames = {
    [123] = { gameAccountID = 123, characterName = "Bridge Tester", clientProgram = "WoW",
        wowProjectID = 18, factionName = "Horde", isInCurrentRegion = true, isOnline = true },
    [456] = { gameAccountID = 456, characterName = "Retail Friend", clientProgram = "WoW",
        wowProjectID = 1, factionName = "Alliance", isInCurrentRegion = true, isOnline = true },
    [789] = { gameAccountID = 789, characterName = "Ally Friend", clientProgram = "WoW",
        wowProjectID = 18, factionName = "Alliance", isInCurrentRegion = true, isOnline = true },
}
-- Friend order as Battle.net lists it: the same-faction Forever friend comes first.
local friendOrder = { 789, 456, 123 }
function BNGetNumFriends() return #friendOrder end
C_BattleNet = {
    GetGameAccountInfoByID = function(id) return bnetGames[id] end,
    GetFriendNumGameAccounts = function() return 1 end,
    GetFriendGameAccountInfo = function(i) return bnetGames[friendOrder[i]] end,
}
assert(loadfile("SyncBetaNetwork.lua"))()
local s, net = Overlord.Sync, Overlord.BetaNetwork
Overlord.PlayerFaction = "Alliance"
local targets = s:GetBetaBNetTargets()
assert(#targets == 2 and targets[1] == 123 and targets[2] == 789,
    "Battle.net targets must be Forever friends (project 18), opposite faction first, never Retail (project 1)")
local bridgeFaction, bridgeName = s:GetBetaBNetTargetInfo(123)
assert(bridgeFaction == "Horde" and bridgeName == "Bridge Tester", "Bridge friend faction/identity unknown")
assert(s:IsForeverBNetProject(18) and not s:IsForeverBNetProject(1),
    "Forever project detection still trusts the Retail WOW_PROJECT_ID")
local function killPayload(name, total)
    return s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", "Alliance",
        1789527600, "", "enus", 0, 1789527600, 2)
end
local function wire(id, kind, data, path)
    return "eu|integration-" .. id .. "|" .. time() .. "|*|" .. (path or "Remote Tester,Bridge Tester")
        .. "|" .. kind .. "|" .. data
end
-- Only the last hop is authenticated by BNet. A relayed origin is written by the
-- gateway and must never own a kill score, even for a genuine remote player.
local directRemoteTotal = Overlord.Leaderboard.kills["Remote Tester"]
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(1, "K", killPayload("Remote Tester", 3)), 123)
assert(Overlord.Leaderboard.kills["Remote Tester"] == directRemoteTotal,
    "Relayed origin was credited as the owner")
assert(not net.stats.lastError, net.stats.lastError)
-- The 1.0.18 exploit: a modified gateway names any victim as origin.
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(11, "K", killPayload("Forged Victim", 4999),
    "Forged Victim,Bridge Tester"), 123)
assert(Overlord.Leaderboard.kills["Forged Victim"] == nil, "Forged beta origin injected a kill row")
for i = 1, 8 do
    s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(20 + i, "K", killPayload("Other Victim", 4999),
        "Forged Victim,Bridge Tester"), 123)
end
assert(Overlord.Leaderboard.kills["Other Victim"] == nil, "Forged origin credited another name")
assert(not s:KillAntiSpoofIsBlacklisted("Forged Victim"),
    "Kill quarantine punished the impersonated name instead of ignoring the relay")
-- The gateway's own packet (no earlier hop) is authenticated and keeps low levels.
local packet = wire(12, "K", killPayload("Bridge Tester", 3), "Bridge Tester")
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. packet, 123)
assert(Overlord.Leaderboard.kills["Bridge Tester"] == 3, "Real R2 kill handler lost low-level score")
assert(s:FindCommunityClub() == nil)
assert(#s:FindAllCommunityClubs() == 0)
assert(s:GetCommunityInviteCode() == "0m7kdXcnvR")
C_Club.GetSubscribedClubs = function()
    return { { clubId = 777, name = "Overlord Forever", clubType = Enum.ClubType.Character } }
end
C_Club.GetClubMembers = function() return {} end
-- The Community button forces a fresh scan immediately after a mid-session join,
-- even when the preceding scan cached that no community was present.
assert(s:FindCommunityClub(true) == 777, "Global Overlord community was not discovered after joining")
assert(s:IsGuildKeepCommunitySender("Remote Tester"), "Routed keep sender lost its trust context")
-- A second score through fragmented R2 reaches the same production receiver.
local payload = killPayload("Bridge Tester", 4)
packet = wire(2, "K", payload, "Bridge Tester")
local count = math.ceil(#packet / 170)
for i = count, 1, -1 do
    s:OnBNetMessage("R2:Forever_eu_H:BF:integration-2:" .. i .. ":" .. count .. ":"
        .. packet:sub((i - 1) * 170 + 1, i * 170), 123)
end
assert(Overlord.Leaderboard.kills["Bridge Tester"] == 4, "Fragmented production R2 failed")
s:OnBNetMessage("R2:Forever_us_A:BR:" .. wire(3, "K", payload, "Bridge Tester"), 123)
assert(net.stats.received >= 3, "Legacy US bridge tag was not accepted by the global pool")
assert(loadfile("SyncGuildKeep.lua"))()
assert(loadfile("SyncOutpost.lua"))()
Overlord.GuildKeepSites = { fixture = {} }
Overlord.OutpostSites = { fixture = {} }
local keep, outpost
Overlord.GuildKeep = {
    SanitizeGuildName = function(_, value) return value end,
    GetState = function() return { status = "neutral" } end,
    ApplyRemoteState = function(_, _, state) keep = state; return false end,
}
Overlord.Outpost = {
    SanitizeGuildName = function(_, value) return value end,
    GetState = function() return { status = "neutral" } end,
    ApplyRemoteState = function(_, _, state) outpost = state; return false end,
}
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(4, "GK",
    "v9:fixture:neutral:0:::0:" .. time() .. ":120:eu:0:::0::0:0:0:"), 123)
assert(keep and keep.pool == "global" and keep.communitySource, "Real keep receiver rejected routed snapshot")
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(5, "OP",
    "v1:fixture:neutral:0:::0:0:" .. time() .. ":120:eu:0"), 123)
assert(outpost and outpost.pool == "global", "Real outpost receiver rejected routed snapshot")
local mergedGuild
local originalMerge = Overlord.Leaderboard.MergeOwnedGuildMetadata
Overlord.Leaderboard.MergeOwnedGuildMetadata = function(self, name, guild, at)
    mergedGuild = { name, guild }
    return originalMerge(self, name, guild, at)
end
local epoch = Overlord:TimestampToCampaignId(OverlordDB.lastResetTimestamp)
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(6, "GI",
    "Remote Tester:Beta Guild:" .. epoch .. ":" .. time()), 123)
assert(mergedGuild == nil, "A relayed origin claimed an authoritative guild")
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(16, "GI",
    "Bridge Tester:Beta Guild:" .. epoch .. ":" .. time(), "Bridge Tester"), 123)
assert(mergedGuild and mergedGuild[1] == "Bridge Tester" and mergedGuild[2] == "Beta Guild",
    "Production guild identity handler rejected the authenticated gateway")
-- UI/community entry points use the replacement transport, preserving payloads.
assert(loadfile("General.lua"))()
assert(loadfile("GeneralSync.lua"))()
assert(loadfile("ManualBounty.lua"))()
assert(loadfile("ManualBountySync.lua"))()
local campaign = OverlordDB.lastResetTimestamp
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(7, "GE",
    "A:eu:5000:5000:1417:" .. time() .. ":" .. campaign), 123)
local commander = Overlord.General:GetSlot("Alliance")
assert(commander and commander.holder == "Remote Tester", "Commander was rejected without a club, or attributed to the bridge")
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(8, "GX",
    "A:eu:" .. time() .. ":" .. campaign), 123)
assert(not Overlord.General:GetSlot("Alliance"), "Relayed commander release was lost")
local contract = { id = "MBFOREVER-1", poster = "Remote Tester", target = "Victim Tester",
    targetRace = "Orc", targetRaceSex = 2, targetGuild = "Guild", targetFaction = "Horde",
    amountCopper = 10000, pool = "eu", epoch = campaign, createdAt = time(), updatedAt = time(), status = "open" }
local contractPayload = assert(Overlord.ManualBountySync:BuildPBPayload(contract))
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(9, "PB", contractPayload), 123)
assert(Overlord.ManualBounty:GetContract(contract.id), "Realmless contract did not cross the bridge")
assert(not net.stats.lastError, net.stats.lastError)
-- BR is also the legacy contract refresh request. Inside a beta envelope it
-- must reach the contract handler, not be decoded as another relay envelope.
local refreshSender
Overlord.ManualBountySync.OnReceiveBR = function(_, _, sender) refreshSender = sender end
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(10, "BR", "contract-refresh"), 123)
assert(refreshSender == "Remote Tester", "Contract BR collided with the BNet relay envelope")
local sent = {}
net.Broadcast = function(_, kind, data) sent[#sent + 1] = { kind, data }; return 1 end
for _, method in ipairs({ "BroadcastToCommunity", "BroadcastGuildKeepToCommunity",
    "BroadcastToEnemyFactionCommunity", "BroadcastGeneralToFactionCommunity" }) do
    assert(s[method](s, "GK", "unchanged"), method .. " lost its replacement route")
    assert(sent[#sent][1] == "GK" and sent[#sent][2] == "unchanged")
end
-- Even the large-event branch must use the replacement community relay.
s.IsLargeEvent = function() return true end
s:SendKillBroadcast("large-event-score")
assert(sent[#sent][1] == "K" and sent[#sent][2] == "large-event-score",
    "Large-event kill stayed on the local raid/channel")
local extras = { { type = "DX", payload = "second-front" }, { type = "VB", payload = "bonus" } }
net.Broadcast = function(_, _, _, actual)
    assert(actual == extras, "Community bundle lost its secondary payloads")
    return 1
end
assert(s:BroadcastToCommunity("DX", "first-front", 12, 0.3, true, extras))
assert(s:BroadcastGuildKeepToCommunity("GK", "keep", 12, 0.3, extras) == 1)

-- A broadcast LK line from our HR target is not part of its addressed snapshot:
-- counting it would break the digest proof and force an endless retry.
assert(loadfile("SyncHistoryCatchup.lua"))()
local lkPayload = "Remote Tester:41:WARRIOR:Alliance:1789527600:enus::0:B1789527600:2"
s._historyCatchupPending = { awaitingAck = true, terminal = false, deliveryCount = 0, deliveryHash = 0,
    targetKey = tostring(s:GetCaptureContributorDedupKey("Remote Tester")):lower() }
net.context = { targeted = false }
assert(not s:NoteHistoryCatchupDelivery("LK", lkPayload, "Remote Tester", "BETA"),
    "A broadcast LK beacon was counted in the HR delivery digest")
net.context = { targeted = true }
assert(s:NoteHistoryCatchupDelivery("LK", lkPayload, "Remote Tester", "BETA")
    and s._historyCatchupPending.deliveryCount == 1, "Addressed HR row was not counted")
net.context, s._historyCatchupPending = nil, nil
-- A legacy direct K/EK/SR copy is skipped once the relay queued the same packet
-- (its channel/group copies carry it); other kinds keep their direct copy.
assert(net:Send("K", "dedup-kill"), "Relay refused the kill")
assert(s:RelayAlreadyCarries("K", "dedup-kill"), "Relayed kill was not recognized")
assert(not s:RelayAlreadyCarries("K", "other-kill"), "Unrelated kill was skipped")
assert(net:Send("C", "dedup-capture"))
assert(not s:RelayAlreadyCarries("C", "dedup-capture"), "Transport-sensitive kind lost its direct copy")
-- Blizzard throttle refusals (Enum.SendAddonMessageResult ~= 0) are reported,
-- counted and never mistaken for a sent packet; older boolean results still work.
local originalChatInfo = C_ChatInfo
C_ChatInfo = { SendAddonMessage = function() return 8 end }
assert(s:SendAddonChecked("K:x", "CHANNEL", 1) == false, "Channel throttle refusal counted as sent")
C_ChatInfo = { SendAddonMessage = function() return 0 end }
assert(s:SendAddonChecked("K:x", "CHANNEL", 1) == true)
C_ChatInfo = { SendAddonMessage = function() return true end }
assert(s:SendAddonChecked("K:x", "RAID") == true)
local channelStats = s._addonSendStats.CHANNEL
assert(channelStats.refused >= 1 and channelStats.lastCode == 8, "Refusal was not counted")
-- Realm channel = only what Blizzard's ~1 msg/s makes useful: no keep/outpost
-- bookkeeping, no leaderboard lines, no ZA photos; sieges in progress and our own
-- kills (one absolute total per 30 s, the last one always flushed) still go.
do
    local clock, pendingTimers = 5000, {}
    local originalGetTime, originalAfter = GetTime, C_Timer.After
    GetTime = function() return clock end
    C_Timer.After = function(delay, fn) pendingTimers[#pendingTimers + 1] = { at = clock + delay, fn = fn } end
    s._channelKillAt, s._channelKillPending, s._channelKillArmed = nil, nil, nil
    assert(not s:ChannelCarries("GH", "x", true) and not s:ChannelCarries("ZA", "x", true)
        and not s:ChannelCarries("LK", "x", true) and not s:ChannelCarries("LO", "x", true))
    assert(not s:ChannelCarries("GK", "v9:site:held:1", true) and s:ChannelCarries("GK", "v9:site:in_progress:1", true))
    assert(not s:ChannelCarries("OP", "v1:site:neutral:1", true) and s:ChannelCarries("OP", "v1:site:in_progress:1", true))
    assert(s:ChannelCarries("C", "x", false) and s:ChannelCarries("ZS", "x", false) and s:ChannelCarries("GC", "x", false))
    assert(s:ChannelCarries("EK", "x", true) and not s:ChannelCarries("EK", "x", false))
    assert(not s:ChannelCarries("K", "k1", false), "A relayed kill went back on the channel")
    assert(s:ChannelCarries("K", "k1", true), "First own kill total was held back")
    clock = 5010
    assert(not s:ChannelCarries("K", "k2", true) and not s:ChannelCarries("K", "k3", true))
    local flushed
    local originalSendToChannel = s.SendToChannel
    s.SendToChannel = function(_, kind, data) flushed = kind .. ":" .. data; return true end
    clock = 5031
    for _, t in ipairs(pendingTimers) do if t.at <= clock then t.fn() end end
    s.SendToChannel = originalSendToChannel
    assert(flushed == "K:k3", "Latest kill total was not flushed at the end of the window: " .. tostring(flushed))
    -- Message budget: one at a time, then ~0.8 message per second.
    s._channelTokens, s._channelTokensAt = nil, nil
    assert(s:TakeChannelToken() and not s:TakeChannelToken())
    assert(s:TakeChannelToken(true), "A critical final message was held back")
    clock = clock + 3
    assert(s:TakeChannelToken(), "Channel budget never refilled")
    -- The solo fallback of Send() used to reach the channel without gate or budget.
    local originalChannelId, originalInGroup, originalInRaid = s.GetChannelId, IsInGroup, IsInRaid
    local channelSends = 0
    local originalChecked = s.SendAddonChecked
    s.GetChannelId = function() return 1 end
    IsInGroup, IsInRaid = function() return false end, function() return false end
    s.SendAddonChecked = function(_, _, chatType) if chatType == "CHANNEL" then channelSends = channelSends + 1 end return true end
    assert(s:Send("ZA", "photo") == true and channelSends == 0, "Solo Send put a map photo on the channel")
    s._channelTokens, s._channelTokensAt = nil, nil
    assert(s:Send("C", "c1") and not s:Send("C", "c2") and channelSends == 1,
        "Solo Send ignored the channel message budget")
    s.GetChannelId, IsInGroup, IsInRaid, s.SendAddonChecked = originalChannelId, originalInGroup, originalInRaid, originalChecked
    GetTime, C_Timer.After = originalGetTime, originalAfter
end
-- ZA ordering: capital flag computed once per entry, same order as the old
-- comparator (territories first, then plain string order), duplicates included.
do
    local originalBase = Overlord.Zones.GetBaseZoneFixedOwner
    local lookups = 0
    Overlord.Zones.GetBaseZoneFixedOwner = function(_, id)
        lookups = lookups + 1
        return (id == "capA" or id == "capH") and "Alliance" or nil
    end
    local input = { "zc:1:A", "capH:9:H", "za:3:H", "capA:2:A", "zb:7:", "za:3:H", "capA:1:A", "zz:0:" }
    local expected = {}
    for i, v in ipairs(input) do expected[i] = v end
    table.sort(expected, function(a, b)
        local aBase = Overlord.Zones:GetBaseZoneFixedOwner((strsplit(":", a))) ~= nil
        local bBase = Overlord.Zones:GetBaseZoneFixedOwner((strsplit(":", b))) ~= nil
        if aBase ~= bBase then return not aBase end
        return a < b
    end)
    lookups = 0
    local ordered = s:OrderZoneAllEntries(input)
    assert(table.concat(ordered, ",") == table.concat(expected, ","),
        "ZA order changed: " .. table.concat(ordered, ","))
    assert(lookups <= #input, "Capital lookups still repeated per comparison: " .. lookups)
    Overlord.Zones.GetBaseZoneFixedOwner = originalBase
end
-- /ov network: channel quota use per message type, relay copies under their kind.
s._channelKindStats = nil
C_ChatInfo = { SendAddonMessage = function() return 8 end }
s:SendAddonChecked("K:a", "CHANNEL", 1)
C_ChatInfo = { SendAddonMessage = function() return 0 end }
s:SendAddonChecked("K:b", "CHANNEL", 1)
s._channelSendKind = "ZS*"
s:SendAddonChecked("BF:fragment", "CHANNEL", 1)
s._channelSendKind = nil
s:SendAddonChecked("K:c", "RAID")
local kindLines = table.concat(s:GetChannelKindDiagnostics(12), " ")
assert(kindLines:find("K 1/2", 1, true) and kindLines:find("ZS* 0/1", 1, true)
    and not kindLines:find("BF", 1, true), "Channel per-type counters wrong: " .. kindLines)
C_ChatInfo = originalChatInfo
print("Beta integration: real R2/fragmented R2, low-level kills, peer trust, no club API, unchanged community payloads OK")
