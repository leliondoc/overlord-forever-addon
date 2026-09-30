-- Call to arms (1.2.1): one call every 4 hours for the whole faction, only from an active
-- front, no nearby-enemy condition, sent on the faction's Overlord channel (plus relay and
-- group), received as a raid warning without any popup. Real SyncAux on the beta fixture.
assert(loadfile("tests/forever_beta_integration.test.lua"))()

local sync = Overlord.Sync
local server = 1790100000
GetServerTime = function() return server end
IsInInstance = function() return false end
IsInGroup, IsInRaid = function() return false end, function() return false end
Overlord.InstanceSuspended = false
Overlord.PlayerFaction = "Alliance"
OverlordDB.factionCallSharedAt, OverlordDB.factionCallLastAt = nil, nil
Overlord.Zones.GetZone = Overlord.Zones.GetZone or function(_, id) return { name = "Goldshire" } end
Overlord.Fronts.GetFront = Overlord.Fronts.GetFront or function(_, id) return { name = "Elwynn Forest" } end
Overlord.L.FACTION_CALL_RECEIVED = Overlord.L.FACTION_CALL_RECEIVED or "%s calls the faction: %s (%s)!"
Overlord.L.FACTION_CALL_RECEIVED_NO_ZONE = Overlord.L.FACTION_CALL_RECEIVED_NO_ZONE or "%s calls the faction: %s!"
Overlord.L.FACTION_CALL_RECEIVED_GENERIC = Overlord.L.FACTION_CALL_RECEIVED_GENERIC or "%s calls the faction!"
Overlord.UI = Overlord.UI or {}
Overlord.UI.GetNearbyEnemyCountRaw = function() return 0 end -- nobody around: no longer required

-- The fixture leaves a checking stub on the relay: count relay sends instead.
local relay = 0
Overlord.BetaNetwork.Broadcast = function(_, kind)
    if kind == "FC" then relay = relay + 1 end
    return 1
end
local channel = {}
sync.SendToChannel = function(_, kind, payload)
    channel[#channel + 1] = { kind = kind, payload = payload }
    return true
end
local warnings, popups = {}, 0
Overlord.PrintRaidWarning = function(_, text) warnings[#warnings + 1] = text end
Overlord.PrintNotification = function() end
Overlord.Popups = Overlord.Popups or {}
Overlord.Popups.ShowFactionCall = function() popups = popups + 1 end

-- 1. Outside an active front the call is refused.
Overlord.InActiveFront = false
assert(sync:BroadcastFactionCall("A:elwynn_goldshire:elwynn:1") == 0, "A call left from outside a front")
assert(#channel == 0, "A refused call still reached the channel")

-- 2. On a front, with no enemy nearby, the call goes out on the faction channel.
Overlord.InActiveFront = true
assert(sync:BroadcastFactionCall("A:elwynn_goldshire:elwynn:1") > 0, "A front call without enemies was refused")
assert(#channel == 1 and channel[1].kind == "FC", "The call did not use the faction's Overlord channel")
assert(relay == 1, "The call did not also go through the relay")
local remaining = sync:GetFactionCallCooldownRemaining()
assert(remaining > 4 * 3600 - 5 and remaining <= 4 * 3600, "Faction cooldown is not 4 hours: " .. remaining)

-- 3. Still on cooldown 3 h 59 later; free again after 4 h.
server = server + 4 * 3600 - 60
assert(sync:BroadcastFactionCall("A:elwynn_goldshire:elwynn:2") == 0, "A second call passed within 4 hours")
server = server + 61
assert(sync:GetFactionCallCooldownRemaining() == 0, "Cooldown outlived 4 hours")

-- 4. Receiving: a raid warning, no popup; the relay copy of the same call is ignored,
--    and so is any other call during the faction cooldown it starts.
OverlordDB.factionCallSharedAt = {}
sync:OnReceiveFactionCall("A:elwynn_goldshire:elwynn:3", "Ally Herald-Realm")
assert(#warnings == 1 and popups == 0, "A received call must be a raid warning without popup")
assert(warnings[1]:find("Ally Herald", 1, true), "The raid warning does not name the caller")
sync:OnReceiveFactionCall("A:elwynn_goldshire:elwynn:3", "Ally Herald-Realm")
sync:OnReceiveFactionCall("A:arathi_refuge:arathi:4", "Other Herald-Realm")
assert(#warnings == 1, "A duplicate or a second call during the faction cooldown was shown")
assert(sync:GetFactionCallCooldownRemaining() > 4 * 3600 - 5, "Receiving a call did not start the faction cooldown")

-- 5. A call carrying the other faction's code is ignored.
OverlordDB.factionCallSharedAt = {}
sync:OnReceiveFactionCall("H:elwynn_goldshire:elwynn:5", "Enemy Herald-Realm")
assert(#warnings == 1, "An enemy faction call was shown")
print("Forever call to arms: 4 h faction cooldown, front only, no enemy condition, channel + raid warning OK")
