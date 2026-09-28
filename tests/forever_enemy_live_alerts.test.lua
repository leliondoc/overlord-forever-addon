-- Real BNet dispatch -> beta envelope -> capture/commander handlers -> chat.
-- A three-name relay path must retain the Horde author at an Alliance client.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("ZoneCaptureLease.lua"))()
local sync, net = Overlord.Sync, Overlord.BetaNetwork
OverlordDB.config.debug = true
Overlord.PlayerFaction = "Alliance"
Overlord.InstanceSuspended = false
Overlord.L.SYNC_CAPTURED_ENEMY_BY = "%s captured by %s (%s)"
Overlord.L.SYNC_CAPTURED_ENEMY = "%s captured by %s"
Overlord.L.GENERAL_ENEMY_ASSUMED = "%s is the enemy commander in %s"
local zone = {
    id = "loch_valley_of_kings", name = "Valley of Kings", owner = "Alliance",
    status = "captured", capturedTime = time() - 300, holdTimeRequired = 120,
}
Overlord.ZoneDatabase = { zone }
Overlord.Fronts.GetZone = function(_, id)
    if id == zone.id then return zone, { id = "loch_modan" } end
end
Overlord.Zones.GetZone = function(_, id) return id == zone.id and zone end
Overlord.Zones.GetEnemyFaction = function() return "Horde" end
Overlord.Zones.GetEnemyFactionName = function() return "Horde" end
Overlord.Zones.GetFactionName = function() return "Alliance" end
Overlord.Zones.IsOnVictoryCooldown = function() return false end
local messages = {}
Overlord.PrintNotification = function(_, message) messages[#messages + 1] = message end
local function receive(id, kind, payload)
    local wire = table.concat({ "global", "enemy-alert-" .. id, tostring(time()), "*",
        "Enemy Tester,Relay Tester,Bridge Tester", kind, payload }, "|")
    sync:OnBNetMessage("R2:Forever_eu_H:BR:" .. wire, 123)
    assert(not net.stats.lastError, net.stats.lastError)
end
local capture = table.concat({ zone.id, "Enemy Tester|WARRIOR", "Horde", time(),
    "enemy-wave", "Player-1-ENEMY", "120" }, ":")
assert(sync:BuildCaptureFinalClaimKey(zone.id, "H", time(), "Enemy Tester",
    "enemy-wave", "Player-1-ENEMY", "120"), "Fixture final claim invalid")
receive(1, "C", capture)
assert(zone.owner == "Horde" and zone.status == "captured", "Relayed Horde capture did not apply")
assert(#messages == 1 and messages[1]:find("Horde", 1, true)
    and messages[1]:find("Enemy Tester", 1, true), "Horde capture chat alert was lost")
receive(2, "C", capture)
assert(#messages == 1, "Capture replay duplicated the alert")
receive(3, "GE", "H:global:5000:5000:1417:" .. time() .. ":" .. OverlordDB.lastResetTimestamp)
local commander = Overlord.General:GetSlot("Horde")
assert(commander and commander.holder == "Enemy Tester", "Horde commander was lost or attributed to a bridge")
assert(#messages == 2 and messages[2]:find("Enemy Tester", 1, true)
    and messages[2]:find("enemy commander", 1, true), "Horde commander chat alert was lost")
receive(4, "GE", "H:global:5000:5000:1417:" .. time() .. ":" .. OverlordDB.lastResetTimestamp)
assert(#messages == 2, "Commander replay duplicated the alert")
print("Horde live alerts: production BNet dispatch preserves capture/commander chat and replay dedup")
