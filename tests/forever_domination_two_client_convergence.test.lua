-- Two clients see the same victory events in different orders, with duplicates.
-- The v2 bar (50 +/- 1 per front victory; the wood system was removed in 1.2.0) is a function
-- of the victory SET (union), so both must show the same bar.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("SyncDomination.lua"))()
assert(loadfile("SyncVictoryBonus.lua"))()

local sync = Overlord.Sync
local campaign = OverlordDB.lastResetTimestamp
local S = campaign + 400000
time = function() return S end
GetServerTime = function() return S end
C_Timer.After = function(_, fn) fn() end
Overlord.MarkDirty = function() end
Overlord.Fronts.Registry = {}
for _, id in ipairs({ "a", "b", "c" }) do
    Overlord.Fronts.Registry[id] = { id = id, zones = { { id = id .. "1" } } }
end
local function client() return { lastResetTimestamp = campaign, frontVictories = {},
    dominationVictoryEvents = { byPool = {} }, config = {} } end

local victories = {
    { frontId = "a", faction = "Alliance", victoryTs = S - 5000 },
    { frontId = "b", faction = "Horde", victoryTs = S - 4000 },
    { frontId = "c", faction = "Alliance", victoryTs = S - 3000 },
}
local function feed(db, victoryOrder, twice)
    OverlordDB = db
    for _ = 1, twice and 2 or 1 do
        for _, index in ipairs(victoryOrder) do
            local v = victories[index]
            db.frontVictories[v.frontId] = { faction = v.faction, timestamp = v.victoryTs }
            local ok = Overlord:ApplyDominationVictoryBonusEvent({ frontId = v.frontId, faction = v.faction,
                victoryTs = v.victoryTs, rangeMaxTs = v.victoryTs, bonusSeconds = 50, totalAtApply = 2500,
                campaignEpoch = campaign }, { transportEvidence = true })
            assert(ok, "Victory " .. index .. " was refused")
        end
    end
    return Overlord:GetDominationBarScore()
end
local a1, h1, va1, vh1, extra1 = feed(client(), { 1, 2, 3 }, false)
local a2, h2, va2, vh2 = feed(client(), { 3, 2, 1 }, true)
assert(extra1 == nil, "The bar still returns wood counters")
assert(va1 == 2 and vh1 == 1, "Client 1 sets are wrong")
assert(va2 == va1 and vh2 == vh1, "Duplicate/reordered events changed the counts")
assert(a1 == 50 + (2 - 1) and a1 == a2 and h1 == 100 - a1 and h2 == h1,
    "Clients displayed different bars for the same event sets")
OverlordDB = client()
local fa, fh = Overlord:GetDominationDisplayFractions()
assert(fa == 0.5 and fh == 0.5, "Empty sets are not 50/50")

assert(Overlord.RecordDominationWoodEvent == nil and Overlord.GetDominationWoodCounts == nil,
    "The wood domination API is still loaded")

print("Forever domination: two clients, reversed order, duplicates and 50/50 identical OK")
