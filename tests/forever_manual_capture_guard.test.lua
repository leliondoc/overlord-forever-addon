-- /ov start used to start a capture by hand, skipping every guard of the 1 s check
-- (PvP flag, mount, death, an ally's capture already running, the entry snapshot
-- grace): with no PvP flag it opened a wave anyway, and on an ally's running wave it
-- made a second capturer at the ally's elapsed time. It now runs that same check.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
SlashCmdList = {}
Overlord.IsInitialized, Overlord.InstanceSuspended = true, false
IsInInstance = function() return false end
assert(loadfile("Commands.lua"))()

local flagged = false
UnitIsPVP = function() return flagged end
UnitIsPVPFreeForAll = function() return false end
IsMounted = function() return false end
IsFlying = function() return false end
IsStealthed = function() return false end
UnitIsDead = function() return false end
UnitIsGhost = function() return false end
UnitInVehicle = function() return false end
UnitOnTaxi = function() return false end
UnitExists = function() return true end
local clock = 2000
GetTime = function() clock = clock + 1; return clock end

local zone = { id = "manual_point", name = "Manual Point", status = "available", center = { 50, 50 } }
Overlord.Zones.GetZone = function(_, id) if id == zone.id then return zone end end
Overlord.Zones.GetCurrentPlayerZone = function() return zone end
Overlord.Zones.IsZoneAvailable = function() return true end
local ZC = Overlord.ZoneControl
local checks, starts = 0, 0
local realCheck = ZC.CheckPlayerPosition
ZC.CheckPlayerPosition = function(self, ...) checks = checks + 1; return realCheck(self, ...) end
ZC.StartHoldTimer = function(_, z) starts = starts + 1; z.isHolding = true end
local hints = {}
Overlord.PrintNotification = function(_, msg) hints[#hints + 1] = msg end

-- No PvP flag: nothing starts, and the player is told why (the 1 s check's hint).
SlashCmdList.OVERLORD("start " .. zone.id)
assert(checks == 1, "/ov start did not run the usual capture check")
assert(starts == 0 and not zone.isHolding and zone.status == "available",
    "/ov start opened a capture without the PvP flag")
local told = false
for _, msg in ipairs(hints) do if msg:find("Manual Point", 1, true) then told = true end end
assert(told, "the player was not told why the capture did not start")

-- An ally's capture is running on the point: no second capturer at its elapsed time.
flagged = true
zone.status, zone.owner, zone.holdTimeElapsed = "in_progress", Overlord.PlayerFaction, 100
zone.zsOfficialCapturerName = "Ally Name"
zone._remoteCaptureLease = { directValidated = true, lastDirectSeen = GetTime(), originKey = "ally name",
    waveId = "allywave", owner = Overlord.PlayerFaction }
SlashCmdList.OVERLORD("start " .. zone.id)
assert(checks == 2, "/ov start did not run the usual capture check on an ally's wave")
assert(starts == 0 and not zone.isHolding and zone.holdTimeElapsed == 100,
    "/ov start took over an ally's running capture")
print("Manual capture start: /ov start runs the usual check (no PvP flag, ally's wave) OK")
