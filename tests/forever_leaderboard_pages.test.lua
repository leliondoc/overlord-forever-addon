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
for _, e in ipairs(clients) do e.Overlord.Sync.SendSyncRequest = function() return true end end
local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.BetaNetwork:Broadcast("NH", "1.0.35") end
    later(45, heartbeat)
end
heartbeat()
advance(10)
local names = {}
for i = 1, 5000 do
    local n = i - 1
    local name = "Player " .. string.char(65 + math.floor(n / 676))
        .. string.char(65 + math.floor(n / 26) % 26) .. string.char(65 + n % 26)
    names[i] = name
    local lb = d.Overlord.Leaderboard
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 2,
        locale = "engb", guild = "Veteran Guild", guildAt = 1790016000 }
end
local done, supported
local receiver = a.Overlord.Sync.OnReceiveLeaderboardKills
a.Overlord.Sync.OnReceiveLeaderboardKills = function(self, payload, sender, channel)
    appliedThisCallback = appliedThisCallback + 1
    assert(a.Overlord.BetaNetwork:IsRelayedOrigin(sender), "Lost relay provenance during deferred application")
    return receiver(self, payload, sender, channel)
end
local send = d.Overlord.Sync.SendWhisper
local dropped, held, duplicated, corrupted, sendAt, charged = false, nil, false, false, now, 0
d.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if payload:sub(1, 2) == "5:" then
        charged = charged + #payload + 200
        assert(charged <= 500 + (now - sendAt) * 300, "Exceeded global page byte budget")
        local _, op, _, _, seq, part = d.strsplit(":", payload, 7)
        if op == "D" and tonumber(seq) == 2 and tonumber(part) == 2 and not dropped then
            dropped = true
            return true -- Blizzard accepted it; the packet was lost farther away.
        end
        if op == "P" and tonumber(seq) == 3 and not held then
            held = payload
            later(25, function() send(self, kind, payload, target) end)
            return true
        end
        if op == "D" and tonumber(seq) == 4 and tonumber(part) == 1 and not duplicated then
            duplicated = true
            later(3, function() send(self, kind, payload, target) end)
        end
        if op == "D" and tonumber(seq) == 5 and tonumber(part) == 1 and not corrupted then
            corrupted = true
            payload = payload:sub(1, -2) .. (payload:sub(-1) == "X" and "Y" or "X")
        end
    end
    return send(self, kind, payload, target)
end
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok, capable) done, supported = ok, capable end))
for i = 1, 100 do
    advance(180)
    if done ~= nil then break end
end
local diag = a.Overlord.Sync:GetPagedLeaderboardDiagnostics()
assert(done and supported, diag .. " " .. tostring(a.Overlord.Sync._leaderboardPageStats.error))
assert(dropped and held and duplicated and corrupted, "Fault injection never ran")
assert(a.Overlord.Sync._leaderboardPageStats.retries >= 1, "Missing page never retried")
for _, name in ipairs(names) do
    assert(a.Overlord.Leaderboard.kills[name] == d.Overlord.Leaderboard.kills[name], "Missing: " .. name)
    assert(a.Overlord.Leaderboard.playerInfo[name].guild == "Veteran Guild", "Missing guild: " .. name)
end
for _, e in ipairs(clients) do assert(e.Overlord.BetaNetwork.stats.dropped == 0, "Relay overflow") end
assert(a.Overlord.Sync._pagedDelivery == nil, "Leaked authorization")
assert(not a.Overlord.Sync:IsExpectedPagedLeaderboardDelivery("LK", names[1], d.name, "BETA"))
print("PASS: 5,000 filtered LK rows through three relay hops; " .. diag)
d.Overlord.Sync.SendWhisper = send
advance(10)
-- A matching second sweep needs a single response, without bucket polling.
local before = a.Overlord.Sync._leaderboardPageStats.rows
local pagesBefore, matchingReplies = a.Overlord.Sync._leaderboardPageStats.pages, 0
d.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if payload:sub(1, 2) == "5:" then matchingReplies = matchingReplies + 1 end
    return send(self, kind, payload, target)
