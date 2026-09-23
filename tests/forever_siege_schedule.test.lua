-- Exercise the real calendar and proof ledger, with a realm clock unlike the OS.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
assert(loadfile("GuildKeep.lua"))()
local gk, lb = Overlord.GuildKeep, Overlord.Leaderboard
local midnight = 1790208000 -- 2026-09-24 00:00 UTC
local now, offset = midnight, 2 * 3600
function time() return now end
function GetServerTime() return now end
function date(fmt, ts) return os.date(fmt, ts or now) end
function GetGameTime()
    local cal = os.date("!*t", now + offset)
    return cal.hour, cal.min
end
local function at(hour, minute, second)
    now = midnight + hour * 3600 + (minute or 0) * 60 + (second or 0) - offset
    return now
end
for _, realmOffset in ipairs({ -7 * 3600, 0, 2 * 3600 }) do
    offset = realmOffset
    for _, hour in ipairs({ 3, 9, 15, 21 }) do
        at(hour - 1, 59, 59)
        assert(not gk:IsSiegeWindowOpen())
        assert(gk:IsSiegeReminderWindow())
        assert(gk:GetSiegeWindowStartLabel() == string.format("%02d:00", hour))
        assert(gk:IsSiegeTimestampInWindow(now, 1, 0), "Before-window transport grace lost")
        at(hour)
        assert(gk:IsSiegeWindowOpen() and not gk:IsSiegeWindowClosedForToday())
        assert(gk:GetSiegeSecondsRemaining() == 3600)
        assert(gk:GetServerSiegeDayKey() == string.format("20260924%02d", hour))
        at(hour, 59, 59)
        assert(gk:GetSiegeSecondsRemaining() == 1)
        at(hour + 1)
        assert(not gk:IsSiegeWindowOpen() and gk:IsSiegeWindowClosedForToday())
        assert(gk:GetSiegeSecondsRemaining() == 0)
        assert(not gk:IsSiegeCaptureTimestampAllowed(now))
        assert(gk:IsSiegeTimestampInWindow(now, 0, 1))
        assert(not gk:IsSiegeReminderWindow())
    end
    at(0)
    assert(gk:GetServerSiegeDayKey() == "2026092321", "Midnight lost previous siege")
    assert(gk:GetServerCalendarDayKey() == "20260924")
    assert(gk:GetSiegeWindowStartLabel() == "03:00")
end
offset = 2 * 3600
local start = at(3)
local finish = at(3, 15)
at(10)
assert(gk:GetSiegeSecondsRemaining(start) == 3600, "Historical timer used current window")
assert(gk:GetAssaultAttemptStartedAt(start, 6 * 3600) == 0,
    "An old assault root crossed into the next siege")
local legacy = 1790126100 -- 2026-09-23 01:15 UTC = previous day's 18:15 Pacific
assert(gk:GetServerSiegeDayKey(legacy) == "20260922")
assert(gk:IsSiegeCaptureTimestampAllowed(legacy), "Historical captures were invalidated")

OverlordDB.lastResetTimestamp = midnight - 2 * 86400
OverlordDB.guildKeepDailyProofEpoch = OverlordDB.lastResetTimestamp
lb.GetCurrentCampaignStart = function() return OverlordDB.lastResetTimestamp end
Overlord.GetCurrentSavedVarsPool = function() return "global" end
local timers = {}
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local function drain()
    local i = 1
    while i <= #timers do
        assert(i < 10000, "Ledger failed to finish")
        local callback = timers[i]; i = i + 1; callback()
    end
    timers = {}
end
local function apply(key, ts)
    return lb:ApplyGuildKeepDailyProofSync("badlands", key, "GC", ts + 900,
        "Alpha", "Alliance", 1, ts, 0, "Alpha Tester", "", nil, 0, "global")
end
at(3, 30)
assert(not apply("2026092403", start), "Victory credited before window closure")
at(4)
assert(apply("2026092403", start), "First siege proof rejected")
lb:EnsureGuildKeepProofLedgerPrepared(true)
drain()
assert(lb:ReconcileGuildKeepDailyAward("badlands", "2026092403"))
drain()
at(10)
-- Same tenant successfully defends at the next cutoff, using its capture proof.
assert(apply("2026092409", start), "Second siege defense rejected")
assert(lb:ReconcileGuildKeepDailyAward("badlands", "2026092409"))
drain()
assert(OverlordDB.guildKeepSiegeWinAwards["2026092403:badlands"])
assert(OverlordDB.guildKeepSiegeWinAwards["2026092409:badlands"])
assert(not apply("2026092409", start), "Duplicate proof was reapplied")
assert(not apply("2026092412", start), "Invalid siege key accepted")
local enemyStart = at(15)
at(16)
assert(lb:ApplyGuildKeepDailyProofSync("badlands", "2026092415", "GC", enemyStart + 900,
    "Bravo", "Horde", 2, enemyStart, 0, "Bravo Tester",
    "Alpha", "Alliance", finish, "global"), "Afternoon recapture rejected")
assert(lb:ReconcileGuildKeepDailyAward("badlands", "2026092415"))
assert(OverlordDB.guildKeepSiegeWinAwards["2026092415:badlands"].guild == "Bravo")
assert(OverlordDB.guildKeepSiegeWinAwards["2026092403:badlands"].guild == "Alpha",
    "Afternoon recapture overwrote the morning victory")
assert(lb:ApplyGuildKeepDailyProofSync("mulgore", "20260922", "GC", legacy,
    "Legacy", "Horde", 3, legacy - 900, 0, "Legacy Tester", "", nil, 0, "global"))
assert(lb:ReconcileGuildKeepDailyAward("mulgore", "20260922"))
lb._guildKeepProofLedgerPrepared = false
lb:EnsureGuildKeepProofLedgerPrepared(true)
drain()
assert(OverlordDB.guildKeepCutoffSnapshots["2026092403"]
    and OverlordDB.guildKeepCutoffSnapshots["2026092409"], "Reload dropped same-day sieges")
assert(OverlordDB.guildKeepSiegeWinAwards["2026092403:badlands"]
    and OverlordDB.guildKeepSiegeWinAwards["2026092409:badlands"], "Reload lost siege victories")
assert(OverlordDB.guildKeepSiegeWinAwards["20260922:mulgore"], "Reload lost legacy daily victory")

-- Daily fronts and their popup must not start rotating four times a day.
Overlord.L.ZONE_NAMES = {}
assert(loadfile("Fronts.lua"))()
assert(loadfile("Popups.lua"))()
at(3)
local featured = assert(Overlord.Fronts:GetFeaturedFrontId())
Overlord.Popups:MarkFeaturedFrontShownToday()
for _, hour in ipairs({9, 15, 21}) do
    at(hour)
    assert(Overlord.Fronts:GetFeaturedFrontId() == featured, "Daily front rotated with siege")
    assert(Overlord.Popups:HasShownFeaturedFrontToday(), "Daily front popup repeated")
end
print("Forever siege schedule: four windows, realm timezones, midnight, legacy captures, per-siege awards and reload OK")
