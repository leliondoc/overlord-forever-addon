-- Bridge election test (fixture shared with the 1.3.2 channel bridge test).
math.randomseed(2)
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)
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
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
net.BridgeChannelHold = { 0, 0 } -- exact timings below
Overlord.PlayerFaction = "Alliance"
Overlord.RelayEnabled = true
function s:GetChannelId() return 5 end

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

local sent = {}
function s:SendAddonChecked(msg, chatType, target)
    if msg:sub(1, 3) == "LK:" then sent[#sent + 1] = { msg = msg, chatType = chatType, target = target } end
    return true
end
local function count(chatType, from)
    local n = 0
    for i = from or 1, #sent do if sent[i].chatType == chatType then n = n + 1 end end
    return n
end

local EPOCH = 1789527600
local peers = { "Peer Alpha", "Peer Bravo", "Peer Charlie", "Peer Delta" }
local function refreshPeers()
    for _, name in ipairs(peers) do
        net.peers[name:lower()] = { name = name, at = clock, via = name, transport = "CHANNEL", hops = 1 }
    end
end
local function know(name, total)
    Overlord.Leaderboard.kills[name] = total
    Overlord.Leaderboard.playerInfo[name] = { class = "WARRIOR", faction = "Horde", level = 60, locale = "enus", guild = "", guildAt = 0 }
end
local serial = 0
local function kOverBnet(name, total)
    serial = serial + 1
    local payload = s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", "Horde", EPOCH, "", "enus", 0, EPOCH, 60)
    net:Receive("eu|chan-" .. serial .. "|" .. time() .. "|*|" .. name .. "|K|" .. payload, name, "BNET", 123)
end


-- ==== Bridge election (2026-10-02) ====
-- Few bridges: share stays 1 and every row is posted after the usual 2-15 s hold.
-- Many bridges (many channel copies of each enemy total): the client keeps only a
-- share of subjects, chosen by a hash of (client, subject); the others wait 20-60 s
-- as a fallback and are cancelled by any copy heard meanwhile. No total is lost.
net.BridgeChannelHold = { 2, 15 }
function s:GetPlayerFullName() return "Local Tester" end
local function copies(name, total, n)
    for i = 1, n do net:NoteChannelBridgeRow(name, total, "Horde", "Bridge Number" .. i) end
end

-- 1. Small scale (2-3 copies per total): share 1, nothing held back.
for t = 1, 20 do copies("Small Horde", 100 + t, 3) end
assert(net:GetBridgeShare() == 1, "share dropped with only 3 copies per total")
local deferredBefore = net.stats.bridgeLKDeferred or 0
know("Quiet Horde", 10)
kOverBnet("Quiet Horde", 11)
assert((net.stats.bridgeLKDeferred or 0) == deferredBefore, "a row was held back at small scale")
local base = #sent
advance(16)
assert(count("CHANNEL", base + 1) == 1, "small-scale row not posted within the usual hold")

-- 2. Crowd of 40 bridges: copies follow the share every client uses (40 x share),
--    and the share settles near 3/40 with about 3 copies per total, no collapse.
local lastCopies
for t = 1, 25 do
    lastCopies = math.max(1, math.floor(40 * net:GetBridgeShare() + 0.5))
    copies("Crowd Horde", 200 + t, lastCopies)
end
local share = net:GetBridgeShare()
assert(share > 0.04 and share < 0.15, "share did not settle near 3/40: " .. share)
assert(lastCopies >= 2 and lastCopies <= 5, "copies per total did not settle near 3: " .. lastCopies)

-- 3. With that share, about share x subjects are elected; the rest are deferred.
advance(120)
refreshPeers()
local subjects, deferredStart = 200, net.stats.bridgeLKDeferred or 0
for i = 1, subjects do
    local name = "Enemy Number" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26))
    know(name, 50)
    kOverBnet(name, 51)
end
local deferred = (net.stats.bridgeLKDeferred or 0) - deferredStart
local elected = subjects - deferred
assert(elected >= 1 and elected <= subjects * share * 2.5 + 3,
    "elected " .. elected .. " of " .. subjects .. " with share " .. share)

-- 4. Fallback: a deferred row with no copy heard still goes out (late, not lost);
--    a deferred row whose total is heard on the channel is cancelled.
--    (Step 3's rows expire first: they share the 6 rows/min client budget.)
advance(400)
refreshPeers()
local lone, heard
for i = 1, 400 do
    local name = "Fallback Horde" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26) % 26)
    local before = net.stats.bridgeLKDeferred or 0
    know(name, 70)
    kOverBnet(name, 71)
    if (net.stats.bridgeLKDeferred or 0) > before then
        if not lone then lone = name elseif not heard then heard = name break end
    end
end
assert(lone and heard, "fixture: no deferred rows found")
net:NoteChannelBridgeRow(heard, 71, "Horde")       -- another bridge posted it
base = #sent
advance(70)
local loneSent, heardSent = false, false
for i = base + 1, #sent do
    if sent[i].msg:match("^LK:" .. lone .. ":71:") then loneSent = true end
    if sent[i].msg:match("^LK:" .. heard .. ":71:") then heardSent = true end
end
assert(loneSent, "a deferred total nobody posted was lost")
assert(not heardSent, "a deferred total already on the channel was posted again")

-- 5. Recovery: when copies fall back to one per total, the share returns to 1.
for t = 1, 12 do copies("Crowd Horde", 300 + t, 1) end
assert(net:GetBridgeShare() == 1, "share did not recover: " .. net:GetBridgeShare())
print("Bridge election: unchanged at small scale, adapts to crowds, fallback never loses a total, recovers")

-- 6. One sender repeating the same row counts once: it cannot drag the share down.
for t = 1, 12 do
    for _ = 1, 30 do net:NoteChannelBridgeRow("Spam Horde", 500 + t, "Horde", "Same Spammer") end
end
assert(net:GetBridgeShare() == 1, "a single sender lowered the share: " .. net:GetBridgeShare())
print("Bridge election: one copy per sender")

-- 7. Weekly reset: totals restart low. A record older than 2 min no longer freezes
--    the estimate (a lower total heard within 2 min is still an old copy).
for t = 1, 25 do copies("Reset Horde", 9000 + t, math.max(1, math.floor(40 * net:GetBridgeShare() + 0.5))) end
local frozen = net:GetBridgeShare()
assert(frozen < 1, "fixture: share did not drop before the reset")
advance(200)
for t = 1, 12 do copies("Reset Horde", 10 + t, 1) end
assert(net:GetBridgeShare() == 1, "estimate stayed frozen after the weekly reset: " .. net:GetBridgeShare())
print("Bridge election: recovers after the weekly reset")
