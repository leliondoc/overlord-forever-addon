-- Ranking sync badge (1.8.1): the leaderboard header shows a green arrow while
-- ranking catch-up still brings missing rows, and a green check once a full sweep
-- with a neighbour found (almost) nothing to fetch. Read-only state: nothing is sent.
local now, clock = 1790020000, 100
local timers = {}
local peers = { "Near Ally" }
Overlord = {
    Sync = {}, Leaderboard = { NETWORK_KILL_RANK_LIMIT = 500 },
    RelayEnabled = true, PlayerFaction = "Alliance",
    Relay = {
        GetDirectPeers = function() return peers end,
        GetPeerPagedProtocol = function() return 8 end,
    },
}
local campaignStart = now - 7200
function Overlord:GetCurrentCampaignStartTs() return campaignStart end
OverlordDB = { campaignId = 1 }
function GetTime() return clock end
function time() return now end
function GetServerTime() return now end
function IsInInstance() return false end
function InCombatLockdown() return false end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
assert(loadfile("SyncHistoryCatchup.lua"))()
local sync = Overlord.Sync
local repaint = 0
Overlord.LeaderboardUI = { IsShown = function() return true end, RefreshSyncBadge = function() repaint = repaint + 1 end }

local nextSweep = { filtered = false, changed = 0 }
sync.StartCompletePagedLeaderboardCatchup = function(_, _, callback)
    sync._leaderboardPageStats = { protocol = 8, lastSweepFiltered = nextSweep.filtered,
        lastSweepChanged = nextSweep.changed }
    callback(true, true)
    return true
end
sync.RequestOutpostHistory = function() return true end
local function runUntil(done)
    local guard = 0
    while not done() and #timers > 0 do
        guard = guard + 1
        assert(guard < 50, "rounds did not settle")
        table.remove(timers, 1)()
    end
end
local function round(filtered, changed)
    nextSweep.filtered, nextSweep.changed = filtered, changed
    timers = {}
    sync._historyCatchupPending = nil
    assert(sync:ScheduleLoginLeaderboardHistoryCatchUp(true))
    table.remove(timers, 1)()
    table.remove(timers, 1)()
end
local function state() return (sync:GetLadderCatchupState()) end

-- Before any round: still syncing.
assert(state() == "SYNCING", "no round yet but not syncing: " .. tostring(state()))
-- A pull running reports its stream step.
sync.GetPagedPullProgress = function() return true, 2, false end
local s, reason, step = sync:GetLadderCatchupState()
assert(s == "SYNCING" and reason == "pulling" and step == 2, "running pull not reported")
sync.GetPagedPullProgress = function() return false end

-- A full sweep that still brought many rows: not caught up yet.
round(false, 40)
assert(state() == "SYNCING", "a sweep that brought 40 rows already showed the check")
-- The next full sweep is quiet: up to date, and the badge was asked to repaint.
repaint = 0
round(false, 0)
assert(state() == "UP_TO_DATE", "a quiet full sweep did not show the check")
assert(repaint >= 1, "the end of the round did not repaint the badge")
-- Reading the state never changes anything.
local before = #timers
for _ = 1, 1000 do sync:GetLadderCatchupState() end
assert(#timers == before, "reading the badge state scheduled work")
-- A few rows (live kills in between) keep it up to date.
round(false, 2)
assert(state() == "UP_TO_DATE", "a sweep with two live rows dropped the check")

-- 15 min without a successful round: back to the arrow.
now = now + 15 * 60 + 1
assert(state() == "SYNCING", "a stale check did not go back to the arrow")

-- Enemy-only sweeps compare enemy rows only: the third quiet one in a row counts.
round(true, 0)
assert(state() == "SYNCING", "one enemy-only sweep showed the check")
round(true, 0)
assert(state() == "SYNCING", "two enemy-only sweeps showed the check")
round(true, 0)
assert(state() == "UP_TO_DATE", "three quiet enemy-only sweeps did not show the check")
-- While up to date, an enemy-only quiet sweep keeps it fresh.
now = now + 10 * 60
round(true, 0)
now = now + 10 * 60
assert(state() == "UP_TO_DATE", "an enemy-only sweep did not keep a fresh check")
-- A busy sweep (rows still missing) removes the check at once.
round(true, 50)
assert(state() == "SYNCING", "a sweep that brought 50 rows kept the check")

-- After a long instance (trust floor moved forward): arrow until the next full round.
round(false, 0)
assert(state() == "UP_TO_DATE")
sync._ladderTrustFloor = now + 1
now = now + 2
assert(state() == "SYNCING", "a long instance kept the check")
round(false, 0)
assert(state() == "UP_TO_DATE", "the round after a long instance did not restore the check")

-- No neighbour: arrow during a 60 s grace, then hidden ("unknown"), and back as soon
-- as a neighbour is picked.
now = now + 20 * 60
peers = {}
timers = {}
sync._historyCatchupPending = nil
assert(sync:ScheduleLoginLeaderboardHistoryCatchUp(true))
table.remove(timers, 1)()
table.remove(timers, 1)()
assert(state() == "SYNCING", "no neighbour hid the badge at once")
clock = clock + 61
local st, why = sync:GetLadderCatchupState()
assert(st == "UNKNOWN" and why == "no_peer", "no neighbour for a minute did not hide the badge")
peers = { "Near Ally" }
repaint = 0
runUntil(function() return sync._historyCatchupStats.noPeerSince == nil end)
assert(sync._historyCatchupStats.noPeerSince == nil and repaint >= 1, "a neighbour coming back was not noticed")

-- A new campaign: no round in its first 30 min, nothing is downloading.
OverlordDB.campaignId = 2
campaignStart = now - 60
st, why = sync:GetLadderCatchupState()
assert(st == "UNKNOWN" and why == "new_campaign", "a new campaign showed the badge")
-- The ack of the previous campaign is ignored.
campaignStart = now - 7200
assert(state() == "SYNCING", "the previous campaign's check carried over")

-- Instance: suspended.
Overlord.InstanceSuspended = true
assert(state() == "SUSPENDED", "the badge ignored the instance")
Overlord.InstanceSuspended = nil

print("Ranking sync badge: arrow while sweeps bring rows, check after a quiet full sweep, staleness, enemy-only rule, instance, no-neighbour grace, campaign OK")
