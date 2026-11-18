-- 2.5.2: killing blows of the week, one more column of the player table (never the guilds).
-- Our own count pairs a killing blow of ours with an honorable kill credited within PAIR_SEC;
-- rows of other players travel in a stream "LB" after the races and as feed rows "b", between
-- clients whose presence says "~lb" (capability 11) only. A client without it (2.5.1) is never
-- asked for them, never sent one, and compares the same profiles as before.
-- Real HR/HA/HB, relay, pages and feed; only WoW transports and the clock are simulated.
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
        assert(steps < 200000, "Unbounded work")
    end
    now = stop
    for _, c in ipairs(clients) do
        assert(not c.Overlord.Relay.stats.lastError, c.Overlord.Relay.stats.lastError)
        assert(not c.Overlord.Sync._leaderboardPageStats.feedError, c.Overlord.Sync._leaderboardPageStats.feedError)
    end
end
local wire, presences = {}, {}
local function client(name, withKB)
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    e.loadfile("Leaderboard.lua")()
    if withKB then e.loadfile("KillingBlows.lua")() else e.Overlord.KillingBlows = nil end
    e.name, e.friends = name, {}
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
        if kind == "BR" then presences[#presences + 1] = { from = name, fragment = fragment } end
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
    -- (2.5.5: the captures compared first have their own test, forever_capture_totals: here every pull
    -- that starts at the kills is a plain sweep.)
    e.Overlord.Sync._captureTurns.FIRST_SEC = math.huge
    e.loadfile("SyncRelay.lua")()
    s.SendSyncRequest = function() return true end
    e.directoryActive = true
    e.Overlord.ChannelDirectory = { IsActive = function() return e.directoryActive end }
    e.Overlord.Version = withKB and "2.5.2" or "2.5.1"
    local send = s.SendWhisper
    s.SendWhisper = function(self, kind, payload, target)
        wire[#wire + 1] = { from = name, to = target, kind = kind, payload = payload, at = now }
        return send(self, kind, payload, target)
    end
    clients[#clients + 1] = e
    return e
end
local function info()
    return { class = "WARRIOR", faction = "Alliance", level = 60, locale = "engb",
        guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true, race = "Human", raceSex = 2, raceAt = 1 }
end
local function sent(from, to, kind, pattern, since)
    local count = 0
    for _, row in ipairs(wire) do
        if row.from == from.name and (not to or row.to == to.name) and row.kind == kind
            and row.payload:find(pattern) and row.at >= (since or 0) then count = count + 1 end
    end
    return count
end
-- Any ranking message between two clients that names the stream LB or carries a feed row "b".
local function kbTraffic(a, b, since)
    local count = 0
    for _, row in ipairs(wire) do
        if row.at >= (since or 0) and ((row.from == a.name and row.to == b.name) or (row.from == b.name and row.to == a.name))
            and (row.payload:find(":LB", 1, true) or (row.kind == "HB" and row.payload:find("^8:U:.-%d+:b"))) then
            count = count + 1
        end
    end
    return count
end
local function pull(PULLER, SOURCE)
    local done
    local started, why = PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end)
    assert(started, tostring(why))
    for _ = 1, 200 do advance(10); if done ~= nil then break end end
    assert(done == true, PULLER.name .. " pull failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
end
local function hello()
    for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
    advance(10)
end

local A, B = client("Alda Source", true), client("Bryn Middle", true)
local OLD = client("Olde Elder", false)
hello()

-- 0) Presence: "~lb" before the marker every older client looks for (it still reads 10).
do
    local seen = {}
    for _, p in ipairs(presences) do seen[p.from] = p.fragment end
    assert(A.Overlord.Relay:GetPeerPagedProtocol(B.name) == 11, "a 2.5.2 peer is not read as capability 11: "
        .. tostring(A.Overlord.Relay:GetPeerPagedProtocol(B.name)))
    assert(A.Overlord.Relay:GetPeerPagedProtocol(OLD.name) == 10, "a client without killing blows is read as 11")
    assert(A.Overlord.KillingBlows:PeerCarries(B.name) and not A.Overlord.KillingBlows:PeerCarries(OLD.name))
end

-- 1) Our own count: a blow, then its honorable kill within PAIR_SEC (or just before it).
local KB = A.Overlord.KillingBlows
local alb = A.Overlord.Leaderboard
alb.kills[A.name], alb.playerInfo[A.name] = 40, info()
assert(KB:Data(), "no killing blow table in a running campaign")
KB:NoteOwnBlow(); now = now + 2; KB:NoteOwnHonorable(1)
assert(KB:Get(A.name) == 1, "a blow followed by its honorable kill did not count")
KB:NoteOwnHonorable(1); now = now + 1; KB:NoteOwnBlow()
assert(KB:Get(A.name) == 2, "an honorable kill followed at once by our blow did not count")
-- Another player's kill (everybody near gets its honorable kill), then our blow on a grey
-- player a few seconds later: nothing.
KB:NoteOwnHonorable(1); now = now + 3; KB:NoteOwnBlow()
assert(KB:Get(A.name) == 2, "someone else's honorable kill paired with a later blow of ours")
now = now + KB.PAIR_SEC + 1
-- A batch of honorable kills (a fight around us) pairs with our one blow, and leaves at most
-- HONOR_WAIT_MAX waiting, for a moment.
KB:NoteOwnBlow(); now = now + 1; KB:NoteOwnHonorable(12)
assert(KB:Get(A.name) == 3, "a batch did not pair with our blow, or paired more")
now = now + KB.HONOR_FIRST_SEC + 0.5
KB:NoteOwnBlow(); KB:NoteOwnBlow()
assert(KB:Get(A.name) == 3, "honorable kills of a batch paired with later blows")
now = now + KB.PAIR_SEC + 1
-- A blow on a grey player (no honorable kill), then an honorable kill too late: nothing.
KB:NoteOwnBlow(); now = now + KB.PAIR_SEC + 1; KB:NoteOwnHonorable(1)
assert(KB:Get(A.name) == 3, "a blow without an honorable kill counted")
-- An honorable kill whose blow is someone else's: nothing (the lone kill above has expired too).
now = now + KB.PAIR_SEC + 1
KB:NoteOwnHonorable(1)
now = now + KB.PAIR_SEC + 1
KB:NoteOwnBlow()
assert(KB:Get(A.name) == 3, "an honorable kill without our blow counted")
-- Never more killing blows than our honorable kills.
alb.kills[A.name] = 3
KB:NoteOwnBlow(); KB:NoteOwnHonorable(1)
assert(KB:Get(A.name) == 3, "killing blows passed our honorable kills")
alb.kills[A.name] = 40
-- Leaving for an instance: nothing waits for a partner.
KB:NoteOwnBlow(); KB:ResetPairing(); KB:NoteOwnHonorable(1)
assert(KB:Get(A.name) == 3, "a blow from before an instance paired after it")
-- 2.5.3: a kill processed late (victim name resolved up to 2.75 s after PARTY_KILL) is dated
-- at its event: the honorable kill that came in between still pairs.
now = now + KB.PAIR_SEC + 1
local blowAt = now
now = now + 0.3; KB:NoteOwnHonorable(1)
now = now + 2.45; KB:NoteOwnBlow(blowAt)
assert(KB:Get(A.name) == 4, "a late-processed blow lost the honorable kill that came after it")
-- Dated at the event, the HONOR_FIRST_SEC rule is unchanged: an honorable kill 3 s before it
-- stays someone else's.
now = now + KB.PAIR_SEC + 1
KB:NoteOwnHonorable(1); now = now + 3
local lateAt = now
now = now + 0.5; KB:NoteOwnBlow(lateAt)
assert(KB:Get(A.name) == 4, "an honorable kill 3 s before a late-processed blow paired with it")
-- And PAIR_SEC runs from the blow itself, not from its processing.
now = now + KB.PAIR_SEC + 1
local oldAt = now
now = now + 2; KB:NoteOwnBlow(oldAt)
now = now + KB.PAIR_SEC - 1; KB:NoteOwnHonorable(1)
assert(KB:Get(A.name) == 4, "PAIR_SEC counted from the processing, not from the blow")
now = now + KB.PAIR_SEC + 1

-- 2) Rows of the network: kept at the highest, within the player's honorable kills.
do
    alb.kills["Rank Aa"], alb.playerInfo["Rank Aa"] = 20, info()
    local ok, moved = KB:MergeRow("Rank Aa:5", "Bryn Middle")
    assert(ok and moved and KB:Get("Rank Aa") == 5, "a valid row was not taken")
    ok, moved = KB:MergeRow("Rank Aa:4", "Bryn Middle")
    assert(ok and not moved and KB:Get("Rank Aa") == 5, "a lower row lowered the count")
    ok = KB:MergeRow("Rank Aa:21", "Bryn Middle")
    assert(not ok and KB:Get("Rank Aa") == 5, "a row above the honorable kills was taken")
    assert(not KB:MergeRow("Nobody Known:3", "Bryn Middle"), "a row of a player with no honorable kill was taken")
    for _, bad in ipairs({ "Rank Aa:0", "Rank Aa:-2", "Rank Aa", ":4", "Rank Aa:4:1", "Rank Aa:99999999",
        string.rep("x", 260) .. ":1" }) do
        assert(not KB:MergeRow(bad, "Bryn Middle") and KB:Get("Rank Aa") == 5, "a malformed row was taken: " .. bad)
    end
    local label = KB:ProfileRevision()
    assert(label and KB:ProfileRevision() == label, "the profiles' label moved without a change")
    KB:MergeRow("Rank Aa:6", "Bryn Middle")
    -- (The label moves at most once per 30 s: each move rebuilds the profiles' killing blows.)
    assert(KB:ProfileRevision() == label, "the profiles' label moved at once")
    now = now + 31
    local again = KB:ProfileRevision()
    assert(again and again ~= label and KB:ProfileRevision() == again, "the profiles' label never moved once old enough")
end

-- 3) Another week, another pool: from nothing.
do
    local realStart, realPool = A.Overlord.GetCurrentCampaignStartTs, A.Overlord.GetCurrentLeaderboardSavedVarsPool
    local week = KB:Data().epoch
    A.Overlord.GetCurrentLeaderboardSavedVarsPool = function() return "other-pool" end
    assert(KB:Get("Rank Aa") == 0, "another pool sees this pool's killing blows")
    A.Overlord.GetCurrentLeaderboardSavedVarsPool = realPool
    assert(KB:Get("Rank Aa") == 6, "the pool lost its killing blows")
    A.Overlord.GetCurrentCampaignStartTs = function() return week + 7 * 86400 end
    assert(KB:Get("Rank Aa") == 0, "a new week kept last week's killing blows")
    A.Overlord.GetCurrentCampaignStartTs = realStart
    assert(KB:Get("Rank Aa") == 0, "last week's killing blows came back")
    KB:MergeRow("Rank Aa:6", "Bryn Middle")
    assert(KB:CreditOwn(3) == 3, "our own count did not start again from nothing")
