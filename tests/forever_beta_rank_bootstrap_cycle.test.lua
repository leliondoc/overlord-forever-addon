-- A missing historical ACK must not put a long v4 exchange ahead of the first
-- complete v6 ranking sweep. Once v6 succeeds, a reload gives v4 its turn.
local now = 1790020000
Overlord = {
    Sync = {}, Leaderboard = { NETWORK_KILL_RANK_LIMIT = 500 },
    BetaNetworkEnabled = true,
}
function Overlord:GetCurrentCampaignStartTs() return 1790016000 end
OverlordDB = { campaignId = 1 }
function GetTime() return 100 end
function time() return now end
function GetServerTime() return now end
function IsInInstance() return false end
C_Timer = { After = function() end }
assert(loadfile("SyncHistoryCatchup.lua"))()
Overlord.Sync.StartCompletePagedLeaderboardCatchup = function() return true end

assert(Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
assert(Overlord.Sync._historyCatchupPending.ladderOnly == true,
    "No-ACK login did not prioritise the complete paged ranking")

-- A successful v6 round persists this campaign id before its v4 wake. A
-- simulated reload retains the DB but replaces the in-memory scheduler.
OverlordDB.leaderboardRankFirstCompletedCampaignId = 1
Overlord.Sync._historyCatchupPending = nil
assert(Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
assert(Overlord.Sync._historyCatchupPending.ladderOnly == false,
    "Reload repeated v6 after it succeeded and starved historical v4")

-- A new campaign must begin with its own ranking sweep even when the old
-- campaign's successful marker remains in SavedVariables.
Overlord.Sync._historyCatchupPending = nil
OverlordDB.campaignId = 2
assert(Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp())
assert(Overlord.Sync._historyCatchupPending.ladderOnly == true,
    "Old campaign marker suppressed the new campaign's complete ranking")
print("Beta ranking bootstrap: v6 first, v4 after completed reload, new campaign v6")
