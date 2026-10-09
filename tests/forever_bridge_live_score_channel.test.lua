-- 1.3.2: a bridged enemy total goes once on the faction channel, where every
-- same-faction player hears it, instead of three whispers to random peers.
-- The whispers remain the fallback when the channel budget is spent.
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

-- 1. One channel copy, no whisper.
refreshPeers()
know("Horde Owner", 100)
kOverBnet("Horde Owner", 105)
advance(1)
assert(count("CHANNEL") == 1, "expected one channel copy, got " .. count("CHANNEL"))
assert(count("WHISPER") == 0, "whispers were sent although the channel carried the row")
local row = sent[1].msg
assert(row:match("^LK:Horde Owner:105:"), "channel row must carry the accepted total: " .. row)
assert((net.stats.bridgeLKChannel or 0) == 1)

-- 2. Receivers accept it from the channel for a known subject, never create an unknown one.
Overlord.Leaderboard.kills["Horde Owner"] = 100
s:OnAddonMessage("OverlordF", row, "CHANNEL", "Peer Alpha")
assert(Overlord.Leaderboard.kills["Horde Owner"] == 105, "channel row refused for a known subject")
Overlord.Leaderboard.kills["Horde Owner"], Overlord.Leaderboard.playerInfo["Horde Owner"] = nil, nil
s:OnAddonMessage("OverlordF", row, "CHANNEL", "Peer Alpha")
assert(Overlord.Leaderboard.kills["Horde Owner"] == nil, "a channel row created an unknown subject")
know("Horde Owner", 105)

-- 3. Same 60 s gap per subject on the channel: one trailing row with the newest total.
local base = #sent
for step = 1, 11 do
    advance(5)
    refreshPeers()
    kOverBnet("Horde Owner", 105 + step * 3)
end
assert(#sent == base, "a second row left inside the 60 s gap")
advance(10)
assert(#sent == base + 1 and sent[#sent].chatType == "CHANNEL"
    and sent[#sent].msg:match("^LK:Horde Owner:138:"), "trailing channel row missing or wrong")

-- 4. Channel only busy (send budget spent): no whisper, the row waits and then
--    goes on the channel once the budget is back.
advance(120)
refreshPeers()
local takeToken = s.TakeChannelToken
function s:TakeChannelToken() return false end
local base = #sent
know("Horde Other", 50)
kOverBnet("Horde Other", 55)
advance(1)
assert(#sent == base, "a row was whispered while the channel was only busy")
s.TakeChannelToken = takeToken
advance(10)
assert(#sent == base + 1 and sent[#sent].chatType == "CHANNEL"
    and sent[#sent].msg:match("^LK:Horde Other:55:"), "the waiting row did not go on the channel")

-- 5. Our own kill total waiting for its channel slot goes first.
advance(120)
refreshPeers()
s._channelKillPending = "own-total"
base = #sent
know("Horde Third", 30)
kOverBnet("Horde Third", 33)
advance(1)
assert(#sent == base, "a bridge row went before our own pending kill total")
s._channelKillPending = nil
advance(10)
assert(#sent == base + 1 and sent[#sent].chatType == "CHANNEL", "bridge row lost after our own total")

-- 6. Channel unavailable (not joined): the whispers are the fallback.
advance(120)
refreshPeers()
function s:GetChannelId() return nil end
base = #sent
know("Horde Fourth", 40)
kOverBnet("Horde Fourth", 44)
advance(1)
assert(count("CHANNEL", base + 1) == 0 and count("WHISPER", base + 1) >= 1
    and count("WHISPER", base + 1) <= 3, "no whisper fallback without a channel")
print("Forever bridge live score on channel: one channel copy, accepted by receivers, 60 s gap kept, busy channel waits, own total first, whisper fallback without channel OK")
