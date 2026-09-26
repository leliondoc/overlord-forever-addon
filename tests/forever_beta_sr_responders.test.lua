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
Overlord.BetaNetwork = {
    IsDispatching = function() return true end,
    IsTargetedDispatch = function() return targeted end,
    GetPeers = function() return peers end,
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

targeted, roll = false, 0.08
sync:OnSyncRequest("Horde Joiner", payload, "BETA")
assert(responded(), "Selected peer did not answer the broadcast request")
release()

math.random = realRandom
print("Forever beta SR responders: targeted requests answered, broadcast bounded to ~3 of 30 peers OK")
