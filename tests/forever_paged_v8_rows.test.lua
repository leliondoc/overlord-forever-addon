-- 1.8.0: ranking pages v8 send only the rows that differ (bucket fingerprints, then
-- row fingerprints, then the rows asked for), and from a Battle.net friend of the
-- other faction only that faction's rows. Real HR/HA/HB, relay, BNet routes and
-- page acceptance; only WoW transports and the clock are simulated.
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
        assert(not c.Overlord.BetaNetwork.stats.lastError, c.Overlord.BetaNetwork.stats.lastError)
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
            other.Overlord.BetaNetwork:Receive(wire, name, "BNET", e)
        else
            other.Overlord.BetaNetwork:ReceiveFragment(wire, name, "BNET", e)
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
    e.loadfile("SyncBetaNetwork.lua")()
    s.SendSyncRequest = function() return true end
    clients[#clients + 1] = e
    return e
end

local PULLER = client("Bridge Tester", "alliance", "Alliance")
local ALLY = client("Analyst Tester", "alliance", "Alliance")
local SOURCE = client("Gateway Tester", "horde", "Horde")
PULLER.friends, SOURCE.friends = { SOURCE }, { PULLER }
-- Only Battle.net proves the other faction (game account of the friend).
PULLER.Overlord.Sync.GetResolvedBNetPlayerFaction = function(_, n) return n == SOURCE.name and "Horde" or nil end
SOURCE.Overlord.Sync.GetResolvedBNetPlayerFaction = function(_, n) return n == PULLER.name and "Alliance" or nil end
local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.BetaNetwork:Broadcast("NH", e.Overlord.Version) end
    later(45, heartbeat)
end
heartbeat()
advance(10)
assert(PULLER.Overlord.BetaNetwork:GetPeerPagedProtocol(SOURCE.name) == 8, "the source did not advertise v8")
assert(PULLER.Overlord.BetaNetwork:GetPeerPagedProtocol(ALLY.name) == 8, "the ally did not advertise v8")
assert(PULLER.Overlord.Sync:GetBetaPeerFaction(SOURCE.name) == "Horde", "fixture: source faction unknown")

local function playerName(i)
    local n = i - 1
    return "Player " .. string.char(65 + math.floor(n / 676)) .. string.char(97 + math.floor(n / 26) % 26)
        .. string.char(97 + n % 26)
end
local horde, alliance = {}, {}
for i = 1, 3000 do
    local name = playerName(i)
    local isHorde = i <= 2400
    local lb = SOURCE.Overlord.Leaderboard
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "WARRIOR", faction = isHorde and "Horde" or "Alliance", level = 60,
        locale = "engb", guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true,
        race = isHorde and "Orc" or "Human", raceSex = 2, raceAt = 1 }
    if isHorde then horde[#horde + 1] = name else alliance[#alliance + 1] = name end
end

-- Wire accounting: every page packet the responder sends, and the byte budget.
local sent, sentBytes, charged, chargeStart = 0, 0, 0, now
local sourceSend = SOURCE.Overlord.Sync.SendWhisper
local faults = { dropped = false, corrupted = false }
SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HA" or kind == "HB" then
        sent, sentBytes = sent + 1, sentBytes + #payload
        if kind == "HB" then
            charged = charged + #payload + 200
            assert(charged <= 500 + (now - chargeStart) * 300, "Exceeded the page byte budget")
        end
        local f = { SOURCE.strsplit(":", payload, 8) }
        if kind == "HB" and f[2] == "D" and f[5] == "3" and f[6] == "1" and not faults.dropped then
            faults.dropped = true
            return true -- accepted by WoW, lost farther away
        end
        if kind == "HB" and f[2] == "D" and f[5] == "6" and f[6] == "1" and not faults.corrupted then
            faults.corrupted = true
            payload = payload:sub(1, -2) .. (payload:sub(-1) == "X" and "Y" or "X")
        end
    end
    return sourceSend(self, kind, payload, target)
end
local applied, firstApplied = 0, {}
local receive = PULLER.Overlord.Sync.OnReceiveLeaderboardKills
PULLER.Overlord.Sync.OnReceiveLeaderboardKills = function(self, payload, ...)
    applied = applied + 1
    if #firstApplied < 24 then firstApplied[#firstApplied + 1] = payload:match("^([^:]+):") end
    return receive(self, payload, ...)
end
local function pull(peer, ...)
    local done
    local started, why = PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(peer.name, function(ok) done = ok end)
    assert(started, tostring(why))
    for _ = 1, 200 do advance(60); if done ~= nil then break end end
    return done
end

-- 1) Cold pull from the other faction's Battle.net friend: every Horde row arrives,
--    the friend's copy of Alliance rows is never asked for.
local stats = PULLER.Overlord.Sync._leaderboardPageStats
assert(pull(SOURCE) == true, "cold v8 pull failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics()
    .. " " .. tostring(stats.error))
