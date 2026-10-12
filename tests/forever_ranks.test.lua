-- Overlord Rank: real Ranks.lua, RankLocales.lua and RanksUI.lua on stub frames.
-- Glory is credited by this client's own kills and captures only; a record is born
-- empty and reads nothing from the ladder; nothing is credited in an instance.
-- Ranks 11 to 15 ask for weeks finished at the top of the faction's ranking (the last
-- one, Overlord, for more glory and weeks finished first): at the
-- week's close the kills this client counted that week are compared with the ladder's
-- rows, once, and only if the ranking was up to date. Our own ladder row (which
-- another client can inflate) is never the score.
-- The character sheet tab writes nothing into Blizzard's tables, hides and restores
-- the open panel, and repaints nothing when nothing changed.

local function check(cond, msg) if not cond then error(msg, 2) end end

-- ---------------------------------------------------------------- texts, 7 languages
local LANGS = { "enUS", "frFR", "esES", "deDE", "ruRU", "ptBR", "zhCN" }
local reference
for _, locale in ipairs(LANGS) do
    Overlord = { L = {} }
    GetLocale = function() return locale end
    dofile("RankLocales.lua")
    local L = Overlord.L
    if not reference then reference = L end
    for key, english in pairs(reference) do
        check(type(L[key]) == "string" and L[key] ~= "", locale .. " misses " .. key)
        local _, wanted = english:gsub("%%[ds]", "")
        local _, got = L[key]:gsub("%%[ds]", "")
        check(wanted == got, locale .. " format slots differ on " .. key)
    end
    for rank = 0, 15 do check(L["RANK_NAME_" .. rank], locale .. " misses rank " .. rank) end
    check(L.RANK_NAME_15 == "Overlord", locale .. ": the last rank keeps the addon's name")
    -- A feat's line is drawn on one line of the Hall of Fame card and cut beyond it.
    for label, text in pairs({
        glory = string.format(L.RANK_FEAT_GLORY, "100,000"),
        top = string.format(L.RANK_FEAT_TOP, 3, 100),
        first = string.format(L.RANK_FEAT_FIRST, "150,000", 5),
    }) do
        local _, letters = text:gsub("[^\128-\191]", "")
        check(letters <= 62, locale .. ": the " .. label .. " feat line is too long for its card (" .. letters .. ")")
    end
    check(L.RANK_TIP_TOP:find("%f[%d]100%f[%D]"), locale .. ": the tooltip must give the week's kill floor")
    local seen = {}
    for rank = 0, 15 do
        local name = L["RANK_NAME_" .. rank]
        check(not seen[name], locale .. " uses a rank name twice: " .. name)
        seen[name] = true
    end
end

-- ---------------------------------------------------------------- rules
Overlord = { L = {} }
GetLocale = function() return "enUS" end
dofile("RankLocales.lua")
local me = "Aldric Vane"
local printed = {}
Overlord.Sync = {
    GetPlayerFullName = function() return me end,
    CanonicalForeverName = function(_, name) return name end,
}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
Overlord.Leaderboard = { kills = {}, captureCount = {} }
Overlord.PlayerFaction = "Alliance"
OverlordDB = {}
dofile("Ranks.lua")
local R = Overlord.Ranks

check(#R.TIERS == 15 and R.MAX_RANK == 15, "fifteen ranks")
check(R.WEEK_MIN_KILLS == 100, "the kill floor printed in the seven languages is the one in the rules")
local icons, previous, previousTop = {}, 0, math.huge
for rank, tier in ipairs(R.TIERS) do
    if rank <= 10 then
        check(tier.glory > previous and not tier.top, "glory alone rises up to rank 10: " .. rank)
    else
        check(tier.glory == previous or rank == 15, "no more glory asked from rank 11 to 14: " .. rank)
        check(tier.top < previousTop and tier.weeks > 0, "a narrower top at each rank: " .. rank)
        previousTop = tier.top
    end
    previous = tier.glory
    check(not icons[tier.icon], "one badge per rank: " .. tier.icon)
    icons[tier.icon] = true
end
check(#R.PLACE_TIERS == 5 and R.PLACE_TIERS[1] == R.TIERS[11].top and R.PLACE_TIERS[4] == R.TIERS[14].top
    and R.PLACE_TIERS[5] == R.TIERS[15].top, "the place tiers are the ones the ranks ask for")
check(R.TIERS[15].top == 1 and R.TIERS[15].weeks == 5 and R.TIERS[15].icon == "prestige-icon-8-4"
    and R.TIERS[15].glory > R.TIERS[14].glory,
    "the last rank, Overlord: more glory and five weeks finished first, under the prestige diamond")
check(R.WEEK_FIRST_MIN_KILLS > R.WEEK_MIN_KILLS, "a week first asks for more kills than a week that merely counts")
local TEN = R.TIERS[10].glory
check(R:GetRankFor(0) == 0 and R:GetRankFor(14) == 0, "unranked below the first threshold")
check(R:GetRankFor(15) == 1 and R:GetRankFor(R.TIERS[2].glory - 1) == 1, "rank 1 from 15")
check(R:GetRankFor(TEN - 1) == 9 and R:GetRankFor(TEN) == 10, "rank 10 by glory")
check(R:GetRankFor(10 ^ 9) == 10, "glory alone never passes rank 10")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 2 } }) == 10, "two weeks are not three")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 3 } }) == 11, "three top 100 weeks: rank 11")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 9, [25] = 3 } }) == 12, "three top 25 weeks: rank 12")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 9, [25] = 2, [10] = 3, [3] = 3 } }) == 11, "ranks come in order")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3 } }) == 14, "three top 3 weeks: rank 14")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3, [1] = 4 } }) == 14, "four weeks first are not five")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 5, [25] = 5, [10] = 5, [3] = 5, [1] = 5 } }) == 15, "five weeks first: Overlord")
check(R:GetRankFor(10 ^ 9, { t = { [100] = 3, [25] = 3, [10] = 3, [3] = 2, [1] = 5 } }) == 13, "Overlord comes after rank 14")
check(R:GetRankFor(R.TIERS[15].glory - 1, { t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3, [1] = 5 } }) == 14, "and asks for its own glory")
check(R.GetFirstStreak == nil and R.GetTierWeeks == nil, "weeks first add up, they need not follow each other")
check(R:GetRankFor(TEN - 1, { t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3 } }) == 9, "weeks never replace the glory")
check(R:GetGlory(10, 2) == 10 * R.GLORY_PER_KILL + 2 * R.GLORY_PER_CAPTURE, "a capture weighs more")

-- Reading never creates a record, whatever the ladder holds.
Overlord.Leaderboard.kills[me] = 99999
Overlord.Leaderboard.captureCount[me] = 499
Overlord.IsInitialized = true
local s = R:GetState()
check(s.rank == 0 and s.glory == 0 and s.nextAt == 15 and s.progress == 0, "empty state")
check(OverlordDB.ranksByCharacter == nil, "a read stores nothing")
check(R:GetState() == s, "the state table is reused")

