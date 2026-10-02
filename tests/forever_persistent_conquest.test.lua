-- 1.4.0 persistent conquest (player design, May 2026 rule): after a total victory
-- and its 15 min truce, only the capitals go back to their faction; every other
-- zone stays with the winner. The winner cannot attack the capital it just lost
-- back until 2 h after the victory, so a front cannot be farmed for victories.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local Z = Overlord.Zones
Overlord.SaveState = function() end -- persistence is covered elsewhere
local truceEndSent = 0
Overlord.Sync.BroadcastFrontTruceEndReset = function() truceEndSent = truceEndSent + 1 end
local epoch = Overlord:GetCurrentCampaignStartTs()
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
Z:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RestoreZoneState()
local front = Overlord.Fronts:GetFront("elwynn")
local hordeCapital = front.hordeCapitalId

-- Total Alliance victory: the whole front is blue, the Horde capital included.
local victoryTs = epoch + 20000
for _, zone in ipairs(front.zones) do
    zone._loginSyncUnconfirmed = nil
    zone.owner, zone.status = "Alliance", "captured"
    zone.capturedTime, zone.updatedAt = victoryTs, victoryTs
end
OverlordDB.frontVictories.elwynn = { faction = "Alliance", timestamp = victoryTs }
local realTime = time
local now = victoryTs + 901
time = function() return now end

-- The truce ends on a client of the losing faction: the critical case (its own
-- view of enemy branches must not be wiped).
Overlord.PlayerFaction = "Horde"
Z:TryExpireFrontTruces()
local capital = Z:GetZone(hordeCapital)
assert(capital.owner == "Horde" and capital.status == "captured", "The lost capital did not go back")
assert(capital.updatedAt == victoryTs + 900, "Returned capital not stamped with the shared truce epoch")
local kept = 0
for _, zone in ipairs(front.zones) do
    if not Z:GetBaseZoneFixedOwner(zone.id) then
        assert(zone.owner == "Alliance" and zone.status == "captured",
            "Conquered zone " .. zone.id .. " was reset")
        kept = kept + 1
    end
end
assert(kept > 3, "fixture: no conquered zones")
assert(OverlordDB.frontVictories.elwynn == nil, "Victory not closed after the truce")
assert(truceEndSent == 1, "Truce end not announced")
-- Seen from the winner's side now.
Overlord.PlayerFaction = "Alliance"
Z:_DoUpdateAvailableZones(true)
assert(capital.owner == "Horde" and capital.status == "locked", "Winner sees the protected capital as open")

-- The winner cannot farm the capital back during the protection...
assert(Z:IsCapitalProtectedFrom(hordeCapital, "Alliance"), "Returned capital not protected")
assert(not Z:FactionMeetsPrereqsForZoneCapture(hordeCapital, "Alliance"), "Winner can farm the capital")
assert(not Z:IsZoneAvailable(hordeCapital), "Protected capital shown attackable to the winner")
assert(not Z:IsCapitalProtectedFrom(hordeCapital, "Horde"), "Protection blocks its own faction")
-- ...while the loser can strike back from its capital at once.
local strikeBack = false
for _, zone in ipairs(front.zones) do
    if zone.id ~= hordeCapital and Z:FactionMeetsPrereqsForZoneCapture(zone.id, "Horde") then
        strikeBack = true
    end
end
assert(strikeBack, "The loser cannot attack anything from its returned capital")

-- 2 h after the victory the capital is a target again (whole front still blue).
now = victoryTs + 7200 + 1
assert(not Z:IsCapitalProtectedFrom(hordeCapital, "Alliance"), "Protection never ends")
assert(Z:FactionMeetsPrereqsForZoneCapture(hordeCapital, "Alliance"), "Capital stayed closed after 2 h")

-- A weekly reset clears the protection with the truces.
now = victoryTs + 1000
OverlordDB.capitalProtectedUntil = { elwynn = victoryTs + 7200 }
Z:ClearFrontVictories()
assert(not Z:IsCapitalProtectedFrom(hordeCapital, "Alliance"), "Weekly reset kept the protection")
time = realTime
print("Persistent conquest: capitals return after the truce, conquest kept, 2 h anti-farming protection OK")