assert(stats.protocol == 8, "the production entry did not use v8")
assert(faults.dropped and faults.corrupted, "fault injection never ran")
for _, name in ipairs(horde) do
    assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "missing Horde row " .. name)
    local race = PULLER.Overlord.Leaderboard:GetExportPlayerRace(name)
    assert(race == "Orc", "race did not ride with the v8 row of " .. name)
end
for _, name in ipairs(alliance) do
    assert(PULLER.Overlord.Leaderboard.kills[name] == nil, "an own-faction row was pulled from the enemy friend: " .. name)
end
-- Cold pull: the 96 best Horde rows come first (T, in rank order), then once more
-- in the sweep (our frozen profile does not hold them): 4 % more rows, no more.
assert(applied == #horde + 96, "rows applied " .. applied .. " for " .. #horde .. " wanted + 96 top")
for i, name in ipairs(firstApplied) do
    assert(name == horde[#horde - i + 1], "row " .. i .. " of the cold pull is not the rank " .. i
        .. " Horde row: " .. tostring(name))
end
print("v8 cold cross-faction pull: " .. #horde .. " rows, " .. sent .. " packets, " .. sentBytes .. " bytes")

-- 2) Equal ranking: the first request carries one fingerprint of the three streams,
--    the pair ends in one exchange (one request, one reply, no end notice).
advance(400)
sent, applied = 0, 0
local requests = 0
local countRequests = PULLER.Overlord.Sync.SendWhisper
PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" then requests = requests + 1 end
    return countRequests(self, kind, payload, target)
end
assert(pull(SOURCE) == true, "steady v8 pull failed")
PULLER.Overlord.Sync.SendWhisper = countRequests
assert(applied == 0, "an equal ranking re-sent rows: " .. applied)
assert(sent == 1 and requests == 1, "an equal ranking cost " .. requests .. " requests and " .. sent .. " replies")

-- 2b) Only a capture count differs: the combined fingerprint covers every stream,
--     so the capture row is still pulled.
advance(400)
SOURCE.Overlord.Leaderboard:SetPlayerCaptureCount(horde[3], 7, true)
assert(pull(SOURCE) == true, "capture-only v8 pull failed")
assert(PULLER.Overlord.Leaderboard.captureCount[horde[3]] == 7, "a capture-only difference was skipped")

-- 3) A few scores change (the usual case): only those rows travel.
advance(400)
local changed = { horde[5], horde[700], horde[1500], horde[2300] }
for i, name in ipairs(changed) do SOURCE.Overlord.Leaderboard:SetPlayerKills(name, 2400 + i, true) end
sent, sentBytes, applied = 0, 0, 0
assert(pull(SOURCE) == true, "delta v8 pull failed")
for i, name in ipairs(changed) do
    assert(PULLER.Overlord.Leaderboard.kills[name] == 2400 + i, "changed row missed: " .. name)
