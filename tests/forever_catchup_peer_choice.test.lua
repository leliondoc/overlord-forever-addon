-- Legacy HR catch-up peer choice (real SyncHistoryCatchup/Pages/BetaNetwork modules,
-- simulated clock and transports). Run from the addon root with Lua 5.1.
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
    function w.start() return s:ScheduleLoginLeaderboardHistoryCatchUp(true, false) end
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

-- 1. The nearest same-faction peer beats a 2-hop enemy peer (an ally with enemy
--    Battle.net friends already holds the enemy rows; the far peer loses lines per hop).
do
    local w = world({
        { name = "Near Ally", faction = "Alliance", hops = 1 },
        { name = "Far Enemy", faction = "Horde", hops = 2 },
    }, "Alliance")
    assert(w.start(), "round not scheduled")
    w.advance(60)
    local hr = w.hr()
    check("first HR sent", #hr >= 1, #hr)
    check("nearest 1-hop ally chosen over 2-hop enemy", hr[1] and hr[1].target == "Near Ally",
        hr[1] and hr[1].target)
end

-- 2. A peer that never replied is skipped by the next attempt, even though it is
--    still the nearest one (HEAD keeps returning to the nearest enemy peer).
do
    local w = world({
        { name = "Silent Enemy", faction = "Horde", hops = 1 },
        { name = "Other Enemy", faction = "Horde", hops = 2 },
    }, "Alliance")
    assert(w.start(), "round not scheduled")
    w.advance(24 + 270 + 12 + 60) -- initial delay + no-reply window + retry delay + slack
    local hr = w.hr()
    check("two HR attempts", #hr >= 2, #hr)
    check("first attempt targets the nearest peer", hr[1] and hr[1].target == "Silent Enemy",
        hr[1] and hr[1].target)
    check("silent peer skipped on the next attempt", hr[2] and hr[2].target ~= hr[1].target,
        hr[2] and hr[2].target)
end

-- 3. A transfer that started and then froze is abandoned after about 90 s
--    instead of waiting for the 20 minute ACK timeout.
do
    local w = world({
        { name = "Frozen Ally", faction = "Alliance", hops = 1 },
        { name = "Backup Ally", faction = "Alliance", hops = 2 },
    }, "Alliance")
    assert(w.start(), "round not scheduled")
    w.advance(40)
    local hr = w.hr()
    assert(hr[1] and hr[1].target == "Frozen Ally", "unexpected first target " .. tostring(hr[1] and hr[1].target))
    local sync = w.sync
    for i = 1, 3 do -- three rows arrive, then silence
        assert(sync:NoteHistoryCatchupDelivery("LK", "Row Player" .. i .. ":10", "Frozen Ally", "WHISPER"),
            "delivery not counted")
        w.advance(5)
    end
    local lastRowAt = w.now()
    w.advance(75) -- 75 s after the last row: still waiting
    check("still waiting before the stall window", #w.hr() == 1, #w.hr())
    w.advance(60 + 12 + 5) -- watcher granularity + retry delay
    local after = w.hr()
    check("stalled transfer abandoned, next peer asked", #after >= 2 and after[2].target == "Backup Ally",
        #after >= 2 and after[2].target or #after)
    check("abandoned well before the 1200 s ACK timeout",
        #after >= 2 and after[2].at - lastRowAt < 200, #after >= 2 and (after[2].at - lastRowAt))
end

-- 4. A peer that answered (ACK) but never sent a single row is abandoned after about
--    90 s too; neither the no-reply window nor the stall watcher used to cover it (live
--    report 2026-09-30: "request sent, 655s ago, Round running: yes").
do
    local w = world({
        { name = "Mute Ally", faction = "Alliance", hops = 1 },
        { name = "Backup Ally", faction = "Alliance", hops = 2 },
    }, "Alliance")
    assert(w.start(), "round not scheduled")
    w.advance(40)
    local hr = w.hr()
    assert(hr[1] and hr[1].target == "Mute Ally", "unexpected first target " .. tostring(hr[1] and hr[1].target))
    local version, campaignId, _, nonce = w.e.strsplit(":", hr[1].payload, 6)
    -- A stray terminal status the requester cannot use: it marks the peer as having replied.
    w.sync:OnHistoryCatchupAck(table.concat({ version, campaignId, nonce, "C", "0", "0" }, ":"),
        "Mute Ally", "WHISPER")
    local repliedAt = w.now()
    w.advance(75)
    check("still waiting shortly after the reply", #w.hr() == 1, #w.hr())
    w.advance(60 + 12 + 5)
    local after = w.hr()
    check("replied-but-silent peer abandoned, next peer asked", #after >= 2 and after[2].target == "Backup Ally",
        #after >= 2 and after[2].target or #after)
    check("abandoned well before the 1200 s ACK timeout",
        #after >= 2 and after[2].at - repliedAt < 200, #after >= 2 and (after[2].at - repliedAt))
end

if #failures > 0 then error("peer choice regression:\n  " .. table.concat(failures, "\n  "), 0) end
print("Forever catch-up peer choice: nearest peer, failed-peer skip, stalled and replied-but-silent abandon OK")
