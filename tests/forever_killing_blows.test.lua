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
-- ... and only while the feed has used less than 70 % of its messages this minute.
do
    local feed = A.Overlord.Sync._leaderboardFeed
    local sub, minute = feed.subs[B.name:lower()], feed.minute
    local savedAt, savedCount = minute.at, minute.count
    minute.at, minute.count = now, math.ceil(feed.PER_MIN * 0.7)
    local key = A.Overlord.Leaderboard:GetNetworkRowKey(names[42])
    KB:Data().counts[key] = 5
    A.Overlord.Sync._NoteKillingBlowMoved(key)
    assert(not sub.has["b" .. key], "a killing blow row queued while the feed's minute was 70 % spent")
    minute.at, minute.count = savedAt, savedCount
    A.Overlord.Sync._NoteKillingBlowMoved(key)
    assert(sub.has["b" .. key], "fixture: the killing blow row was not queued with the minute free")
    advance(40)
end

-- 7) Sweeps carry killing blows once every KB_SWEEP_SEC; only the players of the copy's kill
--    rows, under their spelling, within their kills; a move of killing blows alone rebuilds LB only.
do
    local data = KB:Data()
    data.counts["ghost player"] = 9
    local capped = names[50]
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
    assert(BK:Get(capped) == 20 + 50, "a count above the copy's kills did not come down to them: " .. BK:Get(capped))
    assert(BK:Get("Ghost Player") == 0, "a player outside the copy's kill rows was sent")
    local cappedKey = B.Overlord.Leaderboard:GetNetworkRowKey(capped)
    assert(BK:Counts()[cappedKey] == 20 + 50 and BK:Data().names == nil, "the killing blows table holds names")
    -- (A table saved with names by an earlier build of 2.5.2 lets them go, counts kept.)
    BK:Data().names = { [cappedKey] = capped }
    assert(BK:Data().names == nil and BK:Counts()[cappedKey] == 70, "the saved names were kept")
    assert((A.Overlord.Sync._leaderboardPageStats.profileKBOnly or 0) > kbOnly, "a move of killing blows alone rebuilt the whole profile")
    -- Equal now, both sides: nothing comes again at the next sweep with them.
    local before = B.Overlord.Sync._leaderboardPageStats.kbChanged or 0
    advance(1801)
    hello()
    pull(B, A)
    assert((B.Overlord.Sync._leaderboardPageStats.kbChanged or 0) == before, "killing blows came again between equal copies")
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