end
assert(applied == #changed, "delta pull applied " .. applied .. " rows for " .. #changed .. " changes")
-- The next round comes soon after a v8 round: our own profile, built before the rows
-- just applied, is rebuilt instead of reused (those rows are not asked again).
do
    local reusedBefore = stats.profileReused or 0
    applied = 0
    assert(pull(SOURCE) == true, "immediate next pull failed")
    assert((stats.profileReused or 0) == reusedBefore, "our profile was reused after rows were applied")
    assert(applied == 0, "rows just applied were fetched again: " .. applied)
end
local v8Packets, v8Bytes = sent, sentBytes
-- Only the buckets holding a changed row are listed (V + per bucket L and G, a few packets each).
assert(v8Packets <= 40, "a delta of " .. #changed .. " rows cost " .. v8Packets .. " packets")

-- Same change through v7 (whole differing buckets), for comparison.
advance(400)
for i, name in ipairs(changed) do SOURCE.Overlord.Leaderboard:SetPlayerKills(name, 2410 + i, true) end
sent, sentBytes, applied = 0, 0, 0
local done
assert(PULLER.Overlord.Sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end, true, true))
for _ = 1, 200 do advance(60); if done ~= nil then break end end
assert(done == true, "v7 comparison pull failed")
assert(applied > 4 * #changed, "fixture: v7 did not resend whole buckets (" .. applied .. ")")
print(("delta of %d rows: v8 %d packets / %d bytes, v7 %d packets / %d bytes (%d rows)"):format(
    #changed, v8Packets, v8Bytes, sent, sentBytes, applied))
assert(v8Bytes * 3 < sentBytes, "v8 did not cut the delta traffic by two thirds")

-- 4) Same-faction neighbour: no faction filter, its Alliance rows arrive too.
advance(400)
for _, name in ipairs(alliance) do
    ALLY.Overlord.Leaderboard.kills[name] = SOURCE.Overlord.Leaderboard.kills[name]
    ALLY.Overlord.Leaderboard.playerInfo[name] = { class = "PALADIN", faction = "Alliance", level = 60,
        locale = "enus", guild = "", guildAt = 0, race = "Human", raceSex = 2, raceAt = 1 }
end
ALLY.Overlord.Leaderboard:MarkMetaDirty()
applied = 0
assert(pull(ALLY) == true, "same-faction v8 pull failed")
for _, name in ipairs(alliance) do
    assert(PULLER.Overlord.Leaderboard.kills[name] == ALLY.Overlord.Leaderboard.kills[name], "missing ally row " .. name)
end
assert(applied == #alliance, "same-faction pull applied " .. applied .. " for " .. #alliance)

-- 5) Now holding both factions, a delta from the enemy friend still compares only
--    its faction's rows: the buckets of our own rows are not listed.
advance(400)
SOURCE.Overlord.Leaderboard:SetPlayerKills(horde[10], 2500, true)
SOURCE.Overlord.Leaderboard:SetPlayerKills(horde[1900], 2501, true)
sent, applied = 0, 0
assert(pull(SOURCE) == true, "second delta v8 pull failed")
assert(applied == 2 and PULLER.Overlord.Leaderboard.kills[horde[1900]] == 2501, "second delta rows: " .. applied)
assert(sent <= 30, "own-faction buckets were listed by the enemy friend: " .. sent .. " packets")

-- 6) A hostile responder whose G pages never move their cursor forward: the page is
--    refused (no row applied, no endless loop), the pull ends.
advance(400)
SOURCE.Overlord.Leaderboard:SetPlayerKills(horde[20], 2600, true)
SOURCE.Overlord.Leaderboard:SetPlayerKills(horde[21], 2601, true)
local hostileSend = SOURCE.Overlord.Sync.SendWhisper
SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HA" and payload:sub(1, 4) == "8:P:" then
        local f = { SOURCE.strsplit(":", payload) }
        if f[6] == "G" then f[10] = "1"; payload = table.concat(f, ":") end
    end
    return hostileSend(self, kind, payload, target)
end
applied = 0
local hostileDone = pull(SOURCE)
assert(hostileDone == false, "a pull fed a non-advancing cursor did not end in failure")
assert(applied == 0, "rows of a page with a non-advancing cursor were applied: " .. applied)
SOURCE.Overlord.Sync.SendWhisper = hostileSend
advance(700)
assert(pull(SOURCE) == true and PULLER.Overlord.Leaderboard.kills[horde[21]] == 2601,
    "the next honest pull did not recover the rows")

-- 7) Several pages of wanted rows in one bucket (explicit bitmap, more than 24 rows):
--    the puller misses every other Horde row, so each bucket is listed and paged.
advance(700)
-- Drop rows the way a lost save does: a new score table, indexes rebuilt from it.
local function dropRows(names)
    local gone, kept = {}, {}
    for _, name in ipairs(names) do gone[name] = true end
    for name, count in pairs(PULLER.Overlord.Leaderboard.kills) do
        if not gone[name] then kept[name] = count end
    end
    PULLER.Overlord.Leaderboard.kills = kept
    PULLER.Overlord.Leaderboard:MarkDirty()
    PULLER.Overlord.Leaderboard:EnsureNetworkHotIndexesPrepared()
    advance(30)
end
local removed = {}
for i = 1, #horde, 2 do removed[#removed + 1] = horde[i] end
dropRows(removed)
applied = 0
local sawBitmap, sawPaged = false, false
local requesterSend = PULLER.Overlord.Sync.SendWhisper
PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and payload:sub(1, 4) == "8:G:" then
        local f = { PULLER.strsplit(":", payload) }
        if f[9] and f[9]:sub(1, 1) ~= "*" then sawBitmap = true end
        if tonumber(f[8]) and tonumber(f[8]) > 1 and f[9]:sub(1, 1) ~= "*" then sawPaged = true end
    end
    return requesterSend(self, kind, payload, target)
end
assert(pull(SOURCE) == true, "partial-bucket v8 pull failed")
PULLER.Overlord.Sync.SendWhisper = requesterSend
assert(sawBitmap and sawPaged, "no explicit bitmap page after the first")
for _, name in ipairs(removed) do
    assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "row not paged back: " .. name)
