-- 2.1.0: Overlord Rank starts again from zero at the game's launch (the weekly reset of
-- Tuesday 2026-11-03 08:00 UTC). From that moment a record is sealed with one more step:
-- a record of the beta (sealed before) never reads back, even put back by hand into a
-- save, and is set aside without a word; the character starts again from zero. Records
-- sealed after the launch read back as always. A session across the launch forgets what
-- it had verified. The week closed at the launch is a beta week: nothing credited.
-- Real Ranks.lua and RankLocales.lua.

local function check(cond, msg) if not cond then error(msg, 2) end end

local LAUNCH = 1793692800
local me, guid, clock = "Aldric Vane", "Player-1-0000AAAA", LAUNCH - 3600
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
local function relog()
    dofile("Ranks.lua")
    R = Overlord.Ranks
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end
local function aside() return type(OverlordDB.ranksSetAside) == "table" and #OverlordDB.ranksSetAside or 0 end

check(R.LAUNCH_RESET_AT == LAUNCH, "the launch is not the weekly reset of 2026-11-03 08:00 UTC")
check(not Overlord.L.RANK_LAUNCH_RESET, "a chat line tells players about the launch reset")

-- (1) Beta: Glory earned and read back before the launch.
R:CreditLocal("kills", 600)
R:CreditLocal("captures", 10)
local betaRecord = OverlordDB.ranksByCharacter[me]
local betaSaved = copy(betaRecord)
check(betaRecord and betaRecord.k == 600 and betaRecord.c == 10, "fixture: the beta record was not credited")
relog()
check(R:GetRecord(false) == betaRecord and aside() == 0, "a beta record did not read back before the launch")

-- (2) The first session from the launch on: zero, the beta record aside, nothing said.
clock = LAUNCH + 60
printed = {}
relog()
local state = R:GetState()
check(state and state.kills == 0 and state.captures == 0, "the rank did not start again from zero")
check(aside() >= 1 and OverlordDB.ranksSetAside[aside()].r.k == 600, "the beta record was not kept aside")
check(#printed == 0, "the player was told: " .. tostring(printed[1]))

-- (3) After it: new Glory counts and reads back in later sessions.
R:CreditLocal("kills", 5)
local launchRecord = OverlordDB.ranksByCharacter[me]
check(launchRecord and launchRecord.k == 5, "a kill after the launch was not counted")
clock = LAUNCH + 8 * 86400
relog()
check(R:GetRecord(false) == launchRecord and launchRecord.k == 5 and #printed == 0, "a launch record did not read back")

-- (4) The beta record put back by hand, in the account save or the character's: refused.
OverlordDB.ranksByCharacter[me] = copy(betaSaved)
relog()
-- (the launch record, kept in the character's save, takes its place back)
check(R:GetState().kills == 5 and #printed == 0, "a beta record put back by hand was read back")
OverlordDB.ranksByCharacter = {}
OverlordCharDB = { rank = copy(betaSaved) }
relog()
check(R:GetState().kills == 0, "a beta copy put back into the character's save was read back")
check(#printed == 0, "a refused beta record was announced")

-- (5) A session open across the launch: what it verified before is verified again.
OverlordDB, OverlordCharDB = {}, nil
clock = LAUNCH - 600
relog()
R:CreditLocal("kills", 300)
check(R:GetState().kills == 300, "fixture: no record before the launch")
clock = LAUNCH + 30
check(R:GetState().kills == 0, "a session across the launch kept its beta record")

-- (6) The week closed at the launch's reset is a beta week: a real close of it (synced and
-- played in its last day, 2000 kills of the week, a ladder row) finds no record to credit.
local BETA_WEEK = LAUNCH - 7 * 86400
local function weekMarker()
    return { bucket = { kills = { [me] = 2000 }, playerInfo = {} }, archiveEpoch = BETA_WEEK,
        resetEpoch = LAUNCH, rankSyncedAt = LAUNCH - 3600, rankPlayedAt = LAUNCH - 3600 }
end
OverlordDB, OverlordCharDB = { leaderboard = { campaignStart = BETA_WEEK } }, nil
clock = LAUNCH - 7200
relog()
R:CreditLocal("kills", 2000)
check(OverlordDB.ranksByCharacter[me].wk == 2000, "fixture: the beta week has no kills")
clock = LAUNCH + 30
-- (Control: the same close without the launch seal would probe this record.)
relog()
R.LAUNCH_RESET_AT = math.huge
local control = R:BeginWeekClose(weekMarker())
check(control and #control.probes == 1 and control.probes[1].kills == 2000, "fixture: the close probes nothing")
relog()
local session = R:BeginWeekClose(weekMarker())
check(session == nil, "the week closed at the launch was credited to a beta record")

-- (7) Kills of the first seconds after the launch, before the ladder's own reset: Glory,
-- never the beta's last week; from the ladder's reset on, the new week counts.
OverlordDB, OverlordCharDB = { leaderboard = { campaignStart = BETA_WEEK } }, nil
clock = LAUNCH + 5
relog()
R:CreditLocal("kills", 3)
local early = OverlordDB.ranksByCharacter[me]
check(early.k == 3 and (early.wk or 0) == 0 and (early.we or 0) == 0, "a kill at the launch counted for the beta week")
OverlordDB.leaderboard.campaignStart = LAUNCH
R:CreditLocal("kills", 1)
check(early.k == 4 and early.wk == 1 and early.we == LAUNCH, "the launch week does not count")

print("Forever ranks launch reset: beta records never read back after 2026-11-03 08:00 UTC, "
    .. "even put back by hand; set aside silently; launch records read back; nothing said")