end
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(1200)
assert(done == true, a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(a.Overlord.Sync._leaderboardPageStats.rows == before, "Equal buckets retransmitted scores")
assert(matchingReplies == 1 and a.Overlord.Sync._leaderboardPageStats.pages == pagesBefore,
    "Equal ranking did not use a single digest reply")
d.Overlord.Sync.SendWhisper = send
-- Score/rank changes affect a bucket, never the page cursor of another bucket.
d.Overlord.Leaderboard:SetPlayerKills(names[1], 4999, true)
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(1800)
assert(done == true, a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(a.Overlord.Leaderboard.kills[names[1]] == 4999, "Changed score was skipped")
assert(a.Overlord.Sync._leaderboardPageStats.rows - before < 200, "Unchanged buckets re-sent in delta sweep")
-- Interrupted transfer and reload resume the incomplete bucket from its start.
d.Overlord.Leaderboard:SetPlayerKills(names[2], 4998, true)
local blockedBucket
local sendRequest = a.Overlord.Sync.SendWhisper
a.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    local _, op, _, _, seq, bucket = a.strsplit(":", payload, 7)
    if kind == "HR" and op == "Q" and tonumber(seq) == 5 then
        blockedBucket = tonumber(bucket)
        return true
    end
    return sendRequest(self, kind, payload, target)
end
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(1800)
assert(done == false and blockedBucket, "Disconnected transfer did not terminate")
assert(a.OverlordDB.leaderboardPageProgress.peers[d.name].bucket == blockedBucket)
a.Overlord.Sync.SendWhisper = sendRequest
a.loadfile("SyncLeaderboardPages.lua")()
local firstRequest
a.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and payload:sub(1, 4) == "5:Q:" and not firstRequest then
        firstRequest = { a.strsplit(":", payload) }
    end
    return sendRequest(self, kind, payload, target)
end
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(1800)
assert(done == true, a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(tonumber(firstRequest[6]) == blockedBucket and firstRequest[7] == "-", "Unsafe resumed cursor")
assert(a.Overlord.Leaderboard.kills[names[2]] == 4998)
a.Overlord.Sync.SendWhisper = sendRequest
-- Legacy endpoints do not pretend to support the extended ranking.
local handler = d.Overlord.Sync.OnPagedLeaderboardMessage
d.Overlord.Sync.OnPagedLeaderboardMessage = nil
done, supported = nil, nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok, capable) done, supported = ok, capable end))
advance(212)
local waitingDiag = a.Overlord.Sync:GetPagedLeaderboardDiagnostics()
assert(done == nil and waitingDiag:find("awaiting reply", 1, true)
    and waitingDiag:find("parts=0/?", 1, true), "A silent peer was presented as receiving: " .. waitingDiag)
local waitBeforePause = waitingDiag:match("timeout=(%d+)s")
a.InCombatLockdown = function() return true end
advance(60)
local pausedDiag = a.Overlord.Sync:GetPagedLeaderboardDiagnostics()
assert(done == nil and pausedDiag:find("paused: combat/instance", 1, true)
    and pausedDiag:match("timeout=(%d+)s") == waitBeforePause,
    "Combat wait was hidden or consumed the response timeout: " .. pausedDiag)
a.InCombatLockdown = function() return false end
advance(188)
assert(done == false and supported == false, "Old endpoint did not fall back")
assert(not a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function() error("negative cache") end))
d.Overlord.Sync.OnPagedLeaderboardMessage = handler
print("PASS: delta buckets, interrupted/reloaded checkpoint, legacy fallback; max rows/callback=" .. maxApplied)

advance(700)
-- Valid page framing is not permission to import invalid LK claims.
local serialize = d.Overlord.Sync.BuildPagedLeaderboardKillPayload
local invalid = { [names[33]] = 1, [names[34]] = 2, [names[35]] = 3, [names[36]] = 4 }
for name in pairs(invalid) do d.Overlord.Leaderboard:SetPlayerKills(name, 4990, true) end
d.Overlord.Sync.BuildPagedLeaderboardKillPayload = function(self, snapshot, name, wireEpoch)
    local payload = serialize(self, snapshot, name, wireEpoch)
    if not payload or not invalid[name] then return payload end
    local fields = { d.strsplit(":", payload) }
    if invalid[name] == 1 then fields[2] = "10001" end
    if invalid[name] == 2 then fields[10] = "999" end
    if invalid[name] == 3 then fields[5] = tostring(wireEpoch - 604800) end
    if invalid[name] == 4 then fields[9] = "B" .. tostring(wireEpoch - 604800) end
    return table.concat(fields, ":")
