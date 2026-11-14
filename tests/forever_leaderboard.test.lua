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
local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = deepCopy(item) end
    return result
end
-- A copy of the save is what the SavedVariables writer sees: compact playerInfo
-- rows are written back named first, as PLAYER_LOGOUT does (2.2.2).
local function copy(value)
    local lb = Overlord and Overlord.Leaderboard
    if lb and lb.MaterializePlayerInfoRows then lb:MaterializePlayerInfoRows() end
    return deepCopy(value)
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
    leaderboard = { kills = {}, captures = {}, playerInfo = {} }, leaderboardScoreSanitizeVersion = 10 }
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
local capturers = {}
for capturer, count in pairs(lb.captureCount) do
    if count > 0 then capturers[#capturers + 1] = capturer end
end
assert(#capturers == 1 and capturers[1] == "Dwarf Tester"
    and select(2, lb:GetExportPlayerMeta("Dwarf Tester")) == "Alliance",
    "Capture disappeared from the faction table")

-- Do not turn old, nonempty, unverified scores into current scores as a side effect.
OverlordDB = copy(disk)
OverlordDB.leaderboardScoreBucketEpoch = campaign - 604800
OverlordDB.lastLeaderboardResetAt = nil
lb = loadLeaderboard()
assert(next(lb.captureCount) == nil, "An unverified nonempty score table bypassed the campaign guard")

-- A missing score table follows the same first-install path.
OverlordDB = { config = {}, lastResetTimestamp = campaign, leaderboardScoreSanitizeVersion = 10 }
lb = loadLeaderboard()
assert(OverlordDB.leaderboard.campaignStart == campaign
    and OverlordDB.leaderboardScoreBucketEpoch == campaign, "Missing score table was not initialized")
-- 2.5.2: the locale shown for a ranked player, answers kept per tag (same as before them).
do
    local F = function(tag, pool) return Overlord:FormatLocaleTagForDisplay(tag, pool) end
    for _ = 1, 2 do
        assert(F("frfr") == "frFR" and F("FRFR") == "frFR" and F("ptbr") == "ptBR" and F("esmx") == "esMX")
        -- (English without its region follows the client's region, never a kept answer.)
        local region = GetCurrentRegion
        assert(F("en") == "enGB" and F("enus") == "enGB", "English on an EU client")
        GetCurrentRegion = function() return 1 end
        assert(F("en") == "enUS" and F("enus") == "enUS", "English without a region kept the other region's answer")
        GetCurrentRegion = region
        assert(F("fr") == "frFR" and F("abcd") == "abCD" and F("xyz") == "XYZ")
        assert(F("") == "" and F(nil) == "" and F("12") == "" and F("fr fr") == "")
    end
    -- Made-up tags from the network: answered all the same, never kept beyond the cap.
    for i = 1, 200 do assert(F("q" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26) % 26)) ~= nil) end
    assert(F("dede") == "deDE" and F("en") == "enGB")
end
print("Forever leaderboard: physical capture, first save, reload, alt faction, display and campaign guard OK")
