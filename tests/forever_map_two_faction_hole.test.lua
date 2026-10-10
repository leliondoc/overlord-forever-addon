-- 1.8.2, end to end with the real code on every side (Sync, relay, map request and
-- reply; only WoW's transports and the clock are simulated). The report of
-- 2026-10-10: an Alliance client and its channel mate miss seven Horde captures on
-- Arathi while they hold a newer capture on another front; their Horde Battle.net
-- friend holds everything. Under 1.8.1 nobody pulled anything (same newest capture
-- on every side) and each faction kept its own Arathi for good.
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
    e.Overlord.PrintNotification = function() end
    e.Overlord.SaveState = function() end
    e.OverlordDB.zones, e.OverlordDB.frontVictories, e.OverlordDB.frontTruceResetEpoch = {}, {}, {}
    e.Overlord.Fronts:Activate("redridge")
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

local ALLY = client("Ally Tester", "alliance", "Alliance")
local MATE = client("Mate Tester", "alliance", "Alliance")
local HORDE = client("Horde Tester", "horde", "Horde")
ALLY.friends, HORDE.friends = { HORDE }, { ALLY }
ALLY.Overlord.Sync.GetResolvedBNetPlayerFaction = function(_, n) return n == HORDE.name and "Horde" or nil end
HORDE.Overlord.Sync.GetResolvedBNetPlayerFaction = function(_, n) return n == ALLY.name and "Alliance" or nil end

local epoch = ALLY.Overlord:GetCurrentCampaignStartTs()
local function set(e, id, owner, at)
    local zone = select(1, e.Overlord.Fronts:GetZone(id))
    local active = e.Overlord.Zones:GetZone(id)
    for _, z in ipairs({ zone, active }) do
        z.owner, z.status, z.capturedTime, z.updatedAt = owner, "captured", at, at
        z._loginSyncUnconfirmed = nil
    end
end
local function view(e, ids)
    local out = {}
    for _, id in ipairs(ids) do
        local z = select(1, e.Overlord.Fronts:GetZone(id))
        out[#out + 1] = (z.owner or "N"):sub(1, 1)
    end
    return table.concat(out)
end
local function world(e)
    local out = {}
    for _, front in pairs(e.Overlord.Fronts.Registry) do
        for _, z in ipairs(front.zones) do
            out[#out + 1] = z.id .. "=" .. tostring(z.owner or "N") .. "@" .. tostring(z.owner and z.capturedTime or 0)
        end
    end
    table.sort(out)
    return table.concat(out, ",")
end
for _, e in ipairs(clients) do
    for _, front in pairs(e.Overlord.Fronts.Registry) do
        for _, z in ipairs(front.zones) do z._loginSyncUnconfirmed = nil end
    end
    if e.Overlord.MarkCaptureSyncReceived then e.Overlord:MarkCaptureSyncReceived(true) end
end
-- Yesterday: the Alliance holds Arathi's eight points (everyone knows).
local T = ALLY.time()
local arathi = { "faldir", "witherbark", "goshek", "dabyrie", "highperch", "argorok", "refuge", "newstead" }
for _, e in ipairs(clients) do
    for i, id in ipairs(arathi) do set(e, id, "Alliance", T - 40000 + i) end
end
-- This morning: seven Horde captures on Arathi that only the Horde side saw ...
local taken = { "dabyrie", "goshek", "witherbark", "newstead", "refuge", "argorok", "highperch" }
for i, id in ipairs(taken) do set(HORDE, id, "Horde", T - 6000 + i * 300) end
-- ... then a capture on another front that everyone saw (the newest of all).
for _, e in ipairs(clients) do set(e, "durotar_razor_hill", "Horde", T - 600) end

local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
    later(120, heartbeat)
end
assert(view(ALLY, arathi) == "AAAAAAAA" and view(MATE, arathi) == "AAAAAAAA" and view(HORDE, arathi) == "AHHHHHHH",
    "fixture: the three views of Arathi are not the reported ones")
later(5, heartbeat)
-- The Alliance client pulls its Horde friend's map on the friend's presence ...
advance(150)
assert(view(ALLY, arathi) == "AHHHHHHH", "the hole was not repaired from the Battle.net friend within 2.5 min: "
    .. view(ALLY, arathi))
-- ... and its channel mate, who has no friend of the other faction, pulls it in turn.
advance(300)
assert(view(MATE, arathi) == "AHHHHHHH", "the hole did not spread to the channel mate within 7.5 min: "
    .. view(MATE, arathi))
assert(world(ALLY) == world(HORDE) and world(MATE) == world(HORDE), "the three maps are not identical")
-- One map each was enough, and the Horde friend, who lacked nothing, pulled none.
local pages = ALLY.traffic.za
assert(pages > 0 and MATE.traffic.za == pages and HORDE.traffic.za == 0,
    ("map pages applied: %d / %d / %d"):format(ALLY.traffic.za, MATE.traffic.za, HORDE.traffic.za))
-- Equal maps: half an hour of presence, not one more request.
local requests = ALLY.traffic.sr + MATE.traffic.sr + HORDE.traffic.sr
advance(1800)
assert(ALLY.traffic.sr + MATE.traffic.sr + HORDE.traffic.sr == requests and ALLY.traffic.za == pages,
    "equal maps still asked each other for a map")
print("Forever map, two factions: a hole under a newer capture is repaired through the Battle.net friend, "
    .. "then along the channel, and equal maps stay silent")
