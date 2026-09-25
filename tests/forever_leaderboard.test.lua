-- Exercise the real capture -> save -> fresh character load path.
local now, campaign = 1790017000, 1789527600
local player, faction = "Dwarf Tester", "Alliance"
function time() return now end
function date(format, value) return os.date(format, value or now) end
function GetServerTime() return now end
function GetTime() return 100 end
function GetLocale() return "enUS" end
function GetCurrentRegion() return 3 end
function UnitName() return player end
function UnitFullName() return player, "" end
function GetUnitName() return player end
function UnitFactionGroup() return faction end
function UnitClass() return "Priest", "PRIEST" end
function UnitRace() return "Dwarf", "Dwarf" end
function UnitSex() return 2 end
function UnitLevel() return 2 end
function GetGuildInfo() return nil end
function wipe(t) for key in pairs(t) do t[key] = nil end return t end
function CreateFrame()
    return { RegisterEvent = function() end, SetScript = function() end }
end
C_Timer = { After = function() end, NewTicker = function() return {} end }
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
Overlord = { L = { ZONE_CAPTURED_BY = "%s captured by %s" } }
assert(loadfile("Core.lua"))()
assert(loadfile("RealmPools.lua"))()
local zone = { id = "loch_valley_of_kings", name = "Valley of Kings", status = "available" }
Overlord.ZoneDatabase = { zone }
Overlord.Fronts = {
    Registry = { loch_modan = { zones = { zone } } },
    GetEnemyCapitalId = function() return "enemy_capital" end,
}
Overlord.Zones = {
    GetFactionName = function() return faction end,
    UpdateAvailableZones = function() end,
}
Overlord.PrintNotification = function() end
Overlord.GetLastResetTimestamp = function() return campaign end
Overlord.GetCurrentCampaignStartTs = function() return campaign end
Overlord.PlayerFaction = faction
assert(loadfile("Sync.lua"))()
assert(loadfile("SyncAux.lua"))()
-- Network transport is irrelevant to a physical local capture.
for _, method in ipairs({ "BroadcastCapture", "BroadcastZoneState", "ResetEnemyCaptureAlert",
    "ScheduleControlledZoneSnapshot" }) do Overlord.Sync[method] = function() end end
assert(loadfile("ZoneControl.lua"))()
local function loadLeaderboard()
    assert(loadfile("Leaderboard.lua"))()
    -- Background index scheduling is tested independently; use the synchronous display reader below.
    Overlord.Leaderboard.EnsureNetworkHotIndexesPrepared = function() return true end
    Overlord.Leaderboard:Initialize(true)
    return Overlord.Leaderboard
end

-- A first installation has an empty, unstamped score table and no previous weekly reset.
OverlordDB = { config = {}, zones = {}, lastResetTimestamp = campaign,
    leaderboard = { kills = {}, captures = {}, playerInfo = {} }, leaderboardScoreSanitizeVersion = 5 }
local lb = loadLeaderboard()
lb:ForceUpdateLocalPlayer(player, "PRIEST", faction)
lb:Save()
Overlord.ZoneControl:CaptureZone(zone)
assert(lb.captureCount[player] == 1, "Physical capture did not credit the player")
lb:Save()
local disk = copy(OverlordDB)
assert(disk.leaderboardScoreBucketEpoch == campaign, "Fresh score table was never attested")

-- Reload / another character must keep both the credit and its original owner's faction.
player, faction = "Warrior Tester", "Horde"
Overlord.PlayerFaction = faction
OverlordDB = copy(disk)
assert(loadfile("Sync.lua"))()
assert(loadfile("SyncAux.lua"))()
lb = loadLeaderboard()
assert(lb.captureCount["Dwarf Tester"] == 1, "Login erased the first character's capture")
local rows = lb:GetSortedCapturesByFaction()
assert(#rows.Alliance == 1 and rows.Alliance[1].name == "Dwarf Tester"
    and rows.Alliance[1].count == 1 and #rows.Horde == 0, "Capture disappeared from the faction table")

-- Do not turn old, nonempty, unverified scores into current scores as a side effect.
OverlordDB = copy(disk)
OverlordDB.leaderboardScoreBucketEpoch = campaign - 604800
OverlordDB.lastLeaderboardResetAt = nil
lb = loadLeaderboard()
assert(next(lb.captureCount) == nil, "An unverified nonempty score table bypassed the campaign guard")

-- A missing score table follows the same first-install path.
OverlordDB = { config = {}, lastResetTimestamp = campaign, leaderboardScoreSanitizeVersion = 5 }
lb = loadLeaderboard()
assert(OverlordDB.leaderboard.campaignStart == campaign
    and OverlordDB.leaderboardScoreBucketEpoch == campaign, "Missing score table was not initialized")
print("Forever leaderboard: physical capture, first save, reload, alt faction, display and campaign guard OK")
