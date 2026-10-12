-- Overlord Rank, the record seal: real Ranks.lua.
-- Two promises. An honest record is NEVER refused: every write leaves a valid seal, and
-- the record survives new sessions, renames, a changed identifier, week changes and
-- week closes, whatever the order. A record changed by hand in the saved file is set
-- aside, untouched, and the character starts again from an empty one.
-- (The record of the logged character is also kept in the character's own save,
-- OverlordCharDB: a test that rewrites the account save by hand clears that copy, and
-- the copy has its own section at the end.)
-- The seal's formula is frozen: this file recomputes it on its own and holds fixed
-- values, so that a change in Ranks.lua which would refuse every existing record
-- cannot pass unnoticed.

local function check(cond, msg) if not cond then error(msg, 2) end end

local me, guid, clock = "Aldric Vane", "Player-1-0000AAAA", 1800000000
local printed = {}
Overlord = { L = {}, PlayerFaction = "Alliance" }
GetLocale = function() return "enUS" end
dofile("RankLocales.lua")
Overlord.Sync = {
    GetPlayerFullName = function() return me end,
    CanonicalForeverName = function(_, name) return name end,
    IsDeniedKillContributor = function() return false end,
}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
Overlord.Leaderboard = { kills = {}, captureCount = {} }
UnitGUID = function() return guid end
GetServerTime = function() return clock end
OverlordDB = {}
OverlordCharDB = nil
dofile("Ranks.lua")
local R = Overlord.Ranks
-- A new session: the file is loaded again, so nothing verified earlier is remembered.
local function relog()
    dofile("Ranks.lua")
    R = Overlord.Ranks
end
local function records() return OverlordDB.ranksByCharacter end
local function asideCount()
    local list = OverlordDB.ranksSetAside
    return type(list) == "table" and #list or 0
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

-- ---------------------------------------------------------------- the formula, frozen
local MOD, CHUNK = 2147483647, 16777216
local function mix(h, v)
    h = (h * 48271 + v + 11) % MOD
    return (h * (h % 32749 + 2) + 918273) % MOD
end
local function mixNumber(h, v) return mix(mix(h, v % CHUNK), math.floor(v / CHUNK)) end
local function seed(text)
    if type(text) ~= "string" then return 7 end
    local h = 40507
    for i = 1, #text do
        local b = text:byte(i)
        if b >= 65 and b <= 90 then b = b + 32 end
        h = mix(h, b)
    end
    return h
end
local function n(v) v = math.floor(tonumber(v) or 0); return v > 0 and v or 0 end
local function expected(rec, name)
    local w = type(rec.t) == "table" and rec.t or {}
    local h = mixNumber(seed(name), seed(rec.g))
    h = mixNumber(h, n(rec.k)); h = mixNumber(h, n(rec.c))
    h = mix(h, rec.f == "Alliance" and 1 or rec.f == "Horde" and 2 or 0)
    h = mixNumber(h, n(rec.we)); h = mixNumber(h, n(rec.wk)); h = mixNumber(h, n(rec.lw))
    for _, top in ipairs({ 100, 25, 10, 3, 1 }) do h = mixNumber(h, n(w[top])) end
    h = mixNumber(h, n(rec.pe)); h = mixNumber(h, n(rec.pk))
    return mix(h, 65521) % (MOD - 1) + 1
end
local VECTORS = {
    { name = "Aldric Vane", rec = { k = 0, c = 0, g = "Player-1-0000AAAA" }, seal = 1852317020 },
    { name = "Aldric Vane", rec = { k = 123456, c = 789, f = "Alliance", g = "Player-1-0000AAAA", we = 1791878400,
        wk = 4321, lw = 1791273600, t = { [100] = 7, [25] = 5, [10] = 3, [3] = 1 } }, seal = 1525744934 },
    { name = "Zoé Élan", rec = { k = 15, c = 2, f = "Horde" }, seal = 1375564585 },
    { name = "王 伟", rec = { k = 2000000000, c = 80000000, f = "Horde", g = "Player-4477-0BADF00D",
        t = { [100] = 300 } }, seal = 2004797743 },
    { name = "Aldric Vane", rec = { k = 250000, c = 1200, f = "Horde", g = "Player-1-0000AAAA", we = 1791878400,
        wk = 9000, lw = 1791273600, t = { [100] = 9, [25] = 8, [10] = 6, [3] = 4, [1] = 3 }, pe = 1790668800, pk = 7777 }, seal = 1711791722 },
}
for index, vector in ipairs(VECTORS) do
    local value = expected(vector.rec, vector.name)
    check(value == vector.seal, "vector " .. index .. ": the frozen formula gives " .. value)
    check(value >= 1 and value <= MOD and value == math.floor(value), "a seal is a whole number that a save keeps exactly")
    local sealed = copy(vector.rec)
    sealed.s = value
    check(R:IsSealed(sealed, vector.name), "vector " .. index .. ": Ranks.lua computes another seal than the frozen one")
    sealed.s = value + 1
    check(not R:IsSealed(sealed, vector.name), "vector " .. index .. ": a wrong seal is refused")
