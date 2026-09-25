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
C_BattleNet = { GetGameAccountInfoByID = function()
    return { characterName = "Bridge Tester", clientProgram = "WoW", wowProjectID = WOW_PROJECT_ID,
        factionName = "Alliance", isInCurrentRegion = true }
end }
assert(loadfile("SyncBetaNetwork.lua"))()
local s, net = Overlord.Sync, Overlord.BetaNetwork
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
print("Beta integration: real R2/fragmented R2, low-level kills, peer trust, no club API, unchanged community payloads OK")
