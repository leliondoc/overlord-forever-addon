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
local function toldAbout(text)
    local n = 0
    for _, msg in ipairs(hints) do if msg:find(text, 1, true) then n = n + 1 end end
    return n
end
assert(toldAbout("Manual Point") == 1, "the player was not told (once) why the capture did not start")
-- Again within the check's one-minute hint cooldown: the command still says why.
SlashCmdList.OVERLORD("start " .. zone.id)
assert(toldAbout("/pvp") == 2, "a second /ov start within the hint cooldown said nothing")

-- An ally's capture is running on the point: no second capturer at its elapsed time.
flagged = true
zone.status, zone.owner, zone.holdTimeElapsed = "in_progress", Overlord.PlayerFaction, 100
zone.zsOfficialCapturerName = "Ally Name"
zone._remoteCaptureLease = { directValidated = true, lastDirectSeen = GetTime(), originKey = "ally name",
    waveId = "allywave", owner = Overlord.PlayerFaction }
SlashCmdList.OVERLORD("start " .. zone.id)
assert(checks == 3, "/ov start did not run the usual capture check on an ally's wave")
assert(toldAbout("already in progress") == 1, "/ov start on an ally's wave said nothing")
assert(starts == 0 and not zone.isHolding and zone.holdTimeElapsed == 100,
    "/ov start took over an ally's running capture")
-- Dead (or a ghost): no misleading "Dismount." line; stealthed: told to leave stealth.
zone.status, zone.owner, zone.zsOfficialCapturerName, zone._remoteCaptureLease = "available", nil, nil, nil
local dead, stealthed = true, false
UnitIsDead = function() return dead end
IsStealthed = function() return stealthed end
local before = #hints
SlashCmdList.OVERLORD("start " .. zone.id)
assert(#hints == before and toldAbout("Dismount") == 0, "a dead player was told to dismount")
dead, stealthed = false, true
SlashCmdList.OVERLORD("start " .. zone.id)
assert(toldAbout("stealth") == 1 and toldAbout("Dismount") == 0, "a stealthed player was not told to leave stealth")
-- Initial sync still pending: one line, not the gate's line and ours.
stealthed = false
local realPending = Overlord.IsCaptureSyncPending
Overlord.IsCaptureSyncPending = function() return true end
local syncBefore = toldAbout("sync")
SlashCmdList.OVERLORD("start " .. zone.id)
assert(toldAbout("sync") == syncBefore + 1, "the initial-sync line was not printed exactly once: "
    .. (toldAbout("sync") - syncBefore))
Overlord.IsCaptureSyncPending = realPending
-- Just stepped onto another point: its few seconds' entry grace is not the initial
-- sync; nothing misleading is printed and the capture starts right after.
local entry = { id = "entry_point", name = "Entry Point", status = "available", center = { 60, 60 } }
local realRequest = Overlord.Sync.SendSyncRequest
Overlord.Sync.SendSyncRequest = function() return true end -- the entry snapshot request
local realGetZone = Overlord.Zones.GetZone
Overlord.Zones.GetZone = function(_, id) if id == entry.id then return entry end return realGetZone(_, id) end
Overlord.Zones.GetCurrentPlayerZone = function() return entry end
flagged = true
local syncLines, startsBefore = toldAbout("sync"), starts
SlashCmdList.OVERLORD("start " .. entry.id)
assert(starts == startsBefore and toldAbout("sync") == syncLines,
    "the entry grace was announced as the initial sync")
clock = clock + 10
SlashCmdList.OVERLORD("start " .. entry.id)
assert(starts == startsBefore + 1 and entry.isHolding, "the capture did not start after the entry grace")
Overlord.Sync.SendSyncRequest = realRequest
print("Manual capture start: /ov start runs the usual check (no PvP flag, ally's wave, dead, stealth, sync, entry grace) OK")
