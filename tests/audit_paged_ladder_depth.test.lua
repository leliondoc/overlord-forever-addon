-- Depth regression for the paged (v6) ladder sweep: a 1500-player weekly ladder must
-- converge completely (rows AND guild totals) although the legacy v4 view is top-500.
-- Kill totals stay <= PLAUSIBLE_SYNC_KILL_CEILING (15000): a higher total is refused by design.
-- Real HR/HB/HC/HA, LK/LC/LR admission and monotone merge through three hops.
-- Only WoW transports and clock are simulated; the sliced snapshot builder is real.
local now, serial, pending, clients = 100, 0, {}, {}
local appliedThisCallback, maxApplied = 0, 0
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
        appliedThisCallback = 0
        event.run()
        maxApplied = math.max(maxApplied, appliedThisCallback)
        assert(appliedThisCallback <= 4, "Unbounded page application")
        steps = steps + 1
        assert(steps < 100000, "Unbounded catchup work")
    end
    now = stop
    for _, c in ipairs(clients) do
        assert(not c.Overlord.Relay.stats.lastError, c.Overlord.Relay.stats.lastError)
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
            other.Overlord.Relay:Receive(wire, name, "BNET", e)
        else
            other.Overlord.Relay:ReceiveFragment(wire, name, "BNET", e)
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
    e.loadfile("SyncRelay.lua")()
    clients[#clients + 1] = e
    return e
end

local a = client("Analyst Tester", "alliance")
local b = client("Bridge Tester", "alliance")
local c = client("Gateway Tester", "horde")
local d = client("Veteran Tester", "horde")
b.friends, c.friends = { c }, { b }
-- Catch-up is point to point (1.2.4): the puller asks its direct cross-faction
-- Battle.net neighbour, never a peer three relays away.
local PULLER, SOURCE = b, c
for _, e in ipairs(clients) do e.Overlord.Sync.SendSyncRequest = function() return true end end
local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", "1.0.35~l9~ld~lr~lp6") end
    later(45, heartbeat)
end
heartbeat()
advance(10)
local N = 1500
local ceiling = SOURCE.Overlord.PLAUSIBLE_SYNC_KILL_CEILING
assert(ceiling == 15000 and SOURCE.Overlord.Leaderboard.KILL_RANK_LIMIT >= N)
local rows, guildTruth = {}, {}
for i = 1, N do
    local n = i - 1
    local name = "Player " .. string.char(65 + math.floor(n / 676))
        .. string.char(97 + math.floor(n / 26) % 26) .. string.char(97 + n % 26)
    local guild = "Depth Guild " .. (i % 7)
    local total = 5 + math.floor((N - i) * 4990 / N)      -- 5 .. 4995, never > ceiling
    assert(total <= ceiling)
    SOURCE.Overlord.Leaderboard.kills[name] = total
    SOURCE.Overlord.Leaderboard.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 60,
        locale = "engb", guild = guild, guildAt = 1790016000, guildAuth = true }
    rows[i] = name
    guildTruth[guild] = (guildTruth[guild] or 0) + total
end
local function guildTotals(e)
    local g = {}
    for name, kills in pairs(e.Overlord.Leaderboard.kills) do
        local info = e.Overlord.Leaderboard.playerInfo[name]
        local guild = info and info.guild or "-"
        g[guild] = (g[guild] or 0) + kills
    end
    return g
end
local done, supported
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok, capable)
    done, supported = ok, capable end, true))
for _ = 1, 40 do
    advance(120)
    if done ~= nil then break end
end
local diag = PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics()
assert(done and supported, "v6 sweep did not complete: " .. diag)
local missing, first = 0, nil
for i, name in ipairs(rows) do
    if PULLER.Overlord.Leaderboard.kills[name] ~= SOURCE.Overlord.Leaderboard.kills[name] then
        missing = missing + 1; first = first or i
    end
end
assert(missing == 0, ("v6 sweep stopped short: %d of %d rows missing (first at rank %s); %s")
    :format(missing, N, tostring(first), diag))
local got = guildTotals(PULLER)
for guild, total in pairs(guildTruth) do
    assert(got[guild] == total, "Guild total diverged for " .. guild)
end
-- The bounded SR:F view of the same ladder is still exactly the top 500 (wire contract).
local lb = SOURCE.Overlord.Leaderboard
local built
lb:SnapshotCurrentCampaignBeforeReset(function(ok) built = ok end)
advance(30)
assert(built, "snapshot did not build")
local snapshot = SOURCE.Overlord.Sync:GetAttestedLeaderboardSnapshot()
assert(snapshot, "no attested snapshot")
local nSnapshot = 0
for _ in pairs(snapshot.kills) do nSnapshot = nSnapshot + 1 end
assert(nSnapshot == N, "attested snapshot must hold the whole ladder, got " .. nSnapshot)
local queue = SOURCE.Overlord.Sync:BuildHistoryCatchupSnapshotQueue(snapshot, snapshot.campaignStart)
local lk = 0
for _, packet in ipairs(queue) do if packet.type == "LK" then lk = lk + 1 end end
assert(lk == lb.NETWORK_KILL_RANK_LIMIT and lk == 500, "SR:F LK view changed: " .. lk)
print(("PASS: v6 swept %d/%d ladder rows and guild totals over a direct link (SR:F view = top %d); %s"):format(N, N, lk, diag))