end

-- 4) Pages: the same ranking at A, B and OLD; killing blows at A only.
local names = {}
for i = 1, 60 do
    names[i] = "Rank " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(97 + (i - 1) % 26)
    for _, e in ipairs(clients) do
        e.Overlord.Leaderboard.kills[names[i]] = 20 + i
        e.Overlord.Leaderboard.playerInfo[names[i]] = info()
    end
end
for _, e in ipairs(clients) do
    e.Overlord.Leaderboard.kills[A.name] = 40
    e.Overlord.Leaderboard.playerInfo[A.name] = info()
    e.Overlord.Leaderboard:MarkMetaDirty()
end
for i = 2, 30 do KB:MergeRow(names[i] .. ":" .. i, "Bryn Middle") end
assert(KB:Get(names[30]) == 30)
hello()
pull(B, A)
local BK = B.Overlord.KillingBlows
for i = 1, 30 do
    assert(BK:Get(names[i]) == (i >= 2 and i or i == 1 and 6 or 0), "killing blows of " .. names[i] .. " at B: " .. BK:Get(names[i]))
end
assert(BK:Get(A.name) == 3, "the puller did not take the source's own killing blows")
assert(sent(B, A, "HR", "^8:V:%d+:%d+w%d+b%d+") >= 1, "a pull between 2.5.2 clients was not flagged for killing blows")
-- Equal both ways: nothing comes again.
local mark, changed = now, B.Overlord.Sync._leaderboardPageStats.kbChanged or 0
pull(B, A)
assert((B.Overlord.Sync._leaderboardPageStats.kbChanged or 0) == changed, "killing blows came again between equal clients")

