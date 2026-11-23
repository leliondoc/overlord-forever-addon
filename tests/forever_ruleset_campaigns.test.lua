-- 1.4.0: one Overlord campaign per Forever ruleset. Live: "Classic Beta PvP"
-- (PvP rule on) and "Classic Beta PvE 2" (no rule on). PvP keeps the historical
-- pool "global" (1.3.x clients and saved data stay compatible); Normal/RP/Hardcore
-- get their own pool, channel and Battle.net band, and never mix with PvP.

-- 2. Relay packets and Battle.net bands of another ruleset are refused ------------
assert(loadfile("tests/forever_beta_integration.test.lua"))()
local s, net = Overlord.Sync, Overlord.Relay
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
net:Receive(relayed("pve"), "Bridge Tester", "BNET", 123)
assert(received() == before + 1, "PvP client accepted a Normal-ruleset packet")

ruleset("normal")
before = received()
net:Receive(relayed("global"), "Bridge Tester", "BNET", 123)
assert(received() == before, "Normal client accepted a PvP packet")
net:Receive(relayed("pve"), "Bridge Tester", "BNET", 123)
assert(received() == before + 1, "Normal client refused its own ruleset")
assert(s:GetMyBand() == "Forever_pve_A", "Battle.net band does not carry the ruleset: " .. s:GetMyBand())

-- Legacy-format Battle.net messages carry the sender's band: another ruleset is dropped.
local dispatched = 0
local realDispatch = s.DispatchBNetMessage
s.DispatchBNetMessage = function(...) dispatched = dispatched + 1; return realDispatch(...) end
s:OnBNetMessage("EK:Forever_global_A:x", 123)
assert(dispatched == 0, "A PvP friend's Battle.net message reached a Normal client")
s:OnBNetMessage("EK:Forever_pve_A:x", 123)
assert(dispatched == 1, "A same-ruleset Battle.net message was dropped")
s.DispatchBNetMessage = realDispatch
-- 1.4.1: the 1.4.0 Normal tags are retired: their packets and bands are refused.
before = received()
net:Receive(relayed("normal"), "Bridge Tester", "BNET", 123)
assert(received() == before, "A 1.4.0 Normal-ruleset packet was accepted")
dispatched = 0
s.DispatchBNetMessage = function(...) dispatched = dispatched + 1 end
s:OnBNetMessage("EK:Forever_normal_A:x", 123)
assert(dispatched == 0, "A 1.4.0 Normal band was accepted")
s.DispatchBNetMessage = realDispatch

