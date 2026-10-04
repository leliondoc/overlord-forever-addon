-- Ranking convergence by point-to-point gossip (1.2.4). Four replicas in a chain
-- (Alliance channel <-> Battle.net bridge <-> Horde channel) run the production
-- scheduler: every round is a v6 sweep with a direct neighbour, no catch-up is
-- relayed, and all replicas still converge, both ways, including a late joiner.
-- Only WoW transports and clock are simulated; the sliced snapshot builder is real.
local now, serial, pending, clients = 100, 0, {}, {}
local function later(delay, run)
    serial = serial + 1
    pending[#pending + 1] = { at = now + delay, run = run, serial = serial }
end
local function advance(seconds)
    local stop, steps = now + seconds, 0
    while #pending > 0 do
        table.sort(pending, function(a, b)
            return a.at < b.at or (a.at == b.at and a.serial < b.serial)
        end)
        if pending[1].at > stop then break end
        local event = table.remove(pending, 1)
        now = event.at
        event.run()
        steps = steps + 1
        assert(steps < 100000, "Unbounded catchup work")
    end
    now = stop
    for _, c in ipairs(clients) do
        assert(not c.Overlord.BetaNetwork.stats.lastError, c.Overlord.BetaNetwork.stats.lastError)
    end
end
local function copy(t)
    if type(t) ~= "table" then return t end
    local result = {}
    for k, v in pairs(t) do result[k] = copy(v) end
    return result
end
local function client(name, channel)
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    -- The base capture fixture stubs index readiness; restore the real module
    -- before exercising the production snapshot/index workers.
    e.loadfile("Leaderboard.lua")()
    e.name, e.channel, e.friends = name, channel, {}
    e.GetTime = function() return now end
    e.time = function() return 1790017000 + math.floor(now) end
    e.GetServerTime = e.time
    e.UnitName = function() return name end
    e.UnitFullName = function() return name, "" end
    e.GetUnitName = e.UnitName
    e.InCombatLockdown = function() return false end
    e.C_Timer = {
        After = later,
        NewTicker = function(delay, callback)
            local ticker = { Cancel = function(self) self.cancelled = true end }
            local function tick()
                if ticker.cancelled then return end
                callback()
                if not ticker.cancelled then later(delay, tick) end
            end
            later(delay, tick)
            return ticker
        end,
    }
    e.strsplit = function(sep, value, limit)
        local fields, start = {}, 1
        while not limit or #fields < limit - 1 do
            local at = value:find(sep, start, true)
            if not at then break end
            fields[#fields + 1] = value:sub(start, at - 1)
            start = at + #sep
        end
        fields[#fields + 1] = value:sub(start)
        return unpack(fields)
    end
    -- Community mode is enabled in production; an empty roster must still leave
    -- the channel/group/BNet fallback fully functional for non-members.
    e.C_Club = { GetSubscribedClubs = function() return {} end }
    e.Enum = { ClubType = { Character = 1 } }
    local s, lb = e.Overlord.Sync, e.Overlord.Leaderboard
    s.GetPlayerFullName = function() return name end
    s.GetChannelId = function() return 1 end
    s.GetBetaBNetTargets = function() return e.friends end
    s.SendToChannel = function(_, kind, fragment)
        assert(#kind + #fragment + 1 <= 255)
        if e.refuseChannel then e.refuseChannel = false; return false end
        for _, other in ipairs(clients) do
            if other ~= e and other.channel == channel then
                other.Overlord.Sync:OnAddonMessage("OverlordF", kind .. ":" .. fragment, "CHANNEL", name)
            end
        end
        return true
    end
    s.SendToBNet = function(_, other, kind, wire)
        if kind == "BR" then
            other.Overlord.BetaNetwork:Receive(wire, name, "BNET", e)
        else
            other.Overlord.BetaNetwork:ReceiveFragment(wire, name, "BNET", e)
        end
        return true
    end
    -- Keep production SendWhisper: it must choose BF routes, including replies.
    e.securecall = function(fn, ...) return fn(...) end
    e.C_ChatInfo = { SendAddonMessage = function(prefix, message, transport, target)
        assert(transport == "WHISPER", "Invalid direct transport")
        local destination
        for _, other in ipairs(clients) do
            if other.name == target then destination = other; break end
        end
        assert(message:sub(1, 3) == "BF:"
            or (destination and destination.channel == channel),
            "Raw cross-faction reply: " .. tostring(name) .. " -> " .. tostring(target))
        for _, other in ipairs(clients) do
            if other.name == target then
                local destination = other
                later(0.05, function()
                    destination.Overlord.Sync:OnAddonMessage(prefix, message, transport, name)
                end)
            end
        end
    end }
    lb.kills, lb.captureCount, lb.captures, lb.playerInfo = {}, {}, {}, {}
    lb._storageBound = true
    e.loadfile("SyncHistoryCatchup.lua")()
    e.loadfile("SyncLeaderboardPages.lua")()
    e.loadfile("SyncBetaNetwork.lua")()
    clients[#clients + 1] = e
    return e
end
local a = client("Analyst Tester", "alliance")
local b = client("Bridge Tester", "alliance")
local c = client("Gateway Tester", "horde")
local d = client("Veteran Tester", "horde")
b.friends, c.friends = { c }, { b }
-- Real factions, so the responder fair share (an other-faction requester takes over
-- a same-faction session after two minutes) is active during the whole hour.
for _, e in ipairs(clients) do
    e.Overlord.PlayerFaction = e.channel == "horde" and "Horde" or "Alliance"
    e.Overlord.Sync.GetBetaPeerFaction = function(_, peer)
        for _, other in ipairs(clients) do
            if other.name == peer then return other.channel == "horde" and "Horde" or "Alliance" end
        end
    end
end
for _, e in ipairs(clients) do e.Overlord.Sync.SendSyncRequest = function() return true end end
local heartbeatActive = true
local function heartbeat()
    if not heartbeatActive then return end
    for _, e in ipairs(clients) do
        e.Overlord.Sync.SendSyncRequest = function() return true end
        e.Overlord.BetaNetwork:Broadcast("NH", "1.2.4~lp6")
    end
    later(45, heartbeat)
end
heartbeat()
advance(10)
assert(a.Overlord.BetaNetwork:IsDirectPeer(b.name) and not a.Overlord.BetaNetwork:IsDirectPeer(d.name),
    "Fixture topology: Analyst must reach Veteran only through relays")

local names = {}
for i = 1, 500 do
    local name = "Player " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(65 + (i - 1) % 26)
    names[#names + 1] = name
    local lb = d.Overlord.Leaderboard
    lb.kills[name] = i * 10
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 60,
        locale = "engb", guild = "Veteran Guild", guildAt = 1790016000 }
    if i > 460 then lb.playerInfo[name].race, lb.playerInfo[name].raceSex = "Orc", 2 end
    if i <= 120 then lb.captureCount[name], lb.captures[name] = i, {} end
end
a.Overlord.Leaderboard.kills["Unique Tester"] = 4999
a.Overlord.Leaderboard.playerInfo["Unique Tester"] = {
    class = "PRIEST", faction = "Alliance", level = 60, locale = "engb" }

-- Every replica runs its own production scheduler for an hour of periodic rounds.
for _, e in ipairs(clients) do
    assert(e.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true))
end
advance(3600)
for _, e in ipairs(clients) do
    for _, name in ipairs(names) do
        assert(e.Overlord.Leaderboard.kills[name] == d.Overlord.Leaderboard.kills[name],
            "Replica kills diverged: " .. e.name .. " / " .. name .. " / "
            .. table.concat(e.Overlord.Sync:GetHistoryCatchupDiagnostics(), "; "))
        assert((e.Overlord.Leaderboard.playerInfo[name] or {}).guild == "Veteran Guild",
            "Guild metadata lost: " .. e.name .. " / " .. name)
        if (d.Overlord.Leaderboard.captureCount[name] or 0) > 0 then
            assert(e.Overlord.Leaderboard.captureCount[name] == d.Overlord.Leaderboard.captureCount[name],
                "Replica captures diverged: " .. e.name .. " / " .. name)
        end
    end
    for i = 461, 500 do
        local info = e.Overlord.Leaderboard.playerInfo[names[i]]
        assert(info.race == "Orc" and info.raceSex == 2, "Replica race metadata diverged: " .. e.name)
    end
    assert(e.Overlord.Leaderboard.kills["Unique Tester"] == 4999,
        "The Alliance-only row never reached " .. e.name)
    local stats = e.Overlord.BetaNetwork.stats
    assert((stats.catchupNotRelayed or 0) == 0, "Catch-up was sent through a relay by " .. e.name)
    assert((stats.catchupNotDirect or 0) == 0, "The scheduler aimed at a far peer from " .. e.name)
    assert(stats.dropped == 0, "Catch-up saturated a relay queue at " .. e.name)
end
print("Beta catchup: four replicas converge both ways by direct v6 gossip, no relayed catch-up, no drop")

-- A late joiner on the Alliance channel catches up from its direct neighbours.
local late = client("Late Tester", "alliance")
late.Overlord.Sync.SendSyncRequest = function() return true end
advance(50)
assert(late.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
advance(1800)
heartbeatActive = false
for _, name in ipairs(names) do
    assert(late.Overlord.Leaderboard.kills[name] == d.Overlord.Leaderboard.kills[name],
        "Late joiner never caught up: " .. name)
end
assert(late.Overlord.Leaderboard.kills["Unique Tester"] == 4999, "Late joiner lost the Alliance row")
assert((late.Overlord.BetaNetwork.stats.catchupNotDirect or 0) == 0, "Late joiner aimed at a far peer")
print("Beta catchup: late joiner caught up the full ranking from direct neighbours only")