end
-- Same content, other spellings of nothing: no weeks table, an empty one, zeros.
local plain = { k = 5, c = 1, g = guid }
plain.s = expected(plain, me)
for _, weeks in ipairs({ {}, { [100] = 0, [25] = 0, [10] = 0, [3] = 0, [1] = 0 }, { 0 } }) do
    local same = copy(plain)
    same.t = weeks
    check(R:IsSealed(same, me), "an empty weeks table changes nothing")
end
check(R:IsSealed(plain, "ALDRIC VANE") and not R:IsSealed(plain, "Aldric Vance"),
    "ASCII case is folded in a name, anything else differs")
check(not R:IsSealed(plain, nil) and not R:IsSealed(nil, me) and not R:IsSealed("x", me), "nothing else is a sealed record")
for _, giant in ipairs({ 2 ^ 48, 1e300, math.huge }) do
    local big = { k = giant, c = 0, g = guid }
    for _, seal in ipairs({ 0, 1, 12345, giant }) do
        big.s = seal
        check(not R:IsSealed(big, me), "a record holding a number beyond any count has no seal")
    end
    big.s = nil
    check(not R:IsSealed(big, me), "not even a missing one")
end

-- ---------------------------------------------------------------- every write seals
local function sealedNow(name)
    local rec = records()[name or me]
    return rec and R:IsSealed(rec, name or me) and rec.s == expected(rec, name or me)
end
R:CreditLocal("kills", 3)
check(sealedNow(), "a new record is sealed")
check(records()[me].g == guid, "with the character's identifier")
R:CreditLocal("captures", 2)
check(sealedNow(), "after a capture")
clock = 1791273600 + 86400
OverlordDB.leaderboard = { campaignStart = 1791273600 }
R:CreditLocal("kills", 200)
check(sealedNow() and records()[me].wk == 200, "after kills that start the week's count")
OverlordDB.leaderboard.campaignStart = 1791273600 + 3 * 3600
R:CreditLocal("kills", 1)
check(sealedNow() and records()[me].wk == 201, "after a re-anchored week")
Overlord.PlayerFaction = "Horde"
R:CreditLocal("kills", 1)
check(sealedNow() and records()[me].f == "Horde", "after a faction change")
Overlord.PlayerFaction = "Alliance"
R:CreditLocal("kills", 1)

-- A week close: counted with a place, and counted without one.
local function closeWeek(alliesAbove, startEpoch)
    local name = me
    local bucket = { kills = { [name] = 1 }, playerInfo = {} }
    for i = 1, alliesAbove do
        bucket.kills["Ally " .. i] = 100000 + i
        bucket.playerInfo["Ally " .. i] = { faction = Overlord.PlayerFaction }
    end
    local marker = { archiveEpoch = startEpoch, resetEpoch = startEpoch + 604800, bucket = bucket }
    clock = marker.resetEpoch
    OverlordDB.ranksLadderSeenAt = { ["-"] = marker.resetEpoch - 3600 }
    local session = R:BeginWeekClose(marker)
    if not session then return false end
    for row, kills in pairs(bucket.kills) do R:ProbeWeekRow(session, row, kills, bucket.playerInfo) end
    R:FinishWeekClose(session)
    return true
end
check(closeWeek(4, records()[me].we), "the week closes")
check(sealedNow() and records()[me].t[10] == 1 and records()[me].lw > 0, "after a week close with a place")
OverlordDB.leaderboard.campaignStart = 1791273600 + 604800
R:CreditLocal("kills", 150)
check(closeWeek(500, records()[me].we), "the next week closes")
check(sealedNow() and records()[me].t[100] == 1, "after a week close without a place")

-- A chat that raises an error (another addon hooked into it) while a week is being
-- closed or a rank announced: the record is sealed before anything is printed.
local realPrint = Overlord.PrintNotification
Overlord.PrintNotification = function() error("a chat addon broke") end
OverlordDB.leaderboard.campaignStart = 1791273600 + 2 * 604800
R:CreditLocal("kills", 150)
check(pcall(closeWeek, 0, records()[me].we), "a failing chat does not stop the close")
check(sealedNow() and records()[me].t[3] == 1, "and the record credited by that close is sealed")
records()[me].k = R.TIERS[4].glory - 1
R:CreditLocal("captures", 0)
check(pcall(R.CreditLocal, R, "kills", 5) and sealedNow() and records()[me].k == R.TIERS[4].glory + 4,
    "a failing chat on a new rank leaves the credited record sealed")