end
assert(applied == #removed, "bitmap pull applied " .. applied .. " rows for " .. #removed .. " missing")

-- 7b) A responder that moves its G cursor on but serves the same first rows of the
--     bucket again: the repeated page is refused (key order across the bucket's
--     pages), so no row is applied twice and the pull ends.
advance(700)
do
    local again = {}
    for i = 2, #horde, 2 do again[#again + 1] = horde[i] end
    dropRows(again)
    local handler, send = SOURCE.Overlord.Sync.OnPagedLeaderboardMessage, SOURCE.Overlord.Sync.SendWhisper
    local askedFrom, firstFrom = 1, {}
    SOURCE.Overlord.Sync.OnPagedLeaderboardMessage = function(self, kind, payload, sender, channel)
        if kind == "HR" and payload:sub(1, 4) == "8:G:" then
            local f = { SOURCE.strsplit(":", payload) }
            askedFrom = tonumber(f[8]) or 1
            firstFrom[f[7]] = firstFrom[f[7]] or f[8]
            f[8] = firstFrom[f[7]]
            payload = table.concat(f, ":")
        end
        return handler(self, kind, payload, sender, channel)
    end
    SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HA" and payload:sub(1, 4) == "8:P:" then
            local f = { SOURCE.strsplit(":", payload) }
            if f[6] == "G" then f[10] = tostring(askedFrom + 100); payload = table.concat(f, ":") end
        end
        return send(self, kind, payload, target)
    end
    applied = 0
    assert(pull(SOURCE) == false, "a pull fed repeated G pages did not end in failure")
    assert(applied <= 24, "rows of a repeated G page were applied again: " .. applied)
    SOURCE.Overlord.Sync.OnPagedLeaderboardMessage, SOURCE.Overlord.Sync.SendWhisper = handler, send
    advance(700)
    assert(pull(SOURCE) == true, "honest pull after repeated G pages failed")
    for _, name in ipairs(again) do
        assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "row lost: " .. name)
    end
end

-- 8) No direct ally: our own faction's rows can only come from the enemy friend,
--    so the pull is not filtered.
advance(700)
local lost = {}
for i = 1, #alliance, 3 do lost[#lost + 1] = alliance[i] end
dropRows(lost)
local net = PULLER.Overlord.BetaNetwork
local directPeers = net.GetDirectPeers
net.GetDirectPeers = function() return { SOURCE.name } end
assert(pull(SOURCE) == true, "unfiltered v8 pull failed")
net.GetDirectPeers = directPeers
for _, name in ipairs(lost) do
    assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name],
        "an own-faction row was not pulled without any ally: " .. name)
