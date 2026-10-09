-- 1.8.0 memory: the meta index publishes compact entries (values only, no tie-break
-- scratch) and re-derives one player's entry from its row instead of dropping the
-- whole index. Invariant checked here: after any sequence of setter calls, the
-- incrementally maintained index equals a rebuild from scratch, field by field.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb, sync = Overlord.Leaderboard, Overlord.Sync

local FIELDS = { "class", "level", "faction", "locale", "guild", "guildAt", "guildAuth",
    "guildReplica", "race", "raceSex", "raceAt", "raceKey", "pool" }
local SCRATCH = { "factionAt", "factionKey", "localeAt", "localeKey", "poolAt", "poolKey",
    "guildRank", "_guildSeen" }
local function dk(name) return (sync:GetCaptureContributorDedupKey(name) or name):lower() end
local function dump(index)
    local keys, out = {}, {}
    for key in pairs(index) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local entry, parts = index[key], { key }
        for _, field in ipairs(FIELDS) do parts[#parts + 1] = tostring(entry[field]) end
        out[#out + 1] = table.concat(parts, "|")
    end
    return table.concat(out, "\n")
end
local function assertMatchesRebuild(label)
    local live = assert(lb._dedupMetaIndex, label .. ": index dropped")
    local liveDump = dump(live)
    lb:RebuildDedupMetaIndex()
    local fresh = dump(lb._dedupMetaIndex)
    if liveDump ~= fresh then
        local a, b = {}, {}
        for line in liveDump:gmatch("[^\n]+") do a[#a + 1] = line end
        for line in fresh:gmatch("[^\n]+") do b[#b + 1] = line end
        for i = 1, math.max(#a, #b) do
            if a[i] ~= b[i] then
                error(label .. ": live entry " .. tostring(a[i]) .. " vs rebuild " .. tostring(b[i]))
            end
        end
    end
end

local function name(i)
    return "Meta Player" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26) % 26)
end
local now = GetServerTime()
for i = 1, 60 do
    lb:SetPlayerKills(name(i), i, true)
    lb:SetPlayerInfo(name(i), i % 2 == 0 and "MAGE" or "ROGUE", i % 3 == 0 and "Horde" or "Alliance")
end
-- Identities with two rows (same character spelled with a realm suffix).
lb.playerInfo[name(5) .. "-Realm"] = { class = "WARRIOR", faction = "Alliance", factionAt = now,
    locale = "dede", guild = "Second Row", guildAt = now - 10, pool = "", race = "Orc", raceSex = 2, raceAt = now }
lb.playerInfo[name(6) .. "-Realm"] = { class = "", faction = "Horde", factionAt = 0, locale = "",
    guild = "", pool = "", race = "", raceSex = 0, raceAt = 0 }
-- An old save can hold a class token in another case or with spaces.
lb.playerInfo["Raw Classy"] = { class = " warrior ", faction = "Horde", factionAt = 0,
    locale = "", guild = "", pool = "", race = "", raceSex = 0, raceAt = 0 }
lb:MarkMetaDirty()
lb:RebuildDedupMetaIndex()
local index = lb._dedupMetaIndex
assert(index[dk("Raw Classy")].class == "WARRIOR", "published class not normalized")

-- Compact entries: values only, at most 14 fields (16 hash slots).
for key, entry in pairs(index) do
    local fields = 0
    for _ in pairs(entry) do fields = fields + 1 end
    assert(fields <= 14, "entry " .. key .. " has " .. fields .. " fields")
    for _, field in ipairs(SCRATCH) do
        assert(entry[field] == nil, "entry " .. key .. " kept scratch field " .. field)
    end
end
assert(index[dk(name(7))].src == name(7), "single-row entry lost its source row")
assert(index[dk(name(5))].src == false, "two-row entry claims a single source")
assert(index[dk(name(5))].class == "ROGUE" and index[dk(name(5))].race == "Orc",
    "fixture: two-row class")

-- Single-row identities: every setter re-derives in place, the index survives and
-- builds reading it are not aborted (structural epoch unchanged).
local epoch = lb._dedupMetaEpoch
lb:SetPlayerLevel(name(7), 42)
lb:SetPlayerRace(name(8), "Dwarf", 3, true, now - 100)
lb:SetPlayerRace(name(8), "Gnome", 2, true, now - 50)
lb:SetPlayerGuild(name(9), "First Guild", true, true, now - 300, true)
lb:SetPlayerGuild(name(9), "Newer Guild", true, true, now - 200, true)
lb:ClearPlayerGuild(name(9), true, true, now - 100)
lb:SetPlayerGuild(name(10), "Hint Guild", true, false, now - 400)
lb:SetPlayerLocale(name(11), "frfr")
lb:SetPlayerFaction(name(12), "Alliance")
lb:SetPlayerClassFromSync(name(13), "PRIEST")
lb:SetPlayerInfo(name(14), "DRUID", "Horde", "eses", true)
lb:MergeOwnedGuildMetadata(name(15), "Owned Guild", now - 20)
lb:MergeLeaderboardKillMetadata(name(16), 50, "HUNTER", "Horde", "ruru", "Kill Guild", now - 30, true,
    "Tauren", 2, now - 30, true, false)
lb:SetPlayerInfo("Brand Newcomer", "PALADIN", "Alliance", "enus", true)
lb:SetPlayerLevel("Raw Classy", 20)
assert(index[dk("Raw Classy")].class == "WARRIOR", "re-derived class not normalized")
assert(lb._dedupMetaIndex == index, "a single-row update dropped the whole index")
assert(lb._dedupMetaEpoch == epoch, "a single-row update aborted the builds reading the index")
assert(index[dk(name(7))].level == 42, "level not re-derived")
assert(index[dk(name(8))].race == "Gnome", "race not re-derived")
assert(index[dk(name(9))].guild == "" and index[dk(name(9))].guildAuth == true, "guild tombstone not re-derived")
assert(index[dk("Brand Newcomer")] and index[dk("Brand Newcomer")].src == "Brand Newcomer",
    "a new row did not get its entry")
assertMatchesRebuild("single-row setters")

-- Two-row identity: a change cannot be re-derived from one row, the index is dropped.
index = lb._dedupMetaIndex
lb:SetPlayerLevel(name(5) .. "-Realm", 55)
assert(lb._dedupMetaIndex == nil, "a two-row identity was re-derived from one row")
lb:RebuildDedupMetaIndex()
assert(lb._dedupMetaIndex[dk(name(5))].level == 55, "rebuild missed the second row")

-- A second row appearing for a single-row identity: drop and rebuild, never a
-- one-row entry hiding the other row.
index = lb._dedupMetaIndex
lb.playerInfo[name(20) .. "-Realm"] = { class = "WARLOCK", faction = "Horde", factionAt = 0,
    locale = "", guild = "", pool = "", race = "", raceSex = 0, raceAt = 0 }
lb:SetPlayerLevel(name(20) .. "-Realm", 30)
assert(lb._dedupMetaIndex == nil, "a second row was indexed as a single-row identity")
lb:RebuildDedupMetaIndex()
assert(lb._dedupMetaIndex[dk(name(20))].src == false, "rebuild did not merge the new row")
assertMatchesRebuild("after new alias")

-- Updates during a sliced rebuild: journaled and re-derived on the new index before
-- it is published (the pass may already have read the old row).
local slices = 0
local co = coroutine.create(function()
    lb:RebuildDedupMetaIndex(function()
        slices = slices + 1
        if slices % 10 == 0 then coroutine.yield() end
    end)
end)
local step = 0
repeat
    assert(coroutine.resume(co))
    step = step + 1
    if coroutine.status(co) ~= "dead" then
        lb:SetPlayerLevel(name(step % 60 + 1), 10 + step)
        lb:SetPlayerInfo("Midpass Newcomer" .. string.char(97 + step % 26), "MAGE", "Horde", "", true)
    end
until coroutine.status(co) == "dead"
assert(step > 3, "fixture: rebuild was not sliced")
assertMatchesRebuild("updates during a sliced rebuild")

-- A two-row identity changed during a pass over a cold index cannot be replayed
-- from one row: structural change (the caller rebuilds it again later).
lb:MarkMetaDirty()
epoch = lb._dedupMetaEpoch
slices = 0
co = coroutine.create(function()
    lb:RebuildDedupMetaIndex(function()
        slices = slices + 1
        if slices % 10 == 0 then coroutine.yield() end
    end)
end)
local touched = false
repeat
    assert(coroutine.resume(co))
    if coroutine.status(co) ~= "dead" and not touched then
        touched = true
        lb:SetPlayerLevel(name(6) .. "-Realm", 33)
    end
until coroutine.status(co) == "dead"
assert(lb._dedupMetaEpoch ~= epoch, "an unreplayable change during the pass was not reported")

-- A pass abandoned mid-way (aborted display build, worker error) must not keep its
-- journal: once collected, a cold index again reports the change as structural.
lb:MarkMetaDirty()
do
    local slicesLeft = 0
    local abandoned = coroutine.create(function()
        lb:RebuildDedupMetaIndex(function()
            slicesLeft = slicesLeft + 1
            if slicesLeft % 5 == 0 then coroutine.yield() end
        end)
    end)
    assert(coroutine.resume(abandoned))
    assert(coroutine.status(abandoned) == "suspended", "fixture: pass finished at once")
    assert(lb:RefreshIndexedMetaForName(name(3)) == true, "fixture: no journal while the pass runs")
    abandoned = nil
end
collectgarbage("collect"); collectgarbage("collect")
lb._dedupMetaIndex = nil
assert(lb:RefreshIndexedMetaForName(name(3)) == false, "an abandoned pass left its journal registered")
lb:RebuildDedupMetaIndex()

-- Many rows added while a sliced pass yields (the table grows and rehashes): no
-- existing row is skipped or counted twice.
slices = 0
co = coroutine.create(function()
    lb:RebuildDedupMetaIndex(function()
        slices = slices + 1
        if slices % 7 == 0 then coroutine.yield() end
    end)
end)
local added = 0
repeat
    assert(coroutine.resume(co))
    if coroutine.status(co) ~= "dead" then
        for _ = 1, 150 do
            added = added + 1
            lb:SetPlayerInfo("Grower Number" .. string.char(97 + added % 26, 97 + math.floor(added / 26) % 26,
                97 + math.floor(added / 676) % 26), "HUNTER", "Horde", "", true)
        end
    end
until coroutine.status(co) == "dead"
assert(added >= 1000, "fixture: too few rows added during the pass (" .. added .. ")")
for key, entry in pairs(lb._dedupMetaIndex) do
    if entry.src == false then
        assert(key == dk(name(5)) or key == dk(name(6)) or key == dk(name(20)),
            "a single-row identity was published as several rows: " .. key)
    end
end
assertMatchesRebuild("rows added during a sliced pass")

-- A second row created through a patch path (guild of a realm-suffixed spelling):
-- the patched copy no longer names a single source, so a later update of the
-- first row cannot re-derive the identity from that row alone.
lb:RebuildDedupMetaIndex()
do
    local first = name(40)
    assert(lb._dedupMetaIndex[dk(first)].src == first, "fixture: identity not single-row")
    lb:SetPlayerGuild(first .. "-Realm", "Second Spelling", true, true, now - 5, true)
    lb:SetPlayerLevel(first, 51)
    if lb._dedupMetaIndex then assertMatchesRebuild("update after a patched second row") end
    lb:RebuildDedupMetaIndex()
    assert(lb._dedupMetaIndex[dk(first)].guild == "Second Spelling", "fixture: second row guild lost")
end

-- Guild registers of Overlord users who never score (GI heartbeats, tombstones, guild
-- claims): rows and index entries hold the register only, and still equal a rebuild.
lb:RebuildDedupMetaIndex()
do
    local function fields(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    lb:MergeOwnedGuildMetadata("Heartbeat Only", "Some Guild", now - 50)
    lb:MergeOwnedGuildMetadata("Tombstone Only", "", now - 40)
    lb:SetPlayerGuild("Claimed Only", "Claim Guild", true, true, now - 30, true)
    lb:ClearPlayerGuild("Cleared Only", true, true, now - 20)
    for _, who in ipairs({ "Heartbeat Only", "Tombstone Only", "Claimed Only", "Cleared Only" }) do
        local row = assert(lb.playerInfo[who], "no row for " .. who)
        assert(fields(row) <= 3, who .. " row holds " .. fields(row) .. " fields")
        local entry = assert(lb._dedupMetaIndex[dk(who)], "no entry for " .. who)
        assert(fields(entry) <= 5 and entry.src == who and type(entry.guild) == "string",
            who .. " entry is not a compact register")
    end
    assert(lb._dedupMetaIndex[dk("Heartbeat Only")].guild == "Some Guild"
        and lb._dedupMetaIndex[dk("Tombstone Only")].guildAuth == true, "register values lost")
    assert(lb:GetHotPlayerGuildState("Heartbeat Only") == "Some Guild", "hot guild read lost the register")
    assertMatchesRebuild("guild registers only")
    -- The player then scores: the full entry replaces the register.
    lb:SetPlayerInfo("Heartbeat Only", "SHAMAN", "Horde", "dede", true)
    local entry = lb._dedupMetaIndex[dk("Heartbeat Only")]
    assert(entry.class == "SHAMAN" and entry.guild == "Some Guild" and entry.level == 0, "full entry not published")
    assertMatchesRebuild("register then score")
    -- An unchanged locale on a sparse row does not touch the index again.
    lb:SetPlayerLocale("Tombstone Only", "frfr")
    local before = lb._dedupMetaIndex[dk("Tombstone Only")]
    lb:SetPlayerLocale("Tombstone Only", "frfr")
    assert(lb._dedupMetaIndex[dk("Tombstone Only")] == before, "an unchanged locale re-derived the entry")
end

print("Forever meta index: compact entries, in-place single-row updates equal a rebuild, two-row identities rebuilt, mid-pass updates replayed OK")
