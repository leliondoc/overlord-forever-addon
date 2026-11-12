-- 2.5.1: the login restore of the saved ladder walks up to three 10,000-row tables;
-- one frame took 7 ms on a 4,200-player save and 17 ms at 10,000. The login stage
-- now steps it in 1 ms slices: same writes as the one-pass call, and a bucket
-- swapped between two slices (weekly reset) ends the walk.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local epoch = OverlordDB.lastResetTimestamp
assert(lb.StepFullLadderSnapshotRestore, "no sliced restore")

local clock = 0
local realClock = debugprofilestop
debugprofilestop = function() clock = clock + 0.05; return clock end

-- Forever names are "First Last", letters only (other forms are refused as ladder rows).
local function nameOf(i)
    local s = ""
    repeat
        s = string.char(97 + i % 26) .. s
        i = math.floor(i / 26)
    until i == 0
    return "Slice " .. s:sub(1, 1):upper() .. s:sub(2) .. "ova"
end

local function setup(n)
    lb.kills, lb.captureCount, lb.playerInfo = {}, {}, {}
    local kills, caps, info = {}, {}, {}
    for i = 1, n do
        local name = nameOf(i)
        kills[name] = i
        if i % 3 == 0 then caps[name] = i % 11 + 1 end
        info[name] = { class = "MAGE", level = 30, faction = "Horde", locale = "deDE", pool = "global" }
    end
    OverlordDB.leaderboardSnapshot = {
        campaignStart = epoch, scoreBucketEpoch = epoch, pool = "global",
        kills = kills, captures = {}, captureCount = caps, playerInfo = info,
    }
    return kills, caps
end

-- (1) Sliced = same rows as the one-pass call, over several frames.
local n = 3000
local kills, caps = setup(n)
local frames = 0
repeat
    frames = frames + 1
    assert(frames < 10000, "sliced restore never ended")
until lb:StepFullLadderSnapshotRestore()
assert(frames > 3, "the restore still ran in one frame: " .. frames)
local restored, restoredCaps, restoredInfo = 0, 0, 0
for name, count in pairs(kills) do
    assert(lb.kills[name] == count, "row not restored: " .. name)
    restored = restored + 1
end
for name, count in pairs(caps) do
    assert(lb.captureCount[name] == count, "capture row not restored: " .. name)
    restoredCaps = restoredCaps + 1
end
for name in pairs(kills) do
    local row = lb.playerInfo[name]
    assert(row and row.class == "MAGE" and row.faction == "Horde", "meta row not restored: " .. name)
    restoredInfo = restoredInfo + 1
end
assert(restored == n and restoredInfo == n and restoredCaps == n / 3, "partial restore")
assert(lb._snapshotRestoreJob == nil, "finished job kept")

-- (2) A bucket swapped between two slices ends the walk; nothing is written into the new one.
setup(n)
assert(lb:StepFullLadderSnapshotRestore() == false, "first slice already finished")
local fresh = {}
lb.kills = fresh
local guard = 0
repeat guard = guard + 1; assert(guard < 10000) until lb:StepFullLadderSnapshotRestore()
assert(next(fresh) == nil, "the old snapshot was written into a swapped bucket")

-- (3) Without a clock the step finishes at once (one pass, as before).
debugprofilestop = nil
setup(200)
assert(lb:StepFullLadderSnapshotRestore() == true, "no-clock step did not finish in one call")
assert(lb.kills[nameOf(200)] == 200, "no-clock step wrote nothing")
debugprofilestop = realClock
print("Snapshot restore: sliced over frames, same rows, stops on a swapped bucket")
