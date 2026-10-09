-- 1.7: ranking catch-up while the responder fights. A page already built still leaves
-- in combat; a responder that must build answers "busy: combat" and the requester
-- waits for it (same peer, same place) instead of ending its round.
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
    e.InCombatLockdown = function() return e.combat == true end
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
local function heartbeat()
    for _, e in ipairs(clients) do e.Overlord.BetaNetwork:Broadcast("NH", e.Overlord.Version) end
    later(45, heartbeat)
end
heartbeat()
advance(10)
for i = 1, 400 do
    local name = "Player " .. string.char(65 + math.floor((i - 1) / 26)) .. string.char(97 + (i - 1) % 26)
    SOURCE.Overlord.Leaderboard.kills[name] = i
    SOURCE.Overlord.Leaderboard.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 60,
        locale = "engb", guild = "Veteran Guild", guildAt = 1790016000, race = "Orc", raceSex = 2, raceAt = 1 }
end
local stats = sync._leaderboardPageStats

-- 1) The responder fights when asked: "busy: combat", the requester waits, then completes.
SOURCE.combat = true
later(90, function() SOURCE.combat = false end)
local done
assert(sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(60)
assert(done == nil, "the pull gave up on a peer that is only fighting: "
    .. sync:GetPagedLeaderboardDiagnostics())
assert((stats.combatWaits or 0) >= 1, "no combat wait recorded")
for _ = 1, 120 do advance(60); if done ~= nil then break end end
assert(done == true, "pull after the fight failed: " .. sync:GetPagedLeaderboardDiagnostics())
assert(PULLER.Overlord.Leaderboard.kills["Player Pj"] == 400, "rows missing after the combat wait")

-- 2) The responder enters combat in the middle of a sweep: built pages keep coming.
PULLER.Overlord.Leaderboard.kills = {}
PULLER.Overlord.Leaderboard.playerInfo = {}
PULLER.Overlord.Leaderboard:MarkMetaDirty()
PULLER.OverlordDB.leaderboardPageProgress = nil
advance(700)
local pagesBefore = stats.pages
done = nil
assert(sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
for _ = 1, 90 do advance(1); if stats.pages > pagesBefore + 2 then break end end
assert(stats.pages > pagesBefore + 2, "the sweep did not start")
SOURCE.combat = true
for _ = 1, 120 do advance(60); if done ~= nil then break end end
assert(done == true, "a fight of the responder cut the sweep: " .. sync:GetPagedLeaderboardDiagnostics())
assert(PULLER.Overlord.Leaderboard.kills["Player Pj"] == 400)
SOURCE.combat = false

-- 3) A peer that stays in combat is not waited for forever (about 3 minutes, then another peer).
PULLER.OverlordDB.leaderboardPageProgress = nil
advance(700)
SOURCE.combat = true
done = nil
local waitsBefore = stats.combatWaits or 0
assert(sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
for _ = 1, 30 do advance(60); if done ~= nil then break end end
assert(done == false, "the pull waited forever for a peer that never stops fighting")
assert(stats.result:find("peer in combat", 1, true), tostring(stats.result))
-- At most 5 small re-asks to that peer (30-45 s apart), never one every few seconds.
assert((stats.combatWaits or 0) - waitsBefore == 5, "combat re-asks: " .. ((stats.combatWaits or 0) - waitsBefore))
SOURCE.combat = false
-- 4) The requester itself fights while it waits: it asks again a few seconds after its
-- own fight, not minutes later through the watchdog.
PULLER.Overlord.Leaderboard.kills = {}
PULLER.Overlord.Leaderboard.playerInfo = {}
PULLER.Overlord.Leaderboard:MarkMetaDirty()
PULLER.OverlordDB.leaderboardPageProgress = nil
advance(700)
SOURCE.combat = true
later(20, function() SOURCE.combat = false end)
later(20, function() PULLER.combat = true end)
later(70, function() PULLER.combat = false end)
local asks, askedAt = 0, nil
local realSendWhisper = sync.SendWhisper
sync.SendWhisper = function(self, kind, payload, target)
    if kind == "HR" and (payload:find(":Q:", 1, true) or payload:find("^8:[VLG]:")) then asks = asks + 1; askedAt = askedAt or (asks == 2 and now) end
    return realSendWhisper(self, kind, payload, target)
end
local startedAt = now
done = nil
assert(sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
advance(90)
assert(askedAt and askedAt - startedAt <= 80, "the requester did not ask again right after its own fight: "
    .. tostring(askedAt and askedAt - startedAt))
for _ = 1, 120 do advance(60); if done ~= nil then break end end
assert(done == true, "pull after both fights failed: " .. sync:GetPagedLeaderboardDiagnostics())
sync.SendWhisper = realSendWhisper
print("Paged catch-up in combat: busy-combat wait, sweep continues through a fight, bounded wait OK")