-- 5) With a client without killing blows, nothing of them, either way; its profiles unchanged.
mark = now
pull(OLD, A)
pull(A, OLD)
assert(kbTraffic(A, OLD, mark) == 0, "killing blows were asked of, or sent to, a client without them")
assert(sent(A, OLD, "HR", "^8:V:%d+:%d+w%d+n%d+") >= 1, "the pull of a client without killing blows is flagged for them")
assert(OLD.Overlord.KillingBlows == nil)
-- (Second rounds both ways: equal, no row sent again, killing blows or not.)
local oldStats = OLD.Overlord.Sync._leaderboardPageStats
local before = oldStats.changedRows or 0
pull(OLD, A)
assert((oldStats.changedRows or 0) == before, "rows came again to a client without killing blows")

-- 6) Feed: a killing blow moved at A goes to B (subscribed by its pull), never to OLD.
advance(30)
mark = now
assert(A.Overlord.Sync._leaderboardFeed.subs[B.name:lower()], "B did not subscribe to A's feed")
assert(A.Overlord.Sync._leaderboardFeed.subs[OLD.name:lower()], "OLD did not subscribe to A's feed")
KB:MergeRow(names[40] .. ":17", "Bryn Middle")
advance(40)
assert(BK:Get(names[40]) == 17, "a killing blow did not travel by the feed: " .. BK:Get(names[40]))
assert(kbTraffic(A, OLD, mark) == 0, "a feed row of killing blows went to a client without them")
assert(sent(B, A, "HB", "^8:U:", mark) == 0, "the feed row went back to its source")
-- A feed row goes out named as A's ranking names the player and within its honorable kills,
-- whatever spelling and total A was handed first.
do
    local key = A.Overlord.Leaderboard:GetNetworkRowKey(names[41])
    local data = KB:Data()
    data.counts[key] = 70
    mark = now
    A.Overlord.Sync._NoteKillingBlowMoved(key)
    advance(40)
    assert(sent(A, B, "HB", "b" .. names[41] .. ":61", mark) > 0, "the feed row is not the ranking's own")
    assert(BK:Get(names[41]) == 61, "the capped feed row was refused: " .. BK:Get(names[41]))
end
-- A killing blow row waits in the feed queue of a subscriber that reads them only.
do
    local oldSub = A.Overlord.Sync._leaderboardFeed.subs[OLD.name:lower()]
    for id in pairs(oldSub.has) do assert(id:sub(1, 1) ~= "b", "a killing blow row queued for a client without them") end
    assert((A.Overlord.Sync._leaderboardPageStats.feedKBSkipped or 0) >= 1, "the row for the old client was not skipped")
