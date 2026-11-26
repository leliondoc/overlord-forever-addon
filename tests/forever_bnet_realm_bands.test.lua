-- 2026-11-26 (Roleplay PvP rows in the Normal ranking): a client that read its rules wrong says the
-- wrong campaign in its Battle.net band, in good faith. Its friend's record names its home realm,
-- and a realm plays one ruleset: once a realm's friends clearly agree on a campaign, a band naming
-- another one from that realm is refused. No realm in the record, or no clear majority: nothing
-- changes. Real OnBNetMessage on the beta fixture (our campaign: PvP, pool "global").
assert(loadfile("tests/forever_beta_integration.test.lua"))()

local s, rp = Overlord.Sync, Overlord.RealmPools
local now = 1790300000
GetServerTime = function() return now end
local games = {}
C_BattleNet.GetGameAccountInfoByID = function(id) return games[id] end
local function friend(id, name, realm, fields)
    games[id] = { gameAccountID = id, characterName = name, clientProgram = "WoW", wowProjectID = 18,
        factionName = "Horde", isInCurrentRegion = true, isOnline = true,
        playerGuid = realm and string.format("Player-%d-%08X", realm, id) or nil }
    for k, v in pairs(fields or {}) do games[id][k] = v end
end
local dispatched, relayed = 0, 0
local realDispatch, realReceive, realFragment = s.DispatchBNetMessage, Overlord.Relay.Receive, Overlord.Relay.ReceiveFragment
s.DispatchBNetMessage = function() dispatched = dispatched + 1 end
Overlord.Relay.Receive = function() relayed = relayed + 1 end
Overlord.Relay.ReceiveFragment = function() relayed = relayed + 1 end
local function reset()
    OverlordDB.bnetRealmBands = nil
    rp._bandVerdict, rp._bandPruned, rp.bandRefused, rp._ownBandKey = nil, nil, 0, nil
    dispatched, relayed = 0, 0
end
-- One direct message; true = read (dispatched).
local function say(id, pool)
    local before = dispatched
    s:OnBNetMessage("ZZ:Forever_" .. pool .. "_H:x", id)
    return dispatched > before
end
local function sayRelayed(id, pool)
    local before = relayed
    s:OnBNetMessage("R2:Forever_" .. pool .. "_H:BR:x", id)
    return relayed > before
end
assert(rp:GetOverlordPoolTag() == "global", "fixture: a PvP campaign")

-- 1. A record without any realm: exactly as before (our band read, another refused, nothing noted).
reset()
friend(10, "No Realm")
assert(say(10, "global") and not say(10, "rpv"), "a record without a realm changed the band rule")
assert(rp:CountKnownBandRealms() == 0 and rp.bandRefused == 0, "a record without a realm was noted")

-- 2. A Roleplay PvP realm (7001): its friends say rpv (refused here by the band rule, noted);
-- a misread friend there says PvP. Read while the realm has no clear majority, refused after.
reset()
friend(21, "Rp One", 7001); friend(22, "Rp Two", 7001); friend(23, "Rp Three", 7001)
friend(29, "Peach Pawz", 7001)
assert(not say(21, "rpv") and not say(22, "rpv"))
assert(say(29, "global"), "refused before its realm had a clear majority")
assert(not say(23, "rpv"))
assert(not say(29, "global") and rp.bandRefused == 1,
    "a band against its realm's clear majority was read")
assert(not sayRelayed(29, "global"), "a relay envelope against its realm's majority was read")
assert(rp.bandRefused == 2)

-- 3. Healthy friends are never refused: our own realm's friends, a forged richer band among them.
reset()
for i = 31, 34 do friend(i, "Pvp " .. string.char(64 + i - 30), 6940) end
friend(39, "Odd Forger", 6940)
for i = 31, 34 do assert(say(i, "global"), "a healthy friend was refused") end
assert(not say(39, "rpv"))
for i = 31, 34 do assert(say(i, "global") and sayRelayed(i, "global"), "a healthy friend was refused") end
assert(rp.bandRefused == 0, "a healthy realm refused something")

-- 4. No clear majority (3 against 2): nothing changes. 4 against 2: refused.
reset()
for i = 41, 43 do friend(i, "Rp Q" .. string.char(64 + i - 40), 7002) end
friend(48, "Mix One", 7002); friend(49, "Mix Two", 7002)
assert(say(48, "global") and say(49, "global"))
for i = 41, 43 do say(i, "rpv") end
assert(say(48, "global") and say(49, "global"), "3 against 2 refused a friend")
friend(44, "Rp Qd", 7002); say(44, "rpv")
assert(not say(48, "global"), "4 against 2 did not decide")

