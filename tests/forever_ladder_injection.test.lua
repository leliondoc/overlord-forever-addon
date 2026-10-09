-- Ladder injection (2026-10-06): a fake "EMPIRE SUCKS" (guild "EMPIRE HACKS", 1088,
-- no class, no race) reached #1. One client sent two channel lines: a guild hint
-- (GY) for a name nobody knew, which created a metadata row and made the name
-- "known", then a ladder row (LK) that every client accepted for a known name.
-- Every rule checked here depends only on the line itself and on this client's
-- faction, the same for every receiver of a channel line: nothing may make two
-- clients keep different rankings (the old quorum desync).
math.randomseed(11)
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
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
local s, lb = Overlord.Sync, Overlord.Leaderboard
assert(loadfile("SyncBetaNetwork.lua"))()
assert(loadfile("SyncHistoryCatchup.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()
local net = Overlord.BetaNetwork
Overlord.PlayerFaction = "Alliance"
Overlord.InstanceSuspended = false
function s:GetChannelId() return 5 end
function s:SendAddonChecked() return true end
function s:SendToBNet() return true end
function s:GetBetaBNetTargets() return {} end

local EPOCH = OverlordDB.lastResetTimestamp
local function lkRow(name, total, faction, class, guild)
    local bucket = s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", faction, EPOCH, "", "enus", 0, EPOCH, 30)
        :match(":(B%d+)")
    return table.concat({ name, tostring(total), class or "WARRIOR", faction, tostring(EPOCH), "enus",
        guild or "", "0", bucket or "B0", "30" }, ":")
end
local function channel(msgType, payload, sender)
    s:OnAddonMessage("OverlordF", msgType .. ":" .. payload, "CHANNEL", sender)
end
local function know(name, total, faction)
    lb.kills[name] = total
    lb.playerInfo[name] = { class = "WARRIOR", faction = faction, level = 30, locale = "enus", guild = "", guildAt = 0 }
end
-- Primes the campaign bucket the way a client does at login (first LK of the session).
s:OnReceiveLeaderboardKills(lkRow("Warmup Player", 1, "Horde"), "Warmup Peer", "CHANNEL")

-- ===== (1) the exact attack: GY for an unknown name, then LK, both on the channel
local fake, fakeGuild = "Empire Sucks", "EMPIRE HACKS"
channel("GY", fake .. "|" .. fakeGuild, "Troll Player")
assert(lb.playerInfo[fake] == nil, "a guild hint created a ladder row for an unknown name")
assert(not s:IsKnownLeaderboardSubject(fake), "a guild hint made an unknown name known")
channel("LK", lkRow(fake, 1088, "Alliance", "", fakeGuild), "Troll Player")
assert(lb.kills[fake] == nil, "a third-party channel LK created a ladder row: " .. tostring(lb.kills[fake]))
-- Same row claiming the enemy faction: still unknown, still refused.
channel("LK", lkRow(fake, 1088, "Horde", "", fakeGuild), "Troll Player")
assert(lb.kills[fake] == nil, "a forged enemy row was accepted for an unknown name")

-- ===== (2) names no character can have (Forever capitalises each word)
local shout = "EMPIRE SUCKS"
assert(s:IsDeniedKillContributor(shout), "an all-caps name is a ladder subject")
assert(s:IsDeniedKillContributor("empire sucks"), "a lowercase name is a ladder subject")
assert(s:IsDeniedKillContributor("Empire SUCKS"), "a word with inner capitals is a ladder subject")
assert(not s:IsDeniedKillContributor("Kaín Peraxxis"), "an accented name was refused")
assert(not s:IsDeniedKillContributor("Pàmpamsh Ka"), "an accented name was refused")
assert(not s:IsDeniedKillContributor("Élodie Marchand"), "an accented capital first letter was refused")
assert(not s:IsDeniedKillContributor("Shobek'aran Vale"), "an apostrophe was refused")
assert(not s:IsDeniedKillContributor("D'Arcy Lee"), "a capital after an apostrophe was refused")
assert(s:IsDeniedKillContributor("D'ARCY Lee"), "inner capitals after an apostrophe were accepted")
-- A removed name's capture row is consumed but never stored, nor served (this week's list).
local realCampaignId = OverlordDB.campaignId
OverlordDB.campaignId = 20261006
assert(s:IsDeniedKillContributor("Empire Sucks"), "this week's removal is not applied")
s._pagedDelivery = { kind = "LC", sender = "Page Peer", channel = "WHISPER",
    key = s:GetCaptureContributorDedupKey("Empire Sucks"):lower() }
assert(s:OnReceiveLeaderboardCaptures(table.concat({ "Empire Sucks", "A", "WARRIOR", "9", tostring(EPOCH), "",
    "enus", "B" .. EPOCH }, ":"), "Page Peer", "WHISPER") == true, "a removed capture row was not consumed")
s._pagedDelivery = nil
assert(lb.captureCount["Empire Sucks"] == nil, "a removed name got a capture row from a page")
assert(s:BuildPagedLeaderboardCapturePayload({ captureCount = { ["Empire Sucks"] = 9 }, captures = {},
    playerInfo = {} }, "Empire Sucks", EPOCH) == nil, "a removed name's capture row was served")
OverlordDB.campaignId = realCampaignId
-- Even from a solicited ranking page (the catch-up path), such a row is refused.
s._pagedDelivery = { kind = "LK", sender = "Page Peer", channel = "WHISPER",
    key = s:GetCaptureContributorDedupKey(shout):lower() }
s:OnReceiveLeaderboardKills(lkRow(shout, 1088, "Alliance", "", fakeGuild), "Page Peer", "WHISPER")
s._pagedDelivery = nil
assert(lb.kills[shout] == nil, "a ranking page created an all-caps row")
-- Same for the capture stream (its own gate, LC has no ladder denylist check).
s._pagedDelivery = { kind = "LC", sender = "Page Peer", channel = "WHISPER",
    key = s:GetCaptureContributorDedupKey(shout):lower() }
s:OnReceiveLeaderboardCaptures(table.concat({ shout, "A", "WARRIOR", "7", tostring(EPOCH), "",
    "enus", "B" .. EPOCH }, ":"), "Page Peer", "WHISPER")
s._pagedDelivery = nil
assert(lb.captureCount[shout] == nil, "a ranking page created an all-caps capture row")

-- ===== (3) a guild hint still fills a ranked player's missing guild, as the
-- whispered answer to our own request (GR) only
know("Ranked Friend", 40, "Alliance")
channel("GY", "Ranked Friend|Wrong Guild", "Troll Player")
assert(lb.playerInfo["Ranked Friend"].guild == "", "a channel guild hint was applied")
s:OnAddonMessage("OverlordF", "GY:Ranked Friend|Wrong Guild", "WHISPER", "Troll Player")
assert(lb.playerInfo["Ranked Friend"].guild == "", "an unrequested guild answer was applied")
local sentGR = {}
function s:SendToNamedPeers(kind, payload) sentGR[#sentGR + 1] = kind .. ":" .. payload end
function s:BroadcastToRelay(kind, payload) sentGR[#sentGR + 1] = kind .. ":" .. payload end
local realRandom = math.random
math.random = function(a, b) if a then return a end return 0 end
s:MaybeRequestMissingGuild("Ranked Friend")
s:FlushGuildRequests()
math.random = realRandom
assert(#sentGR > 0 and sentGR[1]:find("Ranked Friend", 1, true), "no guild request was sent")
-- The first answer alone (the attacker answers fastest) changes nothing...
s:OnAddonMessage("OverlordF", "GY:Ranked Friend|EMPIRE HACKS", "WHISPER", "Troll Player")
s:OnAddonMessage("OverlordF", "GY:Ranked Friend|Real Guild", "WHISPER", "Helpful Peer")
assert(lb.playerInfo["Ranked Friend"].guild == "", "a single answer set a guild")
-- ...the same peer repeating its answer still counts once.
s:OnAddonMessage("OverlordF", "GY:Ranked Friend|Real Guild", "WHISPER", "Helpful Peer")
assert(lb.playerInfo["Ranked Friend"].guild == "", "one peer repeating itself counted twice")
-- A second voter with another spelling is not an agreement (it would choose the casing).
s:OnAddonMessage("OverlordF", "GY:Ranked Friend|rEAL gUILD", "WHISPER", "Casing Peer")
assert(lb.playerInfo["Ranked Friend"].guild == "", "a differently cased answer counted as agreement: "
    .. tostring(lb.playerInfo["Ranked Friend"].guild))
s:OnAddonMessage("OverlordF", "GY:Ranked Friend|Real Guild", "WHISPER", "Second Peer")
assert(lb.playerInfo["Ranked Friend"].guild == "Real Guild", "two concordant answers to our guild request were refused")
-- Each layer on its own: a requested, ranked name still ignores channel copies...
lb.playerInfo["Ranked Friend"].guild = ""
channel("GY", "Ranked Friend|Channel Guild", "Troll Player")
assert(lb.playerInfo["Ranked Friend"].guild == "", "a channel guild hint was applied to a requested name")
-- ...and a second-hand guild never creates a row, whatever path calls the setter.
lb:SetPlayerGuild("Fresh Stranger", "EMPIRE HACKS", true, false, 0, false)
assert(lb.playerInfo["Fresh Stranger"] == nil, "a second-hand guild created a ladder row")

-- ===== (4) live rows from a third party: only enemy totals (bridge copies)
know("Faction Mate", 100, "Alliance")
channel("LK", lkRow("Faction Mate", 130, "Alliance"), "Troll Player")
assert(lb.kills["Faction Mate"] == 100,
    "a third party raised an own-faction player on the channel: " .. tostring(lb.kills["Faction Mate"]))
-- Claiming the other faction for a player known as ours changes nothing.
channel("LK", lkRow("Faction Mate", 130, "Horde"), "Troll Player")
assert(lb.kills["Faction Mate"] == 100, "a faction lie let a third party raise an own-faction player")
assert(lb.playerInfo["Faction Mate"].faction == "Alliance", "a forged row changed a player's faction")
-- The owner itself still raises its own total.
local function ownK(name, total, faction)
    channel("K", s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", faction, EPOCH, "", "enus", 0, EPOCH, 30), name)
end
ownK("Faction Mate", 105, "Alliance")
assert(lb.kills["Faction Mate"] == 105, "the owner's own K no longer raises its row")
-- An enemy total posted by a bridge (channel), or sent by an enemy Battle.net friend.
know("Enemy Fighter", 200, "Horde")
channel("LK", lkRow("Enemy Fighter", 205, "Horde"), "Bridge Peer")
assert(lb.kills["Enemy Fighter"] == 205, "a bridge copy of an enemy total was refused")
s:DispatchBNetMessage("LK", lkRow("Enemy Fighter", 210, "Horde"), "BNet-77", 77)
assert(lb.kills["Enemy Fighter"] == 210, "an enemy total from a Battle.net friend was refused")
-- A bridge never sends a "-Suffix" alias of a known enemy (it would relabel the row).
-- In game the identity index is warm, so the alias counts as known: emulate it.
local realMax = lb.GetMaxKillsForDedupName
lb.GetMaxKillsForDedupName = function(self, n)
    if s:GetCaptureContributorDedupKey(n) == "enemy fighter" then return 210 end
    return realMax(self, n)
end
assert(s:IsKnownLeaderboardSubject("Enemy Fighter-Defaced"), "fixture: the alias is not known")
channel("LK", lkRow("Enemy Fighter-Defaced", 215, "Horde"), "Troll Player")
lb.GetMaxKillsForDedupName = realMax
assert(lb.kills["Enemy Fighter-Defaced"] == nil, "a live third-party row created an alias spelling")

-- ===== (4b) a bridge copy brings a total, nothing else (fake guild, class, level)
know("Enemy Star", 400, "Horde")
lb.playerInfo["Enemy Star"].guild, lb.playerInfo["Enemy Star"].guildAt = "", 0
channel("LK", table.concat({ "Enemy Star", "420", "DEATHKNIGHT", "Horde", tostring(EPOCH), "zhcn",
    "EMPIRE HACKS", tostring(time() + 290), lkRow("Enemy Star", 1, "Horde"):match(":(B%d+):"), "90" }, ":"),
    "Troll Player")
local star = lb.playerInfo["Enemy Star"]
assert(lb.kills["Enemy Star"] == 420, "a plausible bridge total was refused: " .. tostring(lb.kills["Enemy Star"]))
assert(star.guild == "", "a bridge copy set a guild: " .. tostring(star.guild))
assert(star.class == "WARRIOR", "a bridge copy replaced a known class: " .. tostring(star.class))
assert(star.locale == "enus", "a bridge copy replaced a known locale")
assert((tonumber(star.level) or 0) == 32, "a bridge copy may raise the held level by two, never to its own: " .. tostring(star.level))
-- One forged copy cannot take a known enemy past the first-contact bound, however long
-- this client has been online (the absence window grows with uptime).
do
    know("Enemy Target", 400, "Horde")
    -- One hour into the campaign (first-contact bound 408), this client online for 8 h.
    local start = Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs() or 0
    local realNow, realLast = Overlord.ServerNow, OverlordDB.lastSessionTimestamp
    Overlord.ServerNow = function() return start + 3600 end
    OverlordDB.lastSessionTimestamp = time() - 8 * 3600
    channel("LK", lkRow("Enemy Target", 14000, "Horde"), "Troll Player")
    Overlord.ServerNow, OverlordDB.lastSessionTimestamp = realNow, realLast
    local cap = 400 + 600 + 30 + 10
    assert(lb.kills["Enemy Target"] <= cap,
        "a forged copy used the uptime window: " .. tostring(lb.kills["Enemy Target"]) .. " > " .. cap)
end
-- A bridge copy for an enemy whose faction we do not hold yet is not admitted.
lb.kills["Faceless Enemy"] = 50
lb.playerInfo["Faceless Enemy"] = { class = "", faction = "", level = 30, locale = "", guild = "", guildAt = 0 }
channel("LK", lkRow("Faceless Enemy", 60, "Horde"), "Troll Player")
assert(lb.kills["Faceless Enemy"] == 50, "a copy filed a player under the faction it claimed")

-- ===== (4c) a second-hand guild (GY hint) is never served in ranking pages
do
    local serve = s.BuildPagedLeaderboardKillPayload
    local snap = { kills = { ["Hint Holder"] = 30, ["Strong Holder"] = 30 }, playerInfo = {
        ["Hint Holder"] = { class = "MAGE", faction = "Alliance", level = 30, locale = "enus",
            guild = "EMPIRE HACKS", guildAt = 0 },
        ["Strong Holder"] = { class = "MAGE", faction = "Alliance", level = 30, locale = "enus",
            guild = "Real Guild", guildAt = 1790016000, guildAuth = true } } }
    local hint = serve(s, snap, "Hint Holder", EPOCH)
    local strong = serve(s, snap, "Strong Holder", EPOCH)
    assert(hint and not hint:find("EMPIRE HACKS", 1, true), "a guild hint was served in a page: " .. tostring(hint))
    assert(strong and strong:find("Real Guild", 1, true), "a confirmed guild was not served: " .. tostring(strong))
end

-- ===== (4d) a race from anyone but the player only fills a missing race
lb.playerInfo["Enemy Star"].race, lb.playerInfo["Enemy Star"].raceSex, lb.playerInfo["Enemy Star"].raceAt = "Orc", 2, 100
local function lrRow(name, race, at) return table.concat({ name, race, "2", tostring(EPOCH), tostring(at) }, ":") end
channel("LR", lrRow("Enemy Star", "Troll", time() + 290), "Troll Player")
assert(lb.playerInfo["Enemy Star"].race == "Orc", "a third-party race replaced a known race")
lb.playerInfo["Enemy Fighter"].race = ""
-- One observer alone does not fill it (one forged line set a race for everyone); a
-- second observer naming another race is no agreement; a second one agreeing fills it.
channel("LR", lrRow("Enemy Fighter", "Tauren", time() + 290), "Helpful Peer")
assert((lb.playerInfo["Enemy Fighter"].race or "") == "", "a single third-party race filled a missing race")
channel("LR", lrRow("Enemy Fighter", "Troll", time() + 290), "Troll Player")
assert((lb.playerInfo["Enemy Fighter"].race or "") == "", "two different races counted as agreement")
channel("LR", lrRow("Enemy Fighter", "Tauren", time() + 290), "Second Peer")
assert(lb.playerInfo["Enemy Fighter"].race == "Tauren", "two agreeing observers no longer fill a missing race")
assert((tonumber(lb.playerInfo["Enemy Fighter"].raceAt) or 0) == 0, "a third-party race was dated")
-- An unranked spelling (case variant of a ranked player) gets no row from a live LR.
lb.kills["D'arcy Lee"] = 12
-- In game the identity index is warm: the variant counts as known. Emulate it.
local realMaxLR = lb.GetMaxKillsForDedupName
lb.GetMaxKillsForDedupName = function(self, n)
    if s:GetCaptureContributorDedupKey(n) == "d'arcy lee" then return 12 end
    return realMaxLR(self, n)
end
assert(s:IsKnownLeaderboardSubject("D'Arcy Lee"), "fixture: the case variant is not known")
channel("LR", lrRow("D'Arcy Lee", "Human", time()), "Troll Player")
lb.GetMaxKillsForDedupName = realMaxLR
assert(lb.playerInfo["D'Arcy Lee"] == nil, "a live LR created an alias row")

-- ===== (4e) a class answer needs two concordant direct peers too
do
    know("Classless Foe", 70, "Horde")
    lb.playerInfo["Classless Foe"].class = ""
    local sentCR = {}
    local realGroup, realChannel = s.SendToGroup, s.SendToChannel
    function s:SendToGroup(kind, payload) sentCR[#sentCR + 1] = payload end
    function s:SendToChannel(kind, payload) sentCR[#sentCR + 1] = payload end
    local realRandom2 = math.random
    math.random = function(a, b) if a then return a end return 0 end
    s:MaybeRequestMissingClass("Classless Foe")
    if s.FlushClassRequests then s:FlushClassRequests() end
    math.random = realRandom2
    s.SendToGroup, s.SendToChannel = realGroup, realChannel
    assert(#sentCR > 0, "fixture: no class request was sent")
    s:OnAddonMessage("OverlordF", "CA:Classless Foe|DEATHKNIGHT", "WHISPER", "Troll Player")
    assert(lb.playerInfo["Classless Foe"].class == "", "a single class answer set the class")
    s:OnAddonMessage("OverlordF", "CA:Classless Foe|ROGUE", "WHISPER", "Helpful Peer")
    s:OnAddonMessage("OverlordF", "CA:Classless Foe|ROGUE", "WHISPER", "Second Peer")
    assert(lb.playerInfo["Classless Foe"].class == "ROGUE", "two concordant class answers were refused")
end

-- ===== (5) only a score makes a name known (metadata alone does not)
lb.playerInfo["Seen Only"] = { class = "MAGE", faction = "Horde", level = 30, locale = "", guild = "", guildAt = 0 }
assert(not s:IsKnownLeaderboardSubject("Seen Only"), "metadata alone made a name known")
channel("LK", lkRow("Seen Only", 900, "Horde"), "Bridge Peer")
assert(lb.kills["Seen Only"] == nil, "a live row created a subject that had only metadata")

-- ===== (6) the catch-up path is unchanged for real names (convergence)
s._pagedDelivery = { kind = "LK", sender = "Page Peer", channel = "WHISPER",
    key = s:GetCaptureContributorDedupKey("Late Joiner"):lower() }
s:OnReceiveLeaderboardKills(lkRow("Late Joiner", 50, "Alliance"), "Page Peer", "WHISPER")
s._pagedDelivery = nil
assert(lb.kills["Late Joiner"] == 50, "a ranking page no longer brings a new player")

-- ===== (6b) captures: an LC only ever comes from a page or an SR:F reply
know("Capture Mate", 10, "Horde")
lb.captureCount["Capture Mate"] = 2
local lc = table.concat({ "Capture Mate", "H", "WARRIOR", "499", tostring(EPOCH), "", "enus",
    "B" .. EPOCH }, ":")
channel("LC", lc, "Troll Player")
s:DispatchBNetMessage("LC", lc, "BNet-77", 77)
s:OnAddonMessage("OverlordF", "LC:" .. lc, "WHISPER", "Troll Player")
assert(lb.captureCount["Capture Mate"] == 2,
    "an unsolicited LC raised captures: " .. tostring(lb.captureCount["Capture Mate"]))

-- ===== (6c) a row already saved under an impossible name is purged at load (v8)
local timers = {}
local realAfter = C_Timer.After
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
lb.kills[shout] = 1088
lb.captureCount[shout] = 3
lb.playerInfo[shout] = { class = "", faction = "Alliance", guild = fakeGuild, level = 30 }
OverlordDB.leaderboard = OverlordDB.leaderboard or {}
OverlordDB.leaderboard.kills, OverlordDB.leaderboard.captureCount = lb.kills, lb.captureCount
OverlordDB.leaderboardScoreSanitizeVersion = 7
lb:EnsureLegacyScoreSanitized()
local guard = 0
while OverlordDB.leaderboardScoreSanitizeVersion ~= 9 and #timers > 0 do
    guard = guard + 1
    assert(guard < 400, "cleanup did not finish")
    table.remove(timers, 1)()
end
C_Timer.After = realAfter
assert(OverlordDB.leaderboardScoreSanitizeVersion == 9, "v9 cleanup did not commit")
assert(lb.kills[shout] == nil, "a saved all-caps kill row survived the cleanup")
assert(lb.captureCount[shout] == nil, "a saved all-caps capture row survived the cleanup")
assert(lb.kills["Faction Mate"] == 105, "the cleanup removed a real player")

-- ===== (6d) a peer cannot make itself "other faction" (picked 2 catch-up rounds of 3)
lb.playerInfo["Liar Peer"] = { class = "ROGUE", faction = "Horde", level = 30, guild = "", guildAt = 0 }
assert(s:GetBetaPeerFaction("Liar Peer") == nil, "a self-declared faction made a peer an enemy")
lb.playerInfo["Mate Peer"] = { class = "ROGUE", faction = "Alliance", level = 30, guild = "", guildAt = 0 }
assert(s:GetBetaPeerFaction("Mate Peer") == "Alliance", "a same-faction peer lost its faction")
local realResolve = s.GetResolvedBNetPlayerFaction
s.GetResolvedBNetPlayerFaction = function(_, name) if name == "Liar Peer" then return "Horde" end end
assert(s:GetBetaPeerFaction("Liar Peer") == "Horde", "a Battle.net friend's faction was ignored")
s.GetResolvedBNetPlayerFaction = realResolve

-- ===== (7) two clients hearing the same channel lines keep the same ranking
local function snapshot()
    local out = {}
    for name, kills in pairs(lb.kills) do out[#out + 1] = name .. "=" .. kills end
    table.sort(out)
    return table.concat(out, ",")
end
local first = snapshot()
channel("GY", "Other Fake|EMPIRE HACKS", "Troll Player")
channel("LK", lkRow("Other Fake", 999, "Alliance"), "Troll Player")
channel("LK", lkRow("Faction Mate", 999, "Alliance"), "Troll Player")
assert(snapshot() == first, "forged channel lines changed the ranking")

print("Forever ladder injection: guild hints create nothing, third-party live rows only for enemy totals, impossible names refused, catch-up unchanged")
