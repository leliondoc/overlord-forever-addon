-- Ladder signatures (2026-10-09): a row "Asmon Gold", 4897 HK (the first-contact cap at
-- that hour), guild "EMPIRE HACKS", no class (grey name) and level 90 reached #1 again.
-- 1.7.5 refuses what no honest client sends, on every path and on every client alike:
-- a ladder row without a class, a level above 60, a name that is not the canonical
-- "Given Family" spelling or that uses invisible or mixed-script letters. It also stops
-- a third party from inflating our own row (our K re-announced it as the owner's total),
-- bounds /ov sync replies like any unsolicited total, and (1.7.6) holds every received
-- total to the campaign envelope. Every rule depends only on the
-- row itself: two clients receiving the same rows by different routes end identical.
math.randomseed(13)
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
Overlord.PlayerFaction = "Alliance"
Overlord.InstanceSuspended = false
function s:GetChannelId() return 5 end
function s:SendAddonChecked() return true end
function s:SendToBNet() return true end
function s:GetBetaBNetTargets() return {} end

local EPOCH = OverlordDB.lastResetTimestamp
local BUCKET = s:BuildKillBroadcastPayload("Warmup Player", "", 1, "WARRIOR", "Horde", EPOCH, "", "enus", 0, EPOCH, 30)
    :match(":(B%d+)")
local function lkRow(name, total, class, level, guild)
    return table.concat({ name, tostring(total), class, "Alliance", tostring(EPOCH), "enus",
        guild or "", guild and tostring(time()) or "0", BUCKET, tostring(level or 30) }, ":")
end
-- K wire: name:zone:total:class:faction:epoch:guild:locale:guildAt:Bbucket:level
local function kPayload(name, total, class, level)
    return table.concat({ name, "", tostring(total), class, "Alliance", tostring(EPOCH),
        "EMPIRE HACKS", "enus", tostring(time()), BUCKET, tostring(level or 30) }, ":")
end
local function send(msgType, payload, sender, transport)
    s:OnAddonMessage("OverlordF", msgType .. ":" .. payload, transport or "CHANNEL", sender)
end
-- A row inside a ranking page we asked for, the way tryApply delivers it.
local function pageRow(payload, peer)
    local name = payload:match("^([^:]+)")
    s._pagedDelivery = { kind = "LK", sender = peer, channel = "WHISPER",
        key = (s:GetCaptureContributorDedupKey(name) or ""):lower() }
    local accepted = s:OnReceiveLeaderboardKills(payload, peer, "WHISPER")
    s._pagedDelivery = nil
    return accepted
end
s:OnReceiveLeaderboardKills(lkRow("Warmup Player", 1, "WARRIOR"), "Warmup Peer", "CHANNEL")

-- ===== (1) the owner's own K: a modified client leaves the class out, claims level 90
send("K", kPayload("Fresh Troll", 4897, ""), "Fresh Troll")
assert(lb.kills["Fresh Troll"] == nil, "a K without a class created a row")
assert(lb.playerInfo["Fresh Troll"] == nil, "a K without a class left a metadata row")
send("K", kPayload("Fresh Troll", 4897, "WARRIOR", 90), "Fresh Troll")
assert(lb.kills["Fresh Troll"] == nil, "a K at level 90 created a row")
local suspects = s:GetSuspiciousSenderDiagnostics()
assert(suspects:find("Fresh Troll", 1, true) and suspects:find("classless K", 1, true)
    and suspects:find("over-level K", 1, true), "the sender was not named in /ov network: " .. suspects)
send("K", kPayload("Fresh Troll", 400, "WARRIOR"), "Fresh Troll")
assert(lb.kills["Fresh Troll"] == 400, "an honest K (class, level 30) was refused")

-- ===== (2) a ranking page: no class or level 90 is no row; honest rows still land
assert(pageRow(lkRow("Paged Ghost", 4897, "", 30, "EMPIRE HACKS"), "Some Responder") == true,
    "a refused page row failed the page instead of counting as received")
assert(lb.kills["Paged Ghost"] == nil and lb.playerInfo["Paged Ghost"] == nil,
    "a page row without a class was stored")
pageRow(lkRow("Paged Ghost", 4897, "MAGE", 90, "EMPIRE HACKS"), "Some Responder")
assert(lb.kills["Paged Ghost"] == nil, "a page row at level 90 was stored")
pageRow(lkRow("Paged Real", 900, "MAGE", 30), "Some Responder")
assert(lb.kills["Paged Real"] == 900, "an honest page row was refused")
-- Same rule when serving: a client never hands such a row on.
local serve = s.BuildPagedLeaderboardKillPayload
local snap = { kills = { ["Ghost Row"] = 500, ["Real Row"] = 500 }, playerInfo = {
    ["Ghost Row"] = { class = "", faction = "Alliance", level = 30, locale = "enus" },
    ["Real Row"] = { class = "MAGE", faction = "Alliance", level = 30, locale = "enus" } } }
assert(serve(s, snap, "Ghost Row", EPOCH) == nil, "a row without a class was served in a page")
assert(serve(s, snap, "Real Row", EPOCH) ~= nil, "an honest row was not served")

-- ===== (3) names: one canonical spelling, letters of a single alphabet per word
local variants = {
    "Fresh  Name",                 -- two spaces: same identity, another key
    "Fresh Name-x",                -- suffix
    "Fresh Na\194\160me",          -- no-break space
    "Fresh Na\226\128\139me",      -- zero-width space
    "Fr\208\181sh Name",           -- Cyrillic e inside a Latin word
}
for _, name in ipairs(variants) do
    assert(s:IsDeniedKillContributor(name), "a look-alike spelling is a ladder subject: " .. name)
    pageRow(lkRow(name, 3000, "MAGE", 30), "Some Responder")
    assert(lb.kills[name] == nil, "a look-alike spelling got a row: " .. name)
end
for _, name in ipairs({ "\195\137lodie Marchand", "Ka\195\173n Peraxxis", "D'Arcy Lee",
    "\208\152\208\178\208\176\208\189 \208\146\208\190\208\184\208\189",          -- Cyrillic
    "\206\145\206\187\206\173\206\190\206\177\206\189\206\180\207\129\206\191\207\130 \206\160\206\177\207\128\207\128\206\172\207\130", -- Greek
    "\234\185\128 \236\178\160\236\136\152",                                      -- Hangul
    "\230\157\142 \229\176\143\233\190\153",                                      -- Han
    "Nguy\225\187\133n V\196\131n" }) do                                          -- Vietnamese
    assert(not s:IsDeniedKillContributor(name), "a real name was refused: " .. name)
end
pageRow(lkRow("\195\137lodie Marchand", 700, "PRIEST", 30), "Some Responder")
assert(lb.kills["\195\137lodie Marchand"] == 700, "an accented page row was refused")
-- The permanent blocks follow the canonical identity too.
assert(s:IsDeniedKillContributor("Asmon  Gold") and s:IsDeniedKillContributor("Ender Zero-x"),
    "a blocked name came back under another spelling")
assert(s:IsEligibleKillContributorLevel(60) and not s:IsEligibleKillContributorLevel(61),
    "the level ceiling is not 60")
-- Nor does a blocked or look-alike name get a race row (a ghost served in LR pages).
s._pagedDelivery = { kind = "LR", sender = "Some Responder", channel = "WHISPER", key = "asmon gold" }
s:OnReceiveLeaderboardRace("Asmon Gold:Human:2:" .. EPOCH .. ":0", "Some Responder", "WHISPER")
s._pagedDelivery = nil
assert(lb.playerInfo["Asmon Gold"] == nil, "a blocked name got a race row")
local raceSnap = { playerInfo = { ["Asmon Gold"] = { race = "Human", raceSex = 2, raceAt = 0 } } }
assert(s:BuildPagedLeaderboardRacePayload(raceSnap, "Asmon Gold", EPOCH) == nil,
    "a blocked name's race was served")

-- ===== (4) the campaign envelope bounds every path; our own row recovers at session start
-- The fixture is 136 h into the campaign (envelope near 15000): place the clock 24 h in.
local me = s:GetPlayerFullName()
local realServerNow = Overlord.ServerNow
local campaignStart = Overlord:GetCurrentCampaignStartTs()
Overlord.ServerNow = function() return campaignStart + 24 * 3600 end
local envelope = s:CampaignKillEnvelope()
assert(envelope == 300 + math.floor(0.03 * 24 * 3600), "unexpected campaign envelope: " .. tostring(envelope))
-- Any known row: a page brings its total at once, but never above the envelope.
lb.kills["Known Row"] = 1000
lb.playerInfo["Known Row"] = { class = "MAGE", faction = "Alliance", level = 30, locale = "enus", guild = "", guildAt = 0 }
pageRow(lkRow("Known Row", 2400, "MAGE", 30), "Some Responder")
assert(lb.kills["Known Row"] == 2400, "an honest page no longer brought a known row's total")
pageRow(lkRow("Known Row", 15000, "MAGE", 30), "Hostile Responder")
assert(lb.kills["Known Row"] == envelope, "a page raised a known row above the campaign envelope: "
    .. tostring(lb.kills["Known Row"]))
-- The additive sync paths stop at the envelope too.
lb.kills["Additive Row"] = envelope - 5
assert(lb:AddKills("Additive Row", 50, true) == envelope, "a synced batch crossed the campaign envelope")
assert(lb:RegisterKill("Additive Row", true) == envelope, "a synced kill crossed the campaign envelope")
-- A bridge passes on the value it keeps, never a total above the envelope.
lb.kills["Enemy Bridged"] = envelope - 50
lb.playerInfo["Enemy Bridged"] = { class = "ROGUE", faction = "Horde", level = 30, locale = "enus", guild = "", guildAt = 0 }
local bridged
local realBridge = Overlord.BetaNetwork.NoteBridgedEnemyTotal
Overlord.BetaNetwork.NoteBridgedEnemyTotal = function(_, name, _, total) bridged = total end
s:DispatchBNetMessage("LK", table.concat({ "Enemy Bridged", tostring(envelope + 400), "ROGUE", "Horde",
    tostring(EPOCH), "enus", "", "0", BUCKET, "30" }, ":"), "BNet-77", 77)
Overlord.BetaNetwork.NoteBridgedEnemyTotal = realBridge
assert(lb.kills["Enemy Bridged"] == envelope, "fixture: the bridge copy was not admitted: " .. tostring(lb.kills["Enemy Bridged"]))
assert(bridged == envelope, "a bridge passed on a total above the envelope: " .. tostring(bridged))
-- Serving follows the same envelope, so digests stay equal on both sides.
local served = s.BuildPagedLeaderboardKillPayload(s, { kills = { ["Known Row"] = 15000 }, playerInfo = {
    ["Known Row"] = lb.playerInfo["Known Row"] } }, "Known Row", EPOCH)
assert(served and served:match("^[^:]+:(%d+):") == tostring(envelope), "a row above the envelope was served: "
    .. tostring(served))
-- Our own row (our K re-announces it): a session ceiling set at its first raise, our row
-- then plus what we could do while away (same pace as the envelope, since our last logout),
-- so a crash or a session on another PC comes back at once whatever the page order; above
-- that ceiling, the fixed window.
Overlord.ServerNow = function() return campaignStart + 48 * 3600 end
local realIsLocal = lb.IsLocalDisplayName
lb.IsLocalDisplayName = function(_, n)
    return n == "Stale Save" or n == "Short Away" or n == "Lost Save" or n == "Unsure Away"
end
local function ownRow(name, total)
    lb.kills[name] = total
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Alliance", level = 30, locale = "enus", guild = "", guildAt = 0 }
end
local function newSession(saveLoaded, away)
    Overlord.SavedVariablesLoadedAtLogin, Overlord.SessionAbsenceAtLogin = saveLoaded, away
    s._ownRowSessionCap = nil
end
newSession(true, 20 * 3600)
ownRow("Stale Save", 1000)
local ceiling = 1000 + 300 + math.floor(0.03 * 20 * 3600)
pageRow(lkRow("Stale Save", 1001, "WARRIOR", 30), "Some Responder") -- a tiny first raise
pageRow(lkRow("Stale Save", 2500, "WARRIOR", 30), "Some Responder")
assert(lb.kills["Stale Save"] == 2500, "an honest stale save did not recover at once: " .. tostring(lb.kills["Stale Save"]))
pageRow(lkRow("Stale Save", 15000, "WARRIOR", 30), "Hostile Responder")
assert(lb.kills["Stale Save"] == ceiling, "a page went past what we could do while away: "
    .. tostring(lb.kills["Stale Save"]))
pageRow(lkRow("Stale Save", 15000, "WARRIOR", 30), "Hostile Responder")
assert(lb.kills["Stale Save"] <= ceiling + 600 + 30 + 10, "a page raised our own row in one go above the ceiling: "
    .. tostring(lb.kills["Stale Save"]))
-- Back after one minute: a hostile page adds what a minute away allows, no more.
newSession(true, 60)
ownRow("Short Away", 1000)
pageRow(lkRow("Short Away", 15000, "WARRIOR", 30), "Hostile Responder")
assert(lb.kills["Short Away"] == 1000 + 300 + math.floor(0.03 * 60), "the first raise ignored our time away: "
    .. tostring(lb.kills["Short Away"]))
-- A loaded save whose last logout is unknown: no time away is assumed.
newSession(true, nil)
ownRow("Unsure Away", 1000)
pageRow(lkRow("Unsure Away", 15000, "WARRIOR", 30), "Hostile Responder")
assert(lb.kills["Unsure Away"] == 1300, "an unknown absence opened our own row: " .. tostring(lb.kills["Unsure Away"]))
-- A session without its save (loader fault, reinstall): the whole envelope, at once.
newSession(false, nil)
pageRow(lkRow("Lost Save", 2000, "MAGE", 30), "Some Responder")
assert(lb.kills["Lost Save"] == 2000, "a lost save did not get its row back: " .. tostring(lb.kills["Lost Save"]))
Overlord.SavedVariablesLoadedAtLogin, Overlord.SessionAbsenceAtLogin = true, nil
lb.IsLocalDisplayName = realIsLocal
Overlord.ServerNow = realServerNow
lb.kills[me] = 1000
lb.playerInfo[me] = { class = "WARRIOR", faction = "Alliance", level = 30, locale = "enus", guild = "", guildAt = 0 }
-- After a weekly reset while online our recreated row had no class (so it was no longer
-- served); the next local kill fills it like the login does.
lb.playerInfo[me].class = ""
lb:RegisterKill(me)
assert(s:IsLadderRowClass(lb.playerInfo[me].class), "our own row stayed without a class after a kill: "
    .. tostring(lb.playerInfo[me].class))
local forced, realForce = 0, lb.ForceUpdateLocalPlayer
lb.ForceUpdateLocalPlayer = function(...) forced = forced + 1; return realForce(...) end
lb:RegisterKill(me)
lb.ForceUpdateLocalPlayer = realForce
assert(forced == 0, "a kill with a known class rebuilt our own row")

-- ===== (5) a /ov sync reply follows the unsolicited bound, even for a known row
send("K", kPayload("Synced Ally", 100, "WARRIOR"), "Synced Ally")
assert(lb.kills["Synced Ally"] == 100, "fixture: the owner's K was refused")
assert(s:ExpectDirectFullLeaderboardResponse("Sync Target"), "fixture: /ov sync not armed")
send("LK", lkRow("Synced Ally", 7000, "WARRIOR", 30), "Sync Target", "WHISPER")
assert(lb.kills["Synced Ally"] > 100 and lb.kills["Synced Ally"] < 1000,
    "a /ov sync reply was not bounded (or was dropped): " .. tostring(lb.kills["Synced Ally"]))

-- ===== (6) only the transports the addon uses
send("K", kPayload("Guild Shout", 300, "WARRIOR"), "Guild Shout", "GUILD")
assert(lb.kills["Guild Shout"] == nil, "a K sent on GUILD was read")
send("K", kPayload("Guild Shout", 300, "WARRIOR"), "Guild Shout", "CHANNEL")
assert(lb.kills["Guild Shout"] == 300, "fixture: the same K on the channel was refused")

-- ===== (7) "nan" is never a date (it froze a guild for the week)
lb.playerInfo["Nan Owner"] = { class = "MAGE", faction = "Alliance", level = 30, locale = "enus", guild = "", guildAt = 0 }
lb:MergeOwnedGuildMetadata("Nan Owner", "Frozen Guild", "nan")
local frozenAt = lb.playerInfo["Nan Owner"].guildAt
assert(frozenAt == frozenAt, "a NaN guild date was stored")
lb:MergeOwnedGuildMetadata("Nan Owner", "Later Guild", time())
assert(lb.playerInfo["Nan Owner"].guild == "Later Guild", "a NaN guild date blocked a later one")
assert(s:SanitizeSyncedCaptureCount("nan") == nil, "a NaN capture count was accepted")

-- ===== (8) the v10 cleanup removes saved rows that break the same rules
local timers = {}
local realAfter = C_Timer.After
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local function savedRow(name, total, class, level)
    lb.kills[name] = total
    lb.playerInfo[name] = { class = class, faction = "Alliance", level = level, locale = "enus", guild = "", guildAt = 0 }
end
savedRow("Saved Ghost", 4897, "", 30)
savedRow("Saved Ninety", 3000, "MAGE", 90)
savedRow("Saved Honest", 500, "MAGE", 30)
savedRow("Saved Cased", 450, "Warrior", 30) -- an old save, fixed by the login repair
savedRow("Saved Inflated", 9000, "MAGE", 30)
savedRow("Account Big", 9000, "MAGE", 30)
savedRow("Account Alt", 200, "", 30)
lb.kills["Saved  Spaced"] = 800
lb.playerInfo["Asmon Gold"] = { class = "", faction = "Alliance", level = 90, guild = "EMPIRE HACKS", guildAt = 0 }
lb.playerInfo[me].class = ""
OverlordDB.leaderboardLocalKillKeys = { ["Account Alt"] = true, ["Account Big"] = true }
OverlordDB.leaderboard = OverlordDB.leaderboard or {}
OverlordDB.leaderboard.kills, OverlordDB.leaderboard.playerInfo = lb.kills, lb.playerInfo
OverlordDB.leaderboardScoreBucketEpoch = campaignStart
OverlordDB.leaderboardsByPool = { lastweek = { campaignStart = campaignStart - 604800,
    kills = { ["Lastweek Star"] = 9000 }, playerInfo = { ["Lastweek Star"] = { class = "MAGE",
    faction = "Alliance", level = 30, locale = "enus", guild = "", guildAt = 0 } } } }
OverlordDB.leaderboardScoreSanitizeVersion = 9
Overlord.ServerNow = function() return campaignStart + 24 * 3600 end
lb:EnsureLegacyScoreSanitized()
local guard = 0
while OverlordDB.leaderboardScoreSanitizeVersion ~= 11 and #timers > 0 do
    guard = guard + 1
    assert(guard < 400, "cleanup did not finish")
    table.remove(timers, 1)()
end
C_Timer.After = realAfter
Overlord.ServerNow = realServerNow
assert(OverlordDB.leaderboardScoreSanitizeVersion == 11, "v11 cleanup did not commit")
assert(lb.kills["Saved Ghost"] == nil, "a saved row without a class survived the cleanup")
assert(lb.kills["Saved Ninety"] == nil, "a saved level-90 row survived the cleanup")
assert(lb.kills["Saved  Spaced"] == nil, "a saved non-canonical spelling survived the cleanup")
assert(lb.playerInfo["Asmon Gold"] == nil, "a blocked name kept its metadata (ghost guild)")
assert(lb.kills["Saved Honest"] == 500, "the cleanup removed an honest row")
assert(lb.kills["Saved Inflated"] == envelope, "a saved row above the campaign envelope was not clamped: "
    .. tostring(lb.kills["Saved Inflated"]))
assert(OverlordDB.leaderboardsByPool.lastweek.kills["Lastweek Star"] == 9000,
    "the cleanup clamped last week's bucket with this week's envelope")
assert(lb.kills["Account Big"] == 9000, "the cleanup clamped one of this account's characters")
assert(lb.kills["Saved Cased"] == 450, "the cleanup removed an honest row whose class token was not normalized yet")
assert(lb.kills["Account Alt"] == 200, "the cleanup removed one of this account's characters")
assert(lb.kills[me] ~= nil, "the cleanup removed our own row")
print("Forever ladder signatures: classless and level-90 rows refused and never served, canonical names, campaign envelope, own row budget, /ov sync bound, transports, NaN dates, v11 cleanup OK")
