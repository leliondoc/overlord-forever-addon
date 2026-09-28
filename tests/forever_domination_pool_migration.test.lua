-- Exercise Core's real saved-variable migration before its unrelated init stages.
assert(loadfile("tests/forever_leaderboard.test.lua"))()

local originalRecalculate = Overlord.RecalculateDominationTotals
local stop = {}
Overlord.RecalculateDominationTotals = function() error(stop) end

local function migrate(pools, alreadyUnified)
    Overlord.IsInitialized = nil
    OverlordDB = {
        config = {}, lastResetTimestamp = 1789527600,
        frontDominationPoolVersion = 1, frontDominationMigrated = true,
        dominationSyncVersion = 11,
        globalDominationUnifiedVersion = alreadyUnified and 1 or nil,
        frontDominationTimeByPool = pools,
    }
    local ok, err = pcall(function() Overlord:Initialize() end)
    assert(not ok and err == stop, "Core did not reach its real domination migration")
    return OverlordDB.frontDominationTimeByPool.global
end

local first = migrate({
    global = { front_a = { Alliance = 100, Horde = 900, scoreSeq = 10, scoreSource = "A" } },
    eu = { front_a = { Alliance = 900, Horde = 100, scoreSeq = 9, scoreSource = "B" } },
})
assert(first.front_a.Alliance == 100 and first.front_a.Horde == 900,
    "Migration synthesized max(Alliance)+max(Horde) instead of one complete snapshot")

local second = migrate({
    us = { front_a = { Alliance = 900, Horde = 100, scoreSeq = 11, scoreSource = "B" },
        front_b = { Alliance = 30, Horde = 10, scoreSeq = 4, scoreSource = "A" } },
    eu = { front_a = { Alliance = 100, Horde = 900, scoreSeq = 10, scoreSource = "A" },
        front_b = { Alliance = 10, Horde = 40, scoreSeq = 3, scoreSource = "B" } },
})
assert(second.front_a.Alliance == 900 and second.front_a.Horde == 100,
    "Same-total DX sequence tie-break was not used")
assert(second.front_b.Alliance == 10 and second.front_b.Horde == 40,
    "Migration did not choose the larger complete territorial snapshot per front")
assert(OverlordDB.frontDominationTimeByPool.us == nil
    and OverlordDB.frontDominationTimeByPool.eu == nil,
    "Legacy pools remained after migration")

local already = migrate({
    global = { front_a = { Alliance = 900, Horde = 900, scoreSeq = 12 } },
    eu = { front_a = { Alliance = 100, Horde = 900, scoreSeq = 10 } },
}, true)
assert(already.front_a.Alliance == 900 and already.front_a.Horde == 900,
    "Already-unified historical scores were changed without source evidence")

Overlord.RecalculateDominationTotals = originalRecalculate
print("Forever domination pool migration: whole snapshots, deterministic DX order, existing saves preserved OK")
