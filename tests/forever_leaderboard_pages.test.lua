-- Real paged HR/HA/HB, LK admission and monotone merge between direct neighbours.
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
local names = {}
for i = 1, 5000 do
    local n = i - 1
    local name = "Player " .. string.char(65 + math.floor(n / 676))
        .. string.char(97 + math.floor(n / 26) % 26) .. string.char(97 + n % 26)
    names[i] = name
    local lb = SOURCE.Overlord.Leaderboard
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 60,
        locale = "engb", guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true }
end
local done, supported
local receiver = PULLER.Overlord.Sync.OnReceiveLeaderboardKills
PULLER.Overlord.Sync.OnReceiveLeaderboardKills = function(self, payload, sender, channel)
    appliedThisCallback = appliedThisCallback + 1
    assert(not PULLER.Overlord.Relay:IsRelayedOrigin(sender), "A direct page was presented as relayed")
    return receiver(self, payload, sender, channel)
end
local send = SOURCE.Overlord.Sync.SendWhisper
local dropped, held, duplicated, corrupted, sendAt, charged = false, nil, false, false, now, 0
SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if payload:sub(1, 2) == "5:" then
        charged = charged + #payload + 200
        assert(charged <= 500 + (now - sendAt) * 300, "Exceeded global page byte budget")
        local _, op, _, _, seq, part = SOURCE.strsplit(":", payload, 7)
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
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok, capable) done, supported = ok, capable end))
for i = 1, 100 do
    advance(180)
    if done ~= nil then break end
end
local diag = PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics()
assert(done and supported, diag .. " " .. tostring(PULLER.Overlord.Sync._leaderboardPageStats.error))
assert(dropped and held and duplicated and corrupted, "Fault injection never ran")
assert(PULLER.Overlord.Sync._leaderboardPageStats.retries >= 1, "Missing page never retried")
for _, name in ipairs(names) do
    assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "Missing: " .. name)
    assert(PULLER.Overlord.Leaderboard.playerInfo[name].guild == "Veteran Guild", "Missing guild: " .. name)
end
for _, e in ipairs(clients) do assert(e.Overlord.Relay.stats.dropped == 0, "Relay overflow") end
assert(PULLER.Overlord.Sync._pagedDelivery == nil, "Leaked authorization")
assert(not PULLER.Overlord.Sync:IsExpectedPagedLeaderboardDelivery("LK", names[1], SOURCE.name, "BETA"))
print("PASS: 5,000 filtered LK rows over a direct cross-faction Battle.net link; " .. diag)
SOURCE.Overlord.Sync.SendWhisper = send
advance(10)
-- A matching second sweep needs a single response, without bucket polling.
local before = PULLER.Overlord.Sync._leaderboardPageStats.rows
local pagesBefore, matchingReplies = PULLER.Overlord.Sync._leaderboardPageStats.pages, 0
SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if payload:sub(1, 2) == "5:" then matchingReplies = matchingReplies + 1 end
    return send(self, kind, payload, target)
