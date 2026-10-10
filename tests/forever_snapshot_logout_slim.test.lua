-- At logout the saved ladder snapshot drops the index-only fields it shares with the
-- live meta index (src, raceKey, an empty pool): about a quarter of its text, parsed
-- at every login. Every page, catch-up row and login restore built from it is unchanged.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
assert(loadfile("Leaderboard.lua"))()
local lb = Overlord.Leaderboard
lb._storageBound = true
local timers, head = {}, 1
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local function drain()
    local steps = 0
    while head <= #timers do
        local callback = timers[head]
        timers[head], head = false, head + 1
        callback()
        steps = steps + 1
        assert(steps < 30000, "builders failed to converge")
    end
    timers, head = {}, 1
end
local races = { "Human", "Orc", "Dwarf", "Scourge", "NightElf", "Tauren" }
local names = {}
local function suffix(i)
    return string.char(97 + math.floor(i / 26) % 26, 97 + i % 26)
end
for i = 1, 300 do
    local name = "Slim Play" .. suffix(i)
    names[#names + 1] = name
    lb.kills[name] = 10 + i
    lb.captureCount[name] = i % 7 + 1
    lb.playerInfo[name] = { guild = "Guild " .. (i % 13), guildAuth = (i % 2 == 0) or nil,
        guildAt = time() - i, faction = i % 2 == 0 and "Alliance" or "Horde", class = "PRIEST",
        level = 60, locale = "enus", race = races[i % #races + 1], raceSex = 2 + i % 2,
        raceAt = time() - 3 * i, pool = (i % 5 == 0) and "global" or "" }
end
lb:MarkDirty()
drain()
local done
lb:SnapshotCurrentCampaignBeforeReset(function(ok) done = ok end)
drain()
assert(done, "the snapshot was not built")
local snapshot = assert(OverlordDB.leaderboardSnapshot)
local withIndexFields = 0
for _, entry in pairs(snapshot.playerInfo) do
    if entry.src ~= nil or entry.raceKey ~= nil or entry.pool == "" then withIndexFields = withIndexFields + 1 end
end
assert(withIndexFields > 0, "the snapshot no longer carries index fields (test is vacuous)")

assert(loadfile("SyncHistoryCatchup.lua"))()
local sync = Overlord.Sync
local epoch = snapshot.campaignStart
local function payloads()
    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = table.concat({ name,
            tostring(sync:BuildPagedLeaderboardKillPayload(snapshot, name, epoch)),
            tostring(sync:BuildPagedLeaderboardCapturePayload(snapshot, name, epoch)),
            tostring(sync:BuildPagedLeaderboardRacePayload(snapshot, name, epoch)),
            tostring(sync._PagedRaceField and sync._PagedRaceField(snapshot, name, "x")) }, "|")
    end
    local count, digest = sync:ComputeHistoryCatchupSnapshotDigest(snapshot, epoch)
    out[#out + 1] = tostring(count) .. ":" .. tostring(digest)
    return table.concat(out, "\n")
end
local function copy(t)
    if type(t) ~= "table" then return t end
    local result = {}
    for k, v in pairs(t) do result[k] = copy(v) end
    return result
end
local function restored()
    local savedInfo, savedKills, savedCaps = lb.playerInfo, lb.kills, lb.captureCount
    lb.playerInfo, lb.kills, lb.captureCount = {}, {}, {}
    lb:RestoreFullLadderFromSnapshotIfNeeded()
    local rows = {}
    for _, name in ipairs(names) do
        local r = lb.playerInfo[name] or {}
        local keys = {}
        for k in pairs(r) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = { name, tostring(lb.kills[name]), tostring(lb.captureCount[name]) }
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(r[k]) end
        rows[#rows + 1] = table.concat(parts, ",")
    end
    lb.playerInfo, lb.kills, lb.captureCount = savedInfo, savedKills, savedCaps
    return table.concat(rows, "\n")
end
local beforePayloads, beforeRestore = payloads(), restored()
local served = 0
for line in beforePayloads:gmatch("[^\n]+") do
    if not line:find("|nil|nil|nil|nil", 1, true) then served = served + 1 end
end
assert(served >= 250, "the snapshot serves almost nothing (test is vacuous): " .. served)
lb:SlimSavedSnapshotForLogout()
-- What the next login reads: a plain copy of the saved tables.
snapshot = copy(snapshot)
OverlordDB.leaderboardSnapshot = snapshot
for name, entry in pairs(snapshot.playerInfo) do
    assert(entry.src == nil and entry.raceKey == nil and entry.pool ~= "",
        "an index-only field was saved for " .. tostring(name))
end
assert(payloads() == beforePayloads, "a page or catch-up row changed after the logout strip")
assert(restored() == beforeRestore, "the login restore changed after the logout strip")
print("Snapshot logout slim: index-only fields dropped, pages and login restore unchanged")
