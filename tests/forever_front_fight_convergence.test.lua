-- Recent activity converges: every client counts only the K it receives (a K is never
-- relayed), so each one announces the fight bracket it crosses (FK) and shows the
-- highest fresh bracket, its own or received. Several clients with partial views must
-- end up showing the same panel, with very few announcements and no reply to one.
local serverNow = 1789530000
local maps = {
    [1437] = { name = "Wetlands", mapType = 3 },
    [1424] = { name = "Hillsbrad Foothills", mapType = 3 },
    [1581] = { name = "The Deadmines", mapType = 4 },
}
local sharedEnv = {
    Enum = { UIMapType = { Zone = 3, Dungeon = 4 } },
    C_Map = { GetMapInfo = function(id) return maps[id] end },
    GetServerTime = function() return serverNow end,
    GetTime = function() return serverNow end,
    time = function() return serverNow end,
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
}

local bus = { sent = {} }
local clients = {}

local function newClient(name)
    local env = setmetatable({}, { __index = function(_, k)
        if sharedEnv[k] ~= nil then return sharedEnv[k] end
        return _G[k]
    end })
    env._G = env
    env.Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }) }
    env.OverlordDB = {}
    local client = { name = name, env = env, timers = {} }
    env.C_Timer = { After = function(delay, fn) client.timers[#client.timers + 1] = fn end }
    env.Overlord.BetaNetwork = {
        Broadcast = function(_, kind, payload)
            assert(kind == "FK")
            bus.sent[#bus.sent + 1] = { from = client, payload = payload }
            for _, other in ipairs(clients) do
                if other ~= client then
                    other.FA:OnReceiveKillBracket(payload, name, "BETA")
                end
            end
            return 1
        end,
    }
    for _, file in ipairs({ "Fronts.lua", "FrontActivity.lua" }) do
        local fn = assert(loadfile(file))
        setfenv(fn, env)
        fn()
    end
    client.FA = env.Overlord.FrontActivity
    clients[#clients + 1] = client
    return client
end

-- Same brackets as the dock (Popups.lua).
local BRACKETS = { 500, 300, 200, 150, 100, 75, 50, 40, 30, 20, 10, 5 }
local function shown(kills)
    for _, floor in ipairs(BRACKETS) do if kills >= floor then return floor .. "+" end end
    return kills > 0 and "active" or "-"
end
-- Exactly what the dock prints (Popups.lua FormatFrontActivityAge), in row order.
local function panel(client)
    local out = {}
    for _, row in ipairs(client.FA:GetActivityRows()) do
        if row.active then
            local text = shown(row.kills)
            if text == "active" or text == "-" then
                local age = math.max(0, tonumber(row.ageSeconds) or 0)
                text = age < 60 and "now" or (math.min(5, math.floor(age / 60)) .. "min")
            end
            out[#out + 1] = row.frontId .. "=" .. text
        end
    end
    return table.concat(out, " ")
end

-- Fire every pending announce in a shuffled order (no client is privileged).
local function runTimers()
    local fired = 0
    while true do
        local pending = {}
        for _, client in ipairs(clients) do
            for _, fn in ipairs(client.timers) do pending[#pending + 1] = fn end
            client.timers = {}
        end
        if #pending == 0 then return fired end
        for i = #pending, 2, -1 do
            local j = math.random(1, i)
            pending[i], pending[j] = pending[j], pending[i]
        end
        for _, fn in ipairs(pending) do fn(); fired = fired + 1 end
    end
end

-- As Sync:OnReceiveKill does: the K is kill evidence (it no longer dates the row while
-- brackets are shared), then the guild alert's delta feeds the fight size.
local function kills(client, zoneRef, n)
    for _ = 1, n do
        client.FA:RecordKillActivity(zoneRef, "Killer Tester")
        assert(client.FA:RecordKills(zoneRef, 1))
    end
end

math.randomseed(42)
local a, b, c, d = newClient("Alpha One"), newClient("Bravo Two"), newClient("Charlie Three"), newClient("Delta Four")
-- Partial views of the same fights: Alpha hears 32 kills in Hillsbrad and 6 in the
-- Wetlands, Bravo 12, Charlie 3 (an active front, no bracket yet), Delta nothing.
kills(a, "@hillsbrad", 32)
kills(a, "#1437", 6)
kills(b, "@hillsbrad", 12)
kills(c, "@hillsbrad", 3)
kills(c, "@ashenvale", 2)
runTimers()
local expected = panel(a)
assert(expected:find("hillsbrad=30+", 1, true) and expected:find("#1437=5+", 1, true)
    and expected:find("ashenvale=now", 1, true), "Alpha's own panel is wrong: " .. expected)
for _, client in ipairs(clients) do
    assert(panel(client) == expected, client.name .. " sees " .. panel(client) .. " instead of " .. expected)
end
-- Few announcements: at most one per zone and bracket crossed (Hillsbrad 1/5/10/20/30 at
-- most from the first crossings, the Wetlands 5, Ashenvale 1), never one per kill.
assert(#bus.sent <= 9, "too many announcements: " .. #bus.sent)
local sentBefore = #bus.sent

-- Receiving never schedules a send (no reply amplifier).
for _, client in ipairs(clients) do assert(#client.timers == 0, "an announcement scheduled a reply") end

-- More kills below an already announced bracket: no new announcement.
kills(b, "@hillsbrad", 5)
runTimers()
assert(#bus.sent == sentBefore, "a covered bracket was announced again")

-- A herd: ten clients cross the same bracket at once; one announcement is enough.
local herd = {}
for i = 1, 10 do herd[i] = newClient("Herd Member" .. string.char(64 + i)) end
bus.sent = {}
for _, client in ipairs(herd) do kills(client, "@redridge", 22) end
runTimers()
local redridge = 0
for _, msg in ipairs(bus.sent) do if msg.payload:find(":redridge:20:", 1, true) then redridge = redridge + 1 end end
assert(redridge == 1, "the herd sent " .. redridge .. " identical announcements")

-- While the fight goes on, the best-informed client refreshes before the bracket
-- expires; the others keep showing it. When it stops, it expires everywhere together.
serverNow = serverNow + 170
kills(a, "@hillsbrad", 30)
runTimers()
serverNow = serverNow + 170
-- Alpha's first 32 kills left its window; the 50+ it announced with the new ones is
-- still fresh: every client shows the same 50+.
for _, client in ipairs(clients) do
    assert(panel(client):find("hillsbrad=50+", 1, true), client.name .. " lost the ongoing fight: " .. panel(client))
end
serverNow = serverNow + 400
for _, client in ipairs(clients) do
    assert(panel(client) == "", client.name .. " still shows an old fight: " .. panel(client))
end

-- A steady fight at the same bracket: the best-informed client refreshes its bracket
-- before it expires, so a client that hears none of the kills keeps showing it.
do
    for _, client in ipairs(clients) do client.FA:ResetForCampaign() end
    local best, watcher = newClient("Steady Best"), newClient("Steady Watcher")
    kills(best, "@arathi", 32)
    runTimers()
    assert(panel(watcher) == "arathi=30+", "watcher did not get the bracket: " .. panel(watcher))
    serverNow = serverNow + 215
    kills(best, "@arathi", 1)
    runTimers()
    serverNow = serverNow + 95
    assert(panel(watcher) == "arathi=30+", "the steady fight was not refreshed: " .. panel(watcher))
    assert(panel(best) == panel(watcher), "best and watcher disagree: " .. panel(best) .. " / " .. panel(watcher))
end

-- End of a fight: the panel stays identical every 30 s until the rows expire, whether
-- a client heard the kills or only the shared brackets.
do
    for _, client in ipairs(clients) do client.FA:ResetForCampaign() end
    local hearer, other = newClient("End Hearer"), newClient("End Other")
    -- 12 kills (10+ announced), then a trickle that stays under the next bracket and
    -- stops before the refresh: the hearer still holds 5 recent kills when the shared
    -- bracket expires. Neither its count nor its own clock may show on its panel.
    kills(hearer, "@arathi", 12)
    runTimers()
    for _ = 1, 5 do
        serverNow = serverNow + 30
        kills(hearer, "@arathi", 1)
        runTimers()
    end
    for _ = 1, 14 do
        assert(panel(hearer) == panel(other), "end of fight differs: " .. panel(hearer) .. " / " .. panel(other))
        serverNow = serverNow + 30
    end
    assert(panel(hearer) == "" and panel(other) == "", "rows did not expire together")
end

-- A K carrying a front's own map ("#uiMapID") does not date that front locally either:
-- nothing shows before the shared bracket, then the same panel everywhere.
do
    for _, client in ipairs(clients) do client.FA:ResetForCampaign() end
    local mapHearer, mapOther = newClient("Map Hearer"), newClient("Map Other")
    kills(mapHearer, "#1424", 3)
    assert(panel(mapHearer) == "", "a front map K dated the row locally: " .. panel(mapHearer))
    runTimers()
    assert(panel(mapHearer) ~= "" and panel(mapHearer) == panel(mapOther),
        "front map K: " .. panel(mapHearer) .. " / " .. panel(mapOther))
end

-- Same bracket: rows are ordered by front id, never by the translated name, so a
-- French and an English player list them in the same order.
do
    for _, client in ipairs(clients) do client.FA:ResetForCampaign() end
    local viewer = newClient("Order Viewer")
    -- A translated name that sorts last (as "Hautes-terres d'Arathi" would among others).
    viewer.env.Overlord.Fronts:GetFront("arathi").dropdownLabel = "Zz Arathi"
    local s30 = math.floor(serverNow / 30)
    for _, id in ipairs({ "redridge", "arathi", "hillsbrad" }) do
        assert(viewer.FA:OnReceiveKillBracket("1:" .. id .. ":10:" .. s30, "Order " .. id, "BETA"))
    end
    assert(panel(viewer) == "arathi=10+ hillsbrad=10+ redridge=10+", "tie order: " .. panel(viewer))
end

-- A send refused by a saturated relay covers nothing: the client tries again later,
-- and the others get the bracket once the relay accepts it.
do
    for _, client in ipairs(clients) do client.FA:ResetForCampaign() end
    local busy, peer = newClient("Busy Sender"), newClient("Busy Peer")
    local realBroadcast = busy.env.Overlord.BetaNetwork.Broadcast
    busy.env.Overlord.BetaNetwork.Broadcast = function() return 0 end
    kills(busy, "@redridge", 12)
    runTimers()
    assert(panel(peer) == "", "a refused bracket reached the others")
    busy.env.Overlord.BetaNetwork.Broadcast = realBroadcast
    serverNow = serverNow + 25
    kills(busy, "@redridge", 1)
    runTimers()
    assert(panel(peer) == "redridge=10+" and panel(busy) == panel(peer),
        "the refused bracket was never sent again: " .. panel(peer) .. " / " .. panel(busy))
end

-- A raw FK posted on the channel or in a group by a stranger is ignored.
do
    local fa = d.FA
    fa:ResetForCampaign()
    local s30 = math.floor(serverNow / 30)
    assert(not fa:OnReceiveKillBracket("1:hillsbrad:500:" .. s30, "Stranger Tester", "CHANNEL"),
        "a raw channel FK was accepted")
    assert(not fa:OnReceiveKillBracket("1:hillsbrad:500:" .. s30, "Stranger Tester", "PARTY"),
        "a raw party FK was accepted")
    assert(panel(d) == "", "a stranger's raw FK reached the panel")
end

-- A client that logs in mid-fight gets the current brackets in the sync reply and
-- shows the same panel right away.
do
    for _, client in ipairs(clients) do client.FA:ResetForCampaign() end
    local veteran = newClient("Sync Veteran")
    kills(veteran, "@ashenvale", 22)
    kills(veteran, "#1437", 7)
    runTimers()
    local joiner = newClient("Sync Joiner")
    local entries = veteran.FA:BuildKillBracketSyncEntries()
    assert(#entries >= 2, "no brackets offered in the sync reply")
    for _, payload in ipairs(entries) do
        joiner.FA:OnReceiveKillBracket(payload, veteran.name, "BETA")
    end
    assert(panel(joiner) == panel(veteran), "the joiner sees " .. panel(joiner) .. " instead of " .. panel(veteran))
end

-- At scale: 40 clients, four fronts fought for 10 minutes, each kill heard by a random
-- quarter of the clients. Everyone shows the same panel all along, and the network
-- carries a handful of announcements per front, not one per kill.
do
    for _, client in ipairs(clients) do client.FA:ResetForCampaign() end
    local crowd = {}
    for i = 1, 40 do crowd[i] = newClient("Crowd Member" .. string.char(64 + (i % 26) + 1) .. i) end
    bus.sent = {}
    local fronts = { "@hillsbrad", "@ashenvale", "@redridge", "@arathi" }
    local killCount, mismatches = 0, 0
    for minute = 1, 10 do
        for _ = 1, 6 do
            serverNow = serverNow + 10
            for f, ref in ipairs(fronts) do
                for _ = 1, f do
                    killCount = killCount + 1
                    for _, client in ipairs(crowd) do
                        if math.random() < 0.25 then
                            client.FA:RecordKillActivity(ref, "Killer Tester")
                            client.FA:RecordKills(ref, 1)
                        end
                    end
                end
            end
            runTimers()
        end
        local first = panel(crowd[1])
        for _, client in ipairs(crowd) do
            if panel(client) ~= first then mismatches = mismatches + 1 end
        end
    end
    assert(mismatches == 0, mismatches .. " minute checks saw different panels")
    assert(#bus.sent <= 4 * 12, string.format("%d announcements for %d kills over 10 min", #bus.sent, killCount))
    __fkScale = string.format("%d announcements for %d kills, 40 clients, 4 fronts, 10 min", #bus.sent, killCount)
end

-- Invalid announcements are ignored: unknown bracket, unknown front, dungeon map,
-- a world zone below 5, a slot too old or in the future, oversized payload.
local slot = math.floor(serverNow / 30)
local fa = d.FA
fa:ResetForCampaign()
assert(not fa:OnReceiveKillBracket("1:hillsbrad:7:" .. slot, "X", "BETA"), "bracket 7 accepted")
assert(not fa:OnReceiveKillBracket("1:nowhere:10:" .. slot, "X", "BETA"), "unknown front accepted")
assert(not fa:OnReceiveKillBracket("1:#1581:10:" .. slot, "X", "BETA"), "a dungeon accepted")
assert(not fa:OnReceiveKillBracket("1:#1437:1:" .. slot, "X", "BETA"), "a world zone below 5 accepted")
assert(not fa:OnReceiveKillBracket("1:hillsbrad:10:" .. (slot - 11), "X", "BETA"), "an old slot accepted")
assert(not fa:OnReceiveKillBracket("1:hillsbrad:10:" .. (slot + 3), "X", "BETA"), "a future slot accepted")
assert(not fa:OnReceiveKillBracket("1:hillsbrad:10:" .. slot .. string.rep("0", 60), "X", "BETA"),
    "an oversized payload accepted")
assert(fa:OnReceiveKillBracket("1:hillsbrad:10:" .. slot, "X", "BETA"), "a valid announcement refused")
-- One sender flooding announcements is cut after its budget (20 per minute).
local accepted = 0
for i = 1, 30 do
    if fa:OnReceiveKillBracket("1:arathi:" .. (i % 2 == 0 and 20 or 30) .. ":" .. (slot - (i % 9)), "Flood Tester", "BETA") then
        accepted = accepted + 1
    end
end
assert(accepted <= 20, "a flooding sender got " .. accepted .. " announcements accepted")
fa:ResetForCampaign()
-- Hundreds of honest senders in one minute are never locked out (oldest make room).
for i = 1, 300 do
    fa:OnReceiveKillBracket("1:redridge:" .. (i <= 150 and 5 or 10) .. ":" .. (slot - (i % 2)), "Crowd Sender" .. i, "BETA")
end
assert(fa:OnReceiveKillBracket("1:redridge:20:" .. slot, "Late Honest Sender", "BETA"),
    "a new honest sender was refused after 300 others")
assert(fa:GetDisplayKillCount("redridge") == 20, "the crowd's bracket was lost")
fa:ResetForCampaign()

-- Inside an instance nothing is announced or received; the weekly reset forgets it all.
d.env.Overlord.InstanceSuspended = true
assert(not fa:OnReceiveKillBracket("1:hillsbrad:20:" .. slot, "X", "BETA"), "received inside an instance")
assert(not fa:RecordKills("@hillsbrad", 9) and #d.timers == 0, "announced from inside an instance")
d.env.Overlord.InstanceSuspended = false
fa:ResetForCampaign()
assert(panel(d) == "", "the weekly reset kept an announced bracket: " .. panel(d))
print("Front fight convergence: same panel everywhere, few announcements, herd, refresh, expiry, validation OK; " .. tostring(__fkScale))
