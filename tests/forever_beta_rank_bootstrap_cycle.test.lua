-- Ranking bootstrap (1.2.4): every round is a complete v6 sweep with a direct
-- neighbour; the outpost/fortress history (SR "H") follows once per six hours;
-- a new campaign starts both over.
local now = 1790020000
local timers = {}
Overlord = {
    Sync = {}, Leaderboard = { NETWORK_KILL_RANK_LIMIT = 500 },
    BetaNetworkEnabled = true, PlayerFaction = "Alliance",
    BetaNetwork = {
        GetDirectPeers = function() return { "Near Ally" } end,
        GetPeerPagedProtocol = function() return 6 end,
    },
}
function Overlord:GetCurrentCampaignStartTs() return 1790016000 end
OverlordDB = { campaignId = 1 }
function GetTime() return 100 end
function time() return now end
function GetServerTime() return now end
function IsInInstance() return false end
function InCombatLockdown() return false end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
assert(loadfile("SyncHistoryCatchup.lua"))()
local sync = Overlord.Sync
local sweeps, history = 0, {}
sync.StartCompletePagedLeaderboardCatchup = function(_, peer, callback)
    assert(peer == "Near Ally", "Ranking asked a non-direct peer: " .. tostring(peer))
    sweeps = sweeps + 1
    callback(true, true)
    return true
end
sync.RequestOutpostHistory = function(_, peer) history[#history + 1] = peer; return true end
local function round(force)
    timers = {}
    sync._historyCatchupPending = nil
    assert(sync:ScheduleLoginLeaderboardHistoryCatchUp(force))
    -- Initial delay, then the first attempt; later wakes are not run here.
    table.remove(timers, 1)()
    table.remove(timers, 1)()
end

round()
assert(sweeps == 1, "Login did not start the v6 ranking")
assert(OverlordDB.leaderboardRankFirstCompletedCampaignId == 1, "Completed sweep was not persisted")
assert(#history == 1 and history[1] == "Near Ally", "Outpost history was not requested after the sweep")

round(true)
assert(sweeps == 2 and #history == 1, "Outpost history repeated within six hours")

now = now + 6 * 60 * 60 + 1
round(true)
assert(sweeps == 3 and #history == 2, "Outpost history not refreshed after six hours")

OverlordDB.campaignId = 2
round(true)
assert(sweeps == 4 and #history == 3, "A new campaign did not restart ranking and history")
assert(OverlordDB.leaderboardRankFirstCompletedCampaignId == 2)
print("Beta ranking bootstrap: v6 with a direct neighbour, outpost history every 6 h, new campaign restarts")
