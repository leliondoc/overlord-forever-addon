-- Guild rating: one point per honorable kill, then GUILD_RATING_POINTS per front point
-- taken by a member, per outpost and per keep taken by the guild. Outposts and keeps
-- are read in the signed ledger (the "Captures" of the two site tables); a capturer's
-- signed captures leave his personal total, the rest are front points. Built in the
-- display pass from data the client already holds: no message.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local worth = lb.GUILD_RATING_POINTS
assert(worth.zone == 50 and worth.outpost == 75 and worth.keep == 100,
    "the values of the captures changed: they are the author's choice (2026-10-12)")
-- The display cache is built in slices on timers: run them all, clock included.
local timers = {}
local timerNow = GetTime()
function GetTime() return timerNow end
C_Timer.After = function(delay, callback)
    timers[#timers + 1] = function()
        timerNow = timerNow + math.max(0, tonumber(delay) or 0)
        callback()
    end
end
local function drain()
    local count = 0
    while #timers > 0 do
        table.remove(timers, 1)()
        count = count + 1
        assert(count < 10000, "Display cache failed to converge")
    end
end
function IsInInstance() return false end
Overlord.PrintNotification = function() end
OverlordDB.outposts = OverlordDB.outposts or {}
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Outpost.lua"))()
local keep, outpost
for key, site in pairs(Overlord.OutpostSites) do
    if site.isFortress == true then
        if not keep or key < keep then keep = key end
    elseif not outpost or key < outpost then
        outpost = key
    end
end
assert(keep and outpost, "Need one keep and one outpost site")

lb.kills = {
    ["Red One"] = 300, ["Red Two"] = 200, ["Red Two-Realm"] = 200,
    ["Blue One"] = 450, ["Lone Wolf"] = 900,
}
lb.captureCount = {
    -- The same player under two spellings: his five captures count once. Two of them
    -- are signed in the ledger (an outpost and a keep): three front points are left.
    ["Red Two"] = 5, ["Red Two-Realm"] = 5,
    ["Quiet One"] = 4, ["Lone Wolf"] = 7,
    -- His personal total has not caught up with his two signed outposts: no front
    -- point, never a negative number.
    ["Short One"] = 1,
}
-- A row with a capture list but no counter (older row) still counts its captures.
lb.captures = { ["List Only"] = { "redridge_ilgalar", "redridge_three_corners" } }
lb.playerInfo = {
    ["Red One"] = { guild = "Red Guild", faction = "Horde" },
    ["Red Two"] = { guild = "Red Guild", faction = "Horde" },
    ["Blue One"] = { guild = "Blue Guild", faction = "Alliance" },
    ["Short One"] = { guild = "Blue Guild", faction = "Alliance" },
    ["Quiet One"] = { guild = "Quiet Guild", faction = "Alliance" },
    ["List Only"] = { guild = "List Guild", faction = "Horde" },
    ["Lone Wolf"] = { guild = "", faction = "Horde" },
}
local now = time()
local function take(site, guild, faction, ago, capturer)
    assert(lb:RecordOutpostCapture(site, guild, faction, now - ago, "global", capturer),
        "Capture refused: " .. site .. " " .. guild)
end
take(outpost, "Red Guild", "Horde", 9000, "Red Two")
take(keep, "Red Guild", "Horde", 8000, "Red Two")
take(outpost, "Blue Guild", "Alliance", 7000, "Short One")
take(outpost, "Blue Guild", "Alliance", 5000, "Short One")
-- A keep taken by a guild none of whose members is ranked yet: rated on the ledger alone.
take(keep, "Late Guild", "Horde", 3000, "Late One")
local sites, signed = lb:CollectGuildSiteCaptures()
assert(sites["red guild"].outposts == 1 and sites["red guild"].keeps == 1
    and sites["blue guild"].outposts == 2 and sites["blue guild"].keeps == 0
    and sites["late guild"].keeps == 1 and sites["late guild"].faction == "Horde", "ledger totals by guild")
local signedCount = 0
for _, n in pairs(signed) do signedCount = signedCount + n end
assert(signedCount == 5, "signed captures by capturer: " .. signedCount)

assert(lb:RebuildNetworkHotIndexes())
lb._storageBound = true
lb:MarkDirty()
assert(lb:StartDisplayCacheBuild())
drain()
local cache = assert(lb._displayCache, "no display cache")
local rating = assert(cache.sortedGuildRating, "the display cache has no guild rating")

local function describe(rows)
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = ("%s=%d(%d+%dz+%do+%dk,%s)"):format(row.guild, row.points, row.kills, row.zones,
            row.outposts, row.keeps, row.faction)
    end
    return table.concat(out, " ")
end
-- Red: 500 HK, 3 front points, 1 outpost, 1 keep. Blue: 450 HK and 2 outposts. Quiet: 4
-- front points and no kill. Late and List: 100 each, by name.
assert(describe(rating) == "Red Guild=825(500+3z+1o+1k,Horde) Blue Guild=600(450+0z+2o+0k,Alliance) "
    .. "Quiet Guild=200(0+4z+0o+0k,Alliance) Late Guild=100(0+0z+0o+1k,Horde) "
    .. "List Guild=100(0+2z+0o+0k,Horde)", describe(rating))
-- The guild table sorted by kills reads a guild's rating by its name, in any case.
local red = assert(lb:GetGuildRating("RED GUILD"), "no rating row by guild name")
assert(red == rating[1] and red.points == 825 and lb:GetGuildRating("No Such Guild") == nil
    and lb:GetGuildRating("") == nil, "rating lookup by guild name")
assert(OverlordDB.leaderboardDisplayCache.guildRatingByKey == nil, "the lookup table leaked into the saved preview")
-- A player without a guild rates no guild.
for _, row in ipairs(rating) do assert(row.guild ~= "", "a guildless player made a rating row") end
-- The guild kill table is untouched: the same guilds as before, ordered by kills.
local kills = {}
for i, row in ipairs(cache.sortedGuilds) do kills[i] = row.guild .. "=" .. row.kills end
assert(table.concat(kills, " ") == "Red Guild=500 Blue Guild=450", table.concat(kills, " "))

-- A site capture alone refreshes the rating (the ledger marks the view stale).
take(keep, "Quiet Guild", "Alliance", 1000, "Quiet One")
assert(lb:EnsureNetworkHotIndexesPrepared() ~= nil)
drain()
lb:EnsureDisplayCache()
drain()
rating = lb._displayCache.sortedGuildRating
-- His four captures now hold one signed keep: 3 front points + 1 keep = 250.
assert(rating[3].guild == "Quiet Guild" and rating[3].points == 250 and rating[3].zones == 3
    and rating[3].keeps == 1, describe(rating))

-- The login preview keeps the rating; a preview saved before it existed has none.
local saved = assert(OverlordDB.leaderboardDisplayCache, "no saved preview")
assert(#saved.sortedGuildRating == 5 and saved.sortedGuildRating[1].points == 825, "rating missing from the preview")
local restored = assert(lb:RestoreDisplayCache(), "the saved preview was refused")
assert(describe(restored.sortedGuildRating) == describe(rating), describe(restored.sortedGuildRating))
-- (The preview holds the live rows themselves: put the value back.)
local keepsBefore = saved.sortedGuildRating[2].keeps
saved.sortedGuildRating[2].keeps = "many"
assert(lb:RestoreDisplayCache() == nil, "a damaged rating row was restored")
saved.sortedGuildRating[2].keeps = keepsBefore
saved.sortedGuildRating = nil
restored = assert(lb:RestoreDisplayCache(), "a preview without rating was refused")
-- On a restored preview the guild table sorted by kills still reads a guild's rating.
saved.sortedGuildRating = { { guild = "Red Guild", points = 825, kills = 500, zones = 3, outposts = 1,
    keeps = 1, faction = "Horde" } }
local liveCache = lb._displayCache
lb._displayCache = assert(lb:RestoreDisplayCache(), "the preview with one rating row was refused")
local previewRating = assert(lb:GetGuildRating("red guild"), "no rating by name on the login preview")
assert(previewRating.points == 825 and previewRating.keeps == 1 and lb:GetGuildRating("Nobody") == nil)
lb._displayCache = liveCache
saved.sortedGuildRating = nil
assert(#restored.sortedGuildRating == 0 and #restored.sortedGuilds == 2)
-- A build with nothing new gives the same rating: the ledger totals are shared
-- between builds and must come out of one unchanged.
local before = describe(lb._displayCache.sortedGuildRating)
lb:SetPlayerKills("Lone Wolf", 901, true)
lb:MarkDirty()
assert(lb:EnsureNetworkHotIndexesPrepared() ~= nil)
drain()
lb:EnsureDisplayCache()
drain()
assert(describe(lb._displayCache.sortedGuildRating) == before, "a second build changed the rating: "
    .. describe(lb._displayCache.sortedGuildRating))
-- The ledger is read once per change, not once per build.
local sitesA = lb:CollectGuildSiteCaptures()
assert(lb:CollectGuildSiteCaptures() == sitesA, "the ledger totals were rebuilt without a ledger change")
-- A guild seen on both sides in the ledger: one side for everyone (the smallest),
-- whatever the order of the rows.
take(outpost, "Twin Guild", "Horde", 2600, "Twin One")
take(keep, "Twin Guild", "Alliance", 1600, "Twin Two")
local sitesB = lb:CollectGuildSiteCaptures()
assert(sitesB ~= sitesA and sitesB["twin guild"].faction == "Alliance", "ledger side of a two-sided guild")
-- One capturer counts for at most a plausible week of site captures per guild.
take(outpost, "Greedy Guild", "Horde", 2900, "Greedy One")
take(outpost, "Greedy Guild", "Horde", 2300, "Greedy One")
take(outpost, "Greedy Guild", "Horde", 1700, "Greedy One")
take(keep, "Greedy Guild", "Horde", 700, "Greedy One")
local full, signedNow = lb:CollectGuildSiteCaptures()
assert(full["greedy guild"].outposts == 3 and full["greedy guild"].keeps == 1, "plain totals of one capturer")
local ceiling = Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING
Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING = 3
lb._guildSiteCaptures = nil
local capped, signedCapped = lb:CollectGuildSiteCaptures()
Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING = ceiling
lb._guildSiteCaptures = nil
assert(capped["greedy guild"].outposts == 2 and capped["greedy guild"].keeps == 0,
    "one capturer filled a guild past the ceiling: " .. capped["greedy guild"].outposts .. "/" .. capped["greedy guild"].keeps)
local greedy
for key, n in pairs(signedCapped) do if key:find("greedy", 1, true) then greedy = n end end
assert(greedy == 4, "his signed captures still leave his personal total in full")
-- Signed events are what counts, not a row's stored counter; and the two-sided guild
-- reads the same with its rows the other way round (sides swapped on the two sites).
take(outpost, "Mirror Guild", "Alliance", 2650, "Mirror One")
take(keep, "Mirror Guild", "Horde", 1650, "Mirror Two")
for _, row in pairs(lb:GetOutpostCaptureCountsTable()) do
    if row.guildKey == "greedy guild" then row.count = 9999 end
end
lb._guildSiteCaptures = nil
local honest = lb:CollectGuildSiteCaptures()
assert(honest["greedy guild"].outposts == 3 and honest["greedy guild"].keeps == 1,
    "a row's stored counter moved the rating")
assert(honest["mirror guild"].faction == "Alliance" and honest["twin guild"].faction == "Alliance",
    "the side of a two-sided guild depends on the order of its rows")
-- Walked in slices (one ledger row per step) with a capture arriving in the middle:
-- no error, the mixed result is used once and not kept.
lb._guildSiteCaptures = nil
local walk = coroutine.create(function() return lb:CollectGuildSiteCaptures(coroutine.yield) end)
assert(coroutine.resume(walk))
take(outpost, "Sliced Guild", "Horde", 300, "Sliced One")
local steps, ok, sliced = 0, true, nil
while coroutine.status(walk) ~= "dead" do
    ok, sliced = coroutine.resume(walk)
    assert(ok, tostring(sliced))
    steps = steps + 1
    assert(steps < 10000, "the sliced ledger walk did not end")
end
assert(type(sliced) == "table" and sliced["greedy guild"].outposts == 3 and lb._guildSiteCaptures == nil,
    "a ledger walk crossed by a capture was kept")
assert(lb:CollectGuildSiteCaptures()["sliced guild"].outposts == 1, "the capture is read by the next walk")
print("Forever guild rating: kills, front points, outposts and keeps by the ledger, aliases once, late totals, ceiling, preview OK")
