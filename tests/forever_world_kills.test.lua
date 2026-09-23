-- Reuse the production module fixture, then drive the actual PvP kill event.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local instanced, instanceType, level = false, "none", 2
local killerGUID = "Player-1-LOCAL"
local hk = 10
function GetPVPSessionStats() return hk, 0 end
function IsInInstance() return instanced, instanceType end
function GetInstanceInfo() return nil, instanceType, nil, nil, nil, nil, nil, 99999 end
function UnitLevel() return level end
function UnitGUID(unit) return unit == "player" and killerGUID or nil end
function UnitNameFromGUID() return "Enemy Tester" end
function UnitExists() return false end
function IsInRaid() return false end
function IsInGroup() return false end
function strsplit(separator, value)
    local parts, start = {}, 1
    while true do
        local at = value:find(separator, start, true)
        if not at then parts[#parts + 1] = value:sub(start); break end
        parts[#parts + 1] = value:sub(start, at - 1)
        start = at + #separator
    end
    return (unpack or table.unpack)(parts)
end
C_Map = { GetBestMapForUnit = function() return 99999 end }
C_Scenario = { IsInScenario = function() return true end }
Overlord.InActiveFront = false
Overlord.Ressources = { IsInOverlordKillZone = function() return false end }
Overlord.Zones.GetCurrentPlayerZone = function() return nil end
Overlord.L.KILL_CONFIRM = "%s: %d"
local sent
Overlord.Sync.BroadcastKill = function(_, zoneId, total, eligible)
    sent = { zoneId = zoneId, total = total, eligible = eligible }
end
assert(loadfile("CombatTracker.lua"))()
local me = Overlord.Sync:GetPlayerFullName()
Overlord.Combat:OnPVPKillsChanged("player")
for _, value in ipairs({ 1, 2, 10, 59, 60 }) do
    level = value
    assert(Overlord:IsKillScoringActive(), "Outdoor kill blocked at level " .. value)
    assert(Overlord.Sync:IsEligibleKillContributorLevel(value), "Sync rejected low level")
    local payload = Overlord.Sync:BuildKillBroadcastPayload(me, "", 1, "PRIEST", "Horde",
        1789527600, "", "enus", 0, 1789527600, value)
    assert(payload and payload:match(":" .. value .. "$"), "Low-level worldwide K was not serialized")
end
assert(not Overlord.Sync:IsEligibleKillContributorLevel(0))
assert(not Overlord.Sync:IsEligibleKillContributorLevel(-1))
assert(not Overlord.Sync:IsEligibleKillContributorLevel("invalid"))
assert(not Overlord.Sync:IsEligibleKillContributorLevel(1.5))
level = 2
Overlord.Combat:OnPartyKillEvent(killerGUID, "Player-2-ENEMY")
hk = 11
Overlord.Combat:OnPVPKillsChanged("player")
assert(Overlord.Leaderboard.kills[me] == 1, "Level 2 outdoor PvP kill was not counted")
assert(sent and sent.zoneId == "" and sent.total == 1 and sent.eligible,
    "Kill outside fronts was not broadcast")
Overlord.Combat:OnPartyKillEvent(killerGUID, "Player-2-ENEMY")
assert(Overlord.Leaderboard.kills[me] == 1, "Duplicate kill was counted twice")
Overlord.Combat:OnPartyKillEvent(killerGUID, "Creature-2-NPC")
assert(Overlord.Leaderboard.kills[me] == 1, "PvE kill was counted")
for _, kind in ipairs({ "pvp", "arena", "party", "raid", "scenario" }) do
    instanced, instanceType = true, kind
    assert(not Overlord:IsKillScoringActive(), "Instanced combat was accepted: " .. kind)
    Overlord.Combat:OnPartyKillEvent(killerGUID, "Player-2-" .. kind)
    hk = hk + 1
    Overlord.Combat:OnPVPKillsChanged("player")
    assert(Overlord.Leaderboard.kills[me] == 1, "Instance kill changed the score")
end
instanced, instanceType = false, "pvp"
assert(not Overlord:IsKillScoringActive(), "BG loading transition was accepted")
instanceType = "none"
Overlord.InstanceSuspended = true
assert(not Overlord:IsKillScoringActive(), "Suspended instance was accepted")
Overlord.InstanceSuspended = false
assert(Overlord:IsKillScoringActive(), "Outdoor counting did not resume")
Overlord.Leaderboard:Save()
assert(OverlordDB.leaderboard.kills[me] == 1, "Outdoor kill was not saved")
local remote = Overlord.Sync:BuildKillBroadcastPayload("Remote Tester", "", 1, "WARRIOR", "Alliance",
    1789527600, "", "enus", 0, 1789527600, 2)
assert(loadfile("SyncResolution.lua"))()
Overlord.Sync:OnReceiveKill(remote, "Remote Tester")
assert(Overlord.Leaderboard.kills["Remote Tester"] == 1, "Receiver rejected a level 2 outdoor kill")
Overlord.Sync:OnReceiveLeaderboardKills(
    "Remote Tester:2:WARRIOR:Alliance:1789527600:enus::0:B1789527600:2", "Remote Tester", "WHISPER")
assert(Overlord.Leaderboard.kills["Remote Tester"] == 2, "Leaderboard sync rejected a level 2 total")
print("Forever world kills: all levels, unlisted outdoor map, event, sync payload, dedup, PvE and instance exclusion OK")
