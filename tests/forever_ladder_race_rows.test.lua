-- 1.7.0: ranking pages v7 carry the player's race at the end of each LK row, so
-- the race arrives with the score. v6 pulls keep the 10-field rows 1.6.3 parses.
-- Real paged HR/HA/HB between two direct neighbours; transports and clock simulated.
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
end
local function client(name)
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    e.loadfile("Leaderboard.lua")()
    e.name = name
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
    e.C_Club = { GetSubscribedClubs = function() return {} end }
    e.Enum = { ClubType = { Character = 1 } }
    local s, lb = e.Overlord.Sync, e.Overlord.Leaderboard
    s.GetPlayerFullName = function() return name end
    s.GetChannelId = function() return 1 end
    s.GetBetaBNetTargets = function() return {} end
    s.SendToChannel = function(_, kind, fragment)
        for _, other in ipairs(clients) do
            if other ~= e then
                other.Overlord.Sync:OnAddonMessage("OverlordF", kind .. ":" .. fragment, "CHANNEL", name)
            end
        end
        return true
    end
    s.SendSyncRequest = function() return true end
    e.securecall = function(fn, ...) return fn(...) end
    e.C_ChatInfo = { SendAddonMessage = function(prefix, message, transport, target)
        for _, other in ipairs(clients) do
            if other.name == target then
                later(0.05, function() other.Overlord.Sync:OnAddonMessage(prefix, message, transport, name) end)
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

local SOURCE = client("Source Tester")
local PULLER = client("Puller Tester")
local sync = PULLER.Overlord.Sync

-- Race field codec: one letter for Classic races, the token otherwise, sex last.
assert(sync:EncodeRaceWireField("Scourge", 3) == "u3")
assert(sync:EncodeRaceWireField("NightElf", 2) == "n2")
assert(sync:EncodeRaceWireField("BloodElf", 0) == "BloodElf0")
assert(sync:EncodeRaceWireField("", 2) == nil)
for _, race in ipairs({ "Human", "Dwarf", "NightElf", "Gnome", "Orc", "Scourge", "Tauren", "Troll", "Draenei" }) do
    for _, sex in ipairs({ 0, 2, 3 }) do
        local back, backSex = sync:DecodeRaceWireField(sync:EncodeRaceWireField(race, sex))
        assert(back == race and backSex == sex, "race field round trip failed for " .. race)
    end
end
assert(sync:DecodeRaceWireField("x2") == nil, "an unknown letter was accepted")
assert(sync:DecodeRaceWireField("o5") == nil, "an invalid sex digit was accepted")
assert(sync:DecodeRaceWireField("Orc2:extra") == nil)

local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.BetaNetwork:Broadcast("NH", e.Overlord.Version) end
    later(45, heartbeat)
end
heartbeat()
advance(10)
-- 1.8.0: clients advertise v8 (~ld); the v7 exchange is still answered (sections 2 and below).
assert(PULLER.Overlord.BetaNetwork:GetPeerPagedProtocol(SOURCE.name) == 8, "the source did not advertise v8")

local RACES = { "Orc", "Scourge", "Tauren", "Troll" }
local names = {}
for i = 1, 300 do
    local name = "Player " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(97 + (i - 1) % 26)
    names[i] = name
    local lb = SOURCE.Overlord.Leaderboard
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 60, locale = "engb",
        guild = "Veteran Guild", guildAt = 1790016000,
        race = RACES[i % 4 + 1], raceSex = i % 2 == 0 and 2 or 3, raceAt = 1790016500 }
end
-- A race the puller saw itself is never replaced by an undated page row, however old
-- its date (1 s): the v7 row race carries no date. The source's own record of that
-- player is undated too, so its LR row cannot replace it either.
PULLER.Overlord.Leaderboard.playerInfo[names[1]] = { class = "WARRIOR", faction = "Horde",
    level = 60, race = "Troll", raceSex = 2, raceAt = 1 }
SOURCE.Overlord.Leaderboard.playerInfo[names[1]].raceAt = 0
-- A few capture rows: their LC (and the LR) rows must never get the race appended.
local zoneId
for _, front in pairs(SOURCE.Overlord.Fronts.Registry or {}) do
    if front.zones and front.zones[1] then zoneId = front.zones[1].id; break end
