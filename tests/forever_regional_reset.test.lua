-- 2.1.0: the game is out, each region runs its own campaign week: it starts and resets at
-- the region's weekly reset (Americas Tuesday 15:00 UTC, Europe Wednesday 04:00 UTC, Korea
-- and Taiwan Wednesday 23:00 UTC). The same calendar computation as on the beta, so every
-- client of a region holds the same instant, to the second.
local TUE_08 = 1793692800 -- Tuesday 2026-11-03 08:00 UTC, the beta's anchor that week
local LAUNCH = TUE_08 + 39 * 3600 -- Wednesday 2026-11-04 23:00 UTC, every region at once
local HOUR, WEEK = 3600, 7 * 86400
local START = { US = TUE_08 + 7 * HOUR, EU = TUE_08 + 20 * HOUR, KR = LAUNCH, TW = LAUNCH }
local CAMPAIGN_ID = { US = 20261103, EU = 20261104, KR = 20261104, TW = 20261104 }

local now, regionName, scheduled, resets, mapResets
function time() return now end
function GetServerTime() return now end
function GetTime() return now end
function date(fmt, ts) return os.date(fmt, ts or now) end
-- Region ids of the real client are not trusted: only the name counts.
function GetCurrentRegion() return 93 end
function GetCurrentRegionName() return regionName end
function GetLocale() return "frFR" end
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end
C_Timer = { After = function(delay) scheduled = delay end }

local function boot(name, at, db, api)
    regionName, now, resets, mapResets = name, at, 0, 0
    C_DateAndTime = api
    OverlordDB = db or {}
    Overlord = { L = { WEEKLY_RESET = "weekly reset", DATE_FORMAT = "%d/%m" } }
    assert(loadfile("Core.lua"))()
    Overlord.GetCurrentLeaderboardSavedVarsPool = function() return "global" end
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
    return Overlord
end

for region, start in pairs(START) do
    -- 1. The first campaign: launch night, an empty save, exactly one start.
    local o = boot(region, LAUNCH + 60)
    assert(o:GetCurrentCampaignStartTs() == start, region .. ": wrong campaign start at the launch")
    assert(o:TimestampToCampaignId(start) == CAMPAIGN_ID[region], region .. ": campaign id")
    o:CheckWeeklyReset()
    assert(resets == 1 and mapResets == 1, region .. ": a fresh save did not start the campaign")
    o.Leaderboard:ResumePendingWeeklyArchive()
    assert(OverlordDB.lastResetTimestamp == start, region .. ": first week badly stamped")
    assert(OverlordDB.leaderboard.campaignStart == start, region .. ": first bucket badly stamped")
    for _ = 1, 3 do o:CheckWeeklyReset() end
    assert(resets == 1 and mapResets == 1, region .. ": the first campaign started twice")

    -- 2. Nothing happens anywhere in the week, not at the beta's Tuesday either.
    local nextReset = start + WEEK
    for hours = 1, 7 * 24 - 1 do
        local at = start + hours * HOUR
        if at >= LAUNCH then
            now = at
            assert(o:GetCurrentCampaignStartTs() == start, region .. ": week moved at +" .. hours .. "h")
            o:CheckWeeklyReset()
        end
    end
    assert(resets == 1 and mapResets == 1, region .. ": a reset inside the week")
    now = TUE_08 + WEEK
    if nextReset > now then
        o:CheckWeeklyReset()
        assert(resets == 1, region .. ": reset on the beta's Tuesday")
    end

    -- 3. The next timer aims at the region's own reset.
    now = LAUNCH + 60
    o:ScheduleNextReset()
    assert(scheduled == nextReset - now, region .. ": next reset badly scheduled")

    -- 4. The true reset, once, to the second.
    now = nextReset - 1
    o:CheckWeeklyReset()
    assert(resets == 1, region .. ": reset one second early")
    now = nextReset
    o:CheckWeeklyReset()
    assert(resets == 2 and mapResets == 2 and OverlordDB.lastResetTimestamp == nextReset,
        region .. ": the true reset did not run")
    o.Leaderboard:ResumePendingWeeklyArchive()
    for _ = 1, 3 do o:CheckWeeklyReset() end
    assert(resets == 2 and mapResets == 2, region .. ": the true reset ran twice")

    -- 5. Same instant whatever the moment a client computes it (no cache: a fresh client).
    for _, at in ipairs({ start, start + 1, start + 3 * 86400, start + WEEK - 1 }) do
        assert(boot(region, at):GetLastResetTimestamp() == start, region .. ": two clients, two instants")
    end
    if start > TUE_08 then
        assert(boot(region, start - 1):GetLastResetTimestamp() == start - WEEK,
            region .. ": a second before its reset, the region is still in the week before")
    end

    -- 6. A name known: the calendar decides, the client's answer is only shown.
    local odd = { GetSecondsUntilWeeklyReset = function() return 3600 end }
    o = boot(region, LAUNCH + 60, nil, odd)
    assert(o:GetLastResetTimestamp() == start, region .. ": the client's answer moved the week")
    assert(o:DescribeCampaignWeek():find("the game says", 1, true), o:DescribeCampaignWeek())
    local exact = { GetSecondsUntilWeeklyReset = function() return start + WEEK - now end }
    o = boot(region, LAUNCH + 60, nil, exact)
    assert(o:DescribeCampaignWeek():find("the game agrees", 1, true), o:DescribeCampaignWeek())
    o = boot(region, LAUNCH + 60)
    assert(o:DescribeCampaignWeek():find("the game gave no answer", 1, true), o:DescribeCampaignWeek())
