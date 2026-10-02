-- 1.4.0: one Overlord campaign per Forever ruleset. Live: "Classic Beta PvP"
-- (PvP rule on) and "Classic Beta PvE 2" (no rule on). PvP keeps the historical
-- pool "global" (1.3.x clients and saved data stay compatible); Normal/RP/Hardcore
-- get their own pool, channel and Battle.net band, and never mix with PvP.

-- 2. Relay packets and Battle.net bands of another ruleset are refused ------------
assert(loadfile("tests/forever_beta_integration.test.lua"))()
local s, net = Overlord.Sync, Overlord.BetaNetwork
-- A packet passes the pool check when the relay counts it as received.
local function received() return net.stats.received end
local serial = 0
local function relayed(pool)
    serial = serial + 1
    return pool .. "|ruleset-" .. serial .. "|" .. time() .. "|*|Bridge Tester|NH|1"
end
local function ruleset(name) Overlord.RealmPools._ruleset = name end

ruleset("pvp")
local before = received()
net:Receive(relayed("global"), "Bridge Tester", "BNET", 123)
assert(received() == before + 1, "PvP client refused a PvP packet")
net:Receive(relayed("normal"), "Bridge Tester", "BNET", 123)
assert(received() == before + 1, "PvP client accepted a Normal-ruleset packet")

ruleset("normal")
before = received()
net:Receive(relayed("global"), "Bridge Tester", "BNET", 123)
assert(received() == before, "Normal client accepted a PvP packet")
net:Receive(relayed("normal"), "Bridge Tester", "BNET", 123)
assert(received() == before + 1, "Normal client refused its own ruleset")
assert(s:GetMyBand() == "Forever_normal_A", "Battle.net band does not carry the ruleset: " .. s:GetMyBand())

-- Legacy-format Battle.net messages carry the sender's band: another ruleset is dropped.
local dispatched = 0
local realDispatch = s.DispatchBNetMessage
s.DispatchBNetMessage = function(...) dispatched = dispatched + 1; return realDispatch(...) end
s:OnBNetMessage("EK:Forever_global_A:x", 123)
assert(dispatched == 0, "A PvP friend's Battle.net message reached a Normal client")
s:OnBNetMessage("EK:Forever_normal_A:x", 123)
assert(dispatched == 1, "A same-ruleset Battle.net message was dropped")
s.DispatchBNetMessage = realDispatch
ruleset("pvp")


-- 1. Detection, through the real RealmPools.lua -----------------------------------
local function detect(rules, realm)
    Enum = Enum or {}
    Enum.GameRule = rules and { HardcoreRuleset = 1, RPRuleset = 2, PvPRuleset = 3 } or nil
    C_GameRules = rules and { IsGameRuleActive = function(rule) return rules[rule] == true end } or nil
    GetRealmName = function() return realm end
    assert(loadfile("RealmPools.lua"))()
    return Overlord.RealmPools
end
local pools = detect({ [3] = true }, "Classic Beta PvP")
assert(pools:GetRuleset() == "pvp" and pools:GetOverlordPoolTag() == "global"
    and pools:GetChannelSuffix() == "", "PvP ruleset must keep the historical campaign")
pools = detect({}, "Classic Beta PvE 2")
assert(pools:GetRuleset() == "normal" and pools:GetOverlordPoolTag() == "normal"
    and pools:GetChannelSuffix() == "N", "No rule on = Normal ruleset")
assert(detect({ [2] = true }, "x"):GetRuleset() == "rp")
assert(detect({ [1] = true, [3] = true }, "x"):GetRuleset() == "hardcore", "Hardcore wins over PvP")
-- No game-rule API: the realm name decides; never a guess beyond it.
assert(detect(nil, "Classic Beta PvE 2"):GetRuleset() == "normal")
assert(detect(nil, "Classic Beta PvP"):GetRuleset() == "pvp")
assert(detect(nil, "Forever RP Realm"):GetRuleset() == "rp")
assert(detect(nil, "Somewhere"):GetRuleset() == "pvp", "Unknown must stay the historical population")
-- Rules not readable yet (all false) on a realm named PvP: the name wins.
assert(detect({}, "Classic Beta PvP"):GetRuleset() == "pvp", "Early all-false read split a PvP player")
assert(detect({}, "Somewhere"):GetRuleset() == "normal", "All rules off on an unnamed realm is Normal")
-- API present but not answering yet (nil), realm name unreadable: unknown, so the
-- historical population, never Normal (that would split a PvP player away).
Enum.GameRule = { HardcoreRuleset = 1, RPRuleset = 2, PvPRuleset = 3 }
C_GameRules = { IsGameRuleActive = function() return nil end }
GetRealmName = function() return "" end
assert(loadfile("RealmPools.lua"))()
assert(Overlord.RealmPools:GetRuleset() == "pvp", "A not-ready rule API classified the player as Normal")
-- Detected once per session: saved buckets and wire tags never switch mid-session.
pools = detect({}, "Classic Beta PvE 2")
assert(pools:GetRuleset() == "normal")
C_GameRules = { IsGameRuleActive = function() return true end }
assert(pools:GetRuleset() == "normal", "Ruleset changed mid-session")
-- Tags: legacy region tags are the PvP campaign; ruleset tags are kept; junk is refused.
for _, legacy in ipairs({ "global", "na", "us", "eu", "fr", "de", "EU" }) do
    assert(pools:NormalizeRegionPool(legacy) == "global", legacy)
end
for _, tag in ipairs({ "normal", "rp", "hardcore" }) do
    assert(pools:NormalizeRegionPool(tag) == tag, tag)
end
assert(pools:NormalizeRegionPool("pvp") == "" and pools:NormalizeRegionPool("x1") == "")
assert(not pools:AreOutpostCrossPoolsLinked("global", "normal"))

print("Ruleset campaigns: detection, pools, relay and Battle.net separation OK")
