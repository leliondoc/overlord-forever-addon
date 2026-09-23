-- Real HR/HB/HC/HA, LK/LC/LR admission and monotone merge through three hops.
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
-- Keep peer discovery alive throughout the deliberately slow 500-row exchange.
-- Isolate HR from legacy SR traffic as in the initial discovery above.
local heartbeatActive = true
local function heartbeat()
    if not heartbeatActive then return end
    for _, e in ipairs(clients) do e.Overlord.BetaNetwork:Broadcast("NH", "1.0.11") end
    later(45, heartbeat)
end
later(45, heartbeat)
local campaign = a.Overlord:GetCurrentCampaignStartTs()
local names = {}
for i = 1, 500 do
    local name = "Player " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(65 + (i - 1) % 26)
    names[#names + 1] = name
    local lb = d.Overlord.Leaderboard
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 2,
        locale = "engb", guild = "Veteran Guild", guildAt = 1790016000 }
    if i > 460 then
        lb.playerInfo[name].race, lb.playerInfo[name].raceSex = "Orc", 2
    end
    if i <= 120 then lb.captureCount[name], lb.captures[name] = i, {} end
end
a.Overlord.Leaderboard.kills["Unique Tester"] = 750
a.Overlord.Leaderboard.playerInfo["Unique Tester"] = {
    class = "PRIEST", faction = "Alliance", level = 2, locale = "engb" }
-- Deterministic peer selection; peer discovery, trust and routing remain real.
a.Overlord.Sync.GetOnlineCommunityMembers = function() return { d.name } end
d.refuseChannel = true
local sendWhisper = d.Overlord.Sync.SendWhisper
d.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "LK" and not d.refusedSnapshotEnqueue then
        d.refusedSnapshotEnqueue = true
        return false
    end
    return sendWhisper(self, kind, payload, target)
end
assert(a.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true))
advance(1600)
for _, name in ipairs(names) do
    assert(a.Overlord.Leaderboard.kills[name] == d.Overlord.Leaderboard.kills[name], "Missing late-login kill: " .. name)
    if (d.Overlord.Leaderboard.captureCount[name] or 0) >= 96 then
        assert(a.Overlord.Leaderboard.captureCount[name] == d.Overlord.Leaderboard.captureCount[name], "Missing late-login capture: " .. name)
    end
    assert(a.Overlord.Leaderboard.playerInfo[name].guild == "Veteran Guild", "Guild metadata lost")
end
assert(d.Overlord.Leaderboard.kills["Unique Tester"] == 750, "Return union never reached veteran")
assert(a.OverlordDB.leaderboardHistoryCatchupAck, "No verified catchup ACK through bridges")
assert(d.refusedSnapshotEnqueue, "Fixture never exercised snapshot backpressure")
for _, e in ipairs(clients) do
    assert(e.Overlord.BetaNetwork.stats.dropped == 0, "Paced catchup saturated a relay queue")
end
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
advance(1600)
for _, e in ipairs(clients) do
    for i = 2, #names do
        local name = names[i]
        assert(e.Overlord.Leaderboard.kills[name] == d.Overlord.Leaderboard.kills[name], "Replica kills diverged")
        if (d.Overlord.Leaderboard.captureCount[name] or 0) >= 96 then
            assert(e.Overlord.Leaderboard.captureCount[name] == d.Overlord.Leaderboard.captureCount[name], "Replica captures diverged")
        end
    end
    assert(e.Overlord.Leaderboard.kills["Unique Tester"] == 750, "Replica lost union")
    for i = 461, 500 do
        local info = e.Overlord.Leaderboard.playerInfo[names[i]]
        assert(info.race == "Orc" and info.raceSex == 2, "Replica race metadata diverged")
    end
end
-- A beta client whose SavedVariables were not loaded must rotate past an empty
-- peer quickly. The same bounded HR exchange then imports a populated peer.
-- Stop the previous fixture's periodic rounds so they cannot inject unrelated
-- cross-faction traffic into the isolated same-faction direct-whisper case.
for _, e in ipairs(clients) do
    e.Overlord.Sync._historyCatchupWakeGeneration =
        (e.Overlord.Sync._historyCatchupWakeGeneration or 0) + 1
    e.Overlord.Sync._historyCatchupPending = nil
    local response = e.Overlord.Sync._historyCatchupResponse
    if response and response.ticker then response.ticker:Cancel() end
    e.Overlord.Sync._historyCatchupResponse = nil
    e.Overlord.Sync._historyCatchupPushInbound = nil
    e.Overlord.Sync.GetOnlineCommunityMembers = function() return {} end
end
heartbeatActive = false
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
advance(1600)
assert(fresh.Overlord.Leaderboard.kills[names[500]] == 500,
    "Beta missing-save client did not recover from the next populated peer")
assert(not fresh.Overlord.Sync._emptySaveCatchupRounds,
    "Empty-save retry state survived successful recovery")
assert((fresh.OverlordDB.leaderboardHistoryCatchupAck.historyAt or 0) > 0,
    "Populated peer did not certify historical catch-up")
-- Different locally retained tails must not change the displayed top or guild total.
for _, e in ipairs({a, b, c, d, fresh}) do
    e.Overlord.Leaderboard:EnsureNetworkHotIndexesPrepared()
end
advance(1)
for _, e in ipairs({a, b, c, d, fresh}) do
    assert(e.Overlord.Leaderboard:StartDisplayCacheBuild())
end
advance(1)
for _, e in ipairs({a, b, c, d, fresh}) do
    local cache = assert(e.Overlord.Leaderboard._displayCache)
    assert(#cache.sortedKills == 500 and cache.sortedKills[1].name == "Unique Tester")
    for _, row in ipairs(cache.sortedKills) do
        assert(row.name ~= names[1], "Rank 501 leaked into the displayed top")
    end
    assert(#cache.sortedGuilds == 1 and cache.sortedGuilds[1].kills == 125249,
        "Replica guild totals included players outside the common top 500")
end

-- Old peers still receive a bounded pull they understand, without a 500-row
-- push request or an impossible digest certification loop.
local legacyResponder = client("Compat Tester", "alliance")
local legacySync = legacyResponder.Overlord.Sync
legacyResponder.OverlordDB.leaderboardSnapshot = copy(a.OverlordDB.leaderboardSnapshot)
legacyResponder.Overlord.Leaderboard._snapshotDirty = false
legacySync.IsOnlineCommunitySender = function() return true end
legacySync.GetSRPayload = function() return nil end
for _, version in ipairs({"2", "3"}) do
    local sent = {}
    legacySync.SendWhisper = function(_, kind, data)
        sent[#sent + 1] = {type = kind, data = data}
        return true
    end
    assert(legacySync:OnHistoryCatchupRequest(table.concat({version,
        a.Overlord:TimestampToCampaignId(campaign), campaign, "plegacy" .. version, 0, 0}, ":"),
        "Legacy Tester", "WHISPER"))
    advance(300)
    local kills = 0
    for _, packet in ipairs(sent) do
        if packet.type == "LK" then kills = kills + 1 end
        assert(packet.type ~= "HB", "Old peer was asked to certify a new top")
    end
    assert(kills == 200 and #sent <= 316, "Legacy reply exceeded its understood scope")
    assert(sent[#sent].type == "HA" and sent[#sent].data:match("^" .. version .. ":")
        and sent[#sent].data:match(":S:0:0$"), "Legacy pull did not terminate cleanly")
end
print("Beta catchup: four replicas converge; late Analyst, 500-player ranking + 25 Horde captures, guilds, three hops, backpressure, paced relay queues, return union and verified ACK OK")
