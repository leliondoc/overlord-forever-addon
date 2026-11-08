-- 2.2.2 memory: meta index entries are arrays sharing immutable profiles (see
-- publishMeta). Checked here:
-- 1. every reader gives what 2.2.1 gave: a digest of GetExportPlayerMeta,
--    GetExportPlayerRace, GetHotPlayerGuildState, GetHotPlayerClass, the named view
--    of every entry, the display meta, the saved (slimmed) snapshot and a login
--    restore from it, over a ladder with odd rows (unnormalized saves, two-row
--    identities, guild registers) and a run of setters, equals the digest the
--    2.2.1 code computes on the same ladder (GOLDEN, recorded with it);
-- 2. a save written without the logout slimming loads as the same named rows;
-- 3. compact playerInfo rows (newInfoRow): every field of every row reads as the
--    named row did, before and after the setters, and is written back named (the
--    save text 2.2.1 wrote); odd rows, shared profiles, writes, the merge emptiness
--    test and the logout write-back of every bucket;
-- 4. retained memory of the whole ladder at 5,000 and 20,000 players.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb, sync = Overlord.Leaderboard, Overlord.Sync

local queue = {}
C_Timer.After = function(_, fn) queue[#queue + 1] = fn end
local function drain()
    for _ = 1, 1000000 do
        if #queue == 0 then return end
        local q = queue
        queue = {}
        for i = 1, #q do q[i]() end
    end
    error("timer queue never drained")
end

local seed = 12345
local function rnd(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
end
local letters = "abcdefghijklmnopqrstuvwxyz"
local function word(i, len)
    local t = {}
    for k = 1, len do
        local c = i % 26
        i = math.floor(i / 26)
        t[k] = letters:sub(c + 1, c + 1)
    end
    t[1] = t[1]:upper()
    return table.concat(t)
end
local classes = { "DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR" }
local races = { "Dwarf", "Gnome", "Human", "NightElf", "Orc", "Scourge", "Skyborne", "Tauren", "Troll" }
local locales = { "engb", "engb", "engb", "frfr", "eses", "ruru", "dede", "" }
local now = GetServerTime()

-- A ladder like the live saves (2026-11-07: 12 fields per row, guild replicas,
-- raceAt mostly 0, empty pool), plus registers and odd rows.
local function fill(count, salt)
    local names = {}
    local guildCount = math.max(20, math.floor(count * 0.15))
    local pi, kills = lb.playerInfo, lb.kills
    for i = 1, count do
        local name = word(i * 31 + salt, 6) .. " " .. word(i * 977 + 3, 7)
        local guild = rnd(100) < 15 and "" or (word(1 + rnd(guildCount) * 7919, 5) .. " Guild")
        local auth = rnd(100) < 3
        if rnd(1000) < 6 then
            pi[name] = { guild = guild ~= "" and guild or "Lone Guild", guildAt = now - rnd(86400), guildAuth = true }
        else
            pi[name] = {
                class = classes[1 + rnd(9)], level = 12 + rnd(15) + rnd(15),
                faction = rnd(100) < 45 and "Alliance" or "Horde", factionAt = now - rnd(200000),
                locale = locales[1 + rnd(8)], guild = guild,
                guildAt = guild ~= "" and (now - rnd(200000)) or nil,
                guildAuth = auth or nil,
                guildReplica = (not auth and guild ~= "") or nil,
                pool = rnd(50) == 0 and "global" or "", race = races[1 + rnd(9)],
                raceSex = rnd(100) < 67 and 2 or 3,
                raceAt = rnd(100) < 27 and (now - rnd(200000)) or 0,
            }
            if rnd(100) < 85 then kills[name] = 1 + rnd(300) end
        end
        names[#names + 1] = name
    end
    return names
end

local function dk(name) return (sync:GetCaptureContributorDedupKey(name) or name):lower() end
local FIELDS = { "class", "level", "faction", "locale", "guild", "guildAt", "guildAuth",
    "guildReplica", "race", "raceSex", "raceAt", "raceKey", "pool", "src" }
local function sortedKeys(t)
    local keys = {}
    for key in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- Digest: two polynomial hashes over every value read (exact in doubles).
local h1, h2, parts = 0, 0, 0
local function feed(...)
    for i = 1, select("#", ...) do
        local s = tostring((select(i, ...))) .. "\31"
        for j = 1, #s do
            local byte = s:byte(j)
            h1 = (h1 * 31 + byte) % 2147483647
            h2 = (h2 * 131 + byte) % 1000000007
        end
        parts = parts + 1
    end
end
local function feedReaders(label, names)
    feed(label)
    for _, name in ipairs(names) do
        feed(name, lb:GetExportPlayerMeta(name))
        feed(lb:GetExportPlayerRace(name))
        feed(lb:GetHotPlayerGuildState(name))
        feed(lb:GetHotPlayerClass(name))
    end
    local index = assert(lb._dedupMetaIndex, label .. ": index cold")
    for _, key in ipairs(sortedKeys(index)) do
        local entry = index[key]
        feed(key)
        for _, field in ipairs(FIELDS) do feed(entry[field]) end
    end
end
local function feedSavedRows(label, rows)
    feed(label)
    for _, name in ipairs(sortedKeys(rows)) do
        local row = rows[name]
        feed(name)
        for _, field in ipairs(sortedKeys(row)) do feed(field, row[field]) end
    end
end
local function savedText(rows)
    local out = {}
    for _, name in ipairs(sortedKeys(rows)) do
        local row = rows[name]
        out[#out + 1] = name
        for _, field in ipairs(sortedKeys(row)) do out[#out + 1] = field .. "=" .. tostring(row[field]) end
    end
    return table.concat(out, "\n")
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

-- 1. Equivalence ---------------------------------------------------------------
local names = fill(3000, 7)
-- Odd rows of old saves: every normalizer of the index sees work.
local odd = {
    ["Odd Classy"] = { class = " warrior ", faction = "Horde", factionAt = now, locale = "FRFR",
        guild = "  Spaced   Guild ", guildAt = now - 5, pool = "EU", race = "Orc", raceSex = 5, raceAt = 500,
        level = "42" },
    ["Odd Unknown"] = { class = "UNKNOWN", faction = "Alliance", factionAt = 12, locale = "dede",
        guild = "", guildAt = 0, guildAuth = true, pool = "", race = "", raceSex = 0, raceAt = 0, level = 12.7 },
    ["Odd Bogus"] = { class = "bogus", faction = "Horde", factionAt = now, locale = "x", guild = "Bogus Guild",
        guildAt = now, guildAuth = true, guildReplica = true, pool = "normal", race = "Troll", raceSex = 3,
        raceAt = now - 1 },
    ["Odd Empty"] = { class = "", faction = "", factionAt = 0, locale = "", guild = "", pool = "" },
    ["Odd Typed"] = { class = "MAGE", faction = true, factionAt = now, locale = "frfr", guild = "",
        pool = "", race = 7, raceSex = 2, raceAt = 0, level = 30 },
    -- Two profiles whose lookup keys collide (separator inside raw values).
    ["Odd Collide"] = { class = "MAGE", faction = "Horde\1xx", factionAt = now, locale = "", guild = "",
        pool = "", race = "Orc", raceSex = 2, raceAt = 0, level = 30 },
    ["Odd Collider"] = { class = "MAGE", faction = "Horde", factionAt = now, locale = "xx", guild = "",
        pool = "", race = "\1Orc", raceSex = 2, raceAt = 0, level = 30 },
    ["Odd Locale Only"] = { class = "", faction = "", factionAt = 0, locale = "eses", guild = "", pool = "" },
}
for name, row in pairs(odd) do lb.playerInfo[name] = row; names[#names + 1] = name end
-- Two-row identities (realm-suffixed spelling of the same character).
local realmNames = {}
for _, name in ipairs({ "Classless One", "Classless One-Realm" }) do
    lb.playerInfo[name] = { class = "", faction = "Horde", factionAt = now, locale = "", guild = "",
        pool = "", race = "Orc", raceSex = 2, raceAt = now - 9 }
    names[#names + 1] = name
end
for i = 1, 40 do
    local base = names[i * 50]
    realmNames[#realmNames + 1] = base .. "-Realm"
    lb.playerInfo[base .. "-Realm"] = { class = classes[1 + i % 9], faction = i % 2 == 0 and "Horde" or "Alliance",
        factionAt = now - i, locale = "frfr", guild = "Second Row", guildAt = now - 100 + i,
        guildAuth = i % 3 == 0 or nil, pool = "", race = races[1 + i % 9], raceSex = 2, raceAt = now - i,
        level = 30 + i % 20 }
    names[#names + 1] = base .. "-Realm"
end
table.sort(names)
-- Every field a reader may ask of a row (src and raceKey: never stored, read nil).
local ROW_FIELDS = { "class", "level", "faction", "factionAt", "locale", "guild", "guildAt",
    "guildAuth", "guildReplica", "race", "raceSex", "raceAt", "pool", "src", "raceKey" }
local function rowView(row)
    local out = {}
    for _, field in ipairs(ROW_FIELDS) do out[#out + 1] = field .. "=" .. tostring(row[field]) end
    return table.concat(out, ",")
end
local namedViews = {}
for _, name in ipairs(names) do namedViews[name] = rowView(lb.playerInfo[name]) end
local namedSave = savedText(lb.playerInfo)
lb._networkHotKillsSource = nil
lb:MarkMetaDirty()
assert(lb:RebuildNetworkHotIndexes(), "hot index build")
feedReaders("built", names)
-- 3a. The build made the rows compact; each reads as its named row did.
local compactRows = 0
for _, name in ipairs(names) do
    local row = lb.playerInfo[name]
    if getmetatable(row) ~= nil then compactRows = compactRows + 1 end
    assert(rowView(row) == namedViews[name], "a compact row reads differently: " .. name)
end
assert(compactRows >= #names * 0.95, "rows left named after the build: " .. (#names - compactRows))
assert(getmetatable(lb.playerInfo["Odd Typed"]) == nil, "a row holding a boolean faction became compact")
-- Written back named, the rows give the save text of the named rows; the next
-- rebuild makes them compact again.
lb:MaterializePlayerInfoRows()
assert(savedText(lb.playerInfo) == namedSave, "compact rows were not written back as the named rows")
for _, name in ipairs(names) do
    assert(getmetatable(lb.playerInfo[name]) == nil, "a row stayed compact after the write-back")
end
lb:MarkMetaDirty()
lb:RebuildDedupMetaIndex()
assert(getmetatable(lb.playerInfo[names[1]]) ~= nil, "the rebuild left the rows named")

-- Setters after the build: re-derived single rows, patched multi-row copies,
-- registers, tombstones, new names.
for i = 1, 600 do
    local name = names[1 + rnd(#names)]
    local op = i % 12
    if op == 0 then lb:SetPlayerLevel(name, 20 + rnd(40))
    elseif op == 1 then lb:SetPlayerRace(name, races[1 + rnd(9)], 2 + rnd(2), true, now - rnd(1000))
    elseif op == 2 then lb:SetPlayerGuild(name, "Setter Guild " .. rnd(5), true, true, now - rnd(500), true)
    elseif op == 3 then lb:SetPlayerGuild(name, "Hint Guild " .. rnd(5), true, false, now - rnd(500))
    elseif op == 4 then lb:ClearPlayerGuild(name, true, true, now - rnd(300))
    elseif op == 5 then lb:SetPlayerInfo(name, classes[1 + rnd(9)], rnd(2) == 0 and "Horde" or "Alliance",
        locales[1 + rnd(8)], true)
    elseif op == 6 then lb:SetPlayerClassFromSync(name, classes[1 + rnd(9)])
    elseif op == 7 then lb:MergeOwnedGuildMetadata(name, "Owned Guild " .. rnd(3), now - rnd(200))
    elseif op == 8 then lb:SetPlayerLocale(name, locales[1 + rnd(7)])
    elseif op == 9 then lb:SetPlayerFaction(name, rnd(2) == 0 and "Horde" or "Alliance")
    elseif op == 10 then
        local fresh = "Late Comer" .. word(i, 3)
        lb:MergeOwnedGuildMetadata(fresh, "Fresh Guild", now - i)
        names[#names + 1] = fresh
    else
        lb:PatchDedupMetaClassForPlayer(name, classes[1 + rnd(9)])
    end
    if not lb._dedupMetaIndex then lb:RebuildDedupMetaIndex() end
end
-- Patch paths of two-row identities: each writes a copy, never the entry the
-- snapshot may share.
realmNames[#realmNames + 1] = "Classless One-Realm"
for i, second in ipairs(realmNames) do
    if not lb._dedupMetaIndex then lb:RebuildDedupMetaIndex() end
    local before = lb._dedupMetaIndex[dk(second)]
    local view = {}
    for _, field in ipairs(FIELDS) do view[field] = tostring(before[field]) end
    if i % 2 == 0 then
        lb:SetPlayerGuild(second, "Patched Guild " .. i, true, true, now - 50 + i, true)
        lb:SetPlayerGuild(second, "Hinted Guild " .. i, true, false, now + i)
    else
        lb:ClearPlayerGuild(second, true, true, now + 10 + i)
    end
    lb:PatchDedupMetaClassForPlayer(second, "MAGE")
    local function feedPatched()
        local patched = lb._dedupMetaIndex and lb._dedupMetaIndex[dk(second)]
        if patched then
            for _, field in ipairs(FIELDS) do feed(patched[field]) end
        end
    end
    feedPatched()
    local row = lb.playerInfo[second]
    if row and row.race and row.race ~= "" then lb:SetPlayerRace(second, row.race, 0, true, now + 20 + i) end
    feedPatched()
    for _, field in ipairs(FIELDS) do
        assert(tostring(before[field]) == view[field], "a patch wrote the published entry of " .. second)
    end
end
-- Single rows whose guild is only re-dated, or whose level alone moves.
for i = 1, #names, 37 do
    local row = lb.playerInfo[names[i]]
    if row and row.guild and row.guild ~= "" then
        lb:SetPlayerGuild(names[i], row.guild, true, true, (tonumber(row.guildAt) or now) + 100, true)
    end
    if row and row.class then lb:SetPlayerLevel(names[i], (tonumber(row.level) or 0) + 1) end
    row = lb.playerInfo[names[i + 1]]
    if row and row.guild and row.guild ~= "" and lb._dedupMetaIndex then
        row.guildAt = (tonumber(row.guildAt) or now) + 7
        if not lb:RefreshIndexedMetaForName(names[i + 1]) then lb:RebuildDedupMetaIndex() end
    end
    if not lb._dedupMetaIndex then lb:RebuildDedupMetaIndex() end
end
-- Guild registers whose flags alone change (an edited save, a replica page).
for i, name in ipairs(names) do
    local row = lb.playerInfo[name]
    if row and row.class == nil and row.guild then
        row.guildReplica = i % 2 == 0 or nil
        row.guildAuth = i % 3 == 0 or nil
        if lb._dedupMetaIndex and not lb:RefreshIndexedMetaForName(name) then lb:RebuildDedupMetaIndex() end
    end
end
if not lb._dedupMetaIndex then lb:RebuildDedupMetaIndex() end
table.sort(names)
feedReaders("after setters", names)
lb:MarkMetaDirty()
lb:RebuildDedupMetaIndex()
feedReaders("rebuilt", names)

-- Display meta (indexedMeta), guild totals and ratings.
lb._displayCacheLastBuildAt, lb._displayCacheLastAttemptAt = nil, nil
lb:StartDisplayCacheBuild()
drain()
local cache = assert(lb._displayCache, "display cache not built")
feed("display")
for _, name in ipairs(sortedKeys(cache.meta)) do
    local m = cache.meta[name]
    feed(name, m[1], m[2], m[3], m[4], cache.locale[name])
end
-- Equal display meta is one shared array (internDisplayMeta).
local metaArrays, metaNames, distinctArrays = {}, 0, 0
for _, m in pairs(cache.meta) do
    if not metaArrays[m] then metaArrays[m] = true; distinctArrays = distinctArrays + 1 end
    metaNames = metaNames + 1
end
assert(metaNames > 1000 and distinctArrays * 4 < metaNames,
    "display meta arrays are not shared: " .. distinctArrays .. " for " .. metaNames .. " names")
for _, row in ipairs(cache.sortedGuilds) do feed(row.guild, row.kills, row.faction) end
for _, row in ipairs(cache.sortedGuildRating) do feed(row.guild, row.points, row.faction) end

-- Snapshot: built, saved as at logout, restored at login.
lb._snapshotDirty = true
lb:SnapshotCurrentCampaignFull()
drain()
local snapshot = assert(OverlordDB.leaderboardSnapshot, "snapshot not written")
local liveRaw = copy(snapshot.playerInfo)
lb:SlimSavedSnapshotForLogout()
local saved = copy(snapshot)
feedSavedRows("saved snapshot", saved.playerInfo)
local slimText = savedText(saved.playerInfo)
OverlordDB.leaderboardSnapshot = saved
local removed = {}
for i = 1, #names, 7 do
    removed[#removed + 1] = names[i]
    lb.playerInfo[names[i]] = nil
end
lb:RestoreFullLadderFromSnapshotIfNeeded()
assert(getmetatable(lb.playerInfo[removed[1]]) ~= nil, "a restored row is not compact")
-- 3b. Read as the next save writes them (compact rows named again, see newInfoRow):
-- after the setters too, every row is written back with the fields it read.
local liveViews = {}
for name, row in pairs(lb.playerInfo) do liveViews[name] = rowView(row) end
lb:MaterializePlayerInfoRows()
for name, row in pairs(lb.playerInfo) do
    assert(getmetatable(row) == nil, "a row stayed compact after the write-back: " .. name)
    assert(rowView(row) == liveViews[name], "the write-back changed a row: " .. name)
end
local restored = {}
for _, name in ipairs(removed) do restored[name] = lb.playerInfo[name] end
feedSavedRows("restored", restored)

local digest = h1 .. ":" .. h2 .. ":" .. parts
print("meta index digest " .. digest)
-- Recorded with the 2.2.1 Leaderboard.lua (named entries) on this same script.
local GOLDEN = "958836507:568429540:300622"
assert(digest == GOLDEN, "readers differ from 2.2.1: digest " .. digest .. " instead of " .. GOLDEN)

-- 2. A save written without the logout slimming (raw entry arrays) loads as the
-- same named rows.
OverlordDB.leaderboardSnapshot = { playerInfo = liveRaw }
lb:NormalizeLoadedSnapshotMeta()
assert(savedText(liveRaw) == slimText, "an unslimmed save did not load as the slimmed one")

-- 3c. Compact rows, one case at a time ---------------------------------------
local function fresh()
    lb.playerInfo, lb.kills = {}, {}
    if OverlordDB.leaderboard then
        OverlordDB.leaderboard.playerInfo, OverlordDB.leaderboard.kills = lb.playerInfo, lb.kills
    end
    lb._dedupMetaIndex, lb._dedupMetaReuse = nil, nil
    return lb.playerInfo
end
local function rebuild()
    lb:MarkMetaDirty()
    lb:RebuildDedupMetaIndex()
end
local pi = fresh()
local function twinRow()
    return { class = "MAGE", level = 40, faction = "Horde", factionAt = now, locale = "frfr",
        guild = "Twin Guild", guildAt = now - 1, guildReplica = true, pool = "", race = "Orc",
        raceSex = 2, raceAt = 0 }
end
pi["Twin One"], pi["Twin Two"] = twinRow(), twinRow()
pi["Extra Keyrow"] = { class = "PRIEST", faction = "Alliance", locale = "dede", guild = "", pool = "",
    race = "Human", raceSex = 3, raceAt = 0, level = 22, factionAt = now, note = "kept" }
pi["Nan Sexrow"] = { class = "ROGUE", faction = "Horde", locale = "", guild = "", pool = "",
    race = "Troll", raceSex = 0 / 0, raceAt = 0, level = 30, factionAt = now }
pi["Profile Only"] = { class = "DRUID", faction = "Alliance" }
pi["Register Only"] = { guild = "Lone Guild", guildAt = now, guildAuth = true }
rebuild()
local one, two = pi["Twin One"], pi["Twin Two"]
assert(getmetatable(one) ~= nil and getmetatable(one) == getmetatable(two), "equal rows do not share a profile")
assert(pi["Extra Keyrow"].note == "kept" and pi["Extra Keyrow"].class == "PRIEST", "an odd key was lost")
assert(getmetatable(pi["Nan Sexrow"]) == nil, "a NaN value became shared")
assert(getmetatable(pi["Profile Only"]) == nil, "a row holding no field of its own became compact")
assert(getmetatable(pi["Register Only"]) == nil, "a guild register became compact")
-- Writes: a profile value moves the row to another profile, its twin keeps its own.
one.class = "ROGUE"
assert(one.class == "ROGUE" and two.class == "MAGE", "a write reached the shared profile")
assert(one.race == "Orc" and one.guild == "Twin Guild" and one.raceSex == 2, "a write lost another field")
one.class = "MAGE"
assert(getmetatable(one) == getmetatable(two), "the same values do not give the same profile back")
one.locale = nil
assert(one.locale == nil and two.locale == "frfr", "a nil write")
one.level, one.newField = 41, "x"
assert(one.level == 41 and rawget(one, "newField") == "x" and two.level == 40, "row fields are the row's own")
one.faction = true
assert(getmetatable(one) == nil and one.faction == true and one.class == "MAGE" and one.race == "Orc",
    "a value no profile holds did not write the row back named")
-- A sliced rebuild holds a row across its yield: a setter that replaces the row
-- meanwhile wins, the pass never writes its stale compact copy back.
pi = fresh()
pi["Slice Row"] = twinRow()
local co = coroutine.create(function() lb:RebuildDedupMetaIndex(coroutine.yield) end)
assert(coroutine.resume(co))
lb:SetPlayerInfo("Slice Row", "WARRIOR", "Alliance", "eses", false)
local newer = pi["Slice Row"]
assert(newer.class == "WARRIOR" and newer.locale == "eses")
while coroutine.status(co) ~= "dead" do assert(coroutine.resume(co)) end
assert(pi["Slice Row"] == newer and newer.class == "WARRIOR" and newer.locale == "eses",
    "a sliced rebuild wrote back a row replaced while it yielded")
-- An emptiness test sees the profile: two spellings of one player whose rows hold
-- no field of their own still merge (2.2.1 merged the named rows).
pi = fresh()
lb:SetPlayerClassFromSync("Mergy Person", "WARLOCK")
lb:SetPlayerClassFromSync("Mergy Person-Realm", "WARLOCK")
for _, name in ipairs({ "Mergy Person", "Mergy Person-Realm" }) do
    local row = pi[name]
    assert(getmetatable(row) ~= nil, "a setter wrote a named row")
    row.factionAt, row.guild = nil, nil
    assert(next(row) == nil and row.class == "WARLOCK")
end
lb:MergeDuplicateLeaderboardKeysByDedup()
local left = {}
for name, row in pairs(pi) do left[#left + 1] = name .. "=" .. tostring(row.class) end
assert(#left == 1 and left[1]:find("=WARLOCK", 1, true), "rows holding only a profile were not merged: "
    .. table.concat(left, " "))

-- 4. Retained memory ------------------------------------------------------------
local function mem()
    collectgarbage("collect"); collectgarbage("collect")
    return collectgarbage("count")
end
local measured = {}
for _, N in ipairs({ 5000, 20000 }) do
    OverlordDB.leaderboardSnapshot = nil
    lb._displayCache, lb._displayMetaCache = nil, nil
    fresh()
    -- A fresh name memo, as at login: its entries for these names count too.
    sync._nameMemo = nil
    local base = mem()
    fill(N, 11 + N)
    local afterRows = mem()
    lb._networkHotKillsSource = nil
    lb:MarkMetaDirty()
    assert(lb:RebuildNetworkHotIndexes(), N .. " hot index build")
    local afterIndex = mem()
    lb._snapshotDirty = true
    lb:SnapshotCurrentCampaignFull()
    drain()
    local afterSnapshot = mem()
    OverlordDB.leaderboardSnapshot = nil
    local withIndex = mem()
    lb._dedupMetaIndex, lb._dedupMetaReuse = nil, nil
    local withoutIndex = mem()
    local perPlayer = (withIndex - withoutIndex) * 1024 / N
    local total = (afterSnapshot - base) * 1024 / N
    measured[N] = total
    -- Rows: named as loaded, then compact after the build (the build makes them so).
    print(string.format("%d players: ladder total %.0f B/player, meta index %.0f, named rows %.0f, after the build %.0f",
        N, total, perPlayer, (afterRows - base) * 1024 / N, (afterIndex - base) * 1024 / N))
    -- 2.2.1 (named entries): ~760 B per player for the index.
    assert(perPlayer < 320, string.format("meta index holds %.0f B per player", perPlayer))
end
-- 2.2.1: ~1,950 B per player at 20,000 in all; named rows with the 2.2.2 index ~1,390.
assert(measured[20000] < 1150, string.format("ladder holds %.0f B per player at 20,000", measured[20000]))
assert(measured[5000] < 1450, string.format("ladder holds %.0f B per player at 5,000", measured[5000]))

-- 3d. Logout: every bucket that may hold compact rows is written back named,
-- the live one and one a weekly archive took away; then no row becomes compact.
pi = fresh()
lb:SetPlayerClassFromSync("Archived Player", "HUNTER")
local archived = pi
assert(getmetatable(archived["Archived Player"]) ~= nil)
pi = fresh()
lb:SetPlayerClassFromSync("Live Player", "SHAMAN")
OverlordDB.pendingWeeklyArchive = { bucket = { playerInfo = archived } }
lb:MaterializePlayerInfoForLogout()
OverlordDB.pendingWeeklyArchive = nil
assert(getmetatable(archived["Archived Player"]) == nil and rawget(archived["Archived Player"], "class") == "HUNTER",
    "an archived bucket kept a compact row at logout")
assert(getmetatable(pi["Live Player"]) == nil and rawget(pi["Live Player"], "class") == "SHAMAN",
    "the live bucket kept a compact row at logout")
lb:SetPlayerClassFromSync("After Logout", "PALADIN")
assert(getmetatable(pi["After Logout"]) == nil and rawget(pi["After Logout"], "class") == "PALADIN",
    "a row became compact after the logout write-back")

print("Forever meta index memory: readers equal 2.2.1, saved snapshot unchanged, unslimmed save loads, "
    .. "compact rows read and save as named rows, ladder under 1,150 B/player at 20,000")