end

-- 9) Malformed v8 requests get no answer at all (no session, no busy, no page).
advance(700)
local answers = 0
local responderSend = SOURCE.Overlord.Sync.SendWhisper
SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HA" or kind == "HB" then answers = answers + 1 end
    return responderSend(self, kind, payload, target)
end
local epochToken = tostring(SOURCE.Overlord:GetCurrentCampaignStartTs())
local function inject(fields)
    SOURCE.Overlord.Sync:OnPagedLeaderboardMessage("HR", table.concat(fields, ":"), PULLER.name, "WHISPER")
    advance(5)
end
for _, fields in ipairs({
    { "8", "V", epochToken, "bad1", 1, "LZ", 0, 0 },          -- unknown stream
    { "8", "V", epochToken, "bad2", 1, "LK", 0, 0, "X" },     -- invalid faction filter
    { "8", "V", epochToken, "bad3", 1, "LK", 0, 0, "H", 1 },  -- extra field
    { "8", "V", epochToken, "bad4", 1, "LK", -1, 0 },         -- negative count
    { "8", "L", epochToken, "bad5", 1, "LK", 0 },             -- bucket 0
    { "8", "L", epochToken, "bad6", 1, "LK", 65 },            -- bucket 65
    { "8", "G", epochToken, "bad7", 1, "LK", 3, 1, "a!b" },   -- bitmap character
    { "8", "G", epochToken, "bad8", 1, "LK", 3, 0, "*" },     -- index 0
    { "8", "G", epochToken, "bad9", 1, "LK", 3, 1, string.rep("A", 201) }, -- bitmap too long
    { "8", "Q", epochToken, "bad10", 1, 1, "-", 0, 0, "LK" }, -- v7 op in v8
}) do inject(fields) end
assert(answers == 0, "malformed v8 requests were answered: " .. answers)
inject({ "8", "V", epochToken, "goodone", 1, "LK", 0, 0 })
assert(answers > 0, "fixture: a well-formed v8 request was not answered")
SOURCE.Overlord.Sync:OnPagedLeaderboardMessage("HR", table.concat({ "8", "F", epochToken, "goodone", 1 }, ":"),
    PULLER.name, "WHISPER")
SOURCE.Overlord.Sync.SendWhisper = responderSend

