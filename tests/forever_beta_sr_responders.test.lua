-- A sync request broadcast through the beta relay reaches every peer. At the old
-- 95 % channel rate each peer answered with a full ZA snapshot; across a Battle.net
-- bridge those answers saturated the bridge queue and none arrived complete.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local sync = Overlord.Sync
local clock = 1000
GetTime = function() return clock end
local timers = {}
C_Timer.After = function(delay, callback) timers[#timers + 1] = { delay = delay, run = callback } end
local targeted = false
local peers = {}
for i = 1, 30 do peers[i] = "Peer " .. string.char(64 + i % 26 + 1) .. "x" end
Overlord.Relay = {
    IsDispatching = function() return true end,
    IsTargetedDispatch = function() return targeted end,
    GetPeers = function() return peers end,
    GetDirectPeers = function() return peers end,
    context = { hops = 0 },
}
Overlord.WaitingForSync = false
Overlord.IsCaptureSyncPending = function() return false end
Overlord.InActiveFront = true
local roll = 0.5
local realRandom = math.random
math.random = function(...) if select("#", ...) == 0 then return roll end return realRandom(...) end

local function responded()
    for _, t in ipairs(timers) do if t.delay == 120 then return true end end
    return false
end
local function release()
    -- The 120 s safety callback clears the in-flight response slot.
    for _, t in ipairs(timers) do if t.delay == 120 then t.run() end end
    timers = {}
    clock = clock + 200
end
local payload = "H:1.0.25:0:::T"

targeted, roll = true, 0.99
sync:OnSyncRequest("Horde Joiner", payload, "BETA")
assert(responded(), "Targeted beta request lost its guaranteed answer")
release()

targeted, roll = false, 0.5
sync:OnSyncRequest("Horde Joiner", payload, "BETA")
assert(not responded(), "Broadcast request still answered by most of 30 peers")
release()

targeted, roll = false, 0.05
sync:OnSyncRequest("Horde Joiner", payload, "BETA")
assert(responded(), "Selected peer did not answer the broadcast request")
release()

-- A small channel never gets more answers than before (about two of 30).
targeted, roll = false, 0.1
sync:OnSyncRequest("Horde Joiner", payload, "BETA")
assert(not responded(), "A small channel now answers more broadcast requests than before")
release()

-- Launch-size crowd: about eight answers in all, not 5 % of everyone (the old
-- floor gave ~250 full maps to one player at 5,000 neighbours).
local crowd = {}
for i = 1, 5000 do crowd[i] = "Crowd " .. i end
Overlord.Relay.GetDirectPeers = function() return crowd end
targeted, roll = false, 0.01
sync:OnSyncRequest("Horde Joiner", payload, "BETA")
assert(not responded(), "A broadcast request was answered by 5 % of a 5,000-player crowd")
release()
targeted, roll = false, 0.001
sync:OnSyncRequest("Horde Joiner", payload, "BETA")
assert(responded(), "A crowd peer never answers a broadcast request")
release()
Overlord.Relay.GetDirectPeers = function() return peers end

-- Point to point (1.2.4): a request that crossed a relay is never answered,
-- targeted or not, since the reply would have to cross the same relays back.
Overlord.Relay.context = { hops = 2 }
targeted, roll = true, 0.01
sync:OnSyncRequest("Far Joiner", payload, "BETA")
assert(not responded(), "A relayed request was answered")
release()
Overlord.Relay.context = { hops = 0 }

-- A raw request heard on the channel is bounded the same way (it used to get an
-- answer from 95 % of listeners, or 18 % plus short answers in a large event).
targeted = false
for _, case in ipairs({ { 0.5, false }, { 0.1, false }, { 0.05, true } }) do
    roll = case[1]
    sync:OnSyncRequest("Channel Joiner", payload, "CHANNEL")
    assert(responded() == case[2], "raw channel request with roll " .. roll .. ": answered " .. tostring(responded()))
    release()
end
local realLarge = sync.IsLargeEvent
sync.IsLargeEvent = function() return true end
roll = 0.5
sync:OnSyncRequest("Channel Joiner", payload, "CHANNEL")
assert(not responded(), "a large event still answered most raw channel requests")
release()
sync.IsLargeEvent = realLarge
-- Relay off (no direct neighbour known): the old 95 % rule applies.
Overlord.Relay.GetDirectPeers = function() return {} end
roll = 0.5
sync:OnSyncRequest("Channel Joiner", payload, "CHANNEL")
assert(responded(), "a raw channel request went unanswered with no neighbour known")
release()
Overlord.Relay.GetDirectPeers = function() return peers end
-- A group request is not bounded.
roll = 0.5
sync:OnSyncRequest("Raid Joiner", payload, "RAID")
assert(responded(), "a group request lost its answer")
release()

math.random = realRandom
print("Forever beta SR responders: targeted requests answered, broadcast and raw channel requests bounded to ~2 of 30 direct peers, relayed requests ignored OK")