end

-- 7. A save of the beta: one reset at the first login, then quiet.
local o = boot("EU", LAUNCH + 60, { lastResetTimestamp = 1792483200, leaderboard = { kills = { Old = 9 } } })
o:CheckWeeklyReset()
o.Leaderboard:ResumePendingWeeklyArchive()
o:CheckWeeklyReset()
assert(resets == 1 and mapResets == 1 and OverlordDB.lastResetTimestamp == START.EU, "beta save at the first login")
assert(OverlordDB.leaderboard.kills.Old == nil, "the beta's kills survived the launch")

-- 8. A save of 2.0.8 played this week (the beta's Tuesday): updating never wipes the week,
-- and the next true reset still runs, once. Asia is further than the tolerance: its week
-- starts with the launch itself, so a save from before the launch holds nothing to keep.
-- Updating there after the launch starts the week again: the release notes say so.
for _, region in ipairs({ "US", "EU" }) do
    local score = { ["Guild Member"] = 12 }
    o = boot(region, LAUNCH + 86400, { lastResetTimestamp = TUE_08, leaderboardResetEpoch = TUE_08,
        leaderboard = { kills = score, campaignStart = TUE_08 }, leaderboardsByPool = {} })
    o:CheckWeeklyReset()
    assert(resets == 0 and mapResets == 0 and OverlordDB.leaderboard.kills == score,
        region .. ": updating from 2.0.8 wiped the week")
    now = START[region] + WEEK - 1
    o:CheckWeeklyReset()
    assert(resets == 0, region .. ": updated save reset before the region's reset")
    now = START[region] + WEEK
    o:CheckWeeklyReset()
    o.Leaderboard:ResumePendingWeeklyArchive()
    o:CheckWeeklyReset()
    assert(resets == 1 and mapResets == 1, region .. ": updated save missed the true reset")
end

-- 9. No name: the client's weekly reset, the same for all despite its one-second jitter.
for _, jitter in ipairs({ -1, 0, 1 }) do
    local api = { GetSecondsUntilWeeklyReset = function() return START.EU + WEEK - now + jitter end }
    for _, name in ipairs({ "", false }) do
        o = boot(name or nil, LAUNCH + 60, nil, api)
        assert(o:GetLastResetTimestamp() == START.EU, "no name: the client's reset was not used")
    end
end
assert(boot("CN", LAUNCH + 60, nil,
    { GetSecondsUntilWeeklyReset = function() return START.US + WEEK - now end }):GetLastResetTimestamp() == START.US,
    "a region without a rule follows the client")

-- 10. No name and no usable answer: exactly the beta's calendar, at any time of the week.
for _, bad in ipairs({ 0, -5, 2 * WEEK }) do
    local api = { GetSecondsUntilWeeklyReset = function() return bad end }
    assert(boot("", LAUNCH + 60, nil, api):GetLastResetTimestamp() == TUE_08, "bad answer " .. bad)
end
assert(boot("", LAUNCH + 60, nil, { GetSecondsUntilWeeklyReset = function() error("not yet") end })
    :GetLastResetTimestamp() == TUE_08, "an API error must not stop the login")
for hours = 0, 7 * 24 - 1, 5 do
    local at = TUE_08 + hours * HOUR
    assert(boot(nil, at):GetLastResetTimestamp() == TUE_08, "beta calendar moved at +" .. hours .. "h")
end
assert(boot(nil, TUE_08 - 1):GetLastResetTimestamp() == TUE_08 - WEEK)

-- 11. A 2.0.8 client's Tuesday certificate never gives a capital back before the region's reset.
for region, start in pairs(START) do
    o = boot(region, TUE_08 + WEEK + HOUR)
    o.Zones = { GetBaseZoneFixedOwner = function(_, id) return id == "capital" and "Horde" or nil end }
    local anchor = TUE_08 + WEEK
    assert(o:IsBetaWeekCapitalCertificate("capital", "Horde", anchor), region .. ": certificate accepted")
    assert(o:IsBetaWeekCapitalCertificate("capital", "Horde", tostring(anchor)), region .. ": stamp as a string")
    assert(not o:IsBetaWeekCapitalCertificate("capital", "Alliance", anchor), region .. ": a conquest is no certificate")
    assert(not o:IsBetaWeekCapitalCertificate("capital", "Horde", anchor + 1), region .. ": a capture a second later")
    assert(not o:IsBetaWeekCapitalCertificate("point", nil, anchor), region .. ": an ordinary point")
    assert(not o:IsBetaWeekCapitalCertificate("capital", "Horde", start + WEEK), region .. ": the region's own certificate")
end
-- The beta's calendar (no region name): the old behaviour, nothing refused.
o = boot(nil, TUE_08 + WEEK + HOUR)
o.Zones = { GetBaseZoneFixedOwner = function() return "Horde" end }
assert(not o:IsBetaWeekCapitalCertificate("capital", "Horde", TUE_08 + WEEK), "a client on the beta's week refused its own")

-- The map receiver asks it (a refused entry, not a refused map).
local sync = assert(io.open("Sync.lua", "rb")):read("*a")
assert(sync:find("or Overlord:IsBetaWeekCapitalCertificate(zoneId, owner, ct)) then", 1, true),
    "the map receiver no longer refuses a 2.0.8 Tuesday certificate")

-- What a 2.0.8 client dates between its week start and ours (its neutral zones are dated at
-- its week start) refuses that entry, not its whole map. Anything older is an old map.
for region, start in pairs(START) do
    o = boot(region, LAUNCH + HOUR)
    assert(o:IsStampInBetaWeekGap(TUE_08), region .. ": a 2.0.8 week start")
    assert(o:IsStampInBetaWeekGap(tostring(TUE_08)), region .. ": stamp as a string")
    assert(o:IsStampInBetaWeekGap(start - 1), region .. ": the last second before our week")
    assert(not o:IsStampInBetaWeekGap(start), region .. ": our own week start")
    assert(not o:IsStampInBetaWeekGap(start + 60), region .. ": a capture of our week")
    assert(not o:IsStampInBetaWeekGap(TUE_08 - 1), region .. ": older than the gap")
    assert(not o:IsStampInBetaWeekGap(0) and not o:IsStampInBetaWeekGap(nil), region .. ": no date")
end
-- A week later, after each region's reset: the same gap, a week on.
for region, start in pairs(START) do
    o = boot(region, start + WEEK + HOUR)
    assert(o:IsStampInBetaWeekGap(TUE_08 + WEEK), region .. ": next 2.0.8 week start")
    assert(o:IsStampInBetaWeekGap(start + WEEK - 1), region .. ": a capture just before the reset")
    assert(not o:IsStampInBetaWeekGap(TUE_08 + WEEK - 1), region .. ": last week's map stays an old map")
end
-- The beta's calendar (no region name): no gap.
o = boot(nil, LAUNCH + HOUR)
assert(not o:IsStampInBetaWeekGap(TUE_08 - 1), "the beta's calendar has no gap")
assert(not o:IsStampInBetaWeekGap(TUE_08), "the beta's calendar has no gap")
assert(sync:find("if not validEntry and Overlord:IsStampInBetaWeekGap(ts) then", 1, true),
    "the map receiver refuses a 2.0.8 map whole again")

-- 12. The other weekly clocks of the addon see one week per region.
local WEEK_REF = 1578384000 -- RankProof.WEEK_REF
local function weekIndex(start) return math.floor((start - WEEK_REF) / WEEK + 0.5) end
for region, start in pairs(START) do
    assert(weekIndex(start) == weekIndex(TUE_08), region .. ": rank week of the launch")
    assert(weekIndex(start + WEEK) == weekIndex(TUE_08) + 1, region .. ": next rank week")
    assert(start >= TUE_08, region .. ": the launch week must be after the launch seal's date")
end

print("Regional reset: campaign start, week and true reset per region, 2.0.8 and beta saves, no-name clients OK")
