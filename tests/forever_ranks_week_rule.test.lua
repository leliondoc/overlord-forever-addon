-- Overlord Rank, which weeks count (2.0): real Ranks.lua and RankLocales.lua.
-- The week's last 24 hours decide. A top 3 week and a week finished first ask that the
-- ranking was compared in full with another player during them; the wider tops (100, 25,
-- 10) only ask that this client was in game, outside instances, during them. A login
-- right after the reset is not "having played the day before". Nothing is sent.

local function check(cond, msg) if not cond then error(msg, 2) end end

Overlord = { L = {} }
GetLocale = function() return "enUS" end
dofile("RankLocales.lua")
local me = "Aldric Vane"
local printed = {}
local RESET, WEEK, DAY = 1791878400, 604800, 86400
local clock, weekStart = RESET - WEEK + 3600, RESET - WEEK
GetServerTime = function() return clock end
Overlord.GetCurrentCampaignStartTs = function() return weekStart end
Overlord.Sync = { GetPlayerFullName = function() return me end }
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
Overlord.Leaderboard = { IsLocalDisplayName = function(_, name) return name == me end }
Overlord.PlayerFaction = "Alliance"
OverlordDB = { leaderboard = { campaignStart = RESET - WEEK } }
-- The frame and the timer the rules ask the game for.
local events, tickers = nil, {}
CreateFrame = function()
    local frame = { RegisterEvent = function() end }
    frame.SetScript = function(_, _, fn) events = fn end
    return frame
