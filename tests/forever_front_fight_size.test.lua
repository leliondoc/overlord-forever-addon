-- Fight size in the dock's recent activity: new kills per front over 5 min, fed by the
-- K deltas the guild alert already measures (no packet), bracketed 5+/10+/20+...
Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }) }
C_Map = { GetMapInfo = function() return nil end }
wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local serverNow = 1789530000
GetServerTime = function() return serverNow end
GetTime = function() return serverNow end
time = os.time
OverlordDB = {}
assert(loadfile("Fronts.lua"))()
assert(loadfile("FrontActivity.lua"))()
local FA = Overlord.FrontActivity

local function row(frontId)
    for _, r in ipairs(FA:GetActivityRows()) do if r.frontId == frontId then return r end end
end

-- A kill zone and a front marker both resolve; an off-front map ref does not count.
FA:Record("ashenvale", nil, serverNow)
assert(FA:RecordKills("ash_mystral_lake", 3))
assert(FA:RecordKills("@ashenvale", 4))
assert(not FA:RecordKills("#1440", 9), "an off-front map ref was counted")
assert(row("ashenvale").kills == 7, "kills per front: " .. tostring(row("ashenvale").kills))
-- A suspicious jump is capped like the guild alert's.
FA:RecordKills("ash_astranaar", 500)
assert(FA:GetKillCount("ashenvale") == 37, "a huge delta was not capped")

-- Kills older than the 5 min window drop out.
serverNow = serverNow + 200
FA:Record("ashenvale", nil, serverNow)
FA:RecordKills("ash_astranaar", 2)
serverNow = serverNow + 120
assert(FA:GetKillCount("ashenvale") == 2, "old kills survived the window: " .. FA:GetKillCount("ashenvale"))

-- Nothing in an instance; weekly reset empties the counts.
Overlord.InstanceSuspended = true
assert(not FA:RecordKills("ash_astranaar", 5), "kills counted inside an instance")
Overlord.InstanceSuspended = false
FA:ResetForCampaign()
assert(FA:GetKillCount("ashenvale") == 0, "fight size survived the weekly reset")
print("Front fight size: per-front kills, cap, 5 min window, instance cutoff, reset OK")
