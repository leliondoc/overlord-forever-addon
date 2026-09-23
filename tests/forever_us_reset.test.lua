local us = 1790064000 -- Tuesday 2026-09-22 08:00 UTC, shared beta campaign anchor.
local now, region = us + 18 * 3600, 3
function time() return now end
function GetServerTime() return now end
function GetTime() return now end
function date(fmt, ts) return os.date(fmt, ts or now) end
function GetCurrentRegion() return region end
function GetLocale() return "frFR" end
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end
local scheduled
C_Timer = { After = function(delay) scheduled = delay end }
-- The regional API deliberately disagrees. It must never choose a beta reset.
C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 3600 end }
Overlord = { L = { WEEKLY_RESET = "US weekly reset" } }
assert(loadfile("Core.lua"))()
Overlord.GetCurrentLeaderboardSavedVarsPool = function() return "global" end
local score = { ["Guild Member"] = 1623 }
OverlordDB = { lastResetTimestamp = us, leaderboardResetEpoch = us,
    leaderboard = { kills = score, campaignStart = us }, leaderboardsByPool = {} }
local resets, mapResets = 0, 0
Overlord.PrintNotification = function() end
Overlord.ResetAll = function() mapResets = mapResets + 1 end
Overlord.Leaderboard = {
    Reset = function(_, _, epoch)
        resets = resets + 1
        OverlordDB.leaderboard = { kills = {}, campaignStart = epoch }
        OverlordDB.pendingWeeklyArchive = { resetEpoch = epoch }
    end,
    MarkWeeklyResetCoreSideEffectsApplied = function()
        OverlordDB.pendingWeeklyArchive.coreSideEffectsApplied = true
    end,
    ResumePendingWeeklyArchive = function()
        OverlordDB.pendingWeeklyResetAt = nil
        OverlordDB.pendingWeeklyArchive = nil
    end,
}
for _, hour in ipairs({18, 19, 20, 30}) do
    now = us + hour * 3600
    for _, endpoint in ipairs({1, 3}) do
        region = endpoint
        assert(Overlord:GetCurrentCampaignStartTs() == us)
        Overlord:CheckWeeklyReset()
        assert(resets == 0 and mapResets == 0 and score["Guild Member"] == 1623,
            "Wednesday/EU endpoint reset the US campaign")
    end
end
OverlordDB.lastResetTimestamp = us + 19 * 3600
OverlordDB.pendingWeeklyResetAt = us + 19 * 3600
Overlord:CheckWeeklyReset()
assert(resets == 0 and mapResets == 0 and OverlordDB.pendingWeeklyResetAt == nil,
    "Legacy interrupted EU reset was replayed")
assert(OverlordDB.lastResetTimestamp == us and score["Guild Member"] == 1623)
OverlordDB.pendingWeeklyResetAt = us + 19 * 3600
OverlordDB.pendingWeeklyArchive = { resetEpoch = us + 19 * 3600, bucket = { kills = score } }
Overlord:CheckWeeklyReset()
assert(resets == 0 and mapResets == 0 and OverlordDB.leaderboard.kills == score,
    "Resuming an already detached EU archive erased the active scores")
Overlord:ScheduleNextReset()
assert(scheduled == us + 604800 - now, "Next reset was scheduled on the EU boundary")
now = us + 604800
Overlord:CheckWeeklyReset()
assert(resets == 1 and mapResets == 1, "Real next US week did not reset")
Overlord.Leaderboard:ResumePendingWeeklyArchive()
Overlord:CheckWeeklyReset()
assert(resets == 1 and mapResets == 1, "Real US reset ran twice")
print("Forever US reset: French/US clients, Wednesday, legacy pending reset and true weekly rollover OK")
