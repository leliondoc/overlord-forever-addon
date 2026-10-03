-- 1.4.2 trust and relay rules (audit follow-ups, 2026-10-04):
--   (1) an unsolicited LK for a known subject is clamped to +30 kills + 1/s; the owner's own K is not;
--   (2) a broadcast received over Battle.net waits before its channel copy and a copy heard on
--       the channel cancels it; without one it is forwarded after the hold;
--   (3) class requests heard on the channel are answered with probability ~3/N (N direct peers),
--       requests addressed to this client always;
--   (4) a TV without the capital's capture is deferred and applied once the proof appears; a TV
--       whose proof never comes is dropped.
math.randomseed(7)
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
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
Overlord.PlayerFaction = "Alliance"
Overlord.InstanceSuspended = false
function s:GetChannelId() return 5 end
function s:SendAddonChecked() return true end
function s:SendToBNet() return true end
function s:GetBetaBNetTargets() return {} end

local clock = 1000
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        clock = timer.at
        timer.fn()
    end
    clock = stop
end

local EPOCH = OverlordDB.lastResetTimestamp
local function know(name, total, faction)
    Overlord.Leaderboard.kills[name] = total
    Overlord.Leaderboard.playerInfo[name] = { class = "WARRIOR", faction = faction, level = 60, locale = "enus", guild = "", guildAt = 0 }
end
local function lkRow(name, total, faction)
    local bucket = s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", faction, EPOCH, "", "enus", 0, EPOCH, 60)
        :match(":(B%d+)")
    return table.concat({ name, tostring(total), "WARRIOR", faction, tostring(EPOCH), "enus", "", "0",
        bucket or "B0", "60" }, ":")
end
local serial = 0
local function ownK(name, total, faction)
    serial = serial + 1
    local payload = s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", faction, EPOCH, "", "enus", 0, EPOCH, 60)
    net:Receive("global|k-" .. serial .. "|" .. time() .. "|*|" .. name .. "|K|" .. payload, name, "CHANNEL")
end

-- ===== (1) unsolicited LK bound
know("Far Player", 100, "Horde")
s:OnReceiveLeaderboardKills(lkRow("Far Player", 5000, "Horde"), "Some Peer", "CHANNEL")
local clamped = Overlord.Leaderboard.kills["Far Player"]
assert(clamped == 100 + 30 + 600, "first unsolicited total not clamped to +30 + 600 s allowance: " .. tostring(clamped))
assert((net.stats.unsolicitedTotalsClamped or 0) == 1, "clamp not counted")
advance(20)
s:OnReceiveLeaderboardKills(lkRow("Far Player", 6000, "Horde"), "Some Peer", "CHANNEL")
assert(Overlord.Leaderboard.kills["Far Player"] == clamped + 30 + 20,
    "second unsolicited total not bounded by elapsed time: " .. tostring(Overlord.Leaderboard.kills["Far Player"]))
-- A plausible growth passes untouched.
advance(100)
s:OnReceiveLeaderboardKills(lkRow("Far Player", clamped + 60, "Horde"), "Some Peer", "CHANNEL")
assert(Overlord.Leaderboard.kills["Far Player"] == clamped + 60, "plausible unsolicited growth was altered")
-- The owner's own K is never clamped.
ownK("Far Player", 5000, "Horde")
assert(Overlord.Leaderboard.kills["Far Player"] == 5000, "the owner's own total was clamped: " .. tostring(Overlord.Leaderboard.kills["Far Player"]))

-- ===== (2) bridge hold on Battle.net broadcasts
net.BridgeChannelHold = { 2, 15 }
local before = net:GetQueueSummary().total
local wire1 = "global|c-1|" .. time() .. "|*|Horde Origin,Friend Seven|FR|f1:Horde:" .. time()
assert(net:Receive(wire1, "Friend Seven", "BNET", 7) ~= nil)
assert((net.stats.bridgeForwardsHeld or 0) == 1, "Battle.net broadcast was not held")
assert(net:GetQueueSummary().total == before, "held broadcast was queued at once")
-- The same packet heard on the channel: another bridge did it, ours is cancelled.
net:Receive("global|c-1|" .. time() .. "|*|Horde Origin,Other Hearer|FR|f1:Horde:" .. time(), "Other Hearer", "CHANNEL")
assert((net.stats.bridgeForwardsCancelled or 0) == 1, "channel copy did not cancel the held forward")
advance(16)
assert(net:GetQueueSummary().total == before, "cancelled forward was still queued")
assert((net.stats.bridgeForwardsSent or 0) == 0)
-- Without a channel copy the forward leaves after the hold.
local wire2 = "global|c-2|" .. time() .. "|*|Horde Origin,Friend Seven|FR|f1:Horde:" .. (time() + 1)
local sentBefore = net.stats.sent or 0
net:Receive(wire2, "Friend Seven", "BNET", 7)
assert((net.stats.bridgeForwardsHeld or 0) == 2)
advance(1)
assert(net:GetQueueSummary().total == before and (net.stats.sent or 0) == sentBefore, "forward left before the hold")
advance(15)
assert((net.stats.bridgeForwardsSent or 0) == 1, "held forward was never sent")
assert((net.stats.sent or 0) > sentBefore, "forward not sent after the hold")
net.BridgeChannelHold = { 0, 0 }

