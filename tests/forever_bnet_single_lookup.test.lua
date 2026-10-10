-- A Battle.net message reads its sender's account record once: the region check and
-- the sender resolution used to call GetGameAccountInfoByID twice per message (a new
-- ~1 KB table each, every relay envelope included). Same senders resolved as before.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
local s, net = Overlord.Sync, Overlord.Relay
local lookup = C_BattleNet.GetGameAccountInfoByID
local reads = 0
C_BattleNet.GetGameAccountInfoByID = function(id) reads = reads + 1; return lookup(id) end
local function killPayload(name, total)
    return s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", "Alliance",
        1789527600, "", "enus", 0, 1789527600, 2)
end
local function wire(id, kind, data, path)
    return "eu|lookup-" .. id .. "|" .. time() .. "|*|" .. (path or "Remote Tester,Bridge Tester")
        .. "|" .. kind .. "|" .. data
end
-- A relay envelope (the bulk of Battle.net traffic): one read, the packet is handled.
local received = net.stats.received
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(1, "K", killPayload("Lookup Remote", 3)), 123)
assert(reads == 1, "a relay envelope read the sender's account " .. reads .. " times")
assert(net.stats.received == received + 1 and not net.stats.lastError, "the relay envelope was not handled")
-- The relay still learnt the authenticated last hop from that single read.
local route = net.peers["remote tester"]
assert(route and route.via == "Bridge Tester" and route.bnet == 123, "the sender was not resolved from the single read")
-- An account the API does not know: one read, nothing handled, no error.
reads, received = 0, net.stats.received
s:OnBNetMessage("R2:Forever_eu_A:BR:" .. wire(2, "K", killPayload("Lookup Remote", 4)), 999)
assert(reads == 1 and not net.stats.lastError, "an unknown account was read " .. reads .. " times")
-- A direct call without the record still resolves the sender itself (one read).
reads = 0
s:DispatchBNetMessage("BR", wire(3, "K", killPayload("Lookup Remote", 5)), "BNet-123", 123)
assert(reads == 1, "a direct dispatch without a record read the account " .. reads .. " times")
C_BattleNet.GetGameAccountInfoByID = lookup
print("Battle.net receive: one account lookup per message, same sender resolution")
