-- 2.5.5: capture totals reach everybody (report of 2026-11-17: a player's captures of the night
-- never left its client, two guild mates 11 captures apart for two days). Three holes: the feed
-- sent a capture row with every zone of its player, too long for any message past a dozen zones;
-- a count only left toward the peers its holder feeds, and only when it moved; and a sweep never
-- reached the captures while two kill rankings differed (they are now compared first).
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
    -- (A front of fixture zones: a capture row is long by the zones its player captured.)
    local front = { zones = {} }
    for i = 1, 40 do front.zones[i] = { id = string.format("fixture_point_%02d", i) } end
    e.Overlord.Fronts.Registry.fixture_front = front
    e.Overlord.Zones = e.Overlord.Zones or {}
    e.Overlord.Zones.GetZone = e.Overlord.Zones.GetZone or function() return nil end
    e.Overlord.Fronts.IsKnownZoneId = e.Overlord.Fronts.IsKnownZoneId or function() return false end
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

local function hello()
    for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
    advance(10)
end
local function captureOf(e, name) return tonumber(e.Overlord.Leaderboard.captureCount[name]) or 0 end
-- A count put into a ranking with no word to the feed (made while nobody listened).
local function holdSilently(e, name, count, zones)
    local lb = e.Overlord.Leaderboard
    local note = lb.OnNetworkRowMoved
    lb.OnNetworkRowMoved = nil
    if zones then lb.captures[name] = zones end
    lb:SetPlayerCaptureCount(name, count, true)
    lb.OnNetworkRowMoved = note
    assert(captureOf(e, name) == count, "fixture: count not held")
end

