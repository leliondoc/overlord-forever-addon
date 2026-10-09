-- Instrument a visible 4,000-row ladder receiving fresh paged LK rows.
-- Counts work; no machine-dependent CPU-time threshold is asserted.
assert(loadfile("tests/forever_world_kills.test.lua"))()
assert(loadfile("Leaderboard.lua"))()
local lb, sync = Overlord.Leaderboard, Overlord.Sync
lb._storageBound = true
local now, pending, serial, slices = 100, {}, 0, 0
function GetTime() return now end
C_Timer.After = function(delay, callback)
    serial = serial + 1
    pending[#pending + 1] = {
        at = now + math.max(0.016, tonumber(delay) or 0),
        serial = serial, callback = callback,
    }
end
local function advance(seconds)
    local stop = now + seconds
    while #pending > 0 do
        table.sort(pending, function(a, b)
            return a.at < b.at or (a.at == b.at and a.serial < b.serial)
        end)
        if pending[1].at > stop then break end
        local item = table.remove(pending, 1)
        now = item.at
        item.callback()
        slices = slices + 1
        assert(slices < 100000, "Unbounded LK/UI work")
    end
    now = stop
end
local function suffix(i)
    return string.char(65 + math.floor(i / 676) % 26,
        97 + math.floor(i / 26) % 26, 97 + i % 26)
end
for i = 1, 4000 do
    local name = "Base " .. suffix(i)
    lb.kills[name] = i
    lb.playerInfo[name] = { class = "PRIEST", level = 2, faction = "Horde",
        guild = "Base Guild", guildAt = 1790016000, locale = "enus" }
end
lb:MarkMetaDirty()
assert(lb:EnsureNetworkHotIndexesPrepared() == false)
advance(15)
assert(lb:EnsureNetworkHotIndexesPrepared() == true)
lb:EnsureDisplayCache()
assert(lb._displayCacheBuildPending,
    "First display build was delayed despite no usable view")
advance(45)
assert(lb._displayCache and lb._displayCache.ready,
    "Open ranking did not have an initial usable view; pending="
        .. tostring(lb._displayCacheBuildPending ~= nil)
        .. " canonical=" .. tostring(lb._displayCanonicalWaitPending ~= nil))

local displayStarts, metadataScans, networkScans, dedupLookups = 0, 0, 0, 0
local startDisplay = lb.StartDisplayCacheBuild
lb.StartDisplayCacheBuild = function(self, ...)
    local started = startDisplay(self, ...)
    if started then displayStarts = displayStarts + 1 end
    return started
end
local rebuildMeta = lb.RebuildDedupMetaIndex
lb.RebuildDedupMetaIndex = function(self, ...)
    metadataScans = metadataScans + 1
    return rebuildMeta(self, ...)
end
local rebuildNetwork = lb.RebuildNetworkHotIndexes
lb.RebuildNetworkHotIndexes = function(self, ...)
    networkScans = networkScans + 1
    return rebuildNetwork(self, ...)
end
local getKey = sync.GetCaptureContributorDedupKey
sync.GetCaptureContributorDedupKey = function(self, ...)
    dedupLookups = dedupLookups + 1
    return getKey(self, ...)
end
sync.IsExpectedPagedLeaderboardDelivery = function() return true end
-- A real paged receiver processes the admitted LK through OnReceiveLeaderboardKills.
-- Keep the existing view open and request its cache after each new row.
local initialSlices = slices
local function importLK(i)
    local name = "Import " .. suffix(i)
    local payload = table.concat({ name, tostring(100 + i), "PRIEST", "Horde",
        "1789527600", "enus", "Imported Guild", "1790016000",
        "B1789527600", "2" }, ":")
    assert(sync:OnReceiveLeaderboardKills(payload, "Relay Tester", "WHISPER"),
        "Synthetic admitted LK was rejected")
end
for i = 1, 60 do
    importLK(i)
    assert(lb:EnsureDisplayCache().ready,
        "A cache abort blanked the visible ranking")
    advance(0.1)
end
local during = { displayStarts = displayStarts, metadataScans = metadataScans,
    networkScans = networkScans, lookups = dedupLookups, slices = slices - initialSlices }
assert(during.displayStarts <= 3 and during.metadataScans <= 3,
    "Aggressive consumer restarted population scans after LK metadata aborts")
advance(12)
lb:EnsureDisplayCache()
advance(12)
assert(lb._displayCache and lb._displayCache.ready,
    "Display cache did not eventually publish after incoming LK stopped")
assert(lb.kills["Import " .. suffix(60)] == 160)
local previousStarts, previousScans = displayStarts, metadataScans
for i = 61, 72 do
    importLK(i)
    assert(lb:EnsureDisplayCache().ready,
        "One-second UI cadence blanked the previous view")
    advance(1)
end
local uiStarts, uiScans = displayStarts - previousStarts,
    metadataScans - previousScans
assert(uiStarts <= 6 and uiScans <= 6,
    "One-second UI cadence bypassed the minimum attempt interval")
advance(12)
lb:EnsureDisplayCache()
advance(12)
local cache = assert(lb._displayCache)
assert(cache.ready and cache.epoch == lb._displayCacheEpoch,
    "Final display refresh missed the last received LK")
local expectedHorde = 0
for name, kills in pairs(lb.kills) do
    local info = lb.playerInfo[name]
    if info and info.faction == "Horde" then expectedHorde = expectedHorde + kills end
end
assert(cache.hordeKills == expectedHorde and lb.kills["Import " .. suffix(72)] == 172,
    "Final ranking lost an imported score or faction total")
print(string.format("LK import while panel open: 60 rows, %d display builds, %d meta scans, %d network scans, %d identity lookups, %d timer slices during import; final builds=%d",
    during.displayStarts, during.metadataScans, during.networkScans,
    during.lookups, during.slices, displayStarts))
print(string.format("LK import at one-second UI cadence: 12 rows, %d display builds, %d meta scans; final cache current",
    uiStarts, uiScans))
