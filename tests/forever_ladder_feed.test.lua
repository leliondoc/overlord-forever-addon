-- 2.5.0: the ranking feed. A pull leaves a subscription behind: the responder then whispers the
-- rows of its ranking that move to the requester, which passes them on to its own subscribers.
-- Rows are taken only from a peer we asked ourselves, through the acceptance of a page row.
-- Real HR/HA/HB, relay and page acceptance; only WoW transports and the clock are simulated.
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
        assert(steps < 200000, "Unbounded feed work")
    end
    now = stop
    for _, c in ipairs(clients) do
        assert(not c.Overlord.Relay.stats.lastError, c.Overlord.Relay.stats.lastError)
        assert(not c.Overlord.Sync._leaderboardPageStats.feedError, c.Overlord.Sync._leaderboardPageStats.feedError)
    end
end
local wire = {}
-- Every whisper as the game is handed it (the relay's pieces).
local raw = {}
local function client(name, version)
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    e.loadfile("Leaderboard.lua")()
    e.name, e.channel, e.friends = name, "alliance", {}
    e.GetTime = function() return now end
    e.time = function() return 1790017000 + math.floor(now) end
    e.GetServerTime = e.time
    e.UnitName = function() return name end
    e.UnitFullName = function() return name, "" end
    e.GetUnitName = e.UnitName
    e.UnitFactionGroup = function() return "Alliance" end
    e.Overlord.PlayerFaction = "Alliance"
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
    e.C_Club = { GetSubscribedClubs = function() return {} end }
    e.Enum = { ClubType = { Character = 1 } }
    local s, lb = e.Overlord.Sync, e.Overlord.Leaderboard
    s.GetPlayerFullName = function() return name end
    s.GetChannelId = function() return 1 end
    s.GetBetaBNetTargets = function() return e.friends end
    s.SendToChannel = function(_, kind, fragment)
        for _, other in ipairs(clients) do
            if other ~= e then
                other.Overlord.Sync:OnAddonMessage("OverlordF", kind .. ":" .. fragment, "CHANNEL", name)
            end
        end
        return true
    end
    e.securecall = function(fn, ...) return fn(...) end
    e.C_ChatInfo = { SendAddonMessage = function(prefix, message, transport, target)
        assert(transport == "WHISPER", "Invalid direct transport")
        assert(#message <= 255, "whisper over 255 bytes")
        raw[#raw + 1] = { from = name, to = target, message = message, at = now }
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
    s.SendSyncRequest = function() return true end
    -- The feed runs while the channel does not carry (the directory's own rule).
    e.directoryActive = true
    e.Overlord.ChannelDirectory = { IsActive = function() return e.directoryActive end }
    e.Overlord.Version = version or "2.5.0"
    -- Every ranking message this client whispers, as the relay is handed it.
    local send = s.SendWhisper
    s.SendWhisper = function(self, kind, payload, target)
        wire[#wire + 1] = { from = name, to = target, kind = kind, payload = payload, at = now }
        return send(self, kind, payload, target)
    end
    clients[#clients + 1] = e
    return e
end
local function info(class)
    return { class = class or "WARRIOR", faction = "Alliance", level = 60, locale = "engb",
        guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true, race = "Human", raceSex = 2, raceAt = 1 }
end
local function feedOf(e) return e.Overlord.Sync._leaderboardFeed end
local function statsOf(e) return e.Overlord.Sync._leaderboardPageStats end
local function pull(PULLER, SOURCE)
    local done
    local started, why = PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end)
    assert(started, tostring(why))
    for _ = 1, 200 do advance(10); if done ~= nil then break end end
    assert(done == true, PULLER.name .. " pull failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
end
local function sentBetween(from, to, kind, pattern, since)
    local count = 0
    for _, row in ipairs(wire) do
        if row.from == from.name and (not to or row.to == to.name) and row.kind == kind
            and row.payload:find(pattern) and row.at >= (since or 0) then count = count + 1 end
    end
    return count
end

-- The feed's messages with rows from one client to another since `since`, as the relay cut them:
-- for each, its whispers and the bytes of its last one.
local function feedPackets(from, to, since)
    local packets, order = {}, {}
    for _, row in ipairs(raw) do
        if row.from == from.name and row.to == to.name and row.at >= (since or 0) then
            local id, part, count, data = row.message:match("^BF:([%w%-]+):(%d+):(%d+):(.*)$")
            part, count = tonumber(part), tonumber(count)
            if id and part == 1 and data:find("|HB|8:U:%d+:%d") then
                packets[id] = { pieces = count, last = #data, got = 1 }
                order[#order + 1] = packets[id]
            elseif id and packets[id] then
                packets[id].got = packets[id].got + 1
                if part == count then packets[id].last = #data end
            end
        end
    end
    return order
end

local A, B, C = client("Alda Source"), client("Bryn Middle"), client("Cole Farther")
local OLD = client("Olde Elder", "2.4.0")
local D = client("Dara Stranger")
for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
advance(10)
local names = {}
for i = 1, 120 do
    names[i] = "Rank " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(97 + (i - 1) % 26)
    for _, e in ipairs(clients) do
        e.Overlord.Leaderboard.kills[names[i]] = i
        e.Overlord.Leaderboard.playerInfo[names[i]] = info()
    end
end

-- 1. A flagged pull leaves a subscription; the requester hears at once that it is fed.
pull(B, A)
assert(sentBetween(B, A, "HR", "^8:V:%d+:%d+[wn]%d+n%d+f:") >= 1, "the pull toward a 2.5.0 peer is not flagged")
assert(feedOf(A).subCount == 1 and feedOf(A).subs[B.name:lower()], "the responder kept no subscriber")
advance(15)
assert(sentBetween(A, B, "HB", "^8:U:%d+:") >= 1, "the new subscriber was told nothing")
assert(B.Overlord.Sync:LadderFeedSources() == 1, "the requester does not count its source: "
    .. tostring(B.Overlord.Sync:LadderFeedSources()))
pull(C, B)
advance(15)
assert(feedOf(B).subs[C.name:lower()] and C.Overlord.Sync:LadderFeedSources() == 1, "second hand not subscribed")

-- 2. A total that moves at the source reaches its subscriber, then the subscriber's own, without
--    any pull: by name and total only (both already hold the player).
local mark = now
local requestsBefore = sentBetween(B, nil, "HR", "^8:[VLGMNT]:") + sentBetween(C, nil, "HR", "^8:[VLGMNT]:")
A.Overlord.Leaderboard:SetPlayerKills(names[7], 4321, true)
A.Overlord.Leaderboard:SetPlayerKills(names[9], 777, true)
advance(40)
assert(B.Overlord.Leaderboard.kills[names[7]] == 4321 and B.Overlord.Leaderboard.kills[names[9]] == 777,
    "the subscriber did not take the moved totals: " .. tostring(B.Overlord.Leaderboard.kills[names[7]]))
assert(C.Overlord.Leaderboard.kills[names[7]] == 4321 and C.Overlord.Leaderboard.kills[names[9]] == 777,
    "the totals did not go on to the second hand: " .. tostring(C.Overlord.Leaderboard.kills[names[7]]))
assert(sentBetween(B, nil, "HR", "^8:[VLGMNT]:") + sentBetween(C, nil, "HR", "^8:[VLGMNT]:") == requestsBefore,
    "a pull was needed")
assert(sentBetween(A, B, "HB", "^8:U:%d+:.*%d+:s" .. names[7] .. ":4321", mark) == 1,
    "a known player did not travel as name and total, once")
assert((statsOf(B).feedChanged or 0) == 2 and (statsOf(C).feedChanged or 0) == 2, "changed rows not counted")
-- Nothing comes back to where it came from, and nothing is said twice.
assert(sentBetween(B, A, "HB", "^8:U:") == 0 and sentBetween(C, B, "HB", "^8:U:") == 0, "a row went back up")
local sentOnce = sentBetween(A, B, "HB", "^8:U:%d+:.") + sentBetween(B, C, "HB", "^8:U:%d+:.")
advance(120)
assert(sentBetween(A, B, "HB", "^8:U:%d+:.") + sentBetween(B, C, "HB", "^8:U:%d+:.") == sentOnce, "rows were sent again")
-- The profile of the subscriber's next own pull is not one built before those rows.
assert((statsOf(B).changedRows or 0) + (statsOf(B).feedChanged or 0) >= 2)

-- 3. A player born at the source after the pull travels whole (class, faction, guild, race).
A.Overlord.Leaderboard.playerInfo["Newly Arrived"] = info("MAGE")
A.Overlord.Leaderboard:SetPlayerKills("Newly Arrived", 12, true)
advance(40)
assert(B.Overlord.Leaderboard.kills["Newly Arrived"] == 12 and C.Overlord.Leaderboard.kills["Newly Arrived"] == 12,
    "a newcomer's row did not arrive whole")
local held = B.Overlord.Leaderboard.playerInfo["Newly Arrived"]
assert(type(held) == "table" and held.class == "MAGE" and held.faction == "Alliance", "a newcomer arrived without its class")
-- Its next total travels short: the whole row went once.
mark = now
A.Overlord.Leaderboard:SetPlayerKills("Newly Arrived", 13, true)
advance(40)
assert(B.Overlord.Leaderboard.kills["Newly Arrived"] == 13)
assert(sentBetween(A, B, "HB", "^8:U:%d+:%d+:sNewly Arrived:13", mark) == 1, "a newcomer's second total travelled whole again")

-- 3b. Kept alive. The feed goes one way, and a source only reaches a subscriber the relay heard
--     in the last five minutes: every KEEP_SEC the subscriber says it is still there, the source
--     answers. Ten quiet minutes later the subscription still works, at both hands.
do
    local keeps = sentBetween(B, A, "HR", "^8:K:%d+$")
    local hellos = sentBetween(A, B, "HB", "^8:U:%d+:$")
    advance(700)
    local sentKeeps = sentBetween(B, A, "HR", "^8:K:%d+$") - keeps
    assert(sentKeeps >= 2 and sentKeeps <= 5, "keep-alives of a subscriber in 700 s: " .. sentKeeps)
    assert(sentBetween(A, B, "HB", "^8:U:%d+:$") - hellos >= 2, "the source did not answer a keep-alive")
    assert(feedOf(A).subs[B.name:lower()] and feedOf(B).subs[C.name:lower()], "a subscription died in ten quiet minutes")
    assert(B.Overlord.Sync:LadderFeedSources() == 1 and C.Overlord.Sync:LadderFeedSources() == 1,
        "a source kept alive no longer counts")
    A.Overlord.Leaderboard:SetPlayerKills(names[11], 1111, true)
    advance(40)
    assert(B.Overlord.Leaderboard.kills[names[11]] == 1111 and C.Overlord.Leaderboard.kills[names[11]] == 1111,
        "a total did not travel after ten quiet minutes")
    -- A source that stops answering counts no more once LIVE_SEC has passed (the rounds take
    -- their usual pace back), and what it sends later is taken only if we ask it again.
    local kept = feedOf(A).kept
    feedOf(A).kept = function() end
    advance(feedOf(B).LIVE_SEC + 60)
    assert(B.Overlord.Sync:LadderFeedSources() == 0, "a silent source still counts")
    feedOf(A).kept = kept
    for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
    advance(5)
    pull(B, A)
    advance(15)
    assert(B.Overlord.Sync:LadderFeedSources() == 1, "asked again, the source does not feed us")
    pull(C, B)
    advance(15)
end

-- 4. A lower total, a made-up row, an unknown player by name alone: nothing is taken.
local epochText
for _, row in ipairs(wire) do epochText = row.payload:match("^8:U:(%d+):") or epochText end
assert(epochText, "fixture: no feed message seen")
local function push(from, to, rows)
    local parts = {}
    for i, row in ipairs(rows) do parts[i] = #row .. ":" .. row end
    from.Overlord.Sync:SendWhisper("HB", "8:U:" .. epochText .. ":" .. table.concat(parts), to.name)
    advance(5)
end
push(A, B, { "s" .. names[7] .. ":5", "sNobody Known:50", "x" .. names[8] .. ":9999", "s" .. names[8] .. ":notanumber" })
assert(B.Overlord.Leaderboard.kills[names[7]] == 4321, "a lower total was taken")
assert(B.Overlord.Leaderboard.kills["Nobody Known"] == nil, "an unknown player was created from a name and a total")
assert(B.Overlord.Leaderboard.kills[names[8]] == 8, "a malformed row was taken")
assert((statsOf(B).feedUnknown or 0) == 1 and (statsOf(B).feedKnown or 0) >= 1 and (statsOf(B).feedBad or 0) >= 1)
-- The plausibility ceiling of a page row holds for a row of the feed.
push(A, B, { "s" .. names[10] .. ":99999999" })
assert(B.Overlord.Leaderboard.kills[names[10]] == 10, "a total above the ceiling was taken: "
    .. tostring(B.Overlord.Leaderboard.kills[names[10]]))

-- 4b. Two messages one after the other: the second arrives while the rows of the first are still
--     being read, a few per frame. None of its rows may be lost.
do
    local first, second = {}, {}
    for i = 60, 71 do first[#first + 1] = "s" .. names[i] .. ":" .. (1500 + i) end
    for i = 72, 83 do second[#second + 1] = "s" .. names[i] .. ":" .. (1500 + i) end
    local function message(rows)
        local parts = {}
        for i, row in ipairs(rows) do parts[i] = #row .. ":" .. row end
        return "8:U:" .. epochText .. ":" .. table.concat(parts)
    end
    assert(#message(first) <= 250 and #message(second) <= 250, "fixture: message too long")
    A.Overlord.Sync:SendWhisper("HB", message(first), B.name)
    local readSoFar = 0
    for _ = 1, 5000 do
        advance(0.001)
        readSoFar = 0
        for i = 60, 71 do if B.Overlord.Leaderboard.kills[names[i]] == 1500 + i then readSoFar = readSoFar + 1 end end
        if readSoFar > 0 then break end
    end
    assert(readSoFar > 0 and readSoFar < 12, "fixture: the first message must be half read: " .. readSoFar)
    A.Overlord.Sync:SendWhisper("HB", message(second), B.name)
    advance(5)
    for i = 60, 83 do
        assert(B.Overlord.Leaderboard.kills[names[i]] == 1500 + i, "a row of two close messages was lost: " .. names[i])
    end
end

-- 4c. Players new to our ranking: a budget per source and per hour. Past it such a row is left to
--     the pulls (whose acceptance is unchanged); totals of players we hold are not concerned.
do
    local feedB = feedOf(B)
    local perSource, perHour = feedB.NEW_PER_SOURCE, feedB.NEW_PER_HOUR
    feedB.NEW_PER_SOURCE = 2
    feedB.newcomers = { at = -1e9, total = 0, by = {} }
    local fresh = {}
    for i = 1, 5 do fresh[i] = "kFresh " .. string.char(64 + i) .. "rrival:" .. (10 + i) .. ":WARRIOR:Alliance:enus::0:60" end
    push(A, B, { fresh[1], fresh[2], fresh[3] })
    push(A, B, { fresh[4], fresh[5] })
    local taken = 0
    for i = 1, 5 do if B.Overlord.Leaderboard.kills["Fresh " .. string.char(64 + i) .. "rrival"] then taken = taken + 1 end end
    assert(taken == 2, "newcomers taken from one source within its budget: " .. taken)
    assert((statsOf(B).feedOverBudget or 0) == 3, "newcomers over budget not counted")
    -- A total of a player we hold still passes.
    push(A, B, { "s" .. names[12] .. ":1212" })
    assert(B.Overlord.Leaderboard.kills[names[12]] == 1212, "a known player's total was held back by the newcomers' budget")
    feedB.NEW_PER_SOURCE, feedB.NEW_PER_HOUR = perSource, perHour
    feedB.newcomers = { at = -1e9, total = 0, by = {} }
end

-- 5. A peer we never asked is not believed, and is told once to stop.
local function presences()
    for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
    advance(5)
end
presences()
local stranger = feedOf(A)
assert(stranger.subscribe(D.name, nil, true), "fixture: forced subscriber")
A.Overlord.Leaderboard:SetPlayerKills(names[20], 2020, true)
advance(40)
assert(D.Overlord.Leaderboard.kills[names[20]] == 20, "a feed nobody asked for was taken")
assert((statsOf(D).feedRefused or 0) >= 1, "the refusal was not counted")
assert(sentBetween(D, A, "HR", "^8:X:%d+$") == 1, "the sender was not told to stop, once")
assert(feedOf(A).subs[D.name:lower()] == nil, "the sender kept a subscriber that refused it")
assert(B.Overlord.Leaderboard.kills[names[20]] == 2020, "the real subscriber lost its row meanwhile")

-- 6. A peer before 2.5.0 is neither flagged nor fed (its own pulls go on as before).
presences()
pull(B, OLD)
assert(sentBetween(B, OLD, "HR", "^8:V:%d+:%d+[wn]%d+n%d+f:") == 0, "a pull toward a 2.4.0 peer was flagged")
assert(feedOf(OLD).subCount == 0)
assert(sentBetween(B, OLD, "HB", "^8:U:") == 0 and sentBetween(A, OLD, "HB", "^8:U:") == 0)

-- 7. No more than SOURCES_MAX peers are asked for their feed; one that feeds us stays asked.
local feed = feedOf(C)
local savedMax = feed.SOURCES_MAX
feed.SOURCES_MAX = 1
local flaggedBefore = sentBetween(C, A, "HR", "^8:V:%d+:%d+[wn]%d+n%d+f:")
pull(C, A)
assert(sentBetween(C, A, "HR", "^8:V:%d+:%d+[wn]%d+n%d+f:") == flaggedBefore, "a source beyond SOURCES_MAX was asked for its feed")
assert(feedOf(A).subs[C.name:lower()] == nil)
local renewedBefore = sentBetween(C, B, "HR", "^8:V:%d+:%d+[wn]%d+n%d+f:")
pull(C, B)
assert(sentBetween(C, B, "HR", "^8:V:%d+:%d+[wn]%d+n%d+f:") == renewedBefore + 1, "the peer that feeds us was not asked again")
feed.SOURCES_MAX = savedMax

-- 8. The budget: one message per subscriber every GAP, PER_MIN for the client; what waits past
--    PENDING_MAX is left to the pulls.
mark = now
-- (A few per frame, as live totals come: a ranking put back in one frame is no news, see 8a.)
for i = 30, 119 do
    A.Overlord.Leaderboard:SetPlayerKills(names[i], 6000 + i, true)
    if i % 30 == 0 then advance(0.02) end
end
advance(60)
local messages = sentBetween(A, B, "HB", "^8:U:%d+:.", mark)
assert(messages >= 2 and messages <= math.ceil(60 / feedOf(A).GAP) + 1, "pace per subscriber: " .. messages)
for _, row in ipairs(wire) do
    if row.kind == "HB" and row.payload:sub(1, 4) == "8:U:" then
        assert(#row.payload <= feedOf(A).MESSAGE_MAX, "feed message longer than its reader takes: " .. #row.payload)
    end
end
-- A burst fills its whispers: PIECES of them at most, the last one FILL full at least.
do
    local packets, several = feedPackets(A, B, mark), 0
    assert(#packets >= 2, "fixture: the burst's messages were not seen as the game got them: " .. #packets)
    for _, packet in ipairs(packets) do
        assert(packet.pieces <= feedOf(A).PIECES, "a feed message in " .. packet.pieces .. " whispers")
        assert(packet.got == packet.pieces, "fixture: a piece of a feed message was not seen")
        if packet.pieces > 1 then
            several = several + 1
            assert(packet.last >= feedOf(A).FILL * 200, "a last whisper left with " .. packet.last .. " bytes")
        end
    end
    assert(several >= 1, "a burst of 90 rows never filled more than one whisper")
end
advance(240)
for i = 30, 119 do
    assert(B.Overlord.Leaderboard.kills[names[i]] == 6000 + i, "a row of the burst was lost on the way: " .. names[i])
end
local sub = feedOf(A).subs[B.name:lower()]
for i = 1, 400 do
    A.Overlord.Leaderboard:SetPlayerKills(names[(i % 90) + 30], 9000 + i, true)
    if i % 30 == 0 then advance(0.02) end
end
assert(sub.count <= feedOf(A).PENDING_MAX, "more rows wait than PENDING_MAX: " .. sub.count)
advance(300)

presences()
-- 8a. A ranking put back in one frame (a login restoring its save): past BULK_PER_FRAME totals
--     in one frame nothing more is queued for anybody, and the next frame counts again.
do
    advance(300)
    local sub = feedOf(A).subs[B.name:lower()]
    assert(sub and sub.count == 0, "fixture: nothing waits for B: " .. tostring(sub and sub.count))
    for i = 10, 119 do A.Overlord.Leaderboard:SetPlayerKills(names[i], 10000 + i, true) end
    assert(sub.count == feedOf(A).BULK_PER_FRAME, "rows queued from one frame: " .. sub.count)
    advance(0.02)
    A.Overlord.Leaderboard:SetPlayerKills(names[6], 10006, true)
    assert(sub.count == feedOf(A).BULK_PER_FRAME + 1, "the next frame is not counted afresh")
    advance(300)
end

-- 8b. A capture count waits CAPTURE_LINGER before it leaves (its event must come first to the
--     clients that witness the capture: totals only go up), then travels like the kills.
mark = now
A.Overlord.Leaderboard:SetPlayerCaptureCount(names[40], 3, true)
advance(feedOf(A).CAPTURE_LINGER - 5)
assert(sentBetween(A, B, "HB", "^8:U:%d+:.*%d+:c" .. names[40] .. ":", mark) == 0, "a capture count left before its wait")
assert((B.Overlord.Leaderboard.captureCount[names[40]] or 0) == 0)
advance(40)
assert(sentBetween(A, B, "HB", "^8:U:%d+:.*%d+:c" .. names[40] .. ":", mark) == 1, "a capture count did not leave once")
assert(B.Overlord.Leaderboard.captureCount[names[40]] == 3, "the subscriber did not take the capture count: "
    .. tostring(B.Overlord.Leaderboard.captureCount[names[40]]))
advance(feedOf(B).CAPTURE_LINGER + 40)
assert(C.Overlord.Leaderboard.captureCount[names[40]] == 3, "the capture count did not go on to the second hand")

-- 8c. A catch-up is not passed on: the rows a big pull brings (a login, an evening away) are
--     news to nobody else. Only the first PULL_PASS rows a pull changes go on to our subscribers.
do
    A.directoryActive = false
    advance(5)
    for i = 30, 119 do A.Overlord.Leaderboard:SetPlayerKills(names[i], 12000 + i, true) end
    advance(300)
    A.directoryActive = true
    presences()
    assert(feedOf(B).subs[C.name:lower()], "fixture: C is fed by B")
    local sentBefore = statsOf(B).feedRowsSent or 0
    pull(B, A)
    advance(120)
    local atB, atC = 0, 0
    for i = 30, 119 do
        if B.Overlord.Leaderboard.kills[names[i]] == 12000 + i then atB = atB + 1 end
        if C.Overlord.Leaderboard.kills[names[i]] == 12000 + i then atC = atC + 1 end
    end
    assert(atB == 90, "fixture: the pull brought " .. atB .. " rows of 90")
    assert(atC >= 1 and atC <= feedOf(B).PULL_PASS, "rows of a catch-up passed on to a subscriber: " .. atC)
    assert((statsOf(B).feedRowsSent or 0) - sentBefore <= feedOf(B).PULL_PASS, "a catch-up was sent on")
    -- C takes the rest by its own pull, as before.
    presences()
    pull(C, B)
    for i = 30, 119 do
        assert(C.Overlord.Leaderboard.kills[names[i]] == 12000 + i, "the subscriber's own pull did not bring the rest")
    end
end

-- 8d. The rows fill whole whispers. A message goes through the relay in pieces of 200 bytes, its
--     header in the first: what fits one whisper leaves in one; a second whisper that a few rows
--     would open stays unsent and those rows wait for the next message; enough rows for a second
--     whisper well filled leave together.
do
    advance(300)
    presences()
    local room = A.Overlord.Relay:PayloadRoom("HB", B.name, 1) - (5 + #epochText)
    local rowBytes = #("14:s" .. names[30] .. ":13030")
    local fit = math.floor(room / rowBytes)
    assert(room >= 60 and fit >= 3 and fit <= 12, "fixture: rows in the first whisper: " .. fit)
    local function move(from, to)
        for i = from, to do A.Overlord.Leaderboard:SetPlayerKills(names[i], 13000 + i, true) end
        advance(30)
        for i = from, to do
            assert(B.Overlord.Leaderboard.kills[names[i]] == 13000 + i, "a row did not arrive: " .. names[i])
        end
    end
    mark = now
    move(30, 32)
    local packets = feedPackets(A, B, mark)
    assert(#packets == 1 and packets[1].pieces == 1, "three rows: " .. #packets .. " messages, "
        .. tostring(packets[1] and packets[1].pieces) .. " whispers")
    mark = now
    local held = statsOf(A).feedHeldBack or 0
    move(40, 40 + fit + 1)
    packets = feedPackets(A, B, mark)
    assert(#packets == 2 and packets[1].pieces == 1 and packets[2].pieces == 1,
        "two rows past one whisper: " .. #packets .. " messages, " .. tostring(packets[1] and packets[1].pieces) .. " whispers first")
    assert((statsOf(A).feedHeldBack or 0) == held + 1, "the rows held back were not counted")
    mark = now
    local many = fit + math.ceil(0.7 * 200 / rowBytes)
    assert(70 + many - 1 <= 119, "fixture: not enough players")
    move(70, 70 + many - 1)
    packets = feedPackets(A, B, mark)
    assert(#packets == 1 and packets[1].pieces == 2 and packets[1].last >= 100,
        "a second whisper well filled: " .. #packets .. " messages, " .. tostring(packets[1] and packets[1].pieces) .. " whispers")
    -- Three whispers when the rows fill them (more rows than ROWS_MAX lets through with names
    -- this short: raised for the time of the check, at both ends).
    do
        local saved = feedOf(A).ROWS_MAX
        for _, e in ipairs({ A, B, C }) do feedOf(e).ROWS_MAX = 40 end
        mark = now
        for i = 30, 69 do A.Overlord.Leaderboard:SetPlayerKills(names[i], 14200 + i, true) end
        advance(30)
        packets = feedPackets(A, B, mark)
        assert(packets[1] and packets[1].pieces == 3 and packets[1].got == 3 and packets[1].last >= 100,
            "forty rows: " .. tostring(packets[1] and packets[1].pieces) .. " whispers first")
        for i = 30, 69 do
            assert(B.Overlord.Leaderboard.kills[names[i]] == 14200 + i, "a row of a three-whisper message was lost: " .. names[i])
        end
        for _, e in ipairs({ A, B, C }) do feedOf(e).ROWS_MAX = saved end
    end
    -- Two peers that asked each other: a total one of them has just told the other is not sent
    -- back to it (both took it from somebody else a moment apart).
    presences()
    pull(A, B)
    advance(40)
    assert(feedOf(B).subs[A.name:lower()] and feedOf(A).subs[B.name:lower()], "fixture: A and B feed each other")
    mark = now
    local skipped = statsOf(B).feedEchoSkipped or 0
    A.Overlord.Leaderboard:SetPlayerKills(names[100], 14100, true)
    advance(1)
    B.Overlord.Leaderboard:SetPlayerKills(names[100], 14100, true)
    advance(40)
    assert(sentBetween(A, B, "HB", "s" .. names[100] .. ":14100", mark) == 1, "fixture: A told B once")
    assert(sentBetween(B, A, "HB", "s" .. names[100] .. ":14100", mark) == 0, "a total went back to the peer that had just told it")
    assert((statsOf(B).feedEchoSkipped or 0) == skipped + 1, "the row left unsent was not counted")
    -- A higher total at B is news to A.
    B.Overlord.Leaderboard:SetPlayerKills(names[100], 14101, true)
    advance(40)
    assert(A.Overlord.Leaderboard.kills[names[100]] == 14101, "a higher total did not go back")
end

-- 8e. The fight brackets of "Recent activity" travel in the feed's messages: a bracket new to a
--     client goes to its subscribers, which take it through FrontActivity's own acceptance and
--     pass it on; never back to the peer it came from, never twice; with the rows when rows
--     leave; and a new subscriber gets the fights going on.
do
    advance(300)
    presences()
    local function fights(e)
        local real = e.Overlord.FrontActivity
        local fa = { entries = {}, got = {} }
        fa.BuildKillBracketSyncEntries = function(self) return self.entries end
        fa.OnReceiveKillBracket = function(self, bracket, sender, channel)
            self.got[#self.got + 1] = { bracket = bracket, sender = sender, channel = channel }
            for _, known in ipairs(self.entries) do if known == bracket then return false end end
            self.entries[#self.entries + 1] = bracket
            feedOf(e).noteBracket()
            return true
        end
        e.Overlord.FrontActivity = fa
        return fa, real
    end
    local faA, realA = fights(A)
    local faB, realB = fights(B)
    local faC, realC = fights(C)
    local faD, realD = fights(D)
    assert(feedOf(A).subs[B.name:lower()] and feedOf(B).subs[A.name:lower()] and feedOf(B).subs[C.name:lower()],
        "fixture: A and B feed each other, B feeds C")
    mark = now
    local first = "1:elwynn:50:59667233"
    faA.entries[1] = first
    feedOf(A).noteBracket()
    advance(40)
    assert(#faB.got == 1 and faB.got[1].bracket == first and faB.got[1].sender == A.name and faB.got[1].channel == "BETA",
        "the subscriber did not take the bracket: " .. #faB.got)
    assert(#faC.got == 1 and faC.got[1].sender == B.name, "the bracket did not go on to the second hand: " .. #faC.got)
    assert(#faA.got == 0, "the bracket came back to the peer that told it")
    assert(sentBetween(A, B, "HB", "%d+:f" .. first:gsub("%p", "%%%0"), mark) == 1, "the bracket did not leave once")
    -- (One whisper for it, whatever else that message carried.)
    local packets = feedPackets(A, B, mark)
    assert(#packets == 1 and packets[1].pieces == 1, "a bracket took " .. #packets .. " messages, "
        .. tostring(packets[1] and packets[1].pieces) .. " whispers")
    -- Said again by FrontActivity without anything new: nothing leaves.
    feedOf(A).noteBracket()
    feedOf(B).noteBracket()
    advance(60)
    assert(sentBetween(A, B, "HB", ":f1:elwynn:", mark) == 1 and sentBetween(B, C, "HB", ":f1:elwynn:", mark) == 1
        and sentBetween(B, A, "HB", ":f1:elwynn:", mark) == 0, "a bracket was told twice or told back")
    -- With a row that moves: the same message carries both.
    mark = now
    local second = "1:elwynn:75:59667236"
    A.Overlord.Leaderboard:SetPlayerKills(names[33], 14500, true)
    faA.entries[2] = second
    feedOf(A).noteBracket()
    advance(40)
    assert(sentBetween(A, B, "HB", "s" .. names[33] .. ":14500.*:f1:elwynn:75:59667236", mark) == 1,
        "the row and the bracket did not travel together")
    assert(sentBetween(A, B, "HB", "^8:U:%d+:.", mark) == 1, "more than one message for a row and a bracket")
    assert(#faB.got == 2 and #faC.got == 2, "the second bracket: " .. #faB.got .. " and " .. #faC.got)
    -- A new subscriber is told the fights going on with its first message.
    presences()
    pull(D, A)
    advance(40)
    assert(#faD.got == 2, "a new subscriber was told " .. #faD.got .. " of the two fights going on")
    -- Up the feed: C, fed by B and feeding nobody, learns a bracket first (a Battle.net friend, a
    -- player out of the list): it tells B, the peer that feeds it, which tells everyone else.
    -- Never to a peer that is not fed by us, and nothing from a peer we do not feed.
    do
        mark = now
        local up = "1:elwynn:200:59667238"
        assert(feedOf(C).subCount == 0 and feedOf(C).sources[B.name:lower()], "fixture: C is fed by B and feeds nobody")
        -- Anybody can become a subscriber by asking for our ranking: a bracket coming up from one
        -- that is no contact of ours (nor a guild mate, nor a Battle.net friend) is not read.
        local stranger = "1:elwynn:2000:59667237"
        B.Overlord.Sync:OnPagedLeaderboardMessage("HR", "8:W:" .. epochText .. ":" .. stranger, C.name, "WHISPER")
        advance(5)
        for _, row in ipairs(faB.got) do assert(row.bracket ~= stranger, "a bracket was read from a subscriber that is no contact") end
        assert((statsOf(B).feedFightsRefused or 0) == 1, "the refusal was not counted")
        B.Overlord.ChannelDirectory.IsContact = function(_, who) return who == C.name end
        faC.entries[#faC.entries + 1] = up
        feedOf(C).noteBracket()
        advance(40)
        assert(sentBetween(C, B, "HR", "^8:W:%d+:1:elwynn:200:59667238$", mark) == 1, "the bracket did not go up to the source, once")
        local function has(fa) for _, row in ipairs(fa.got) do if row.bracket == up then return row end end end
        assert(has(faB) and has(faB).sender == C.name and has(faB).channel == "BETA", "the source did not take what its subscriber told it")
        assert(has(faA) and has(faD), "what came up did not go on to the others")
        assert(sentBetween(B, C, "HB", ":f1:elwynn:200:", mark) == 0, "it was told back to the subscriber it came from")
        -- Told again by FrontActivity: nothing more goes up.
        feedOf(C).noteBracket()
        advance(40)
        assert(sentBetween(C, B, "HR", "^8:W:", mark) == 1, "a bracket went up twice")
        -- What a source told us is not told back up to it.
        local down = "1:elwynn:300:59667239"
        faA.entries[#faA.entries + 1] = down
        feedOf(A).noteBracket()
        advance(60)
        assert(sentBetween(C, B, "HR", "^8:W:%d+:.*elwynn:300", mark) == 0 and sentBetween(B, A, "HR", "^8:W:", mark) == 0,
            "a bracket was told back up to the peer it came from")
        -- From a peer we do not feed: not read.
        local gotBefore = #faC.got
        B.Overlord.Sync:SendWhisper("HR", "8:W:" .. epochText .. ":1:elwynn:500:59667240", C.name)
        advance(5)
        assert(#faC.got == gotBefore, "a bracket was taken from a peer we do not feed")
    end
    -- A bracket FrontActivity refuses is told on to nobody.
    mark = now
    local gotB = #faB.got
    faB.OnReceiveKillBracket = function(self, bracket) self.got[#self.got + 1] = { bracket = bracket } return false end
    faA.entries[3] = "1:nowhere:2000:59667240"
    feedOf(A).noteBracket()
    advance(40)
    assert(#faB.got == gotB + 1 and faB.got[#faB.got].bracket == "1:nowhere:2000:59667240"
        and sentBetween(B, C, "HB", ":f1:nowhere:", mark) == 0, "a refused bracket was passed on")
    A.Overlord.FrontActivity, B.Overlord.FrontActivity = realA, realB
    C.Overlord.FrontActivity, D.Overlord.FrontActivity = realC, realD
    feedOf(A).subs[D.name:lower()] = nil
    feedOf(A).subCount = 0
    for _ in pairs(feedOf(A).subs) do feedOf(A).subCount = feedOf(A).subCount + 1 end
    advance(60)
end

-- 8f. The zone of a fight travels with the kill rows: one marker per zone in a message, the rows
--     of that zone behind it; the client that takes such a total hands it to the fight counter
--     with its zone, and passes the zone on to its own subscribers; a zone is told for ZONE_SEC.
do
    advance(300)
    presences()
    local counted = {}
    local function listen(e)
        counted[e.name] = {}
        e.Overlord.GuildKillAlert = { OnFedKill = function(_, who, total, zone, wireEpoch)
            local list = counted[e.name]
            list[#list + 1] = { who = who, total = total, zone = zone }
        end }
    end
    listen(A); listen(B); listen(C)
    -- (The front of a zone reference: as FrontActivity resolves it.)
    for _, e in ipairs({ A, B, C }) do
        e.savedFA = e.Overlord.FrontActivity
        e.Overlord.FrontActivity = { GetFrontIdFromZoneRef = function(_, ref)
            return (ref == "elwynn_goldshire" or ref == "@elwynn") and "elwynn" or nil
        end }
    end
    assert(feedOf(A).subs[B.name:lower()] and feedOf(B).subs[C.name:lower()], "fixture: A feeds B, B feeds C")
    mark = now
    local fa = feedOf(A)
    -- Four totals move at A: two in Elwynn (told by a zone id), one in a world zone, one nowhere known.
    fa.noteZone(names[51], "elwynn_goldshire")
    fa.noteZone(names[52], "#1437")
    fa.noteZone(names[53], "elwynn_goldshire")
    fa.noteZone(names[54], "not a zone we know")
    for i = 51, 54 do A.Overlord.Leaderboard:SetPlayerKills(names[i], 14600 + i, true) end
    advance(40)
    local message
    for _, row in ipairs(wire) do
        if row.from == A.name and row.to == B.name and row.at >= mark and row.payload:find("s" .. names[51] .. ":14651", 1, true) then
            message = row.payload
        end
    end
    assert(message, "fixture: the message carrying the rows")
    local _, elwynnMarkers = message:gsub("%d+:z@elwynn", "")
    local _, worldMarkers = message:gsub("%d+:z#1437", "")
    assert(elwynnMarkers == 1 and worldMarkers == 1, "one marker per zone in a message: " .. message)
    assert(message:find("s" .. names[54] .. ":14654.-%d+:z"), "a row without a zone must come before every marker: " .. message)
    assert(message:find("z@elwynn%d+:s" .. names[51] .. ":14651%d+:s" .. names[53] .. ":14653"), "the rows of a zone follow its marker: " .. message)
    local byWho = {}
    for _, row in ipairs(counted[B.name]) do byWho[row.who] = row end
    assert(byWho[names[51]] and byWho[names[51]].zone == "@elwynn" and byWho[names[51]].total == 14651
        and byWho[names[53]] and byWho[names[53]].zone == "@elwynn", "the totals of Elwynn were not handed with their zone")
    assert(byWho[names[52]] and byWho[names[52]].zone == "#1437", "the total of a world zone was not handed with its map")
    assert(byWho[names[54]] == nil, "a total without a zone was handed to the fight counter")
    -- The second hand has the zones too.
    byWho = {}
    for _, row in ipairs(counted[C.name]) do byWho[row.who] = row end
    assert(byWho[names[51]] and byWho[names[51]].zone == "@elwynn" and byWho[names[52]] and byWho[names[52]].zone == "#1437",
        "the zone did not go on to the second hand")
    -- A total already held: nothing is counted (no kill twice).
    local before = #counted[B.name]
    push(A, B, { "z@elwynn", "s" .. names[51] .. ":14651" })
    assert(#counted[B.name] == before, "a total already held was counted again")
    -- A made-up marker is no zone: the row is taken, nothing is counted for a fight.
    push(A, B, { "z|Hbad|h", "s" .. names[55] .. ":14655" })
    push(A, B, { "z" .. ("x"):rep(40), "s" .. names[56] .. ":14656" })
    assert(B.Overlord.Leaderboard.kills[names[55]] == 14655 and B.Overlord.Leaderboard.kills[names[56]] == 14656,
        "a row behind a bad marker was lost")
    for _, row in ipairs(counted[B.name]) do assert(row.who ~= names[55] and row.who ~= names[56], "a made-up zone was believed") end
    -- Long after the kills the zone is no longer told.
    advance(feedOf(A).ZONE_SEC + 60)
    mark = now
    A.Overlord.Leaderboard:SetPlayerKills(names[51], 14700, true)
    advance(40)
    assert(sentBetween(A, B, "HB", "s" .. names[51] .. ":14700", mark) == 1 and sentBetween(A, B, "HB", "z@elwynn", mark) == 0,
        "a zone was told long after its kills")
    for _, e in ipairs({ A, B, C }) do e.Overlord.FrontActivity, e.Overlord.GuildKillAlert = e.savedFA, nil end
end

-- 9. An instance, or the channel carrying again: nothing is fed any more, nothing is taken.
A.directoryActive = false
A.Overlord.Leaderboard:SetPlayerKills(names[5], 5555, true)
advance(40)
assert(B.Overlord.Leaderboard.kills[names[5]] == 5, "the feed went on while the channel carries")
assert(feedOf(A).subCount == 0, "subscribers kept while the channel carries")
A.directoryActive = true
B.Overlord.Sync:DropPagedServing()
assert(feedOf(B).subCount == 0 and B.Overlord.Sync:LadderFeedSources() == 0, "an instance kept the feed's books")
-- The rounds' pace reads the feed: an idle round with enough sources rests LADDER_FED_SEC (the
-- wiring is checked in the source: its timing is the whole-client bench's business).
do
    local function read(path) local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text end
    local catchup, directory = read("SyncHistoryCatchup.lua"), read("SyncDirectory.lua")
    assert(catchup:find("local function ArmNextHistoryCatchup%(delay, fast, productive, fed%)"), "the rounds do not take the fed pace")
    assert(catchup:find("elseif fed and directory then%s+delay, jitter, shortest = directory%.LADDER_FED_SEC"),
        "a fed round does not rest LADDER_FED_SEC")
    assert(catchup:find("productive ~= true and sync%.LadderFeedSources and directory%.LADDER_FED_SOURCES"),
        "a round that brought rows must keep the fast pace")
    assert(catchup:find("ArmNextHistoryCatchup%(fast and directory%.LADDER_ACK_SEC.-productive == true, fed%)"),
        "FinishRound does not pass the fed pace on")
    local sec, jitter, sources = directory:match("LADDER_FED_SEC = (%d+), LADDER_FED_JITTER = (%d+), LADDER_FED_SOURCES = (%d+)")
    assert(tonumber(sec) and tonumber(sec) >= 60 and tonumber(sec) + tonumber(jitter) <= 240 and tonumber(sources) >= 2,
        "the fed pace: " .. tostring(sec) .. " " .. tostring(jitter) .. " " .. tostring(sources))
    -- A source counts for less long than the fed rounds take to come back to it twice.
    assert(feedOf(A).LIVE_SEC > feedOf(A).KEEP_SEC * 2 and feedOf(A).SUB_TTL > feedOf(A).KEEP_SEC * 3)
end
print("Ladder feed: subscription by pull, rows by name and total, newcomers whole, second hand, nothing believed from a peer we did not ask, old peers untouched, budget OK")