end
-- 2.5.5: a killing blow row waits, whatever the feed's load (2.5.2 dropped it, for good, past
-- 70 % of the minute's messages or a quarter of the subscriber's queue). In a busy minute no
-- message leaves for it alone; the next message a kill row makes carries it, in one whisper.
-- How many rows "b" each feed message from one client to another carried since a moment.
local function kbRowsByMessage(from, to, since)
    local out = {}
    for _, row in ipairs(wire) do
        if row.from == from.name and row.to == to.name and row.kind == "HB" and row.at >= since
            and row.payload:find("^8:U:") then
            local blob, pos, count, kills = row.payload:match("^8:U:%d+:(.*)$"), 1, 0, 0
            while pos <= #blob do
                local prefix, stop = blob:match("^(%d+)():", pos)
                if not prefix then break end
                local kind = blob:sub(stop + 1, stop + 1)
                if kind == "b" then count = count + 1 elseif kind == "s" or kind == "k" then kills = kills + 1 end
                pos = stop + 1 + tonumber(prefix)
            end
            out[#out + 1] = { kb = count, kills = kills }
        end
    end
    return out
end
do
    local feed = A.Overlord.Sync._leaderboardFeed
    local astats = A.Overlord.Sync._leaderboardPageStats
    local sub, minute = feed.subs[B.name:lower()], feed.minute
    local savedAt, savedCount = minute.at, minute.count
    local skipped = astats.feedKBSkipped or 0
    minute.at, minute.count = now, math.ceil(feed.PER_MIN * 0.7)
    local key = A.Overlord.Leaderboard:GetNetworkRowKey(names[42])
    KB:Data().counts[key] = 5
    mark = now
    A.Overlord.Sync._NoteKillingBlowMoved(key)
    assert(sub.kb and sub.kb.has[key] and sub.kb.count == 1, "a killing blow row was dropped while the feed's minute was 70 % spent")
    A.Overlord.Sync._NoteKillingBlowMoved(key)
    assert(sub.kb.count == 1, "the same player waits twice")
    advance(20)
    for _, message in ipairs(kbRowsByMessage(A, B, mark)) do
        assert(message.kb == 0, "a message left for killing blows alone in a busy minute")
    end
    assert(BK:Get(names[42]) == 0 and sub.kb.has[key], "fixture: the row did not wait")
    -- A kill row moves: its message carries the waiting row, and uses no whisper more.
    local sentBefore, whispersBefore = astats.feedSent or 0, astats.feedWhispers or 0
    A.Overlord.Leaderboard:SetPlayerKills(names[43], 500, true)
    advance(20)
    assert(B.Overlord.Leaderboard.kills[names[43]] == 500, "fixture: the kill row did not travel")
    assert(BK:Get(names[42]) == 5, "the waiting killing blow row did not ride the kill row's message: " .. BK:Get(names[42]))
    assert(not sub.kb.has[key] and sub.kb.count == 0, "the row sent still waits")
    assert((astats.feedWhispers or 0) - whispersBefore == (astats.feedSent or 0) - sentBefore,
        "a killing blow row opened a whisper of its own")
    minute.at, minute.count = savedAt, savedCount
    -- Messages whose kill rows leave no room at the end of their last whisper (here eight short
    -- rows, a whisper full to five bytes): the killing blow row waits, however many of them
    -- leave, and no kill row is ever held back for it (the killing blows never come before the
    -- kills). It leaves once the kill rows stop.
    do
        advance(70)
        local waiting = A.Overlord.Leaderboard:GetNetworkRowKey(names[44])
        KB:Data().counts[waiting] = 4
        local feedWhispers, feedSent = astats.feedWhispers or 0, astats.feedSent or 0
        local rounds = 6
        for round = 1, rounds do
            mark = now
            -- (A busy minute: no message for the killing blow row alone.)
            minute.at, minute.count = now, math.ceil(feed.PER_MIN * 0.7)
            for i = 1, 8 do A.Overlord.Leaderboard:SetPlayerKills(names[i], 100 + 10 * round + i, true) end
            if round == 1 then A.Overlord.Sync._NoteKillingBlowMoved(waiting) end
            advance(10)
            -- (The round's first message with kill rows; a word to a keep-alive may come too.)
            local first
            for _, message in ipairs(kbRowsByMessage(A, B, mark)) do
                if message.kills > 0 then first = first or message end
            end
            assert(first, "fixture: no message in round " .. round)
            assert(first.kills == 8 and first.kb == 0 and sub.kb.has[waiting],
                "round " .. round .. ": a killing blow row took room from the kill rows: " .. first.kills
                .. " kill rows, " .. first.kb .. " killing blow rows")
        end
        assert((astats.feedWhispers or 0) - feedWhispers == (astats.feedSent or 0) - feedSent, "a waiting row opened a whisper")
        for i = 1, 8 do
            assert(B.Overlord.Leaderboard.kills[names[i]] == 100 + 10 * rounds + i, "a kill row was held back for a killing blow row")
        end
        minute.at, minute.count = now - 60, 0
        advance(20)
        assert(BK:Get(names[44]) == 4 and not sub.kb.has[waiting], "the waiting row did not leave once the kill rows stopped")
    end
    -- A subscriber's queue full of kill rows: the killing blow rows wait all the same, leave in
    -- what the kill rows leave of their whispers, and every row of both kinds arrives.
    advance(70)
    mark = now
    -- (In two frames: the feed notes BULK_PER_FRAME totals of one frame at most.)
    for i = 1, 45 do A.Overlord.Leaderboard:SetPlayerKills(names[i], 600 + i, true) end
    advance(0.2)
    for i = 46, 60 do A.Overlord.Leaderboard:SetPlayerKills(names[i], 600 + i, true) end
    assert(sub.count == 60, "fixture: the subscriber's queue does not hold the 60 kill rows: " .. sub.count)
    for i = 2, 21 do KB:MergeRow(names[i] .. ":" .. (i + 5), "Olde Elder") end
    assert(sub.kb.count == 20, "killing blow rows were dropped behind a queue of kill rows: " .. sub.kb.count)
    advance(120)
    for _, message in ipairs(kbRowsByMessage(A, B, mark)) do
        assert(message.kills + message.kb <= feed.ROWS_MAX, "a message over its rows")
    end
    for i = 2, 21 do
        assert(BK:Get(names[i]) == i + 5, "a killing blow row waiting behind kill rows never arrived: " .. names[i])
    end
    for i = 1, 60 do assert(B.Overlord.Leaderboard.kills[names[i]] == 600 + i, "a kill row was lost to the killing blows") end
    assert(sub.kb.count == 0 and next(sub.kb.has) == nil, "rows sent still wait")
    -- Messages full of long kill rows (their bytes are spent before their rows), and a killing
    -- blow row of the longest kind first in the list: it waits for a message with that much
    -- room and does not hold the rows behind it for good. Everything arrives, in no whisper more.
    do
        local long = {}
        for i = 1, 30 do
            long[i] = "Abcdefghij" .. string.char(96 + math.ceil(i / 26)) .. string.char(97 + (i - 1) % 26) .. " Mnopqrstuvwx"
            for _, e in ipairs(clients) do
                e.Overlord.Leaderboard.kills[long[i]] = 100 + i
                e.Overlord.Leaderboard.playerInfo[long[i]] = info()
                e.Overlord.Leaderboard:MarkMetaDirty()
            end
        end
        advance(70)
        mark = now
        local feedWhispers, feedSent = astats.feedWhispers or 0, astats.feedSent or 0
        for i = 1, 30 do A.Overlord.Leaderboard:SetPlayerKills(long[i], 700 + i, true) end
        assert(select(2, KB:MergeRow(long[1] .. ":99", "Olde Elder")), "fixture: the long row was not taken")
        for i = 22, 30 do KB:MergeRow(names[i] .. ":" .. (i + 7), "Olde Elder") end
        advance(120)
        for _, message in ipairs(kbRowsByMessage(A, B, mark)) do
            assert(message.kills + message.kb <= feed.ROWS_MAX, "a message over its rows")
        end
        assert(BK:Get(long[1]) == 99, "a killing blow row of the longest kind never arrived: " .. BK:Get(long[1]))
        for i = 22, 30 do assert(BK:Get(names[i]) == i + 7, "a killing blow row behind a long one never arrived") end
        for i = 1, 30 do assert(B.Overlord.Leaderboard.kills[long[i]] == 700 + i, "a long kill row was lost") end
        assert((astats.feedWhispers or 0) - feedWhispers <= ((astats.feedSent or 0) - feedSent) * feed.PIECES, "a message over its whispers")
    end
    -- With no kill row to ride, a message leaves for killing blow rows alone only once
    -- KB_ALONE_ROWS wait, or the oldest has waited KB_ALONE_SEC (one message per row would spend
    -- the bytes the kill rows need).
    advance(70)
    KB:MergeRow(names[31] .. ":3", "Olde Elder")
    advance(feed.KB_ALONE_SEC - 10)
    assert(BK:Get(names[31]) == 0 and sub.kb.has[A.Overlord.Leaderboard:GetNetworkRowKey(names[31])],
        "a single killing blow row made a message of its own at once")
    advance(25)
    assert(BK:Get(names[31]) == 3, "a single killing blow row never left: " .. BK:Get(names[31]))
    advance(70)
    for i = 32, 31 + feed.KB_ALONE_ROWS do KB:MergeRow(names[i] .. ":4", "Olde Elder") end
    advance(15)
    for i = 32, 31 + feed.KB_ALONE_ROWS do
        assert(BK:Get(names[i]) == 4, "a batch of killing blow rows waited as a single one does: " .. names[i])
    end
    -- More players waiting than KB_PENDING_MAX: the rest is left to the stream LB, and counted.
    local saved = feed.KB_PENDING_MAX
    feed.KB_PENDING_MAX = 2
    skipped = astats.feedKBSkipped or 0
    for i = 45, 48 do
        local k = A.Overlord.Leaderboard:GetNetworkRowKey(names[i])
        KB:Data().counts[k] = 3
        A.Overlord.Sync._NoteKillingBlowMoved(k)
    end
    -- (Two of the four for this subscriber, the four of the subscriber without killing blows.)
    assert(sub.kb.count == 2 and (astats.feedKBSkipped or 0) == skipped + 2 + 4, "the waiting list has no bound")
    feed.KB_PENDING_MAX = saved
    advance(40)
end

-- 7) Sweeps carry killing blows once every KB_SWEEP_SEC; only the players of the copy's kill
--    rows, under their spelling, within their kills; a move of killing blows alone rebuilds LB only.
do
    -- (A serves a copy of its ranking as it is now: only the killing blows move from here on.
    -- Late enough for the killing blows to be due and compared here, whatever came before.)
    advance(1801)
    hello()
    pull(B, A)
    local data = KB:Data()
    data.counts["ghost player"] = 9
    local capped = names[50]
    local cappedKills = A.Overlord.Leaderboard.kills[capped]
    data.counts[A.Overlord.Leaderboard:GetNetworkRowKey(capped)] = 999
    KB.revision, KB.served = KB.revision + 1, nil
    local kbOnly = A.Overlord.Sync._leaderboardPageStats.profileKBOnly or 0
    -- Within half an hour of the last sweep with them: none.
    advance(700)
    hello()
    mark = now
    pull(B, A)
    assert(sent(B, A, "HR", "^8:V:%d+:%d+w%d+n%d+", mark) >= 1 and sent(B, A, "HR", "^8:V:%d+:%d+w%d+b%d+", mark) == 0,
        "killing blows swept again within half an hour")
    assert(BK:Get(capped) == 0, "killing blows came by a sweep without them")
    advance(1801)
    hello()
    -- A pull cut before the stream LB leaves the window open (it counts from LB itself).
    assert(B.Overlord.Sync:StartCompletePagedLeaderboardCatchup(A.name, function() end))
    assert(B.Overlord.Sync:CancelPagedLeaderboardCatchup(), "fixture: no pull to cut")
    advance(5)
    mark = now
    pull(B, A)
    assert(sent(B, A, "HR", "^8:V:%d+:%d+w%d+b%d+", mark) >= 1, "killing blows never swept again")
    assert(cappedKills < 999 and BK:Get(capped) == cappedKills, "a count above the copy's kills did not come down to them: " .. BK:Get(capped))
    assert(BK:Get("Ghost Player") == 0, "a player outside the copy's kill rows was sent")
    local cappedKey = B.Overlord.Leaderboard:GetNetworkRowKey(capped)
    assert(BK:Counts()[cappedKey] == cappedKills and BK:Data().names == nil, "the killing blows table holds names")
    -- (A table saved with names by an earlier build of 2.5.2 lets them go, counts kept.)
    BK:Data().names = { [cappedKey] = capped }
    assert(BK:Data().names == nil and BK:Counts()[cappedKey] == cappedKills, "the saved names were kept")
    assert((A.Overlord.Sync._leaderboardPageStats.profileKBOnly or 0) > kbOnly, "a move of killing blows alone rebuilt the whole profile")
    -- Equal now, both sides: nothing comes again at the next sweep with them.
    local before = B.Overlord.Sync._leaderboardPageStats.kbChanged or 0
    advance(1801)
    hello()
    pull(B, A)
    assert((B.Overlord.Sync._leaderboardPageStats.kbChanged or 0) == before, "killing blows came again between equal copies")
end

-- 7b) 2.5.5: the killing blows' own turn. Once they are due, a pull that would start at the
--     kills compares the stream LB alone, then the kills' pull follows at once with the same
--     neighbour (one free to answer is rare on a busy evening: the turn must not spend it).
--     (At the end of a sweep only, LB was hardly ever reached while two rankings differed.)
do
    local turns = B.Overlord.Sync._killingBlowTurns
    local bstats = B.Overlord.Sync._leaderboardPageStats
    local function hold(i, count)
        -- (Straight into the table: no feed row, only the stream can bring it.)
        KB:Data().counts[A.Overlord.Leaderboard:GetNetworkRowKey(names[i])] = count
        KB.revision, KB.served = KB.revision + 1, nil
    end
    hold(51, 7)
    advance(1801)
    hello()
    mark = now
    local before = bstats.kbTurns or 0
    pull(B, A)
    assert((bstats.kbTurns or 0) == before + 1, "killing blows due: the pull was not their turn")
    assert(sent(B, A, "HR", "^8:V:%d+:%d+w%d+b%d+f?:1:LB:", mark) == 1, "the turn did not open at the stream LB")
    assert(BK:Get(names[51]) == 7, "the turn did not bring the killing blows: " .. BK:Get(names[51]))
    -- The turn told its end, and the kills' pull followed with the same neighbour: a second
    -- pull (its own first request), without the killing blows (compared a moment ago).
    assert((bstats.kbTurnsFollowed or 0) >= 1, "the kills' pull did not follow the turn")
    assert(sent(B, A, "HR", "^8:F:", mark) >= 1, "the turn did not tell its end")
    assert(sent(B, A, "HR", "^8:V:%d+:%d+w%d+n%d+f?:1:LK:", mark) == 1, "the pull after the turn is not a plain pull of the kills")
    assert(sent(B, A, "HR", "^8:V:%d+:%w+:%d+:LB:", mark) == 1, "the pull after the turn asked the killing blows again")
    assert(bstats.result == "sweep received", tostring(bstats.result))
    assert(B.OverlordDB.leaderboardPageProgress.shared.stream == "LK", "the turn left the sweep at the stream LB")
    -- When that pull cannot start (this client in a fight), the round ends on the turn: it
    -- compared no kill row, and must not leave the previous sweep to be read as one of now.
    do
        hold(60, 3)
        advance(1801)
        hello()
        local start = B.Overlord.Sync.StartPagedLeaderboardCatchup
        local calls = 0
        B.Overlord.Sync.StartPagedLeaderboardCatchup = function(self, ...)
            calls = calls + 1
            if calls == 1 then return start(self, ...) end
            return false, "local"
        end
        pull(B, A)
        B.Overlord.Sync.StartPagedLeaderboardCatchup = start
        assert(calls == 2 and BK:Get(names[60]) == 3, "fixture: no turn, or no pull tried after it")
        assert(bstats.result == "killing blows compared", tostring(bstats.result))
        assert(bstats.lastSweepFull == false and bstats.lastSweepChanged == 0, "a turn left the last sweep's figures to be read again")
        assert(B.OverlordDB.leaderboardPageProgress.shared.stream == "LK", "the turn left the sweep at the stream LB")
    end
    -- The next pull is the kills', without killing blows (compared a moment ago).
    advance(5)
    mark = now
    pull(B, A)
    assert(sent(B, A, "HR", "^8:V:%d+:%d+w%d+n%d+f?:1:LK:", mark) == 1 and sent(B, A, "HR", ":LB:", mark) == 0,
        "the pull after a turn is not a plain pull of the kills")
    -- A turn ends on its time: told to the responder, counted, and the killing blows are due
    -- again at once for a sweep that reaches them (a turn only GAP later): the kills' pull that
    -- follows it is such a sweep, here it reaches them and brings what the turn left.
    for i = 52, 59 do hold(i, i - 40) end
    advance(1801)
    hello()
    local savedSec, cut = turns.SEC, bstats.kbTurnsCut or 0
    turns.SEC = 0
    mark = now
    before = bstats.kbTurns or 0
    pull(B, A)
    turns.SEC = savedSec
    assert((bstats.kbTurns or 0) == before + 1 and (bstats.kbTurnsCut or 0) == cut + 1, "a turn past its time went on")
    assert(sent(B, A, "HR", "^8:V:%d+:%d+w%d+b%d+f?:1:LK:", mark) == 1,
        "the pull after a cut turn is a second turn, or forgot the killing blows")
    for i = 52, 59 do assert(BK:Get(names[i]) == i - 40, "the sweep after a cut turn did not bring " .. names[i]) end
    assert(B.OverlordDB.leaderboardPageProgress.shared.stream == "LK", "a cut turn left the sweep at the stream LB")
    -- A neighbour that answers "busy" compared nothing: the turn stays due for the next one asked.
    do
        hold(49, 5)
        advance(1801)
        hello()
        local turnAt = turns.at
        A.InCombatLockdown = function() return true end
        local done
        before = bstats.kbTurns or 0
        assert(B.Overlord.Sync:StartCompletePagedLeaderboardCatchup(A.name, function(ok) done = ok end))
        for _ = 1, 60 do advance(10); if done ~= nil then break end end
        A.InCombatLockdown = function() return false end
        assert(done == false and (bstats.kbTurns or 0) == before + 1 and tostring(bstats.result):find("peer in combat", 1, true),
            "fixture: " .. tostring(bstats.result))
        assert(turns.at == turnAt, "a turn a busy peer refused was spent")
        hello()
        pull(B, A)
        assert((bstats.kbTurns or 0) == before + 2 and BK:Get(names[49]) == 5, "the turn did not come again after a busy peer")
    end
    -- No turn while the session's first pull is younger than FIRST_SEC (a login fills its ranking first).
    hold(51, 8)
    advance(1801)
    hello()
    local savedFirst = turns.firstPullAt
    turns.firstPullAt = now - turns.FIRST_SEC + 30
    before = bstats.kbTurns or 0
    mark = now
    pull(B, A)
    turns.firstPullAt = savedFirst
    assert((bstats.kbTurns or 0) == before and sent(B, A, "HR", "^8:V:%d+:%d+w%d+b%d+f?:1:LK:", mark) == 1,
        "a turn of the killing blows before the session's first pull was old enough")
    assert(BK:Get(names[51]) == 8, "the sweep did not bring the killing blows at its end")
