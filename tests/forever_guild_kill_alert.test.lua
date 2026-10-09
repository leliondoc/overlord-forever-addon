-- Guild raid alert: every client counts authenticated K for guilds of BOTH factions
-- (and its own kills); the detector shares one GW through the relay; only the
-- enemy faction of the guild prints it.
assert(loadfile("tests/forever_world_kills.test.lua"))()
assert(loadfile("GuildKillAlert.lua"))()
local NAMES = { "Alpha Tester", "Bravo Tester", "Charlie Tester", "Delta Tester", "Echo Tester", "Foxtrot Tester" }
local GKA = Overlord.GuildKillAlert
-- The cases below predate the allied rampage line (1.7.1): checked with it off, then
-- the allied section at the end turns it on.
GKA:SetAllyEnabled(false)
local clock, serverClock = 1000, 1789530000
local EPOCH = 1789527600
function GetTime() return clock end
function GetServerTime() return serverClock end
Overlord.PlayerFaction = "Horde"
Overlord.Zones.GetEnemyFactionName = function() return "Alliance" end
local printed = {}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
local shards = { [NAMES[1]] = 143 }
Overlord.Sync.GetShardAlertTagForPlayer = function(_, name)
    return shards[name] and (" #" .. shards[name]) or ""
end
local sent = {}
local function record(kind)
    return function(_, msgType, payload) sent[#sent + 1] = { kind, msgType, payload }; return 1 end
end
local realChannel, realGroup, realCommunity, realBeta, realBetaEnabled =
    Overlord.Sync.SendToChannel, Overlord.Sync.SendToGroup, Overlord.Sync.BroadcastToRelay,
    Overlord.Relay, Overlord.RelayEnabled
Overlord.Sync.SendToChannel = record("channel")
Overlord.Sync.SendToGroup = record("group")
Overlord.Sync.BroadcastToRelay = record("community")
Overlord.RelayEnabled = true
Overlord.Relay = { Broadcast = record("beta") }
-- Broadcast jitter: timers are collected and fired on demand.
local timers = {}
GKA._After = function(delay, fn)
    assert(delay >= 0.5 and delay <= 6, "Broadcast jitter out of range: " .. tostring(delay))
    timers[#timers + 1] = fn
end
local function flush() local due = timers; timers = {}; for _, fn in ipairs(due) do fn() end end

-- Real receive path: authenticated K from its own author.
local function kill(name, total, zone, guild, faction)
    local payload = Overlord.Sync:BuildKillBroadcastPayload(name, zone or "", total, "WARRIOR",
        faction or "Alliance", EPOCH, guild or "Empire", "enus", 0, EPOCH, 60)
    Overlord.Sync:OnReceiveKill(payload, name)
end
local function alerts(guild)
    local n = 0
    for _, text in ipairs(printed) do if text:find(guild or "Empire", 1, true) then n = n + 1 end end
    return n
end
local function reset() GKA:_ResetState(); printed = {}; sent = {}; timers = {} end
-- 5 members, first K counts 1, second K jumps by 3: 20 kills.
local function raid(zone, base, guild, faction)
    base = base or 0
    for m = 1, 5 do kill(NAMES[m], base + 1, zone, guild, faction) end
    for m = 1, 5 do kill(NAMES[m], base + 4, zone, guild, faction) end
end
local function gw(guild, faction, kills, members, zone, shard, ts)
    return GKA:BuildNetworkPayload(guild, faction, kills, members, zone, shard, ts)
end

-- Two members alone never trigger, whatever their score.
for i = 1, 20 do kill(NAMES[1], i); kill(NAMES[2], i) end
assert(alerts() == 0 and #sent == 0 and #timers == 0, "Two members triggered a guild alert")

-- Duplicate copies of the same K count once; coalesced K counts its full jump.
reset()
for m = 1, 5 do kill(NAMES[m], 1); kill(NAMES[m], 1) end
assert(alerts() == 0, "Five duplicated kills triggered the alert")
for m = 1, 5 do kill(NAMES[m], 4) end
assert(alerts() == 1, "20 kills by 5 members did not alert")
local text = printed[1]
assert(text:find("20+ HK by 5+ members (#143)!", 1, true), text)
for _, name in ipairs(NAMES) do assert(not text:find(name, 1, true), "Alert named a player: " .. text) end

-- The detector shares exactly one GW, after a random delay, through the relay only.
assert(#sent == 0 and #timers == 1, "GW was not deferred")
flush()
assert(#sent == 1 and sent[1][1] == "beta" and sent[1][2] == "GW", "GW did not go through the relay alone")
assert(sent[1][3] == "1:Empire:A:20:5::143:" .. serverClock, sent[1][3])

-- Cooldown: another burst right away stays silent and sends nothing.
sent = {}
for m = 1, 5 do kill(NAMES[m], 20) end
assert(alerts() == 1 and #sent == 0 and #timers == 0, "Cooldown did not hold")

-- Review #1: the guild's OWN faction sees its kills. A Horde client counting a
-- Horde raid prints nothing but sends the GW to the other faction.
reset()
raid("", 0, "Horde Band", "Horde")
assert(#printed == 0, "Own faction raid was printed locally")
assert(#timers == 1, "Own faction raid was not queued for the enemy")
flush()
assert(#sent == 1 and sent[1][3]:find("^1:Horde Band:H:20:5:"), tostring(sent[1] and sent[1][3]))
-- Same guild name in both factions is tracked separately.
reset()
-- 10 Horde kills + 10 Alliance kills would reach 20 only if merged.
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Horde", "Twin", 1, "", EPOCH) end
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Horde", "Twin", 2, "", EPOCH) end
for m = 1, 5 do GKA:OnLiveKill("Other" .. m, "Alliance", "Twin", 1, "", EPOCH) end
for m = 1, 5 do GKA:OnLiveKill("Other" .. m, "Alliance", "Twin", 2, "", EPOCH) end
assert(#timers == 0 and #printed == 0, "Guilds of both factions were merged under one name")

-- Own kills feed the same counter (Sync:BroadcastKill hook).
-- (source checks need io, available under the CI Lua 5.1, not under fengari)
local srcFile = io and io.open and io.open("Sync.lua")
local src = srcFile and srcFile:read("*a")
if srcFile then srcFile:close() end
assert(not src or src:find("GuildKillAlert:OnLiveKill(playerName, faction, guildTag,", 1, true),
    "Own kills are not counted for the local guild")

-- Review #4: a baseline older than the 5-minute window is not a datable start.
reset()
for m = 1, 5 do kill(NAMES[m], 1) end
clock = clock + 301
for m = 1, 5 do kill(NAMES[m], 5) end
assert(alerts() == 0, "Kills older than 5 min were counted as recent")

-- Review #3: a new score week restarts baselines instead of blocking on old totals.
reset()
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Empire", 100, "", EPOCH) end
clock = clock + 10
local NEXT = EPOCH + 7 * 86400
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Empire", 1, "", NEXT) end
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Empire", 3, "", NEXT) end
assert(alerts() == 1, "Weekly reset blocked the detector")
-- A late or duplicate copy does not refresh the baseline's age: 5 + 20 kills would
-- alert if the copies at +200 s had kept the base alive until +350 s.
reset()
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Empire", 10, "", EPOCH) end
clock = clock + 200
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Empire", 9, "", EPOCH) end
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Empire", 10, "", EPOCH) end
clock = clock + 150
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Empire", 14, "", EPOCH) end
assert(alerts() == 0, "Duplicate copies kept an expired baseline alive")

-- Review #7: no guild in the K means no attribution, even with a cached guild.
reset()
Overlord.Leaderboard.playerInfo = Overlord.Leaderboard.playerInfo or {}
for m = 1, 5 do Overlord.Leaderboard.playerInfo[NAMES[m]] = { guild = "FormerGuild" } end
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "", 1, "", EPOCH) end
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", nil, 4, "", EPOCH) end
assert(alerts("FormerGuild") == 0 and #timers == 0, "Cached guild was attributed a live raid")

-- Layer: majority of the guild's killers wins; none known -> no number.
reset()
shards = { [NAMES[1]] = 143, [NAMES[2]] = 88, [NAMES[3]] = 88 }
raid()
assert(printed[1] and printed[1]:find("(#88)", 1, true), tostring(printed[1]))
reset()
shards = {}
raid()
assert(printed[1] and printed[1]:find("members!", 1, true), "Unknown layer shown: " .. tostring(printed[1]))
shards = { [NAMES[1]] = 143 }

-- Location: "#uiMapID" in the K, sub-maps climb to their zone, majority wins.
local maps = {
    [1417] = { name = "Arathi Highlands", mapType = 3, parentMapID = 1414 },
    [1414] = { name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
    [1420] = { name = "Tirisfal Glades", mapType = 3, parentMapID = 1414 },
    [9001] = { name = "Some Cave", mapType = 5, parentMapID = 1417 },
}
C_Map.GetMapInfo = function(id) return maps[id] end
local bestMap = 9001
C_Map.GetBestMapForUnit = function() return bestMap end
assert(GKA:GetLocalMapRef() == "#1417", "Sub-map did not climb to its zone")
bestMap = 1414
assert(GKA:GetLocalMapRef() == nil, "Continent was used as a kill location")
reset()
kill(NAMES[1], 30, "#1420")
raid("#9001", 30)
assert(alerts() == 1, "Located raid did not alert")
assert(printed[1]:find("in Arathi Highlands (#143)!", 1, true), printed[1])
flush()
assert(sent[1][3]:find(":#9001:143:", 1, true), sent[1][3])

-- Another detector's GW arriving during our delay cancels our own send.
reset()
raid()
assert(alerts() == 1 and #timers == 1)
assert(not GKA:OnReceiveNetworkAlert(gw("Empire", "Alliance", 21, 5, "", 143), "Other Tester", "BETA"),
    "Duplicate GW printed after local detection")
flush()
assert(alerts() == 1 and #sent == 0, "Detector still sent after another GW arrived")

-- Review #5: turning the option off cancels an already scheduled send.
reset()
raid()
assert(#timers == 1)
GKA:SetEnabled(false)
flush()
assert(#sent == 0, "A scheduled GW left after the option was disabled")
GKA:ResetDefaults(); GKA:SetAllyEnabled(false)

-- Without the relay (not loaded yet): direct group + channel copies, still one alert.
reset()
local savedNet = Overlord.Relay
Overlord.Relay = nil
raid()
flush()
assert(#sent == 2 and sent[1][1] == "group" and sent[2][1] == "channel", "Fallback fan-out wrong")
Overlord.Relay = savedNet

-- Disabled: nothing printed, nothing sent.
reset()
GKA:SetEnabled(false)
raid()
flush()
assert(alerts() == 0 and #sent == 0, "Disabled alert still printed or sent")
GKA:ResetDefaults(); GKA:SetAllyEnabled(false)
assert(GKA:IsEnabled())

-- Receiving a GW prints the very same text, once per guild per 10 minutes.
reset()
local iron = gw("Iron Watch", "Alliance", 27, 6, "#1417", 55)
assert(GKA:OnReceiveNetworkAlert(iron, "Relay Tester", "BETA"), "Valid GW rejected")
assert(printed[1] == "|cFFFF4444[Overlord]|r "
    .. GKA:BuildAlertText("Iron Watch", "Alliance", 27, 6, "#1417", 55), tostring(printed[1]))
assert(printed[1]:find("27+ HK by 6+ members in Arathi Highlands (#55)!", 1, true), printed[1])
assert(not GKA:OnReceiveNetworkAlert(iron, "Other Tester", "CHANNEL"), "Duplicate GW printed twice")
assert(#sent == 0, "Receiver re-broadcast the GW")

-- Review #2: a GW never masks a later corroborated local detection, and a GW that
-- did not come through a relay transport is ignored.
reset()
assert(not GKA:OnReceiveNetworkAlert(gw("Empire", "Alliance", 20, 5, "", nil), "Forger", "WHISPER"),
    "Whispered GW was accepted")
assert(GKA:OnReceiveNetworkAlert(gw("Empire", "Alliance", 20, 5, "", nil), "Forger", "BETA"))
raid()
assert(alerts() == 2, "A received GW masked the local detection")
flush()
assert(#sent == 0, "Local detection re-sent a GW that already circulated")

-- 1.7.1 security: whitespace variants of one name never get a fresh 10-minute slot.
reset()
for _, variant in ipairs({ " Empire", "Empire ", "Em  pire" }) do
    local payload = "1:" .. variant .. ":A:20:5::" .. ":" .. tostring(GetServerTime())
    assert(not GKA:OnReceiveNetworkAlert(payload, "Forger", "BETA"),
        "Padded guild name '" .. variant .. "' was accepted")
end
assert(GKA:OnReceiveNetworkAlert(gw("Iron Wolves", "Alliance", 20, 5, "", nil), "Relay Tester", "BETA"),
    "A real two-word guild name was refused")

-- Own-faction GW: not printed, but cancels our pending send for that guild.
reset()
raid("", 0, "Horde Band", "Horde")
assert(#timers == 1)
assert(not GKA:OnReceiveNetworkAlert(gw("Horde Band", "Horde", 22, 5, "", nil), "x", "BETA"))
flush()
assert(#printed == 0 and #sent == 0, "Own-faction GW was printed or duplicated")

-- A forged own-faction GW that does not cover our observation (other place, or
-- fewer kills) never silences the real detection, before or after it.
reset()
assert(not GKA:OnReceiveNetworkAlert(gw("Horde Band", "Horde", 99, 9, "#1420", nil), "Forger", "CHANNEL"))
raid("", 0, "Horde Band", "Horde")
assert(#timers == 1, "Forged GW elsewhere suppressed the real detection")
flush()
assert(#sent == 1, "Forged GW elsewhere suppressed the real GW")
reset()
raid("", 0, "Horde Band", "Horde")
assert(not GKA:OnReceiveNetworkAlert(gw("Horde Band", "Horde", 20, 5, "#1420", nil), "Forger", "CHANNEL"))
flush()
assert(#sent == 1, "Forged GW during the delay cancelled the real GW")

-- Review follow-up: a guild change never credits the total jump to the new guild.
reset()
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "Old Guild", 1, "", EPOCH) end
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "", 4, "", EPOCH) end
for m = 1, 5 do GKA:OnLiveKill(NAMES[m], "Alliance", "New Guild", 5, "", EPOCH) end
assert(alerts("New Guild") == 0 and #timers == 0, "Old kills were credited to the new guild")

-- Rejected GW: below threshold, stale, malformed.
reset()
assert(not GKA:OnReceiveNetworkAlert(gw("Tiny", "Alliance", 5, 2, "", nil), "x", "BETA"), "Below-threshold GW accepted")
assert(not GKA:OnReceiveNetworkAlert(gw("Old Guard", "Alliance", 30, 6, "", nil, serverClock - 301), "x", "BETA"),
    "Stale GW accepted")
assert(not GKA:OnReceiveNetworkAlert("1:Bad|Guild:A:30:6:::" .. serverClock, "x", "BETA"), "Invalid guild accepted")
assert(not GKA:OnReceiveNetworkAlert("1:Guild:A:30:6:bad zone!::" .. serverClock, "x", "BETA"), "Invalid zone accepted")

-- A /reload does not replay a GW already shown during its validity window.
reset()
local once = gw("Reload Guild", "Alliance", 25, 5, "", nil)
assert(GKA:OnReceiveNetworkAlert(once, "x", "BETA"))
GKA:_ResetState(true)
assert(not GKA:OnReceiveNetworkAlert(once, "x", "BETA"), "GW replayed after /reload")
-- The 10-minute cooldown survives the reload for a NEW GW about the same guild too.
serverClock = serverClock + 60
assert(not GKA:OnReceiveNetworkAlert(gw("Reload Guild", "Alliance", 26, 5, "", nil), "x", "BETA"),
    "New GW for the same guild shown right after /reload")
serverClock = serverClock + 541
assert(GKA:OnReceiveNetworkAlert(gw("Reload Guild", "Alliance", 26, 5, "", nil), "x", "BETA"),
    "Persisted cooldown never expired")

-- A guild in cooldown survives the eviction of 128 inactive guilds.
reset()
assert(GKA:OnReceiveNetworkAlert(gw("Kept Guild", "Alliance", 25, 5, "", nil), "x", "BETA"))
OverlordDB.guildKillAlertSeen = nil -- only the in-memory cooldown is under test here
for i = 1, 130 do GKA:OnLiveKill("Filler" .. i, "Alliance", "Filler" .. i, 1, "", EPOCH) end
clock = clock + 61
assert(not GKA:OnReceiveNetworkAlert(gw("Kept Guild", "Alliance", 30, 6, "", nil, serverClock - 1), "x", "BETA"),
    "Cooldown lost to guild eviction")

-- Flood guard: at most 4 network alerts per minute.
reset()
for i = 1, 6 do
    GKA:OnReceiveNetworkAlert(gw("Flood" .. string.char(64 + i), "Alliance", 30, 6, "", nil), "x", "BETA")
end
assert(#printed == 4, "Network alert flood was not capped: " .. #printed)
clock = clock + 61
assert(GKA:OnReceiveNetworkAlert(gw("Later Guild", "Alliance", 30, 6, "", nil), "x", "BETA"))

-- /ov guildkills test prints one alert through the real path, sends nothing,
-- even when disabled, and restores the exact setting (nil stays nil).
reset()
OverlordDB.config.guildKillAlertEnabled = nil
local tagFn = Overlord.Sync.GetShardAlertTagForPlayer
GKA:HandleCommand({ "guildkills", "test" })
assert(#printed == 1 and printed[1]:find("Empire [TEST]", 1, true)
    and printed[1]:find("20+ HK by 5+ members in Arathi Highlands (#143)!", 1, true)
    and not printed[1]:find("Sim", 1, true), tostring(printed[1]))
assert(#sent == 0 and #timers == 0, "Simulation sent network traffic")
assert(OverlordDB.config.guildKillAlertEnabled == nil, "Simulation changed the default setting")
assert(Overlord.Sync.GetShardAlertTagForPlayer == tagFn)
GKA:SetEnabled(false)
GKA:HandleCommand({ "guildkills", "test" })
assert(#printed == 2 and OverlordDB.config.guildKillAlertEnabled == false, "Simulation did not restore false")
GKA:ResetDefaults(); GKA:SetAllyEnabled(false)

-- Dispatch: GW reaches the module from addon messages (with their channel) and Battle.net.
reset()
Overlord.Sync.SenderBurstShouldDrop = function() return false end
Overlord.Sync:DispatchBNetMessage("GW", gw("Bnet Guild", "Alliance", 20, 5, "", nil), "BNet-1", 1)
assert(alerts("Bnet Guild") == 1, "BNet GW was not dispatched")
local receiveAlert, split = GKA.OnReceiveNetworkAlert, strsplit
local dispatched
GKA.OnReceiveNetworkAlert = function(_, payload, sender, channel)
    dispatched = { payload, sender, channel }
end
-- The fixture's general-purpose splitter ignores WoW's result limit. Use the
-- actual two-field message contract here so a full GW reaches the dispatcher.
strsplit = function(sep, value, limit)
    if limit == 2 then
        local at = value:find(sep, 1, true)
        if at then return value:sub(1, at - 1), value:sub(at + #sep) end
        return value
    end
    return split(sep, value, limit)
end
local channelPayload = gw("Channel Guild", "Alliance", 20, 5, "", nil)
Overlord.Sync:OnAddonMessage("OverlordF", "GW:" .. channelPayload, "CHANNEL", "Channel Tester")
GKA.OnReceiveNetworkAlert, strsplit = receiveAlert, split
assert(dispatched and dispatched[1] == channelPayload
    and dispatched[2] == "Channel Tester" and dispatched[3] == "CHANNEL",
    "Addon-message GW dispatch lost its payload, sender or channel")

-- 1.7.1: allied guild rampages. The guild's own faction sees it too, in green, with
-- its own option (on by default), once per guild per 30 min; nothing more is sent.
do
    local GREEN = "|cFF33FF66"
    local function greens() local n = 0; for _, t in ipairs(printed) do if t:find(GREEN, 1, true) then n = n + 1 end end; return n end
    OverlordDB.config.guildKillAllyAlertEnabled = nil
    assert(GKA:IsAllyEnabled(), "allied rampages are not on by default")
    -- Local detection of a Horde guild by this Horde client: one green line, and the GW
    -- for the Alliance is still queued exactly as before.
    reset()
    raid("", 0, "Horde Band", "Horde")
    assert(#printed == 1 and greens() == 1 and printed[1]:find("20+ HK by 5+ members", 1, true),
        "own-faction rampage not shown in green: " .. tostring(printed[1]))
    assert(#timers == 1, "the GW for the enemy faction was not queued")
    flush()
    assert(#sent == 1 and sent[1][2] == "GW", "the allied line changed what is sent")
    -- The same guild again inside 10 min: nothing more.
    clock = clock + 400
    raid("", 100, "Horde Band", "Horde")
    assert(greens() == 1, "an allied rampage was shown twice within 10 minutes")
    -- Allies wait 30 min (enemies 10): a fresh rampage 15 min later stays quiet, one
    -- after 30 min shows again.
    clock, serverClock = clock + 500, serverClock + 900
    raid("", 200, "Horde Band", "Horde")
    assert(greens() == 1, "an allied rampage was shown again after 15 minutes")
    clock, serverClock = clock + 1000, serverClock + 1000
    raid("", 300, "Horde Band", "Horde")
    assert(greens() == 2, "an allied rampage was not shown again after 30 minutes")
    -- A GW for another Horde guild (detected by someone else): shown once, in green.
    reset()
    assert(GKA:OnReceiveNetworkAlert(gw("Horde Pack", "Horde", 25, 6, "", nil), "Horde Friend", "CHANNEL"),
        "an allied GW was not shown")
    assert(greens() == 1 and printed[1]:find("25+ HK by 6+ members", 1, true), tostring(printed[1]))
    assert(not GKA:OnReceiveNetworkAlert(gw("Horde Pack", "Horde", 30, 7, "", nil), "Horde Friend", "CHANNEL"),
        "an allied GW was shown twice")
    -- After a /reload the 10 minutes still hold.
    GKA:_ResetState(true)
    printed = {}
    assert(not GKA:OnReceiveNetworkAlert(gw("Horde Pack", "Horde", 30, 7, "", nil), "Horde Friend", "CHANNEL"),
        "an allied GW was shown again after a reload")
    -- Option off: no green line, but the GW for the enemy is still queued.
    GKA:SetAllyEnabled(false)
    reset()
    raid("", 0, "Horde Band", "Horde")
    assert(#printed == 0 and #timers == 1, "allied option off still printed, or stopped the GW")
    assert(not GKA:OnReceiveNetworkAlert(gw("Horde Crew", "Horde", 25, 6, "", nil), "Horde Friend", "CHANNEL"),
        "an allied GW was shown with the option off")
    -- Enemy alerts off, allied on: the green line shows, nothing is sent (as before when off).
    GKA:SetAllyEnabled(true)
    GKA:SetEnabled(false)
    reset()
    raid("", 0, "Horde Band", "Horde")
    assert(greens() == 1, "allied line missing with enemy alerts off")
    flush()
    assert(#sent == 0, "a GW was sent with enemy alerts off")
    assert(not GKA:OnReceiveNetworkAlert(gw("Empire", "Alliance", 25, 6, "", nil), "x", "CHANNEL"),
        "an enemy GW was shown with enemy alerts off")
    GKA:SetEnabled(true)
    -- Enemy alerts are unchanged: red line for the Alliance guild.
    reset()
    raid()
    assert(alerts() == 1 and greens() == 0 and printed[1]:find("|cFFFF4444", 1, true), "enemy alert changed")
    GKA:SetAllyEnabled(false)
end

-- Launch scale: a guild's previous totals survive 600 other killers in between, so
-- each K still counts its real delta (at 512 they were evicted and counted 1 each).
do
    reset()
    for m = 1, 5 do kill(NAMES[m], 1, "", "Empire") end
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 1, 600 do
        local who = "Bulk" .. letters:sub(i % 26 + 1, i % 26 + 1)
            .. letters:sub(math.floor(i / 26) % 26 + 1, math.floor(i / 26) % 26 + 1) .. " Fighter"
        kill(who, 1, "", "Crowd " .. letters:sub(i % 26 + 1, i % 26 + 1))
    end
    for m = 1, 5 do kill(NAMES[m], 4, "", "Empire") end
    assert(alerts("Empire") == 1, "A guild's kill deltas were lost among many other killers")
    -- Past the cap: bounded, counter exact, the order never grows without bound.
    for i = 1, 4300 do
        local a, b, c = i % 26, math.floor(i / 26) % 26, math.floor(i / 676) % 26
        local who = "Cap" .. letters:sub(a + 1, a + 1) .. letters:sub(b + 1, b + 1)
            .. letters:sub(c + 1, c + 1) .. " Fighter"
        clock = clock + 400 -- each baseline is outside its window by the next insert
        kill(who, 1, "", "Crowd")
    end
    local counted, live, ordered = GKA:_TrackedPlayers()
    assert(counted >= 4000, "Fixture kills were not tracked: " .. counted)
    assert(counted == live and live <= 4096 and ordered <= 2 * 4096 + 1,
        "Player tracking unbounded or miscounted: " .. counted .. "/" .. live .. "/" .. ordered)
end

Overlord.Sync.SendToChannel, Overlord.Sync.SendToGroup, Overlord.Sync.BroadcastToRelay =
    realChannel, realGroup, realCommunity
Overlord.Relay, Overlord.RelayEnabled = realBeta, realBetaEnabled
print("Forever guild kill alert: both-faction detection, own kills, epoch, window, relay GW, provenance, dedup, reload, eviction, simulation, allied rampages OK")

-- Player feedback (2026-10-02): the guild carries its own faction crest instead of
-- "(the Horde)", and English reads "in <zone>".
local tagged = GKA:BuildAlertText("Kor Kron Enforcers", "Horde", 21, 6, nil, nil)
assert(tagged:find("<Kor Kron Enforcers> |TInterface\\Timer\\Horde-Logo:18:18|t: 21+ HK by 6+ members!", 1, true), tagged)
assert(not tagged:find("(", 1, true), "Faction label still in brackets: " .. tagged)