end
done = nil
local rejectedBefore = a.Overlord.Sync._leaderboardPageStats.rejected
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(2000)
assert(done == true, a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
for i = 33, 36 do assert(a.Overlord.Leaderboard.kills[names[i]] == i, "Invalid LK bypassed filters: " .. i) end
assert(a.Overlord.Sync._leaderboardPageStats.rejected >= rejectedBefore + 4)
d.Overlord.Sync.BuildPagedLeaderboardKillPayload = serialize

-- Combat stops application; an expired responder snapshot must reset the cursor.
d.loadfile("SyncLeaderboardPages.lua")() -- remove the deliberately poisoned cached wire profile
local inCombat, sendsDuringCombat = false, 0
a.InCombatLockdown = function() return inCombat end
a.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if inCombat and payload:sub(1, 2) == "5:" then sendsDuringCombat = sendsDuringCombat + 1 end
    return sendRequest(self, kind, payload, target)
end
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(2)
inCombat = true
local rowsBeforeCombat = a.Overlord.Sync._leaderboardPageStats.rows
advance(400)
assert(done == nil, "Combat incorrectly exhausted receive deadline")
assert(sendsDuringCombat == 0 and a.Overlord.Sync._leaderboardPageStats.rows == rowsBeforeCombat, "Catchup work during combat")
inCombat = false
advance(600)
assert(done == false, "Expired immutable responder profile was silently replaced")
advance(400)
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(2000)
assert(done == true, a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
for i = 33, 36 do assert(a.Overlord.Leaderboard.kills[names[i]] == 4990, "Reset bucket skipped a player") end
a.Overlord.Sync.SendWhisper = sendRequest

-- A campaign switch invalidates outstanding pages before any more application.
d.Overlord.Leaderboard:SetPlayerKills(names[40], 4990, true)
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
advance(3)
local campaign = a.Overlord.GetCurrentCampaignStartTs
local previousEpoch = a.Overlord:GetCurrentCampaignStartTs()
a.Overlord.GetCurrentCampaignStartTs = function() return previousEpoch + 604800 end
local rowsAtReset = a.Overlord.Sync._leaderboardPageStats.rows
advance(10)
assert(done == false and a.Overlord.Sync._leaderboardPageStats.rows == rowsAtReset, "Stale campaign imported")
a.Overlord.GetCurrentCampaignStartTs = campaign
print("PASS: score/level/epoch/bucket filters, combat pause, expired snapshot and campaign cancellation")

advance(400)
-- Both peers can pull at once; sending a request must not lock out its reply.
a.Overlord.Leaderboard:SetPlayerKills(names[10], 5000, true)
d.Overlord.Leaderboard:SetPlayerKills(names[11], 4999, true)
local reverseDone
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
assert(d.Overlord.Sync:StartPagedLeaderboardCatchup(a.name, function(ok) reverseDone = ok end))
advance(2500)
assert(done == true and reverseDone == true, "Simultaneous pulls deadlocked: "
    .. a.Overlord.Sync:GetPagedLeaderboardDiagnostics() .. " / " .. d.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(a.Overlord.Leaderboard.kills[names[11]] == 4999 and d.Overlord.Leaderboard.kills[names[10]] == 5000)

-- The two cross-faction gateways remain busy for the entire pull. A quiet-lane
-- prerequisite used to prevent HB pages from leaving the gateways at all.
d.Overlord.Leaderboard:SetPlayerKills(names[12], 4997, true)
local pressureUntil = now + 900
local pressureSerial = 0
local function pressure()
    if now >= pressureUntil then return end
    pressureSerial = pressureSerial + 1
    for _, bridge in ipairs({ b, c }) do
        bridge.Overlord.BetaNetwork:Send('ZS', 'busy-bridge-' .. pressureSerial)
    end
    later(0.2, pressure)
end
pressure()
done = nil
assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(d.name, function(ok) done = ok end))
for i = 1, 8 do
    advance(100)
    if done ~= nil then break end
end
assert(done == true and a.Overlord.Leaderboard.kills[names[12]] == 4997,
    'Paged catch-up failed through busy Horde/Alliance bridges: ' .. a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(now < pressureUntil, 'Catch-up only finished after ordinary traffic stopped')
pressureUntil = now
advance(180)
print('PASS: paged cross-faction catch-up completes while both gateways remain saturated')

-- Exercise the production scheduler, including automatic fallback to v4.
a.Overlord.Sync.GetOnlineEuropeanLeaderboardBridgeMembers = function() return { d.name } end
a.Overlord.Sync.GetOnlineCommunityMembers = function() return { d.name } end
local sawPaged, sawLegacy = false, false
a.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" then
        if payload:sub(1, 2) == "5:" then sawPaged = true end
        if payload:sub(1, 2) == "4:" then sawLegacy = true end
    end
    return sendRequest(self, kind, payload, target)
end
d.Overlord.Sync.OnPagedLeaderboardMessage = nil
assert(a.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true))
advance(700)
assert(sawPaged and sawLegacy, "Production scheduler failed to probe/fall back")
print("PASS: simultaneous cross-faction pulls and scheduled v4 fallback")
