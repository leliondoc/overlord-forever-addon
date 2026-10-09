-- 1.4.1 (player request): only PvP-flagged players take or hold objectives. An
-- unflagged player cannot be attacked (Normal ruleset, or own territory on a PvP
-- ruleset) and must not capture for free. The rule lives in the shared
-- "cannot capture right now" check (mount, flight, stealth...), used by front
-- zones, outposts and fortresses alike.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local ZC = Overlord.ZoneControl
assert(ZC and ZC.PlayerLacksPvpFlag, "PvP flag rule missing")

local flagged, ffa = false, false
UnitIsPVP = function(unit) assert(unit == "player"); return flagged end
UnitIsPVPFreeForAll = function() return ffa end
IsMounted = function() return false end
IsFlying = function() return false end
IsStealthed = function() return false end
UnitIsDead = function() return false end
UnitIsGhost = function() return false end
UnitInVehicle = UnitInVehicle or function() return false end
UnitOnTaxi = UnitOnTaxi or function() return false end
local clock = 1000
GetTime = function() clock = clock + 1; return clock end -- defeat the 0.05 s cache

assert(ZC:PlayerLacksPvpFlag(), "Unflagged player allowed to capture")
assert(ZC:IsPlayerInNonCaptureStateForSync(), "Unflagged player counted as a capturer")
flagged = true
assert(not ZC:PlayerLacksPvpFlag(),
    "Flagged player blocked from capturing")
-- Mines generate gold without the flag (audit 1.4.1): only the body rules apply.
flagged = false
UnitExists = UnitExists or function() return true end
assert(ZC.IsPlayerInNonMiningStateForSync, "Mining state check missing")
local okMine, minesBlocked = pcall(ZC.IsPlayerInNonMiningStateForSync, ZC)
assert(okMine and minesBlocked == false, "Mining blocked by a missing PvP flag")
flagged, ffa = false, true
assert(not ZC:PlayerLacksPvpFlag(), "Free-for-all PvP blocked from capturing")
-- 1.7.7: a capture paused because the capturer lost the flag (or mounted) said
-- nothing and the timer looked frozen. The capturer is now told why, in chat, at
-- the start of the pause and at most once a minute while it lasts.
do
    UnitIsPVP, ffa = function() return false end, false
    local zone = { id = "pause_test", name = "Test Capital", isHolding = true, holdAuthorityLocal = true,
        owner = Overlord.PlayerFaction, status = "in_progress", holdTimeElapsed = 189 }
    local realCurrent, realEnemy = Overlord.Zones.GetCurrentPlayerZone, Overlord.Zones.GetEnemyFaction
    Overlord.Zones.GetCurrentPlayerZone = function() return zone end
    Overlord.Zones.GetEnemyFaction = function() return Overlord.PlayerFaction == "Horde" and "Alliance" or "Horde" end
    local lines, realPrint = {}, Overlord.PrintNotification
    Overlord.PrintNotification = function(_, msg) lines[#lines + 1] = msg end
    ZC._pausedHintAt = nil
    ZC:UpdateHoldTimer(zone, 1)
    ZC:UpdateHoldTimer(zone, 1)
    assert(#lines == 1 and lines[1]:find("Test Capital", 1, true) and lines[1]:find("/pvp", 1, true),
        "a paused capture did not say why: " .. tostring(lines[1]))
    assert(zone.holdTimeElapsed == 189, "the paused capture moved")
    clock = clock + 61
    ZC:UpdateHoldTimer(zone, 1)
    assert(#lines == 2, "the pause reminder did not come back after a minute")
    UnitIsPVP = function() return true end
    IsMounted = function() return true end
    clock = clock + 61
    ZC:UpdateHoldTimer(zone, 1)
    assert(#lines == 3 and lines[3]:find((Overlord.L and Overlord.L.INDICATOR_DISMOUNT_TO_CAPTURE) or "Dismount", 1, true),
        "a mounted capturer was not told to dismount: " .. tostring(lines[3]))
    IsMounted = function() return false end
    Overlord.PrintNotification = realPrint
    Overlord.Zones.GetCurrentPlayerZone, Overlord.Zones.GetEnemyFaction = realCurrent, realEnemy
end
-- Unknown API or answer never blocks anyone.
ffa = false
UnitIsPVP = function() return nil end
assert(not ZC:PlayerLacksPvpFlag(), "A nil answer blocked the capture")
UnitIsPVP = nil
assert(not ZC:PlayerLacksPvpFlag(), "A missing API blocked the capture")
print("PvP flag capture rule: unflagged blocked, flagged and FFA allowed, paused capture explained, unknown never blocks")
