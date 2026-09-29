-- 2026-09-29 : a priest's 3434 HK from the previous campaign reappeared in the new week.
-- No save or stamp path may relabel another week's scores as the current campaign.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local campaign = OverlordDB.lastResetTimestamp
local lastWeek = campaign - 604800

-- A Save between the weekly boundary and the reset swap keeps the old label, so the
-- write guard still sees a stale bucket and runs the reset.
lb.kills["Previous Week"] = 3434
OverlordDB.leaderboard.campaignStart = lastWeek
lb:Save()
assert(OverlordDB.leaderboard.campaignStart == lastWeek,
    "Save relabelled a previous-week score table as the current campaign")
assert(not lb:IsCurrentCampaignBucket(), "Previous-week scores became writable")
-- Current-campaign tables are still stamped normally.
OverlordDB.leaderboard.campaignStart = campaign
lb:Save()
assert(OverlordDB.leaderboard.campaignStart == campaign, "Current table lost its stamp")

-- The direct stamp refuses another week; the stale-marker resync archives and empties
-- the bucket at once instead of relabelling it or blocking writes until the next login.
OverlordDB.leaderboard.campaignStart = lastWeek
assert(lb:StampCurrentCampaignBucket(OverlordDB.leaderboard) == false
    and OverlordDB.leaderboard.campaignStart == lastWeek, "Stamp relabelled a previous week")
OverlordDB.lastResetTimestamp = campaign
OverlordDB.leaderboardResetEpoch = lastWeek
OverlordDB.pendingWeeklyResetAt = nil
OverlordDB.pendingWeeklyArchive = nil
Overlord:CheckWeeklyReset()
assert(OverlordDB.leaderboard.campaignStart == campaign
    and OverlordDB.leaderboard.kills["Previous Week"] == nil
    and lb.kills["Previous Week"] == nil, "Stale marker resync carried last week into this week")
assert(type(OverlordDB.pendingWeeklyArchive) == "table"
    and OverlordDB.pendingWeeklyArchive.bucket.kills["Previous Week"] == 3434,
    "Last week's scores were not archived")
print("Forever stale week: save, stamp and marker resync never relabel previous-week scores OK")