-- A record is born empty: our ladder row, which other clients can raise, gives nothing.
R:CreditLocal("kills", 1)
local rec = OverlordDB.ranksByCharacter[me]
check(rec.k == 1 and rec.c == 0, "born with the credit alone, nothing from the ladder row")
check(rec.f == "Alliance", "the character's own faction is kept on the record")
R:CreditLocal("kills", 14)
check(rec.k == 15 and R:GetState().rank == 1, "kills add up")
check(#printed == 1 and printed[1]:find(Overlord.L.RANK_NAME_1, 1, true), "one line on a new rank")
check(printed[1]:find("prestige%-icon%-1:16"), "with the rank badge")
R:CreditLocal("kills", 5)
check(rec.k == 20 and #printed == 1, "no announcement without a new rank")
local captures = math.ceil((R.TIERS[2].glory - 20) / R.GLORY_PER_CAPTURE)
local withCaptures = 20 + captures * R.GLORY_PER_CAPTURE
R:CreditLocal("captures", captures)
check(rec.c == captures and R:GetState().glory == withCaptures and R:GetState().rank == 2, "captures add up")
check(#printed == 2 and printed[2]:find(Overlord.L.RANK_NAME_2, 1, true), "the second rank is announced")

-- Refused: other fields, empty amounts, anything in an instance.
R:CreditLocal("kills", 0); R:CreditLocal("kills", -5); R:CreditLocal("gold", 50); R:CreditLocal("kills", "x")
Overlord.InstanceSuspended = true
R:CreditLocal("kills", 1000)
Overlord.InstanceSuspended = false
check(rec.k == 20 and rec.c == captures, "nothing credited by a bad call or in an instance")
check(R:GetState().glory == withCaptures, "glory never follows the ladder")

-- The week's own counter: kills only, started again when the ladder opens a new week.
check(rec.we == nil and rec.wk == nil, "no week counted without a ladder week")
OverlordDB.leaderboard = { campaignStart = 5000000 }
R:CreditLocal("kills", 3)
R:CreditLocal("captures", 1)
check(rec.we == 5000000 and rec.wk == 3, "three kills this week, captures apart")
R:CreditLocal("kills", 2)
check(rec.wk == 5, "the week adds up")
OverlordDB.leaderboard.campaignStart = 5604800
R:CreditLocal("kills", 4)
check(rec.we == 5604800 and rec.wk == 4 and rec.k == 29, "a new week starts its own count, the glory stays")
-- The same week re-anchored a few hours away (an old save being repaired) keeps its count.
OverlordDB.leaderboard.campaignStart = 5604800 + 3 * 3600
R:CreditLocal("kills", 1)
check(rec.we == 5604800 + 3 * 3600 and rec.wk == 5, "a week moved by three hours is the same week")
OverlordDB.leaderboard = nil

-- One record per character; no name, no record.
me = "Brann Holt"
check(R:GetState().glory == 0, "another character starts from nothing")
me = ""
R:CreditLocal("kills", 5)
local count = 0
for _ in pairs(OverlordDB.ranksByCharacter) do count = count + 1 end
check(count == 1, "no record without a name")
me = "Aldric Vane"

-- Progress and the top of the ladder.
local two, three = R.TIERS[2].glory, R.TIERS[3].glory
rec.k, rec.c = (two + three) / 2, 0
s = R:GetState()
check(s.rank == 2 and s.floor == two and s.nextAt == three and s.progress == 0.5, "progress inside a rank")
rec.k = TEN * 6
s = R:GetState()
check(s.rank == 10 and s.nextAt == nil and s.gateTop == 100 and s.gateNeed == 3 and s.gateHave == 0
    and s.progress == 0, "beyond rank 10 the next rank asks for weeks")
rec.t = { [100] = 3, [25] = 1 }
s = R:GetState()
check(s.rank == 11 and s.gateTop == 25 and s.gateHave == 1 and s.progress == 1 / 3, "weeks toward rank 12")
rec.t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3, [1] = 1 }
s = R:GetState()
check(s.rank == 14 and s.gateTop == 1 and s.gateNeed == 5 and s.gateHave == 1 and s.progress == 1 / 5,
    "from rank 14, weeks finished first toward Overlord")
rec.k = (R.TIERS[14].glory + R.TIERS[15].glory) / 2
s = R:GetState()
check(s.rank == 14 and s.nextAt == R.TIERS[15].glory and s.gateTop == nil and s.progress == 0.5,
    "but first the glory Overlord asks for")
rec.k = TEN * 6
rec.t[1] = 5
s = R:GetState()
check(s.rank == 15 and s.nextAt == nil and s.gateTop == nil and s.progress == 1, "top rank is full")
rec.t = nil
check(R.SeasonOverlords == nil and R.GetOverlordSeason == nil and s.overlordSeason == nil,
    "no hand-kept list: Overlord is earned like any other rank")

-- ---------------------------------------------------------------- week close
-- The finished week, detached by the ladder: allies above us, enemies and weaker allies
-- around, a tie, a row without faction, and our own short-name row.
local RESET = 1791878400
local WEEK = 604800
local function finishedWeek(alliesAbove, index)
    index = index or 0
    local bucket = { kills = { [me] = 500, ["Aldric"] = 900 }, captureCount = {},
        playerInfo = { [me] = { faction = "Alliance" }, ["Aldric"] = { faction = "Alliance" } } }
    for i = 1, alliesAbove do
        bucket.kills["Ally Above" .. i] = 500 + i
        bucket.playerInfo["Ally Above" .. i] = { faction = "Alliance" }
    end
    for i = 1, 40 do
        bucket.kills["Enemy Above" .. i] = 5000 + i
        bucket.playerInfo["Enemy Above" .. i] = { faction = "Horde" }
        bucket.kills["Ally Below" .. i] = i
        bucket.playerInfo["Ally Below" .. i] = { faction = "Alliance" }
    end
    bucket.kills["Ally Level"] = 500
    bucket.playerInfo["Ally Level"] = { faction = "Alliance" }
    bucket.kills["No Faction"] = 9000
    local marker = { archiveEpoch = RESET + (index - 1) * WEEK, resetEpoch = RESET + index * WEEK, bucket = bucket }
    OverlordDB.ranksLadderSeenAt = { ["-"] = marker.resetEpoch - 600 }
    return marker
end
-- The kills this client counted for a character during that week.
local function played(record, marker, kills)
    record.we, record.wk = marker.archiveEpoch, kills
end
local function closeWeek(marker)
    local session = R:BeginWeekClose(marker)
    if not session then return nil end
    for name, kills in pairs(marker.bucket.kills) do
        R:ProbeWeekRow(session, name, kills, marker.bucket.playerInfo)
    end
    R:FinishWeekClose(session)
    for _, probe in ipairs(session.probes) do
        if probe.name == me then return probe, session end
    end
    return nil, session
end
Overlord.Leaderboard.IsLocalDisplayName = function(_, name) return name == me or name == "Aldric" end
rec.k, rec.c, rec.t, rec.lw, rec.f = TEN - 1000, 0, nil, nil, "Alliance"
-- A record of another character of the account, born the way the addon makes one (a
-- record written by hand carries no seal and would be set aside), then given its values.
local function makeRecord(name, fields)
    local keep = me
    me = name
    R:CreditLocal("kills", 1)
    me = keep
    local record = OverlordDB.ranksByCharacter[name]
    for key, value in pairs(fields) do record[key] = value end
    return record
end
printed = {}

-- The ranking's kills must have been compared in full in the week's last day. The date
-- comes from the catch-up alone (the badge's own mark, fullAt, is hardly ever there on
-- a busy ranking and is not read).
local week = finishedWeek(11)
played(rec, week, 500)
OverlordDB.ranksLadderSeenAt = nil
check(closeWeek(week) == nil, "no exchange, no placement")
week = finishedWeek(11)
OverlordDB.ranksLadderSeenAt = nil
OverlordDB.leaderboardHistoryCatchupAck = { at = RESET - 600, fullAt = RESET - 600 }
check(closeWeek(week) == nil, "the badge's mark is not the ranks' date")
OverlordDB.leaderboardHistoryCatchupAck = nil
week = finishedWeek(11)
OverlordDB.ranksLadderSeenAt = nil
R:NoteLadderSeen(nil)
check(OverlordDB.ranksLadderSeenAt == nil and R:GetLadderSeenAt() == 0, "a partial comparison leaves no date")
R:NoteLadderSeen(RESET - 5 * 3600)
R:NoteLadderSeen(RESET - 9 * 3600)
check(R:GetLadderSeenAt() == RESET - 5 * 3600, "a whole comparison leaves its date, which never goes back")
R:NoteLadderSeen("x")
R:NoteLadderSeen(-5)
R:NoteLadderSeen(math.huge)
check(R:GetLadderSeenAt() == RESET - 5 * 3600, "and nothing else is a date")
-- One date per ranking: the save is per account, the rankings are per realm rule. A
-- character of another rule that logs in after the reset must not date ours.
Overlord.GetCurrentLeaderboardSavedVarsPool = function() return "pve" end
check(R:GetLadderSeenAt() == 0, "another ranking has its own date")
R:NoteLadderSeen(RESET + 4 * 3600)
check(R:GetLadderSeenAt() == RESET + 4 * 3600, "noted for that ranking")
Overlord.GetCurrentLeaderboardSavedVarsPool = nil
check(R:GetLadderSeenAt() == RESET - 5 * 3600, "and ours is untouched")
check(closeWeek(week) and rec.t and rec.t[100] == 1, "compared in full in the last day: counted")
rec.t, rec.lw = nil, nil
printed = {}
week = finishedWeek(11)
OverlordDB.ranksLadderSeenAt = { ["-"] = RESET - 30 * 3600 }
check(closeWeek(week) == nil and rec.t == nil, "seen up to date the day before the last: too old")
week = finishedWeek(11)
OverlordDB.ranksLadderSeenAt = { ["-"] = RESET - 20 * 3600 }
check(closeWeek(week) and rec.t and rec.t[100] == 1, "seen up to date in the last day: counted")
rec.t, rec.lw = nil, nil
printed = {}
week = finishedWeek(11)
OverlordDB.ranksLadderSeenAt = { ["-"] = RESET - 3 * 86400 }
check(closeWeek(week) == nil and week.rankSyncedAt == RESET - 3 * 86400, "three days old: refused, the stamp kept")
OverlordDB.ranksLadderSeenAt = { ["-"] = RESET - 60 }
check(closeWeek(week) == nil, "a later stamp does not rescue a resumed archive")
week = finishedWeek(11)
OverlordDB.ranksLadderSeenAt = { ["-"] = RESET + 1800 }
check(closeWeek(week) == nil, "a stamp half an hour into the new week is refused")
-- Not a week: a few hours. And a week closed three resets late (an absence) with a
-- ranking seen up to date only at that late login: the view of the played week was not.
local long, short = finishedWeek(11), finishedWeek(11)
long.archiveEpoch, short.archiveEpoch = RESET - 21 * 86400, RESET - 3600
played(rec, long, 500)
check(closeWeek(long) == nil, "a late close with a stamp from the late login is refused")
played(rec, short, 500)
check(closeWeek(short) == nil, "a few hours are not a week")
check(rec.t == nil and rec.lw == nil, "nothing stored for a week that cannot count")
-- A week that does not count says nothing in the chat (the author's rule: nothing that
-- nags players; the bar's tooltip shows when the ranking was last compared): not for
-- a ranking compared too long ago, not for too few kills, at any rank.
check(#printed == 0, "a week that does not count spoke: " .. table.concat(printed, " / "))
week = finishedWeek(11)
played(rec, week, 500)
OverlordDB.ranksLadderSeenAt = nil
check(closeWeek(week) == nil and #printed == 0 and week.rankTold == nil, "a ranking not compared in time: silence")
local gloryBelowTen = rec.k
rec.k = TEN
week = finishedWeek(11)
played(rec, week, 40)
check(closeWeek(week) == nil and #printed == 0, "too few kills, even from rank 10: silence")
rec.k = gloryBelowTen
printed = {}

-- The score is what this client counted, in that week, in that ladder.
week = finishedWeek(11)
rec.we, rec.wk = nil, nil
check(closeWeek(week) == nil, "no kill counted here that week, no placement")
played(rec, week, R.WEEK_MIN_KILLS - 1)
check(closeWeek(week) == nil, "a handful of kills is not a ranked week")
played(rec, week, 500)
rec.we = rec.we - 3 * 86400
check(closeWeek(week) == nil, "a count from another week is not this week's")
played(rec, week, 500)
week.bucket.kills[me] = nil
check(closeWeek(week) == nil, "no row in this ladder: another ruleset's week")
check(rec.t == nil and rec.lw == nil, "still nothing stored")

-- Twelfth of the faction, told once. Our own row raised by somebody else changes
-- nothing, and the faction is the character's, not the row's.
week = finishedWeek(11)
played(rec, week, 500)
week.bucket.kills[me] = 99999
week.bucket.playerInfo[me].faction = "Horde"
local probe, session = closeWeek(week)
check(probe and probe.kills == 500 and probe.faction == "Alliance", "local count and own faction")
check(probe.above == 11, "eleven allies above, got " .. tostring(probe.above))
check(rec.t[100] == 1 and rec.t[25] == 1 and rec.t[10] == nil and rec.t[3] == nil, "twelfth: top 100 and top 25")
check(rec.lw == week.archiveEpoch, "the week is marked counted")
check(#printed == 1 and printed[1]:find("12") and printed[1]:find("25"), "one line with the place")
check(rec.k == TEN - 1000, "a placement never changes the glory")
-- The same week again (archive resumed after a cut) is never counted twice.
check(closeWeek(finishedWeek(11)) == nil, "a counted week is not probed again")
R:FinishWeekClose(session)
check(rec.t[100] == 1 and rec.t[25] == 1 and #printed == 1, "a second finish adds nothing")
-- The same week under a slightly different stamp (restored, archived again): once.
local again = finishedWeek(0)
again.archiveEpoch, again.resetEpoch = again.archiveEpoch + 7200, again.resetEpoch + 7200
played(rec, again, 500)
OverlordDB.ranksLadderSeenAt = { ["-"] = again.resetEpoch - 60 }
check(closeWeek(again) == nil and rec.t[3] == nil, "two counted weeks are at least six days apart")

-- Beyond the widest tier: counted (never probed again), nothing credited, no line.
week = finishedWeek(150, 1)
played(rec, week, 500)
probe = closeWeek(week)
check(probe and probe.above == 100, "the count stops at the widest tier")
check(rec.t[100] == 1 and rec.lw == week.archiveEpoch and #printed == 1, "outside the top 100: nothing credited")

-- First of the faction, with the glory of rank 10: tiers add up week after week and
-- the third week opens the ranks it pays for, announced once.
rec.k = TEN + 5
week = finishedWeek(0, 2)
played(rec, week, 500)
closeWeek(week)
check(rec.t[100] == 2 and rec.t[3] == 1 and R:GetState().rank == 10, "first of the faction counts for every tier")
printed = {}
week = finishedWeek(0, 3)
played(rec, week, 500)
closeWeek(week)
-- (The twelfth place counted for the top 25 too, so the third week opens rank 12 at once.)
check(rec.t[100] == 3 and rec.t[25] == 3 and rec.t[10] == 2 and rec.t[3] == 2, "tiers add up week after week")
check(R:GetState().rank == 12 and #printed == 2 and printed[2]:find(Overlord.L.RANK_NAME_12, 1, true),
    "the third week opens the ranks it pays for, announced once")

-- Closed while in an instance: the record is credited, the chat stays quiet.
printed = {}
week = finishedWeek(0, 4)
played(rec, week, 500)
Overlord.InstanceSuspended = true
closeWeek(week)
Overlord.InstanceSuspended = false
check(rec.t[3] == 3 and #printed == 0, "counted in an instance, told nothing there")
-- (These weeks were finished first of the faction, with too few kills to be weeks first.)
check(rec.t[1] == nil and R:GetState().rank == 14,
    "three top 3 weeks by now: the rank is there when the sheet is opened")

-- The save is per account: an alt that played the week is placed with its own
-- faction even though another character is logged in at the close, and nobody is told.
local alt = makeRecord("Mira Stone", { k = 10, c = 0, f = "Horde" })
makeRecord("Idle Alt", { k = 900, c = 0, f = "Horde" })
week = finishedWeek(0, 5)
played(alt, week, 5010)
week.bucket.kills["Mira Stone"] = 1
week.bucket.playerInfo["Mira Stone"] = { faction = "Alliance" }
week.bucket.kills["Idle Alt"] = 99999
week.bucket.playerInfo["Idle Alt"] = { faction = "Horde" }
printed = {}
closeWeek(week)
check(alt.t and alt.t[100] == 1 and alt.t[25] == nil and alt.lw == week.archiveEpoch,
    "the alt: thirty-second of the Horde by its own count (thirty-one enemies above)")
check(OverlordDB.ranksByCharacter["Idle Alt"].t == nil,
    "a row fabricated for a character that counted no kill gives it nothing")
check(#printed == 0 and rec.lw ~= week.archiveEpoch, "the logged character did not play: no line, no mark")

-- A session finished under another character credits what it probed and tells nobody.
week = finishedWeek(0, 6)
played(rec, week, 500)
session = R:BeginWeekClose(week)
me = "Brann Holt"
R:FinishWeekClose(session)
check(OverlordDB.ranksByCharacter["Brann Holt"] == nil and #printed == 0,
    "no record for the character now logged in, and no line")
me = "Aldric Vane"

-- More characters on the account than probes: the logged one is never dropped.
week = finishedWeek(0, 7)
played(rec, week, 500)
for i = 1, 40 do
    local name = "Alt " .. string.char(96 + (i - 1) % 26 + 1) .. string.char(97 + math.floor((i - 1) / 26))
    local crowd = makeRecord(name, { f = "Horde" })
    played(crowd, week, 100 + i)
    week.bucket.kills[name] = 100 + i
end
session = R:BeginWeekClose(week)
check(session and #session.probes == R.WEEK_MAX_PROBES and session.probes[1].name == me,
    "the probe cap keeps the logged character first")
for name in pairs(OverlordDB.ranksByCharacter) do
    if name:find("^Alt ") then OverlordDB.ranksByCharacter[name] = nil end
end

-- Unknown faction: a character without a faction on its record and none on the client.
local lost = makeRecord("Lost Soul", { k = 5 })
lost.f = nil
week = finishedWeek(0, 8)
played(lost, week, 700)
week.bucket.kills["Lost Soul"] = 700
week.bucket.playerInfo["Lost Soul"] = { faction = "Alliance" }
closeWeek(week)
check(lost.t == nil and lost.lw == nil, "the row's faction is never trusted for our own characters")
OverlordDB.ranksByCharacter["Lost Soul"], OverlordDB.ranksByCharacter["Mira Stone"] = nil, nil
OverlordDB.ranksByCharacter["Idle Alt"] = nil

-- Away for a whole week after a played one: at the next login the ladder still holds
-- the played week and closes it two resets late. It counts when the ranking was seen
-- up to date at the end of THAT week, and only once.
week = finishedWeek(0, 20)
week.resetEpoch = week.resetEpoch + 2 * WEEK
played(rec, week, 500)
OverlordDB.ranksLadderSeenAt = { ["-"] = week.archiveEpoch + WEEK - 3600 }
local topWeeks = rec.t[3]
closeWeek(week)
check(rec.t[3] == topWeeks + 1 and rec.lw == week.archiveEpoch, "the played week counts after a week away")
closeWeek(week)
check(rec.t[3] == topWeeks + 1, "and only once")

-- A kill of the NEW week credited before the finished week is closed (a reload, a
-- logout or a crash in the middle of the archive, whose probes are then rebuilt from
-- the record): the finished week's count is kept on the record and the week is still
-- placed.
do
    local finished = finishedWeek(0, 24)
    played(rec, finished, 640)
    local topHundred = rec.t[100]
    OverlordDB.leaderboard = { campaignStart = finished.resetEpoch }
    R:CreditLocal("kills", 3)
    check(rec.we == finished.resetEpoch and rec.wk == 3 and rec.pe == finished.archiveEpoch and rec.pk == 640,
        "the count of the week that ends is kept when the next one starts")
    R:CreditLocal("kills", 2)
    check(rec.wk == 5 and rec.pk == 640, "and later kills leave it alone")
    check(closeWeek(finished) and rec.t[100] == topHundred + 1 and rec.lw == finished.archiveEpoch,
        "the finished week is placed from its kept count")
    check(closeWeek(finished) == nil and rec.t[100] == topHundred + 1, "once")
    -- The next week closes from the running count, as usual.
    local following = finishedWeek(0, 25)
    rec.wk = 300
    check(closeWeek(following) and rec.t[100] == topHundred + 2, "and the week after from its own count")
    -- A kept count below the floor is no week either.
    local thin = finishedWeek(0, 27)
    played(rec, thin, R.WEEK_MIN_KILLS - 1)
    OverlordDB.leaderboard = { campaignStart = thin.resetEpoch }
    R:CreditLocal("kills", 1)
    check(rec.pk == R.WEEK_MIN_KILLS - 1 and closeWeek(thin) == nil, "a kept count below the floor places nothing")
    OverlordDB.leaderboard = nil
end

-- Overlord: five weeks finished first of the faction, each with enough kills; they add
-- up and need not follow each other.
local FIRST = R.WEEK_FIRST_MIN_KILLS
rec.k = R.TIERS[15].glory
local function reign(index, kills, rivals)
    local finished = finishedWeek(0, index)
    played(rec, finished, kills)
    for i = 1, rivals or 0 do
        finished.bucket.kills["Rival " .. i] = kills + i
        finished.bucket.playerInfo["Rival " .. i] = { faction = "Alliance" }
    end
    closeWeek(finished)
end
local topThree = rec.t[3]
printed = {}
reign(30, FIRST - 1)
check(rec.t[1] == nil and rec.t[3] == topThree + 1, "first with too few kills is a top 3 week, not a week first")
check(printed[1] == "|cFFFFD100[Overlord]|r " .. string.format(Overlord.L.RANK_WEEK_CHAT, 1, 3) .. " "
    .. string.format(Overlord.L.RANK_WEEK_FIRST_FLOOR, tostring(FIRST), tostring(FIRST - 1)),
    "and the player is told why: " .. tostring(printed[1]))
printed = {}
reign(31, FIRST)
reign(32, FIRST + 5)
check(rec.t[1] == 2, "two weeks first")
reign(33, FIRST, 1)
check(rec.t[1] == 2 and rec.t[3] == topThree + 4, "a week finished second takes nothing away")
check(printed[#printed] == "|cFFFFD100[Overlord]|r " .. string.format(Overlord.L.RANK_WEEK_CHAT, 2, 3),
    "and nothing is said about the floor of a week first: " .. tostring(printed[#printed]))
-- (Weeks 34 to 37 are not played.)
reign(38, FIRST)
reign(39, FIRST)
check(rec.t[1] == 4 and R:GetState().rank == 14, "four weeks first, spread out, are not five")
printed = {}
reign(40, FIRST)
check(rec.t[1] == 5 and R:GetState().rank == 15, "five weeks first: Overlord")
check(#printed == 2 and printed[2]:find(string.format(Overlord.L.RANK_UP_CHAT, Overlord.L.RANK_NAME_15), 1, true),
    "announced once, after the week's line")
reign(41, FIRST, 3)
check(rec.t[1] == 5 and R:GetState().rank == 15, "and kept for life")
check(rec.fs == nil and rec.fb == nil, "no streak is kept on the record")

Overlord.Leaderboard.IsLocalDisplayName = nil
rec.k, rec.c, rec.t, rec.lw, rec.we, rec.wk, rec.pe, rec.pk = 200, 0, nil, nil, nil, nil, nil, nil
printed = {}

-- The ladder's catch-up tells the ranks at the end of a round: the date of a round that
-- compared the whole ranking, nothing otherwise.
local catchup = io.open("SyncHistoryCatchup.lua", "rb"):read("*a")
check(catchup:find("pcall(Overlord.Ranks.NoteLadderSeen, Overlord.Ranks, whole and not filtered and ack.at or nil)", 1, true),
    "the catch-up gives the date of a whole, unfiltered round, under pcall")
-- And sooner, as soon as the kills of a sweep are compared (v6/v7 and v8 paths): the
-- behaviour itself is tested in forever_paged_v8_rows.test.lua.
local pages = io.open("SyncLeaderboardPages.lua", "rb"):read("*a")
local _, killsHooks = pages:gsub("\n%s+noteKillsCompared%(state%)", "")
check(killsHooks == 2 and pages:find("pcall(ranks.NoteLadderSeen, ranks, GetServerTime())", 1, true),
    "both pull paths tell the ranks when the kills are compared, under pcall: " .. killsHooks)

-- The ladder credits the ranks on its local paths only, and never breaks on them.
local source = io.open("Leaderboard.lua", "rb"):read("*a")
local hooks, previousLine = 0, ""
for line in source:gmatch("[^\r\n]+") do
    if line:find("Overlord.Ranks.CreditLocal", 1, true) then
        hooks = hooks + 1
        check(line:find("pcall(Overlord.Ranks.CreditLocal, Overlord.Ranks, ", 1, true), "credit under pcall: " .. line)
        check(previousLine:find("if not fromSync and Overlord.Ranks then", 1, true), "credit guarded: " .. previousLine)
    end
    previousLine = line
end
check(hooks == 3, "three local credit points, got " .. hooks)
for _, call in ipairs({ "pcall(Overlord.Ranks.BeginWeekClose", "pcall(Overlord.Ranks.ProbeWeekRow",
    "pcall(Overlord.Ranks.FinishWeekClose" }) do
    local _, uses = source:gsub(call:gsub("%p", "%%%0"), "")
    check(uses == 1, "the weekly archive calls the ranks under pcall: " .. call)
end
for _, file in ipairs({ "Ranks.lua", "RanksUI.lua" }) do
    local text = io.open(file, "rb"):read("*a")
    for _, word in ipairs({ "SendAddonMessage", "SendChatMessage", "RegisterAddonMessagePrefix", "CHAT_MSG" }) do
        check(not text:find(word, 1, true), file .. " must stay off the network: " .. word)
    end
end
-- Nothing of the ladder's own rows is read as a score, a glory or a faction.
local rules = io.open("Ranks.lua", "rb"):read("*a")
check(not rules:find("lb.kills", 1, true) and not rules:find("captureCount", 1, true)
    and not rules:find("info.faction ~= ", 1, true), "the rules read no ladder row of ours")

-- ---------------------------------------------------------------- character sheet tab
local created, writes = 0, 0
local function widget(kind)
    local w = { _kind = kind, _shown = true, _scripts = {} }
    local methods = {}
    function methods:Show()
        local was = self._shown
        self._shown = true
        if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
    end
    function methods:Hide()
        local was = self._shown
        self._shown = false
        if was and self._scripts.OnHide then self._scripts.OnHide(self) end
    end
    function methods:SetShown(shown) if shown then self:Show() else self:Hide() end end
    function methods:IsShown() return self._shown end
    function methods:IsProtected() return false end
    function methods:SetScript(name, fn) self._scripts[name] = fn end
    function methods:HookScript(name, fn)
        local before = self._scripts[name]
        self._scripts[name] = function(...)
            if before then before(...) end
            return fn(...)
        end
    end
    function methods:SetPoint(...) self._point = { ... } end
    function methods:ClearAllPoints() self._point = nil end
    function methods:SetText(text) writes = writes + 1; self._text = text end
    function methods:SetTexture(texture) writes = writes + 1; self._texture = texture end
    function methods:SetAtlas(atlas) self._atlas = atlas end
    function methods:SetTexCoord(...) self._coords = { ... } end
    function methods:SetValue(value) self._value = value end
    function methods:SetDesaturated(flag) writes = writes + 1; self._grey = flag end
    function methods:GetFrameLevel() return 1 end
    function methods:CreateTexture() created = created + 1; return widget("Texture") end
    function methods:CreateAnimationGroup()
        created = created + 1
        local group = widget("AnimationGroup")
        group.CreateAnimation = function() return widget("Animation") end
        group.Play = function(self) self._plays = (self._plays or 0) + 1 end
        return group
    end
    function methods:CreateFontString() created = created + 1; return widget("FontString") end
    return setmetatable(w, { __index = function(_, key)
        if methods[key] then return methods[key] end
        if type(key) == "string" and key:match("^%u") then return function() end end
        return nil
    end })
end

local login
CreateFrame = function(kind, _, _, template)
    created = created + 1
    local f = widget(kind)
    if template == "LargeSideTabButtonTemplate" then
        f.Icon = widget("Texture")
        f.SetChecked = function(self, checked) self._checked = checked end
        f.SetCustomOnMouseUpHandler = function(self, fn) self._click = fn end
    end
    f.RegisterEvent = function(self) login = self end
    return f
end
GameTooltip = widget("GameTooltip")
UIParent = widget("Frame")
local uiNow, uiTimers, sounds = 100, {}, {}
GetTime = function() return uiNow end
C_Timer = { After = function(delay, fn) uiTimers[#uiTimers + 1] = { at = uiNow + delay, fn = fn } end }
PlaySoundFile = function(file) sounds[#sounds + 1] = file end
local function runTimers(seconds)
    uiNow = uiNow + seconds
    local due = {}
    for index = #uiTimers, 1, -1 do
        if uiTimers[index].at <= uiNow then table.insert(due, 1, table.remove(uiTimers, index)) end
    end
    for _, timer in ipairs(due) do timer.fn() end
end
GameTooltip_Hide = function() end
NORMAL_FONT_COLOR = {}
InCombatLockdown = function() return false end
UnitFactionGroup = function() return "Horde" end
GameFontNormal = {}
-- No method of Blizzard's sheet may be wrapped: a wrapper that fails would fail
-- Blizzard's own call (the sheet would no longer open).
hooksecurefunc = function(_, name) error("a method of Blizzard's sheet was hooked: " .. tostring(name)) end

local function blizzardTab(frameName, shown)
    local tab = widget("Frame")
    tab.frameName, tab._shown, tab.SelectedTexture = frameName, shown, widget("Texture")
    return tab
end
PaperDollFrame, ReputationFrame = widget("Frame"), widget("Frame")
ReputationFrame._shown = false
CHARACTERFRAME_SUBFRAMES = { "PaperDollFrame", "ReputationFrame" }
CharacterFrame = widget("Frame")
CharacterFrame._shown = false
CharacterFrame.ModeTabs = widget("Frame")
CharacterFrame.ModeTabs.Tabs = {
    blizzardTab("PaperDollFrame", true), blizzardTab("ReputationFrame", true), blizzardTab("TokenFrame", false),
}
CharacterFrame.LeftPaneHost = widget("Frame")
CharacterFrame.RightPaneHost = widget("Frame")
CharacterFrame.RightPaneHost.StoneBg = widget("Texture")
CharacterFrame.activeSubframe = "PaperDollFrame"
local title, portrait = nil, widget("Texture")
CharacterFrame.SetTitle = function(_, text) title = text end
CharacterFrame.SetTitleColor = function() end
CharacterFrame.GetPortrait = function() return portrait end
CharacterFrame.UpdateTitle = function() title = "player" end
CharacterFrame.UpdatePortrait = function() portrait._texture = "player" end
CharacterFrame.UpdateRightPaneHeader = function() end
CharacterFrame.UpdateTabLayout = function() end
CharacterFrame.RefreshDisplay = function(self) self:UpdateTitle(); self:UpdatePortrait() end
CharacterFrame.ShowSubFrame = function(self, name)
    self.activeSubframe = name
    for _, sub in ipairs(CHARACTERFRAME_SUBFRAMES) do _G[sub]:SetShown(sub == name) end
end
-- Blizzard's first panel refreshes the sheet when it hides, like the real one.
PaperDollFrame._scripts.OnHide = function() CharacterFrame:RefreshDisplay() end
-- The two paths by which Blizzard puts its title and portrait back while a tab stays
-- open: the right pane's button, and the sheet's own events (as in its OnEvent).
CharacterFrame.RightPaneToggleButton = widget("Button")
CharacterFrame.RightPaneToggleButton._scripts.OnClick = function() CharacterFrame:RefreshDisplay() end
CharacterFrame._scripts.OnEvent = function(self, event, unit)
    if event == "UNIT_NAME_UPDATE" then
        if unit == "player" then self:UpdateTitle() end
    elseif event == "UNIT_PORTRAIT_UPDATE" then
        if unit == "player" then self:UpdatePortrait() end
    else
        self:UpdatePortrait()
    end
end
local sheetMethods = { "ShowSubFrame", "RefreshDisplay", "UpdateTitle", "UpdatePortrait", "UpdateTabLayout" }
local sheetOriginals = {}
for _, method in ipairs(sheetMethods) do sheetOriginals[method] = CharacterFrame[method] end

local function fieldsOf(t)
    local keys = {}
    for key in pairs(t) do if key ~= "_scripts" and key ~= "_shown" and key ~= "_point" then keys[#keys + 1] = tostring(key) end end
    table.sort(keys)
    return table.concat(keys, ",")
end
local sheetFields = fieldsOf(CharacterFrame)

dofile("RanksUI.lua")
local UIR = Overlord.RanksUI
local before = created
login._scripts.OnEvent(login)
check(UIR.attached and created == before, "attaching builds nothing")
check(UIR.tab == nil, "no tab before the sheet opens")

CharacterFrame:Show()
local tab = UIR.tab
check(tab and tab._shown, "the tab comes with the sheet")
check(tab._point[2] == CharacterFrame.ModeTabs.Tabs[2] and tab._point[3] == "BOTTOMLEFT",
    "under Blizzard's last visible tab")
check(tab.Icon._texture:find("overlord_minimap", 1, true), "the Overlord logo on the tab")
check(UIR.left == nil, "panes wait for the first click")

rec.k, rec.c = 16000, 0
tab._click(tab, "RightButton", true)
tab._click(tab, "LeftButton", false)
check(not UIR.selected, "only a left click released on the tab")
tab._click(tab, "LeftButton", true)
check(UIR.selected and UIR.left._shown and UIR.right._shown, "the click opens the rank panes")
check(not PaperDollFrame._shown, "Blizzard's panel is hidden")
check(title == "Overlord", "our title after Blizzard's own refresh")
check(portrait._texture:find("overlord_minimap", 1, true), "the Overlord logo in the portrait")
check(tab._checked == true and not CharacterFrame.ModeTabs.Tabs[1].SelectedTexture._shown, "only our tab is lit")
check(UIR.name._text == Overlord.L.RANK_NAME_7 and UIR.socket._text == 7, "rank 7 at 16 000 glory")
check(UIR.endIcon._texture:find("prestige%-icon%-6%-3$"), "the next rank's badge closes the bar")
check(UIR.badge._texture:find("prestige%-icon%-6%-2$"), "its badge")
check(UIR.bar._value == (16000 - 15000) / (30000 - 15000), "progress to the next rank")
check(UIR.rows[7].back._shown and not UIR.rows[8].back._shown, "the current rank is marked")
check(UIR.rows[8].icon._grey == true and UIR.rows[7].icon._grey == false, "ranks to come are greyed")

-- Nothing changed: no frame, no write. A credit while open: a few writes, no frame,
-- and the rank rows only when the rank moves.
before, writes = created, 0
UIR:Refresh(); UIR:Refresh()
check(created == before and writes == 0, "an unchanged refresh costs nothing")
R:CreditLocal("kills", 1)
check(created == before and writes > 0 and writes <= 2, "a credit repaints two texts: " .. writes)
check(UIR.kills._text == "16001", "the count follows")
writes = 0
R:CreditLocal("kills", 14000)
check(UIR.name._text == Overlord.L.RANK_NAME_8 and UIR.rows[8].icon._grey == false, "the next rank lights up")

-- The rank just reached is announced on a toast at the bottom of the screen: not in the
-- first seconds of a login, one at a time, with the rank's badge, name and feat points.
local toast = Overlord.RankToast
check(toast.frame == nil and #sounds == 0, "nothing on screen in the first seconds after login")
runTimers(toast.LAYOUT.LOGIN_DELAY + 1)
check(toast.frame and toast.frame._shown and toast.showing, "then the toast shows")
check(toast.name._text == Overlord.L.RANK_NAME_8 and toast.points._text == R.TIERS[8].points
    and toast.icon._texture:find("prestige%-icon%-6%-3$"), "with the rank's name, points and badge")
check(#sounds == 1 and sounds[1] == toast.LAYOUT.SOUND and toast.life._plays == 1, "once, with the game's jingle")
local toastFrames = created
toast:Show(9)
toast:Show(10)
check(toast.name._text == Overlord.L.RANK_NAME_8 and #sounds == 1, "the next ones wait their turn")
toast.life._scripts.OnFinished()
check(toast.frame._shown and toast.name._text == Overlord.L.RANK_NAME_9 and #sounds == 2, "and follow one by one")
OverlordDB.config = { soundEnabled = false }
toast.life._scripts.OnFinished()
check(toast.name._text == Overlord.L.RANK_NAME_10 and #sounds == 2, "silent when the addon's sounds are off")
OverlordDB.config = nil
toast.life._scripts.OnFinished()
check(not toast.frame._shown and not toast.showing and created == toastFrames, "then it leaves, and no frame was added")
Overlord.InstanceSuspended = true
toast:Show(11)
Overlord.InstanceSuspended = false
toast:Show("x")
check(not toast.showing and not toast.frame._shown, "nothing in an instance, nothing for what is not a rank")
for flood = 1, 20 do toast:Show(3) end
check(#toast.queue <= toast.LAYOUT.MAX_QUEUE, "a burst never piles up")
toast.queue = nil
toast.showing = false

-- Each rank is a feat of the Hall of Fame (Your feats): earned or to earn, with progress.
local view = R:GetFeatView()
check(#view.rows == 15 and view.rows[1].kind == "lifetime" and view.rows[15].data.id == "rank_15", "fifteen feats")
check(view.rows[1].iconShaped and view.rows[15].iconShaped and view.rows[15].title == "Overlord"
    and view.rows[15].progressTotal == R.TIERS[15].glory and view.rows[15].points == R.TIERS[15].points
    and view.rows[15].subtitle:find("150", 1, true),
    "badges are cut-out shapes, and Overlord is the last feat, with the glory it asks for")
check(view.rows[8].earned and not view.rows[9].earned and view.rows[8].title == Overlord.L.RANK_NAME_8, "earned up to the rank held")
check(view.rows[9].progressTotal == R.TIERS[9].glory and view.rows[9].progressCurrent == R:GetState().glory,
    "glory progress toward the next one")
check(view.rows[11].progressTotal == R.TIERS[11].glory and view.rows[11].progressCurrent == R:GetState().glory
    and view.rows[11].subtitle:find("100"), "beyond ten too, the glory comes first")
local pointsHeld = 0
for index = 1, 8 do pointsHeld = pointsHeld + R.TIERS[index].points end
check(view.stats.earnedCount == 8 and view.stats.totalCount == 15 and view.stats.totalPoints == pointsHeld,
    "points of the feats held")
check(R:GetFeatView() == view and R:GetFeatView().rows == view.rows, "the view and its rows are reused")
check(view.rows[3].searchHaystack:find(Overlord.L.RANK_NAME_3:lower(), 1, true), "and can be searched")

-- The bar's tooltip says when the ranking was last compared with other players: what
-- decides whether the week will count.
do
    local tip = {}
    GameTooltip.AddLine = function(_, text) tip[#tip + 1] = text end
    local function hover()
        tip = {}
        UIR.bar._scripts.OnEnter(UIR.bar)
        return table.concat(tip, "\n")
    end
    local keepSeen, keepClock = OverlordDB.ranksLadderSeenAt, GetServerTime
    OverlordDB.ranksLadderSeenAt = nil
    check(hover():find(Overlord.L.RANK_TIP_NOT_COMPARED, 1, true), "not compared yet: said")
    GetServerTime = function() return 5000000 end
    OverlordDB.ranksLadderSeenAt = { ["-"] = 5000000 - 2 * 3600 - 5 * 60 }
    check(hover():find(string.format(Overlord.L.RANK_TIP_COMPARED, "125 min"), 1, true), "compared two hours ago: " .. hover())
    SecondsToTime = function(seconds) return (seconds / 3600) .. " h" end
    OverlordDB.ranksLadderSeenAt = { ["-"] = 5000000 - 3 * 3600 }
    check(hover():find(string.format(Overlord.L.RANK_TIP_COMPARED, "3 h"), 1, true), "in the game's own words when it has them")
    SecondsToTime = function() error("no such thing") end
    check(hover():find(string.format(Overlord.L.RANK_TIP_COMPARED, "180 min"), 1, true), "and without them")
    check(hover():find(Overlord.L.RANK_TIP_WEEKS_FIRST:match("^[^%%]+"), 1, true), "next to the weeks finished first")
    SecondsToTime, GetServerTime, OverlordDB.ranksLadderSeenAt = nil, keepClock, keepSeen
    GameTooltip.AddLine = nil
end

-- Beyond rank 10 the bar counts weeks, and the list says what each rank asks for.
check(UIR.rows[10].need._text == "100000" and UIR.rows[11].need._text:find("100") and UIR.rows[14].need._text:find("3"),
    "the list shows glory, then the top to reach")
check(#UIR.rows == 14 and UIR.rows[15] == nil, "Overlord has its own line above the fourteen others")
local keptKills = rec.k
rec.k, rec.t = 170000, { [100] = 1 }
UIR:Refresh()
check(UIR.name._text == Overlord.L.RANK_NAME_10 and UIR.bar._value == 1 / 3, "one week out of three")
check(UIR.barText._text:find("100") and UIR.barText._text:find("1 / 3"), "the bar says which top: " .. UIR.barText._text)
local feats = R:GetFeatView()
check(feats.rows[11].progressTotal == 3 and feats.rows[11].progressCurrent == 1 and feats.rows[15].progressTotal == 5
    and feats.rows[15].progressCurrent == 0, "once the glory is there, a feat counts its weeks")
rec.t[100] = 3
UIR:Refresh()
check(UIR.name._text == Overlord.L.RANK_NAME_11 and UIR.rows[11].back._shown, "a week counted moves the rank")
rec.k, rec.t = keptKills, nil
UIR:Refresh()
check(UIR.name._text == Overlord.L.RANK_NAME_8, "back to the glory ranks")

-- Blizzard refreshing the sheet (right pane toggle) keeps our title, and so do its
-- own single updates (name, grade or portrait changed while our tab is open). Both
-- are followed by their scripts: no method of the sheet is wrapped.
for _, method in ipairs(sheetMethods) do
    check(CharacterFrame[method] == sheetOriginals[method], "Blizzard's " .. method .. " was replaced")
end
local toggle = CharacterFrame.RightPaneToggleButton
toggle._scripts.OnClick(toggle)
check(title == "Overlord" and portrait._texture:find("overlord_minimap", 1, true),
    "our title and logo survive the right pane's button")
CharacterFrame._scripts.OnEvent(CharacterFrame, "UNIT_NAME_UPDATE", "player")
CharacterFrame._scripts.OnEvent(CharacterFrame, "PORTRAITS_UPDATED")
check(title == "Overlord" and portrait._texture:find("overlord_minimap", 1, true),
    "our title and logo survive Blizzard's single updates")
check(portrait._coords and portrait._coords[1] ~= 0, "the logo is drawn recentred")
writes = 0
CharacterFrame._scripts.OnEvent(CharacterFrame, "UNIT_PORTRAIT_UPDATE", "nameplate7")
CharacterFrame._scripts.OnEvent(CharacterFrame, "UNIT_NAME_UPDATE", "party2")
check(writes == 0, "somebody else's name or portrait repaints nothing: " .. writes)

-- A Blizzard tab takes over by its own path.
CharacterFrame:ShowSubFrame("ReputationFrame")
CharacterFrame:RefreshDisplay()
check(not UIR.selected and not UIR.left._shown and tab._checked == false, "another tab closes ours")
check(ReputationFrame._shown and not PaperDollFrame._shown and title == "player", "Blizzard's state is its own")

-- Whatever path Blizzard takes to show one of its panels, ours closes at once: here a
-- panel is shown directly, without the sheet's own switch function or refresh.
check(UIR.hooks.OnEvent == "ok" and UIR.hooks.RightPaneToggle == "ok", "the script hooks report their state")
tab._click(tab, "LeftButton", true)
check(UIR.selected and not ReputationFrame._shown and title == "Overlord", "selected over the reputation panel")
PaperDollFrame._scripts.OnHide = nil
PaperDollFrame:Show()
check(not UIR.selected and not UIR.left._shown and not UIR.right._shown and tab._checked == false,
    "a panel shown by any path closes ours")
check(title == "player" and portrait._texture == "player" and portrait._coords[1] == 0,
    "and the sheet's own title and portrait are put back without waiting for Blizzard")
-- Two panels left shown by somebody else: selecting ours hides them all.
ReputationFrame:Show()
tab._click(tab, "LeftButton", true)
check(UIR.selected and not PaperDollFrame._shown and not ReputationFrame._shown, "nothing stays under our panes")
-- Second safety: a left click on one of Blizzard's tabs never leaves ours open, even if
-- Blizzard showed nothing; the panel we had hidden then comes back.
local blizzardTab = CharacterFrame.ModeTabs.Tabs[2]
blizzardTab._scripts.OnMouseUp(blizzardTab, "RightButton", true)
check(UIR.selected, "a right click on a Blizzard tab changes nothing")
blizzardTab._scripts.OnMouseUp(blizzardTab, "LeftButton", true)
check(not UIR.selected and ReputationFrame._shown and not UIR.left._shown, "a click on a Blizzard tab always closes ours")
PaperDollFrame._shown = false

-- Closing the sheet on our tab puts back the panel we had hidden.
tab._click(tab, "LeftButton", true)
check(UIR.selected and not ReputationFrame._shown, "selected again")
CharacterFrame:Hide()
check(not UIR.selected and ReputationFrame._shown and title == "player", "the hidden panel is restored")
check(portrait._texture == "player" and portrait._coords[1] == 0 and portrait._coords[2] == 1,
    "the player's portrait is back on the whole texture")

-- Overlord, the last rank: more glory, then five weeks finished first. From rank 14 the
-- bar counts them; once there the diamond, the halo and its own line light up.
CharacterFrame:Show()
tab._click(tab, "LeftButton", true)
check(UIR.name._text == Overlord.L.RANK_NAME_8 and not UIR.lordBack._shown and not UIR.glow._shown,
    "not an Overlord before the last rank")
local heldKills = rec.k
rec.k, rec.t = 120000, { [100] = 3, [25] = 3, [10] = 3, [3] = 3, [1] = 5 }
UIR:Refresh()
check(UIR.name._text == Overlord.L.RANK_NAME_14 and UIR.barText._text:find("150"),
    "the glory Overlord asks for comes first: " .. UIR.barText._text)
rec.k, rec.t = 170000, { [100] = 3, [25] = 3, [10] = 3, [3] = 3, [1] = 3 }
UIR:Refresh()
check(UIR.name._text == Overlord.L.RANK_NAME_14 and UIR.rows[14].back._shown and not UIR.lordBack._shown,
    "rank 14 while a week first is missing")
check(UIR.barText._text == string.format(Overlord.L.RANK_BAR_FIRST, 3, 5) and UIR.bar._value == 3 / 5
    and UIR.nextText._text:find("Overlord", 1, true) and UIR.endIcon._texture:find("prestige%-icon%-8%-4$"),
    "the bar counts the weeks finished first: " .. UIR.barText._text)
rec.t[1] = 5
UIR:Refresh()
check(UIR.name._text == "Overlord" and UIR.badge._texture:find("prestige%-icon%-8%-4$"), "the Overlord emblem")
check(UIR.lordBack._shown and UIR.glow._shown and not UIR.rows[14].back._shown and UIR.rows[14].icon._grey == false,
    "its line lights up, the fourteen others are all earned")
check(UIR.line._text:find("15") and UIR.nextText._text == Overlord.L.RANK_MAX and UIR.bar._value == 1, "nothing beyond")
rec.k, rec.t = heldKills, nil
UIR:Refresh()
check(UIR.name._text == Overlord.L.RANK_NAME_8 and not UIR.lordBack._shown and not UIR.glow._shown, "and back")

-- Instances: tab gone, nothing selectable; back afterwards. A toast on screen goes too.
toast:Show(3)
toast:Show(4)
check(toast.frame._shown and toast.showing, "a toast is on screen")
Overlord.InstanceSuspended = true
UIR:OnInstanceSuspend()
check(not UIR.selected and not tab._shown, "cut in an instance")
check(not toast.frame._shown and not toast.showing and toast.queue == nil, "the toast does not follow into the instance")
tab._click(tab, "LeftButton", true)
check(not UIR.selected, "nothing opens in an instance")
Overlord.InstanceSuspended = false
UIR:OnInstanceResume()
check(tab._shown, "back after the instance")

-- Blizzard's tables were never written.
check(fieldsOf(CharacterFrame) == sheetFields, "no field added to the character sheet")
check(#CHARACTERFRAME_SUBFRAMES == 2 and #CharacterFrame.ModeTabs.Tabs == 3, "Blizzard's lists untouched")

-- ---------------------------------------------------------------- damaged saved data
-- Never raises and never invents a rank: a record that cannot be trusted is set aside,
-- untouched, and the character starts again from an empty one (the seal has its own
-- test file: tests/forever_ranks_seal.test.lua).
local broken = { k = "many", c = {}, t = 7, lw = -5, we = "x", wk = {}, f = 3 }
OverlordDB.ranksByCharacter[me] = broken
printed = {}
s = R:GetState()
check(s.glory == 0 and s.rank == 0 and s.progress == 0, "a damaged record reads as empty")
local aside = OverlordDB.ranksSetAside
check(OverlordDB.ranksByCharacter[me] == nil and aside[#aside].n == me and aside[#aside].r == broken
    and broken.k == "many", "and is kept aside, untouched")
check(#printed == 1 and printed[1]:find(Overlord.L.RANK_RECORD_RESET, 1, true), "the player is told once")
OverlordDB.leaderboard = { campaignStart = RESET + 50 * WEEK }
R:CreditLocal("kills", 150)
local healed = OverlordDB.ranksByCharacter[me]
check(healed.k == 150 and healed.wk == 150 and healed.f == "Alliance", "the fresh record takes credits")
local damaged = finishedWeek(0, 51)
healed.t = 7
closeWeek(damaged)
check(type(healed.t) == "table" and healed.t[3] == 1, "a weeks field that is not a table is rebuilt at a close")
OverlordDB.leaderboard = nil
OverlordDB.ranksByCharacter = "broken"
check(R:GetState().glory == 0, "a damaged store reads as empty")
check(R:BeginWeekClose(finishedWeek(0, 60)) == nil, "and closes no week")
R:CreditLocal("kills", 1)
check(type(OverlordDB.ranksByCharacter) == "table" and OverlordDB.ranksByCharacter[me].k == 1,
    "and is rebuilt empty, whatever the ladder row says")
check(R:BeginWeekClose(nil) == nil and R:BeginWeekClose({}) == nil and R:BeginWeekClose({ bucket = {} }) == nil,
    "a marker without a week is ignored")
R:FinishWeekClose(nil); R:FinishWeekClose({}); R:FinishWeekClose({ probes = {} })

-- ---------------------------------------------------------------- ladder seen up to date
-- The date given by the catch-up is kept in the save and never goes back: later kills,
-- or a session that ends without another comparison, cost no week.
OverlordDB = { ranksByCharacter = {}, leaderboard = { campaignStart = RESET + 70 * WEEK } }
R:CreditLocal("kills", 500)
R:NoteLadderSeen(RESET + 71 * WEEK - 7200)
R:NoteLadderSeen(RESET + 71 * WEEK - 9000)
R:CreditLocal("kills", 1)
check(R:GetLadderSeenAt() == RESET + 71 * WEEK - 7200, "the date is kept across kills")
local stamp = OverlordDB.ranksLadderSeenAt
local kept = finishedWeek(0, 71)
-- (The fixture starts each week from its own date: put ours back.)
OverlordDB.ranksLadderSeenAt = stamp
OverlordDB.ranksByCharacter[me].wk = 501
check(closeWeek(kept) and OverlordDB.ranksByCharacter[me].t[3] == 1, "the week counts from the kept date")
-- A date in the future (damaged save, clock set forward) is worth nothing: kept, it
-- would refuse every later week since the date never goes back. So is a value that is
-- not a table of dates (a save from before the dates were kept per ranking).
local clock = RESET + 72 * WEEK - 3600
GetServerTime = function() return clock end
OverlordDB.ranksLadderSeenAt = { ["-"] = clock + 30 * 86400 }
check(R:GetLadderSeenAt() == 0, "a future date is not read")
OverlordDB.leaderboard.campaignStart = RESET + 71 * WEEK
R:NoteLadderSeen(clock + 7200)
check(R:GetLadderSeenAt() == 0, "nor written")
R:NoteLadderSeen(clock - 600)
R:CreditLocal("kills", 200)
check(R:GetLadderSeenAt() == clock - 600, "and is replaced by the next real one")
OverlordDB.ranksLadderSeenAt = clock - 600
check(R:GetLadderSeenAt() == 0, "a bare number is not a date per ranking")
R:NoteLadderSeen(clock - 600)
check(R:GetLadderSeenAt() == clock - 600, "and the next comparison starts the table")
local after = finishedWeek(0, 72)
OverlordDB.ranksLadderSeenAt = { ["-"] = clock - 600 }
check(closeWeek(after) and OverlordDB.ranksByCharacter[me].t[3] == 2, "and the following week counts")
GetServerTime = nil

-- ---------------------------------------------------------------- one character, one record
-- A renamed character finds its record again. A record under our own name is always
-- ours, whatever identifier it carries: a transfer can change the identifier, and a
-- lifetime rank must never be thrown away for that.
local guid = "Player-1-0000AAAA"
UnitGUID = function() return guid end
OverlordDB = {}
R:CreditLocal("kills", 40)
check(OverlordDB.ranksByCharacter[me].g == guid, "the record carries the character's identifier")
me = "Aldric Renamed"
check(R:GetState().kills == 40 and OverlordDB.ranksByCharacter["Aldric Vane"] == nil
    and OverlordDB.ranksByCharacter[me].k == 40, "a renamed character keeps its record")
guid = "Player-9-0000AAAA"
check(R:GetState().kills == 40, "a changed identifier (transfer) keeps the record of that name")
R:CreditLocal("kills", 3)
check(OverlordDB.ranksByCharacter[me].k == 43 and OverlordDB.ranksByCharacter[me].g == guid,
    "which adds up and takes the new identifier")
-- A record written by hand, without a seal, is never adopted.
OverlordDB.ranksByCharacter["Old Timer"] = { k = 77, c = 0 }
me = "Old Timer"
guid = "Player-1-0000CCCC"
check(R:GetState().kills == 0 and OverlordDB.ranksByCharacter[me] == nil, "a record without a seal is set aside")
UnitGUID = nil
me = "Aldric Vane"
print("Forever ranks: glory, weekly places, character sheet tab, damaged data, identity OK")
