-- Stress the real builders with a population much larger than the visible top.
-- Guard work and queue bounds, not machine-dependent FPS or timing thresholds.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
assert(loadfile("Leaderboard.lua"))()
local lb = Overlord.Leaderboard
lb._storageBound = true
local timers, head = {}, 1
local calls, maxCalls, maxQueued, slices = 0, 0, 0, 0
local getKey = Overlord.Sync.GetCaptureContributorDedupKey
Overlord.Sync.GetCaptureContributorDedupKey = function(self, name)
    calls = calls + 1
    return getKey(self, name)
end
C_Timer.After = function(_, callback)
    timers[#timers + 1] = callback
    maxQueued = math.max(maxQueued, #timers - head + 1)
end
local function drain()
    while head <= #timers do
        local callback = timers[head]
        timers[head], head = false, head + 1
        calls = 0
        callback()
        maxCalls = math.max(maxCalls, calls)
        assert(calls <= 512, "A frame rescanned the player population")
        slices = slices + 1
        assert(slices < 30000, "Builders failed to converge")
    end
    timers, head = {}, 1
end
local sort = table.sort
table.sort = function(rows, less)
    assert(#rows <= 200, "Unbounded synchronous sort in a frame")
    return sort(rows, less)
end
local function suffix(i)
    return string.char(65 + math.floor(i / 676) % 26,
        65 + math.floor(i / 26) % 26, 65 + i % 26)
end
local total = 0
for i = 1, 10000 do
    local name = "Stress Player" .. suffix(i)
    lb.kills[name] = i
    -- Every character in a separate guild exercises the largest possible guild sort.
    lb.playerInfo[name] = { guild = "Guild " .. suffix(i), guildAuth = true,
        guildAt = time(), faction = i % 2 == 0 and "Alliance" or "Horde", class = "PRIEST", level = 2 }
    lb.captureCount[name] = i % 25 + 1
    if i % 10 == 0 then lb.kills[name .. "-Realm"] = i end
    if i > 9500 then total = total + i end
end
lb:MarkDirty()
assert(lb:EnsureNetworkHotIndexesPrepared() == false)
for _ = 1, 100 do lb:EnsureNetworkHotIndexesPrepared() end
assert(#timers == 1, "Repeated requests duplicated the index builder")
drain()
assert(lb:EnsureNetworkHotIndexesPrepared() == true)
assert(lb:StartDisplayCacheBuild())
for _ = 1, 100 do assert(not lb:StartDisplayCacheBuild()) end
assert(#timers == 1, "Repeated refreshes duplicated the display builder")
local beforeDisplay = slices
drain()
assert(slices - beforeDisplay > 200, "Large ranking preparation did not yield")
local cache = assert(lb._displayCache, "Large display cache was not published")
assert(#cache.sortedKills == 500 and cache.sortedKills[1].kills == 10000)
for i, row in ipairs(cache.sortedKills) do
    assert(row.kills == 10001 - i, "Top 500 lost, duplicated or misordered a player")
end
assert(#cache.sortedGuilds == 500 and cache.sortedGuilds[1].kills == 10000)
assert(cache.alliKills + cache.hordeKills == total, "Aliases inflated faction totals")
local guildTotal = 0
for _, row in ipairs(cache.sortedGuilds) do guildTotal = guildTotal + row.kills end
assert(guildTotal == total, "Guild totals differ from the displayed top 500")

-- The real snapshot and its wire serializer must agree with that exact top,
-- including aliases, without sorting 500 rows or serializing them in one frame.
lb._storageBound = true
local snapshotDone
local beforeSnapshot = slices
lb:SnapshotCurrentCampaignBeforeReset(function(ok) snapshotDone = ok end)
drain()
assert(snapshotDone and slices - beforeSnapshot > 100, "Snapshot work was not sliced")
local snapshot = assert(OverlordDB.leaderboardSnapshot)
assert(#snapshot.killOrder == 500)
for i, row in ipairs(cache.sortedKills) do
    assert(snapshot.killOrder[i] == row.name and snapshot.kills[row.name] == row.kills,
        "Network and display disagree on the top 500")
    assert(snapshot.playerInfo[row.name].guild ~= "", "Alias lost its guild metadata")
end
assert(loadfile("SyncHistoryCatchup.lua"))()
local prepared
local beforeWire = slices
Overlord.Sync:PrepareBoundedFullSrLeaderboardQueue(false, function(ok) prepared = ok end)
drain()
assert(prepared and slices - beforeWire > 40, "Network serialization did not yield")
local count, _, queue = Overlord.Sync:ComputeHistoryCatchupSnapshotDigest(snapshot, snapshot.campaignStart)
local killsSent = 0
for _, packet in ipairs(queue) do if packet.type == "LK" then killsSent = killsSent + 1 end end
assert(killsSent == 500 and count <= 615, "Wire queue truncated or exceeded the top 500")

-- Identity repair must scan verified populations cooperatively and send nothing.
assert(loadfile("SyncResolution.lua"))()
Overlord.CommunityModeEnabled = false
Overlord.InActiveFront = true
function IsInInstance() return false end
function IsInGroup() return false end
function IsInRaid() return false end
local sent = 0
Overlord.BetaNetwork = {
    IsPeer = function() return true end,
    Send = function() sent = sent + 1; return true end,
}
Overlord.Sync:HealRequestMissingGuildsFromDB()
drain()
assert(sent == 0, "Verified guilds caused background network traffic")

-- Thousands of incoming legacy rows coalesce into at most twelve owner requests,
-- then their per-character cooldown prevents an immediate repeat.
for _, info in pairs(lb.playerInfo) do info.guildAuth = nil end
lb:MarkMetaDirty()
for name in pairs(lb.playerInfo) do Overlord.Sync:MaybeRequestMissingGuild(name) end
assert(#timers <= 1, "One timer was allocated per incoming player")
drain()
assert(sent == 12, "Guild repair exceeded or failed its bounded pending queue")
assert(maxQueued <= 2, "Builders accumulated concurrent timer work")
table.sort = sort
print(string.format("Forever performance: 10000 players/guilds + 1000 aliases, %d slices, "
    .. "max %d identity lookups/slice, max %d queued callbacks, bounded guild requests OK",
    slices, maxCalls, maxQueued))

-- The global-pool migration introduced with the beta also traverses other alts'
-- historical settlements. It must participate in the existing login coroutine.
assert(loadfile("tests/forever_contracts.test.lua"))()
timers, head = {}, 1
local writes, maxWrites, migrationSlices = 0, 0, 0
local source = {}
for i = 1, 5000 do source["contract" .. i] = { updatedAt = i } end
local target = setmetatable({}, { __newindex = function(t, key, value)
    writes = writes + 1
    rawset(t, key, value)
end })
OverlordDB.manualBountySettlementLedger = {
    eu = { ["offline tester"] = source },
    global = { ["offline tester"] = target },
}
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
assert(loadfile("ManualBounty.lua"))()
assert(Overlord.ManualBounty:Initialize() == "waiting")
while not Overlord.ManualBounty._initialized do
    local callback = assert(timers[head], "Settlement migration lost its continuation")
    timers[head], head = false, head + 1
    writes = 0
    callback()
    maxWrites = math.max(maxWrites, writes)
    assert(writes <= 64, "Settlement migration blocked a frame with the entire archive")
    migrationSlices = migrationSlices + 1
    assert(migrationSlices < 1000, "Settlement migration failed to finish")
end
for key, value in pairs(source) do
    assert(target[key] == value, "Migration lost an existing settlement")
end
assert(OverlordDB.manualBountySettlementLedger.eu == nil)
print(string.format("Forever performance: 5000 legacy settlements migrated in %d slices, "
    .. "max %d writes/slice, no lost records", migrationSlices, maxWrites))