-- 1.4.1 leak fix: the attested ladder snapshot is served only in its own pool
-- (1.4.0 Normal clients served their old 1.3.x PvP snapshot to each other).
if s.GetAttestedLeaderboardSnapshot and Overlord.GetCurrentCampaignStartTs then
    local start = Overlord:GetCurrentCampaignStartTs()
    OverlordDB.leaderboardScoreBucketEpoch = start
    OverlordDB.campaignId = Overlord.TimestampToCampaignId and Overlord:TimestampToCampaignId(start) or 0
    local legacy = { campaignStart = start, scoreBucketEpoch = start, kills = { ["Pvp Player"] = 5 } }
    OverlordDB.leaderboardSnapshot = legacy
    ruleset("pvp")
    assert(s:GetAttestedLeaderboardSnapshot() == legacy, "PvP lost its pre-1.4 snapshot")
    ruleset("normal")
    assert(s:GetAttestedLeaderboardSnapshot() == nil, "A Normal client served a PvP snapshot")
    legacy.pool = "pve"
    assert(s:GetAttestedLeaderboardSnapshot() == legacy, "A Normal client refused its own snapshot")
    -- 2.2.2: a bucket kept on an equivalent anchor (CheckWeeklyReset's 36 h tolerance) still
    -- serves its week; last week's never does.
    legacy.campaignStart = start - 13 * 3600
    assert(s:GetAttestedLeaderboardSnapshot() == legacy, "an equivalent week anchor refused its own snapshot")
    legacy.campaignStart = start - 7 * 86400
    assert(s:GetAttestedLeaderboardSnapshot() == nil, "last week's snapshot served as this week's")
    legacy.campaignStart = start
end

-- 2.1.0: Roleplay PvP never mixes with Roleplay nor with PvP, in either direction.
ruleset("rppvp")
assert(s:GetMyBand() == "Forever_rpv_A", "Roleplay PvP band: " .. s:GetMyBand())
before = received()
net:Receive(relayed("rpg"), "Bridge Tester", "BNET", 123)
net:Receive(relayed("global"), "Bridge Tester", "BNET", 123)
assert(received() == before, "A Roleplay PvP client accepted a Roleplay or PvP packet")
net:Receive(relayed("rpv"), "Bridge Tester", "BNET", 123)
assert(received() == before + 1, "A Roleplay PvP client refused its own ruleset")
dispatched = 0
s.DispatchBNetMessage = function(...) dispatched = dispatched + 1 end
s:OnBNetMessage("EK:Forever_rpg_A:x", 123)
s:OnBNetMessage("EK:Forever_global_A:x", 123)
assert(dispatched == 0, "A Roleplay or PvP friend reached a Roleplay PvP client")
s:OnBNetMessage("EK:Forever_rpv_A:x", 123)
assert(dispatched == 1, "A Roleplay PvP friend was dropped")
s.DispatchBNetMessage = realDispatch
for _, other in ipairs({ "rp", "pvp" }) do
    ruleset(other)
    before = received()
    net:Receive(relayed("rpv"), "Bridge Tester", "BNET", 123)
    assert(received() == before, other .. " client accepted a Roleplay PvP packet")
    dispatched = 0
    s.DispatchBNetMessage = function(...) dispatched = dispatched + 1 end
    s:OnBNetMessage("EK:Forever_rpv_A:x", 123)
    assert(dispatched == 0, other .. " client took a Roleplay PvP friend's message")
    s.DispatchBNetMessage = realDispatch
end
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
assert(pools:GetRuleset() == "normal" and pools:GetOverlordPoolTag() == "pve"
    and pools:GetChannelSuffix() == "E", "No rule on = Normal ruleset")
assert(detect({ [2] = true }, "x"):GetRuleset() == "rp")
assert(detect({ [1] = true, [3] = true }, "x"):GetRuleset() == "hardcore", "Hardcore wins over PvP")
-- 2.1.0: Roleplay PvP = both rules on (no rule of its own in client 1.60.1.70755).
pools = detect({ [2] = true, [3] = true }, "x")
assert(pools:GetRuleset() == "rppvp" and pools:GetOverlordPoolTag() == "rpv"
    and pools:GetChannelSuffix() == "RPP", "Roleplay PvP must be its own campaign")
assert(pools:DescribeDetection():find("RP on, PvP on", 1, true), "Detection line: " .. pools:DescribeDetection())
assert(pools:NormalizeRegionPool("rpv") == "rpv" and pools:AreOutpostCrossPoolsLinked("rpv", "rpv"))
assert(not pools:AreOutpostCrossPoolsLinked("rpv", "rpg") and not pools:AreOutpostCrossPoolsLinked("rpv", "global"))
assert(detect({ [1] = true, [2] = true, [3] = true }, "x"):GetRuleset() == "hardcore", "Hardcore wins over RP and PvP")
assert(detect({ [2] = true }, "x"):GetOverlordPoolTag() == "rpg", "Roleplay keeps its tag")
assert(detect({ [3] = true }, "x"):GetOverlordPoolTag() == "global", "PvP keeps its tag")
-- Realm names: no rule API, one rule read, or rules not readable yet.
for _, name in ipairs({ "Roleplay PvP", "Forever RP-PvP", "RP PvP", "RPPvP", "Forever RPPVP 2" }) do
    assert(detect(nil, name):GetRuleset() == "rppvp", name)
    assert(detect({}, name):GetRuleset() == "rppvp", name .. " (rules off)")
    assert(detect({ [2] = true }, name):GetRuleset() == "rppvp", name .. " (RP rule only)")
    assert(detect({ [3] = true }, name):GetRuleset() == "rppvp", name .. " (PvP rule only)")
end
assert(detect({ [1] = true }, "Roleplay PvP"):GetRuleset() == "hardcore")
assert(detect(nil, "Roleplay"):GetRuleset() == "rp" and detect(nil, "Some PvP"):GetRuleset() == "pvp")
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
for _, tag in ipairs({ "pve", "rpg", "rpv", "hc" }) do
    assert(pools:NormalizeRegionPool(tag) == tag, tag)
end
assert(pools:NormalizeRegionPool("pvp") == "" and pools:NormalizeRegionPool("x1") == "")
for _, retired in ipairs({ "normal", "rp", "hardcore" }) do
    assert(pools:NormalizeRegionPool(retired) == "", "Retired 1.4.0 tag still accepted: " .. retired)
end
assert(not pools:AreOutpostCrossPoolsLinked("global", "pve"))

-- 3. 2.6.1: the rules read again after the login --------------------------------------
-- A Roleplay PvP client loaded before the game answered its RP rule: the session went to
-- the PvP campaign. The rules read again name Roleplay PvP: confirmed after CONFIRM_SEC,
-- the session stops (as in an instance, no resume) and asks for /reload.
local live = {}
local function session(rules, realm)
    Enum.GameRule = { HardcoreRuleset = 1, RPRuleset = 2, PvPRuleset = 3 }
    live = rules
    C_GameRules = { IsGameRuleActive = function(rule) return live[rule] end }
    GetRealmName = function() return realm end
    assert(loadfile("RealmPools.lua"))()
    return Overlord.RealmPools
end
pools = session({ [1] = false, [3] = true }, "")
assert(pools:GetRuleset() == "pvp" and pools._rulesetSettled == false,
    "An unanswered RP rule must be read as unsettled")
live = { [1] = false, [2] = true, [3] = true }
assert(pools:CheckSessionRuleset(10) == nil, "One reading is not enough")
assert(pools:CheckSessionRuleset(12) == nil, "Confirmed before CONFIRM_SEC")
assert(pools:CheckSessionRuleset(13) == "rppvp", "Roleplay PvP read after the login was not caught")
assert(pools:GetRuleset() == "pvp", "The session's campaign must not switch mid-session")
live = { [1] = false, [2] = false, [3] = true }
assert(pools:CheckSessionRuleset(99) == "rppvp", "A found mismatch must stay")

-- A right campaign is never stopped; a single odd reading is forgotten.
pools = session({ [1] = false, [2] = true, [3] = true }, "")
assert(pools:GetRuleset() == "rppvp" and pools._rulesetSettled == true)
for t = 0, 60, 5 do assert(pools:CheckSessionRuleset(t) == nil) end
live = { [1] = false, [2] = false, [3] = true }
assert(pools:CheckSessionRuleset(61) == nil)
live = { [1] = false, [2] = true, [3] = true }
assert(pools:CheckSessionRuleset(65) == nil)
live = { [1] = false, [2] = false, [3] = true }
assert(pools:CheckSessionRuleset(70) == nil, "Two readings that are not in a row confirmed a mismatch")
-- Every rule off (what a client answers before it knows them) on a realm without a name: a PvP
-- session is paused for it only after NORMAL_CONFIRM_SEC, never after CONFIRM_SEC.
pools = session({ [1] = false, [3] = true }, "")
assert(pools:GetRuleset() == "pvp")
live = { [1] = false, [2] = false, [3] = false }
assert(pools:CheckSessionRuleset(10) == nil)
assert(pools:CheckSessionRuleset(14) == nil, "An unbacked Normal reading paused a PvP session after CONFIRM_SEC")
live = { [1] = false, [2] = false, [3] = true }
assert(pools:CheckSessionRuleset(18) == nil and pools._rulesetPending == nil, "The PvP answer did not clear it")
live = { [1] = false, [2] = false, [3] = false }
assert(pools:CheckSessionRuleset(20) == nil)
assert(pools:CheckSessionRuleset(20 + pools.NORMAL_CONFIRM_SEC) == "normal", "A Normal reading that held was never confirmed")
-- A realm name that says Normal backs it: CONFIRM_SEC is enough.
pools = session({ [1] = false, [3] = true }, "Some PvE Realm")
assert(pools:GetRuleset() == "pvp")
live ={ [1] = false, [2] = false, [3] = false }
assert(pools:CheckSessionRuleset(10) == nil and pools:CheckSessionRuleset(13) == "normal")
-- Still unanswered: nothing is concluded.
pools = session({ [3] = true }, "")
assert(pools:CheckSessionRuleset(0) == nil and pools:CheckSessionRuleset(10) == nil)
-- A rule this client does not know (no Hardcore in Enum.GameRule) is not waited for.
pools = session({ [2] = true, [3] = true }, "")
Enum.GameRule.HardcoreRuleset = nil
assert(loadfile("RealmPools.lua"))()
assert(Overlord.RealmPools:GetRuleset() == "rppvp" and Overlord.RealmPools._rulesetSettled == true)

-- Core: the whole addon stops for the session and a resume is refused.
pools = session({ [1] = false, [3] = true }, "")
assert(pools:GetRuleset() == "pvp")
local printed = {}
local realPrint, realGetTime = print, GetTime
print = function(text) printed[#printed + 1] = tostring(text) end
local clock = 100
GetTime = function() return clock end
IsInInstance = IsInInstance or function() return false end
Overlord.InstanceSuspended, Overlord.RulesetMismatch = false, nil
assert(Overlord:CheckSessionRuleset() == false, "Stopped on a right reading")
live = { [1] = false, [2] = true, [3] = true }
assert(Overlord:CheckSessionRuleset() == false, "Stopped on the first reading")
clock = 104
assert(Overlord:CheckSessionRuleset() == true and Overlord.RulesetMismatch == "rppvp")
assert(Overlord.InstanceSuspended == true, "The wrong campaign kept running")
assert(#printed == 1 and printed[1]:find("/reload", 1, true), "The player was not told to /reload")
clock = 200
assert(Overlord:CheckSessionRuleset() == true and #printed == 1, "The /reload line was repeated")
-- Out of any instance, login stages done: the resume itself must refuse.
local realInit, realInstanceInfo = Overlord._deferredModuleInitDone, GetInstanceInfo
Overlord._deferredModuleInitDone = true
GetInstanceInfo = function() return "", "none" end
Overlord:ResumeFromInstance()
assert(Overlord.InstanceSuspended == true, "Leaving an instance resumed the wrong campaign")
Overlord._deferredModuleInitDone, GetInstanceInfo = realInit, realInstanceInfo
-- A first odd reading at the last check of the list (60 s) is confirmed CONFIRM_SEC later by a
-- check of its own; a right reading arms nothing.
do
    local realTimer, armed = C_Timer, {}
    C_Timer = { After = function(delay, fn) armed[#armed + 1] = { delay = delay, fn = fn } end }
    pools = session({ [1] = false, [3] = true }, "")
    Overlord.InstanceSuspended, Overlord.RulesetMismatch = false, nil
    Overlord._rulesetConfirmArmed, Overlord._rulesetConfirmCount = nil, nil
    printed = {}
    clock = 160
    assert(Overlord:CheckSessionRuleset() == false and #armed == 0, "A right reading armed a confirmation")
    live = { [1] = false, [2] = true, [3] = true }
    assert(Overlord:CheckSessionRuleset() == false and #armed == 1, "A first odd reading armed no confirmation")
    assert(armed[1].delay > pools.CONFIRM_SEC, "The confirmation came before CONFIRM_SEC")
    clock = clock + armed[1].delay
    armed[1].fn()
    assert(Overlord.RulesetMismatch == "rppvp" and Overlord.InstanceSuspended == true and #printed == 1,
        "The odd reading of the last check was never confirmed")
    -- Inside an instance nothing is read (a battleground's rules are not the realm's).
    pools = session({ [1] = false, [3] = true }, "")
    assert(pools:GetRuleset() == "pvp")
    Overlord.InstanceSuspended, Overlord.RulesetMismatch = false, nil
    Overlord._rulesetConfirmArmed, Overlord._rulesetConfirmCount = nil, nil
    local realInInstance = IsInInstance
    IsInInstance = function() return true, "pvp" end
    live = { [1] = false, [2] = true, [3] = true }
    assert(Overlord:CheckSessionRuleset() == false and pools._rulesetPending == nil,
        "The rules were read inside an instance")
    IsInInstance = realInInstance
    C_Timer = realTimer
end
print, GetTime = realPrint, realGetTime
Overlord.InstanceSuspended, Overlord.RulesetMismatch = false, nil

print("Ruleset campaigns: detection, pools, relay and Battle.net separation OK")
