-- Exercise the real Forever event handlers with Blizzard's session counters.
assert(loadfile("tests/forever_leaderboard.test.lua"))()

local clock, honorableKills, killingBlows = 100, 10, 2
local scheduled = {}
function GetTime() return clock end
function GetPVPSessionStats() return honorableKills, 0 end
function IsInInstance() return false, "none" end
function GetInstanceInfo() return nil, "none" end
function IsInRaid() return false end
function IsInGroup() return false end
function UnitExists() return false end
function UnitGUID(unit) return unit == "player" and "Player-1-LOCAL" or nil end
function UnitNameFromGUID(guid)
    return ({ ["Player-2-VICTIM_A"] = "Victim A",
        ["Player-2-VICTIM_B"] = "Victim B" })[guid]
end
C_AchievementInfo = { GetCriteriaInfo = function() return { quantity = killingBlows } end }
C_Timer.After = function(delay, callback)
    scheduled[#scheduled + 1] = { due = clock + delay, callback = callback }
end
CreateFrame = function()
    return { RegisterEvent = function() end, RegisterUnitEvent = function() end,
        SetScript = function() end }
end

local function advance(seconds)
    local untilTime = clock + seconds
    while true do
        local nextIndex, nextDue
        for index, timer in ipairs(scheduled) do
            if timer.due <= untilTime and (not nextDue or timer.due < nextDue) then
                nextIndex, nextDue = index, timer.due
            end
        end
        if not nextIndex then break end
        local timer = table.remove(scheduled, nextIndex)
        clock = timer.due
        timer.callback()
    end
    clock = untilTime
end

Overlord.InActiveFront = false
Overlord.Zones.GetCurrentPlayerZone = function() return nil end
Overlord.Sync.BroadcastKill = function() end
Overlord.L.KILL_CONFIRM = "%s: %d"
assert(loadfile("CombatTracker.lua"))()
Overlord.Combat:Initialize()
local playerName = Overlord.Sync:GetPlayerFullName()
local function score() return Overlord.Leaderboard.kills[playerName] or 0 end

-- Every role gets exactly the official delta, independent of damage/healing.
for _, role in ipairs({ "DAMAGER", "HEALER", "TANK" }) do
    UnitGroupRolesAssigned = function() return role end
    honorableKills = honorableKills + 1
    Overlord.Combat:OnPVPKillsChanged("player")
    Overlord.Combat:OnPVPKillsChanged("player")
end
assert(score() == 3, "Role or duplicate notification changed the official VH count")

-- Named killing blows are evidence, never a second source of leaderboard points.
Overlord.Combat:OnPartyKillEvent("Player-1-LOCAL", "Player-2-VICTIM_A")
assert(score() == 3, "Killing blow added a point before Blizzard awarded an HK")
honorableKills, killingBlows = 14, 3
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 4, "KB before HK counted twice")
honorableKills, killingBlows = 15, 4
Overlord.Combat:OnPVPKillsChanged("player")
Overlord.Combat:OnPartyKillEvent("Player-1-LOCAL", "Player-2-VICTIM_B")
advance(10)
assert(score() == 5, "HK before KB or delayed backup counted twice")

Overlord.InActiveFront = true
Overlord.Fronts.IsFeaturedFrontActive = function() return Overlord.InActiveFront end
local gold = 0
Overlord.Ressources = { AddGold = function(_, count) gold = gold + count end }
honorableKills = 16
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 6 and gold == 1, "Featured front must grant gold but never multiply HK")
Overlord.InActiveFront = false

-- A batched counter increase must not be capped at the old limit of 40.
honorableKills = 96
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 86, "Batched legitimate HKs were lost")

-- Missing data is not zero; the next valid reading keeps the previous reference.
GetPVPSessionStats = function() return nil end
Overlord.Combat:OnPVPKillsChanged("player")
honorableKills = 97
GetPVPSessionStats = function() return honorableKills, 0 end
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 87, "Transient counter outage lost an HK")

-- A daily reset never subtracts weekly points or replays old totals.
honorableKills = 0
Overlord.Combat:OnPVPKillsChanged("player")
honorableKills = 1
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 88, "Daily reset changed weekly history")

-- Instance credits are baselined, including changes while events are suspended.
Overlord.InstanceSuspended = true
honorableKills = 40
Overlord.Combat:OnPVPKillsChanged("player")
Overlord.InstanceSuspended = false
Overlord.Combat:Resume()
honorableKills = 41
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 89, "Instance points leaked into the outdoor leaderboard")

-- Prefer the lifetime counter: no daily rollover, no false zero replay.
local lifetime = 2000
GetPVPLifetimeStats = function() return lifetime end
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 89, "Switching counter imported historical HKs")
lifetime = 0
Overlord.Combat:OnPVPKillsChanged("player")
lifetime = 2001
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 90, "Transient lifetime zero duplicated the player's history")

-- 2026-09-29 : the lifetime counter can read 0 at login before PvP data arrives. The
-- first real reading (3434 last week + 50 today) must not be credited as one delta.
lifetime, honorableKills = 0, 50
Overlord.Combat:Resume()
lifetime = 3484
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 90, "Late lifetime data credited the player's whole history")
lifetime, honorableKills = 3485, 51
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 91, "First HK after the late lifetime rebase was lost")
-- A brand-new character really starts at 0: its first HKs still count.
lifetime, honorableKills = 0, 0
Overlord.Combat:Resume()
lifetime, honorableKills = 2, 2
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 93, "A new character's first HKs were dropped")
-- A stale non-zero lifetime read at login is not a valid reference either.
lifetime, honorableKills = 3000, 50
Overlord.Combat:Resume()
lifetime = 3484
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 93, "Stale lifetime reference credited historical HKs")
lifetime, honorableKills = 3487, 53
Overlord.Combat:OnPVPKillsChanged("player")
lifetime, honorableKills = 3587, 153
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 196, "Confirmed reference lost legitimate batched HKs")
-- Without today's counter, a valid non-zero reference keeps batched HKs...
local sessionReader = GetPVPSessionStats
GetPVPSessionStats = function() return nil end
Overlord.Combat:Resume()
lifetime = 3590
Overlord.Combat:OnPVPKillsChanged("player")
lifetime = 3593
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 202, "Missing daily counter dropped legitimate batched HKs")
-- ...while a zero reference still cannot import the whole history.
lifetime = 0
Overlord.Combat:Resume()
lifetime = 3600
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 202, "Missing daily counter let a zero reference import history")
-- ...and a stale non-zero reference cannot either.
lifetime = 3000
Overlord.Combat:Resume()
lifetime = 3484
Overlord.Combat:OnPVPKillsChanged("player")
assert(score() == 202, "Missing daily counter let a stale reference import history")
GetPVPSessionStats = sessionReader

-- Being the target or a nearby priest when someone dies is not an HK.
Overlord.Zones.GetEnemyFaction = function() return "Alliance" end
Overlord.Combat.IdentifyKiller = function() return "Nearby Priest", "Player-2-PRIEST" end
Overlord.Combat.GetEnemyClassFromNameplate = function() return "PRIEST" end
Overlord.Sync.SendToGroup = function() end
Overlord.Sync.SendToChannel = function() end
Overlord.Sync.BroadcastToRelay = function() end
Overlord.Combat:OnPlayerDead()
assert((Overlord.Leaderboard.kills["Nearby Priest"] or 0) == 0,
    "A guessed killer received an exportable score")
assert(score() == 202)
print("Forever HK: exact Blizzard deltas, all roles, no KB/death/x2 additions, batching, counters and instances OK")