end

-- 7c) 2.5.5: nothing of the killing blows is dropped on its way, and a count that no longer
--     moves is told all the same (report of 2026-11-17 on the captures, the same holes here:
--     8 whole clients, a player logging in with 37 killing blows of its own, none of the 7
--     others held them after 50 min).
do
    local afeed, bfeed = A.Overlord.Sync._leaderboardFeed, B.Overlord.Sync._leaderboardFeed
    local astats, bstats = A.Overlord.Sync._leaderboardPageStats, B.Overlord.Sync._leaderboardPageStats
    local lowerA, lowerB = A.name:lower(), B.name:lower()
    local function keyOf(e, name) return e.Overlord.Leaderboard:GetNetworkRowKey(name) end
    -- (A count put into a table with no word to the feed: made while nobody listened.)
    local function holdAt(e, name, count)
        local blows = e.Overlord.KillingBlows
        blows:Data().counts[keyOf(e, name)] = count
        blows.revision, blows.served = blows.revision + 1, nil
    end
    local function subscribeAfresh(source, subscriber)
        local sfeed, lower = source.Overlord.Sync._leaderboardFeed, subscriber.name:lower()
        if sfeed.subs[lower] then sfeed.subs[lower], sfeed.subCount = nil, sfeed.subCount - 1 end
        subscriber.Overlord.Sync._leaderboardFeed.asked[source.name:lower()] = now
        assert(sfeed.subscribe(subscriber.name, nil, true), "fixture: no subscription")
        return sfeed.subs[lower]
    end
    for _, e in ipairs(clients) do
        -- (Through the ranking's own door: a killing blow count travels within the kills held.)
        e.Overlord.Leaderboard.playerInfo[B.name] = info()
        e.Overlord.Leaderboard:MarkMetaDirty()
        e.Overlord.Leaderboard:SetPlayerKills(A.name, 400, true)
        e.Overlord.Leaderboard:SetPlayerKills(B.name, 400, true)
    end
    advance(5)
    hello()

    -- A new subscriber is handed our own killing blows, whenever they were made.
    holdAt(A, A.name, 61)
    mark = now
    subscribeAfresh(A, B)
    advance(afeed.KB_ALONE_SEC + 30)
    assert(BK:Get(A.name) == 61, "a new subscriber was not handed our own killing blows: " .. BK:Get(A.name))

    -- Our own killing blows go UP to the peer that feeds us, at its first word: B holds 44 of
    -- its own that A lacks, and A is a source of B again.
    holdAt(B, B.name, 44)
    assert(KB:Get(B.name) == 0, "fixture: A already holds B's killing blows")
    bfeed.sources[lowerA], bfeed.asked[lowerA] = nil, now
    mark = now
    alb:SetPlayerKills(names[1], (alb.kills[names[1]] or 0) + 1, true)
    -- (B's indexes are rebuilt after the kills set above: the row is asked again 30 s later.)
    advance(50)
    assert(sent(B, A, "HR", "^8:C:%d+:%d+:b" .. B.name .. ":44$", mark) == 1, "the new source was not told our own killing blows, once")
    assert(KB:Get(B.name) == 44, "the source did not take its subscriber's own killing blows: " .. KB:Get(B.name))
    -- While they move: KB_UP_SEC apart, never a whisper per kill.
    mark = now
    for step = 1, 5 do
        holdAt(B, B.name, 44 + step)
        B.Overlord.Sync._NoteKillingBlowMoved(keyOf(B, B.name))
        advance(10)
    end
    -- (Well past the gap a source reads two messages apart: only KB_UP_SEC holds them back.)
    advance(2 * bfeed.CAPTURE_UP_GAP + 30)
    assert(bfeed.KB_UP_SEC > 2 * bfeed.CAPTURE_UP_GAP + 80, "fixture: KB_UP_SEC too short for this check")
    assert(sent(B, A, "HR", "^8:C:", mark) == 0, "our own killing blows went up at every kill")
    advance(bfeed.KB_UP_SEC)
    assert(sent(B, A, "HR", "^8:C:%d+:%d+:b" .. B.name .. ":49$", mark) == 1 and KB:Get(B.name) == 49,
        "our own killing blows did not go up after KB_UP_SEC: " .. KB:Get(B.name))
    -- (Audit) Killing blows alone never go up while the feed has used half of its minute: the
    -- kill rows first. They wait, and leave in a quieter minute. [6g]
    do
        advance(bfeed.CAPTURE_UP_GAP + 10)
        holdAt(B, B.name, 50)
        mark = now
        local minute = bfeed.minute
        minute.at, minute.count = now, bfeed.PER_MIN / 2
        bfeed.ownCaptureUp()
        advance(2)
        assert(sent(B, A, "HR", "^8:C:", mark) == 0, "killing blows alone went up in a busy minute")
        advance(100)
        assert(sent(B, A, "HR", "^8:C:%d+:%d+:b" .. B.name .. ":50$", mark) == 1 and KB:Get(B.name) == 50,
            "killing blows held back by a busy minute never went up: " .. KB:Get(B.name))
    end
    -- (Audit) Our very first killing blow arms the upward timer: our identity is known to the
    -- feed before we hold any. [6h]
    do
        advance(bfeed.KB_UP_SEC + 5)
        assert(not bfeed.kbUpTimer, "fixture: an upward timer is still armed")
        local key = keyOf(B, B.name)
        local blows = B.Overlord.KillingBlows
        local saved = blows:Data().counts[key]
        blows:Data().counts[key] = nil
        bfeed.ownKey = nil
        bfeed.ownCaptureUp()
        blows:Data().counts[key] = 1
        B.Overlord.Sync._NoteKillingBlowMoved(key)
        assert(bfeed.kbUpTimer == true, "a first killing blow did not arm the upward timer")
        blows:Data().counts[key] = saved
        blows.revision, blows.served = blows.revision + 1, nil
        advance(bfeed.KB_UP_SEC + 5)
    end
    -- (Final audit) A player with many captured zones AND killing blows: its two rows together
    -- make an upward message of more than 180 bytes. Counted dearer than the feed's bucket
    -- holds, that message never left: the count of the best capturers did not go up. [6i]
    do
        advance(bfeed.CAPTURE_UP_GAP + 10)
        -- (This fixture holds no map: the lookups a capture row makes on arrival.)
        for _, e in ipairs({ A, B }) do
            e.Overlord.Zones = e.Overlord.Zones or {}
            e.Overlord.Zones.GetZone = e.Overlord.Zones.GetZone or function() return nil end
            e.Overlord.Fronts = e.Overlord.Fronts or {}
            e.Overlord.Fronts.IsKnownZoneId = e.Overlord.Fronts.IsKnownZoneId or function() return false end
        end
        local list = {}
        for i = 1, 14 do list[i] = string.format("fixture_point_%02d", i) end
        local blb = B.Overlord.Leaderboard
        blb.captures[B.name] = list
        local note = blb.OnNetworkRowMoved
        blb.OnNetworkRowMoved = nil
        blb:SetPlayerCaptureCount(B.name, 14, true)
        blb.OnNetworkRowMoved = note
        holdAt(B, B.name, BK:Get(B.name) + 1)
        local blows = BK:Get(B.name)
        mark = now
        bfeed.ownCaptureUp()
        -- (The row is asked again 30 s later while the indexes are rebuilt.)
        advance(70)
        local length
        for _, row in ipairs(wire) do
            if row.from == B.name and row.to == A.name and row.kind == "HR" and row.at >= mark and row.payload:find("^8:C:") then
                length = #row.payload
            end
        end
        assert(length and length > 180 and length <= 250,
            "the upward message of a player with many zones and killing blows did not leave: " .. tostring(length))
        assert(tonumber(alb.captureCount[B.name]) == 14 and KB:Get(B.name) == blows,
            "the two rows of a long upward message were not both taken: " .. tostring(alb.captureCount[B.name]) .. "/" .. KB:Get(B.name))
    end
    -- (Final audit) With nobody feeding us there is nothing to tell upward, and no timer is
    -- armed for it (in a fight every row "waits": the timer came back every 30 s for nothing). [6j]
    do
        advance(60)
        assert(not bfeed.captureUpTimer, "fixture: an upward timer is still armed")
        local saved = bfeed.sources
        bfeed.sources = {}
        -- (A row that cannot be built in a fight "waits": that is what armed the timer.)
        local blb = B.Overlord.Leaderboard
        local live = blb.GetLiveNetworkRow
        blb.GetLiveNetworkRow = function() return nil end
        B.InCombatLockdown = function() return true end
        holdAt(B, B.name, BK:Get(B.name) + 1)
        bfeed.ownCaptureUp()
        B.InCombatLockdown = function() return false end
        blb.GetLiveNetworkRow = live
        bfeed.sources = saved
        assert(not bfeed.captureUpTimer, "an upward timer was armed with nobody feeding us")
    end
    -- Another player's killing blows from a subscriber: not read.
    do
        advance(afeed.CAPTURE_UP_GAP + 5)
        local epochText
        for _, row in ipairs(wire) do epochText = row.payload:match("^8:C:(%d+):") or epochText end
        local heldBefore = KB:Get(names[2])
        assert(heldBefore + 1 <= alb.kills[names[2]], "fixture: no room under the kills held")
        local foreign = "b" .. names[2] .. ":" .. (heldBefore + 1)
        local refused = astats.feedCapturesUpRefused or 0
        B.Overlord.Sync:SendWhisper("HR", "8:C:" .. epochText .. ":" .. #foreign .. ":" .. foreign, A.name)
        advance(5)
        assert(KB:Get(names[2]) == heldBefore, "a subscriber raised another player's killing blows: " .. KB:Get(names[2]))
        assert((astats.feedCapturesUpRefused or 0) == refused + 1, "a foreign row from below was not counted as refused")
    end

    -- A subscriber whose presence was not heard in the last five minutes: its rows WAIT (they
    -- were dropped), and leave once its presence says it reads them.
    do
        local sub = subscribeAfresh(A, B)
        advance(60)
        -- (Its presence grows old: nothing is said for six minutes but the feed's own words.)
        advance(360)
        sub.kbOk = nil
        local skipped = astats.feedKBSkipped or 0
        local waiting = KB:Get(names[40]) + 1
        assert(waiting <= alb.kills[names[40]], "fixture: no room under the kills held")
        KB:MergeRow(names[40] .. ":" .. waiting, "Olde Elder")
        assert(sub.kb and sub.kb.has[keyOf(A, names[40])], "a row for a subscriber of unknown presence did not wait")
        assert((astats.feedKBSkipped or 0) <= skipped + 1, "fixture: more than the subscriber without killing blows left it out")
        advance(60)
        assert(BK:Get(names[40]) < waiting, "fixture: the row left for a subscriber whose presence is not fresh")
        hello()
        alb:SetPlayerKills(names[3], (alb.kills[names[3]] or 0) + 1, true)
        advance(60)
        assert(BK:Get(names[40]) == waiting, "a row that waited for a presence never left: " .. BK:Get(names[40]))
    end

    -- A busy inbox puts a killing blow row aside, and reads it once no kill row waits (it was
    -- dropped, and its sender had counted it as told).
    do
        hello()
        local epochText
        for _, row in ipairs(wire) do epochText = row.payload:match("^8:U:(%d+):") or epochText end
        local blow41, blow42 = BK:Get(names[41]) + 1, BK:Get(names[42]) + 1
        local rows = { "s" .. names[5] .. ":2005", "b" .. names[41] .. ":" .. blow41, "s" .. names[6] .. ":2006", "b" .. names[42] .. ":" .. blow42 }
        local parts = {}
        for i, row in ipairs(rows) do parts[i] = #row .. ":" .. row end
        local savedMax, skipped, aside = bfeed.INBOX_MAX, bstats.feedKBSkipped or 0, bstats.feedKBLater or 0
        bfeed.INBOX_MAX = 2
        bfeed.sources[lowerA] = now
        A.Overlord.Sync:SendWhisper("HB", "8:U:" .. epochText .. ":" .. table.concat(parts), B.name)
        advance(5)
        bfeed.INBOX_MAX = savedMax
        assert((bstats.feedKBLater or 0) == aside + 2, "fixture: the killing blow rows were not put aside: " .. tostring(bstats.feedKBLater))
        assert(B.Overlord.Leaderboard.kills[names[5]] == 2005, "fixture: the kill row was not read")
        assert(BK:Get(names[41]) == blow41 and BK:Get(names[42]) == blow42, "a killing blow row put aside was not read: "
            .. BK:Get(names[41]) .. "/" .. BK:Get(names[42]))
        assert((bstats.feedKBSkipped or 0) == skipped and bfeed.kbLater == nil, "a row put aside was counted as left out, or the list stayed")
    end
end

-- 8) A counter catching up (login, after an instance) never pairs with a blow of ours.
do
    local combat = A.Overlord.Combat
    local had = KB:Get(A.name)
    alb.kills[A.name] = 400
    KB:NoteOwnBlow()
    combat:CreditHonorableKills(3, true)
    assert(KB:Get(A.name) == had, "honorable kills of a catch-up paired with our blow")
    now = now + 0.5
    combat:CreditHonorableKills(1)
    assert(KB:Get(A.name) == had + 1, "a live honorable kill did not pair with our blow")
end
print("forever_killing_blows: OK")