end
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(1200)
assert(done == true, PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(PULLER.Overlord.Sync._leaderboardPageStats.rows == before, "Equal buckets retransmitted scores")
assert(matchingReplies == 1 and PULLER.Overlord.Sync._leaderboardPageStats.pages == pagesBefore,
    "Equal ranking did not use a single digest reply")
SOURCE.Overlord.Sync.SendWhisper = send
-- Score/rank changes affect a bucket, never the page cursor of another bucket.
SOURCE.Overlord.Leaderboard:SetPlayerKills(names[1], 4999, true)
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(1800)
assert(done == true, PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(PULLER.Overlord.Leaderboard.kills[names[1]] == 4999, "Changed score was skipped")
assert(PULLER.Overlord.Sync._leaderboardPageStats.rows - before < 200, "Unchanged buckets re-sent in delta sweep")
-- Interrupted transfer and reload resume the incomplete bucket from its start.
SOURCE.Overlord.Leaderboard:SetPlayerKills(names[2], 4998, true)
local blockedBucket
local sendRequest = PULLER.Overlord.Sync.SendWhisper
PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    local _, op, _, _, seq, bucket = PULLER.strsplit(":", payload, 7)
    if kind == "HR" and op == "Q" and tonumber(seq) == 5 then
        blockedBucket = tonumber(bucket)
        return true
    end
    return sendRequest(self, kind, payload, target)
end
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(1800)
assert(done == false and blockedBucket, "Disconnected transfer did not terminate")
assert(PULLER.OverlordDB.leaderboardPageProgress.shared.bucket == blockedBucket)
PULLER.Overlord.Sync.SendWhisper = sendRequest
PULLER.loadfile("SyncLeaderboardPages.lua")()
local firstRequest
PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and payload:sub(1, 4) == "5:Q:" and not firstRequest then
        firstRequest = { PULLER.strsplit(":", payload) }
    end
    return sendRequest(self, kind, payload, target)
end
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(1800)
assert(done == true, PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(tonumber(firstRequest[6]) == blockedBucket and firstRequest[7] == "-", "Unsafe resumed cursor")
assert(PULLER.Overlord.Leaderboard.kills[names[2]] == 4998)
PULLER.Overlord.Sync.SendWhisper = sendRequest
-- Legacy endpoints do not pretend to support the extended ranking.
local handler = SOURCE.Overlord.Sync.OnPagedLeaderboardMessage
SOURCE.Overlord.Sync.OnPagedLeaderboardMessage = nil
done, supported = nil, nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok, capable) done, supported = ok, capable end))
advance(212)
local waitingDiag = PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics()
assert(done == nil and waitingDiag:find("awaiting reply", 1, true)
    and waitingDiag:find("parts=0/?", 1, true), "A silent peer was presented as receiving: " .. waitingDiag)
local waitBeforePause = waitingDiag:match("timeout=(%d+)s")
PULLER.InCombatLockdown = function() return true end
advance(60)
local pausedDiag = PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics()
assert(done == nil and pausedDiag:find("paused: combat/instance", 1, true)
    and pausedDiag:match("timeout=(%d+)s") == waitBeforePause,
    "Combat wait was hidden or consumed the response timeout: " .. pausedDiag)
PULLER.InCombatLockdown = function() return false end
advance(188)
assert(done == false and supported == false, "Old endpoint did not fall back")
assert(not PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function() error("negative cache") end))
SOURCE.Overlord.Sync.OnPagedLeaderboardMessage = handler
print("PASS: delta buckets, interrupted/reloaded checkpoint, legacy fallback; max rows/callback=" .. maxApplied)

advance(700)
-- Valid page framing is not permission to import invalid LK claims.
local serialize = SOURCE.Overlord.Sync.BuildPagedLeaderboardKillPayload
local invalid = { [names[33]] = 1, [names[34]] = 2, [names[35]] = 3, [names[36]] = 4 }
for name in pairs(invalid) do SOURCE.Overlord.Leaderboard:SetPlayerKills(name, 4990, true) end
SOURCE.Overlord.Sync.BuildPagedLeaderboardKillPayload = function(self, snapshot, name, wireEpoch)
    local payload = serialize(self, snapshot, name, wireEpoch)
    if not payload or not invalid[name] then return payload end
    local fields = { SOURCE.strsplit(":", payload) }
    if invalid[name] == 1 then fields[2] = "15001" end
    if invalid[name] == 2 then fields[10] = "999" end
    if invalid[name] == 3 then fields[5] = tostring(wireEpoch - 604800) end
    if invalid[name] == 4 then fields[9] = "B" .. tostring(wireEpoch - 604800) end
    return table.concat(fields, ":")
