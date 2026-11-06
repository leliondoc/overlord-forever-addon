-- 2.2.0: the channel's member list as a directory of catch-up partners (SyncDirectory.lua).
-- Real relay, real guild lane, real directory, real ranking rounds and map rounds: only the
-- game's channel list, member list, selection and SendAddonMessage are stubs.
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
local s = Overlord.Sync
local clock = 1000
function GetTime() return clock end
function GetServerTime() return 1790018000 end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn, delay = delay } end,
    NewTicker = function() return {} end }
local combat = false
function InCombatLockdown() return combat end
assert(loadfile("SyncHistoryCatchup.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()
assert(loadfile("SyncRelay.lua"))()
assert(loadfile("SyncGuild.lua"))()
assert(loadfile("SyncDirectory.lua"))()
local net, lane, dir = Overlord.Relay, Overlord.GuildLane, Overlord.ChannelDirectory
assert(dir, "SyncDirectory.lua did not load")
net.BridgeChannelHold = { 0, 0 }
Overlord.RelayEnabled = true
Overlord.PlayerFaction = "Alliance"
local instanced, inGuild, grouped = false, false, false
function IsInInstance() return instanced end
function IsInGuild() return inGuild end
function IsInGroup() return grouped end
function IsInRaid() return false end
s.GetBetaBNetTargets = function() return {} end
local me = s:GetPlayerFullName()
assert(type(me) == "string" and me:find(" ", 1, true), "fixture: a Forever name is expected")
local PREFIX = "OverlordF"
local CHANNEL = s:GetChannelBaseName()

local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        clock = math.max(clock, timer.at)
        timer.fn()
    end
    clock = stop
end

local sent = {}
C_ChatInfo = C_ChatInfo or {}
C_ChatInfo.SendAddonMessage = function(_, msg, chatType, target)
    sent[#sent + 1] = { msg = msg, chatType = chatType, target = target, at = clock }
    return 0
end
-- What a relay fragment carries: target, path, kind.
local function fields(msg)
    local target, path, kind = msg:match("^BF:[^:]+:%d+:%d+:[^|]*|[^|]*|[^|]*|([^|]*)|([^|]*)|([^|]*)|")
    return target, path, kind
end
local function whispers(kind, target)
    local out = {}
    for _, row in ipairs(sent) do
        local to, _, what = fields(row.msg)
        if row.chatType == "WHISPER" and what == kind and (not target or row.target == target) then
            out[#out + 1] = { row = row, target = to }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The game's channel list, member list and selection
-- ---------------------------------------------------------------------------

local display, selections, selected, loaded, fetchWorks, zeroCount, otherCustom = {}, {}, nil, false, true, false, false
local members = { "Alpha Lune", "Brume Vent", me, "Cendre Roc", "Dune Sable", "Zed", "Alpha Lune", "Ecume Gris" }
local function setDisplay()
    display = { { name = "Groupe", header = true, category = "CHANNEL_CATEGORY_GROUP" } }
    if grouped then display[#display + 1] = { name = "Groupe", count = 2, category = "CHANNEL_CATEGORY_GROUP" } end
    display[#display + 1] = { name = "Monde", header = true, category = "CHANNEL_CATEGORY_WORLD" }
    display[#display + 1] = { name = "General - Elwynn", count = 40, category = "CHANNEL_CATEGORY_WORLD", world = true }
    display[#display + 1] = { name = "Trade", count = 300, category = "CHANNEL_CATEGORY_WORLD", world = true }
    display[#display + 1] = { name = "Custom", header = true, category = "CHANNEL_CATEGORY_CUSTOM" }
    if otherCustom then display[#display + 1] = { name = "Autre", category = "CHANNEL_CATEGORY_CUSTOM" } end
    display[#display + 1] = { name = CHANNEL, ours = true, category = "CHANNEL_CATEGORY_CUSTOM" }
    -- (As in game: an empty header for Discord channels.)
    display[#display + 1] = { name = "", header = true, category = "CHANNEL_CATEGORY_DISCORD" }
end
local function ourIndex()
    for i, entry in ipairs(display) do if entry.ours then return i end end
end
function GetNumDisplayChannels() return #display end
function GetChannelDisplayInfo(i)
    local entry = display[i]
    if not entry then return nil end
    local count = entry.count
    if entry.ours then count = loaded and #members or (zeroCount and 0 or nil) end
    return entry.name, entry.header == true, false, i, count, true, entry.category, 0
end
-- As in game: selecting our channel when it was not the selected one fetches its list (2 s);
-- selecting the one already selected does nothing, nor does a header (measured 2026-11-06).
function SetSelectedDisplayChannel(i)
    selections[#selections + 1] = i
    local entry = display[i]
    if not entry or entry.header or not fetchWorks then return end
    local changed = selected ~= i
    selected = i
    if changed and entry and entry.ours then C_Timer.After(2, function() loaded = true end) end
end
C_ChatInfo.GetChannelRosterInfo = function(i, k)
    local entry = display[i]
    if not (entry and entry.ours and loaded) then return nil end
    local name = members[k]
    if name then return name, false, false, "Player-6940-" .. k end
end
local function selectedWorld()
    for _, i in ipairs(selections) do
        if display[i] and display[i].world then return true end
    end
    return false
end
local function selectedHeader()
    for _, i in ipairs(selections) do
        if display[i] and display[i].header then return true end
    end
    return false
end

-- Somebody's relay packet, whispered to us by its author (or by path's last node). Every player
-- keeps one relay session ("<session>-<serial>" ids) until newSession (a /reload, a relog).
local serial, sessions = 0, {}
local function newSession(origin)
    serial = serial + 1
    sessions[origin] = "s" .. serial
end
local function whisperFrom(origin, kind, payload, target, path, chatType)
    if not sessions[origin] then newSession(origin) end
    serial = serial + 1
    local id = sessions[origin] .. "-" .. serial
    local wire = table.concat({ Overlord.RealmPools:GetOverlordPoolTag(), id, tostring(GetServerTime()),
        target or me, path or origin, kind, payload }, "|")
    local last = path and path:match("[^,]+$") or origin
    s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire, chatType or "WHISPER", last)
end
local function presence()
    return tostring(Overlord.Version) .. "~t0~y" .. net.LocalMapLayout() .. "~m0~o0~z0000000~l9~ld~lr~lp6"
end

local function clearRoutes()
    for key in pairs(net.peers) do net.peers[key] = nil end
end
local function resetDirectory()
    dir.generation = dir.generation + 1
    dir.names, dir.partners, dir.partnerCount, dir.failedMethods, dir.provenMethods = {}, {}, 0, {}, {}
    dir.replies = { at = -1000, count = 0 }
    dir.fetching, dir.fetchAt, dir.readAt, dir.nextReadAt, dir.nextGreetAt, dir.state = nil, nil, nil, nil, nil, nil
    dir.forgottenAt = nil
    for key in pairs(dir.stats) do dir.stats[key] = 0 end
end
-- A fresh world: our channel joined, its list not fetched yet, still "selected" from before the
-- relog (the case measured in game).
local function fresh(opts)
    opts = opts or {}
    advance(600)
    grouped, inGuild, instanced, combat = opts.grouped == true, false, false, false
    Overlord.InstanceSuspended = false
    fetchWorks, zeroCount, otherCustom = opts.fetchWorks ~= false, opts.zero == true, opts.custom == true
    setDisplay()
    selections, loaded, selected = {}, false, ourIndex()
    s._channelRefusedAt, s._channelRefusedWhy = nil, nil
    if not opts.open then s._channelRefusedAt, s._channelRefusedWhy = clock, "test" end
    s._channelSilence, s._channelHeardAt = nil, nil
    _G.ChannelFrame = nil
    clearRoutes()
    resetDirectory()
    dir:Arm(dir.TICK_SEC)
    sent = {}
end

-- ---------------------------------------------------------------------------
-- 1. Nothing while the channel carries
-- ---------------------------------------------------------------------------

net:Start()
assert(dir.started, "the relay starts the directory")
fresh({ open = true })
advance(300)
assert(not dir:IsActive(), "inactive while the channel carries (closed " .. tostring(s:IsChannelClosed())
    .. ", silent " .. tostring(s:IsChannelSilent()) .. ", joined " .. tostring(s:GetJoinedChannelId()) .. ")")
assert(#selections == 0, "no selection while the channel carries")
assert(#whispers("NH") == 0, "no greeting while the channel carries")

-- ---------------------------------------------------------------------------
-- 2. The list, fetched through the group's channel, read without us, bad names and doubles
-- ---------------------------------------------------------------------------

fresh({ grouped = true })
advance(dir.TICK_SEC + 1)
assert(dir:IsActive(), "active once the channel is refused")
assert(#selections == 2 and display[selections[1]].category == "CHANNEL_CATEGORY_GROUP"
    and not display[selections[1]].header and selections[2] == ourIndex(),
    "the group's channel, then ours: " .. table.concat(selections, ","))
advance(dir.READ_POLLS[1])
assert(#dir.names == 5, "five names read, got " .. #dir.names)
for _, name in ipairs(dir.names) do
    assert(name ~= me and name ~= "Zed", "neither us nor a bad name: " .. name)
end
assert(dir.provenMethods.group, "the group method is proven by a list that was not there")
assert(not selectedWorld(), "a world channel is never selected")
-- Within STALE_SEC the list is read again without any selection.
local before = #selections
advance(dir.REFRESH_SEC + dir.TICK_SEC)
assert(#selections == before, "a fresh list is read again without selecting")
assert(dir.stats.reads == 2, "read twice, got " .. dir.stats.reads)

-- ---------------------------------------------------------------------------
-- 3. Without a group: another channel (a custom one before a world one), never a header
-- ---------------------------------------------------------------------------

fresh()
advance(dir.TICK_SEC + dir.READ_POLLS[1] + 1)
assert(display[selections[1]] and display[selections[1]].world and selections[2] == ourIndex(),
    "a world channel, then ours, when not in a group: " .. table.concat(selections, ","))
assert(#dir.names == 5 and dir.provenMethods.world, "the world method fetched the list")
assert(not selectedHeader(), "a header is never selected")
fresh({ custom = true })
advance(dir.TICK_SEC + dir.READ_POLLS[1] + 1)
assert(display[selections[1]] and display[selections[1]].name == "Autre", "a custom channel before a world one")
assert(#dir.names == 5 and dir.provenMethods.custom, "read through the custom channel")
-- A list not there yet may also come as a count of 0.
fresh({ zero = true })
advance(dir.TICK_SEC + dir.READ_POLLS[1] + 1)
assert(#dir.names == 5 and dir.provenMethods.world, "a count of 0 is no list: the fetch that brought one proves it")

fresh({ fetchWorks = false })
advance(dir.TICK_SEC + dir.READ_POLLS[2] + 1)
assert(#dir.names == 0 and dir.failedMethods.world, "a selection that does nothing: no list, method set aside")
assert(dir.state == "member list not loaded", "the state says so: " .. tostring(dir.state))
assert(not selectedHeader(), "still no header")
before = #selections
advance(dir.RETRY_SEC * 5)
assert(#selections == before, "a failed method is not tried again before STALE_SEC")
assert(#whispers("NH") == 0, "no greeting without a list")
-- The player opens the game's window on our channel: the list is there and read, no selection.
loaded = true
advance(dir.RETRY_SEC + dir.TICK_SEC)
assert(#dir.names == 5 and #selections == before, "a list the game holds is read as it is")

-- Our channel kept by the game, put aside by the server: out of the display list, flagged
-- disabled in GetChannelList (measured 2026-11-06). Said as such, nothing selected, and read
-- again once the server gives it back.
fresh()
local keptDisplay = display
display = {}
for _, entry in ipairs(keptDisplay) do if not entry.ours then display[#display + 1] = entry end end
function GetChannelList() return 1, "General", false, 5, CHANNEL, true end
advance(dir.TICK_SEC + 1)
assert(dir.suspended and dir.state == "channel suspended by the game for this session", tostring(dir.state))
assert(#selections == 0, "nothing selected while our channel is suspended")
assert(select(3, lane:Describe()):find("^channel suspended by the game; data goes through"), select(3, lane:Describe()))
display = keptDisplay
function GetChannelList() return 1, "General", false, 5, CHANNEL, false end
advance(dir.RETRY_SEC + dir.TICK_SEC + dir.READ_POLLS[1] + 1)
assert(not dir.suspended and #dir.names == 5, "read once the server gives the channel back: " .. tostring(dir.state))
GetChannelList = nil

-- ---------------------------------------------------------------------------
-- 4. Never while the game's window is open, nor in combat, nor in an instance
-- ---------------------------------------------------------------------------

fresh({ grouped = true })
_G.ChannelFrame = { IsShown = function() return true end }
advance(dir.TICK_SEC * 3)
assert(#selections == 0, "no selection while the channel window is open")
_G.ChannelFrame = { IsShown = function() return false end }
combat = true
advance(dir.RETRY_SEC + dir.TICK_SEC)
assert(#selections == 0, "no selection in combat")
combat = false
instanced = true
Overlord.InstanceSuspended = true
s:OnNetworkSuspend()
advance(dir.RETRY_SEC * 3)
assert(#selections == 0 and #whispers("NH") == 0, "nothing in an instance")
instanced = false
Overlord.InstanceSuspended = false
s:OnNetworkResume()
advance(dir.TICK_SEC * 2 + dir.READ_POLLS[1] + 1)
assert(#dir.names == 5, "back after the instance")

-- ---------------------------------------------------------------------------
-- 5. A greeting: our presence by whisper, a route that makes no neighbour
-- ---------------------------------------------------------------------------

fresh({ grouped = true })
local directBefore = net:CountDirectPeers()
advance(dir.TICK_SEC + dir.READ_POLLS[1] + dir.TICK_SEC + 2)
local greetings = whispers("NH")
assert(#greetings == 1, "one greeting, got " .. #greetings)
local partner = greetings[1].row.target
assert(greetings[1].target == partner, "the presence is addressed to the player it is whispered to")
assert(partner ~= me and dir.partners[partner:lower()], "a listed player is greeted: " .. tostring(partner))
assert(net.peers[partner:lower()] and net.peers[partner:lower()].directory, "a route for that whisper")
assert(not net:IsPeer(partner) and not net:IsDirectPeer(partner), "that route makes no neighbour")
for _, name in ipairs(net:GetDirectPeers()) do assert(name ~= partner, "not in the neighbour list") end
assert(net:CountDirectPeers() == directBefore, "not counted")
assert(not dir:FastRounds(), "no closer rounds before an answer")
advance(5)

-- ---------------------------------------------------------------------------
-- 6. The answer: a neighbour now, no answer back, closer rounds
-- ---------------------------------------------------------------------------

local repliesBefore = dir.stats.replies
whisperFrom(partner, "NH", presence())
assert(net:IsDirectPeer(partner) and not net.peers[partner:lower()].directory, "the answer makes a neighbour")
assert(dir.stats.answered == 1, "counted as an answer")
advance(5)
assert(#whispers("NH", partner) == 1 and dir.stats.replies == repliesBefore, "our greeting is not answered back")
assert(dir:FastRounds(), "closer ranking rounds while a partner answers")
-- The map rounds keep their pace.
local savedTimers = timers
timers = {}
s._mapCatchupArmed = nil
assert(s:SchedulePeriodicMapCatchup(), "a map round is armed")
assert(#timers == 1 and timers[1].delay >= s.BETA_MAP_CATCHUP_INTERVAL
    and timers[1].delay <= s.BETA_MAP_CATCHUP_INTERVAL + s.BETA_MAP_CATCHUP_JITTER,
    "map rounds keep their pace: " .. tostring(timers[1] and timers[1].delay))
timers, s._mapCatchupArmed = savedTimers, nil
assert(not s:IsOutdatedMapPeer(partner), "its presence was heard: its map can be taken")
assert(select(2, lane:Describe()):find("exchanging with you", 1, true), "the panel names the member list: "
    .. select(2, lane:Describe()))
-- One greeting a minute at most.
advance(dir.GREET_SEC - 20)
assert(#whispers("NH") == 1, "no second greeting within GREET_SEC")
-- The partner reloads (a new relay session) and greets us again, well within PRESENCE_SEC of
-- our presence: answered, since the new session never got it. Once per PRESENCE_SEC.
local repliesNow = dir.stats.replies
newSession(partner)
whisperFrom(partner, "NH", presence())
advance(1)
assert(dir.stats.replies == repliesNow + 1 and #whispers("NH", partner) == 2, "a new session is answered")
newSession(partner)
whisperFrom(partner, "NH", presence())
advance(1)
assert(dir.stats.replies == repliesNow + 1 and #whispers("NH", partner) == 2, "one renewal per PRESENCE_SEC")
whisperFrom(partner, "NH", presence())
advance(1)
assert(#whispers("NH", partner) == 2, "the same session is not answered again")

-- ---------------------------------------------------------------------------
-- 7. Silence: left alone for SILENT_SEC
-- ---------------------------------------------------------------------------

advance(dir.GREET_SEC + dir.GREET_JITTER + dir.TICK_SEC)
local second
for _, g in ipairs(whispers("NH")) do if g.row.target ~= partner then second = g.row.target end end
assert(second, "a second player greeted")
advance(dir.ANSWER_WAIT + 1)
local row = dir.partners[second:lower()]
assert(row.silentUntil and row.silentUntil > clock, "a silent player is left alone")
-- (Greetings are jittered: a third player may have been greeted, and left silent, meanwhile.)
assert(dir.stats.silent >= 1, "counted silent")
advance(dir.GREET_SEC * 6)
local again = 0
for _, g in ipairs(whispers("NH")) do if g.row.target == second then again = again + 1 end end
assert(again == 1, "not greeted again within SILENT_SEC")
for _, g in ipairs(whispers("NH")) do assert(g.row.target ~= me, "never ourselves") end

-- ---------------------------------------------------------------------------
-- 8. Somebody greets us: answered once, six a minute at most
-- ---------------------------------------------------------------------------

fresh({ grouped = true })
whisperFrom("Zora Brise", "NH", presence())
advance(3)
assert(#whispers("NH", "Zora Brise") == 1, "a greeting is answered by our presence")
assert(whispers("NH", "Zora Brise")[1].target == "Zora Brise", "addressed to that player alone")
assert(net:IsDirectPeer("Zora Brise") and dir:LiveCount() == 0 and not dir:FastRounds()
    and not dir:HasPartner(), "a player who greets us first is answered, not made a partner")
whisperFrom("Zora Brise", "NH", presence())
advance(3)
assert(#whispers("NH", "Zora Brise") == 1, "answered once per PRESENCE_SEC")
assert(dir.stats.greetedUs == 1, "one player greeted us")
local strangers = { "Abel Un", "Brice Deux", "Cyan Trois", "Dora Quatre", "Elio Cinq", "Fanny Six" }
for _, name in ipairs(strangers) do whisperFrom(name, "NH", presence()) end
advance(3)
local answered = 0
for _, name in ipairs(strangers) do answered = answered + #whispers("NH", name) end
assert(answered == 5 and dir.stats.repliesCapped == 1, "six answers a minute: " .. answered)
-- A relayed presence, a broadcast one, one over the guild: never answered. (Those who greeted
-- us are no partners of ours: the directory greets listed players meanwhile.)
whisperFrom("Gaby Sept", "NH", presence(), me, "Gaby Sept,Hugo Huit")
whisperFrom("Ivan Neuf", "NH", presence(), "*")
inGuild = true
whisperFrom("Jade Dix", "NH", presence(), me, nil, "GUILD")
inGuild = false
advance(70)
local unanswered = 0
for _, name in ipairs({ "Gaby Sept", "Hugo Huit", "Ivan Neuf", "Jade Dix" }) do
    unanswered = unanswered + #whispers("NH", name)
end
assert(unanswered == 0, "only a presence whispered to us alone by its author is answered")
assert(dir.stats.greeted >= 1, "listed players are greeted although strangers greeted us")

-- ---------------------------------------------------------------------------
-- 9. Our broadcast presence and a greeting both leave
-- ---------------------------------------------------------------------------

fresh({ grouped = true })
sent = {}
net:Broadcast("NH", tostring(Overlord.Version))
net:NoteDirectoryRoute("Kira Onze")
net:Send("NH", tostring(Overlord.Version), "Kira Onze")
advance(10)
local groupCopy = false
for _, row in ipairs(sent) do
    local target, _, kind = fields(row.msg)
    if (row.chatType == "PARTY" or row.chatType == "RAID") and kind == "NH" and target == "*" then groupCopy = true end
end
assert(groupCopy, "the broadcast presence still goes to the group")
assert(#whispers("NH", "Kira Onze") == 1, "the greeting goes too")
-- Another player's presence addressed to somebody else is never passed on.
for _, name in ipairs({ "Tara Loin", "Ugo Loin" }) do
    net.peers[name:lower()] = { name = name, at = clock, via = name, hops = 1, transport = "WHISPER" }
end
whisperFrom("Rex Douze", "NH", presence(), "Tara Loin")
whisperFrom("Rex Douze", "NH", presence(), "Ugo Loin")
advance(5)
assert(#whispers("NH", "Tara Loin") == 0 and #whispers("NH", "Ugo Loin") == 0, "a presence is never forwarded")

-- ---------------------------------------------------------------------------
-- 10. Ranking rounds: one turn of our side in two to a partner, every neighbour still asked
-- ---------------------------------------------------------------------------

local function find(fn, name, depth, seen)
    seen = seen or {}
    if seen[fn] or depth < 0 then return nil end
    seen[fn] = true
    for i = 1, 200 do
        local key, value = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then return value end
        if type(value) == "function" then
            local found = find(value, name, depth - 1, seen)
            if found then return found end
        end
    end
end
local pick = find(s.ScheduleLoginLeaderboardHistoryCatchUp, "PickDirectPeer", 4)
local arm = find(s.ScheduleLoginLeaderboardHistoryCatchUp, "ArmNextHistoryCatchup", 4)
assert(pick and arm, "PickDirectPeer and ArmNextHistoryCatchup reachable")

fresh({ grouped = true })
advance(dir.TICK_SEC + dir.READ_POLLS[1] + dir.TICK_SEC + 2)
partner = whispers("NH")[1].row.target
whisperFrom(partner, "NH", presence())
local mates = { "Mate Un", "Mate Deux", "Mate Trois" }
local function keepMates()
    for _, name in ipairs(mates) do
        net.peers[name:lower()] = { name = name, at = clock, via = name, hops = 1, transport = "GUILD" }
    end
end
keepMates()
local asked, partnerTurns = {}, 0
for r = 0, 11 do
    OverlordDB.leaderboardHistoryCatchupTargetRotation = r
    local name = pick()
    asked[name] = true
    if name == partner then partnerTurns = partnerTurns + 1 end
    if r % 2 == 1 then assert(name == partner, "odd turn " .. r .. " goes to the partner, got " .. tostring(name)) end
end
for _, name in ipairs(mates) do assert(asked[name], "every neighbour still asked: " .. name) end
assert(partnerTurns >= 6, "the partner has one turn in two")
-- With the channel back, the usual walk again.
s._channelRefusedAt = nil
OverlordDB.leaderboardHistoryCatchupTargetRotation = 1
local normal = pick()
assert(not dir:FastRounds(), "no closer rounds once the channel carries")
assert(normal ~= nil, "a neighbour is still picked")
s._channelRefusedAt = clock
-- The next v8 round in 20-40 s while partners answer (45-105 s otherwise).
timers = {}
arm(dir.LADDER_ACK_SEC, true)
assert(#timers == 1 and timers[1].delay >= 20 and timers[1].delay <= 40, "fast round in 20-40 s: " .. timers[1].delay)
timers = {}
arm(45)
assert(#timers == 1 and timers[1].delay >= 45 and timers[1].delay <= 105, "usual round: " .. timers[1].delay)
-- The end of a v8 round: closer rounds only while a partner can take one of the next turns.
-- One set aside after a silent round leaves them to the usual neighbours, at their pace.
local finish = find(s.ScheduleLoginLeaderboardHistoryCatchUp, "FinishRound", 4)
local penalties = find(s.ScheduleLoginLeaderboardHistoryCatchUp, "peerPenaltyUntil", 5)
assert(finish and penalties, "FinishRound and the penalties reachable")
local savedAck, savedStats = OverlordDB.leaderboardHistoryCatchupAck, s._leaderboardPageStats
local function nextRoundAfterV8()
    local pending = { campaignId = 0 }
    s._historyCatchupPending, s._leaderboardPageStats = pending, { protocol = 8 }
    timers = {}
    finish(pending, true)
    return timers[1] and timers[1].delay
end
keepMates()
net.peers[partner:lower()].at = clock
local delay = nextRoundAfterV8()
assert(delay and delay >= 20 and delay <= 40, "closer round with a partner ahead: " .. tostring(delay))
penalties[partner:lower()] = clock + 600
delay = nextRoundAfterV8()
assert(dir:FastRounds() and delay and delay >= 45 and delay <= 105,
    "usual pace while the only partner is set aside: " .. tostring(delay))
penalties[partner:lower()] = nil
delay = nextRoundAfterV8()
assert(delay and delay >= 20 and delay <= 40, "closer again once it is back: " .. tostring(delay))
OverlordDB.leaderboardHistoryCatchupAck, s._leaderboardPageStats = savedAck, savedStats
s._historyCatchupPending = nil
timers = {}
dir:Arm(dir.TICK_SEC)

-- ---------------------------------------------------------------------------
-- 11. Map rounds: our presence first, the request a moment later
-- ---------------------------------------------------------------------------

advance(dir.MAP_PRESENCE_SEC + 5)
keepMates()
net.peers[partner:lower()].at = clock
sent = {}
s._mapCatchupRound, s._mapAllyTurns = 0, 0
s._lastFullZaAt, s._lastOwnFullZaAt, s._lastEnemyFullZaAt = nil, nil, nil
assert(s:RunPeriodicMapCatchup(), "a map round runs")
advance(0.5)
local nh, sr = whispers("NH", partner), whispers("SR", partner)
assert(#nh == 1 and #sr == 0, "our presence first")
advance(dir.MAP_PULL_DELAY + 1)
sr = whispers("SR", partner)
assert(#sr == 1 and sr[1].row.at > nh[1].row.at, "then the map request")
assert(dir.stats.mapTurns == 1, "counted as a map round with a partner")
-- A player who greeted us first is no partner, yet hears our presence only by whisper too:
-- picked by an ordinary map round, it gets our presence first as well.
whisperFrom("Gael Premier", "NH", presence())
advance(dir.MAP_PRESENCE_SEC + 5)
for _, row in pairs(net.peers) do row.at = clock - 400 end
net.peers["gael premier"].at = clock
sent = {}
s._lastFullZaAt, s._lastOwnFullZaAt, s._lastEnemyFullZaAt = nil, nil, nil
assert(not dir:IsUsable(dir.partners["gael premier"]), "a player who greeted us first is no partner")
assert(s:RunPeriodicMapCatchup(), "a map round with that player runs")
advance(0.5)
assert(#whispers("NH", "Gael Premier") == 1 and #whispers("SR", "Gael Premier") == 0,
    "our presence first to a player who greeted us")
advance(dir.MAP_PULL_DELAY + 1)
assert(#whispers("SR", "Gael Premier") == 1, "then its map request")
-- A listed player we never heard through the list (greeted, silent) gets none, even reached
-- another way: a client before 2.2.0 hears our guild presence when it is a guild mate.
dir.partners["sid muet"] = { name = "Sid Muet", greetedAt = clock - 200, silentUntil = clock + 1600 }
dir.partnerCount = dir.partnerCount + 1
for _, transport in ipairs({ "GUILD", "WHISPER" }) do
    net.peers["sid muet"] = { name = "Sid Muet", at = clock, via = "Sid Muet", hops = 1, transport = transport }
    sent = {}
    local addressed = 0
    assert(not dir:BeforeMapPull("Sid Muet"), "no presence first to a silent player (" .. transport .. ")")
    advance(0.5)
    for _, row in ipairs(sent) do
        local to, _, what = fields(row.msg)
        if what == "NH" and (to == "Sid Muet" or row.target == "Sid Muet") then addressed = addressed + 1 end
    end
    assert(addressed == 0, "nothing addressed to a silent player (" .. transport .. ")")
end
net.peers["sid muet"] = nil
keepMates()
net.peers[partner:lower()].at = clock
-- Once the channel carries again, a round that falls on that player sends no presence first.
s._channelRefusedAt = nil
advance(dir.MAP_PRESENCE_SEC + 5)
assert(not dir:IsActive() and not dir:BeforeMapPull(partner), "no presence first once the channel carries")
s._channelRefusedAt = clock

-- ---------------------------------------------------------------------------
-- 12. Reports and load order
-- ---------------------------------------------------------------------------

assert(dir:GetDiagnostics():find("Channel member list: 5 names", 1, true), dir:GetDiagnostics())
-- 2.2.0: a refused channel with players of the list exchanging is not a fault: green, and the
-- panel says what carries the data instead.
local level, text = lane:Describe()
assert(level == "ok" and text:find("channel refused by the server", 1, true)
    and text:find("data goes through the channel member list, your group and Battle.net friends", 1, true), text)
-- The panel dot's tooltip gets the short form: no retry period, no guild counters.
local short = select(3, lane:Describe())
assert(short == "channel refused; data goes through the channel member list, your group and Battle.net friends",
    tostring(short))
-- Nobody of the list exchanging (yet): the panel does not count on them, and warns.
net.peers[partner:lower()].at = clock - 400
-- Still green while the list is being read and greeted.
lane.downSince = clock
level, text = lane:Describe()
assert(level == "ok" and text:find("looking for players", 1, true), text)
lane.downSince = clock - 1000
level, text = lane:Describe()
assert(level == "warn" and text:find("0 of them exchanging with you", 1, true)
    and text:find("no guild; data goes through your group and Battle.net friends", 1, true), text)
net.peers[partner:lower()].at = clock
dir.stats.full, dir.lastError = 2, "boom"
local report = dir:GetDiagnostics()
assert(report:find("2 refused (table full)", 1, true) and report:find("last error: boom", 1, true), report)
dir.stats.full, dir.lastError = 0, nil
local toc = io.open("Overlord.toc", "rb"):read("*a"):gsub("\r\n", "\n")
assert(toc:find("SyncGuild.lua\nSyncDirectory.lua\n", 1, true), "SyncDirectory.lua must load right after SyncGuild.lua")

print("Channel directory: list fetched without a world channel, greeting and answer, a reload answered, silence, "
    .. "answers capped, presence kept, ranking and map turns, closer ranking rounds, map pace kept, reports OK")