-- 10) Compact rows: the standard row is rebuilt byte for byte from the compact one,
--     for every row the source serves and for edge rows; malformed rows are refused.
do
    local sync = SOURCE.Overlord.Sync
    local compact, expand = assert(sync._PagedCompactRow8), assert(sync._PagedExpandRow8)
    local epochValue = SOURCE.Overlord:GetCurrentCampaignStartTs()
    local snapshot = assert(sync:GetAttestedLeaderboardSnapshot(), "fixture: no attested snapshot")
    local checked = 0
    local function roundTrip(stream, payload, race)
        local short = assert(compact(stream, payload, epochValue), "row not compacted: " .. payload)
        assert(#short < #payload, "compact row not shorter: " .. payload)
        if race then short, payload = short .. ":" .. race, payload .. ":" .. race end
        assert(expand(stream, short, epochValue) == payload, "rebuilt row differs: " .. payload)
        checked = checked + 1
    end
    for name in pairs(snapshot.kills) do
        local lk = sync:BuildPagedLeaderboardKillPayload(snapshot, name, epochValue)
        if lk then roundTrip("LK", lk, "o2"); roundTrip("LK", lk) end
        local lr = sync:BuildPagedLeaderboardRacePayload(snapshot, name, epochValue)
        if lr then roundTrip("LR", lr) end
    end
    for name in pairs(snapshot.captureCount or {}) do
        local lc = sync:BuildPagedLeaderboardCapturePayload(snapshot, name, epochValue)
        if lc then roundTrip("LC", lc) end
    end
    local e = tostring(epochValue)
    roundTrip("LK", "Edge Case:12:MAGE:Horde:" .. e .. ":::0:B" .. e .. ":60")
    roundTrip("LK", "Edge Case:12::Alliance:" .. e .. ":frfr:Some Guild:1790000000:B" .. e .. ":7", "h3")
    roundTrip("LK", string.rep("x", 190) .. ":99999:WARRIOR:Horde:" .. e .. ":enus::0:B" .. e .. ":60")
    roundTrip("LC", "Edge Case:H:ROGUE:3:" .. e .. ":zone_a,zone_b:enus:B" .. e)
    roundTrip("LC", "Edge Case:A::0:" .. e .. "::" .. ":B" .. e)
    roundTrip("LR", "Edge Case:Orc:2:" .. e .. ":1790000000")
    assert(checked > 3000, "fixture: few rows checked (" .. checked .. ")")
    -- Another epoch is never compacted (the row would be rebuilt with ours).
    assert(compact("LK", "A B:1:MAGE:Horde:123:enus::0:B123:60", epochValue) == nil, "foreign epoch compacted")
    assert(compact("LR", "A B:Orc:2:123:5", epochValue) == nil, "foreign race epoch compacted")
    for _, bad in ipairs({ "", "A B", "A B:1:MAGE", "A B:1:MAGE:Horde:enus::0:60:o2:extra",
        "A B:1:MAGE:Horde:enus::0", string.rep("y", 240) .. ":1:MAGE:Horde:enus::0:60" }) do
        assert(expand("LK", bad, epochValue) == nil, "malformed LK row rebuilt: " .. bad:sub(1, 40))
    end
    assert(expand("LR", "A B:Orc", epochValue) == nil and expand("LC", "A B:H:1", epochValue) == nil,
        "malformed LR/LC row rebuilt")
end

-- 11) A responder that holds nothing (fresh install): its empty buckets are never
--     listed, the pull costs the three bucket fingerprints and nothing else.
local FRESH = client("Fresh Tester", "alliance", "Alliance")
advance(60)
local freshSend, freshSent = FRESH.Overlord.Sync.SendWhisper, 0
FRESH.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HA" or kind == "HB" then freshSent = freshSent + 1 end
    return freshSend(self, kind, payload, target)
end
assert(pull(FRESH) == true, "pull from an empty peer failed")
FRESH.Overlord.Sync.SendWhisper = freshSend
assert(freshSent <= 12, "an empty peer cost " .. freshSent .. " packets")