-- 5. One friend repeating itself is one word: never a majority alone.
reset()
friend(51, "Loud One", 7003); friend(59, "Quiet Pvp", 7003)
for _ = 1, 20 do say(51, "rpv") end
now = now + 7200
for _ = 1, 20 do say(51, "rpv") end
assert(say(59, "global"), "one friend repeating itself made a majority")

-- 6. Kept between sessions, for 21 days: an old word leaves at the next session's first read.
reset()
friend(61, "Old A", 7004); friend(62, "Old B", 7004); friend(63, "Old C", 7004); friend(69, "Late Pvp", 7004)
for i = 61, 63 do say(i, "rpv") end
assert(not say(69, "global"))
rp._bandVerdict, rp._bandPruned = nil, nil          -- a new session, the same saved table
assert(not say(69, "global"), "the realm's majority was not kept between sessions")
now = now + 22 * 86400                               -- same session: the words age out on reading
assert(say(69, "global"), "a majority older than 21 days still refused")
local before = rp:CountKnownBandRealms()
rp._bandVerdict, rp._bandPruned = nil, nil          -- next session: the old words leave the table
friend(68, "Other Realm", 7005); say(68, "global")
assert(OverlordDB.bnetRealmBands.g7004 and OverlordDB.bnetRealmBands.g7004.bands.rpv == nil,
    "words older than 21 days were kept in the saved table")
assert(before >= 1)

-- 7. Other keys: the record's realm id, else its realm name. Bounded store.
reset()
friend(71, "Id One", nil, { realmID = 88 }); friend(72, "Id Two", nil, { realmID = 88 })
friend(73, "Id Three", nil, { realmID = 88 }); friend(79, "Id Pvp", nil, { realmID = 88 })
for i = 71, 73 do say(i, "rpv") end
assert(not say(79, "global"), "the record's realm id was not used")
friend(81, "Name One", nil, { realmName = "93" }); friend(82, "Name Two", nil, { realmName = "93" })
friend(83, "Name Three", nil, { realmName = "93" }); friend(89, "Name Pvp", nil, { realmName = "93" })
for i = 81, 83 do say(i, "rpv") end
assert(not say(89, "global"), "the record's realm name was not used")
local realMax = rp.BAND_REALMS_MAX
rp.BAND_REALMS_MAX = 2
friend(91, "Third Realm", 7999); say(91, "global")
assert(rp:CountKnownBandRealms() == 2, "the realm store is not bounded")
rp.BAND_REALMS_MAX = realMax

-- 9. A character's latest word only: three that read PvP first, then their right campaign,
-- count once each, for it (both words kept, 3 against 3, never decided).
reset()
for i = 111, 113 do friend(i, "Late Reader " .. i, 7006) end
friend(119, "Still Wrong", 7006)
for i = 111, 113 do say(i, "global") end
for i = 111, 113 do say(i, "rpv") end
assert(not say(119, "global"), "a character's old word kept counting for its first campaign")
assert(OverlordDB.bnetRealmBands.g7006.bands.global.a111 == nil,
    "an old word stayed in the saved table")

-- 10. A mixed realm (two campaigns with BAND_MIN characters each): nothing is refused there.
reset()
for i = 121, 126 do friend(i, "Many Rp " .. i, 7008) end
for i = 127, 129 do friend(i, "Some Pvp " .. i, 7008) end
for i = 121, 126 do say(i, "rpv") end
for i = 127, 129 do say(i, "global") end   -- (the first two refused while six spoke against them)
assert(say(127, "global") and say(128, "global") and say(129, "global"),
    "a realm with two real campaigns refused one of them")

-- 11. Our own realm is never refused: we know its campaign.
reset()
local realGuid = UnitGUID
UnitGUID = function(unit)
    if unit == "player" then return "Player-6950-00000001" end
    return realGuid and realGuid(unit)
end
for i = 131, 133 do friend(i, "Home Rp " .. i, 6950) end
friend(139, "Home Pvp", 6950)
for i = 131, 133 do say(i, "rpv") end
assert(say(139, "global") and rp.bandRefused == 0, "a friend of our own realm was refused")
UnitGUID = realGuid

-- 12. A record heard once with its GUID, later without: the same realm, the same character.
reset()
friend(141, "Guid Once", 7009)
say(141, "rpv")
games[141].playerGuid, games[141].realmName = nil, "Elsewhere"
say(141, "rpv")
now = now + 7200
say(141, "global")
assert(rp:CountKnownBandRealms() == 1, "a record without its GUID made a second realm")
local words = 0
for _, list in pairs(OverlordDB.bnetRealmBands.g7009.bands) do for _ in pairs(list) do words = words + 1 end end
assert(words == 1, "a record without its GUID made a second word")