end
done = nil
local rejectedBefore = PULLER.Overlord.Sync._leaderboardPageStats.rejected
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(2000)
assert(done == true, PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
for i = 33, 36 do assert(PULLER.Overlord.Leaderboard.kills[names[i]] == i, "Invalid LK bypassed filters: " .. i) end
assert(PULLER.Overlord.Sync._leaderboardPageStats.rejected >= rejectedBefore + 4)
SOURCE.Overlord.Sync.BuildPagedLeaderboardKillPayload = serialize

-- Combat stops application; an expired responder snapshot must reset the cursor.
SOURCE.loadfile("SyncLeaderboardPages.lua")() -- remove the deliberately poisoned cached wire profile
local inCombat, sendsDuringCombat = false, 0
PULLER.InCombatLockdown = function() return inCombat end
PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if inCombat and payload:sub(1, 2) == "5:" then sendsDuringCombat = sendsDuringCombat + 1 end
    return sendRequest(self, kind, payload, target)
end
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(2)
inCombat = true
local rowsBeforeCombat = PULLER.Overlord.Sync._leaderboardPageStats.rows
advance(400)
assert(done == nil, "Combat incorrectly exhausted receive deadline")
assert(sendsDuringCombat == 0 and PULLER.Overlord.Sync._leaderboardPageStats.rows == rowsBeforeCombat, "Catchup work during combat")
inCombat = false
advance(600)
assert(done == false, "Expired immutable responder profile was silently replaced")
advance(400)
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(2000)
assert(done == true, PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
for i = 33, 36 do assert(PULLER.Overlord.Leaderboard.kills[names[i]] == 4990, "Reset bucket skipped a player") end
PULLER.Overlord.Sync.SendWhisper = sendRequest

-- A campaign switch invalidates outstanding pages before any more application.
SOURCE.Overlord.Leaderboard:SetPlayerKills(names[40], 4990, true)
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(3)
local campaign = PULLER.Overlord.GetCurrentCampaignStartTs
local previousEpoch = PULLER.Overlord:GetCurrentCampaignStartTs()
PULLER.Overlord.GetCurrentCampaignStartTs = function() return previousEpoch + 604800 end
local rowsAtReset = PULLER.Overlord.Sync._leaderboardPageStats.rows
advance(10)
assert(done == false and PULLER.Overlord.Sync._leaderboardPageStats.rows == rowsAtReset, "Stale campaign imported")
local progressAfter = PULLER.OverlordDB.leaderboardPageProgress
assert(not (progressAfter and progressAfter.epoch == previousEpoch + 604800 and progressAfter.shared),
    "A pull of the finished campaign seeded the new campaign's sweep position")
PULLER.Overlord.GetCurrentCampaignStartTs = campaign
print("PASS: score/level/epoch/bucket filters, combat pause, expired snapshot and campaign cancellation")

advance(400)
-- Both peers can pull at once; sending a request must not lock out its reply.
PULLER.Overlord.Leaderboard:SetPlayerKills(names[10], 5000, true)
SOURCE.Overlord.Leaderboard:SetPlayerKills(names[11], 4999, true)
local reverseDone
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
assert(SOURCE.Overlord.Sync:StartPagedLeaderboardCatchup(PULLER.name, function(ok) reverseDone = ok end))
advance(2500)
assert(done == true and reverseDone == true, "Simultaneous pulls deadlocked: "
    .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics() .. " / " .. SOURCE.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(PULLER.Overlord.Leaderboard.kills[names[11]] == 4999 and SOURCE.Overlord.Leaderboard.kills[names[10]] == 5000)

-- The two cross-faction gateways remain busy for the entire pull. A quiet-lane
-- prerequisite used to prevent HB pages from leaving the gateways at all.
SOURCE.Overlord.Leaderboard:SetPlayerKills(names[12], 4997, true)
local pressureUntil = now + 900
local pressureSerial = 0
local function pressure()
    if now >= pressureUntil then return end
    pressureSerial = pressureSerial + 1
    for _, bridge in ipairs({ b, c }) do
        bridge.Overlord.Relay:Send('ZS', 'busy-bridge-' .. pressureSerial)
    end
    later(0.2, pressure)
end
pressure()
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
for i = 1, 8 do
    advance(100)
    if done ~= nil then break end
end
assert(done == true and PULLER.Overlord.Leaderboard.kills[names[12]] == 4997,
    'Paged catch-up failed through busy Horde/Alliance bridges: ' .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(now < pressureUntil, 'Catch-up only finished after ordinary traffic stopped')
pressureUntil = now
advance(180)
print('PASS: paged cross-faction catch-up completes while both gateways remain saturated')

-- The production scheduler asks a direct neighbour, in v8 only (1.8.1: every
-- neighbour it asks advertises capability 9).
local sawV8, sawOther = false, false
PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" then
        if payload:sub(1, 2) == "8:" then sawV8 = true else sawOther = true end
    end
    return sendRequest(self, kind, payload, target)
end
assert(PULLER.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true))
advance(700)
assert(sawV8 and not sawOther, "Production scheduler did not use v8 only")
print("PASS: simultaneous cross-faction pulls and v8-only scheduler")

-- 1.3.3: one sweep position shared by every neighbour. A pull interrupted with
-- one peer resumes with the next peer at the same bucket, and the buckets it
-- already certified count toward the end of the stream (v7 bucket resume, asked
-- explicitly: v8 keeps only the stream).
advance(400)
-- Stop the scheduler's periodic rounds: this section drives the pulls itself.
PULLER.Overlord.Sync._historyCatchupWakeGeneration = (PULLER.Overlord.Sync._historyCatchupWakeGeneration or 0) + 1000
-- The scheduler's own round may still be sweeping (its first peer is drawn at random):
-- end the round (or cancelling its pull would start its next attempt) and its pull,
-- and start this section from a fresh sweep position.
local runningRound = PULLER.Overlord.Sync._historyCatchupPending
if runningRound then runningRound.terminal = true end
PULLER.Overlord.Sync._historyCatchupPending = nil
PULLER.Overlord.Sync:CancelPagedLeaderboardCatchup()
PULLER.OverlordDB.leaderboardPageProgress = nil
PULLER.Overlord.Sync.SendWhisper = sendRequest
local SECOND = a -- same channel as the puller: a second direct neighbour
for _, field in ipairs({ "kills", "playerInfo", "captureCount" }) do
    SECOND.Overlord.Leaderboard[field] = copy(SOURCE.Overlord.Leaderboard[field])
end
for i = 1, 1500 do
    local value = (SOURCE.Overlord.Leaderboard.kills[names[i]] or 0) + 1
    SOURCE.Overlord.Leaderboard:SetPlayerKills(names[i], value, true)
    SECOND.Overlord.Leaderboard:SetPlayerKills(names[i], value, true)
end
local cutSeq, lkBuckets, firstResumed = 40, {}, nil
PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and payload:sub(1, 4) == "7:Q:" then
        local f = { PULLER.strsplit(":", payload) }
        if target == SOURCE.name and tonumber(f[5]) >= cutSeq then return true end -- peer gone
        if target == SECOND.name then
            firstResumed = firstResumed or { stream = f[10], bucket = tonumber(f[6]) }
            if f[10] == "LK" and f[7] == "-" then lkBuckets[tonumber(f[6])] = true end
        end
    end
    return sendRequest(self, kind, payload, target)
end
done = nil
local started, why = PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end, true, true)
assert(started, tostring(why) .. " " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
for _ = 1, 20 do advance(100); if done ~= nil then break end end
assert(done == false, "the cut pull did not end")
local shared = PULLER.OverlordDB.leaderboardPageProgress.shared
assert(shared and shared.stream == "LK" and (shared.done or 0) >= 5,
    "no shared position after the cut pull: " .. tostring(shared and shared.done))
local resumeBucket, certified = shared.bucket, shared.done
-- Badge: the cut pull already brought rows; the sweep keeps counting them.
local pageStats = PULLER.Overlord.Sync._leaderboardPageStats
local cutChanged = (pageStats.changedRows or 0) - (pageStats.sweepBase or 0)
assert(pageStats.sweepBase and cutChanged > 0, "the cut pull changed no row or lost its sweep start")
done = nil
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SECOND.name, function(ok) done = ok end, true, true))
for _ = 1, 40 do advance(100); if done ~= nil then break end end
assert(done == true, "the second neighbour did not finish the sweep: "
    .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(firstResumed and firstResumed.stream == "LK" and firstResumed.bucket == resumeBucket,
    "the next neighbour restarted the sweep instead of resuming it")
local asked = 0
for _ in pairs(lkBuckets) do asked = asked + 1 end
assert(asked == 64 - certified, "buckets certified with the first neighbour were asked again: "
    .. asked .. " of " .. (64 - certified))
for i = 1, 1500 do
    assert(PULLER.Overlord.Leaderboard.kills[names[i]] == SOURCE.Overlord.Leaderboard.kills[names[i]],
        "missing after the shared sweep: " .. names[i])
end
local final = PULLER.OverlordDB.leaderboardPageProgress.shared
assert(final.stream == "LK" and final.bucket == 1 and final.done == 0, "a finished sweep did not restart from the top")
-- The badge judges the whole sweep (both neighbours), not only its last pull.
assert(pageStats.lastSweepFull == true and pageStats.sweepBase == nil, "the resumed sweep was not a whole one")
-- 1,500 rows changed in all, some with each neighbour.
assert(pageStats.lastSweepChanged >= 1500,
    "the sweep total left out the rows of its first pull: " .. tostring(pageStats.lastSweepChanged)
    .. " (first pull " .. cutChanged .. ")")
PULLER.Overlord.Sync.SendWhisper = sendRequest
print("PASS: sweep position shared across neighbours (" .. certified .. " buckets certified, resumed at " .. resumeBucket .. ")")

-- 1.7.1 CPU: a responder whose ranking keeps changing (a bridge, a busy fight) serves
-- the page profile of a copy younger than 2 minutes instead of rebuilding the copy
-- and its profile for every requester; an older copy is rebuilt.
do
    local responderStats = SOURCE.Overlord.Sync._leaderboardPageStats
    PULLER.OverlordDB.leaderboardPageProgress = nil
    advance(400)
    -- First pull: the responder builds a fresh copy and profile.
    SOURCE.Overlord.Leaderboard:SetPlayerKills(names[5], 4990, true)
    done = nil
    assert(PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
    advance(20)
    PULLER.Overlord.Sync:CancelPagedLeaderboardCatchup()
    advance(5)
    local reusedBefore = responderStats.profileReused or 0
    -- Changed again 30 s later: the next requester gets the 30-second-old profile.
    SOURCE.Overlord.Leaderboard:SetPlayerKills(names[6], 4991, true)
    PULLER.OverlordDB.leaderboardPageProgress = nil
    done = nil
    assert(PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
    for _ = 1, 40 do advance(100); if done ~= nil then break end end
    assert(done == true, "pull on a reused profile failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
    assert((responderStats.profileReused or 0) == reusedBefore + 1, "a recent profile was rebuilt")
    assert(PULLER.Overlord.Leaderboard.kills[names[5]] == 4990, "the reused profile lost an older change")
    -- More than 2 minutes later the copy is rebuilt and carries the newer change.
    PULLER.OverlordDB.leaderboardPageProgress = nil
    done = nil
    assert(PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
    for _ = 1, 40 do advance(100); if done ~= nil then break end end
    assert(done == true and PULLER.Overlord.Leaderboard.kills[names[6]] == 4991,
        "an old profile was served again: " .. tostring(PULLER.Overlord.Leaderboard.kills[names[6]]))
end
print("PASS: recent page profile reused, older copy rebuilt")