-- 11b) Hostile top pages on a cold pull: a T page whose cursor does not move, or
--      that repeats rows already given, is refused; nothing is applied twice.
do
    local freshApplied = 0
    local freshReceive = FRESH.Overlord.Sync.OnReceiveLeaderboardKills
    FRESH.Overlord.Sync.OnReceiveLeaderboardKills = function(self, ...)
        freshApplied = freshApplied + 1
        return freshReceive(self, ...)
    end
    local allySend = ALLY.Overlord.Sync.SendWhisper
    local mode = "stuck"
    ALLY.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HA" and payload:sub(1, 4) == "8:P:" then
            local f = { ALLY.strsplit(":", payload) }
            if f[6] == "T" and mode == "stuck" then f[10] = "1"; payload = table.concat(f, ":") end
        end
        return allySend(self, kind, payload, target)
    end
    local function freshPull()
        local done
        assert(FRESH.Overlord.Sync:StartCompletePagedLeaderboardCatchup(ALLY.name, function(ok) done = ok end))
        for _ = 1, 200 do advance(60); if done ~= nil then break end end
        return done
    end
    assert(freshPull() == false and freshApplied == 0, "a stuck top page was applied: " .. freshApplied)
    -- A responder that moves its cursor on but serves the same best rows again.
    advance(700)
    mode = "repeat"
    local allyHandler = ALLY.Overlord.Sync.OnPagedLeaderboardMessage
    local askedFrom = 1
    ALLY.Overlord.Sync.OnPagedLeaderboardMessage = function(self, kind, payload, sender, channel)
        if kind == "HR" and payload:sub(1, 4) == "8:T:" then
            local f = { ALLY.strsplit(":", payload) }
            askedFrom = tonumber(f[7]) or 1
            f[7] = "1"
            payload = table.concat(f, ":")
        end
        return allyHandler(self, kind, payload, sender, channel)
    end
    ALLY.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HA" and payload:sub(1, 4) == "8:P:" then
            local f = { ALLY.strsplit(":", payload) }
            if f[6] == "T" then f[10] = tostring(askedFrom + 100); payload = table.concat(f, ":") end
        end
        return allySend(self, kind, payload, target)
    end
    assert(freshPull() == false and freshApplied == 24, "repeated top rows were applied again: " .. freshApplied)
    ALLY.Overlord.Sync.OnPagedLeaderboardMessage = allyHandler
    ALLY.Overlord.Sync.SendWhisper = allySend
    advance(700)
    -- Honest top then sweep from the same peer: every ally row once, the top twice at most.
    assert(freshPull() == true, "honest cold pull after the hostile one failed")
    assert(freshApplied >= #alliance and freshApplied <= #alliance + 96, "cold pull applied " .. freshApplied)
    FRESH.Overlord.Sync.OnReceiveLeaderboardKills = freshReceive
end

-- 11c) A busy channel: the neighbour table forgets a peer within seconds (here a
--      table of 2 entries for 4 peers heard every 45 s). The peers of a running pull
--      or served session are kept, so a long pull still completes.
advance(700)
do
    -- Same faction (whispered route, unlike a Battle.net friend): both tables churn.
    local pullerNet, allyNet = PULLER.Overlord.BetaNetwork, ALLY.Overlord.BetaNetwork
    pullerNet.PEER_RING_LIMIT, allyNet.PEER_RING_LIMIT = 2, 1
    for i = 1, #alliance do
        local name = alliance[i]
        ALLY.Overlord.Leaderboard:SetPlayerKills(name, (ALLY.Overlord.Leaderboard.kills[name] or 0) + 1, true)
        ALLY.Overlord.Leaderboard.playerInfo[name].level = 60
    end
    ALLY.Overlord.Leaderboard:MarkDirty()
    ALLY.Overlord.Leaderboard:MarkMetaDirty()
    advance(200)
    local started, retriesBefore = now, PULLER.Overlord.Sync._leaderboardPageStats.retries
    assert(pull(ALLY) == true, "a long pull failed when the neighbour tables churned: "
        .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
    assert(now - started > 300, "fixture: the pull was too short to see the tables churn")
    CHURN_RETRIES = PULLER.Overlord.Sync._leaderboardPageStats.retries - retriesBefore
    assert(CHURN_RETRIES == 0, "pages were lost while the neighbour tables churned: "
        .. CHURN_RETRIES .. " retries")
    for _, name in ipairs(alliance) do
        assert(PULLER.Overlord.Leaderboard.kills[name] == ALLY.Overlord.Leaderboard.kills[name], "row lost: " .. name .. " puller " .. tostring(PULLER.Overlord.Leaderboard.kills[name]) .. " ally " .. tostring(ALLY.Overlord.Leaderboard.kills[name]) .. " " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics() .. " rejected " .. tostring(PULLER.Overlord.Sync._leaderboardPageStats.rejected))
    end
    -- The quiet gap of a session (profile being built, combat wait): new peers keep
    -- arriving, the peer of the running pull must stay in the table.
    pullerNet.PEER_RING_LIMIT = 1
    local quietDone
    assert(PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(ALLY.name, function(ok) quietDone = ok end))
    advance(0.2)
    FRESH.Overlord.BetaNetwork:Broadcast("NH", "quiet-gap-" .. now)
    assert(pullerNet:IsPeer(ALLY.name), "the peer of a running pull left the neighbour table")
    for _ = 1, 60 do advance(60); if quietDone ~= nil then break end end
    assert(quietDone == true, "the pull with a pinned peer failed")
    pullerNet.PEER_RING_LIMIT, allyNet.PEER_RING_LIMIT = nil, nil
end

-- 12) Counters for /ov network.
local fp = PULLER.Overlord.Sync
assert(fp._leaderboardPageStats.listed and fp._leaderboardPageStats.wanted, "list counters missing")

SOURCE.Overlord.Sync.SendWhisper = sourceSend
print("Paged v8 rows: cold cross-faction pull filtered by faction, equal ranking quiet, deltas row by row, v7 still answered OK")
