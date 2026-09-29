-- Exercise real K/LK receivers and storage guards at the synchronization ceiling.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local sync, lb = Overlord.Sync, Overlord.Leaderboard
assert(Overlord.PLAUSIBLE_SYNC_KILL_CEILING == 10000)
assert(lb.KILL_RANK_LIMIT == 5000, "Score ceiling changed the ranking population")
local epoch = OverlordDB.lastResetTimestamp
local live, snapshot = "Remote Tester", "Snapshot Tester"
local function killPayload(total)
    return assert(sync:BuildKillBroadcastPayload(live, "", total, "WARRIOR", "Alliance",
        epoch, "", "enus", 0, epoch, 2))
end
local function snapshotPayload(total)
    return snapshot .. ":" .. total .. ":WARRIOR:Alliance:" .. epoch
        .. ":enus::0:B" .. epoch .. ":2"
end
for _, total in ipairs({ 1000, 1001, 4999, 5000, 6017, 9999, 10000 }) do
    sync:OnReceiveKill(killPayload(total), live)
    sync:OnReceiveLeaderboardKills(snapshotPayload(total), snapshot, "WHISPER")
    assert(lb.kills[live] == total, "K rejected legitimate total " .. total)
    assert(lb.kills[snapshot] == total, "LK rejected legitimate total " .. total)
end
for _, total in ipairs({ 10001, 99999 }) do
    assert(sync:SanitizeSyncedKillTotal(total) == nil)
    sync:OnReceiveKill(killPayload(total), live)
    sync:OnReceiveLeaderboardKills(snapshotPayload(total), snapshot, "WHISPER")
    assert(lb.kills[live] == 10000 and lb.kills[snapshot] == 10000,
        "Oversized remote total changed a score")
end
sync:OnReceiveKill(killPayload(1000), live)
sync:OnReceiveLeaderboardKills(snapshotPayload(1000), snapshot, "WHISPER")
assert(lb.kills[live] == 10000 and lb.kills[snapshot] == 10000,
    "Old peer regressed a current score")
-- Five-digit totals still fit the addon message limit (K <= 250 bytes).
assert(#killPayload(10000) <= 250 and #snapshotPayload(10000) <= 250, "Ceiling totals overflow payloads")

local additive = "Additive Tester"
lb:SetPlayerKills(additive, 9999, true)
assert(lb:RegisterKill(additive, true) == 10000)
assert(lb:RegisterKill(additive, true) == 10000)
assert(lb:AddKills(additive, 2, true) == 10000)
local batch = "Batch Tester"
lb:SetPlayerKills(batch, 9999, true)
assert(lb:AddKills(batch, 20, true) == 10000, "Synced batch crossed the ceiling")
lb:SetPlayerKills("Rejected Tester", 10001, true)
assert(lb.kills["Rejected Tester"] == nil, "Rejected total became a capped row")

-- This is a network plausibility filter, not a cap on Blizzard's local HKs.
local me = sync:GetPlayerFullName()
lb:SetPlayerKills(me, 10000)
assert(lb:RegisterKill(me) == 10001, "Local HK counting was capped")
assert(lb:AddKills(me, 2) == 10003, "Local batched HK counting was capped")
lb:Save()
assert(OverlordDB.leaderboard.kills[live] == 10000, "Save lost the raised score")

-- The existing sliced sanitizer must preserve newly valid remote scores in
-- every bucket it repairs, while still removing oversized remote data.
local timers, head = {}, 1
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
lb.kills["Corrupt Tester"] = 99999
OverlordDB.leaderboardsByPool = { global = { kills = {
    [live] = 1001, [snapshot] = 10000, ["Corrupt Tester"] = 99999,
} } }
OverlordDB.leaderboardSnapshot = { kills = {
    [live] = 1001, [snapshot] = 10000, ["Corrupt Tester"] = 10001,
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
    assert(bucket.kills[live] >= 1001 and bucket.kills[snapshot] == 10000,
        "Saved-score sanitizer removed a newly valid score")
    assert(bucket.kills["Corrupt Tester"] == nil, "Oversized saved score survived cleanup")
end
assert(lb.kills[me] == 10003, "Remote-score cleanup erased local HKs")
local rows = lb:GetSortedKills(500)
assert(rows[1].name == me and rows[1].kills == 10003, "Larger scores broke ranking order")
print("Forever kill ceiling: K/LK 1001..10000, rejection, monotonic merge, additive guards, local HKs, save/cleanup and ranking OK")
