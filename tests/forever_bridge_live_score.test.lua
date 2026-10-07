-- Live-score bridge: an opposite-faction owner's K received over Battle.net (hop 0) is passed on as a
-- raw LK whisper to a few same-faction peers, bounded and only for plausible growth.
math.randomseed(1)
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 0 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)   -- the world-kills fixture ignores the limit argument
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
local s = Overlord.Sync
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
net.BridgeChannelHold = { 0, 0 } -- exact timings below
Overlord.PlayerFaction = "Alliance"
Overlord.BetaNetworkEnabled = true

local clock = 1000
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        clock = timer.at
        timer.fn()
    end
    clock = stop
end

local whispers = {}
function s:SendAddonChecked(msg, chatType, target)
    if msg:sub(1, 3) == "LK:" then whispers[#whispers + 1] = { at = clock, msg = msg, chatType = chatType, target = target } end
    return true
end

local EPOCH = 1789527600
local function lkRows(from)
    local rows = {}
    for i = from or 1, #whispers do
        local w = whispers[i]
        local name, total = w.msg:match("^LK:([^:]+):(%d+):")
        rows[#rows + 1] = { name = name, total = tonumber(total), target = w.target, chatType = w.chatType, msg = w.msg }
    end
    return rows
end
local function distinctRows(rows)
    local seen, n = {}, 0
    for _, r in ipairs(rows) do
        local key = r.name .. ":" .. r.total
        if not seen[key] then seen[key] = true; n = n + 1 end
    end
    return n
end

local samePeers = { "Peer Alpha", "Peer Bravo", "Peer Charlie", "Peer Delta", "Peer Echo" }
local function refreshPeers()
    for _, name in ipairs(samePeers) do
        net.peers[name:lower()] = { name = name, at = clock, via = name, transport = "CHANNEL", hops = 1 }
    end
    -- a peer known to be Horde and a peer routed through a bridge are never whisper targets
    Overlord.Leaderboard.playerInfo["Peer Enemy"] = { faction = "Horde", class = "WARRIOR", level = 60 }
    net.peers["peer enemy"] = { name = "Peer Enemy", at = clock, via = "Peer Enemy", transport = "WHISPER", hops = 1 }
    net.peers["peer distant"] = { name = "Peer Distant", at = clock, via = "Peer Alpha", transport = "CHANNEL", hops = 2 }
end
local function know(name, total, faction)
    Overlord.Leaderboard.kills[name] = total
    Overlord.Leaderboard.playerInfo[name] = { class = "WARRIOR", faction = faction, level = 60, locale = "enus", guild = "", guildAt = 0 }
end
local function kPayload(name, total, faction)
    return s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", faction, EPOCH, "", "enus", 0, EPOCH, 60)
end
local serial = 0
local function wire(path, kind, data)
    serial = serial + 1
    return "eu|bridge-" .. serial .. "|" .. time() .. "|*|" .. path .. "|" .. kind .. "|" .. data
end
local function kOverBnet(name, total, faction)
    net:Receive(wire(name, "K", kPayload(name, total, faction or "Horde")), name, "BNET", 123)
end

-- 1. opposite-faction owner over BNet at hop 0: one LK row to at most 3 same-faction local peers
refreshPeers()
know("Horde Owner", 100, "Horde")
kOverBnet("Horde Owner", 105)
advance(1)
assert(Overlord.Leaderboard.kills["Horde Owner"] == 105, "the bridge itself must accept the owner's K")
local rows = lkRows()
assert(#rows >= 1 and #rows <= 3, "expected 1-3 whispers, got " .. #rows)
local isSame = {}
for _, n in ipairs(samePeers) do isSame[n] = true end
for _, r in ipairs(rows) do
    assert(r.chatType == "WHISPER" and isSame[r.target], "LK sent to a non-peer or non-whisper: " .. tostring(r.target))
    assert(r.name == "Horde Owner" and r.total == 105, "row must carry the accepted total")
end
assert(distinctRows(rows) == 1, "a single row expected")

-- 2. the receiving client (this same code) accepts that row for a known subject, refuses an unknown one
local row = rows[1].msg
Overlord.Leaderboard.kills["Horde Owner"] = 100
s:OnAddonMessage("OverlordF", row, "WHISPER", "Peer Alpha")
assert(Overlord.Leaderboard.kills["Horde Owner"] == 105, "receiver refused the bridge row for a known subject")
Overlord.Leaderboard.kills["Horde Owner"], Overlord.Leaderboard.playerInfo["Horde Owner"] = nil, nil
s:OnAddonMessage("OverlordF", row, "WHISPER", "Peer Alpha")
assert(Overlord.Leaderboard.kills["Horde Owner"] == nil, "receiver created an unknown subject from a bridge row")
know("Horde Owner", 105, "Horde")

-- 3. per-subject gap: a K every 5 s produces one row, the trailing one carries the newest total after 60 s
local base = #whispers
for step = 1, 11 do
    advance(5)
    refreshPeers()
    kOverBnet("Horde Owner", 105 + step * 3)
end
local gapRows = lkRows(base + 1)
assert(#gapRows == 0, "a second row left inside the 60 s gap (" .. #gapRows .. ")")
advance(10)
gapRows = lkRows(base + 1)
assert(#gapRows >= 1 and #gapRows <= 3 and distinctRows(gapRows) == 1, "trailing row missing or duplicated")
assert(gapRows[1].total == 138, "trailing row must carry the newest total, got " .. tostring(gapRows[1].total))

-- 4. implausible jump: neither passed on nor walked through with a small next step
advance(120)
refreshPeers()
base = #whispers
kOverBnet("Horde Owner", 3000)
advance(5)
kOverBnet("Horde Owner", 3003)
advance(130)
-- 1.4.2: the owner's own jump is bounded too (+30 kills + 1/s since the last total).
local bounded = Overlord.Leaderboard.kills["Horde Owner"]
assert(bounded > 138 and bounded < 1000, "owner's implausible jump was not bounded: " .. tostring(bounded))
for _, r in ipairs(lkRows(base + 1)) do assert(r.total < 1000, "an implausible total was re-emitted: " .. r.total) end

-- 5. cap: 8 subjects at once -> at most 6 rows in the first minute, all delivered afterwards
advance(200)
refreshPeers()
for i = 1, 8 do know("Horde Extra" .. string.char(96 + i), 50, "Horde") end
base = #whispers
local t0 = clock
for i = 1, 8 do kOverBnet("Horde Extra" .. string.char(96 + i), 55) end
advance(30)
assert(distinctRows(lkRows(base + 1)) <= 6, "more than 6 rows in a minute: " .. distinctRows(lkRows(base + 1)))
for _ = 1, 6 do advance(30); refreshPeers() end
assert(distinctRows(lkRows(base + 1)) == 8, "delayed rows were lost: " .. distinctRows(lkRows(base + 1)))

-- 6. not re-emitted: same-faction K, channel K, relayed K, unknown subject
advance(200)
refreshPeers()
base = #whispers
know("Ally Owner", 100, "Alliance")
net:Receive(wire("Ally Owner", "K", kPayload("Ally Owner", 105, "Alliance")), "Ally Owner", "BNET", 123)
know("Horde Channel", 100, "Horde")
net:Receive(wire("Horde Channel", "K", kPayload("Horde Channel", 105, "Horde")), "Horde Channel", "CHANNEL")
know("Horde Relayed", 100, "Horde")
net:Receive(wire("Horde Relayed,Bridge Tester", "K", kPayload("Horde Relayed", 105, "Horde")), "Bridge Tester", "BNET", 123)
-- subject unknown to this bridge (first K ever seen: before == 0)
net:Receive(wire("Horde Stranger", "K", kPayload("Horde Stranger", 105, "Horde")), "Horde Stranger", "BNET", 123)
advance(130)
assert(#lkRows(base + 1) == 0, "a row was re-emitted for a K that must stay local: " .. tostring((lkRows(base + 1)[1] or {}).name))
assert(Overlord.Leaderboard.kills["Horde Relayed"] == 100, "a relayed K was credited")
assert(not net.stats.lastError, net.stats.lastError)
print("Forever bridge live score: LK re-emit, 60 s gap, 6 rows/min, jump guard, local-only kinds and receiver acceptance OK")
