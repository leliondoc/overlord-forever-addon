-- Two clients see the same DX snapshots in different orders, with duplicates.
-- Territorial fronts and the separate VB overlay must give the same bar.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("SyncDomination.lua"))()

local sync = Overlord.Sync
local clients = {
    { a = { Alliance = 100, Horde = 900, scoreSeq = 1, scoreSource = "old-a" },
      b = { Alliance = 900, Horde = 100, scoreSeq = 1, scoreSource = "old-b" } },
    { a = { Alliance = 900, Horde = 100, scoreSeq = 1, scoreSource = "old-b" },
      b = { Alliance = 100, Horde = 900, scoreSeq = 1, scoreSource = "old-a" } },
}
local snapshots = {
    { front = "a", ally = 600, horde = 600, seq = 2, source = "new-a" },
    { front = "b", ally = 300, horde = 900, seq = 3, source = "new-b" },
}

local function apply(client, row)
    sync:MergeDominationBucket(client[row.front], row.ally, row.horde, row.seq, row.source)
end
apply(clients[1], snapshots[1]); apply(clients[1], snapshots[2]); apply(clients[1], snapshots[1])
apply(clients[2], snapshots[2]); apply(clients[2], snapshots[1]); apply(clients[2], snapshots[2])

Overlord.GetDominationVictoryBonusTotals = function() return 50, 20 end
local expected = (600 + 300 + 50) / (600 + 600 + 300 + 900 + 50 + 20)
for index, client in ipairs(clients) do
    assert(client.a.Alliance == 600 and client.a.Horde == 600
        and client.b.Alliance == 300 and client.b.Horde == 900,
        "Client " .. index .. " failed to converge its complete per-front DX snapshots")
    OverlordDB.frontDominationTime = client
    local allyPct, hordePct = Overlord:GetDominationDisplayFractions()
    assert(math.abs(allyPct - expected) < 0.000001
        and math.abs(hordePct - (1 - expected)) < 0.000001,
        "Client " .. index .. " displayed a different territorial + VB ratio")
end

print("Forever domination: two clients, reverse DX order, duplicates, fronts and VB ratio OK")
