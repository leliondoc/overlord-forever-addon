-- Large event: the wide (relay + Battle.net) ZS copy of an in_progress capture is sent every 15 s
-- during the first 45 s of a wave, then every 60 s. A normal event keeps 15 s throughout.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local s = Overlord.Sync
assert(loadfile("SyncAux.lua"))()
local clock, large = 1000, true
function GetTime() return clock end
Overlord.InActiveFront, Overlord.PlayerFaction = true, "Horde"
Overlord.WaitingForSync = nil
Overlord.IsCaptureSyncPending = function() return false end
Overlord.LocalFrontAwaitingNetworkSnapshot = function() return false end
function s:IsLargeEvent() return large end
function s:GetPlayerFullName() return "Capper Tester" end
local wide = {}
function s:SendToGroup() end
function s:SendToChannel() end
function s:BroadcastToRelay(kind) if kind == "ZS" then wide[#wide + 1] = clock end end
function s:SendToBNetFriends() end
local zone = { id = "zone_a", status = "in_progress", owner = "Horde", isHolding = true,
    holdAuthorityLocal = true, holdTimeElapsed = 0, holdTimeRequired = 120, updatedAt = time() }
local function run(seconds)
    wide = {}
    zone.holdTimeElapsed = 0
    for t = 0, seconds, 5 do
        clock = clock + (t == 0 and 200 or 5)          -- fresh zone state each run (200 s idle first)
        zone.holdTimeElapsed = t
        zone.updatedAt = time()
        s:BroadcastZoneState(zone)
    end
    return wide
end
local sent = run(120)
local offsets = {}
for i, at in ipairs(sent) do offsets[i] = at - sent[1] end
local retries, later = 0, 0
for _, o in ipairs(offsets) do
    if o > 5 and o <= 50 then retries = retries + 1 end     -- 0 and 5 s are the capture start itself
    if o > 50 and o < 90 then later = later + 1 end
end
assert(#sent >= 1, "no wide copy at all")
assert(retries >= 2, "large event: expected retries every 15 s during the first 45 s, got " .. table.concat(offsets, ","))
assert(later == 0, "after 45 s the large-event cadence must be 60 s, got " .. table.concat(offsets, ","))
large = false
sent = run(60)
assert(#sent >= 5, "a normal event must keep the 15 s cadence, got " .. #sent .. " copies in 60 s")
print("Forever siege start cadence: 15 s for the first 45 s of a wave in a large event, 60 s afterwards")