end
C_Timer = { NewTicker = function(period, fn) tickers[#tickers + 1] = { period = period, fn = fn } end }
dofile("Ranks.lua")
local R = Overlord.Ranks
check(R.WEEK_STRICT_TOP == 3 and R.WEEK_FRESH_SEC == DAY, "the strict tops and the window are the ones the texts state")

R:CreditLocal("kills", 1)
local rec = OverlordDB.ranksByCharacter[me]
check(rec, "fixture: no record")
rec.k = 200000

-- A finished week: `above` allies with more kills than ours, enemies never count.
local function finishedWeek(above, kills)
    local bucket = { kills = { [me] = kills }, playerInfo = { [me] = { faction = "Alliance" } } }
    for i = 1, above do
        bucket.kills["Ally Above" .. i] = kills + i
        bucket.playerInfo["Ally Above" .. i] = { faction = "Alliance" }
    end
    for i = 1, 30 do
        bucket.kills["Enemy Above" .. i] = kills + 1000 + i
        bucket.playerInfo["Enemy Above" .. i] = { faction = "Horde" }
    end
    rec.we, rec.wk, rec.t, rec.lw = RESET - WEEK, kills, nil, nil
    printed = {}
    return { archiveEpoch = RESET - WEEK, resetEpoch = RESET, bucket = bucket }
end
local function closeWeek(marker)
    local session = R:BeginWeekClose(marker)
    if not session then return nil end
    for name, kills in pairs(marker.bucket.kills) do R:ProbeWeekRow(session, name, kills, marker.bucket.playerInfo) end
    R:FinishWeekClose(session)
    return session
end
local function weeks(top) return rec.t and rec.t[top] or nil end
local function compared(at) OverlordDB.ranksLadderSeenAt = at and { ["-"] = at } or nil end
local function online(a, p) OverlordDB.ranksOnlineAt = (a or p) and { ["-"] = { a = a, p = p } } or nil end
local NOT_COMPARED, FLOOR = Overlord.L.RANK_WEEK_NOT_COMPARED, Overlord.L.RANK_WEEK_FIRST_FLOOR:match("^[^%%]+")
check(type(NOT_COMPARED) == "string" and NOT_COMPARED ~= "", "the chat text of a top 3 week not compared is missing")
clock = RESET + 120

-- 1. Neither compared nor in game during the last day: the week does not count, in silence.
compared(nil); online(nil)
local week = finishedWeek(11, 500)
check(closeWeek(week) == nil and rec.t == nil and rec.lw == nil and #printed == 0, "nothing in the last day: no week, no word")

-- 2. In game during the last day, place 12: a top 25 and a top 100 week.
online(RESET - 3600)
week = finishedWeek(11, 500)
local session = closeWeek(week)
check(session and session.fresh == false, "in game in the last day: the week is judged")
check(weeks(100) == 1 and weeks(25) == 1 and weeks(10) == nil and weeks(3) == nil, "place 12: top 25 and top 100")
check(#printed == 1 and not printed[1]:find(NOT_COMPARED, 1, true), "place 12 needs no explanation: " .. tostring(printed[1]))
check(rec.lw == week.archiveEpoch, "the week is marked counted")

-- 3. In game only, place 2: the wide tops count, the top 3 does not, and the line says why.
week = finishedWeek(1, 500)
closeWeek(week)
check(weeks(100) == 1 and weeks(25) == 1 and weeks(10) == 1, "place 2, in game only: top 10, 25 and 100")
check(weeks(3) == nil and weeks(1) == nil, "place 2, ranking not compared: no top 3 week")
check(#printed == 1 and printed[1]:find(NOT_COMPARED, 1, true), "the line says what a top 3 week needs: " .. tostring(printed[1]))

-- 4. In game only, first with far more than the floor: no week finished first, one reason.
week = finishedWeek(0, 5000)
closeWeek(week)
check(weeks(10) == 1 and weeks(3) == nil and weeks(1) == nil, "first, ranking not compared: a top 10 week only")
check(#printed == 1 and printed[1]:find(NOT_COMPARED, 1, true) and not printed[1]:find(FLOOR, 1, true),
    "first, not compared: the reason is the comparison, not the kills: " .. tostring(printed[1]))

-- 5. Ranking compared in the last day: the three first places count again.
online(nil); compared(RESET - 600)
week = finishedWeek(1, 500)
session = closeWeek(week)
check(session and session.fresh == true and weeks(3) == 1 and weeks(10) == 1 and weeks(1) == nil, "compared, place 2: a top 3 week")
check(#printed == 1 and not printed[1]:find(NOT_COMPARED, 1, true), "nothing to explain when it counts")
week = finishedWeek(0, 5000)
closeWeek(week)
check(weeks(1) == 1 and weeks(3) == 1, "compared, first with the kills: a week finished first")
week = finishedWeek(0, 500)
closeWeek(week)
check(weeks(1) == nil and weeks(3) == 1 and printed[1]:find(FLOOR, 1, true) and not printed[1]:find(NOT_COMPARED, 1, true),
    "compared, first under the kill floor: the floor is the reason")

-- 6. The window is the week's last 24 hours, to the second, with no margin after its end.
compared(nil)
online(RESET - DAY)
check(closeWeek(finishedWeek(11, 500)) ~= nil, "in game exactly 24 hours before the end: counted")
online(RESET - DAY - 1)
check(closeWeek(finishedWeek(11, 500)) == nil, "one second earlier: too old")
online(RESET)
check(closeWeek(finishedWeek(11, 500)) ~= nil, "in game at the very end: counted")

-- 7. A login right after the reset is not having played the day before; the presence of
--    the week before is kept apart so that this login does not erase it either.
OverlordDB.ranksOnlineAt = nil
clock, weekStart = RESET - 2 * 3600, RESET - WEEK
R:NoteOnline()
local row = OverlordDB.ranksOnlineAt["-"]
check(row.a == RESET - 2 * 3600 and row.p == nil, "a presence is noted with its time")
clock = RESET - 3600
R:NoteOnline()
check(row.a == RESET - 3600 and row.p == nil, "the same week: only the latest is kept")
clock, weekStart = RESET + 300, RESET
R:NoteOnline()
check(row.a == RESET + 300 and row.p == RESET - 3600, "a new week: the last presence of the week before is kept apart")
check(closeWeek(finishedWeek(11, 500)) ~= nil and weeks(100) == 1, "played the last evening, logged in after the reset: counted")
OverlordDB.ranksOnlineAt = nil
R:NoteOnline()
check(closeWeek(finishedWeek(11, 500)) == nil, "only logged in after the reset: not counted")
online(RESET + 300, RESET - 3 * DAY)
check(closeWeek(finishedWeek(11, 500)) == nil, "last played three days before the end: not counted")

-- 8. The presence is read once per archive: a later one does not rescue a resumed close.
online(nil)
week = finishedWeek(11, 500)
check(closeWeek(week) == nil and week.rankPlayedAt == 1, "refused, and the reading kept on the archive")
online(RESET - 60)
check(closeWeek(week) == nil, "a presence written afterwards changes nothing for this archive")

-- 9. Never in an instance; a time in the future is worth nothing; one row per ranking.
OverlordDB.ranksOnlineAt = nil
Overlord.InstanceSuspended = true
R:NoteOnline()
Overlord.InstanceSuspended = false
IsInInstance = function() return true end
R:NoteOnline()
IsInInstance = nil
check(OverlordDB.ranksOnlineAt == nil, "nothing is noted in an instance")
clock, weekStart = RESET + 3600, RESET
online(clock + 10 * DAY)
R:NoteOnline()
row = OverlordDB.ranksOnlineAt["-"]
check(row.a == clock and row.p == nil, "a presence dated in the future is replaced and never kept as the week before's")
Overlord.GetCurrentLeaderboardSavedVarsPool = function() return "pve" end
R:NoteOnline()
check(OverlordDB.ranksOnlineAt.pve and OverlordDB.ranksOnlineAt.pve.a == clock and OverlordDB.ranksOnlineAt["-"] == row,
    "another ranking has its own presence")
Overlord.GetCurrentLeaderboardSavedVarsPool = nil
OverlordDB.ranksOnlineAt = "broken"
R:NoteOnline()
check(type(OverlordDB.ranksOnlineAt) == "table" and OverlordDB.ranksOnlineAt["-"].a == clock, "a damaged store is rebuilt")

-- 10. The game side: noted at login, every five minutes, and at logout. One timer.
check(type(events) == "function", "fixture: no event handler")
OverlordDB.ranksOnlineAt = nil
clock = RESET + 7200
events(nil, "PLAYER_LOGIN")
check(OverlordDB.ranksOnlineAt["-"].a == clock, "noted at login")
check(#tickers == 1 and tickers[1].period == R.ONLINE_STAMP_SEC and R.ONLINE_STAMP_SEC == 300, "one five-minute timer")
events(nil, "PLAYER_LOGIN")
check(#tickers == 1, "the timer is never doubled")
clock = clock + 300
tickers[1].fn()
check(OverlordDB.ranksOnlineAt["-"].a == clock, "noted by the timer")
clock = clock + 77
events(nil, "PLAYER_LOGOUT")
check(OverlordDB.ranksOnlineAt["-"].a == clock, "noted at logout")
check(rec.s ~= nil and R:IsSealed(rec, me), "and the record is still sealed for the save")

-- 11. Damaged data never raises: an archive whose player details are not a table, and a
--     set-aside list far too long (trimmed in one pass, the newest kept).
compared(RESET - 600)
week = finishedWeek(2, 500)
session = R:BeginWeekClose(week)
check(session, "fixture: the week must be judged")
for name, kills in pairs(week.bucket.kills) do R:ProbeWeekRow(session, name, kills, 7) end
check(session.probes[1].above == 0, "player details that are not a table count nobody above")
local long = {}
for i = 1, 500 do long[i] = { n = "Old " .. i, a = i, r = {} } end
OverlordDB.ranksSetAside = long
OverlordDB.ranksByCharacter["Broken One"] = { k = 5, s = 1 }
local keepName = me
me = "Broken One"
check(R:GetRecord(false) == nil, "a record with a wrong seal is set aside")
me = keepName
check(#long == R.SET_ASIDE_MAX and long[#long].n == "Broken One" and long[1].n == "Old 494",
    "the set-aside list keeps its newest entries: " .. #long .. ", " .. tostring(long[1] and long[1].n))

print("Forever ranks week rule: top 3 and first need the ranking compared, the wider tops only a presence in the last day OK")
