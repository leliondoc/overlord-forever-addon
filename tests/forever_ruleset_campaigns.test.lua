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
-- 2026-11-26 (Roleplay PvP rows in the Normal ranking): a direct message without a
-- Forever band, or with a realm band ("Grobbulus_A"), named no ruleset and was read by
-- every campaign. No Forever client sends one (SendToBNet always adds the band).
dispatched = 0
s:OnBNetMessage("K:Arathi:Peach Pawz:86", 123)
s:OnBNetMessage("K:Grobbulus_A:Arathi:Peach Pawz:86", 123)
s:OnBNetMessage("K", 123)
s:OnBNetMessage("K:", 123)
assert(dispatched == 0, "A Battle.net message naming no ruleset reached a Normal client")
s:OnBNetMessage("K:Forever_pve_H:Arathi:Some One:3", 123)
assert(dispatched == 1, "A same-ruleset Battle.net kill was dropped")
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
-- A first reading heard long ago (the checks capped in between) is not a confirmation: it starts over.
pools = session({ [1] = false, [3] = true }, "")
assert(pools:GetRuleset() == "pvp")
live = { [1] = false, [2] = true, [3] = true }
assert(pools:CheckSessionRuleset(10) == nil)
assert(pools:CheckSessionRuleset(10 + pools.CONFIRM_SEC + pools.PENDING_STALE_SEC + 1) == nil,
    "A stale first reading confirmed a mismatch")
assert(pools:CheckSessionRuleset(10 + 2 * pools.CONFIRM_SEC + pools.PENDING_STALE_SEC + 1) == "rppvp",
    "The fresh reading was never confirmed")

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
-- 2026-11-26 (Berryem: Roleplay PvP players in the Normal ranking): a Roleplay PvP session read as
-- Normal at load ("no rule on", realm name ""). What its bucket learnt before the pause, on lanes
-- without a pool (raid, whisper), stayed in the account-wide Normal bucket. On the pause the names
-- it learnt leave it; the rows it already had stay, and a snapshot written meanwhile goes too.
do
    local realTimer = C_Timer
    C_Timer = { After = function() end }
    pools = session({ [1] = false, [2] = false, [3] = false }, "")
    assert(pools:GetRuleset() == "normal" and pools:IsLoadReadingDoubtful(),
        "An unbacked Normal reading at load was trusted")
    local lb = Overlord.Leaderboard
    local savedBucket, savedSnapshot = OverlordDB.leaderboard, OverlordDB.leaderboardSnapshot
    local bucket = { kills = { ["Native Player"] = 5 }, captureCount = {}, captures = {},
        playerInfo = { ["Native Player"] = { class = "WARRIOR", faction = "Horde" } },
        bountyKills = {}, bountyTimes = {} }
    OverlordDB.leaderboard = bucket
    OverlordDB.leaderboardSnapshot = nil
    if lb.BeginCampaignJournal then assert(lb:BeginCampaignJournal(), "No journal for a doubtful reading") end
    -- Heard on the raid lane from Roleplay PvP mates, then served from this bucket.
    bucket.kills["Peach Pawz"] = 86
    bucket.playerInfo["Peach Pawz"] = { class = "DRUID", faction = "Alliance" }
    bucket.captureCount["Peach Pawz"] = 2
    bucket.kills["Native Player"] = 7
    OverlordDB.leaderboardSnapshot = { pool = "pve", at = (GetServerTime and GetServerTime() or time()) + 1,
        kills = { ["Peach Pawz"] = 86, ["Native Player"] = 7 } }
    Overlord.InstanceSuspended, Overlord.RulesetMismatch = false, nil
    Overlord._rulesetConfirmArmed, Overlord._rulesetConfirmCount = nil, nil
    printed = {}
    clock = 300
    live = { [1] = false, [2] = true, [3] = true }
    assert(Overlord:CheckSessionRuleset() == false)
    clock = 304
    assert(Overlord:CheckSessionRuleset() == true and Overlord.RulesetMismatch == "rppvp")
    assert(bucket.kills["Peach Pawz"] == nil and bucket.playerInfo["Peach Pawz"] == nil
        and bucket.captureCount["Peach Pawz"] == nil,
        "A Roleplay PvP row learnt in the wrong campaign stayed in the Normal bucket")
    assert(bucket.kills["Native Player"] == 7 and bucket.playerInfo["Native Player"] ~= nil,
        "A row the Normal bucket already had was purged")
    assert(OverlordDB.leaderboardSnapshot == nil, "The snapshot written in the wrong campaign was kept")
    assert(getmetatable(bucket.kills) == nil and getmetatable(bucket.playerInfo) == nil,
        "The journal was left on the bucket")
    -- Only a reading its realm name backs keeps no journal: a settled PvP reading of a Roleplay
    -- PvP client (its RP rule not known yet, 2.6.1) is as wrong as "no rule on". A closed journal
    -- purges nothing.
    pools = session({ [1] = false, [2] = false, [3] = true }, "")
    assert(pools:IsLoadReadingDoubtful(), "A settled PvP reading no realm name backs was trusted")
    pools = session({ [1] = false, [2] = true, [3] = true }, "Classic Beta Roleplay PvP")
    assert(not pools:IsLoadReadingDoubtful(), "A reading its realm name backs was doubted")
    pools = session({ [1] = false, [3] = true }, "")
    assert(pools:IsLoadReadingDoubtful(), "An unanswered RP rule was trusted")
    assert(lb:BeginCampaignJournal())
    bucket.kills["Later Name"] = 3
    lb:EndCampaignJournal()
    assert(lb:PurgeCampaignJournal() == 0 and bucket.kills["Later Name"] == 3, "A closed journal purged a row")
    OverlordDB.leaderboard, OverlordDB.leaderboardSnapshot = savedBucket, savedSnapshot
    C_Timer = realTimer
