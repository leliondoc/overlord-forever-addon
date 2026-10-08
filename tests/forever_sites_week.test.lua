-- Leaderboard "Capturers and rivalries" view: read only from the signed keep and
-- outpost capture ledger (no packet). Capturers are counted per character, keeps and
-- outposts apart; a rivalry is two successive captures of one site by guilds of
-- opposite factions ("A took from B"), never a same-faction change.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now = 1790018000
function time() return now end
function GetServerTime() return now end
function GetTime() return now - 1790016000 end
function GetGuildInfo() return "Lions" end
function IsInInstance() return false end
function UnitFactionGroup() return "Alliance" end
Overlord.PlayerFaction = "Alliance"
Overlord.PrintNotification = function() end
OverlordDB = { lastResetTimestamp = 1789527600, config = {}, outposts = {} }
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Outpost.lua"))()
local lb = Overlord.Leaderboard

local keep, outpost
for key, site in pairs(Overlord.OutpostSites) do
    if site.isFortress == true then
        if not keep or key < keep then keep = key end
    elseif not outpost or key < outpost then
        outpost = key
    end
end
assert(keep and outpost, "Need one keep and one outpost site")

local function take(site, guild, faction, ago, capturer)
    local ok = lb:RecordOutpostCapture(site, guild, faction, now - ago, "global", capturer)
    assert(ok, "Capture refused: " .. site .. " " .. guild)
end
take(keep, "Lions", "Alliance", 5000, "Arthas-Realm")
take(keep, "Orcs", "Horde", 4000, "Thrall-Realm")
take(keep, "Lions", "Alliance", 3000, "Arthas-Realm")
take(outpost, "Orcs", "Horde", 2000, "Thrall-Realm")
take(outpost, "Wolves", "Horde", 1000, "Rexxar-Realm")

local stats = lb:GetOutpostWeeklyStats()
local c = stats.capturers
assert(#c == 3, "Three capturers expected, got " .. #c)
-- Same total (2): more keeps first, then the name.
assert(c[1].name == "Arthas-Realm" and c[1].keeps == 2 and c[1].outposts == 0)
assert(c[2].name == "Thrall-Realm" and c[2].keeps == 1 and c[2].outposts == 1)
assert(c[3].name == "Rexxar-Realm" and c[3].total == 1)

local r = stats.rivalries
assert(#r == 2, "Two rivalries expected (Orcs > Lions, Lions > Orcs), got " .. #r)
local seen = {}
for _, row in ipairs(r) do seen[row.taker .. ">" .. row.victim] = row.count end
assert(seen["Orcs>Lions"] == 1 and seen["Lions>Orcs"] == 1, "Wrong rivalries")
assert(seen["Wolves>Orcs"] == nil, "A same-faction change is not a rivalry")

-- Cached until the ledger changes, then rebuilt, at most every 3 s (a catch-up
-- burst keeps the previous view for a moment instead of rebuilding per event).
assert(lb:GetOutpostWeeklyStats() == stats, "Stats should be cached")
take(keep, "Orcs", "Horde", 500, "Thrall-Realm")
local held, late = lb:GetOutpostWeeklyStats()
assert(held == stats and late == true, "A rebuild within 3 s keeps the previous stats and says so")
now = now + 5
local after = lb:GetOutpostWeeklyStats()
assert(after ~= stats and after.rivalries[1].taker == "Orcs" and after.rivalries[1].count == 2,
    "A new capture must update the rivalries")
assert(after.capturers[1].name == "Thrall-Realm" and after.capturers[1].total == 3)
print("Sites week: capturers per character, cross-faction rivalries, cache by ledger OK")
