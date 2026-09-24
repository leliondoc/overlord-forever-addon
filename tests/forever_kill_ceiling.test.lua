-- Exercise real K/LK receivers and storage guards at the synchronization ceiling.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local sync, lb = Overlord.Sync, Overlord.Leaderboard
assert(Overlord.PLAUSIBLE_SYNC_KILL_CEILING == 5000)
assert(lb.KILL_RANK_LIMIT == 500, "Score ceiling changed the ranking population")
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
for _, total in ipairs({ 1000, 1001, 4999, 5000 }) do
    sync:OnReceiveKill(killPayload(total), live)
    sync:OnReceiveLeaderboardKills(snapshotPayload(total), snapshot, "WHISPER")
    assert(lb.kills[live] == total, "K rejected legitimate total " .. total)
    assert(lb.kills[snapshot] == total, "LK rejected legitimate total " .. total)
end
for _, total in ipairs({ 5001, 9999 }) do
    assert(sync:SanitizeSyncedKillTotal(total) == nil)
    sync:OnReceiveKill(killPayload(total), live)
    sync:OnReceiveLeaderboardKills(snapshotPayload(total), snapshot, "WHISPER")
    assert(lb.kills[live] == 5000 and lb.kills[snapshot] == 5000,
        "Oversized remote total changed a score")
end
sync:OnReceiveKill(killPayload(1000), live)
sync:OnReceiveLeaderboardKills(snapshotPayload(1000), snapshot, "WHISPER")
assert(lb.kills[live] == 5000 and lb.kills[snapshot] == 5000,
    "Old peer regressed a current score")
assert(#killPayload(1000) == #killPayload(5000), "New ceiling grew K payloads")
assert(#snapshotPayload(1000) == #snapshotPayload(5000), "New ceiling grew LK payloads")

local additive = "Additive Tester"
lb:SetPlayerKills(additive, 4999, true)
assert(lb:RegisterKill(additive, true) == 5000)
assert(lb:RegisterKill(additive, true) == 5000)
assert(lb:AddKills(additive, 2, true) == 5000)
local batch = "Batch Tester"
lb:SetPlayerKills(batch, 4999, true)
assert(lb:AddKills(batch, 20, true) == 5000, "Synced batch crossed the ceiling")
lb:SetPlayerKills("Rejected Tester", 5001, true)
assert(lb.kills["Rejected Tester"] == nil, "Rejected total became a capped row")

-- This is a network plausibility filter, not a cap on Blizzard's local HKs.
local me = sync:GetPlayerFullName()
lb:SetPlayerKills(me, 5000)
assert(lb:RegisterKill(me) == 5001, "Local HK counting was capped")
assert(lb:AddKills(me, 2) == 5003, "Local batched HK counting was capped")
lb:Save()
assert(OverlordDB.leaderboard.kills[live] == 5000, "Save lost the raised score")

-- The existing sliced sanitizer must preserve newly valid remote scores in
-- every bucket it repairs, while still removing oversized remote data.
local timers, head = {}, 1
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
lb.kills["Corrupt Tester"] = 9999
OverlordDB.leaderboardsByPool = { global = { kills = {
    [live] = 1001, [snapshot] = 5000, ["Corrupt Tester"] = 9999,
} } }
OverlordDB.leaderboardSnapshot = { kills = {
    [live] = 1001, [snapshot] = 5000, ["Corrupt Tester"] = 5001,
} }
OverlordDB.leaderboardScoreSanitizeVersion = 3
lb:EnsureLegacyScoreSanitized()
while head <= #timers do
    assert(head < 100, "Cleanup failed to finish in bounded slices")
    local callback = timers[head]
    head = head + 1
    callback()
end
assert(OverlordDB.leaderboardScoreSanitizeVersion == 4)
for _, bucket in ipairs({ OverlordDB.leaderboard, OverlordDB.leaderboardsByPool.global,
    OverlordDB.leaderboardSnapshot }) do
    assert(bucket.kills[live] >= 1001 and bucket.kills[snapshot] == 5000,
        "Saved-score sanitizer removed a newly valid score")
    assert(bucket.kills["Corrupt Tester"] == nil, "Oversized saved score survived cleanup")
end
assert(lb.kills[me] == 5003, "Remote-score cleanup erased local HKs")
local rows = lb:GetSortedKills(500)
assert(rows[1].name == me and rows[1].kills == 5003, "Larger scores broke ranking order")
print("Forever kill ceiling: K/LK 1001..5000, rejection, monotonic merge, additive guards, local HKs, save/cleanup and ranking OK")
