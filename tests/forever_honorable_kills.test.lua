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

-- A DPS receives an HK even when someone else lands the killing blow.
honorableKills = 11
Overlord.Combat:OnPVPKillsChanged("player")
advance(3.1)
assert(score() == 1, "DPS honorable victory without a killing blow was lost")

-- Detailed killing-blow evidence before the HK counter must consume that HK.
Overlord.Combat:OnPartyKillEvent("Player-1-LOCAL", "Player-2-VICTIM_A")
assert(score() == 2, "Local killing blow was not credited")
honorableKills, killingBlows = 12, 3
Overlord.Combat:OnPVPKillsChanged("player")
advance(3.1)
assert(score() == 2, "KB followed by HK counted twice")

-- The reverse event order must also cancel the delayed anonymous HK credit.
honorableKills, killingBlows = 13, 4
Overlord.Combat:OnPVPKillsChanged("player")
Overlord.Combat:OnPartyKillEvent("Player-1-LOCAL", "Player-2-VICTIM_B")
advance(3.1)
assert(score() == 3, "HK followed by KB counted twice")

-- The featured front's advertised x2 applies once to every role, including DPS.
Overlord.InActiveFront = true
Overlord.Fronts.IsFeaturedFrontActive = function() return true end
honorableKills = 14
Overlord.Combat:OnPVPKillsChanged("player")
advance(3.1)
assert(score() == 5, "Featured-front honorable victory did not receive x2")

-- A healer still receives the same HK credit without a killing blow.
Overlord.InActiveFront = false
UnitGroupRolesAssigned = function() return "HEALER" end
honorableKills = 15
Overlord.Combat:OnPVPKillsChanged("player")
Overlord.Combat:OnPVPKillsChanged("player")
advance(3.1)
assert(score() == 6, "A repeated healer HK event counted twice")
print("Forever honorable kills: DPS/healer HKs, KB dedup in both orders and featured x2 OK")
