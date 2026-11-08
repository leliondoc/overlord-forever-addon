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
    dir.forgottenAt, dir.refreshTried, dir.seeds, dir.seedsAt = nil, nil, nil, nil
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
-- 2.2.2: without a list, only players of the book or of this week's ranking (our faction) are
-- greeted, one every BOOK_GREET_SEC at most, while fewer than MAX_PARTNERS answer.
do
    local seeds = {}
    for _, name in ipairs(dir:LadderSeeds()) do seeds[name] = true end
    for _, name in ipairs(dir:BookNames()) do seeds[name] = true end
    local greeted = whispers("NH")
    for _, row in ipairs(greeted) do
        assert(seeds[row.row.target], "a greeting without a list to a player of neither the book nor the ranking: "
            .. tostring(row.row.target))
        local info = Overlord.Leaderboard.playerInfo[row.row.target]
        assert(dir:InBook(row.row.target) or (info and info.faction == Overlord.PlayerFaction),
            "a seed of the other faction greeted")
    end
    assert(#greeted <= math.ceil(dir.RETRY_SEC * 5 / dir.BOOK_GREET_SEC) + 1, "greetings without a list: " .. #greeted)
end
sent = {}
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
-- 2.2.1: said once, even when yellow (the list's own state said it a second time).
lane.downSince = clock - 1000
do
    local level, _, said = lane:Describe()
    local _, times = said:gsub("suspended", "")
    assert(level == "warn" and times == 1, said)
end
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
-- (The session's first list is behind us: one greeting at a time, not the login's burst.)
dir.booted, dir.wasIdle = true, nil
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
-- (2.2.2: a first silence lasts FIRST_SILENT_SEC; the long one comes with the second.)
-- (Counted from that player's own greeting: jittered, it may come early in the window above.)
assert(row.greetedAt and row.silentUntil == row.greetedAt + dir.ANSWER_WAIT + dir.FIRST_SILENT_SEC,
    "a first silence does not last FIRST_SILENT_SEC")
advance(row.silentUntil - clock - 10)
local again = 0
for _, g in ipairs(whispers("NH")) do if g.row.target == second then again = again + 1 end end
assert(again == 1, "not greeted again within FIRST_SILENT_SEC")
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
-- 10. Ranking rounds: two turns of our side in three to a partner, every neighbour still asked
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
    if r % 3 ~= 0 then assert(name == partner, "turn " .. r .. " goes to the partner, got " .. tostring(name)) end
end
for _, name in ipairs(mates) do assert(asked[name], "every neighbour still asked: " .. name) end
assert(partnerTurns >= 8, "the partner has two turns in three")
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
-- A round that changed at least 4 rows is followed by a hot one (6-12 s); 3 rows are not enough; at most
-- 10 hot rounds in a row, then the next 5 productive ones at the normal pace; the idle rounds that follow a productive one
-- (HOT_IDLE_ROUNDS) are hot too, and a quiet pace resets the streak.
local changedTotal = 0
local function roundAfter(gain)
    local pending = { campaignId = 0, changedBase = changedTotal }
    changedTotal = changedTotal + gain
    s._historyCatchupPending, s._leaderboardPageStats = pending, { protocol = 8, changedRows = changedTotal }
    timers = {}
    finish(pending, true)
    return timers[1] and timers[1].delay
end
s._hotStreak, s._hotIdleLeft, s._hotRest = 0, 0, 0
delay = roundAfter(3)
assert(delay and delay >= 20 and delay <= 40, "3 changed rows are not a productive round: " .. tostring(delay))
for round = 1, 10 do
    delay = roundAfter(4 + round)
    assert(delay and delay >= 6 and delay <= 12, "hot round " .. round .. " of 10: " .. tostring(delay))
end
delay = roundAfter(40)
assert(delay and delay >= 20 and delay <= 40, "the 11th productive round in a row rests at the normal pace: " .. tostring(delay))
assert(s._hotStreak == 0 and s._hotIdleLeft == 0 and s._hotRest == 5, "the streak starts again after the pause")
for rest = 1, 5 do
    delay = roundAfter(40)
    assert(delay and delay >= 20 and delay <= 40, "productive round " .. rest .. " of the rest at the normal pace: " .. tostring(delay))
end
assert(s._hotRest == 0 and s._hotIdleLeft == 0, "the rest is over")
delay = roundAfter(40)
assert(delay and delay >= 6 and delay <= 12, "hot again after the rest: " .. tostring(delay))
s._hotStreak, s._hotIdleLeft = 0, 0
delay = roundAfter(3)
assert(delay and delay >= 20 and delay <= 40, "quiet pace after the pause: " .. tostring(delay))
delay = roundAfter(9)
assert(delay and delay >= 6 and delay <= 12, "hot again after a new productive round: " .. tostring(delay))
for idle = 1, 2 do
    delay = roundAfter(0)
    assert(delay and delay >= 6 and delay <= 12, "idle round " .. idle .. " after a productive one stays hot: " .. tostring(delay))
end
delay = roundAfter(0)
assert(delay and delay >= 20 and delay <= 40, "the third idle round rests: " .. tostring(delay))
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
-- 2.3.0: our own side's turn falls on a guild mate right after a guild mate's whole map: no second
-- copy of the guild's map. A held site waiting for its snapshot still pulls, and so does the next
-- turn once that map is older than the interval.
do
    local mate = "Mila Guilde"
    local outdated, savedOutpost = s.IsOutdatedMapPeer, Overlord.Outpost
    s.IsOutdatedMapPeer = function() return false end
    for _, row in pairs(net.peers) do row.at = clock - 400 end
    net.peers[mate:lower()] = { name = mate, at = clock, via = mate, hops = 1, transport = "WHISPER" }
    lane.peers[mate:lower()], lane.peerCountAt = clock, nil
    assert(dir:IsActive() and lane:IsGuildMate(mate), "fixture: the list in use, a guild mate reached")
    s._mapCatchupRound, s._mapAllyTurns = 0, 0
    s._lastFullZaAt, s._lastOwnFullZaAt, s._lastEnemyFullZaAt, s._lastOwnFarZaAt = nil, nil, nil, nil
    s:NoteFullMapReceived(mate)
    assert(s._lastOwnFullZaAt == clock and s._lastOwnFarZaAt == nil, "a guild mate's map is no far map")
    sent, s._mapCatchupLastTarget = {}, nil
    assert(not s:RunPeriodicMapCatchup() and s._mapCatchupLastTarget == nil,
        "a guild mate asked for the guild's map again: " .. tostring(s._mapCatchupLastTarget))
    advance(dir.MAP_PULL_DELAY + 1)
    assert(#whispers("SR", mate) == 0, "no map request to the guild mate")
    Overlord.Outpost = { HasStateAwaitingNetwork = function() return true end }
    s._mapCatchupLastTarget = nil
    s:RunPeriodicMapCatchup()
    Overlord.Outpost = savedOutpost
    assert(s._mapCatchupLastTarget == mate, "a held site waiting for its snapshot pulls from the guild mate")
    s._lastFullZaAt = clock - s.BETA_MAP_CATCHUP_INTERVAL - 1
    s._lastOwnFullZaAt = s._lastFullZaAt
    s._mapCatchupLastTarget = nil
    s:RunPeriodicMapCatchup()
    assert(s._mapCatchupLastTarget == mate, "the guild mate is asked once that map is older than the interval")
    s.IsOutdatedMapPeer = outdated
    net.peers[mate:lower()], lane.peers[mate:lower()], lane.peerCountAt = nil, nil, nil
    keepMates()
    net.peers[partner:lower()].at = clock
end

-- ---------------------------------------------------------------------------
-- 12. Reports and load order
-- ---------------------------------------------------------------------------

assert(dir:GetDiagnostics():find("Channel member list: 5 names", 1, true), dir:GetDiagnostics())
assert(dir:GetDiagnostics():find("; address book: %d+ players; 0 players met in the world greeted; %d+ contacts, %d+ leaves; "
    .. "0 answers waiting"), dir:GetDiagnostics())
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
-- 2.2.1: a greeted player the relay reaches without its answer to our greeting (a guild mate
-- under 2.1.1) is not "exchanging with you" through the list.
do
    local row = dir.partners[partner:lower()]
    local heard = row.heardAt
    row.heardAt = nil
    assert(dir:AnsweringCount() == 0 and select(2, dir:Describe()) == 0, "counted without an answer")
    row.heardAt = heard
    assert(dir:AnsweringCount() == 1, "an answering partner not counted")
end
-- ---------------------------------------------------------------------------
-- 13. 2.2.2: the first greetings of a session, the address book, answers waiting for the next
-- minute, a shorter first silence, a player said offline, answers while our channel carries
-- ---------------------------------------------------------------------------

local function serverNow() return Overlord.ServerNow and Overlord.ServerNow() or time() end
OverlordDB.directoryBook = nil
fresh({ grouped = true })
dir.booted = nil
advance(dir.TICK_SEC + dir.READ_POLLS[1] + 1)
assert(#dir.names == 5, "list read: " .. #dir.names)
advance(dir.BOOT_GREETS * dir.BOOT_GAP + 3)
local bootGreetings = #whispers("NH")
assert(bootGreetings >= dir.BOOT_GREETS and bootGreetings <= dir.BOOT_GREETS + 1,
    "the first list: a few greetings within seconds, got " .. bootGreetings)
-- An answer from a listed player goes into the book; an unlisted greeter does not.
local first = whispers("NH")[1].row.target
whisperFrom(first, "NH", presence())
assert(dir:InBook(first), "a listed player that answered is kept in the book")
whisperFrom("Hors Liste", "NH", presence())
assert(not dir:InBook("Hors Liste"), "an unlisted greeter is not kept")
-- Newest first; old and malformed entries dropped.
local page = dir:Book(true)
page["vieux nom"] = { n = "Vieux Nom", t = serverNow() - 4 * 86400 }
page["mal forme"] = { n = "Autre Nom", t = serverNow() }
page["nina livre"] = { n = "Nina Livre", t = serverNow() - 60 }
local bookNames = dir:BookNames()
assert(#bookNames == 2 and bookNames[1] == first and bookNames[2] == "Nina Livre", table.concat(bookNames, ","))
assert(page["vieux nom"] == nil and page["mal forme"] == nil, "old and malformed entries dropped")
-- Full: the oldest makes room.
for i = 1, dir.BOOK_MAX - 2 do page["filler " .. i] = { n = "Filler " .. i, t = serverNow() - 1000 - i } end
local another
for _, name in ipairs(dir.names) do if name ~= first then another = name break end end
assert(dir:Remember(another), "a listed player remembered")
local entries = 0
for _ in pairs(page) do entries = entries + 1 end
assert(entries == dir.BOOK_MAX and page["filler " .. (dir.BOOK_MAX - 2)] == nil, "the book stays at its size: " .. entries)
for i = 1, dir.BOOK_MAX - 2 do page["filler " .. i] = nil end
-- Without the list (unreadable, suspended): the book's players are known and greeted.
local savedNames = dir.names
dir.names = {}
assert(dir:ListLess(), "no list after a try")
assert(dir:Known("Nina Livre") and not dir:Known("Hors Liste"), "the book stands for the list")
local picked = dir:PickNew()
assert(picked and dir:InBook(picked) and not net:IsPeer(picked), "a player of the book greeted: " .. tostring(picked))
-- An empty book: this week's ranking of our faction instead; one that answers our own greeting
-- is kept, a player that whispers first is not.
do
    local savedPage, lb = OverlordDB.directoryBook, Overlord.Leaderboard
    OverlordDB.directoryBook = nil
    dir.seeds, dir.seedsAt = nil, nil
    lb.kills["Sid Graine"], lb.playerInfo["Sid Graine"] = 7, { faction = Overlord.PlayerFaction }
    lb.kills["Rob Rouge"], lb.playerInfo["Rob Rouge"] = 9, { faction = "Horde" }
    local seedSet = {}
    for _, name in ipairs(dir:LadderSeeds()) do seedSet[name] = true end
    assert(seedSet["Sid Graine"] and not seedSet["Rob Rouge"], "seeds: players of our faction only")
    -- A big ranking: one look reads a window of it, keeps its best LADDER_SEEDS, of our faction.
    local function seedName(i)
        local a, b, c = i % 26, math.floor(i / 26) % 26, math.floor(i / 676) % 26
        return "Seed " .. string.char(65 + c) .. string.char(97 + b) .. string.char(97 + a)
    end
    for i = 1, 5000 do
        local name = seedName(i)
        lb.kills[name], lb.playerInfo[name] = i % 50 + 1, { faction = i % 2 == 0 and Overlord.PlayerFaction or "Horde" }
    end
    dir.seeds, dir.seedsAt = nil, nil
    local big = dir:LadderSeeds()
    assert(#big == dir.LADDER_SEEDS, "seeds of a big ranking: " .. #big)
    for _, name in ipairs(big) do
        local row = lb.playerInfo[name]
        assert(row and row.faction == Overlord.PlayerFaction, "a seed of the other faction: " .. name)
    end
    combat = true
    dir.seedsAt = -1e9
    assert(dir:LadderSeeds() == big, "seeds looked up again in combat")
    combat = false
    for i = 1, 5000 do lb.kills[seedName(i)], lb.playerInfo[seedName(i)] = nil, nil end
    dir.seeds, dir.seedsAt = nil, nil
    seedSet = {}
    for _, name in ipairs(dir:LadderSeeds()) do seedSet[name] = true end
    assert(seedSet["Sid Graine"], "Sid Graine back among the seeds")
    assert(dir:Greet("Sid Graine"), "a seed greeted")
    -- (Its answer waited for its next minute: still the answer to our greeting.)
    dir.partners["sid graine"].greetedAt = clock - dir.ANSWER_WAIT - 15
    whisperFrom("Sid Graine", "NH", presence())
    assert(dir:InBook("Sid Graine"), "a seed that answered our greeting is kept")
    whisperFrom("Tom Intrus", "NH", presence())
    assert(not dir:InBook("Tom Intrus"), "a player that whispered first is not kept")
    OverlordDB.directoryBook = savedPage
    lb.kills["Sid Graine"], lb.playerInfo["Sid Graine"], lb.kills["Rob Rouge"], lb.playerInfo["Rob Rouge"] = nil, nil, nil, nil
    dir.seeds, dir.seedsAt = nil, nil
end
-- 2.3.0: a look at a big ranking walks a bounded part of it (never the whole ranking, twice,
-- in one frame); the seeds stay the best of our faction, each once, and the window moves on.
do
    local lb = Overlord.Leaderboard
    local rawNext, rawPairs = next, pairs
    local function bigName(i)
        local a, b, c, d = i % 26, math.floor(i / 26) % 26, math.floor(i / 676) % 26, math.floor(i / 17576) % 26
        return "Big " .. string.char(65 + d) .. string.char(97 + c) .. string.char(97 + b) .. string.char(97 + a)
    end
    for i = 1, 20000 do
        local name = bigName(i)
        lb.kills[name], lb.playerInfo[name] = i % 50 + 1, { faction = i % 2 == 0 and Overlord.PlayerFaction or "Horde" }
    end
    local steps = 0
    next = function(t, k)
        if t == lb.kills then steps = steps + 1 end
        return rawNext(t, k)
    end
    pairs = function(t)
        if t ~= lb.kills then return rawPairs(t) end
        return function(tt, k) steps = steps + 1 return rawNext(tt, k) end, t, nil
    end
    local union, seen = {}, 0
    for look = 1, 5 do
        steps = 0
        dir.seeds, dir.seedsAt = nil, nil
        local seeds = dir:LadderSeeds()
        local bound = dir.LADDER_SEED_SCAN + (dir.LADDER_SEED_SKIP or 0) + 2
        assert(steps <= bound, string.format("look %d: %d rows walked in a ranking of 20000 (at most %d)", look, steps, bound))
        assert(#seeds == dir.LADDER_SEEDS, "seeds of a 20000-row ranking: " .. #seeds)
        local once = {}
        for _, name in ipairs(seeds) do
            assert(not once[name], "a seed twice: " .. name)
            once[name] = true
            local row = lb.playerInfo[name]
            assert(row and row.faction == Overlord.PlayerFaction, "a seed of the other faction: " .. name)
            if not union[name] then union[name], seen = true, seen + 1 end
        end
    end
    next, pairs = rawNext, rawPairs
    assert(seen > dir.LADDER_SEEDS, "the window never moved: " .. seen .. " seeds in 5 looks")
    for i = 1, 20000 do lb.kills[bigName(i)], lb.playerInfo[bigName(i)] = nil, nil end
    -- A small ranking (fewer rows than the window): each player once, the cursor gone with its row.
    for _, name in ipairs({ "Una Petite", "Deux Petite", "Tres Petite" }) do
        lb.kills[name], lb.playerInfo[name] = 1000000, { faction = Overlord.PlayerFaction }
    end
    dir.seeds, dir.seedsAt = nil, nil
    local count = {}
    for _, name in ipairs(dir:LadderSeeds()) do count[name] = (count[name] or 0) + 1 end
    for _, name in ipairs({ "Una Petite", "Deux Petite", "Tres Petite" }) do
        assert(count[name] == 1, "a small ranking: " .. name .. " seen " .. tostring(count[name]))
        lb.kills[name], lb.playerInfo[name] = nil, nil
    end
    dir.seeds, dir.seedsAt, dir.seedCursor = nil, nil, nil
end
-- The panel counts the players of the book that exchange with us.
do
    local text, live, listLess = dir:Describe()
    assert(live >= 1 and listLess and text:find("found without it exchanging with you", 1, true), text)
end
-- 2.2.2: nobody at all (no list, no book, no ranking, nobody heard directly): players of our
-- faction met in the world, PvP on, are greeted (a few a session); the unit events are watched
-- only then, and dropped as soon as somebody is heard.
do
    local savedPage, savedCount, savedName = OverlordDB.directoryBook, net.CountDirectPeers, Overlord.SafeGetUnitName
    local savedFrame, savedGlobals = CreateFrame, { UnitIsPlayer, UnitIsUnit, UnitFactionGroup, UnitIsPVP }
    local registered = {}
    dir:WatchWorld(false)
    dir.worldFrame = nil
    CreateFrame = function()
        return { SetScript = function() end,
            RegisterEvent = function(_, event) registered[event] = true end,
            UnregisterEvent = function(_, event) registered[event] = nil end }
    end
    local units = {
        target = { name = "Mia Croisee", faction = Overlord.PlayerFaction, pvp = true },
        mouseover = { name = "Rob Ennemi", faction = "Horde", pvp = true },
        nameplate1 = { name = "Pat Paisible", faction = Overlord.PlayerFaction, pvp = false },
        nameplate2 = { name = "Lou Voisine", faction = Overlord.PlayerFaction, pvp = true },
    }
    UnitIsPlayer = function(unit) return units[unit] ~= nil end
    UnitIsUnit = function() return false end
    UnitFactionGroup = function(unit) return units[unit] and units[unit].faction end
    UnitIsPVP = function(unit) return units[unit] and units[unit].pvp end
    Overlord.SafeGetUnitName = function(_, unit) return units[unit] and units[unit].name end
    OverlordDB.directoryBook = {}
    dir.seeds, dir.seedsAt = {}, clock
    net.CountDirectPeers = function() return 1 end
    assert(not dir:Isolated(), "a peer heard directly: not isolated")
    dir:Tick()
    assert(not dir.worldWatched and not registered.PLAYER_TARGET_CHANGED, "no unit event while somebody is heard")
    net.CountDirectPeers = function() return 0 end
    assert(dir:Isolated(), "nobody heard, no list: isolated")
    dir:Tick()
    assert(dir.worldWatched and registered.PLAYER_TARGET_CHANGED and registered.NAME_PLATE_UNIT_ADDED,
        "unit events watched while isolated")
    assert(dir:NoteSeen("target"), "a PvP player of our faction met")
    assert(not dir:NoteSeen("mouseover"), "an enemy is not greeted")
    assert(not dir:NoteSeen("nameplate1"), "a player without PvP is not greeted")
    assert(dir:NoteSeen("nameplate2"), "a second one met")
    assert(dir:NoteSeen("target") and #dir.world == 2 and dir.world[1].name == "Mia Croisee", "met again: first, once")
    local picked = dir:PickNew()
    assert(picked == "Mia Croisee" and dir.stats.worldGreeted == 1, "the last met greeted: " .. tostring(picked))
    assert(dir:Greet(picked), "greeting sent")
    local again = dir:PickNew()
    assert(again == "Lou Voisine", "the next one, not the same twice: " .. tostring(again))
    whisperFrom("Mia Croisee", "NH", presence())
    assert(dir:InBook("Mia Croisee"), "a player met that answered is kept in the book")
    -- Somebody heard: the events dropped (Tick), the players met forgotten.
    net.CountDirectPeers = function() return 1 end
    dir:Tick()
    assert(not dir.worldWatched and not registered.PLAYER_TARGET_CHANGED and #dir.world == 0, "events dropped")
    -- The session's greetings used up: never isolated again.
    net.CountDirectPeers = function() return 0 end
    dir.stats.worldGreeted = dir.WORLD_MAX
    assert(not dir:Isolated(), "the session's greetings used up")
    dir:Tick()
    assert(not dir.worldWatched, "no events past the budget")
    dir.stats.worldGreeted = 0
    OverlordDB.directoryBook, net.CountDirectPeers, Overlord.SafeGetUnitName = savedPage, savedCount, savedName
    CreateFrame, dir.worldFrame = savedFrame, nil
    UnitIsPlayer, UnitIsUnit, UnitFactionGroup, UnitIsPVP = savedGlobals[1], savedGlobals[2], savedGlobals[3], savedGlobals[4]
    dir.seeds, dir.seedsAt = nil, nil
end
dir.names = savedNames
-- Past the answers of the minute, the next ones wait for the next minute (REPLY_QUEUE at most).
dir.replies = { at = clock, count = dir.REPLIES_PER_MIN }
sent = {}
local waiters = { "Ana Une", "Bea Deux", "Cyl Trois", "Dan Quatre", "Eva Cinq", "Fil Six", "Gus Sept", "Hal Huit" }
for _, name in ipairs(waiters) do whisperFrom(name, "NH", presence()) end
assert(#dir.replyQueue == dir.REPLY_QUEUE, "answers kept for the next minute: " .. #(dir.replyQueue or {}))
local answered = 0
for _, name in ipairs(waiters) do answered = answered + #whispers("NH", name) end
assert(answered == 0, "none within the capped minute")
-- (The relay paces its whispers: a few seconds more for the last ones.)
advance(61 + 10)
answered = 0
for _, name in ipairs(waiters) do answered = answered + #whispers("NH", name) end
assert(answered == math.min(dir.REPLY_QUEUE, dir.REPLIES_PER_MIN), "the kept answers go next minute: " .. answered)
-- An instance meanwhile: the waiting answers dropped; a queue made after it still goes.
dir.replies = { at = clock, count = dir.REPLIES_PER_MIN }
whisperFrom("Ivo Neuf", "NH", presence())
assert(#(dir.replyQueue or {}) == 1, "an answer kept")
dir:Suspend()
assert(dir.replyQueue == nil and not dir.partners["ivo neuf"].queued, "kept answers dropped in an instance")
dir:Resume()
whisperFrom("Jon Dix", "NH", presence())
assert(#(dir.replyQueue or {}) == 1, "a new answer kept after the instance")
sent = {}
advance(61 + 10)
assert(#whispers("NH", "Jon Dix") == 1, "the answer kept after an instance went")
-- A greeting without an answer: a short first silence, the long one after.
local quiet = { name = "Quin Muet", greetedAt = clock }
dir.partners["quin muet"] = quiet
dir.partnerCount = dir.partnerCount + 1
dir:CheckAnswer(quiet)
assert(quiet.silentUntil == clock + dir.FIRST_SILENT_SEC, "first silence: " .. tostring(quiet.silentUntil - clock))
quiet.silentUntil = nil
dir:CheckAnswer(quiet)
assert(quiet.silentUntil == clock + dir.SILENT_SEC, "second silence: " .. tostring(quiet.silentUntil - clock))
-- Said offline by the game: no partner turns, no direct route, until it greets us again.
local firstRow = dir.partners[first:lower()]
assert(dir:IsUsable(firstRow), "the player that answered is a partner")
assert(dir:NoteUnreachable(first), "offline noted")
assert(not dir:IsUsable(firstRow) and not net:IsDirectPeer(first), "offline: no partner, no direct route")
advance(dir.PRESENCE_SEC + 1)
whisperFrom(first, "NH", presence())
assert(not firstRow.unreachableUntil and dir:IsUsable(firstRow), "back once it greets us")
-- Our channel carries again: a greeting is still answered (the greeter's may be refused).
s._channelRefusedAt = nil
assert(not dir:IsActive(), "inactive while the channel carries")
dir.replies = { at = -1000, count = 0 }
sent = {}
whisperFrom("Omar Ouvert", "NH", presence())
advance(5)
assert(#whispers("NH", "Omar Ouvert") == 1, "answered even while our channel carries")
s._channelRefusedAt = clock

-- 2.3.0: refused while the players of the list are heard on our channel (refused alone, or just
-- after a refusal): they do not hear us there. They are greeted; one that stays silent is silent.
fresh()
local onChannel = {}
for _, name in ipairs({ "Alpha Lune", "Brume Vent", "Cendre Roc", "Dune Sable", "Ecume Gris" }) do
    onChannel[name] = true
    net.peers[name:lower()] = { name = name, at = clock, via = name, hops = 1, transport = "CHANNEL" }
end
advance(dir.TICK_SEC + dir.READ_POLLS[1] + dir.TICK_SEC + 2)
local greetedThere = whispers("NH")
assert(#dir.names == 5 and #greetedThere >= 1, "nobody heard on our channel was greeted: " .. #greetedThere)
for _, g in ipairs(greetedThere) do assert(onChannel[g.row.target], "greeted: " .. tostring(g.row.target)) end
advance(dir.ANSWER_WAIT + 1)
local quietThere = dir.partners[greetedThere[1].row.target:lower()]
assert(quietThere and not quietThere.heardAt and quietThere.silentUntil,
    "heard on our channel was taken for an answer to our greeting")
s._channelRefusedAt = clock

-- 2.3.0: a player of the list that greeted us first is a contact while the relay reaches it
-- directly: its greeting half an hour old (it sends no presence again while it hears us), it is
-- not forgotten; gone quiet, it is.
do
    fresh({ grouped = true })
    advance(dir.TICK_SEC + dir.READ_POLLS[#dir.READ_POLLS] + 1)
    local name = dir.names[1]
    assert(name, "list read")
    whisperFrom(name, "NH", presence())
    local row = dir.partners[name:lower()]
    assert(row and dir:IsContact(name), "a listed greeter is a contact")
    local old = clock - dir.SILENT_SEC - 600
    row.greetedAt, row.askedAt, row.silentUntil = nil, nil, nil
    row.heardAt, row.chainAt, row.presenceAt = old, old, old
    net.peers[name:lower()].at = clock
    dir:Forget()
    assert(dir.partners[name:lower()] == row and dir:IsContact(name),
        "a contact still reached directly was forgotten: its news taken for a stranger's")
    net.peers[name:lower()].at = clock - 400
    dir:Forget()
    assert(dir.partners[name:lower()] == nil, "a contact gone quiet is forgotten")
end
s._channelRefusedAt = clock

-- 2.3.0: a player kept out of every list (a leaf) that greeted us half an hour ago and that the
-- relay still reaches directly (its ranking rounds keep its route) is still a leaf: it sends no
-- presence again while it hears us. Gone quiet, it is not.
do
    fresh({ grouped = true })
    advance(dir.TICK_SEC + dir.READ_POLLS[#dir.READ_POLLS] + 1)
    assert(#dir.names > 0, "list read")
    local leaf = "Lia Vieille"
    whisperFrom(leaf, "NH", presence())
    local row = dir.partners[leaf:lower()]
    assert(row and dir:IsLeaf(leaf) and not dir:Known(leaf), "an unlisted greeter is a leaf")
    local old = clock - dir.SILENT_SEC - 600
    row.heardAt, row.chainAt, row.presenceAt = old, old, old
    net.peers[leaf:lower()].at = clock
    local named = false
    for _, name in ipairs(dir:LeafNames()) do if name == leaf then named = true end end
    assert(dir:IsLeaf(leaf) and named,
        "a leaf still reached directly lost its leaf status: its own captures taken for a stranger's")
    net.peers[leaf:lower()].at = clock - 400
    assert(not dir:IsLeaf(leaf), "a leaf gone quiet is no leaf")
end
s._channelRefusedAt = clock

-- 2.3.0: a greeter missing from our list (a player the game keeps out of every list) has it read
-- again once, not every REREAD_SEC for as long as it whispers its presence to us.
do
    fresh({ grouped = true })
    advance(dir.TICK_SEC + dir.READ_POLLS[#dir.READ_POLLS] + 1)
    assert(#dir.names > 0, "list read")
    advance(dir.REREAD_SEC + 1)
    whisperFrom("Lea Feuille", "NH", presence())
    assert(dir.nextReadAt <= clock + dir.RETRY_SEC, "an unlisted greeter: the list read again soon")
    local reads = dir.stats.reads
    advance(dir.RETRY_SEC + dir.TICK_SEC + dir.READ_POLLS[#dir.READ_POLLS] + 1)
    assert(dir.stats.reads > reads and not dir:Lists("Lea Feuille"), "read again, still not listed")
    advance(dir.REREAD_SEC + 1)
    local planned = dir.nextReadAt
    whisperFrom("Lea Feuille", "NH", presence())
    assert(dir.nextReadAt == planned, string.format("the list read again for the same leaf: planned in %d s, now in %d s",
        planned - clock, dir.nextReadAt - clock))
end
s._channelRefusedAt = clock

local toc = io.open("Overlord.toc", "rb"):read("*a"):gsub("\r\n", "\n")
assert(toc:find("SyncGuild.lua\nSyncDirectory.lua\n", 1, true), "SyncDirectory.lua must load right after SyncGuild.lua")

-- 2.3.0: the channel carried a while, then is refused again: the first greetings come together as
-- after a login (Boot), not one a minute.
fresh()
advance(dir.TICK_SEC + dir.READ_POLLS[1] + 1)
assert(#dir.names == 5, "fixture: list read")
s._channelRefusedAt = nil
advance(dir.TICK_SEC * 2)
assert(not dir:IsActive(), "fixture: the channel carries")
sent = {}
s._channelRefusedAt = clock
advance(dir.TICK_SEC + dir.BOOT_GREETS * dir.BOOT_GAP + 3)
assert(#whispers("NH") >= dir.BOOT_GREETS, "refused again: " .. #whispers("NH") .. " greetings")

-- 2.3.0: back from an instance longer than the relay keeps a route (300 s): every partner is a
-- stranger again (no direct route), the chain's view is empty. The first greetings come together
-- as after a login (Boot), not one a minute; a short instance keeps its partners and boots nothing.
fresh({ grouped = true })
dir.booted, dir.wasIdle = true, nil
advance(dir.TICK_SEC + dir.READ_POLLS[1] + dir.TICK_SEC + 2)
local backPartner = whispers("NH")[1] and whispers("NH")[1].row.target
assert(#dir.names == 5 and backPartner, "fixture: list read, one greeting out")
whisperFrom(backPartner, "NH", presence())
assert(dir:IsUsable(dir.partners[backPartner:lower()]), "fixture: a partner answers")
instanced, Overlord.InstanceSuspended = true, true
s:OnNetworkSuspend()
advance(600)
instanced, Overlord.InstanceSuspended = false, false
s:OnNetworkResume()
-- (The channel probe is SyncGuild's business: not in this test's window.)
lane.probeGeneration = (lane.probeGeneration or 0) + 1
sent = {}
assert(not dir:IsUsable(dir.partners[backPartner:lower()]), "fixture: the routes died in the instance")
advance(dir.TICK_SEC * 2 + dir.BOOT_GREETS * dir.BOOT_GAP + 10)
assert(#whispers("NH") >= dir.BOOT_GREETS, "back from a long instance: " .. #whispers("NH") .. " greetings, one a minute")
-- A short one: the partners are still reached, nothing boots.
fresh({ grouped = true })
dir.booted, dir.wasIdle = true, nil
advance(dir.TICK_SEC + dir.READ_POLLS[1] + dir.TICK_SEC + 2)
instanced, Overlord.InstanceSuspended = true, true
s:OnNetworkSuspend()
advance(120)
instanced, Overlord.InstanceSuspended = false, false
s:OnNetworkResume()
lane.probeGeneration = (lane.probeGeneration or 0) + 1
sent = {}
advance(dir.TICK_SEC * 2 + dir.BOOT_GREETS * dir.BOOT_GAP + 10)
assert(#whispers("NH") <= 1, "back from a short instance: " .. #whispers("NH") .. " greetings, no boot")

print("Channel directory: list fetched without a world channel, greeting and answer, a reload answered, silence, "
    .. "answers capped, presence kept, ranking and map turns, closer ranking rounds, map pace kept, reports OK")
