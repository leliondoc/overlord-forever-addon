-- A truce ends in silence (2.0.2), end to end with the real code on every side (Sync,
-- relay, map request and answer; only WoW's transports and the clock are simulated).
-- A truce end used to be announced (FR, with the front's map pages) and repeated in
-- every map answer, one row per front that had a truce since the weekly reset, with the
-- priority of a capture end: the first traffic of a busy bridge on 2026-10-13. Every
-- client that holds the victory now ends its truce by itself, at the same second, and
-- gives the conquest the same dates; a client that missed everything reads the conquest
-- in the map it asks for.
--  (1) the client that ends a truce sends nothing;
--  (2) its map answer carries no truce-end row;
--  (3) a late client ends with the same map, owners and dates, with no truce of its own
--      and no victory of its own, and its own answers say the same map;
--  (4) a victory whose truce is over by the clock is not replayed in a map answer.
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
        assert(steps < 400000, "Unbounded work")
    end
    now = stop
end
local realLoadfile = loadfile
local function client(name, channel, faction)
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    e.loadfile = function(path) return setfenv(assert(realLoadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    e.loadfile("Leaderboard.lua")()
    e.name, e.channel, e.friends, e.faction = name, channel, {}, faction
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
    s.GetBetaBNetTargetInfo = function(_, other) return other.faction, other.name end
    e.traffic = { za = 0, sr = 0 }
    s.SendToChannel = function(_, kind, fragment)
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
        for _, other in ipairs(clients) do
            if other.name == target then
                later(0.05, function() other.Overlord.Sync:OnAddonMessage(prefix, message, transport, name) end)
            end
        end
        return 0
    end }
    lb.kills, lb.captureCount, lb.captures, lb.playerInfo = {}, {}, {}, {}
    lb._storageBound = true
    e.Overlord.L.ZONE_NAMES = {}
    setmetatable(e.Overlord.L, { __index = function(_, key) return tostring(key) end })
    e.loadfile("Fronts.lua")()
    e.loadfile("Zones.lua")()
    e.loadfile("ZoneCaptureLease.lua")()
    e.notes = {}
    e.Overlord.PrintNotification = function(_, text) e.notes[#e.notes + 1] = tostring(text) end
    e.Overlord.SaveState = function() end
    e.OverlordDB.zones, e.OverlordDB.frontVictories, e.OverlordDB.frontTruceResetEpoch = {}, {}, {}
    e.Overlord.Fronts:Activate("elwynn")
    e.Overlord.Zones:ApplyFactionConfig(faction)
    e.Overlord:RestoreZoneState()
    e.loadfile("SyncHistoryCatchup.lua")()
    e.loadfile("SyncLeaderboardPages.lua")()
    e.loadfile("SyncRelay.lua")()
    e.Overlord.RelayEnabled = true
    e.Overlord.Relay.BridgeChannelHold = { 0, 0 }
    -- Count the map requests received and the map replies applied.
    local onSr = s.OnSyncRequest
    s.OnSyncRequest = function(self, ...) e.traffic.sr = e.traffic.sr + 1; return onSr(self, ...) end
    local onZa = s.OnReceiveZoneAll
    s.OnReceiveZoneAll = function(self, ...) e.traffic.za = e.traffic.za + 1; return onZa(self, ...) end
    clients[#clients + 1] = e
    return e
end


local WIN = client("Ally Tester", "alliance", "Alliance")
local LATE = client("Mate Tester", "alliance", "Alliance")
local function world(e, frontId)
    local out = {}
    for id, front in pairs(e.Overlord.Fronts.Registry) do
        if not frontId or id == frontId then
            for _, z in ipairs(front.zones) do
                out[#out + 1] = z.id .. "=" .. tostring(z.owner or "N") .. "@" .. tostring(z.owner and z.capturedTime or 0)
            end
        end
    end
    table.sort(out)
    return table.concat(out, ",")
end
local function set(e, id, owner, at)
    local zone = select(1, e.Overlord.Fronts:GetZone(id))
    local active = e.Overlord.Zones:GetZone(id)
    for _, z in ipairs({ zone, active }) do
        z.owner, z.status, z.capturedTime, z.updatedAt = owner, "captured", at, at
        z._loginSyncUnconfirmed = nil
    end
end
for _, e in ipairs(clients) do
    for _, front in pairs(e.Overlord.Fronts.Registry) do
        for _, z in ipairs(front.zones) do z._loginSyncUnconfirmed = nil end
    end
    if e.Overlord.MarkCaptureSyncReceived then e.Overlord:MarkCaptureSyncReceived(true) end
end
-- Everything either client sends through the relay, by kind.
for _, e in ipairs(clients) do
    e.sent = {}
    local send = e.Overlord.Relay.Send
    e.Overlord.Relay.Send = function(self, kind, payload, target, immediate)
        local ok = send(self, kind, payload, target, immediate)
        if ok then e.sent[#e.sent + 1] = { kind = kind, target = target or "*", at = now } end
        return ok
    end
end
local function sentKinds(e, since)
    local kinds = {}
    for _, row in ipairs(e.sent) do
        if row.at >= since then kinds[row.kind] = (kinds[row.kind] or 0) + 1 end
    end
    return kinds
end

-- Earlier today: the Alliance holds Elwynn but the Horde capital, on both clients; the
-- late client also still shows two points to the Horde (it left before they fell).
local front = WIN.Overlord.Fronts:GetFront("elwynn")
local T = WIN.time()
for _, e in ipairs(clients) do
    for i, z in ipairs(front.zones) do
        set(e, z.id, z.id == front.hordeCapitalId and "Horde" or "Alliance", T - 5000 + i)
    end
end
set(LATE, "elwynn_eastvale", "Horde", T - 9000)
set(LATE, "elwynn_jerods_landing", "Horde", T - 9001)
-- The Alliance takes the Horde capital: victory, the front repainted, a truce. Only the
-- winner's client is there for it.
local V = T
WIN.Overlord.Zones:SetVictoryCooldown("elwynn", "Alliance", V)
WIN.Overlord.Zones:ForceSyncFrontToWinner("elwynn", "Alliance", V, true)
assert(select(1, WIN.Overlord.Zones:IsOnVictoryCooldown("elwynn")), "Test setup: no truce on the winner's client")

-- (1) Fifteen minutes later its truce ends: the conquest takes the dates of the truce
-- end, and nothing leaves this client.
advance(905)
local endedAt = now
WIN.Overlord.Zones:TryExpireFrontTruces()
local E = V + 900
assert(WIN.OverlordDB.frontTruceResetEpoch.elwynn == E, "The truce did not end on the winner's client")
advance(60)
assert(next(sentKinds(WIN, endedAt)) == nil, "A truce end still sent something")
local cap = select(1, WIN.Overlord.Fronts:GetZone(front.hordeCapitalId))
assert(cap.owner == "Alliance" and cap.capturedTime == E + 1, "The fallen capital is not kept at the truce end")
print("Silent truce end: the client that ends a truce sends nothing")

-- The late client knows the victory from the journal only (the usual case), and its
-- "recent activity" must not take the truce-end dates of the map for captures.
local activity = {}
LATE.Overlord.GetLatestDominationVictoryForFront = function(_, frontId)
    -- Four seconds apart from the winner's own date: two clients may differ by up to
    -- five on a victory, and the kept capital adds one.
    if frontId == "elwynn" then return V - 4, "Alliance" end
    return 0, nil
end
LATE.Overlord.FrontActivity = LATE.Overlord.FrontActivity or {}
LATE.Overlord.FrontActivity.RecordByZoneRef = function(_, zoneId, _, at) activity[#activity + 1] = { zoneId = zoneId, at = at } end
-- (2) The late client comes back and hears its neighbour: its presence says another map,
-- so it asks for it (the real pull, SyncRelay).
local askedAt = now
for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
advance(120)
assert((sentKinds(LATE, askedAt).SR or 0) >= 1 and WIN.traffic.sr >= 1, "Test setup: the late client asked for no map")
local answer = sentKinds(WIN, askedAt)
assert((answer.ZA or 0) >= 1, "Test setup: no map answer left")
assert(answer.FR == nil, "A map answer still carries truce-end rows: " .. tostring(answer.FR))
print("Silent truce end: a map answer carries no truce-end row")

-- (3) Same map on both sides, dates included; no truce and no victory on the late client.
assert(world(LATE, "elwynn") == world(WIN, "elwynn"),
    "The late client did not end with the winner's map: " .. world(LATE, "elwynn") .. " / " .. world(WIN, "elwynn"))
LATE.Overlord.InActiveFront = true
LATE.Overlord.Zones:TryExpireFrontTruces()
if LATE.Overlord.Sync.CheckTotalVictoryFromSync then LATE.Overlord.Sync:CheckTotalVictoryFromSync() end
advance(30)
assert(not select(1, LATE.Overlord.Zones:IsOnVictoryCooldown("elwynn")), "The late client opened a truce of its own")
assert(LATE.OverlordDB.frontVictories.elwynn == nil, "The late client recorded a victory of its own")
assert(world(LATE, "elwynn") == world(WIN, "elwynn"), "The late client's map moved after the answer")
for _, text in ipairs(LATE.notes) do
    assert(not text:find("VICTORY", 1, true) and not text:find("TRUCE", 1, true),
        "The late client announced something: " .. text)
end
-- What it would answer in turn is the same map.
local pages = LATE.Overlord.Sync:BuildZoneAllSnapshotPages(front.zones, "F")
local mine = WIN.Overlord.Sync:BuildZoneAllSnapshotPages(front.zones, "F")
local function bodies(list)
    local out = {}
    for i, page in ipairs(list) do out[i] = page:match("|(.*)$") end
    return table.concat(out, ",")
end
assert(bodies(pages) == bodies(mine), "The late client would answer another map")
for _, row in ipairs(activity) do
    assert(row.at ~= E and row.at ~= E + 1, "A truce-end date read on the map was recorded as a capture: " .. row.zoneId)
end
print("Silent truce end: a late client reads the conquest in the map, with no truce and no victory of its own")

-- (4) A client that holds a victory ends its truce at its next 30 s tick; until then the
-- victory record is still there. Asked for its map in between, it used to replay the
-- victory (TV, VT, VF) although the truce was over, and the asker showed a new victory.
local second = WIN.Overlord.Fronts:GetFront("redridge")
local T2 = WIN.time()
for _, e in ipairs(clients) do
    for i, z in ipairs(second.zones) do
        set(e, z.id, z.id == second.hordeCapitalId and "Horde" or "Alliance", T2 - 5000 + i)
    end
end
WIN.Overlord.Zones:SetVictoryCooldown("redridge", "Alliance", T2)
WIN.Overlord.Zones:ForceSyncFrontToWinner("redridge", "Alliance", T2, true)
advance(903) -- the truce is over by the clock; the winner's tick has not run yet
assert(WIN.OverlordDB.frontVictories.redridge ~= nil, "Test setup: the victory record is gone")
local notesBefore = #LATE.notes
-- Meanwhile the Horde retook a point of Elwynn, five minutes after the truce end: a real
-- capture, which the late client's recent activity must record (positive control).
set(WIN, "elwynn_eastvale", "Horde", E + 300)
local secondAsk = now
for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
advance(60)
local replay = sentKinds(WIN, secondAsk)
assert((replay.ZA or 0) >= 1, "Test setup: no second map answer left")
assert(replay.TV == nil and replay.VT == nil and replay.VF == nil,
    "A victory whose truce is over was replayed in a map answer")
assert(LATE.OverlordDB.frontVictories.redridge == nil, "The late client took an ended truce for a running one")
for i = notesBefore + 1, #LATE.notes do
    assert(not LATE.notes[i]:find("VICTORY", 1, true) and not LATE.notes[i]:find("TRUCE", 1, true),
        "The late client announced a victory whose truce was over: " .. LATE.notes[i])
end
local recorded = false
for _, row in ipairs(activity) do
    if row.zoneId == "elwynn_eastvale" and row.at == E + 300 then recorded = true end
end
assert(recorded, "A real capture made after the truce end was not recorded as recent activity")
print("Silent truce end: a victory whose truce is over is not replayed; a real capture after it is still recorded")