end
-- 2026-11-26: a session loaded inside an instance read nothing in its first five minutes (every
-- check returns there), and a resume other than the exit PLAYER_ENTERING_WORLD (zone change,
-- retry, forced) read nothing either: a Roleplay PvP session read as Normal at load played on in
-- the Normal campaign. The checks now start at the first resume outside, and every resume reads
-- the rules first; a reading that differs holds the resume until it is confirmed or cleared.
do
    local realTimer, realInInstance, realInstanceInfo = C_Timer, IsInInstance, GetInstanceInfo
    local realInit = Overlord._deferredModuleInitDone
    -- (The modules' own resume needs frames this harness lacks; only the gate is tested here.)
    local stubbed = {}
    for _, name in ipairs({ "Combat", "ZoneControl", "Sync" }) do
        local m = Overlord[name]
        if m then stubbed[name] = { m.Resume, m.Suspend }; m.Resume, m.Suspend = function() end, function() end end
    end
    local armed = {}
    local function handle() return { Cancel = function() end, IsCancelled = function() return false end } end
    C_Timer = setmetatable({ After = function(delay, fn) armed[#armed + 1] = { delay = delay, fn = fn } end,
        NewTimer = handle, NewTicker = handle }, { __index = realTimer })
    local inside = true
    IsInInstance = function() if inside then return true, "pvp" end return false, "none" end
    GetInstanceInfo = function() if inside then return "Warsong Gulch", "pvp" end return "", "none" end
    local function reset(rules)
        pools = session(rules, "")
        Overlord.InstanceSuspended, Overlord.RulesetMismatch = true, nil
        Overlord._rulesetConfirmArmed, Overlord._rulesetConfirmCount = nil, nil
        Overlord._rulesetChecksDeferred, Overlord._resumeAwaitsRuleset = nil, nil
        Overlord._deferredModuleInitDone = true
        armed, printed = {}, {}
    end
    reset({ [1] = false, [2] = false, [3] = false })
    assert(pools:GetRuleset() == "normal")
    clock = 10
    Overlord:ScheduleSessionRulesetChecks()
    assert(#armed == 0 and Overlord._rulesetChecksDeferred == true,
        "The checks of a login inside an instance ran out inside it")
    -- Six minutes in the battleground; the rules answered meanwhile. Out by a zone change.
    clock = 370
    live = { [1] = false, [2] = true, [3] = true }
    inside = false
    Overlord:ResumeFromInstance()
    assert(Overlord.InstanceSuspended == true and Overlord.RulesetMismatch == nil,
        "Leaving an instance resumed a session whose rules now name another campaign")
    assert(#armed == 1 and armed[1].delay > pools.CONFIRM_SEC, "The differing reading armed no confirmation")
    clock = clock + armed[1].delay
    armed[1].fn()
    assert(Overlord.RulesetMismatch == "rppvp" and Overlord.InstanceSuspended == true and #printed == 1,
        "The held resume was not paused once the reading was confirmed")
    -- A right campaign resumes at once, and its checks start outside.
    reset({ [1] = false, [2] = false, [3] = false })
    inside = true
    Overlord:ScheduleSessionRulesetChecks()
    inside = false
    Overlord:ResumeFromInstance()
    assert(Overlord.InstanceSuspended == false and Overlord._rulesetChecksDeferred == nil,
        "A right campaign was kept stopped after an instance")
    local timed = 0
    for _, a in ipairs(armed) do if a.delay <= 300 then timed = timed + 1 end end
    assert(timed >= 10, "The checks of a login inside an instance never started outside")
    -- A single odd reading at the resume holds it; cleared, the resume goes on.
    Overlord:SuspendForInstance()
    reset({ [1] = false, [2] = true, [3] = true })
    assert(pools:GetRuleset() == "rppvp")
    live = { [1] = false, [2] = true, [3] = false }
    Overlord:ResumeFromInstance()
    assert(Overlord.InstanceSuspended == true and #armed == 1, "An odd reading did not hold the resume")
    live = { [1] = false, [2] = true, [3] = true }
    clock = clock + armed[1].delay
    armed[1].fn()
    assert(Overlord.RulesetMismatch == nil and Overlord.InstanceSuspended == false
        and Overlord._resumeAwaitsRuleset == nil, "A cleared reading left the session stopped")
    -- "No rule on" at the exit of a right Roleplay PvP session (NORMAL_CONFIRM_SEC) does not hold it.
    Overlord:SuspendForInstance()
    reset({ [1] = false, [2] = true, [3] = true })
    assert(pools:GetRuleset() == "rppvp")
    live = { [1] = false, [2] = false, [3] = false }
    Overlord:ResumeFromInstance()
    assert(Overlord.InstanceSuspended == false and Overlord._resumeAwaitsRuleset == nil,
        "A right PvP session was stopped 30 s for a Normal reading at the exit")
    C_Timer, IsInInstance, GetInstanceInfo = realTimer, realInInstance, realInstanceInfo
    Overlord._deferredModuleInitDone = realInit
    for name, fn in pairs(stubbed) do Overlord[name].Resume, Overlord[name].Suspend = fn[1], fn[2] end
end
-- Audit 2026-11-26: the journal's close (335 s after the login) came inside a battleground entered
-- early, before any reading: the pause at the exit then purged nothing. It now waits for the exit.
-- And a confirmation armed earlier for a Normal reading (30 s) no longer delays a held resume.
do
    local realTimer, realInInstance, realInstanceInfo = C_Timer, IsInInstance, GetInstanceInfo
    local realInit = Overlord._deferredModuleInitDone
    local stubbed = {}
    for _, name in ipairs({ "Combat", "ZoneControl", "Sync" }) do
        local m = Overlord[name]
        if m then stubbed[name] = { m.Resume, m.Suspend }; m.Resume, m.Suspend = function() end, function() end end
    end
    local armed = {}
    local function handle() return { Cancel = function() end, IsCancelled = function() return false end } end
    C_Timer = setmetatable({ After = function(delay, fn) armed[#armed + 1] = { delay = delay, fn = fn } end,
        NewTimer = handle, NewTicker = handle }, { __index = realTimer })
    local inside = false
    IsInInstance = function() if inside then return true, "pvp" end return false, "none" end
    GetInstanceInfo = function() if inside then return "Warsong Gulch", "pvp" end return "", "none" end
    local lb = Overlord.Leaderboard
    local savedBucket, savedSnapshot = OverlordDB.leaderboard, OverlordDB.leaderboardSnapshot
    local bucket
    local function reset(rules)
        pools = session(rules, "")
        pools:GetRuleset()
        Overlord.InstanceSuspended, Overlord.RulesetMismatch = false, nil
        Overlord._rulesetConfirmArmed, Overlord._rulesetConfirmCount, Overlord._rulesetConfirmAt = nil, nil, nil
        Overlord._rulesetChecksDeferred, Overlord._resumeAwaitsRuleset = nil, nil
        lb:EndCampaignJournal()
        Overlord._deferredModuleInitDone = true
        bucket = { kills = {}, captureCount = {}, captures = {}, playerInfo = {}, bountyKills = {}, bountyTimes = {} }
        OverlordDB.leaderboard, OverlordDB.leaderboardSnapshot = bucket, nil
        armed, printed, inside = {}, {}, false
    end
    reset({ [1] = false, [2] = false, [3] = false })
    assert(pools:GetRuleset() == "normal" and lb:BeginCampaignJournal())
    clock = 0
    Overlord:ScheduleSessionRulesetChecks()
    for _, a in ipairs(armed) do
        assert(a.delay <= 300, "A timer past the last check was armed (the journal stays open now)")
    end
    -- Heard before the battleground, entered at 20 s and left after 335 s.
    bucket.kills["Peach Pawz"] = 86
    inside = true
    Overlord:SuspendForInstance()
    clock = 340
    assert(getmetatable(bucket.kills) ~= nil, "The journal closed before the exit's reading")
    live = { [1] = false, [2] = true, [3] = true }
    inside, armed = false, {}
    Overlord:ResumeFromInstance()
    assert(Overlord.InstanceSuspended == true and #armed == 1, "The differing reading did not hold the resume")
    clock = clock + armed[1].delay
    armed[1].fn()
    assert(Overlord.RulesetMismatch == "rppvp" and bucket.kills["Peach Pawz"] == nil,
        "A row learnt before the battleground stayed after the pause")
    -- A mismatch found late (rules answered at 10 min, at a loading screen) still purges.
    reset({ [1] = false, [2] = false, [3] = false })
    assert(lb:BeginCampaignJournal())
    bucket.kills["Late Leak"] = 4
    clock = 600
    live = { [1] = false, [2] = true, [3] = true }
    assert(Overlord:CheckSessionRuleset() == false and #armed == 1)
    clock = clock + armed[1].delay
    armed[1].fn()
    assert(Overlord.RulesetMismatch == "rppvp" and bucket.kills["Late Leak"] == nil,
        "A mismatch found after five minutes purged nothing")
    assert(OverlordDB.campaignPurge and OverlordDB.campaignPurge.why == "pause" and OverlordDB.campaignPurge.n >= 1,
        "the names purged by the pause were not counted")
    -- 2026-11-26: the logout reading. A rule read on that the campaign does not have purges the
    -- names the session learnt, before the save; every other reading keeps everything.
    local function logout(loadRules, logoutRules, instance)
        reset(loadRules)
        bucket.kills["Old Row"] = 9
        assert(lb:BeginCampaignJournal())
        bucket.kills["New Row"] = 2
        bucket.playerInfo["New Row"] = { class = "DRUID", faction = "Alliance" }
        live, inside = logoutRules, instance == true
        local purged = Overlord:PurgeCampaignJournalAtLogout()
        inside = false
        assert(bucket.kills["Old Row"] == 9, "A row the bucket had before the session was purged")
        return purged, bucket.kills["New Row"] == nil and bucket.playerInfo["New Row"] == nil
    end
    local NONE, PVP, RP, RPPVP = { [1] = false, [2] = false, [3] = false },
        { [1] = false, [2] = false, [3] = true }, { [1] = false, [2] = true, [3] = false },
        { [1] = false, [2] = true, [3] = true }
    OverlordDB.campaignPurge = nil
    local purged, gone = logout(NONE, RPPVP)
    assert(purged and gone, "A Roleplay PvP session read as Normal kept its names at logout")
    -- (Counted and shown: nothing leaves the ranking unseen.)
    assert(OverlordDB.campaignPurge and OverlordDB.campaignPurge.n == 1 and OverlordDB.campaignPurge.why == "logout",
        "the names purged at logout were not counted")
    assert(Overlord.RealmPools:DescribeDetection():find("last campaign purge: 1 names left the ranking", 1, true),
        "the purge is not in /ov network")
    purged, gone = logout(PVP, RPPVP)
    assert(purged and gone, "A Roleplay PvP session read as PvP kept its names at logout")
    purged, gone = logout(NONE, NONE)
    assert(not purged and not gone, "A healthy Normal logout purged")
    purged, gone = logout(PVP, PVP)
    assert(not purged and not gone, "A healthy PvP logout purged")
    purged, gone = logout(PVP, NONE)
    assert(not purged and not gone, "An all-off reading at logout purged a PvP session")
    purged, gone = logout(RPPVP, RP)
    assert(not purged and not gone, "One rule fewer at logout purged a Roleplay PvP session")
    purged, gone = logout(NONE, RPPVP, true)
    assert(not purged and not gone, "A logout inside a battleground purged")
    purged, gone = logout(NONE, { [1] = false, [3] = true })
    assert(not purged and not gone, "An unsettled reading at logout purged")
    -- Just out of a battleground, before the resume: the rules may still be the instance's.
    reset(NONE)
    bucket.kills["Old Row"] = 9
    assert(lb:BeginCampaignJournal())
    bucket.kills["New Row"] = 2
    live, Overlord.InstanceSuspended = RPPVP, true
    assert(not Overlord:PurgeCampaignJournalAtLogout() and bucket.kills["New Row"] == 2,
        "A logout before the resume from an instance purged")
    Overlord.InstanceSuspended = false
    -- Every journal table: a name new to any of the six leaves.
    reset(NONE)
    assert(lb:BeginCampaignJournal())
    for _, field in ipairs({ "kills", "captureCount", "captures", "playerInfo", "bountyKills", "bountyTimes" }) do
        bucket[field]["Six " .. field] = 1
    end
    live = RPPVP
    assert(Overlord:PurgeCampaignJournalAtLogout())
    for _, field in ipairs({ "kills", "captureCount", "captures", "playerInfo", "bountyKills", "bountyTimes" }) do
        assert(bucket[field]["Six " .. field] == nil, "A name new to " .. field .. " escaped the journal")
    end
    -- The tables the session writes are the module's (Save links them into the bucket): journaled
    -- too, even when they are not the bucket's yet, or the bucket lacks a field.
    reset(NONE)
    local FIELDS = { "kills", "captureCount", "captures", "playerInfo", "bountyKills", "bountyTimes" }
    local savedLive = {}
    for _, field in ipairs(FIELDS) do savedLive[field] = lb[field]; lb[field] = {} end
    bucket.captures = nil
    assert(lb:BeginCampaignJournal())
    lb.kills["Live Row"], lb.captures["Live Row"] = 1, 2
    live = RPPVP
    assert(Overlord:PurgeCampaignJournalAtLogout())
    local leftKills, leftCaptures = lb.kills["Live Row"], lb.captures["Live Row"]
    for _, field in ipairs(FIELDS) do lb[field] = savedLive[field] end
    assert(leftKills == nil and leftCaptures == nil, "A name written to the module's own tables escaped the journal")
    -- A weekly reset inside the session: the new tables join the journal.
    reset(NONE)
    assert(lb:BeginCampaignJournal())
    local week = { kills = {}, captureCount = {}, captures = {}, playerInfo = {}, bountyKills = {}, bountyTimes = {} }
    lb:AttachCampaignJournal(week)
    -- The finished week becomes the pending archive: it leaves the journal, the purge never touches it.
    local finished = bucket
    finished.kills["Before Reset"] = 1
    lb:DetachCampaignJournal(finished)
    assert(getmetatable(finished.kills) == nil, "The finished week kept the journal's metatable")
    finished.kills["Archived Row"] = 5
    week.kills["After Reset"] = 1
    live = RPPVP
    assert(Overlord:PurgeCampaignJournalAtLogout() and week.kills["After Reset"] == nil,
        "A name learnt after a weekly reset escaped the journal")
    assert(finished.kills["Archived Row"] == 5 and finished.kills["Before Reset"] == 1,
        "The purge touched the finished week's archive")
    -- Wiring: the weekly swap re-attaches, and the logout purges before anything is saved.
    local lbSource = io.open("Leaderboard.lua", "rb"):read("*a")
    local swap = lbSource:find("OverlordDB.leaderboard = newBucket", 1, true)
    assert(swap and lbSource:find("self:AttachCampaignJournal(newBucket)", swap, true),
        "The weekly bucket swap does not re-attach the journal")
    local detach = swap and lbSource:find("self:DetachCampaignJournal(oldBucket)", swap, true)
    assert(detach and detach < lbSource:find("self:AttachCampaignJournal(newBucket)", swap, true),
        "The weekly bucket swap does not detach the finished week")
    local coreSource = io.open("Core.lua", "rb"):read("*a")
    local purgeAt = coreSource:find('persist(Overlord, "PurgeCampaignJournalAtLogout")', 1, true)
    local firstSave = coreSource:find('persist(Overlord.Leaderboard, "MaterializePlayerInfoForLogout")', 1, true)
    assert(purgeAt and firstSave and purgeAt < firstSave, "The logout purge does not come before the saves")
    -- A Normal reading armed a 30 s confirmation; the exit reads Roleplay: held, confirmed in ~3 s.
    reset({ [1] = false, [2] = true, [3] = true })
    live = { [1] = false, [2] = false, [3] = false }
    clock = 500
    assert(Overlord:CheckSessionRuleset() == false and #armed == 1 and armed[1].delay > 30)
    inside = true
    Overlord:SuspendForInstance()
    live = { [1] = false, [2] = true, [3] = false }
    inside, clock = false, 505
    Overlord:ResumeFromInstance()
    assert(Overlord.InstanceSuspended == true and #armed == 2 and armed[2].delay < 5,
        "A held resume waited for a Normal reading's 30 s confirmation")
    clock = clock + armed[2].delay
    armed[2].fn()
    assert(Overlord.RulesetMismatch == "rp", "The held reading was not confirmed by its own timer")
    OverlordDB.leaderboard, OverlordDB.leaderboardSnapshot = savedBucket, savedSnapshot
    C_Timer, IsInInstance, GetInstanceInfo = realTimer, realInInstance, realInstanceInfo
    Overlord._deferredModuleInitDone = realInit
    Overlord._rulesetChecksDeferred, Overlord._rulesetConfirmArmed, Overlord._rulesetConfirmCount = nil, nil, nil
    for name, fn in pairs(stubbed) do Overlord[name].Resume, Overlord[name].Suspend = fn[1], fn[2] end
end
print, GetTime = realPrint, realGetTime
Overlord.InstanceSuspended, Overlord.RulesetMismatch = false, nil

print("Ruleset campaigns: detection, pools, relay and Battle.net separation OK")
