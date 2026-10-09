-- Ranking catch-up peer choice (real SyncHistoryCatchup/Pages/BetaNetwork modules,
-- simulated clock and transports). Run from the addon root with Lua 5.1.
-- Since 1.2.4 only direct neighbours (hops == 1) are asked, in v7 (1.7.5; v6 before).
-- Set SRC_DIR to a folder holding other copies of the three modules to test them.
local SRC = SRC_DIR or "."
local function world(peers, playerFaction)
    local now, serial, pending = 100, 0, {}
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    local function later(delay, run)
        serial = serial + 1
        pending[#pending + 1] = { at = now + delay, run = run, serial = serial }
    end
    local w = { sent = {} }
    function w.advance(seconds)
        local stop, steps = now + seconds, 0
        while true do
            table.sort(pending, function(a, b)
                return a.at < b.at or (a.at == b.at and a.serial < b.serial)
            end)
            if not pending[1] or pending[1].at > stop then break end
            local ev = table.remove(pending, 1)
            now = ev.at
            ev.run()
            steps = steps + 1
            assert(steps < 200000, "runaway")
        end
        now = stop
    end
    function w.now() return now end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    e.loadfile("Leaderboard.lua")()
    e.Overlord.PlayerFaction = playerFaction
    e.GetTime = function() return now end
    e.time = function() return 1790017000 + math.floor(now) end
    e.GetServerTime = e.time
    e.UnitName = function() return "Test Player" end
    e.UnitFullName = function() return "Test Player", "" end
    e.GetUnitName = e.UnitName
    e.InCombatLockdown = function() return false end
    e.C_Timer = { After = later, NewTicker = function(delay, cb)
        local t = { Cancel = function(self) self.cancelled = true end }
        local function tick() if t.cancelled then return end cb() if not t.cancelled then later(delay, tick) end end
        later(delay, tick); return t end }
    e.strsplit = function(sep, value, limit)
        local f, start = {}, 1
        while not limit or #f < limit - 1 do
            local at = value:find(sep, start, true); if not at then break end
            f[#f + 1] = value:sub(start, at - 1); start = at + #sep
        end
        f[#f + 1] = value:sub(start); return unpack(f)
    end
    e.C_Club = { GetSubscribedClubs = function() return {} end }
    e.Enum = { ClubType = { Character = 1 } }
    local s, lb = e.Overlord.Sync, e.Overlord.Leaderboard
    s.GetPlayerFullName = function() return "Test Player" end
    s.SendWhisper = function(_, kind, payload, target)
        w.sent[#w.sent + 1] = { kind = kind, payload = payload, target = target, at = now }
        return true
    end
    s.SendSyncRequest = function() return true end
    lb.kills, lb.captureCount, lb.captures, lb.playerInfo = {}, {}, {}, {}
    lb._storageBound = true
    for _, file in ipairs({ "SyncHistoryCatchup.lua", "SyncLeaderboardPages.lua", "SyncBetaNetwork.lua" }) do
        setfenv(assert(loadfile(SRC .. "/" .. file)), e)()
    end
    local factions = {}
    for _, p in ipairs(peers) do factions[p.name] = p.faction end
    s.GetBetaPeerFaction = function(_, name) return factions[name] end
    -- Peers stay "heard" (fresh routes) for the whole scenario.
    local net = e.Overlord.BetaNetwork
    local function refresh()
        for _, p in ipairs(peers) do
            net.peers[p.name:lower()] = { name = p.name, at = now, via = p.name, hops = p.hops }
        end
        later(10, refresh)
    end
    refresh()
    e.OverlordDB.leaderboardHistoryCatchupTargetRotation = 0
    w.e, w.sync = e, s
    function w.start() return s:ScheduleLoginLeaderboardHistoryCatchUp(true) end
    function w.hr()
        local list = {}
        for _, m in ipairs(w.sent) do if m.kind == "HR" then list[#list + 1] = m end end
        return list
    end
    return w
end

local failures = {}
local function check(label, ok, detail)
    if not ok then failures[#failures + 1] = label .. (detail and (": " .. tostring(detail)) or "") end
end

-- 1. A direct neighbour is asked; a peer two relays away is never asked.
do
    local w = world({
        { name = "Near Ally", faction = "Alliance", hops = 1 },
        { name = "Far Enemy", faction = "Horde", hops = 2 },
    }, "Alliance")
    assert(w.start(), "round not scheduled")
    w.advance(60)
    local hr = w.hr()
    check("first request sent", #hr >= 1, #hr)
    check("direct ally chosen, far enemy never asked", hr[1] and hr[1].target == "Near Ally",
        hr[1] and hr[1].target)
    check("request is v7", hr[1] and hr[1].payload:sub(1, 2) == "7:", hr[1] and hr[1].payload)
end

-- 2. A direct neighbour that stays silent is skipped by the next attempt.
do
    local w = world({
        { name = "Silent Enemy", faction = "Horde", hops = 1 },
        { name = "Other Ally", faction = "Alliance", hops = 1 },
    }, "Alliance")
    assert(w.start(), "round not scheduled")
    w.advance(24 + 270 + 12 + 60) -- initial delay + v7 reply window + retry delay + slack
    local targets, order = {}, {}
    for _, m in ipairs(w.hr()) do
        if not targets[m.target] then targets[m.target] = true; order[#order + 1] = m.target end
    end
    check("the enemy neighbour is asked first", order[1] == "Silent Enemy", order[1])
    check("silent neighbour skipped on the next attempt", order[2] == "Other Ally", order[2])
end

-- 3. With only peers behind relays, nothing is requested at all.
do
    local w = world({
        { name = "Far Ally", faction = "Alliance", hops = 2 },
        { name = "Far Enemy", faction = "Horde", hops = 3 },
    }, "Alliance")
    assert(w.start(), "round not scheduled")
    w.advance(600)
    check("no request toward peers behind relays", #w.hr() == 0, #w.hr())
    local step = w.sync:GetHistoryCatchupSummary().step
    check("the round reports the missing neighbour", step == "no direct neighbour"
        or step == "all attempts used, next round in 2 min", step)
end

-- 4. Rotation reaches every neighbour: with three neighbours (one enemy) the
--    old shared modulo-3 counter never asked "Ally One".
do
    local w = world({
        { name = "Ally One", faction = "Alliance", hops = 1 },
        { name = "Enemy Two", faction = "Horde", hops = 1 },
        { name = "Ally Three", faction = "Alliance", hops = 1 },
    }, "Alliance")
    local function find(fn, name, depth, seen)
        seen = seen or {}
        if seen[fn] or depth < 0 then return nil end
        seen[fn] = true
        for i = 1, 200 do
            local key, value = debug.getupvalue(fn, i)
            if not key then break end
            if key == name then return value end
            if type(value) == "function" then
                local found = find(value, name, depth - 1, seen)
                if found then return found end
            end
        end
    end
    local pick = find(w.sync.ScheduleLoginLeaderboardHistoryCatchUp, "PickDirectPeer", 4)
    check("PickDirectPeer reachable", pick ~= nil)
    local asked, enemyRounds = {}, 0
    for r = 0, 8 do
        w.e.OverlordDB.leaderboardHistoryCatchupTargetRotation = r
        local name = pick and pick()
        if name then asked[name] = true end
        if name == "Enemy Two" then enemyRounds = enemyRounds + 1 end
    end
    check("every neighbour asked within nine rounds", asked["Ally One"] and asked["Ally Three"]
        and asked["Enemy Two"])
    check("the enemy neighbour keeps two rounds out of three", enemyRounds == 6, enemyRounds)
end

-- 4. 1.7.5: a neighbour announcing a protocol older than v7 (a client before 1.7.0,
-- still open to forged rows) is left out of the rotation, even when it sorts first.
do
    local w = world({
        { name = "Aged Ally", faction = "Alliance", hops = 1 },
        { name = "Young Ally", faction = "Alliance", hops = 1 },
    }, "Alliance")
    w.e.Overlord.BetaNetwork.GetPeerPagedProtocol = function(_, name)
        return name == "Aged Ally" and 6 or 7
    end
    assert(w.start(), "round not scheduled")
    w.advance(60)
    local hr = w.hr()
    check("a v7 neighbour is asked", hr[1] and hr[1].target == "Young Ally", hr[1] and hr[1].target)
    for _, m in ipairs(hr) do
        check("a neighbour older than 1.7.0 was asked", m.target ~= "Aged Ally", m.target)
    end
    local diag = w.sync:GetCatchupNeighbourDiagnostics()
    check("an old neighbour stayed in the rotation", diag:find("before 1.7 1 (Aged Ally)", 1, true)
        and diag:find("ally 1 (Young Ally)", 1, true), diag)
end

if #failures > 0 then error("peer choice regression:\n  " .. table.concat(failures, "\n  "), 0) end
print("Forever catch-up peer choice: direct neighbours only, v7, silent neighbour skipped, far peers never asked OK")
