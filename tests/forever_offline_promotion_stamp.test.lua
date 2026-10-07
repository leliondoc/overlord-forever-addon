-- 1.7.0 audit: an enemy capture already complete at logout and promoted at login is
-- dated from the logout (in server time), not from the login. A login stamp read as a
-- fresh capture in Recent activity on this client and went out as such in its ZA.
local localNow, serverNow = 1790020000, 1790020300 -- local clock 5 min behind the server
function time() return localNow end
function GetServerTime() return serverNow end
function GetTime() return 100 end
wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }),
    ServerNow = function() return serverNow end, PlayerFaction = "Alliance" }
OverlordDB = { lastSessionTimestamp = localNow - 170 } -- logged out 170 s ago (promotion window: hold + 60 s)
assert(loadfile("Zones.lua"))()
local Z = Overlord.Zones

local zone = { id = "test_zone", owner = "Horde", status = "in_progress",
    holdTimeElapsed = 125, holdTimeRequired = 120, updatedAt = serverNow - 170 }
Z.GetCurrentPlayerZone = function() return nil end
Z:RestoreInProgressAfterOffline(zone, {}, "Alliance")
assert(zone.status == "captured" and zone.owner == "Horde", "the complete enemy hold was not promoted")
assert(zone.capturedTime == serverNow - 170,
    "promotion stamp should be the logout in server time, got " .. tostring(zone.capturedTime)
    .. " (expected " .. (serverNow - 170) .. ")")
assert(zone.capturedTime < serverNow - 120, "the login time was used")

-- A quick /reload (logout 10 s ago) keeps a recent stamp: the capture is recent.
OverlordDB.lastSessionTimestamp = localNow - 10
local quick = { id = "quick_zone", owner = "Horde", status = "in_progress",
    holdTimeElapsed = 121, holdTimeRequired = 120, updatedAt = serverNow - 10 }
Z:RestoreInProgressAfterOffline(quick, {}, "Alliance")
assert(quick.status == "captured" and quick.capturedTime == serverNow - 10, tostring(quick.capturedTime))
print("Offline promotion stamp: dated from the logout in server time, not the login OK")
