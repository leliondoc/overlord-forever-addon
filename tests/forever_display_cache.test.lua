-- A reload must paint the last bounded view without a peer, a population scan,
-- or waiting for the login index workers. Only real scores feed future views.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
assert(loadfile("Leaderboard.lua"))()
local lb = Overlord.Leaderboard
local campaign = lb:GetCurrentCampaignStart()
function IsInInstance() return false end
local timers, head = {}, 1
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local function drain()
    local steps = 0
    while head <= #timers do
        local run = timers[head]
        timers[head], head = false, head + 1
        run()
        steps = steps + 1
        assert(steps < 10000, "Cache refresh did not finish")
    end
    timers, head = {}, 1
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local names = {}
for i = 1, 600 do
    local name = "Cached Player" .. string.char(65 + math.floor(i / 26), 65 + i % 26)
    names[i] = name
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Horde", guild = "Cache Guild",
        guildAuth = true, guildAt = time(), locale = "engb", race = "Orc", raceSex = 2, level = 2 }
end
lb._storageBound = true
lb:Save()
assert(lb:EnsureNetworkHotIndexesPrepared() == false)
drain()
assert(not lb:EnsureDisplayCache().ready)
drain()
local first = lb:EnsureDisplayCache()
assert(first.ready and #first.sortedKills == 500)
local saved = assert(OverlordDB.leaderboardDisplayCache)
assert(#saved.sortedKills == 500 and #saved.sortedGuilds == 1)
assert(saved.killSource == nil and saved.playerInfoSource == nil,
    "Persistent presentation cache references unbounded source tables")
local disk = copy(OverlordDB)

-- SavedVariables are back, but Initialize has not bound any score table yet.
OverlordDB = copy(disk)
assert(loadfile("Leaderboard.lua"))()
lb = Overlord.Leaderboard
local networkCalls = 0
Overlord.Sync.SendWhisper = function() networkCalls = networkCalls + 1; return true end
local preview = lb:EnsureDisplayCache()
assert(preview.ready and preview.fromSavedCache and #preview.sortedKills == 500,
    "Reload did not immediately return the saved ranking")
assert(preview.sortedKills[1].name == names[600] and preview.sortedKills[1].kills == 600)
assert(next(lb.kills) == nil and next(lb.playerInfo) == nil,
    "Presentation cache was merged into authoritative scores")
assert(#timers == 0 and networkCalls == 0, "Painting a saved view started unbound work or network traffic")
for _ = 1, 50 do
    assert(lb:EnsureDisplayCache() == preview, "Opening the cached ranking recopied the saved view")
end
assert(#timers == 0)

-- Real initialization binds scores and prepares indexes independently of preview.
local refreshRequested = false
Overlord.LeaderboardUI = { RequestRefresh = function() refreshRequested = true end }
assert(lb:Initialize(true) == false)
drain()
assert(lb:Initialize(true) == nil and lb._storageBound)
assert(refreshRequested, "Login did not wake an already visible cached preview")
local loading = lb:EnsureDisplayCache()
assert(loading.ready and loading.fromSavedCache, "Login binding blanked the cached ranking")
for _ = 1, 50 do assert(lb:EnsureDisplayCache() == loading) end
drain()
local live = lb:EnsureDisplayCache()
assert(live.ready and not live.fromSavedCache and #live.sortedKills == 500)
assert(live.sortedGuilds[1].kills == first.sortedGuilds[1].kills)
assert(networkCalls == 0, "Cache refresh queried the network")
for _ = 1, 50 do assert(lb:EnsureDisplayCache() == live) end
assert(#timers == 0, "Opening an unchanged ranking rebuilt it")

lb:SetPlayerKills(names[101], 900, true)
assert(lb:EnsureDisplayCache() == live, "A background update blanked the existing ranking")
drain()
local updated = lb:EnsureDisplayCache()
assert(updated.sortedKills[1].name == names[101] and updated.sortedKills[1].kills == 900,
    "Cached display stayed frozen after a real score update")
assert(OverlordDB.leaderboardDisplayCache.sortedKills[1].kills == 900,
    "Updated view was not saved for the next login")
assert(saved.sortedKills[1].kills == 600, "Publishing a view mutated the previous saved view")

-- Reject a wrong region, incompatible layout, stale week, invalid attestation,
-- or malformed cache. Reading a cache must never repair/attest score data.
local valid = copy(OverlordDB.leaderboardDisplayCache)
for _, mutate in ipairs({
    function(c) c.pool = "another-pool" end,
    function(c) c.version = 99 end,
    function(c) c.killLimit = 5000 end,
    function(c) c.campaignStart = campaign - 604800 end,
    function(c) c.scoreBucketEpoch = campaign - 604800 end,
    function(c) c.sortedKills[1] = "corrupt" end,
    function(c) c.sortedKills[1].kills = 0/0 end,
    function(c) c.meta[c.sortedKills[1].name] = nil end,
    function(c) c.byFaction.Alliance = false end,
}) do
    local bad = copy(valid)
    mutate(bad)
    OverlordDB.leaderboardDisplayCache = bad
    assert(lb:RestoreDisplayCache() == nil, "Invalid cache was displayed")
end
OverlordDB.leaderboardDisplayCache = valid
OverlordDB.leaderboardScoreBucketEpoch = campaign - 604800
assert(lb:RestoreDisplayCache() == nil, "Unattested bucket displayed a cached ranking")
OverlordDB.leaderboardScoreBucketEpoch = campaign

assert(lb:OpenAtomicWeeklyBucket(campaign, campaign + 604800, 20260923))
assert(OverlordDB.leaderboardDisplayCache == nil, "Weekly rollover retained the previous display cache")
assert(not lb:EnsureDisplayCache().ready, "Previous week's in-memory view survived the rollover")

-- A client-side failure to load every SavedVariable cannot be repaired by a cache.
OverlordDB = nil
assert(loadfile("Leaderboard.lua"))()
assert(not Overlord.Leaderboard:EnsureDisplayCache().ready)
print("Forever display cache: immediate reload preview, bounded persistence, no peer request, warm reopen, background updates and campaign/pool/schema guards OK")