-- 13. Only the known misreading is refused: a realm whose friends say Normal never refuses a
-- PvP band (it may be the misreaders' own majority); a Roleplay PvP realm refuses PvP.
reset()
for i = 151, 154 do friend(i, "Says Normal " .. i, 7010) end
friend(159, "Right Pvp", 7010)
for i = 151, 154 do say(i, "pve") end
assert(say(159, "global") and sayRelayed(159, "global") and rp.bandRefused == 0,
    "a band with more rules than its realm's majority was refused")

-- 14. A friend of our own realm heard without its GUID (the record's realm id, the game's
-- GetRealmID) is ours too. A GUID's server id and a record's realm id never share a tally: they
-- may be different numbers for one realm, the same number for two.
reset()
UnitGUID = function(unit)
    if unit == "player" then return "Player-6951-00000001" end
    return realGuid and realGuid(unit)
end
local realGetRealmID = GetRealmID
GetRealmID = function() return 6951 end
for i = 161, 163 do friend(i, "Home Rp " .. i, 6951) end
friend(169, "Home No Guid", nil, { realmID = 6951 })
for i = 161, 163 do say(i, "rpv") end
assert(say(169, "global") and rp.bandRefused == 0, "a friend of our own realm without its GUID was refused")
-- (Three friends of our realm heard by the record's realm id only: still ours.)
for i = 164, 166 do friend(i, "Home Id Rp " .. i, nil, { realmID = 6951 }) end
for i = 164, 166 do say(i, "rpv") end
assert(say(169, "global") and rp.bandRefused == 0, "our realm by GetRealmID was refused")
GetRealmID = function() error("no realm id") end
reset()
for i = 164, 166 do say(i, "rpv") end
assert(not say(169, "global"), "a GetRealmID error made every realm-id friend ours")
GetRealmID = realGetRealmID
UnitGUID = realGuid
reset()
for i = 171, 172 do friend(i, "Guid Rp " .. i, 7011) end
friend(173, "Id Rp", nil, { realmID = 7011 })
friend(179, "Id Pvp", 7011)
for i = 171, 173 do say(i, "rpv") end
assert(say(179, "global"), "a GUID's server id and a record's realm id were counted in one tally")
assert(OverlordDB.bnetRealmBands.g7011 and OverlordDB.bnetRealmBands.r7011, "the two keys were not kept apart")

-- 16. One game account, one word: a player's alts on one realm count once.
reset()
friend(201, "Alt One", 7014); say(201, "rpv")
friend(201, "Alt Two", 7014, { playerGuid = "Player-7014-0000A002" }); say(201, "rpv")
friend(201, "Alt Three", 7014, { playerGuid = "Player-7014-0000A003" }); say(201, "rpv")
friend(209, "Other Pvp", 7014)
assert(say(209, "global"), "three alts of one game account made a majority")
friend(202, "Second Rp", 7014); friend(203, "Third Rp", 7014)
say(202, "rpv"); say(203, "rpv")
assert(not say(209, "global"), "three game accounts did not make a majority")

-- 15. The rule itself, whatever our campaign: under a Roleplay PvP majority, Normal, Roleplay
-- and PvP bands are refused; under a hardcore one, Normal is, PvP is not.
reset()
for i = 181, 183 do friend(i, "Rpv Rule " .. i, 7012) end
for i = 181, 183 do say(i, "rpv") end
friend(189, "Rule Probe", 7012)
assert(rp:IsBNetBandRefused(games[189], "Forever_pve_H") and rp:IsBNetBandRefused(games[189], "Forever_rpg_H")
    and rp:IsBNetBandRefused(games[189], "Forever_global_H"), "a band with fewer rules than a Roleplay PvP realm passed")
reset()
for i = 191, 193 do friend(i, "Hc Rule " .. i, 7013) end
for i = 191, 193 do say(i, "hc") end
friend(199, "Hc Probe", 7013)
assert(rp:IsBNetBandRefused(games[199], "Forever_pve_H") and not rp:IsBNetBandRefused(games[199], "Forever_global_H"),
    "the hardcore majority rule is wrong")

-- 8. /ov network shows it.
local line = rp:DescribeDetection()
assert(line:find("Battle.net realms known", 1, true) and line:find("refused for their realm's campaign", 1, true),
    "the counters are not in /ov network")

s.DispatchBNetMessage, Overlord.Relay.Receive, Overlord.Relay.ReceiveFragment = realDispatch, realReceive, realFragment
print("forever_bnet_realm_bands ok")
