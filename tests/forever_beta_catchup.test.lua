-- Real HR/HB/HC/HA, LK/LC/LR admission and monotone merge through three hops.
-- Only WoW's transports, clock and asynchronous snapshot builder are simulated.
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
        assert(transport == "WHISPER" and message:sub(1, 3) == "BF:", "Raw cross-faction reply")
        for _, other in ipairs(clients) do
            if other.name == target then
                other.Overlord.Sync:OnAddonMessage(prefix, message, transport, name)
            end
        end
    end }
    lb.kills, lb.captureCount, lb.captures, lb.playerInfo = {}, {}, {}, {}
    lb.SnapshotCurrentCampaignBeforeReset = function(self, done)
        local snapshot = {
            campaignStart = e.Overlord:GetCurrentCampaignStartTs(),
            scoreBucketEpoch = e.OverlordDB.leaderboardScoreBucketEpoch,
            kills = copy(self.kills), captureCount = copy(self.captureCount),
            captures = copy(self.captures), playerInfo = copy(self.playerInfo),
            killOrder = {}, captureOrder = {},
        }
        for key in pairs(snapshot.kills) do snapshot.killOrder[#snapshot.killOrder + 1] = key end
        for key in pairs(snapshot.captureCount) do snapshot.captureOrder[#snapshot.captureOrder + 1] = key end
        table.sort(snapshot.killOrder)
        table.sort(snapshot.captureOrder)
        e.OverlordDB.leaderboardSnapshot = snapshot
        later(0, function() done(true) end)
        return true
    end
    e.loadfile("SyncHistoryCatchup.lua")()
    e.loadfile("SyncBetaNetwork.lua")()
    clients[#clients + 1] = e
    return e
end
local a = client("Analyst Tester", "alliance")
local b = client("Bridge Tester", "alliance")
local c = client("Gateway Tester", "horde")
local d = client("Veteran Tester", "horde")
b.friends, c.friends = { c }, { b }
-- Discovery establishes return paths. Suppress legacy SR:F here to isolate the
-- complete digest exchange from an unrelated simultaneous legacy response.
for _, e in ipairs(clients) do
    e.savedRequest = e.Overlord.Sync.SendSyncRequest
    e.Overlord.Sync.SendSyncRequest = function() return true end
    assert(e.Overlord.BetaNetwork:Broadcast("NH", "1.0.2") == 1)
end
advance(10)
for _, e in ipairs(clients) do e.Overlord.Sync.SendSyncRequest = e.savedRequest end
local campaign = a.Overlord:GetCurrentCampaignStartTs()
local names = {}
for i = 1, 180 do
    local name = "Player " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(65 + (i - 1) % 26)
    names[#names + 1] = name
    local lb = d.Overlord.Leaderboard
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 2,
        locale = "engb", guild = "Veteran Guild", guildAt = 1790016000 }
    if i <= 10 then
        lb.playerInfo[name].race, lb.playerInfo[name].raceSex = "Orc", 2
    end
    if i <= 120 then lb.captureCount[name], lb.captures[name] = i, {} end
end
a.Overlord.Leaderboard.kills["Unique Tester"] = 7
a.Overlord.Leaderboard.playerInfo["Unique Tester"] = {
    class = "PRIEST", faction = "Alliance", level = 2, locale = "engb" }
-- Deterministic peer selection; peer discovery, trust and routing remain real.
a.Overlord.Sync.GetOnlineCommunityMembers = function() return { d.name } end
d.refuseChannel = true
assert(a.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true))
advance(550)
for _, name in ipairs(names) do
    assert(a.Overlord.Leaderboard.kills[name] == d.Overlord.Leaderboard.kills[name], "Missing late-login kill: " .. name)
    assert(a.Overlord.Leaderboard.captureCount[name] == d.Overlord.Leaderboard.captureCount[name], "Missing late-login capture: " .. name)
    assert(a.Overlord.Leaderboard.playerInfo[name].guild == "Veteran Guild", "Guild metadata lost")
end
assert(d.Overlord.Leaderboard.kills["Unique Tester"] == 7, "Return union never reached veteran")
assert(a.OverlordDB.leaderboardHistoryCatchupAck, "No verified catchup ACK through bridges")
assert(d.Overlord.BetaNetwork.stats.dropped > 0, "Fixture never exercised queue backpressure")
-- The gateways also import the same union: relaying alone must not be mistaken
-- for merging targeted replies intended for another player.
b.Overlord.Sync.GetOnlineCommunityMembers = function() return { a.name } end
c.Overlord.Sync.GetOnlineCommunityMembers = function() return { d.name } end
assert(b.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true))
assert(c.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true))
-- Refresh the discovered paths without another legacy pull.
for _, e in ipairs(clients) do
    e.Overlord.Sync.SendSyncRequest = function() return true end
    e.Overlord.BetaNetwork:Broadcast("NH", "1.0.2")
end
advance(550)
for _, e in ipairs(clients) do
    for _, name in ipairs(names) do
        assert(e.Overlord.Leaderboard.kills[name] == d.Overlord.Leaderboard.kills[name], "Replica kills diverged")
        assert(e.Overlord.Leaderboard.captureCount[name] == d.Overlord.Leaderboard.captureCount[name], "Replica captures diverged")
    end
    assert(e.Overlord.Leaderboard.kills["Unique Tester"] == 7, "Replica lost union")
    for i = 1, 10 do
        local info = e.Overlord.Leaderboard.playerInfo[names[i]]
        assert(info.race == "Orc" and info.raceSex == 2, "Replica race metadata diverged")
    end
end
-- A beta client whose SavedVariables were not loaded must rotate past an empty
-- peer quickly. The same bounded HR exchange then imports a populated peer.
local empty = client("Empty Tester", "alliance")
local fresh = client("Fresh Tester", "alliance")
fresh.Overlord.SavedVariablesLoadedAtLogin = false
empty.Overlord.Sync.IsOnlineCommunitySender = function(_, sender)
    return sender == fresh.name
end
a.Overlord.Sync.IsOnlineCommunitySender = function(_, sender)
    return sender == fresh.name
end
fresh.Overlord.Sync.GetOnlineCommunityMembers = function()
    return { empty.name }
end
assert(fresh.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
advance(28)
assert(fresh.Overlord.Sync._emptySaveCatchupRounds == 1,
    "Blank beta peer incorrectly certified lost leaderboard as recovered")
assert((fresh.OverlordDB.leaderboardHistoryCatchupAck.historyAt or 0) == 0,
    "Blank beta peer incorrectly certified keep and outpost history")
fresh.Overlord.Sync.GetOnlineCommunityMembers = function()
    return { a.name }
end
advance(250)
assert(fresh.Overlord.Leaderboard.kills[names[180]] == 180,
    "Beta missing-save client did not recover from the next populated peer")
assert(not fresh.Overlord.Sync._emptySaveCatchupRounds,
    "Empty-save retry state survived successful recovery")
assert((fresh.OverlordDB.leaderboardHistoryCatchupAck.historyAt or 0) > 0,
    "Populated peer did not certify historical catch-up")
print("Beta catchup: four replicas converge; late Analyst, 180 kills + 120 captures, guilds, three hops, saturated queue, return union and verified ACK OK")
