-- 1.8.1: the Attack coins (next capture 60 s shorter) never apply to a capital. The
-- network only accepts a capital's canonical duration (CaptureLease
-- NormalizeCaptureRequirement): a capital started with Attack ready ended with a
-- shortened requirement that BroadcastCapture itself refused to announce, so the
-- capital stayed captured for its capturer alone. Attack stays ready for the next zone.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local ZC = Overlord.ZoneControl
local mine = Overlord.PlayerFaction
local enemy = mine == "Horde" and "Alliance" or "Horde"

local consumed = 0
Overlord.Ressources = Overlord.Ressources or {}
Overlord.Ressources.ConsumeCaptureReduction = function(_, required, minimum)
    consumed = consumed + 1
    return math.max(minimum, required - 60), true
end
Overlord.Outpost = nil
local broadcast = 0
Overlord.Sync.BroadcastZoneState = function() broadcast = broadcast + 1 end
local realFixedOwner, realCapitalHold = Overlord.Zones.GetBaseZoneFixedOwner, Overlord.Zones.GetCapitalHoldTime
Overlord.Zones.GetBaseZoneFixedOwner = function() return enemy end
Overlord.Zones.GetCapitalHoldTime = function() return 480 end

local capital = { id = "attack_capital", name = "Enemy Capital", isCapital = true,
    owner = enemy, status = "available", holdTimeElapsed = 0 }
ZC:StartHoldTimer(capital, true)
assert(consumed == 0, "Attack was spent on a capital")
assert(capital.holdTimeRequired == 480, "A capital lost its canonical duration: " .. tostring(capital.holdTimeRequired))
if not Overlord.CaptureLease then assert(loadfile("ZoneCaptureLease.lua"))() end
assert(Overlord.CaptureLease:NormalizeCaptureRequirement(capital, mine, capital.holdTimeRequired) == 480,
    "The capital's final would not be announced")

local point = { id = "attack_point", name = "Plain Point", owner = enemy, status = "available", holdTimeElapsed = 0 }
ZC:StartHoldTimer(point, true)
assert(consumed == 1 and point.holdTimeRequired == 60, "Attack no longer shortens an ordinary point")
assert(broadcast == 2, "Capture start was not announced")

Overlord.Zones.GetBaseZoneFixedOwner, Overlord.Zones.GetCapitalHoldTime = realFixedOwner, realCapitalHold
print("Capital attack coins: capitals keep their canonical duration and Attack, points are shortened OK")
