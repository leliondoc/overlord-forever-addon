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
    env.Overlord.BetaNetwork = {
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
    client.FA:RecordByZoneRef(ref, "Killer Tester")
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
print(string.format("Front fight herd: %d/%d first announcers at %d s latency, %d in a 5-min steady fight, full table safe",
    firstWave, N, LATENCY, refresh))
