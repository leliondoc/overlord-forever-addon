-- Fight brackets under real relay latency: a crowd hearing the same K crosses a bracket
-- in the same second. With every announcement taking seconds to arrive, only a handful
-- may still announce, and the regular refresh must not herd either. A full table of
-- received brackets must never turn a client into a repeating sender.
local simTime = 1789530000
local maps = { [1437] = { name = "Wetlands", mapType = 3 } }
for id = 2000, 2060 do maps[id] = { name = "Zone " .. id, mapType = 3 } end
local sharedEnv = {
    Enum = { UIMapType = { Zone = 3, Dungeon = 4 } },
    C_Map = { GetMapInfo = function(id) return maps[id] end },
    GetServerTime = function() return math.floor(simTime) end,
    GetTime = function() return simTime end,
    time = function() return math.floor(simTime) end,
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
}

local LATENCY = 3
local events = {}
local clients = {}
local sent = {}
local peerNames = {}

local function schedule(at, fn) events[#events + 1] = { at = at, fn = fn, seq = #events } end

local function newClient(name)
    local env = setmetatable({}, { __index = function(_, k)
        if sharedEnv[k] ~= nil then return sharedEnv[k] end
        return _G[k]
    end })
    env._G = env
    env.Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }) }
    env.OverlordDB = {}
    local client = { name = name, env = env }
    env.C_Timer = { After = function(delay, fn) schedule(simTime + delay, fn) end }
    env.Overlord.Relay = {
        GetDirectPeers = function() return peerNames end,
        Broadcast = function(_, kind, payload)
            sent[#sent + 1] = { from = name, payload = payload, at = simTime }
            for _, other in ipairs(clients) do
                if other ~= client then
                    schedule(simTime + LATENCY, function()
                        other.FA:OnReceiveKillBracket(payload, name, "BETA")
                    end)
                end
            end
            return 1
        end,
    }
    for _, file in ipairs({ "Fronts.lua", "FrontActivity.lua" }) do
        local fn = assert(loadfile(file))
        setfenv(fn, env)
        fn()
    end
    client.FA = env.Overlord.FrontActivity
    clients[#clients + 1] = client
    peerNames[#peerNames + 1] = name
    return client
end

local function runUntil(limit)
    while true do
        table.sort(events, function(a, b)
            if a.at ~= b.at then return a.at < b.at end
            return a.seq < b.seq
        end)
        local nextEvent = events[1]
        if not nextEvent or nextEvent.at > limit then simTime = limit; return end
        table.remove(events, 1)
        simTime = nextEvent.at
        nextEvent.fn()
    end
end

local function kill(client, ref)
    client.FA:RecordKillActivity(ref, "Killer Tester")
    client.FA:RecordKills(ref, 1)
end

math.randomseed(7)
local N = 150
for i = 1, N do newClient("Crowd Member" .. i) end

-- Everyone hears the same 12 kills in the same second: bracket 10 crossed by all.
for _ = 1, 12 do for _, client in ipairs(clients) do kill(client, "@arathi") end end
runUntil(simTime + 60)
local first = 0
for _, msg in ipairs(sent) do if msg.payload:find(":arathi:10:", 1, true) then first = first + 1 end end
assert(first >= 1 and first <= 12,
    string.format("%d of %d clients announced the same bracket with %d s of latency", first, N, LATENCY))
for _, client in ipairs(clients) do
    assert(client.FA:GetDisplayKillCount("arathi") >= 10, client.name .. " missed the bracket")
end
local firstWave = first

-- The fight goes on at the same size: the refresh before expiry must not herd either.
sent = {}
for step = 1, 30 do
    for _, client in ipairs(clients) do kill(client, "@arathi") end
    runUntil(simTime + 10)
end
local refresh = 0
for _, msg in ipairs(sent) do if msg.payload:find(":arathi:", 1, true) then refresh = refresh + 1 end end
assert(refresh <= 30, string.format("%d announcements in 5 min of a steady fight for %d clients", refresh, N))
for _, client in ipairs(clients) do
    assert(client.FA:GetDisplayKillCount("arathi") >= 10, client.name .. " lost the steady fight")
end

-- A full table of received brackets (forged or real) never makes a client repeat itself.
local victim = clients[1]
simTime = simTime + 1000
sent = {}
-- The victim announces its own fight first (6 kills: the 5+ bracket)...
for _ = 1, 6 do kill(victim, "@redridge") end
runUntil(simTime + 45)
-- ...then fresher brackets from many senders push it out of the table, and the fight
-- goes on below the next bracket (9 kills at most): nothing new to announce.
simTime = simTime + 40
local slot = math.floor(simTime / 30)
for id = 2000, 2040 do
    victim.FA:OnReceiveKillBracket("1:#" .. id .. ":5:" .. slot, "Filler" .. id, "BETA")
end
for _ = 1, 3 do
    kill(victim, "@redridge")
    runUntil(simTime + 45)
end
local own = 0
for _, msg in ipairs(sent) do if msg.from == victim.name then own = own + 1 end end
assert(own == 1, "a client with a full table announced " .. own .. " times for one bracket")

-- 2.5.0: without the channel (the directory runs) the crowd is those who hear the kills we hear:
-- our guild's lane and our group, no floor of 100. A player alone announces within 6 s; in a
-- guild of 40 a few do, the others wait; and every new bracket is handed to the ranking feed.
do
    local lone = newClient("Lone Fighter")
    local mates, group, feedNotes = 0, 0, 0
    -- (ownFKTaken: the whisper chain took every report of ours; without it the report is taken
    -- back 8 s later and sent again, FrontActivity SendReport.)
    lone.env.Overlord.ChannelDirectory = { IsActive = function() return true end,
        ownFKTaken = setmetatable({ n = 0 }, { __index = function() return 1 end }) }
    lone.env.Overlord.GuildLane = { IsActive = function() return true end, PeerCount = function() return mates end }
    lone.env.GetNumGroupMembers = function() return group end
    lone.env.Overlord.Sync = { _leaderboardFeed = { noteBracket = function() feedNotes = feedNotes + 1 end } }
    local delays = {}
    lone.env.C_Timer = { After = function(delay, fn)
        delays[#delays + 1] = delay
        schedule(simTime + delay, fn)
    end }
    simTime = simTime + 2000
    sent = {}
    for _ = 1, 6 do kill(lone, "@redridge") end
    assert(#delays >= 1 and delays[1] <= 18, "a player alone waited " .. tostring(delays[1]) .. " s to announce its fight")
    runUntil(simTime + 20)
    local told = 0
    for _, msg in ipairs(sent) do if msg.from == lone.name and msg.payload:find(":redridge:5:", 1, true) then told = told + 1 end end
    assert(told == 1, "the fight of a player alone was announced " .. told .. " times within 20 s")
    assert(feedNotes >= 1, "a new bracket was not handed to the ranking feed")
    -- A bracket already known is no news for the feed.
    local before = feedNotes
    local ownSlot
    for _, msg in ipairs(sent) do ownSlot = msg.from == lone.name and msg.payload:match(":redridge:5:(%d+)$") or ownSlot end
    assert(ownSlot, "fixture: the slot of the player's own report")
    lone.FA:OnReceiveKillBracket("1:redridge:5:" .. ownSlot, "Somebody Else", "BETA")
    assert(feedNotes == before, "a known bracket was handed to the feed again")
    lone.FA:OnReceiveKillBracket("1:redridge:20:" .. math.floor(simTime / 30), "Somebody Else", "BETA")
    assert(feedNotes == before + 1, "a bracket taken from somebody was not handed to the feed")
    -- Whispered by a stranger through the relay: shown here, told to nobody by the feed. By a
    -- contact, by a guild mate or by the feed itself: told on.
    local contact = "Known Contact"
    lone.env.Overlord.ChannelDirectory.IsContact = function(_, name) return name == contact end
    lone.env.Overlord.ChannelDirectory.IsLeaf = function() return false end
    local function relayed(bracket, gateway, transport, vouched)
        lone.env.Overlord.Relay.context = { kind = "FK", gateway = gateway, transport = transport, hops = 2 }
        local taken = lone.FA:OnReceiveKillBracket("1:redridge:" .. bracket .. ":" .. math.floor(simTime / 30), "Far Author", "BETA", vouched)
        lone.env.Overlord.Relay.context = nil
        return taken
    end
    before = feedNotes
    assert(relayed(30, "Some Stranger", "WHISPER"), "fixture: a relayed bracket was refused")
    assert(lone.FA:GetDisplayKillCount("redridge") >= 30, "a stranger's bracket is still shown here")
    assert(feedNotes == before, "a bracket whispered by a stranger was handed to the feed")
    assert(relayed(40, contact, "WHISPER") and feedNotes == before + 1, "a contact's bracket was not handed to the feed")
    assert(relayed(50, "Guild Mate", "GUILD") and feedNotes == before + 2, "a guild mate's bracket was not handed to the feed")
    assert(relayed(75, "Some Stranger", "WHISPER", true) and feedNotes == before + 3, "a bracket of the feed was not handed on")
    -- Fed by the ranking feed, a client counts everybody's kills, like every other fed client:
    -- the channel's floor again (about one time in twenty-five within 6 s).
    local fedSources = 2
    lone.env.Overlord.Sync.LadderFeedSources = function() return fedSources end
    local fedQuick = 0
    for i = 1, 150 do
        delays = {}
        simTime = simTime + 1000
        for _ = 1, 6 do kill(lone, "#" .. (2000 + i % 60)) end
        if delays[1] and delays[1] <= 6 then fedQuick = fedQuick + 1 end
        runUntil(simTime + 60)
    end
    assert(fedQuick <= 20, "a fed client announced early " .. fedQuick .. " times of 150")
    fedSources = 0
    -- A player alone: about one time in three within 6 s, never later than 18 s.
    local quick, slow = 0, 0
    for i = 1, 150 do
        delays = {}
        simTime = simTime + 1000
        for _ = 1, 6 do kill(lone, "#" .. (2000 + i % 60)) end
        if delays[1] and delays[1] <= 6 then quick = quick + 1 end
        if delays[1] and delays[1] > 18 then slow = slow + 1 end
        runUntil(simTime + 60)
    end
    assert(quick >= 25 and quick <= 80 and slow == 0, "a player alone: " .. quick .. " of 150 within 6 s, " .. slow .. " after 18 s")
    -- Forty guild mates hear the same kills: about one in ten announces in the first seconds.
    mates = 39
    local early, tries = 0, 160
    for i = 1, tries do
        delays = {}
        simTime = simTime + 1000
        for _ = 1, 6 do kill(lone, "#" .. (2000 + i % 60)) end
        if delays[1] and delays[1] <= 6 then early = early + 1 end
        runUntil(simTime + 60)
    end
    assert(early >= tries * 0.04 and early <= tries * 0.2, "early announcers in a guild of 40: " .. early .. " of " .. tries)
    -- In a raid of 40 without a guild, the same.
    mates, group, early = 0, 40, 0
    for i = 1, tries do
        delays = {}
        simTime = simTime + 1000
        for _ = 1, 6 do kill(lone, "#" .. (2000 + i % 60)) end
        if delays[1] and delays[1] <= 6 then early = early + 1 end
        runUntil(simTime + 60)
    end
    assert(early >= tries * 0.04 and early <= tries * 0.2, "early announcers in a raid of 40: " .. early .. " of " .. tries)
end
print(string.format("Front fight herd: %d/%d first announcers at %d s latency, %d in a 5-min steady fight, full table safe; "
    .. "without the channel a player alone announces within 18 s, a guild of 40 by a few",
    firstWave, N, LATENCY, refresh))
