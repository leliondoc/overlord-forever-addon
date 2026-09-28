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
local objectives, objectiveSet = {}, {}
for _, front in pairs(d.Overlord.Fronts.Registry or {}) do
    for _, site in ipairs(front.zones or {}) do
        if not objectiveSet[site.id] then
            objectiveSet[site.id] = true
            objectives[#objectives + 1] = site.id
        end
    end
end
while #objectives < 59 do
    local id = string.format("audit_objective_%02d", #objectives + 1)
    objectiveSet[id] = true
    objectives[#objectives + 1] = id
end
table.sort(objectives)
for _, e in ipairs(clients) do
    e.Overlord.GuildKeepSites = {}
    for i, id in ipairs(objectives) do
        e.Overlord.GuildKeepSites[i] = { id = id }
    end
    e.Overlord.Zones.GetZone = function(_, id)
        return objectiveSet[id] and { id = id } or nil
    end
end
local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.BetaNetwork:Broadcast("NH", "1.0.35~lp6") end
    later(45, heartbeat)
end
heartbeat()
advance(10)

local zone = objectives[1]
local names = {}
for i = 1, 500 do
    local n = i - 1
    local name = "Captor " .. string.char(65 + math.floor(n / 676))
        .. string.char(65 + math.floor(n / 26) % 26) .. string.char(65 + n % 26)
    names[i] = name
    local lb = d.Overlord.Leaderboard
    lb.captureCount[name] = math.max(1, 500 - i)
    lb.captures[name] = i == 1 and copy(objectives) or { zone }
    if i <= 100 then lb.kills[name] = i end
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 2,
        locale = "engb", race = "Orc", raceSex = 2,
        raceAt = 1790016000, guild = "Veteran Guild", guildAt = 1790016000 }
end
-- The owner is offline. Its newer guild register (including a departure) must
-- survive three relay hops and correct an old owner-confirmed local record.
d.Overlord.Leaderboard.playerInfo[names[2]].guild = ""
d.Overlord.Leaderboard.playerInfo[names[2]].guildAt = 1790016100
d.Overlord.Leaderboard.playerInfo[names[2]].guildAuth = true
for i = 1, 2 do
    a.Overlord.Leaderboard.kills[names[i]] = i
    a.Overlord.Leaderboard.playerInfo[names[i]] = {
        class = "WARRIOR", faction = "Horde", level = 2,
        locale = "engb", guild = "Previous Guild", guildAt = 1790015900,
        guildAuth = true,
    }
end
local alias = names[1] .. "-Realm"
local veteran = d.Overlord.Leaderboard
veteran.kills[alias] = veteran.kills[names[1]]
veteran.captureCount[alias] = veteran.captureCount[names[1]]
veteran.playerInfo[alias] = copy(veteran.playerInfo[names[1]])
veteran.captures[alias], veteran.captures[names[1]] = {}, {}
for i, id in ipairs(objectives) do
    local target = i <= 30 and veteran.captures[alias] or veteran.captures[names[1]]
    target[#target + 1] = id
end

local snapshotDone
assert(d.Overlord.Leaderboard:SnapshotCurrentCampaignBeforeReset(function(ok) snapshotDone = ok end))
advance(30)
assert(snapshotDone == true, "Snapshot build failed")
local snapshot = assert(d.OverlordDB.leaderboardSnapshot)
assert(#snapshot.captureOrder == 500, "The 500th capture rank was cut from the snapshot")
assert(snapshot.captureCount[names[500]] == 1, "Low capture row lost")
assert(snapshot.playerInfo[alias] == nil and snapshot.playerInfo[names[1]],
    "Overlapping kill/capture aliases duplicated race identity")
assert(#snapshot.captures[names[1]] == #objectives,
    "Snapshot discarded valid map objectives")
local fullLc = assert(d.Overlord.Sync:BuildPagedLeaderboardCapturePayload(snapshot,
    names[1], d.Overlord:GetCurrentCampaignStartTs()))
assert(#fullLc > 250 and #fullLc <= 3500,
    "v6 LC did not need or exceed bounded multi-part framing")

-- A live score burst may temporarily exhaust admission for the very sender
-- serving a page. It must delay a row, never consume it as if received.
local normalBurst = a.Overlord.Sync.SenderBurstShouldDrop
local limitedOnce = false
a.Overlord.Sync.SenderBurstShouldDrop = function(self, sender, kind)
    if kind == "LK" and self._pagedDelivery == nil and not limitedOnce then
        limitedOnce = true
        return true
    end
    return normalBurst and normalBurst(self, sender, kind) or false
end
local done, supported
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
for _ = 1, 50 do
    advance(180)
    if done ~= nil then break end
end
assert(done == true and supported == true,
    a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
for _, index in ipairs({ 1, 26, 41, 100, 500 }) do
    local name = names[index]
    assert(a.Overlord.Leaderboard.captureCount[name] == math.max(1, 500 - index),
        "Missing capture rank " .. index)
    assert(a.Overlord.Leaderboard.captures[name][1] == zone,
        "Missing capture zone " .. index)
    assert(a.Overlord.Leaderboard.playerInfo[name].race == "Orc",
        "Missing race at rank " .. index)
end
assert(#a.Overlord.Leaderboard.captures[names[1]] == #objectives,
    "v6 LC truncated the full objective set")
print("PASS: v6 restored rank 500 capture and race beyond legacy 40 across three hops")
assert(limitedOnce and a.Overlord.Sync._leaderboardPageStats.deferred > 0,
    "The transient admission limit was not exercised")
for i = 1, 100 do
    assert(a.Overlord.Leaderboard.kills[names[i]] == i,
        "A throttled LK row was silently lost at rank " .. i)
end
assert(a.Overlord.Leaderboard.playerInfo[names[1]].guild == "Veteran Guild",
    "A solicited relay snapshot could not correct an old owner-confirmed guild")
assert(a.Overlord.Leaderboard.playerInfo[names[2]].guild == "",
    "A solicited relay lost the offline owner's guild departure")
local function guildTotal(client, wanted)
    local total = 0
    local lb = client.Overlord.Leaderboard
    -- names contains canonical identities; the source also has a test alias.
    for _, name in ipairs(names) do
        if (lb.playerInfo[name] or {}).guild == wanted then
            total = total + (lb.kills[name] or 0)
        end
    end
    return total
end
assert(guildTotal(a, "Veteran Guild") == guildTotal(d, "Veteran Guild"),
    "Opposite-faction views kept different guild totals after catch-up")
a.Overlord.Sync.SenderBurstShouldDrop = normalBurst

local rowsBefore = a.Overlord.Sync._leaderboardPageStats.rows
done, supported = nil, nil
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
advance(1000)
assert(done == true and supported == true, "Identical streams did not certify")
assert(a.Overlord.Sync._leaderboardPageStats.rows == rowsBefore,
    "Identical scores were needlessly replayed")

d.Overlord.Leaderboard:SetPlayerCaptureCount(names[500], 2, true)
local normalSend = a.Overlord.Sync.SendWhisper
local dropped = 0
a.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and payload:match("^6:Q:")
        and payload:find(":LC:", 1, true) then
        dropped = dropped + 1
        return true
    end
    return normalSend(self, kind, payload, target)
end
done, supported = nil, nil
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
advance(1500)
assert(dropped >= 3 and done == false and supported == true,
    "Interrupted LC stream was falsely marked complete")
local saved = assert(a.OverlordDB.leaderboardPageProgress.peers[d.name])
assert(saved.stream == "LC" and saved.bucket == 1,
    "Interrupted typed checkpoint omitted the LC stage")
assert(a.Overlord.Leaderboard.captureCount[names[500]] == 1,
    "Dropped capture row was somehow credited")
a.Overlord.Sync.SendWhisper = normalSend
a.loadfile("SyncLeaderboardPages.lua")()
done, supported = nil, nil
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
advance(2500)
assert(done == true and supported == true,
    a.Overlord.Sync:GetPagedLeaderboardDiagnostics())
assert(a.Overlord.Leaderboard.captureCount[names[500]] == 2,
    "Reloaded LC checkpoint skipped the lower capture row")
print("PASS: identical three-stream round, interrupted LC checkpoint and reload")

d.Overlord.Leaderboard:SetPlayerKills(names[1], 123, true)
local responderSend = d.Overlord.Sync.SendWhisper
local wrongStream = false
d.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if not wrongStream and kind == "HA" and payload:match("^6:P:")
        and payload:sub(-3) == ":LK" then
        wrongStream = true
        return responderSend(self, kind, payload:sub(1, -3) .. "LC", target)
    end
    return responderSend(self, kind, payload, target)
end
done, supported = nil, nil
local retriesBefore = a.Overlord.Sync._leaderboardPageStats.retries
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
advance(2000)
assert(wrongStream and done == true and supported == true,
    "A mismatched stream broke the transfer")
assert(a.Overlord.Sync._leaderboardPageStats.retries > retriesBefore,
    "A wrong-stream page was accepted without retry")
assert(a.Overlord.Leaderboard.kills[names[1]] == 123,
    "Correct retry did not import the LK row")
d.Overlord.Sync.SendWhisper = responderSend
print("PASS: wrong-stream page rejected before LK merge")

d.Overlord.Leaderboard:SetPlayerKills(names[1], 124, true)
a.Overlord.Sync.SenderBurstShouldDrop = function(_, _, kind) return kind == "LK" end
done, supported = nil, nil
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
advance(1500)
assert(done == false and supported == true,
    "Permanent admission pressure pinned a session or falsely completed its page")
assert(a.Overlord.Leaderboard.kills[names[1]] == 123,
    "Admission policy was bypassed under pressure")
a.Overlord.Sync.SenderBurstShouldDrop = normalBurst
done, supported = nil, nil
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
advance(2000)
assert(done == true and a.Overlord.Leaderboard.kills[names[1]] == 124,
    "The checkpoint skipped the previously throttled row")
print("PASS: bounded admission wait preserves rows and resumes the interrupted bucket")

local modernReceive = d.Overlord.Sync.OnPagedLeaderboardMessage
d.Overlord.Sync.OnPagedLeaderboardMessage = function(self, kind, payload, sender, channel)
    if payload:sub(1, 2) == "6:" then return end
    return modernReceive(self, kind, payload, sender, channel)
end
local previousAck = a.OverlordDB.leaderboardHistoryCatchupAck
done, supported = nil, nil
assert(a.Overlord.Sync:StartCompletePagedLeaderboardCatchup(d.name,
    function(ok, capable) done, supported = ok, capable end))
advance(800)
assert(done == false and supported == false,
    "v5-only peer falsely certified the complete v6 ranking")
assert(a.OverlordDB.leaderboardHistoryCatchupAck == previousAck,
    "v5-only result wrote a full history ACK")

a.Overlord.Sync.GetOnlineEuropeanLeaderboardBridgeMembers = function()
    return { d.name }
end
a.Overlord.Sync.GetOnlineCommunityMembers = function()
    return { d.name }
end
local requesterSend = a.Overlord.Sync.SendWhisper
local v4Requested = false
a.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and payload:sub(1, 2) == "4:" then
        v4Requested = true
    end
    return requesterSend(self, kind, payload, target)
end
assert(a.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true))
advance(1600)
assert(v4Requested, "Scheduler omitted v4 LC/LR fallback for a v5-only peer")
a.Overlord.Sync.SendWhisper = requesterSend
d.Overlord.Sync.OnPagedLeaderboardMessage = modernReceive
print("PASS: v5-only peer remains partial, scheduler requests legacy v4 LC/LR")

-- A new client (and a /reload while its history ACK is still absent) starts
-- with the complete paged ranking. The historical v4 exchange remains queued
-- for the next wake, so prioritising ranking does not silently drop GK/history.
local login = client("Login Tester", "alliance")
login.Overlord.Sync.GetOnlineEuropeanLeaderboardBridgeMembers = function()
    return { d.name }
end
local pagedStarted, historyRequested = false, false
login.Overlord.Sync.StartCompletePagedLeaderboardCatchup = function(_, peer, callback)
    assert(peer == d.name)
    pagedStarted = true
    callback(true, true)
    return true
end
login.Overlord.Sync.SendWhisper = function(_, kind, payload)
    if kind == "HR" and payload:sub(1, 2) == "4:" then historyRequested = true end
    return true
end
assert(login.OverlordDB.leaderboardHistoryCatchupAck == nil)
assert(login.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
assert(login.Overlord.Sync._historyCatchupPending.ladderOnly == true,
    "First login without ACK scheduled slow v4 before complete v6")
local loginCampaign = login.Overlord.Sync._historyCatchupPending.campaignId
advance(35)
assert(pagedStarted and not historyRequested,
    "Bootstrap did not start v6 before territorial history")
assert(login.OverlordDB.leaderboardRankFirstCompletedCampaignId == loginCampaign,
    "A completed first v6 sweep did not persist its phase")
local afterSweepReload = client("Completed Tester", "alliance")
afterSweepReload.Overlord.Sync.SendWhisper = function() return true end
afterSweepReload.OverlordDB.leaderboardRankFirstCompletedCampaignId =
    login.OverlordDB.leaderboardRankFirstCompletedCampaignId
assert(afterSweepReload.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
assert(afterSweepReload.Overlord.Sync._historyCatchupPending.ladderOnly == false,
    "Reload after completed v6 starved the still-missing territorial history")
advance(270)
assert(historyRequested,
    "Bootstrap failed to schedule territorial history after the first v6 round")
local reloaded = client("Reload Tester", "alliance")
assert(reloaded.OverlordDB.leaderboardHistoryCatchupAck == nil)
assert(reloaded.Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
assert(reloaded.Overlord.Sync._historyCatchupPending.ladderOnly == true,
    "/reload with no ACK again blocked v6 behind a long v4 round")
print("PASS: no-ACK login and reload start v6 promptly, then retain v4 history")