local A, B, C, D = client("Alda Source"), client("Bryn Middle"), client("Cole Farther"), client("Dara Stranger")
-- (The captures first: the last part's business. The pulls before it are plain sweeps.)
for _, e in ipairs(clients) do e.Overlord.Sync._captureTurns.FIRST_SEC = math.huge end
hello()
local names = {}
for i = 1, 60 do
    names[i] = "Rank " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(97 + (i - 1) % 26)
    for _, e in ipairs(clients) do
        e.Overlord.Leaderboard.kills[names[i]] = i
        e.Overlord.Leaderboard.playerInfo[names[i]] = info()
    end
end
for _, e in ipairs(clients) do
    for _, other in ipairs(clients) do
        other.Overlord.Leaderboard.kills[e.name] = 5
        other.Overlord.Leaderboard.playerInfo[e.name] = info()
    end
end
local zones = {}
for i = 1, 36 do zones[i] = string.format("fixture_point_%02d", i) end
assert(A.Overlord.Leaderboard:IsValidCaptureObjectiveId(zones[36]), "fixture: zones unknown to the ranking")

-- 1. The best capturers. A player with 36 different zones: its page row is over 600 bytes, and
--    the feed sent that very row, which no message holds (2.5.4: dropped at every hand, the
--    count stayed where it was on everybody else's screen). The feed's row is short: the count
--    and the zones that fit.
pull(B, A)
advance(15)
pull(C, B)
advance(15)
local feed = feedOf(A)
assert(feed.subs[B.name:lower()] and feedOf(B).subs[C.name:lower()], "fixture: no subscription")
local top = names[3]
holdSilently(A, top, 40, zones)
do
    local snap = { kills = {}, captureCount = { [top] = 40 }, captures = { [top] = zones }, playerInfo = { [top] = info() } }
    local page = A.Overlord.Sync:BuildPagedLeaderboardCapturePayload(snap, top, 1)
    assert(page and #page > 600, "fixture: the page row of this player is not a long one")
end
local mark = now
A.Overlord.Leaderboard:SetPlayerCaptureCount(top, 41, true)
advance(feed.CAPTURE_LINGER + 40)
assert(captureOf(B, top) == 41, "the count of a player with many zones did not reach the subscriber: " .. captureOf(B, top))
local length
for _, row in ipairs(wire) do
    if row.from == A.name and row.to == B.name and row.kind == "HB" and row.at >= mark then
        length = tonumber(row.payload:match("(%d+):c" .. top .. ":")) or length
    end
end
assert(length and length <= feed.CAPTURE_ROW_MAX + 1, "the capture row of the feed is not a short one: " .. tostring(length))
local heldZones = #(B.Overlord.Leaderboard.captures[top] or {})
assert(heldZones >= 5 and heldZones < 36, "the short row carried no zone, or all of them: " .. heldZones)
advance(feedOf(B).CAPTURE_LINGER + 40)
assert(captureOf(C, top) == 41, "the count did not go on to the second hand: " .. captureOf(C, top))
-- Another part of the list at each count: a few counts later the subscriber holds every zone.
for count = 42, 48 do
    A.Overlord.Leaderboard:SetPlayerCaptureCount(top, count, true)
    advance(feed.CAPTURE_LINGER + 40)
    assert(captureOf(B, top) == count, "count " .. count .. " did not reach the subscriber")
end
assert(#(B.Overlord.Leaderboard.captures[top] or {}) == 36, "the zones never came whole: "
    .. #(B.Overlord.Leaderboard.captures[top] or {}))
-- A short list travels whole, as before.
A.Overlord.Leaderboard.captures[names[4]] = { zones[1], zones[2], zones[3] }
A.Overlord.Leaderboard:SetPlayerCaptureCount(names[4], 3, true)
advance(feed.CAPTURE_LINGER + 40)
assert(captureOf(B, names[4]) == 3 and #(B.Overlord.Leaderboard.captures[names[4]] or {}) == 3, "a short zone list lost zones")
-- A capture count enters a full waiting list (the kill rows of a busy evening), a few of them.
do
    local sub = feed.subs[B.name:lower()]
    local savedMax = feed.PENDING_MAX
    feed.PENDING_MAX = sub.count
    local overflow = statsOf(A).feedOverflow or 0
    A.Overlord.Leaderboard:SetPlayerKills(names[30], 9000, true)
    assert((statsOf(A).feedOverflow or 0) == overflow + 1, "fixture: the list is not full")
    A.Overlord.Leaderboard.captures[names[31]] = { zones[1] }
    A.Overlord.Leaderboard:SetPlayerCaptureCount(names[31], 2, true)
    advance(feed.CAPTURE_LINGER + 2)
    feed.PENDING_MAX = savedMax
    advance(40)
    assert(captureOf(B, names[31]) == 2, "a capture count was dropped at a full waiting list")
end

-- 1b. A long row no longer ends the reading of a message. A 2.5.4 source sends the whole capture
--     row of a player with many zones (through a relay a message holds it): it is taken, and so
--     are the kill rows behind it; a long row of another kind is skipped, not the rows after it.
do
    local epochText
    for _, row in ipairs(wire) do epochText = row.payload:match("^8:U:(%d+):") or epochText end
    assert(epochText, "fixture: no feed message seen")
    local list = {}
    for i = 1, 16 do list[i] = zones[i] end
    local long = "c" .. names[33] .. ":A:WARRIOR:21:" .. table.concat(list, ",") .. ":engb"
    local junk = "x" .. string.rep("y", 280)
    assert(#long > 250 and #long <= feed.MESSAGE_MAX, "fixture: not a long row: " .. #long)
    local function message(rows)
        local parts = {}
        for i, row in ipairs(rows) do parts[i] = #row .. ":" .. row end
        return "8:U:" .. epochText .. ":" .. table.concat(parts)
    end
    A.Overlord.Sync:SendWhisper("HB", message({ long, "s" .. names[34] .. ":3400" }), B.name)
    advance(5)
    assert(captureOf(B, names[33]) == 21, "a long capture row was not read: " .. captureOf(B, names[33]))
    assert(B.Overlord.Leaderboard.kills[names[34]] == 3400, "the kill row behind a long row was lost")
    A.Overlord.Sync:SendWhisper("HB", message({ junk, "s" .. names[35] .. ":3500" }), B.name)
    advance(5)
    assert(B.Overlord.Leaderboard.kills[names[35]] == 3500, "the kill row behind a long row of another kind was lost")
end

-- 2. A player's own count goes UP to the peer that feeds it, at that peer's first word: D made
--    9 captures while nobody listened, then asks A (D becomes A's subscriber: A's ranking goes to
--    D by the pull, nothing of D's goes to A by it).
holdSilently(D, D.name, 9, { zones[1], zones[2] })
advance(feedOf(D).RING_SEC + 10)
hello()
assert(captureOf(A, D.name) == 0, "fixture: A already holds D's captures")
mark = now
pull(D, A)
advance(20)
assert(sentBetween(D, A, "HR", "^8:C:%d+:%d+:c" .. D.name .. ":", mark) == 1, "the new source was not told our own count, once")
assert(captureOf(A, D.name) == 9, "the source did not take its subscriber's own count: " .. captureOf(A, D.name))
assert((statsOf(A).feedCapturesUpTaken or 0) == 1 and (statsOf(D).feedCapturesUp or 0) == 1)
-- And from there down, like any count that moves (after its wait).
advance(feed.CAPTURE_LINGER + 40)
assert(captureOf(B, D.name) == 9, "a count that came up was not passed on down: " .. captureOf(B, D.name))
-- Never back to the player it came from, and not told twice.
assert(sentBetween(A, D, "HB", "^8:U:%d+:.*c" .. D.name .. ":", mark) == 0, "its own count went back to its player")
advance(400)
assert(sentBetween(D, A, "HR", "^8:C:", mark) == 1, "the same count was told up again")
-- A capture of ours: up CAPTURE_LINGER later (its event first on the clients that witness it).
mark = now
-- (With many zones by now: its row is as long as a feed row gets, the upward message nearly
-- fills a whisper. Counted dearer than the feed's bucket holds, it never left.)
D.Overlord.Leaderboard.captures[D.name] = zones
D.Overlord.Leaderboard:SetPlayerCaptureCount(D.name, 10, false)
advance(feedOf(D).CAPTURE_LINGER - 5)
assert(sentBetween(D, A, "HR", "^8:C:", mark) == 0 and captureOf(A, D.name) == 9, "our own count went up before its wait")
advance(30)
assert(sentBetween(D, A, "HR", "^8:C:", mark) == 1 and captureOf(A, D.name) == 10, "our own capture did not go up: "
    .. captureOf(A, D.name))
do
    local longest = 0
    for _, row in ipairs(wire) do
        if row.from == D.name and row.kind == "HR" and row.at >= mark and row.payload:find("^8:C:") then
            longest = math.max(longest, #row.payload)
        end
    end
    assert(longest > 150 and longest <= 250, "fixture: the upward message of a player with many zones is not a long one: " .. longest)
end

-- 3. A new subscriber is handed our own count, whenever it was made.
hello()
mark = now
pull(C, D)
advance(20)
assert(sentBetween(D, C, "HB", "^8:U:%d+:.*%d+:c" .. D.name .. ":", mark) == 1, "a new subscriber was not handed our own count")
assert(captureOf(C, D.name) == 10)

-- 3b. And the capture counts that moved at the source lately: each was told once, to the
--     subscribers of that minute. (D heard none of them: it asked nobody but A, long after.)
do
    local dfeed = feedOf(D)
    D.Overlord.Leaderboard.playerInfo[names[40]], D.Overlord.Leaderboard.kills[names[40]] = info(), 40
    D.Overlord.Leaderboard.captures[names[40]] = { zones[3] }
    D.Overlord.Leaderboard:SetPlayerCaptureCount(names[40], 5, true)
    -- (Told to C, D's subscriber, after its wait; B asks D only later.)
    advance(dfeed.CAPTURE_LINGER + 40)
    assert(captureOf(C, names[40]) == 5 and captureOf(B, names[40]) == 0, "fixture: the count is where it should not be")
    assert(not dfeed.subs[B.name:lower()], "fixture: B is already fed by D")
    hello()
    mark = now
    -- (Straight to the feed: a pull would bring the count by its pages in this quiet world.)
    feedOf(B).asked[D.name:lower()] = now
    assert(dfeed.subscribe(B.name, nil, true), "fixture: no subscription")
    advance(30)
    assert(sentBetween(D, B, "HB", "^8:U:%d+:.*%d+:c" .. names[40] .. ":", mark) == 1, "a new subscriber was not handed a count that moved lately")
    assert(captureOf(B, names[40]) == 5, "the new subscriber did not take it: " .. captureOf(B, names[40]))
    -- Past CAPTURE_RECENT_SEC it is the turns' business, and the list is bounded.
    advance(dfeed.CAPTURE_RECENT_SEC)
    hello()
    mark = now
    dfeed.subs[B.name:lower()], dfeed.subCount = nil, dfeed.subCount - 1
    feedOf(B).asked[D.name:lower()] = now
    assert(dfeed.subscribe(B.name, nil, true))
    advance(30)
    assert(sentBetween(D, B, "HB", "^8:U:%d+:.*%d+:c" .. names[40] .. ":", mark) == 0, "an old move was handed to a new subscriber")
    for i = 1, dfeed.CAPTURE_RECENT_MAX + 20 do dfeed.captureMoved("cfixture " .. i, now + i / 100) end
    assert(dfeed.captureRecentCount == dfeed.CAPTURE_RECENT_MAX, "the recent moves have no bound: " .. tostring(dfeed.captureRecentCount))
    local held = 0
    for _ in pairs(dfeed.captureRecent) do held = held + 1 end
    assert(held == dfeed.CAPTURE_RECENT_MAX and dfeed.captureRecent["cfixture 1"] == nil, "the oldest move did not give way")
    dfeed.captureRecent, dfeed.captureRecentCount = nil, 0
end

-- 4. Only its own row, only from a subscriber of ours, one per CAPTURE_UP_GAP.
do
    local epochText
    for _, row in ipairs(wire) do epochText = row.payload:match("^8:C:(%d+):") or epochText end
    assert(epochText, "fixture: no upward message seen")
    local function up(from, to, name, count)
        local row = "c" .. name .. ":A:WARRIOR:" .. count .. ":" .. zones[5] .. ":engb"
        from.Overlord.Sync:SendWhisper("HR", "8:C:" .. epochText .. ":" .. #row .. ":" .. row, to.name)
        advance(5)
    end
    advance(feed.CAPTURE_UP_GAP + 5)
    local refused = statsOf(A).feedCapturesUpRefused or 0
    -- (Another player's row from a subscriber.)
    up(D, A, names[6], 77)
    assert(captureOf(A, names[6]) == 0 and (statsOf(A).feedCapturesUpRefused or 0) == refused + 1,
        "a subscriber raised another player's count")
    -- (Its own row from a peer we do not feed: nothing is read.)
    assert(not feed.subs[C.name:lower()], "fixture: C is a subscriber of A")
    up(C, A, C.name, 33)
    assert(captureOf(A, C.name) == 0, "a count came up from a peer we do not feed")
    -- (Its own row from a subscriber: taken; a second one within the gap: not read. A message
    -- refused counts for the gap like any other.)
    advance(feed.CAPTURE_UP_GAP + 5)
    up(D, A, D.name, 12)
    assert(captureOf(A, D.name) == 12, "a subscriber's own row was not taken: " .. captureOf(A, D.name))
    up(D, A, D.name, 60)
    assert(captureOf(A, D.name) == 12, "a second row within the gap was read")
    -- (Above the ceiling of a capture count: refused like a page row holding it.)
    advance(feed.CAPTURE_UP_GAP + 5)
    up(D, A, D.name, 500)
    assert(captureOf(A, D.name) == 12, "a count above the ceiling came up")
    -- (A row of another kind, or its own row twice in one message: nothing more is read.)
    advance(feed.CAPTURE_UP_GAP + 5)
    do
        local kill = "s" .. D.name .. ":9000"
        local own = "c" .. D.name .. ":A:WARRIOR:13:" .. zones[5] .. ":engb"
        local twice = "c" .. D.name .. ":A:WARRIOR:20:" .. zones[5] .. ":engb"
        D.Overlord.Sync:SendWhisper("HR", "8:C:" .. epochText .. ":" .. #kill .. ":" .. kill, A.name)
        advance(feed.CAPTURE_UP_GAP + 5)
        assert(A.Overlord.Leaderboard.kills[D.name] ~= 9000, "a kill total came up as a subscriber's own count")
        D.Overlord.Sync:SendWhisper("HR", "8:C:" .. epochText .. ":" .. #own .. ":" .. own .. #twice .. ":" .. twice, A.name)
        advance(5)
        assert(captureOf(A, D.name) == 13, "one message raised a count twice: " .. captureOf(A, D.name))
    end
end

-- 5. The captures first. Once they have not been compared for GAP, a pull that would start at
--    the kills compares the captures first, then goes on with the kills in the same exchange
--    (at the second place of a sweep they were not reached while two kill rankings differed; a
--    pull of their own cost the kills a neighbour free to answer).
do
    local turns, bstats = B.Overlord.Sync._captureTurns, statsOf(B)
    turns.FIRST_SEC = 120
    holdSilently(A, names[20], 6, { zones[7] })
    -- (And a kill total the same pull must bring: the kills are compared in it.)
    do
        local lb = A.Overlord.Leaderboard
        local note = lb.OnNetworkRowMoved
        lb.OnNetworkRowMoved = nil
        lb:SetPlayerKills(names[50], 7777, true)
        lb.OnNetworkRowMoved = note
    end
    advance(turns.GAP + 1)
    hello()
    mark = now
    local before = bstats.capTurns or 0
    pull(B, A)
    assert((bstats.capTurns or 0) == before + 1, "captures due: the pull did not compare them first")
    assert(sentBetween(B, A, "HR", "^8:V:%d+:%w+:1:LC:", mark) == 1, "the pull did not open at the captures")
    assert(sentBetween(B, A, "HR", "^8:V:%d+:%w+:%d+:LK:", mark) == 1, "the pull did not go on with the kills")
    assert(sentBetween(B, A, "HR", "^8:V:%d+:%w+:%d+:LC:", mark) == 1, "the captures were asked a second time after the kills")
    assert(sentBetween(B, A, "HR", "^8:V:%d+:%w+:%d+:LR:", mark) == 1, "the sweep did not go on to the races")
    assert(captureOf(B, names[20]) == 6, "the pull did not bring the captures: " .. captureOf(B, names[20]))
    assert(B.Overlord.Leaderboard.kills[names[50]] == 7777, "the pull did not bring the kills: "
        .. tostring(B.Overlord.Leaderboard.kills[names[50]]))
    assert(bstats.result == "sweep received", tostring(bstats.result))
    -- (A whole sweep, seen from its start: the badge and the Overlord Rank read it as one.)
    assert(bstats.lastSweepFull == true and bstats.lastSweepChanged >= 2, "captures first: the sweep is not read as a whole one")
    assert(B.OverlordDB.leaderboardPageProgress.shared.stream == "LK", "the sweep was left elsewhere than at the kills")
    -- Within GAP the next pull is a plain sweep (kills, captures, races).
    advance(5)
    mark = now
    pull(B, A)
    assert((bstats.capTurns or 0) == before + 1 and sentBetween(B, A, "HR", "^8:V:%d+:%w+:1:LK:", mark) == 1,
        "captures compared first again within GAP")
    -- A pull cut while it compares the captures leaves the sweep at the kills (a checkpoint at
    -- the captures would send the next pull to the races without a kill row), and is counted.
    holdSilently(A, names[21], 4, { zones[8] })
    advance(turns.GAP + 1)
    hello()
    local cut = bstats.capTurnsCut or 0
    before = bstats.capTurns or 0
    assert(B.Overlord.Sync:StartCompletePagedLeaderboardCatchup(A.name, function() end))
    assert((bstats.capTurns or 0) == before + 1, "fixture: the captures were not due")
    assert(B.Overlord.Sync:CancelPagedLeaderboardCatchup(), "fixture: no pull to cut")
    assert((bstats.capTurnsCut or 0) == cut + 1, "a pull cut in the captures was not counted")
    assert(B.OverlordDB.leaderboardPageProgress.shared.stream == "LK", "a pull cut in the captures left the sweep there")
    advance(5)
    mark = now
    pull(B, A)
    assert((bstats.capTurns or 0) == before + 1 and sentBetween(B, A, "HR", "^8:V:%d+:%w+:1:LK:", mark) == 1,
        "the pull after a cut one did not start at the kills")
    assert(captureOf(B, names[21]) == 4, "the sweep after a cut pull did not bring the captures")
    -- A peer that answers "busy" compared nothing: the captures stay due for the next pull.
    holdSilently(A, names[22], 2, { zones[9] })
    advance(turns.GAP + 1)
    hello()
    local turnAt = turns.at
    -- (In a fight with no session open, a responder answers "busy: combat" to every request.)
    A.InCombatLockdown = function() return true end
    local done
    before = bstats.capTurns or 0
    assert(B.Overlord.Sync:StartCompletePagedLeaderboardCatchup(A.name, function(ok) done = ok end))
    for _ = 1, 60 do advance(10); if done ~= nil then break end end
    A.InCombatLockdown = function() return false end
    assert(tostring(bstats.result):find("peer in combat", 1, true), "fixture: " .. tostring(bstats.result))
    assert(done == false and (bstats.capTurns or 0) == before + 1, "fixture: the busy peer was not asked the captures first")
    assert(turns.at == turnAt, "the captures' place was spent on a busy peer")
    hello()
    pull(B, A)
    assert((bstats.capTurns or 0) == before + 2 and captureOf(B, names[22]) == 2, "the captures did not come first again after a busy peer")
    -- Not while the session's first pull is younger than FIRST_SEC (a login fills its ranking first).
    advance(turns.GAP + 1)
    hello()
    local kb = B.Overlord.Sync._killingBlowTurns
    local savedFirst = kb.firstPullAt
    kb.firstPullAt = now - turns.FIRST_SEC + 30
    before = bstats.capTurns or 0
    pull(B, A)
    kb.firstPullAt = savedFirst
    assert((bstats.capTurns or 0) == before, "captures first before the session's first pull was old enough")
end

-- 6. After the audit of 2026-11-17.
do
    local afeed, astats = feedOf(A), statsOf(A)
    hello()
    local sub = afeed.subs[B.name:lower()]
    if not sub then
        feedOf(B).asked[A.name:lower()] = now
        assert(afeed.subscribe(B.name, nil, true), "fixture: no subscription")
        sub = afeed.subs[B.name:lower()]
    end
    advance(30)
    assert(sub.count == 0, "fixture: rows still waiting: " .. sub.count)

    -- 6a. A row that cannot be built yet waits, and the rows behind it with it: after WAIT_MAX
    --     tries one row is given up and counted, never the whole list (it was the whole list,
    --     in one message). In a fight nothing is given up at all.
    local alb = A.Overlord.Leaderboard
    local live, prepared = alb.GetLiveNetworkRow, alb.EnsureNetworkHotIndexesPrepared
    alb.GetLiveNetworkRow = function() return nil end
    alb.EnsureNetworkHotIndexesPrepared = function() return false end
    local gone = astats.feedGone or 0
    for i = 1, 30 do alb:SetPlayerKills(names[i], 9100 + i, true) end
    local waiting = sub.count
    assert(waiting >= 30, "fixture: the rows are not waiting: " .. waiting)
    A.InCombatLockdown = function() return true end
    advance(3 * afeed.WAIT_MAX)
    assert(sub.count == waiting and (astats.feedGone or 0) == gone, "rows were given up in a fight: " .. sub.count .. " of " .. waiting)
    A.InCombatLockdown = function() return false end
    -- (Out of the fight a try is made every few seconds: until the first row is given up.)
    for _ = 1, 200 do
        advance(1)
        if sub.count < waiting then break end
    end
    -- (One row per subscriber that had rows waiting, at the very most.)
    assert((astats.feedGone or 0) > gone and (astats.feedGone or 0) - gone <= afeed.subCount,
        "rows given up after WAIT_MAX tries: " .. ((astats.feedGone or 0) - gone) .. " for " .. afeed.subCount .. " subscribers")
    assert(sub.count == waiting - 1, "a whole waiting list was dropped behind one row: " .. sub.count .. " left of " .. waiting)
    alb.GetLiveNetworkRow, alb.EnsureNetworkHotIndexesPrepared = live, prepared
    advance(60)
    assert(B.Overlord.Leaderboard.kills[names[30]] == 9130, "the rows that waited never left: " .. tostring(B.Overlord.Leaderboard.kills[names[30]]))

    -- 6b. WALK_MAX rows are looked at per message: a long list of rows that are not for this
    --     subscriber (its faction filter) is not walked whole in one frame.
    do
        local savedWalk, savedFilter = afeed.WALK_MAX, sub.filter
        afeed.WALK_MAX, sub.filter = 10, "H"
        for i = 1, 40 do alb:SetPlayerKills(names[i], 9200 + i, true) end
        local queued = sub.count
        assert(queued >= 40, "fixture: rows not queued: " .. queued)
        for _ = 1, 40 do
            advance(0.5)
            if sub.count < queued then break end
        end
        assert(sub.count == queued - 10, "the walk of one message is not WALK_MAX rows: " .. sub.count .. " left of " .. queued)
        advance(60)
        assert(sub.count == 0, "rows not for this subscriber stayed in its list: " .. sub.count)
        afeed.WALK_MAX, sub.filter = savedWalk, savedFilter
    end

    -- 6c. The zones of a short row: the list is told whole in a few counts, whatever the room.
    do
        local function union(room, list)
            local seen, n = {}, 0
            for count = 1, 3 * #list do
                local part = afeed.captureZones(list, count, room)
                local used = 0
                for _, zone in ipairs(part) do
                    used = used + #zone + 1
                    if not seen[zone] then seen[zone], n = true, n + 1 end
                end
                assert(part == list or used <= room + 1, "a part over its room: " .. used .. " for " .. room)
            end
            return n
        end
        assert(union(123, zones) == 36, "a usual room does not tell the whole list")
        -- (An 80-byte name leaves 50 bytes: two zones a row.)
        assert(union(50, zones) == 36, "a long name never tells the whole list: " .. union(50, zones))
        -- (A list of twenty: a fixed step of five zones came back to the same four places.)
        local twenty = {}
        for i = 1, 20 do twenty[i] = zones[i] end
        assert(union(50, twenty) == 20, "a list of twenty zones is never told whole: " .. union(50, twenty))
        -- (And with long zones among short ones: a step sharing a divisor with the list's length
        -- came back to the same places, and a long zone there hid the ones behind it.)
        local mixed = {}
        for i = 1, 20 do mixed[i] = (i % 5 == 0) and ("fixture_point_long_name_" .. i) or ("z" .. i) end
        assert(union(40, mixed) == 20, "a list with long zones is never told whole: " .. union(40, mixed))
        assert(#afeed.captureZones(zones, 7, 0) == 0, "no room, yet zones")
        assert(afeed.captureZones({ zones[1] }, 3, 100)[1] == zones[1] and afeed.captureZones(nil, 3, 100) == nil)
    end

    -- 6d. A count comes up only for a player our ranking holds already, and the gap between two
    --     upward messages is kept by name (asking us again makes a new subscription).
    do
        local E = client("Evan Newcomer")
        E.Overlord.Sync._captureTurns.FIRST_SEC = math.huge
        for i = 1, 60 do
            E.Overlord.Leaderboard.kills[names[i]] = i
            E.Overlord.Leaderboard.playerInfo[names[i]] = info()
        end
        E.Overlord.Leaderboard.playerInfo[E.name] = info()
        hello()
        -- (A real session: it asked a neighbour once, its ranking and its indexes are built.)
        pull(E, A)
        advance(15)
        assert(not A.Overlord.Sync:IsKnownLeaderboardSubject(E.name), "fixture: A already holds the newcomer")
        assert(afeed.subs[E.name:lower()], "fixture: the newcomer is not a subscriber of A")
        local epochText
        for _, row in ipairs(wire) do epochText = row.payload:match("^8:C:(%d+):") or epochText end
        local function up(from, count)
            local row = "c" .. from.name .. ":A:WARRIOR:" .. count .. ":" .. zones[5] .. ":engb"
            from.Overlord.Sync:SendWhisper("HR", "8:C:" .. epochText .. ":" .. #row .. ":" .. row, A.name)
            advance(5)
        end
        local refused = astats.feedCapturesUpRefused or 0
        up(E, 7)
        assert(captureOf(A, E.name) == 0 and (astats.feedCapturesUpRefused or 0) == refused + 1,
            "a player unknown to our ranking raised its own count from below")
        -- (D is known, and a subscriber: taken; then it asks us again within the gap.)
        advance(afeed.CAPTURE_UP_GAP + 5)
        local dsub = afeed.subs[D.name:lower()]
        if not dsub then assert(afeed.subscribe(D.name, nil, true)) end
        local base = captureOf(A, D.name)
        up(D, base + 1)
        assert(captureOf(A, D.name) == base + 1, "fixture: a subscriber's own row was not taken")
        afeed.subs[D.name:lower()], afeed.subCount = nil, afeed.subCount - 1
        assert(afeed.subscribe(D.name, nil, true))
        up(D, base + 2)
        assert(captureOf(A, D.name) == base + 1, "a new subscription opened the gap between two upward messages")

        -- 6e. A capture made with nobody fed takes its wait all the same: a subscriber that comes
        --     within the CAPTURE_LINGER is not handed the count before the capture's own event.
        local efeed = feedOf(E)
        assert(efeed.subCount == 0, "fixture: the newcomer already feeds somebody")
        E.Overlord.Leaderboard:SetPlayerKills(E.name, 12, true)
        advance(efeed.RING_SEC + 10)
        E.Overlord.Leaderboard.captures[E.name] = { zones[2] }
        -- (The ranking's capture index is built, as in a session a few seconds old: a count
        -- that moves is told to the feed through it.)
        assert(E.Overlord.Leaderboard:GetMaxCapturesForDedupName(E.name) == 0)
        -- (Nobody fed and nobody feeding: the capture takes its wait all the same.)
        efeed.sources = {}
        E.Overlord.Leaderboard:SetPlayerCaptureCount(E.name, 4, false)
        assert(efeed.captureWaiting and efeed.captureWaiting["c" .. E.Overlord.Leaderboard:GetNetworkRowKey(E.name)],
            "a capture made with nobody fed did not take its wait")
        advance(5)
        mark = now
        feedOf(C).asked[E.name:lower()] = now
        assert(efeed.subscribe(C.name, nil, true), "fixture: no subscription")
        advance(efeed.CAPTURE_LINGER - 20)
        assert(sentBetween(E, C, "HB", "^8:U:%d+:.*%d+:c" .. E.name .. ":", mark) == 0 and captureOf(C, E.name) == 0,
            "a capture made with nobody fed was handed to a subscriber before its wait")
        -- (A subscriber is only reached while the relay heard it in the last five minutes.)
        hello()
        advance(60)
        assert(sentBetween(E, C, "HB", "^8:U:%d+:.*%d+:c" .. E.name .. ":", mark) == 1 and captureOf(C, E.name) == 4,
            "a capture made with nobody fed never reached the subscriber that came: " .. captureOf(C, E.name))
    end
end

print("Capture totals: short feed row for many zones, own count up and to a new subscriber, own rows only, compared first in a sweep OK")