end
assert(zoneId, "no zone to seed captures")
-- The fixture's zone stub has no lookup; capture rows only need it to name a real zone.
for _, e in ipairs(clients) do
    e.Overlord.Zones.GetZone = e.Overlord.Zones.GetZone
        or function(_, id) return id == zoneId and { id = id } or nil end
end
for i = 1, 20 do
    SOURCE.Overlord.Leaderboard.captureCount[names[i]] = 21 - i
    SOURCE.Overlord.Leaderboard.captures[names[i]] = { zoneId }
end
local streamRows = { LC = {}, LR = {} }
for kind, method in pairs({ LC = "OnReceiveLeaderboardCaptures", LR = "OnReceiveLeaderboardRace" }) do
    local original = sync[method]
    sync[method] = function(self, payload, ...)
        streamRows[kind][#streamRows[kind] + 1] = payload
        return original(self, payload, ...)
    end
end

local rows = { v6 = 0, v7 = 0, raced = 0 }
local receiver = sync.OnReceiveLeaderboardKills
sync.OnReceiveLeaderboardKills = function(self, payload, sender, channel)
    local colons = select(2, payload:gsub(":", ":"))
    if colons == 10 then rows.raced = rows.raced + 1 end
    assert(colons == 9 or colons == 10, "unexpected LK row: " .. payload)
    return receiver(self, payload, sender, channel)
end
local wireVersions = {}
local sendWhisper = SOURCE.Overlord.Sync.SendWhisper
SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HA" or kind == "HB" then wireVersions[payload:sub(1, 1)] = true end
    return sendWhisper(self, kind, payload, target)
end

-- 1) v6 pull (what a 1.6.3 client asks): never a raced row.
local done
assert(sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end, true, false))
for _ = 1, 60 do advance(60); if done ~= nil then break end end
assert(done == true, "v6 pull failed: " .. sync:GetPagedLeaderboardDiagnostics() .. " " .. tostring(sync._leaderboardPageStats.error))
assert(rows.raced == 0, "a v6 pull received raced rows")
assert(wireVersions["6"] and not wireVersions["7"], "the v6 pull was not answered in v6")
assert(PULLER.Overlord.Leaderboard.kills[names[300]] == 300)

-- 2) v7 pull (what a 1.7.0-1.7.7 client asks; v8 is covered by forever_paged_v8_rows).
-- Reset the puller so the LK stream really has to be paged again.
PULLER.Overlord.Leaderboard.kills = {}
for i = 2, #names do PULLER.Overlord.Leaderboard.playerInfo[names[i]] = nil end
PULLER.Overlord.Leaderboard.captureCount, PULLER.Overlord.Leaderboard.captures = {}, {}
PULLER.Overlord.Leaderboard:MarkMetaDirty()
PULLER.OverlordDB.leaderboardPageProgress = nil
assert(#streamRows.LC >= 20, "the v6 pull carried no capture rows")
local v6Captures = {}
for _, payload in ipairs(streamRows.LC) do v6Captures[payload] = true end
streamRows.LC, streamRows.LR = {}, {}
wireVersions, rows.raced, done = {}, 0, nil
assert(sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end, true, true))
for _ = 1, 120 do advance(60); if done ~= nil then break end end
assert(done == true, "v7 pull failed: " .. sync:GetPagedLeaderboardDiagnostics())
assert(wireVersions["7"] and not wireVersions["6"], "the v7 pull was not answered in v7")
assert(rows.raced >= 299, "raced rows received: " .. rows.raced)
local lb = PULLER.Overlord.Leaderboard
for i = 2, #names do
    local race, sex = lb:GetExportPlayerRace(names[i])
    assert(race == RACES[i % 4 + 1] and sex == (i % 2 == 0 and 2 or 3),
        "race missing after the v7 pull for " .. names[i] .. ": " .. tostring(race))
