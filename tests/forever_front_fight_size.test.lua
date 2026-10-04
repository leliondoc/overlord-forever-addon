-- Fight size in the dock's recent activity: new kills per front over 5 min, fed by the
-- K deltas the guild alert already measures (no packet), bracketed 5+/10+/20+...
Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }) }
Enum = { UIMapType = { Zone = 3, Dungeon = 4 } }
local maps = {
    [1451] = { name = "Silithus", mapType = 3 },
    [1440] = { name = "Ashenvale", mapType = 3 },
    [1581] = { name = "The Deadmines", mapType = 4 },
    [1411] = { name = "Durotar", mapType = 3 },
}
for id = 2000, 2024 do maps[id] = { name = "Zone " .. id, mapType = 3 } end
C_Map = { GetMapInfo = function(id) return maps[id] end }
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
assert(FA:RecordKills("#1440", 2), "the front's own map ref was not counted")
assert(row("ashenvale").kills == 9, "kills per front: " .. tostring(row("ashenvale").kills))
-- A suspicious jump is capped like the guild alert's.
FA:RecordKills("ash_astranaar", 500)
assert(FA:GetKillCount("ashenvale") == 39, "a huge delta was not capped")

-- Off-front fights: the world zone is named from the map already in the K; a dungeon
-- or an invented map id is ignored; small skirmishes (under 5 kills) are not listed.
assert(not FA:RecordKills("#1581", 3), "an instance map was counted")
assert(not FA:RecordKills("#424242", 3), "an invented map id was counted")
FA:RecordKills("#1451", 3)
assert(not row("#1451"), "a 3-kill skirmish was listed")
FA:RecordKills("#1451", 4)
local silithus = row("#1451")
assert(silithus and silithus.label == "Silithus" and silithus.kills == 7 and silithus.active,
    "the off-front fight in Silithus is missing")
-- A front's own map sent as "#uiMapID" lights that front up as well.
FA:RecordKills("#1411", 5)
assert(row("durotar") and row("durotar").active and row("durotar").kills == 5, "front map ref did not light the front")
-- A full list of tracked zones makes room for a new fight (oldest out), never refuses it.
for id = 2000, 2023 do serverNow = serverNow + 1; FA:RecordKills("#" .. id, 1) end
serverNow = serverNow + 1
assert(FA:RecordKills("#2024", 6), "a new off-front fight was refused when the list was full")
assert(FA:GetKillCount("#2024") == 6, "the new fight was not counted")

-- Kills older than the 5 min window drop out.
serverNow = serverNow + 200
FA:Record("ashenvale", nil, serverNow)
FA:RecordKills("ash_astranaar", 2)
serverNow = serverNow + 120
assert(FA:GetKillCount("ashenvale") == 2, "old kills survived the window: " .. FA:GetKillCount("ashenvale"))
assert(not row("#1451"), "an old off-front fight stayed listed")

-- Nothing in an instance; weekly reset empties the counts.
Overlord.InstanceSuspended = true
assert(not FA:RecordKills("ash_astranaar", 5), "kills counted inside an instance")
Overlord.InstanceSuspended = false
FA:ResetForCampaign()
assert(FA:GetKillCount("ashenvale") == 0, "fight size survived the weekly reset")
assert(FA:GetKillCount("#1451") == 0, "an off-front fight survived the weekly reset")
print("Front fight size: per-front kills, off-front zones, cap, 5 min window, instance cutoff, reset OK")