-- ===== (3) class answers scale with the population
for i = 1, 30 do
    local name = "Peer " .. string.char(64 + i)
    net.peers[name:lower()] = { name = name, at = GetTime(), via = name, hops = 1, transport = "CHANNEL" }
end
assert(net:CountDirectPeers() >= 30)
Overlord.Leaderboard.GetHotPlayerClass = function(_, name) return "WARRIOR" end
local answers = {}
function s:SendWhisper(kind, payload, target)
    if kind == "CA" then answers[#answers + 1] = target end
    return true
end
local roll = 0.5
local realRandom = math.random
math.random = function(...)
    if select("#", ...) == 0 then return roll end
    return realRandom(...)
end
-- 3/30 = 10 %: a roll of 0.5 is silent, a roll of 0.05 answers.
s:OnReceiveClassRequest("Known Player", "Asker One", "CHANNEL")
advance(3)
assert(#answers == 0, "channel request answered above the 3/N share")
roll = 0.05
s:OnReceiveClassRequest("Known Player", "Asker Two", "CHANNEL")
advance(3)
assert(#answers == 1 and answers[1] == "Asker Two", "channel request not answered inside the 3/N share")
-- A request addressed to this client alone is always answered.
roll = 0.99
s:OnReceiveClassRequest("Known Player", "Asker Three", "WHISPER")
advance(3)
assert(#answers == 2 and answers[2] == "Asker Three", "whispered request was not answered")
math.random = realRandom

-- ===== (4) TV needs the capital's capture
local capitals, victories, capitalCaptured = {}, {}, false
Overlord.Fronts.GetFront = function(_, id) return id == "f1" and { id = "f1", zones = {} } or nil end
Overlord.Fronts.GetCurrentFront = function() return nil end
Overlord.Fronts.GetEnemyCapitalId = function(_, _, frontId) return frontId .. "-capital" end
Overlord.Fronts.GetZone = function(_, zoneId) return capitals[zoneId] end
Overlord.Zones.LocalStateSupportsVictoryTruce = function() return capitalCaptured end
Overlord.Zones.SetVictoryCooldown = function(_, frontId, faction, ts) victories[frontId] = { faction = faction, timestamp = ts } end
Overlord.Zones.ForceSyncFrontToWinner = function() end
Overlord.L.TOTAL_VICTORY_MSG = Overlord.L.TOTAL_VICTORY_MSG or "%s won a front"
Overlord.L.VICTORY_FACTION_ALLIANCE, Overlord.L.VICTORY_FACTION_HORDE = "Alliance", "Horde"
OverlordDB.frontVictories = OverlordDB.frontVictories or {}
local vts = time() - 60
local pendingBefore = #timers
s:OnReceiveTotalVictory("Horde:" .. vts .. ":0:0:f1", "Far Peer", "BETA")
assert(victories.f1 == nil, "a TV without local proof was applied")
assert(#timers == pendingBefore + 1, "a TV without proof was dropped instead of deferred")
-- The capital's capture arrives (relayed C): the retry applies the TV.
capitalCaptured = true
capitals["f1-capital"] = { capturedTime = vts }
advance(6)
assert(victories.f1 and victories.f1.faction == "Horde", "deferred TV was not applied once the proof arrived")
-- A forged TV (no capital capture ever) expires without effect.
capitalCaptured = false
local forgedTs = vts + 100
s:OnReceiveTotalVictory("Alliance:" .. forgedTs .. ":0:0:f1", "Forger", "BETA")
advance(1200)
assert(victories.f1.faction == "Horde" and victories.f1.timestamp == vts, "a TV without proof repainted the front")

print("1.4.2 trust and relay: LK bound, bridge hold, 3/N class answers, TV proof OK")
