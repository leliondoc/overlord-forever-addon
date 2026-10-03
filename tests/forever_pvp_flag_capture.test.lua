-- 1.4.1 (player request): only PvP-flagged players take or hold objectives. An
-- unflagged player cannot be attacked (Normal ruleset, or own territory on a PvP
-- ruleset) and must not capture for free. The rule lives in the shared
-- "cannot capture right now" check (mount, flight, stealth...), used by front
-- zones, outposts and fortresses alike.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local ZC = Overlord.ZoneControl
assert(ZC and ZC.PlayerLacksPvpFlag, "PvP flag rule missing")
-- Consent rulesets only (Normal/RP/Hardcore): on the PvP ruleset players are
-- attackable in their own territory without the flag, so the rule never applies.
Overlord.RealmPools = Overlord.RealmPools or {}
local realRuleset = Overlord.RealmPools.GetRuleset
local currentRuleset = "normal"
Overlord.RealmPools.GetRuleset = function() return currentRuleset end

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
-- Unknown API or answer never blocks anyone.
ffa = false
UnitIsPVP = function() return nil end
assert(not ZC:PlayerLacksPvpFlag(), "A nil answer blocked the capture")
UnitIsPVP = nil
assert(not ZC:PlayerLacksPvpFlag(), "A missing API blocked the capture")
-- PvP ruleset: an unflagged defender in his own territory still captures.
UnitIsPVP = function() return false end
currentRuleset = "pvp"
assert(not ZC:PlayerLacksPvpFlag(), "PvP-ruleset defender blocked without /pvp")
currentRuleset = "rp"
assert(ZC:PlayerLacksPvpFlag(), "RP ruleset lets an unflagged player capture")
Overlord.RealmPools.GetRuleset = realRuleset
print("PvP flag capture rule: unflagged blocked, flagged and FFA allowed, unknown never blocks")