Overlord.PrintNotification = realPrint

-- The last seal before the save: whatever happened in the session, every record that
-- was verified leaves with the seal of what it holds; a record never verified is left
-- exactly as it is.
local stranger = { k = 5, c = 0, s = 1 }
records()["Never Read"] = stranger
records()[me].k = records()[me].k + 7
check(not sealedNow(), "(a write that escaped the seal)")
R:SealForSave()
check(sealedNow(), "the save seals the session's records")
check(stranger.s == 1 and records()["Never Read"] == stranger, "and does not touch a record it never verified")
records()["Never Read"] = nil

-- New sessions: the record is read back, nothing is set aside, nothing is said.
local before = copy(records()[me])
printed = {}
relog()
local state = R:GetState()
check(state.kills == before.k and state.captures == before.c and asideCount() == 0 and #printed == 0,
    "a new session reads the record back")
relog(); relog()
R:CreditLocal("kills", 1)
check(records()[me].k == before.k + 1 and sealedNow() and asideCount() == 0, "and goes on from it")

-- A changed identifier under the same name (a transfer) keeps the record.
guid = "Player-77-0000AAAA"
relog()
check(R:GetState().kills == before.k + 1 and records()[me].g == guid and sealedNow() and asideCount() == 0,
    "a changed identifier keeps the record, sealed again")
-- A rename: the record is found by its identifier under the old name and follows.
relog()
me = "Aldric Reborn"
check(R:GetState().kills == before.k + 1 and records()["Aldric Vane"] == nil and sealedNow() and asideCount() == 0,
    "a renamed character keeps its record, sealed under the new name")
