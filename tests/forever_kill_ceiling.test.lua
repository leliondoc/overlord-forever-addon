-- Exercise real K/LK receivers and storage guards at the synchronization ceiling.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local sync, lb = Overlord.Sync, Overlord.Leaderboard
assert(Overlord.PLAUSIBLE_SYNC_KILL_CEILING == 15000)
assert(lb.KILL_RANK_LIMIT == 5000, "Score ceiling changed the ranking population")
-- A six-day-old campaign: the first-contact cap (300 + 0.03/s since the reset) is
-- above 15000, so only the global and per-level ceilings act here.
OverlordDB.lastResetTimestamp = time() - 6 * 86400
if Overlord.ResetCampaignStartCache then Overlord:ResetCampaignStartCache() end
local epoch = OverlordDB.lastResetTimestamp
-- The campaign start is otherwise computed from today's date: pin it, or the
-- first-contact cap (and this test) would depend on the day of the week.
Overlord.GetCurrentCampaignStartTs = function() return epoch end
-- 1.4.2: a total also has a per-level ceiling (350 per level above 1, 2000 at least,
-- 15000 from level 30, the beta's cap) and a
-- growth bound per subject (+30 kills + 1/s); the ceiling itself is exercised with
-- level-60 subjects, one fresh subject per total.
local live, snapshot = "Remote Tester", "Snapshot Tester"
local function killPayload(total, name, level)
    return assert(sync:BuildKillBroadcastPayload(name or live, "", total, "WARRIOR", "Alliance",
        epoch, "", "enus", 0, epoch, level or 60))
end
local function snapshotPayload(total, name, level)
    return (name or snapshot) .. ":" .. total .. ":WARRIOR:Alliance:" .. epoch
        .. ":enus::0:B" .. epoch .. ":" .. (level or 60)
end
for i, total in ipairs({ 1000, 1001, 4999, 5000, 6017, 14999, 15000 }) do
    local liveName = "Remote Tester" .. string.char(96 + i)
    local snapName = "Snapshot Tester" .. string.char(96 + i)
    sync:OnReceiveKill(killPayload(total, liveName), liveName)
    sync:OnReceiveLeaderboardKills(snapshotPayload(total, snapName), snapName, "WHISPER")
    assert(lb.kills[liveName] == total, "K rejected legitimate total " .. total)
    assert(lb.kills[snapName] == total, "LK rejected legitimate total " .. total)
end
-- Level ceiling: a level 14 character cannot hold more than 4550 kills in a week.
sync:OnReceiveKill(killPayload(4550, "Lowbie Tester", 14), "Lowbie Tester")
assert(lb.kills["Lowbie Tester"] == 4550, "level 14 total at the ceiling was rejected")
sync:OnReceiveKill(killPayload(5000, "Lowbie Cheater", 14), "Lowbie Cheater")
assert(lb.kills["Lowbie Cheater"] == 4550, "level 14 total above the ceiling was not clamped to it")
assert(sync:MaxPlausibleKillsForLevel(60) == 15000 and sync:MaxPlausibleKillsForLevel(1) == 2000)
-- The beta is capped at level 30, where honest players near 6000 kills: full ceiling.
assert(sync:MaxPlausibleKillsForLevel(30) == 15000 and sync:MaxPlausibleKillsForLevel(29) == 9800)
sync:OnReceiveKill(killPayload(6017, "Capped Tester", 30), "Capped Tester")
assert(lb.kills["Capped Tester"] == 6017, "level 30 honest total was clamped")
live, snapshot = "Remote Testerg", "Snapshot Testerg" -- the 15000 rows above
for _, total in ipairs({ 15001, 99999 }) do
    assert(sync:SanitizeSyncedKillTotal(total) == nil)
    sync:OnReceiveKill(killPayload(total), live)
    sync:OnReceiveLeaderboardKills(snapshotPayload(total), snapshot, "WHISPER")
    assert(lb.kills[live] == 15000 and lb.kills[snapshot] == 15000,
        "Oversized remote total changed a score")
end
sync:OnReceiveKill(killPayload(1000), live)
sync:OnReceiveLeaderboardKills(snapshotPayload(1000), snapshot, "WHISPER")
assert(lb.kills[live] == 15000 and lb.kills[snapshot] == 15000,
    "Old peer regressed a current score")
-- Five-digit totals still fit the addon message limit (K <= 250 bytes).
assert(#killPayload(15000) <= 250 and #snapshotPayload(15000) <= 250, "Ceiling totals overflow payloads")

local additive = "Additive Tester"
lb:SetPlayerKills(additive, 14999, true)
assert(lb:RegisterKill(additive, true) == 15000)
assert(lb:RegisterKill(additive, true) == 15000)
assert(lb:AddKills(additive, 2, true) == 15000)
local batch = "Batch Tester"
lb:SetPlayerKills(batch, 14999, true)
assert(lb:AddKills(batch, 20, true) == 15000, "Synced batch crossed the ceiling")
lb:SetPlayerKills("Rejected Tester", 15001, true)
assert(lb.kills["Rejected Tester"] == nil, "Rejected total became a capped row")

-- This is a network plausibility filter, not a cap on Blizzard's local HKs.
local me = sync:GetPlayerFullName()
lb:SetPlayerKills(me, 15000)
assert(lb:RegisterKill(me) == 15001, "Local HK counting was capped")
assert(lb:AddKills(me, 2) == 15003, "Local batched HK counting was capped")
lb:Save()
assert(OverlordDB.leaderboard.kills[live] == 15000, "Save lost the raised score")

-- The existing sliced sanitizer must preserve newly valid remote scores in
-- every bucket it repairs, while still removing oversized remote data.
local timers, head = {}, 1
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
lb.kills["Corrupt Tester"] = 99999
OverlordDB.leaderboardsByPool = { global = { kills = {
    [live] = 1001, [snapshot] = 15000, ["Corrupt Tester"] = 99999,
} } }
OverlordDB.leaderboardSnapshot = { kills = {
    [live] = 1001, [snapshot] = 15000, ["Corrupt Tester"] = 15001,
} }
OverlordDB.leaderboardScoreSanitizeVersion = 3
lb:EnsureLegacyScoreSanitized()
while head <= #timers do
    assert(head < 100, "Cleanup failed to finish in bounded slices")
    local callback = timers[head]
    head = head + 1
    callback()
end
assert(OverlordDB.leaderboardScoreSanitizeVersion == 7)
for _, bucket in ipairs({ OverlordDB.leaderboard, OverlordDB.leaderboardsByPool.global,
    OverlordDB.leaderboardSnapshot }) do
    assert(bucket.kills[live] >= 1001 and bucket.kills[snapshot] == 15000,
        "Saved-score sanitizer removed a newly valid score")
    assert(bucket.kills["Corrupt Tester"] == nil, "Oversized saved score survived cleanup")
end
assert(lb.kills[me] == 15003, "Remote-score cleanup erased local HKs")
local rows = lb:GetSortedKills(500)
assert(rows[1].name == me and rows[1].kills == 15003, "Larger scores broke ranking order")
print("Forever kill ceiling: K/LK 1001..15000, rejection, monotonic merge, additive guards, local HKs, save/cleanup and ranking OK")
