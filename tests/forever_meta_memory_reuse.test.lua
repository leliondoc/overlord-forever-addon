-- Ranking memory: a meta index rebuild keeps the entry table of every identity whose
-- values did not change (entries are never written in place), instead of allocating
-- ~700 B per player again. Checked here: unchanged entries are the same tables after
-- a rebuild, changed ones are new, the index and every getter equal a rebuild from
-- nothing, and the allocation of a rebuild over 5,000 players drops.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb, sync = Overlord.Leaderboard, Overlord.Sync

local FIELDS = { "class", "level", "faction", "locale", "guild", "guildAt", "guildAuth",
    "guildReplica", "race", "raceSex", "raceAt", "raceKey", "pool", "src" }
local function dk(name) return (sync:GetCaptureContributorDedupKey(name) or name):lower() end
local function dump(index)
    local keys, out = {}, {}
    for key in pairs(index) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local entry, parts = index[key], { key }
        for _, field in ipairs(FIELDS) do parts[#parts + 1] = tostring(entry[field]) end
        local n = 0
        for _ in pairs(entry) do n = n + 1 end
        parts[#parts + 1] = n
        out[#out + 1] = table.concat(parts, "|")
    end
    return table.concat(out, "\n")
end

local N = 5000
local letters = "abcdefghijklmnopqrstuvwxyz"
local function name(i)
    local a, b, c, d = i % 26, math.floor(i / 26) % 26, math.floor(i / 676) % 26, math.floor(i / 17576) % 26
    return "Reuse" .. letters:sub(a + 1, a + 1) .. letters:sub(b + 1, b + 1)
        .. " Row" .. letters:sub(c + 1, c + 1) .. letters:sub(d + 1, d + 1)
end
local now = GetServerTime()
local classes = { "MAGE", "ROGUE", "WARRIOR", "PRIEST", "HUNTER" }
for k in pairs(lb.playerInfo) do lb.playerInfo[k] = nil end
for i = 1, N do
    lb.playerInfo[name(i)] = { class = classes[i % 5 + 1], faction = i % 2 == 0 and "Horde" or "Alliance",
        factionAt = now - i, locale = i % 3 == 0 and "frfr" or "enus", guild = "Guild " .. (i % 300),
        guildAt = now - i * 2, guildAuth = i % 7 == 0 or nil, pool = "", race = "Orc", raceSex = 2,
        raceAt = now - i, level = 60 }
end
-- A two-row identity, a guild register only, a class token to normalize.
lb.playerInfo[name(5) .. "-Realm"] = { class = "WARRIOR", faction = "Alliance", factionAt = now,
    locale = "dede", guild = "Second Row", guildAt = now - 1, pool = "", race = "Dwarf", raceSex = 3, raceAt = now }
lb.playerInfo["Register Only"] = { guild = "Lone Guild", guildAt = now - 50 }
lb.playerInfo["Raw Classy"] = { class = " warrior ", faction = "Horde", factionAt = 0,
    locale = "", guild = "", pool = "", race = "", raceSex = 0, raceAt = 0 }

local names = {}
for n in pairs(lb.playerInfo) do names[#names + 1] = n end
table.sort(names)
local function getters()
    local out = {}
    for _, n in ipairs(names) do
        local class, faction = lb:GetExportPlayerMeta(n)
        local race, sex = lb:GetExportPlayerRace(n)
        local guild, guildAt, auth = lb:GetHotPlayerGuildState(n)
        out[#out + 1] = table.concat({ n, class, faction, race, sex, guild, guildAt, tostring(auth),
            lb:GetHotPlayerClass(n) }, "|")
    end
    return table.concat(out, "\n")
end

lb:MarkMetaDirty()
lb:RebuildDedupMetaIndex()
local first = lb._dedupMetaIndex
assert(first[dk("Raw Classy")].class == "WARRIOR" and first[dk(name(5))].src == false
    and first[dk("Register Only")].class == nil, "fixture: entry shapes")

-- Changes: one level, one guild, the second row of the two-row identity, a removed row
-- and a new one. Everything else must keep its table.
lb.playerInfo[name(7)].level = 61
lb.playerInfo[name(9)].guild, lb.playerInfo[name(9)].guildAt = "Moved Guild", now
lb.playerInfo[name(5) .. "-Realm"].level = 65
lb.playerInfo[name(11)] = nil
lb.playerInfo["Brand Newcomer"] = { class = "PALADIN", faction = "Alliance", factionAt = now, locale = "enus",
    guild = "", guildAt = 0, pool = "", race = "Human", raceSex = 2, raceAt = now, level = 10 }
names = {}
for n in pairs(lb.playerInfo) do names[#names + 1] = n end
table.sort(names)
local changed = { [dk(name(7))] = true, [dk(name(9))] = true, [dk(name(5))] = true,
    [dk("Brand Newcomer")] = true }

lb:MarkMetaDirty()
assert(lb._dedupMetaIndex == nil and lb._dedupMetaReuse == first, "a dropped index was not kept for reuse")
lb:RebuildDedupMetaIndex()
local second = lb._dedupMetaIndex
assert(lb._dedupMetaReuse == nil, "the reuse source outlived the rebuild")
local kept, fresh = 0, 0
for key, entry in pairs(second) do
    if changed[key] then
        assert(not rawequal(entry, first[key]), "changed entry " .. key .. " kept its old table")
        fresh = fresh + 1
    else
        assert(rawequal(entry, first[key]), "unchanged entry " .. key .. " was allocated again")
        kept = kept + 1
    end
end
assert(second[dk(name(11))] == nil, "a removed row kept its entry")
assert(second[dk(name(7))].level == 61 and second[dk(name(9))].guild == "Moved Guild"
    and second[dk(name(5))].level == 65 and second[dk("Brand Newcomer")].race == "Human", "changed values")
assert(kept == N - 1 + 1 + 1 - 3 and fresh == 4, "kept " .. kept .. ", new " .. fresh)

-- The same index and the same getter answers as a rebuild from nothing.
local reusedDump, reusedGetters = dump(second), getters()
lb._dedupMetaIndex, lb._dedupMetaReuse = nil, nil
lb:RebuildDedupMetaIndex()
local scratch = lb._dedupMetaIndex
for key, entry in pairs(scratch) do
    assert(not rawequal(entry, second[key]), "fixture: the rebuild from nothing reused " .. key)
end
assert(dump(scratch) == reusedDump, "reused index differs from a rebuild from nothing")
assert(getters() == reusedGetters, "getters differ between reused and fresh entries")

-- A single-row re-derivation with the same values keeps the entry too.
do
    local before = lb._dedupMetaIndex[dk(name(20))]
    lb:MarkPlayerMetaDirty(name(20))
    assert(rawequal(lb._dedupMetaIndex[dk(name(20))], before), "an unchanged re-derivation allocated an entry")
    lb:SetPlayerLevel(name(20), 70)
    assert(not rawequal(lb._dedupMetaIndex[dk(name(20))], before)
        and lb._dedupMetaIndex[dk(name(20))].level == 70, "a changed re-derivation kept the old entry")
end

-- A sliced rebuild with updates journaled mid-pass keeps reusing (and stays exact).
do
    local base = lb._dedupMetaIndex
    lb:MarkMetaDirty()
    local slices = 0
    local co = coroutine.create(function()
        lb:RebuildDedupMetaIndex(function()
            slices = slices + 1
            if slices % 500 == 0 then coroutine.yield() end
        end)
    end)
    local step = 0
    repeat
        assert(coroutine.resume(co))
        step = step + 1
        if coroutine.status(co) ~= "dead" and step == 2 then lb:SetPlayerLevel(name(30), 71) end
    until coroutine.status(co) == "dead"
    local sliced = lb._dedupMetaIndex
    assert(sliced[dk(name(30))].level == 71, "mid-pass update lost")
    assert(rawequal(sliced[dk(name(31))], base[dk(name(31))]), "sliced rebuild did not reuse")
    local slicedDump = dump(sliced)
    lb._dedupMetaIndex, lb._dedupMetaReuse = nil, nil
    lb:RebuildDedupMetaIndex()
    assert(dump(lb._dedupMetaIndex) == slicedDump, "sliced reused index differs from a rebuild from nothing")
end

-- Memory: allocation of one rebuild over an unchanged ladder, with and without reuse.
local function measure(withReuse)
    collectgarbage("collect"); collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    if withReuse then lb:MarkMetaDirty() else lb._dedupMetaIndex, lb._dedupMetaReuse = nil, nil end
    lb:RebuildDedupMetaIndex()
    local used = collectgarbage("count") - before
    collectgarbage("restart")
    return used
end
measure(true)
local without = measure(false)
local with = measure(true)
print(string.format("Meta index rebuild over %d players: %.0f KB allocated with reuse, %.0f KB without (%.0f vs %.0f B/player)",
    #names, with, without, with * 1024 / #names, without * 1024 / #names))
-- (2.2.2: entries are small arrays, so a rebuild from nothing allocates less than before.)
assert(with < without * 0.5, "reuse did not cut the rebuild allocation")

-- Duplicate keys: groups stay strings until a second spelling (same merge).
lb.kills[name(40)] = 5
lb.kills[name(40) .. "-Realm"] = 9
lb:MergeDuplicateLeaderboardKeysByDedup()
local merged = 0
for n in pairs(lb.kills) do if dk(n) == dk(name(40)) then merged = merged + 1 end end
assert(merged == 1, "duplicate spellings not merged")

-- Weekly reset: nothing of the old week is kept for reuse, the name memo starts again.
sync:CanonicalForeverName(name(1))
assert(sync._nameMemo, "fixture: no name memo")
lb:MarkMetaDirty()
local campaign = tonumber(OverlordDB.leaderboard and OverlordDB.leaderboard.campaignStart) or now
assert(lb:OpenAtomicWeeklyBucket(campaign, campaign + 604800, 20261013), "the week did not close")
assert(lb._dedupMetaReuse == nil and sync._nameMemo == nil, "weekly reset kept the old index or names")

print("Forever meta memory: unchanged entries reused, changed ones new, identical to a fresh rebuild OK")