relog()
check(R:GetState().kills == before.k + 1 and asideCount() == 0, "which the next session reads back")
-- No identifier available at all (never seen in the world, but it must not break).
UnitGUID = nil
relog()
R:CreditLocal("kills", 1)
check(sealedNow() and asideCount() == 0, "a session without identifier keeps the record")
UnitGUID = function() return guid end
relog()
check(R:GetState().kills == before.k + 2 and asideCount() == 0 and #printed == 0, "and the next one too")

-- ---------------------------------------------------------------- changed by hand
-- Each sealed value, changed alone in the saved file, is caught at the next session.
local honest = copy(records()[me])
local function tamper(label, change)
    relog()
    records()[me] = copy(honest)
    OverlordDB.ranksSetAside = nil
    printed = {}
    local edited = records()[me]
    change(edited)
    -- (No copy in the character's own save here: that case is tested further down.)
    OverlordCharDB = nil
    relog()
    local read = R:GetState()
    check(read.kills == 0 and read.glory == 0 and read.rank == 0, label .. ": the edited record gives no rank")
    check(records()[me] == nil, label .. ": it is no longer the character's record")
    local list = OverlordDB.ranksSetAside
    check(#list == 1 and list[1].n == me and list[1].r == edited and list[1].a == clock, label .. ": it is kept aside as it was")
    check(#printed == 1, label .. ": the player is told once")
    R:GetState(); R:GetState()
    check(#printed == 1 and #list == 1, label .. ": and only once")
    R:CreditLocal("kills", 2)
    check(records()[me].k == 2 and sealedNow() and #list == 1, label .. ": the character goes on from an empty record")
end
tamper("kills", function(r) r.k = r.k + 1 end)
tamper("kills to a fortune", function(r) r.k = 999999 end)
tamper("captures", function(r) r.c = r.c + 1 end)
tamper("faction", function(r) r.f = "Horde" end)
tamper("faction removed", function(r) r.f = nil end)
tamper("identifier", function(r) r.g = "Player-1-0000BBBB" end)
tamper("identifier removed", function(r) r.g = nil end)
tamper("week start", function(r) r.we = r.we + 604800 end)
tamper("week count", function(r) r.wk = 50000 end)
tamper("last counted week", function(r) r.lw = 0 end)
tamper("kept count of the week before", function(r) r.pk = (r.pk or 0) + 5000 end)
tamper("kept week before", function(r) r.pe = (r.pe or 0) + 604800 end)
tamper("kept week and count written in", function(r) r.pe, r.pk = r.we - 604800, 9000 end)
tamper("running count moved to the kept one", function(r) r.pe, r.pk, r.wk = r.we, r.wk + 1, 0 end)
tamper("top 100 weeks", function(r) r.t[100] = 3 end)
tamper("top 25 weeks", function(r) r.t[25] = 3 end)
tamper("top 10 weeks", function(r) r.t[10] = 3 end)
tamper("top 3 weeks", function(r) r.t[3] = 3 end)
tamper("weeks first", function(r) r.t[1] = 3 end)
tamper("one more week first", function(r) r.t[1] = (r.t[1] or 0) + 1 end)
tamper("weeks first, written as a list", function(r) table.insert(r.t, 1, 3) end)
tamper("weeks table replaced", function(r) r.t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3 } end)
tamper("weeks table replaced, Overlord", function(r) r.t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3, [1] = 3 } end)
tamper("seal changed", function(r) r.s = r.s + 1 end)
tamper("an identifier no game would give", function(r) r.g = string.rep("Player-1-0000AAAA", 4000) end)
tamper("seal removed", function(r) r.s = nil end)
tamper("seal as text", function(r) r.s = tostring(r.s) end)
tamper("seal of nothing", function(r) r.s = 0 end)
tamper("two values swapped", function(r) r.k, r.c = r.c, r.k end)
-- No value is reduced before it enters the seal: adding the seal's own range, or any
-- other large step, to a number is seen like any other change.
for _, step in ipairs({ 2147483647, 2147483646, 2147483648, 16777216, 65521, 32749, 4294967296, 2 ^ 40 }) do
    tamper("kills plus " .. step, function(r) r.k = r.k + step end)
    tamper("captures plus " .. step, function(r) r.c = r.c + step end)
    tamper("week count plus " .. step, function(r) r.wk = r.wk + step end)
    tamper("week start plus " .. step, function(r) r.we = r.we + step end)
    tamper("last week plus " .. step, function(r) r.lw = r.lw + step end)
    tamper("every weeks counter set to " .. step, function(r) r.t = { [100] = step, [25] = step, [10] = step, [3] = step } end)
    tamper("weeks first plus " .. step, function(r) r.t[1] = (r.t[1] or 0) + step end)
end
-- One value raised and another lowered to make up for it (what a plain chained sum would let through).
tamper("kills up, captures adjusted", function(r) r.k, r.c = r.k + 1, r.c + 2147483647 - 48271 end)
tamper("kills up, week count adjusted", function(r) r.k, r.wk = r.k + 1000, r.wk + 2147483647 - 1000 end)
-- Numbers no honest record can hold have no seal at all.
tamper("kills beyond any count", function(r) r.k = 2 ^ 48 end)
tamper("kills as a giant", function(r) r.k = 1e300 end)
tamper("kills without end", function(r) r.k = math.huge end)
tamper("a weeks counter without end", function(r) r.t[3] = math.huge end)
tamper("weeks first without end", function(r) r.t[1] = math.huge end)
tamper("a value moved from kills to captures", function(r) r.k, r.c = r.k - 25, r.c + 1 end)

tamper("kills as the text of a fortune", function(r) r.k = "999999" end)
tamper("captures beyond any count", function(r) r.c = 2 ^ 48 end)
tamper("week count beyond any count", function(r) r.wk = 2 ^ 50 end)
tamper("week start without end", function(r) r.we = math.huge end)
tamper("last week as a giant", function(r) r.lw = 1e300 end)
tamper("faction in another spelling", function(r) r.f = "alliance" end)

-- Other spellings of the same content are the same record: nothing gained, nothing refused.
for label, change in pairs({
    ["a fraction"] = function(r) r.k = r.k + 0.5 end,
    ["a number written as text"] = function(r) r.k = tostring(r.k) end,
    ["a weeks counter under a text key"] = function(r) r.t["100"] = 99 end,
    ["another key in the weeks table"] = function(r) r.t[50] = 99 end,
    ["an identifier that is not text"] = function(r) if r.g == nil then r.g = 12345 end end,
}) do
    relog()
    records()[me] = copy(honest)
    OverlordDB.ranksSetAside = nil
    change(records()[me])
    relog()
    local read = R:GetState()
    check(read.kills == honest.k and read.captures == honest.c and asideCount() == 0,
        label .. ": the same content is the same record")
    check(R:GetTopWeeks(records()[me], 100) == (honest.t and honest.t[100] or 0), label .. ": and gives no week")
end

-- A value the rank does not read (anything else in the record) changes nothing.
relog()
records()[me] = copy(honest)
OverlordDB.ranksSetAside = nil
records()[me].note = "kept"
relog()
check(R:GetState().kills == honest.k and asideCount() == 0, "a field the seal does not cover is harmless")

-- ---------------------------------------------------------------- other people's records
-- A friend's record copied under our name, or with our identifier written in it.
local friend = { k = 400000, c = 900, f = "Alliance", g = "Player-1-0000FFFF", t = { [100] = 9, [25] = 9, [10] = 9, [3] = 9 } }
friend.s = expected(friend, "Famous Friend")
check(R:IsSealed(friend, "Famous Friend"), "the friend's record is a valid record of the friend")
relog()
OverlordDB.ranksByCharacter = { [me] = copy(friend) }
OverlordCharDB = nil
OverlordDB.ranksSetAside = nil
relog()
check(R:GetState().glory == 0 and asideCount() == 1, "a friend's record under our name is refused")
relog()
local forged = copy(friend)
forged.g = guid
OverlordDB.ranksByCharacter = { ["Famous Friend"] = forged }
OverlordCharDB = nil
OverlordDB.ranksSetAside = nil
relog()
check(R:GetState().glory == 0 and records()[me] == nil and asideCount() == 1 and records()["Famous Friend"] == nil,
    "a friend's record given our identifier does not follow us as a rename")
-- The friend's record left as it is stays what it is: another character's record.
relog()
OverlordDB.ranksByCharacter = { ["Famous Friend"] = copy(friend) }
OverlordCharDB = nil
OverlordDB.ranksSetAside = nil
relog()
check(R:GetState().glory == 0 and asideCount() == 0 and records()["Famous Friend"].k == 400000,
    "a record that is not ours is neither ours nor touched")

-- ---------------------------------------------------------------- week close and seals
-- At a week close an edited record of another character of the account is set aside
-- without a word and takes no part; the honest ones are placed.
relog()
OverlordDB = { leaderboard = { campaignStart = 1793000000 } }
OverlordCharDB = nil
clock = 1793000000 + 3600
R:CreditLocal("kills", 300)
local keepName = me
me = "Second Char"
guid = "Player-1-0000DDDD"
R:CreditLocal("kills", 300)
me, guid = keepName, "Player-77-0000AAAA"
records()["Second Char"].wk = 90000
printed = {}
relog()
local bucket = { kills = { [me] = 1, ["Second Char"] = 1 }, playerInfo = {} }
local marker = { archiveEpoch = 1793000000, resetEpoch = 1793000000 + 604800, bucket = bucket }
clock = marker.resetEpoch
OverlordDB.ranksLadderSeenAt = { ["-"] = marker.resetEpoch - 60 }
local session = R:BeginWeekClose(marker)
check(session and #session.probes == 1 and session.probes[1].name == me, "only the honest record is placed")
check(records()["Second Char"] == nil and asideCount() == 1 and #printed == 0, "the edited one is set aside without a word")
R:FinishWeekClose(session)
check(records()[me].t[3] == 1 and sealedNow(), "and the honest one is credited and sealed")
-- A record that disappears between the start and the end of a close breaks nothing.
relog()
OverlordDB.leaderboard.campaignStart = 1793000000 + 604800
R:CreditLocal("kills", 300)
bucket = { kills = { [me] = 1 }, playerInfo = {} }
marker = { archiveEpoch = OverlordDB.leaderboard.campaignStart, resetEpoch = OverlordDB.leaderboard.campaignStart + 604800, bucket = bucket }
clock = marker.resetEpoch
OverlordDB.ranksLadderSeenAt = { ["-"] = marker.resetEpoch - 60 }
session = R:BeginWeekClose(marker)
records()[me] = nil
R:FinishWeekClose(session)
check(records()[me] == nil, "a record gone before the end of a close is not recreated")

-- A week only closes after its reset: an archive dated in the future is not the game's
-- (the week being played cannot be closed early with nobody above).
relog()
R:CreditLocal("kills", 300)
local early = { archiveEpoch = OverlordDB.leaderboard.campaignStart,
    resetEpoch = OverlordDB.leaderboard.campaignStart + 604800, bucket = { kills = { [me] = 1 }, playerInfo = {} } }
OverlordDB.ranksLadderSeenAt = { ["-"] = early.resetEpoch - 60 }
clock = early.resetEpoch - 2 * 86400
check(R:BeginWeekClose(early) == nil, "a week still being played cannot be closed")
early.rankSyncedAt = nil
clock = early.resetEpoch + 30
check(R:BeginWeekClose(early) ~= nil, "the same week closes once its reset has come")

-- A save stuffed with false records does not get them all checked: the close stops
-- after a few refusals, the honest record of the logged character is still placed, and
-- the rest is left alone.
relog()
local stuffed = 0
for index = 1, 500 do
    records()["Guess " .. index] = { k = 100000, c = 0, g = guid, s = index, t = { [100] = 3, [25] = 3, [10] = 3, [3] = 3 } }
    stuffed = stuffed + 1
end
OverlordDB.ranksSetAside = nil
early.rankSyncedAt = nil
session = R:BeginWeekClose(early)
check(session and #session.probes == 1 and session.probes[1].name == me, "the honest record is still placed")
local left = 0
for name in pairs(records()) do
    if type(name) == "string" and name:find("^Guess ") then left = left + 1 end
end
check(asideCount() == R.SET_ASIDE_MAX and left == stuffed - R.SET_ASIDE_MAX,
    "the close stops after a few refusals: " .. asideCount() .. " set aside, " .. left .. " left unread")
for name in pairs(records()) do
    if type(name) == "string" and name:find("^Guess ") then records()[name] = nil end
end

-- The week of a kill is the week being played: a ladder week dated long ago or in the
-- future (a date the game cannot give) counts the kill for the glory, not for a week.
relog()
OverlordDB = { leaderboard = { campaignStart = 1796000000 } }
OverlordCharDB = nil
clock = 1796000000 + 3 * 86400
R:CreditLocal("kills", 150)
check(records()[me].wk == 150 and records()[me].we == 1796000000, "a kill in the current week counts for the week")
OverlordDB.leaderboard.campaignStart = 1796000000 - 40 * 86400
R:CreditLocal("kills", 10)
check(records()[me].k == 160 and records()[me].wk == 150 and records()[me].we == 1796000000,
    "a week dated long ago takes the glory and leaves the week alone")
OverlordDB.leaderboard.campaignStart = 1796000000 + 40 * 86400
R:CreditLocal("kills", 10)
check(records()[me].k == 170 and records()[me].wk == 150 and sealedNow(), "and so does a week dated in the future")
OverlordDB.leaderboard.campaignStart = 1796000000 + 6 * 86400
clock = 1796000000 + 6 * 86400 + 600
R:CreditLocal("kills", 5)
check(records()[me].wk == 5 and records()[me].we == 1796000000 + 6 * 86400, "the next real week starts its count")

-- ---------------------------------------------------------------- the set-aside list
relog()
OverlordDB = {}
OverlordCharDB = nil
printed = {}
for index = 1, R.SET_ASIDE_MAX + 5 do
    OverlordDB.ranksByCharacter = { [me] = { k = index } }
    relog()
    R:GetState()
end
local list = OverlordDB.ranksSetAside
check(#list == R.SET_ASIDE_MAX and list[#list].r.k == R.SET_ASIDE_MAX + 5 and list[1].r.k == 6,
    "the list keeps the most recent records only")
-- Values that are not records are dropped without being kept; a damaged list is replaced.
OverlordDB.ranksByCharacter = { [me] = "text", ["Other One"] = 12, [7] = { k = 1 } }
OverlordCharDB = nil
OverlordDB.ranksSetAside = "damaged"
relog()
check(R:GetState().glory == 0 and records()[me] == nil, "a value that is not a record is dropped")
clock = 1795000000 + 604800
OverlordDB.ranksLadderSeenAt = { ["-"] = clock - 60 }
check(R:BeginWeekClose({ archiveEpoch = 1795000000, resetEpoch = 1795000000 + 604800,
    bucket = { kills = {} } }) == nil, "and a close over such a store raises nothing")
check(records()["Other One"] == nil and records()[7] == nil, "nor is a record under a key that is not a name kept")
check(type(OverlordDB.ranksSetAside) == "table" and #OverlordDB.ranksSetAside == 1 and OverlordDB.ranksSetAside[1].n == 7,
    "only real records go to the list, which is rebuilt when damaged")
-- In an instance the record is set aside all the same, without a line in the chat.
OverlordDB = { ranksByCharacter = { [me] = { k = 5 } } }
OverlordCharDB = nil
printed = {}
Overlord.InstanceSuspended = true
relog()
check(R:GetState().glory == 0 and asideCount() == 1 and #printed == 0, "silent in an instance")
Overlord.InstanceSuspended = false

-- ---------------------------------------------------------------- an honest long life
-- A long random life of an account with three characters: credits, new weeks, week
-- closes with and without a place, new sessions, renames, changed identifiers, faction
-- changes, in any order. No record is ever set aside and every total matches a plain
-- count kept beside. (Own generator: the game's and the test machines' differ.)
local rng = 20261011
local function roll(limit)
    rng = (rng * 1103515245 + 12345) % 2147483648
    return math.floor(rng / 65536) % limit + 1
end
OverlordDB = { leaderboard = { campaignStart = 1800000000 } }
OverlordCharDB = nil
printed = {}
clock = 1800000000
local cast = {
    { name = "Long Life", guid = "Player-1-00000001", faction = "Alliance", k = 0, c = 0, weeks = 0 },
    { name = "Second Life", guid = "Player-1-00000002", faction = "Horde", k = 0, c = 0, weeks = 0 },
    { name = "Third Life", guid = "Player-1-00000003", faction = "Alliance", k = 0, c = 0, weeks = 0 },
}
local who = cast[1]
local function become(actor)
    who = actor
    me, guid = actor.name, actor.guid
    Overlord.PlayerFaction = actor.faction
end
become(cast[1])
relog()
local renames = 0
for step = 1, 1500 do
    local action = roll(100)
    if action <= 45 then
        local amount = roll(40)
        R:CreditLocal("kills", amount)
        who.k = who.k + amount
        who.played = true
    elseif action <= 55 then
        R:CreditLocal("captures", 1)
        who.c = who.c + 1
    elseif action <= 67 then
        relog()
    elseif action <= 79 then
        become(cast[roll(#cast)])
        relog()
    elseif action <= 84 then
        renames = renames + 1
        who.name = "Renamed " .. string.rep("x", renames % 7 + 1) .. " " .. string.char(96 + roll(26)) .. string.char(96 + roll(26))
        become(who)
        relog()
        R:GetState()
    elseif action <= 88 then
        who.guid = "Player-" .. roll(900) .. "-" .. string.format("%08d", roll(99999999))
        become(who)
        relog()
        -- The record is read once at each login (Ranks.lua, PLAYER_LOGIN): a transfer
        -- followed by a rename stays attached to it.
        R:GetRecord(false)
    elseif action <= 91 then
        who.faction = who.faction == "Alliance" and "Horde" or "Alliance"
        become(who)
    else
        -- The week ends: the logged character's place depends on the roll.
        local start = OverlordDB.leaderboard.campaignStart
        local closing = { kills = {}, playerInfo = {} }
        for _, actor in ipairs(cast) do closing.kills[actor.name] = 1 end
        local above = roll(4) == 1 and 150 or roll(30) - 1
        for i = 1, above do
            closing.kills["Rival " .. i] = 10000000 + i
            closing.playerInfo["Rival " .. i] = { faction = "Alliance" }
            closing.kills["Enemy " .. i] = 10000000 + i
            closing.playerInfo["Enemy " .. i] = { faction = "Horde" }
        end
        local m = { archiveEpoch = start, resetEpoch = start + 604800, bucket = closing }
        clock = m.resetEpoch
        if roll(5) > 1 then OverlordDB.ranksLadderSeenAt = { ["-"] = m.resetEpoch - roll(86400) } end
        local sessionNow = R:BeginWeekClose(m)
        if sessionNow then
            for row, kills in pairs(closing.kills) do R:ProbeWeekRow(sessionNow, row, kills, closing.playerInfo) end
            if roll(6) == 1 then relog() else R:FinishWeekClose(sessionNow) end
        end
        OverlordDB.leaderboard = { campaignStart = start + 604800 }
    end
    if step % 25 == 0 or step > 1480 then
        check(asideCount() == 0, "step " .. step .. ": an honest record was set aside")
        for _, actor in ipairs(cast) do
            local rec = records() and records()[actor.name]
            if actor.played or actor.c > 0 then
                check(rec, "step " .. step .. ": the record of " .. actor.name .. " is gone")
                check(rec.k == actor.k and rec.c == actor.c, "step " .. step .. ": totals of " .. actor.name
                    .. " are " .. tostring(rec.k) .. "/" .. tostring(rec.c) .. ", expected " .. actor.k .. "/" .. actor.c)
                check(R:IsSealed(rec, actor.name), "step " .. step .. ": the record of " .. actor.name .. " lost its seal")
            end
        end
    end
end
relog()
for _, actor in ipairs(cast) do
    become(actor)
    relog()
    local final = R:GetState()
    check(final.kills == actor.k and final.captures == actor.c, "the life of " .. actor.name .. " reads back whole")
end
check(asideCount() == 0, "nothing was ever set aside in an honest life")
for _, line in ipairs(printed) do
    check(not line:find(Overlord.L.RANK_RECORD_RESET, 1, true), "and nobody was told of a reset")
end

-- ---------------------------------------------------------------- the character's own copy
-- The account save can be lost (a client that does not load it at login writes it back
-- empty at logout). The logged character's record is therefore also kept in the
-- character's own save: the same table, so always up to date. At the first read of a
-- session the copy takes over when it is validly sealed for this name and the account
-- record is missing, refused or behind.
relog()
me, guid = "Copy Keeper", "Player-1-0000CCCC"
Overlord.PlayerFaction = "Alliance"
OverlordDB = { leaderboard = { campaignStart = 1797000000 } }
OverlordCharDB = nil
clock = 1797000000 + 3600
R:CreditLocal("kills", 100)
check(OverlordCharDB.rank == records()[me], "the record is also in the character's save, as the same table")
local older = copy(records()[me])
R:CreditLocal("kills", 600)
R:CreditLocal("captures", 3)
check(OverlordCharDB.rank.k == 700 and OverlordCharDB.rank.c == 3, "and follows every write")
local saved = copy(records()[me])
local function session(account, character)
    relog()
    OverlordDB = { leaderboard = { campaignStart = 1797000000 }, ranksByCharacter = account and { [me] = account } or nil }
    OverlordCharDB = character
    printed = {}
end
local function same()
    return records() and records()[me] ~= nil and records()[me] == OverlordCharDB.rank and sealedNow()
end
-- The account save lost, the character's save loaded.
session(nil, { rank = copy(saved) })
check(R:GetRecord(false) ~= nil, "back at the login read, before any kill")
check(R:GetState().kills == 700 and R:GetState().captures == 3 and same() and asideCount() == 0 and #printed == 0,
    "the account save lost: the rank comes back from the character's copy, without a word")
R:CreditLocal("kills", 1)
check(records()[me].k == 701 and same(), "and the character goes on from it")
-- The account record behind the copy (an older account save put back), and the reverse.
session(copy(older), { rank = copy(saved) })
check(R:GetState().kills == 700 and same() and asideCount() == 0 and #printed == 0, "the further of the two is the record")
session(copy(saved), { rank = copy(older) })
check(R:GetState().kills == 700 and same() and asideCount() == 0, "whichever file holds it")
session(copy(saved), { rank = copy(saved) })
check(R:GetState().kills == 700 and same(), "two equal records are one record")
-- Same kills, the order goes on: captures, then the last counted week.
R:CreditLocal("captures", 1)
local oneMore = copy(records()[me])
session(copy(saved), { rank = copy(oneMore) })
check(R:GetState().captures == 4 and same(), "one capture more is further")
session(copy(oneMore), { rank = copy(saved) })
check(R:GetState().captures == 4 and same(), "from either file")
-- The character's save lost: the account record goes into a new copy.
session(copy(saved), nil)
check(R:GetState().kills == 700 and same(), "the character's save lost: written again from the account's")
-- A copy changed by hand is worth nothing, whatever the account holds.
local raised = copy(saved)
raised.k = 99999
session(copy(saved), { rank = raised })
check(R:GetState().kills == 700 and same() and asideCount() == 0 and #printed == 0, "an edited copy is ignored")
session(nil, { rank = copy(raised) })
check(R:GetState().kills == 0 and R:GetRecord(false) == nil and asideCount() == 0, "even when it is all there is")
R:CreditLocal("kills", 2)
check(records()[me].k == 2 and same(), "and the next write replaces it")
-- An account record changed by hand, an honest copy: the honest record comes back in
-- silence and the edited one is kept aside. Both changed: set aside and said, as before.
local edited = copy(saved)
edited.k = 99999
session(edited, { rank = copy(saved) })
check(R:GetState().kills == 700 and same() and #printed == 0, "an edited account record gives way to the honest copy")
check(asideCount() == 1 and OverlordDB.ranksSetAside[1].r == edited, "and is kept aside")
session(copy(edited), { rank = copy(raised) })
check(R:GetState().kills == 0 and asideCount() == 1 and #printed == 1
    and printed[1]:find(Overlord.L.RANK_RECORD_RESET, 1, true), "both edited: set aside and said")
-- Somebody else's record as the copy, or anything that is not a record.
local stranger = { k = 400000, c = 900, f = "Alliance", g = "Player-1-0000FFFF" }
stranger.s = expected(stranger, "Famous Friend")
session(copy(saved), { rank = stranger })
check(R:GetState().kills == 700 and same(), "another character's record is not our copy")
session(nil, { rank = copy(stranger) })
check(R:GetState().kills == 0, "even alone")
for _, junk in ipairs({ "x", 7, true }) do
    session(copy(saved), junk)
    check(R:GetState().kills == 700 and type(OverlordCharDB) == "table" and same(), "a character's save that is not a table is replaced")
    session(copy(saved), { rank = junk })
    check(R:GetState().kills == 700 and same(), "a copy that is not a record is replaced")
end
-- A rename: the copy under the new name does not exist yet; the account's record follows
-- by its identifier, and the copy is written under the new name.
session(copy(saved), nil)
R:GetState()
local oldName = me
me = "Copy Keeper Renamed"
relog()
OverlordCharDB = nil
check(R:GetState().kills == 700 and records()[oldName] == nil and same(), "a renamed character gets its copy too")
OverlordCharDB = nil

print("Forever ranks seal: frozen formula, every write sealed, hand edits set aside, 1500 honest steps OK")
