-- 2.4.0: the ranking holds 10,000 kill rows. Two clients that both say so ("~la" in their
-- presence, capability 10) compare and exchange all of them. With a client that holds 5,000
-- (capability 9) both sides compare the best 5,000 of what they hold, as that client always
-- did: it gets those rows and no other, and two equal rankings stay equal (no row sent again
-- pull after pull). Real HR/HA/HB, relay and page acceptance; transports and clock simulated.
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
        assert(steps < 200000, "Unbounded catchup work")
    end
    now = stop
    for _, c in ipairs(clients) do
        assert(not c.Overlord.Relay.stats.lastError, c.Overlord.Relay.stats.lastError)
    end
end
local function client(name, channel, faction)
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    e.loadfile("Leaderboard.lua")()
    e.name, e.channel, e.friends = name, channel, {}
    e.GetTime = function() return now end
    e.time = function() return 1790017000 + math.floor(now) end
    e.GetServerTime = e.time
    e.UnitName = function() return name end
    e.UnitFullName = function() return name, "" end
    e.GetUnitName = e.UnitName
    e.UnitFactionGroup = function() return faction end
    e.Overlord.PlayerFaction = faction
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
        assert(#kind + #fragment + 1 <= 255)
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
    e.securecall = function(fn, ...) return fn(...) end
    e.C_ChatInfo = { SendAddonMessage = function(prefix, message, transport, target)
        assert(transport == "WHISPER", "Invalid direct transport")
        assert(#message <= 255, "whisper over 255 bytes")
        for _, other in ipairs(clients) do
            if other.name == target then
                local destination = other
                assert(message:sub(1, 3) == "BF:" or destination.channel == channel,
                    "Raw cross-faction reply")
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
    clients[#clients + 1] = e
    return e
end


local PULLER = client("Bridge Tester", "alliance", "Alliance")
local SOURCE = client("Gateway Tester", "alliance", "Alliance")
local SMALL = client("Analyst Tester", "alliance", "Alliance")
for _, e in ipairs(clients) do e.Overlord.Relay.GetPeerReleaseWithin = function() return nil end end
local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
    later(45, heartbeat)
end
heartbeat()
advance(10)
local sync = PULLER.Overlord.Sync
assert(PULLER.Overlord.Relay:GetPeerPagedProtocol(SOURCE.name) == 10 and sync.PAGED_FULL_PROTOCOL == 10,
    "fixture: the source does not say it holds the whole ranking")
assert(PULLER.Overlord.Leaderboard.KILL_RANK_LIMIT == 10000, "the ranking does not hold 10,000 rows")

-- 0) The view of 5,000 of a copy: nothing but a cut of it.
do
    local view = sync._LegacyLadderView
    local small = { kills = { A = 2, B = 1 }, killOrder = { "A", "B" }, playerInfo = {}, captureCount = {} }
    assert(view(small) == small and view(nil) == nil, "a copy of 5,000 rows or fewer is its own view")
    local big = { kills = {}, killOrder = {}, playerInfo = {}, captureCount = { ["Capture Only"] = 3, P5003 = 1 },
        captures = { marker = true }, campaignStart = 77 }
    for i = 1, 5003 do
        local name = "P" .. i
        big.killOrder[i], big.kills[name], big.playerInfo[name] = name, 6000 - i, { level = i }
    end
    big.playerInfo["Capture Only"] = { level = 1 }
    local cut = view(big)
    assert(cut ~= big and view(big) == cut, "the view of a larger copy is built once")
    assert(#cut.killOrder == 5000 and cut.killOrder[1] == "P1" and cut.killOrder[5000] == "P5000", "the view is not the best 5,000")
    assert(cut.kills.P5000 == 1000 and cut.kills.P5001 == nil, "a kill row beyond the best 5,000 is in the view")
    assert(cut.playerInfo.P5000 and cut.playerInfo.P5001 == nil, "the race row of a player beyond the best 5,000 is in the view")
    assert(cut.playerInfo["Capture Only"] and cut.playerInfo.P5003, "the rows of capture players left the view")
    assert(cut.captureCount == big.captureCount and cut.captures == big.captures and cut.campaignStart == 77,
        "the view changed something else than kills")
    assert(#big.killOrder == 5003 and big.kills.P5003 == 997, "building the view changed the copy")
    -- The view does not keep its copy alive (Lua 5.1 never frees a weak key that its own value
    -- holds: every copy attested in a session, and what is cached under it, would stay).
    local alive = setmetatable({ big }, { __mode = "v" })
    big, cut = nil, nil
    collectgarbage("collect"); collectgarbage("collect")
    assert(alive[1] == nil, "a copy is kept for the whole session by its view of 5,000")
end

local function playerName(i)
    local n = i - 1
    return "Player " .. string.char(65 + math.floor(n / 676)) .. string.char(97 + math.floor(n / 26) % 26)
        .. string.char(97 + n % 26)
end
-- 5,300 rows at the source, no two with the same score: the best 5,000 are rows 301..5300.
local ROWS, BEYOND = 5300, 300
for i = 1, ROWS do
    local name = playerName(i)
    local lb = SOURCE.Overlord.Leaderboard
    lb.kills[name] = 100 + i
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Alliance", level = 60, locale = "engb",
        guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true, race = "Human", raceSex = 2, raceAt = 1 }
end
local applied, nonces = 0, {}
local receive = sync.OnReceiveLeaderboardKills
sync.OnReceiveLeaderboardKills = function(self, payload, ...)
    applied = applied + 1
    return receive(self, payload, ...)
end
local send = sync.SendWhisper
sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" then
        local _, _, _, nonce = PULLER.strsplit(":", payload)
        nonces[#nonces + 1] = nonce
    end
    return send(self, kind, payload, target)
end
local function pull(peer)
    local done
    local started, why = sync:StartCompletePagedLeaderboardCatchup(peer.name, function(ok) done = ok end)
    assert(started, tostring(why))
    for _ = 1, 400 do advance(60); if done ~= nil then break end end
    advance(400)
    return done
end
local function held(e)
    local count = 0
    for _ in pairs(e.Overlord.Leaderboard.kills) do count = count + 1 end
    return count
end
local function whole(pattern)
    for _, nonce in ipairs(nonces) do
        if not tostring(nonce):match(pattern) then return false, nonce end
    end
    return #nonces > 0
end

-- 1) The source is read as a client of 5,000 rows (what a 2.3.3 client reads of anybody, and
--    what we read of one): the pull is about the best 5,000 and brings those only.
local realProtocol = PULLER.Overlord.Relay.GetPeerPagedProtocol
PULLER.Overlord.Relay.GetPeerPagedProtocol = function(self, name) return 9 end
assert(pull(SOURCE) == true, "the pull of the best 5,000 failed: " .. sync:GetPagedLeaderboardDiagnostics())
assert(whole("^%d+n%d+n%d+$"), "a pull with a client of 5,000 rows was marked as about the whole ranking")
-- (A row can be handed over twice when its page is asked again; what is held is what counts.)
assert(held(PULLER) == 5000 and applied >= 5000 and applied < ROWS, "the best 5,000 did not arrive, or more did: " .. held(PULLER) .. "/" .. applied)
for i = 1, ROWS do
    local got = PULLER.Overlord.Leaderboard.kills[playerName(i)]
    assert(got == (i > BEYOND and 100 + i or nil), "row " .. i .. " of the source: " .. tostring(got))
end
-- Equal on the best 5,000: nothing comes again, whatever the source holds beyond.
applied, nonces = 0, {}
assert(pull(SOURCE) == true and applied == 0, "rows came again between equal best 5,000: " .. applied)

-- 2) Both hold 10,000: the pull says so and the rows beyond the best 5,000 arrive.
PULLER.Overlord.Relay.GetPeerPagedProtocol = realProtocol
applied, nonces = 0, {}
assert(pull(SOURCE) == true, "the pull of the whole ranking failed: " .. sync:GetPagedLeaderboardDiagnostics())
assert(whole("^%d+w%d+n%d+$"), "a pull between two clients of 10,000 rows was not marked as such")
assert(held(PULLER) == ROWS and applied >= BEYOND and applied < 1000, "the rows beyond the best 5,000: " .. held(PULLER) .. "/" .. applied)
for i = 1, ROWS do
    assert(PULLER.Overlord.Leaderboard.kills[playerName(i)] == 100 + i, "row " .. i .. " after the whole pull")
end
applied, nonces = 0, {}
assert(pull(SOURCE) == true and applied == 0, "rows came again between equal rankings: " .. applied)

-- 3) We hold 5,300 rows, a client of 5,000 holds the best 5,000 of them: equal for it and for
--    us, in both directions (it never held the others, and never will).
for i = BEYOND + 1, ROWS do
    local name = playerName(i)
    SMALL.Overlord.Leaderboard.kills[name] = 100 + i
    SMALL.Overlord.Leaderboard.playerInfo[name] = { class = "WARRIOR", faction = "Alliance", level = 60, locale = "engb",
        guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true, race = "Human", raceSex = 2, raceAt = 1 }
end
SMALL.Overlord.Leaderboard:MarkMetaDirty()
PULLER.Overlord.Relay.GetPeerPagedProtocol = function(self, name)
    if name == SMALL.name then return 9 end
    return realProtocol(self, name)
end
local sentRows, smallSend = 0, SMALL.Overlord.Sync.SendWhisper
SMALL.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HB" then sentRows = sentRows + 1 end
    return smallSend(self, kind, payload, target)
end
applied, nonces = 0, {}
assert(pull(SMALL) == true, "the pull from a client of 5,000 rows failed: " .. sync:GetPagedLeaderboardDiagnostics())
assert(whole("^%d+n%d+n%d+$") and applied == 0 and sentRows == 0,
    "our rows beyond its best 5,000 made a client of 5,000 rows send pages: " .. applied .. "/" .. sentRows)
-- The other direction: it pulls us (its nonce says nothing of the whole ranking) and gets
-- nothing either, though we hold 300 rows more.
local smallSync, smallApplied, smallDone = SMALL.Overlord.Sync, 0, nil
local smallReceive = smallSync.OnReceiveLeaderboardKills
smallSync.OnReceiveLeaderboardKills = function(self, payload, ...)
    smallApplied = smallApplied + 1
    return smallReceive(self, payload, ...)
end
SMALL.Overlord.Relay.GetPeerPagedProtocol = function() return 9 end
assert(smallSync:StartCompletePagedLeaderboardCatchup(PULLER.name, function(ok) smallDone = ok end))
for _ = 1, 400 do advance(60); if smallDone ~= nil then break end end
assert(smallDone == true and smallApplied == 0 and held(SMALL) == 5000,
    "a client of 5,000 rows was sent rows beyond its best 5,000: " .. smallApplied .. " " .. tostring(smallDone))
print("forever_ladder_10k: OK")