end
local keptRace = lb:GetExportPlayerRace(names[1])
assert(keptRace == "Troll", "an undated page row replaced a race seen locally: " .. tostring(keptRace))
-- Only LK rows carry the race: v7 capture rows are byte for byte the v6 ones, and race
-- rows keep their 5 fields.
assert(#streamRows.LC >= 20 and #streamRows.LR >= 200, ("v7 streams: %d LC, %d LR"):format(
    #streamRows.LC, #streamRows.LR))
for _, payload in ipairs(streamRows.LC) do
    assert(v6Captures[payload], "a v7 capture row differs from v6: " .. payload)
end
for _, payload in ipairs(streamRows.LR) do
    assert(select(2, payload:gsub(":", ":")) == 4, "a v7 race row got an extra field: " .. payload)
end

-- Wire versions are matched on both sides of an exchange.
-- Responder: a v6 request inside an open v7 session of the same requester is "busy" in v6.
local replies = {}
local responderSend = SOURCE.Overlord.Sync.SendWhisper
SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
    replies[#replies + 1] = kind .. ":" .. payload
    return responderSend(self, kind, payload, target)
end
local epochToken = tostring(PULLER.Overlord:GetCurrentCampaignStartTs())
SOURCE.Overlord.Sync:OnPagedLeaderboardMessage("HR",
    table.concat({ "7", "Q", epochToken, "wiretest", 1, 1, "-", 0, 0, "LK" }, ":"), PULLER.name, "WHISPER")
advance(1)
SOURCE.Overlord.Sync:OnPagedLeaderboardMessage("HR",
    table.concat({ "6", "Q", epochToken, "wiretest", 2, 1, "-", 0, 0, "LK" }, ":"), PULLER.name, "WHISPER")
local busyInV6 = false
for _, reply in ipairs(replies) do
    if reply:find("^HA:6:R:") then busyInV6 = true end
    assert(not reply:find("^HA:7:R:"), "busy reply sent in the session's version, not the request's")
end
assert(busyInV6, "a v6 request inside a v7 session was not answered busy")
SOURCE.Overlord.Sync:OnPagedLeaderboardMessage("HR",
    table.concat({ "7", "F", epochToken, "wiretest", 1 }, ":"), PULLER.name, "WHISPER")
SOURCE.Overlord.Sync.SendWhisper = responderSend
advance(300)
-- Requester: a reply in another version than its own request is ignored.
local nonceSeen, seqSeen
local requesterSend = sync.SendWhisper
sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and payload:find("^7:Q:") then
        local _, _, _, nonce, seq = PULLER.strsplit(":", payload)
        nonceSeen, seqSeen = nonce, seq
    end
    return requesterSend(self, kind, payload, target)
end
-- Hold the source's answers so the pull is still waiting when the replies are injected.
local held = SOURCE.Overlord.Sync.OnPagedLeaderboardMessage
SOURCE.Overlord.Sync.OnPagedLeaderboardMessage = function() end
PULLER.OverlordDB.leaderboardPageProgress = nil
done = nil
assert(sync:StartPagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end, true, true))
for _ = 1, 20 do if nonceSeen then break end; advance(0.5) end
assert(nonceSeen, "no v7 request seen")
sync:OnPagedLeaderboardMessage("HA", table.concat({ "6", "R", epochToken, nonceSeen, seqSeen }, ":"),
    SOURCE.name, "WHISPER")
assert(done == nil, "a v6 busy reply ended a v7 pull")
-- Control: the same busy reply in the pull's own version is taken (the injection works).
sync:OnPagedLeaderboardMessage("HA", table.concat({ "7", "R", epochToken, nonceSeen, seqSeen }, ":"),
    SOURCE.name, "WHISPER")
assert(done == false, "the v7 busy reply was not taken: the check above proved nothing")
SOURCE.Overlord.Sync.OnPagedLeaderboardMessage = held
sync.SendWhisper = requesterSend

-- A raced row never exceeds the 250-byte row limit the receiver enforces.
local raceFieldFor = assert(sync._PagedRaceField, "race field builder not exposed")
local snapshotStub = { playerInfo = { Big = { race = "Orc", raceSex = 2 } } }
assert(raceFieldFor(snapshotStub, "Big", string.rep("x", 247)) == "o2", "a 250-byte raced row was refused")
assert(raceFieldFor(snapshotStub, "Big", string.rep("x", 248)) == nil, "a raced row went over 250 bytes")

-- Fair share: when an other-faction requester takes over a v7 session, the busy
-- notice to the previous (v7) requester is in v7, or it would wait for its timeout.
do
    local S = SOURCE.Overlord
    local savedFaction, savedPeerFaction, savedKnown = S.PlayerFaction, S.Sync.GetBetaPeerFaction,
        S.Sync.IsKnownRelayPeer
    S.PlayerFaction = "Horde"
    S.Sync.GetBetaPeerFaction = function(_, name) return name == "Enemy Tester" and "Alliance" or "Horde" end
    S.Sync.IsKnownRelayPeer = function() return true end
    local notices = {}
    local send = S.Sync.SendWhisper
    S.Sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HA" and target == PULLER.name then notices[#notices + 1] = payload end
        return send(self, kind, payload, target)
    end
    local epochToken = tostring(PULLER.Overlord:GetCurrentCampaignStartTs())
    S.Sync:OnPagedLeaderboardMessage("HR",
        table.concat({ "7", "Q", epochToken, "share7", 1, 1, "-", 0, 0, "LK" }, ":"), PULLER.name, "WHISPER")
    advance(130)
    notices = {}
    S.Sync:OnPagedLeaderboardMessage("HR",
        table.concat({ "6", "Q", epochToken, "enemy6", 1, 1, "-", 0, 0, "LK" }, ":"), "Enemy Tester", "WHISPER")
    local sawV7Busy = false
    for _, payload in ipairs(notices) do
        if payload:find("^7:R:" .. epochToken .. ":share7:") then sawV7Busy = true end
        assert(not payload:find("^6:R:" .. epochToken .. ":share7:"), "takeover notice sent in v6 to a v7 requester")
    end
    assert(sawV7Busy, "the v7 requester got no takeover notice")
    S.Sync:OnPagedLeaderboardMessage("HR",
        table.concat({ "6", "F", epochToken, "enemy6", 1 }, ":"), "Enemy Tester", "WHISPER")
    S.Sync.SendWhisper = send
    S.PlayerFaction, S.Sync.GetBetaPeerFaction, S.Sync.IsKnownRelayPeer = savedFaction, savedPeerFaction, savedKnown
    advance(300)
end

-- A live (unrequested) LK carrying a race field is not trusted for the race.
local liveTarget = names[5]
local livePayload = "Liar Tester:1:WARRIOR:Horde:1789527600:engb:::B1789527600:60:h2"
lb.playerInfo[liveTarget].race, lb.playerInfo[liveTarget].raceSex, lb.playerInfo[liveTarget].raceAt = "", 0, 0
lb:MarkMetaDirty()
local beforeLive = lb:GetExportPlayerRace(liveTarget)
local liveOk, liveErr = pcall(sync.OnReceiveLeaderboardKills, sync, (livePayload:gsub("^Liar Tester", liveTarget)),
    SOURCE.name, "WHISPER")
assert(liveOk, tostring(liveErr))
assert(lb:GetExportPlayerRace(liveTarget) == beforeLive, "a live LK set a race: " .. tostring(lb:GetExportPlayerRace(liveTarget)))

-- 3) Audit (performance): races stay out of the digests. Same scores, different race
-- knowledge (the puller saw names[1] as a Troll and knows a race the source lacks):
-- a new sweep (v8 between 1.8 clients) re-sends nothing.
lb.playerInfo[names[2]].race, lb.playerInfo[names[2]].raceSex = "Orc", 2
SOURCE.Overlord.Leaderboard.playerInfo[names[3]].race = ""
SOURCE.Overlord.Leaderboard:MarkMetaDirty()
lb:MarkMetaDirty()
PULLER.OverlordDB.leaderboardPageProgress = nil
local rowsBefore = rows.raced
local received = 0
local countRows = sync.OnReceiveLeaderboardKills
sync.OnReceiveLeaderboardKills = function(self, ...) received = received + 1; return countRows(self, ...) end
done = nil
advance(700) -- past the snapshot refresh
assert(sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
for _ = 1, 120 do advance(60); if done ~= nil then break end end
assert(done == true, "steady pull failed: " .. sync:GetPagedLeaderboardDiagnostics())
assert(received == 0 and rows.raced == rowsBefore,
    "buckets differing only by race were re-sent: " .. received .. " rows")

print("Ladder race rows: codec, v7 capability, v6 rows unchanged, v7 races with scores, local race kept OK")
