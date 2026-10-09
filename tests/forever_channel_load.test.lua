-- Realm-channel and relay load (Blizzard allows ~1 message/s per player on the channel).
-- Run from the addon root under Lua 5.1 (copy to tests/forever_channel_load.test.lua).
--  (1) SH presence leaves the realm channel once, not once directly and once as the relay's
--      channel copy; alerts (OP in progress) and terminal events keep both; a refused direct
--      send stays a retry; another player's identical payload never stands in for ours.
--  (2) SH presence is forwarded by a hop at most once per 90 s per origin (like NH).
--  (3) Another player's NH is never relayed (1.2.4, about half of the relay budget);
--      the origin's own NH keeps the full fan-out (channel, bridges, friends).
assert(loadfile("tests/forever_beta_integration.test.lua"))()
-- The integration fixture stubs net.Broadcast and IsLargeEvent: start from the real relay.
assert(loadfile("SyncRelay.lua"))()

local sync, net = Overlord.Sync, Overlord.Relay
sync.IsLargeEvent = function() return false end
local failures = {}
local function check(condition, message)
    if not condition then failures[#failures + 1] = message end
end
local now, pending = 1000, {}
local function pump(seconds)
    local stop = now + (seconds or 0)
    while true do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local first = pending[1]
        if not first or first.at > stop then break end
        table.remove(pending, 1)
        now = first.at
        first.run()
    end
    now = stop
end
GetTime = function() return now end
time = function() return 1790016000 + math.floor(now) end
GetServerTime = time
C_Timer = {
    After = function(delay, callback) pending[#pending + 1] = { at = now + delay, run = callback } end,
    NewTicker = function() return {} end,
}
IsInInstance = function() return false end
IsInGroup = function() return false end
IsInRaid = function() return false end
Overlord.InstanceSuspended = false
Overlord.PlayerFaction = "Alliance"

-- Blizzard side: every channel message is recorded; refuse while `refuseNext` > 0.
local channel, refuseNext = {}, 0
C_ChatInfo = {
    SendAddonMessage = function(_, message, chatType)
        if chatType ~= "CHANNEL" then return 0 end
        if refuseNext > 0 then refuseNext = refuseNext - 1; return 8 end
        channel[#channel + 1] = { at = now, message = message }
        return 0
    end,
}
-- Battle.net side: one opposite-faction bridge and two same-faction friends.
local bnetFriends = { [1] = { "Horde", "Bridge Friend" }, [2] = { "Alliance", "Ally One" },
    [3] = { "Alliance", "Ally Two" } }
sync.GetChannelId = function() return 7 end
sync.GetPlayerFullName = function() return "Local Tester" end
sync.GetBetaBNetTargets = function() return { 1, 2, 3 } end
sync.GetBetaBNetTargetInfo = function(_, id) return bnetFriends[id][1], bnetFriends[id][2] end
local bnetSent = {}
sync.SendToBNet = function(_, id, _, data)
    bnetSent[#bnetSent + 1] = { id = id, data = data }
    return true
end
local function reset()
    channel, bnetSent = {}, {}
    refuseNext = 0
    pump(300) -- drain timers
    sync._channelTokens, sync._channelTokensAt = nil, nil -- full local channel budget
    channel, bnetSent = {}, {}
end
local function direct(kind)
    local n = 0
    for _, row in ipairs(channel) do
        if row.message:match("^" .. kind .. ":") then n = n + 1 end
    end
    return n
end
local function relayCopies(kind)
    -- a relay copy is a BF fragment whose first chunk carries "...|<kind>|payload"
    local n = 0
    for _, row in ipairs(channel) do
        if row.message:match("^BF:") and row.message:find("|" .. kind .. "|", 1, true) then n = n + 1 end
    end
    return n
end
local function relay(kind, payload)
    assert(net:Broadcast(kind, payload) == 1, kind .. " was not admitted by the relay")
    pump(5)
end
local function bnetCopies(kind)
    local byId, n = {}, 0
    for _, row in ipairs(bnetSent) do
        if row.data:find("|" .. kind .. "|", 1, true) then byId[row.id] = true; n = n + 1 end
    end
    return n, byId
end

-- (1) one message on the channel for a state packet
reset()
assert(sync:SendToChannel("SH", "4242") == true)
relay("SH", "4242")
check(direct("SH") == 1, "the direct SH was not sent")
check(relayCopies("SH") == 0,
    "SH went out a second time as the relay's channel copy (" .. relayCopies("SH") .. ")")
-- ... alerts keep both copies: hearers of the relay copy forward it to their own bridges
reset()
local opPayload = "v1:badlands:in_progress:0:Keep Guild:A:1790017500:0:1790017500:600:global:0"
assert(sync:SendToChannel("OP", opPayload, true) == true)
relay("OP", opPayload)
check(direct("OP") == 1 and relayCopies("OP") >= 1, "an in-progress OP alert lost one of its channel copies")

-- ... a different origin's identical SH payload is not "the same packet"
reset()
sync:OnAddonMessage("OverlordF", "SH:4244", "CHANNEL", "Other Tester")
relay("SH", "4244")
check(relayCopies("SH") >= 1, "another player's identical SH suppressed our own relay copy")

-- ... terminal events keep the direct copy AND the relay copy
reset()
local cPayload = "elwynn_goldshire:Local Tester|WARRIOR:Alliance:1790016100:w1_1:Player-1-1:120"
assert(sync:SendToChannel("C", cPayload, true) == true)
relay("C", cPayload)
check(direct("C") == 1 and relayCopies("C") >= 1, "a terminal C lost one of its channel copies")

-- ... and a direct send refused by Blizzard is retried by the relay copy
reset()
refuseNext = 1
assert(sync:SendToChannel("SH", "4243") == false)
relay("SH", "4243")
check(relayCopies("SH") >= 1, "a refused direct SH was not retried by the relay copy")

-- (2) SH forward filter: an origin's SH is forwarded at most once per 90 s by a hop
local function distinctIds(kind)
    local ids, n = {}, 0
    for _, row in ipairs(bnetSent) do
        if row.data:find("|" .. kind .. "|", 1, true) then
            local id = row.data:match("^[^|]*|([^|]*)|")
            if not ids[id] then ids[id] = true; n = n + 1 end
        end
    end
    return n
end
local function shFrom(serial)
    local wire = table.concat({ "global", "sh" .. serial, time(), "*", "Origin Tester,Bridge Tester", "SH", "4242" }, "|")
    net:Receive(wire, "Bridge Tester", "BNET", 5)
    pump(5)
end
reset()
shFrom(1); pump(55)     -- t=0
shFrom(2); pump(55)     -- t=60: origin heartbeat inside the 90 s window
shFrom(3); pump(55)     -- t=120
check(distinctIds("SH") == 2,
    "SH from one origin was forwarded " .. distinctIds("SH") .. " times in 120 s (expected 2: at 0 and 120)")

-- (3) another player's NH is never relayed (1.2.4): not to friends, not to the channel,
-- whether it arrived first-hand from a Battle.net friend or already relayed once.
local function nhFrom(path, serial)
    local wire = table.concat({ "global", "nh" .. serial, time(), "*", path, "NH", "1.1.10~lp6" }, "|")
    net:Receive(wire, "Gateway Tester", "BNET", 5)
    pump(5)
end
reset()
nhFrom("Far Origin,Gateway Tester", 1)
check(bnetCopies("NH") == 0, "a relayed NH was forwarded to Battle.net friends")
check(relayCopies("NH") == 0, "a relayed NH was put on the channel")
for i = 2, 3 do
    channel, bnetSent = {}, {}
    pump(95)
    nhFrom("Gateway Tester", i * 10)
    check(bnetCopies("NH") == 0 and relayCopies("NH") == 0,
        "a friend's first-hand NH was relayed onward")
end
-- the origin's own heartbeat keeps the full fan-out: channel + bridge + two friends
reset()
relay("NH", "1.1.10~lp6")
local ownNh, ownIds = bnetCopies("NH")
check(relayCopies("NH") == 1, "the origin's own NH lost its channel copy")
check(ownIds[1] and ownNh >= 3, "the origin's own NH lost part of its friend fan-out (" .. ownNh .. " copies)")

assert(#failures == 0, "channel/relay load regressions:" .. string.char(10) .. "  - "
    .. table.concat(failures, string.char(10) .. "  - "))
print("Forever channel load: SH sent once on the channel, SH forward filter, others' NH never relayed, own NH full fan-out, alerts keep both copies OK")
