-- Execute the production modules with WoW API stubs, including a fresh login.
local timers, events = {}, {}
local now = 1790016000
local region = 3
function GetTime() return 100 end
function time(t) return t and os.time(t) or now end
function date(fmt, t) return os.date(fmt, t or now) end
function GetServerTime() return now end
function GetCurrentRegion() return region end
function GetLocale() return "enUS" end
function UnitFactionGroup() return "Alliance" end
function UnitName() return "Dwarf Tester" end
function UnitFullName() return "Dwarf Tester", "" end
function GetUnitName() return "Dwarf Tester" end
function InCombatLockdown() return false end
function IsInInstance() return false end
function GetInstanceInfo() return nil, nil, "none" end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function CreateFrame()
    local f = { RegisterEvent = function() end, UnregisterEvent = function() end }
    function f:SetScript(kind, callback) if kind == "OnEvent" then events[#events + 1] = callback end end
    return f
end
C_Timer = {
    After = function(_, callback) timers[#timers + 1] = callback end,
    NewTicker = function() return { Cancel = function() end } end,
    NewTimer = function() return { Cancel = function() end } end,
}
Overlord = { L = {} }
assert(loadfile("Core.lua"))()
assert(loadfile("RealmPools.lua"))()
assert(loadfile("Popups.lua"))()

-- Forever beta is one global pool regardless of the login region or old tag.
OverlordDB = { lastSessionPool = "us" }
assert(Overlord.RealmPools:GetOverlordPoolTag() == "global")
region = 1
OverlordDB.lastSessionPool = "eu"
assert(Overlord.RealmPools:GetOverlordPoolTag() == "global")
assert(Overlord.RealmPools:AreOutpostCrossPoolsLinked("eu", "us"))
assert(Overlord.RealmPools:AreOutpostCrossPoolsLinked("fr", "eu"))
assert(Overlord.RealmPools:NormalizeRegionPool("na") == "global")
-- 1.4.0: an account-wide DB, one world per ruleset. A PvE alt parks the PvP
-- world (front zones, victories, truces, outposts, fortresses) and starts from
-- the initial state; back on PvP it comes back intact; a world parked before the
-- weekly reset never comes back.
do
    local function world(tag)
        return {
            zones = { z = { owner = tag } }, frontVictories = { f = { faction = tag } },
            frontTruceResetEpoch = { f = 1 },
            outposts = { site = { status = "held", ownerGuild = tag, pool = tag == "pvp" and "global" or nil } },
            outpostTenants = { site = { guild = tag } }, outpostCaptureCounts = { k = { count = 2 } },
        }
    end
    local function newSession() Overlord._rulesetWorldChecked = nil; return true end
    local keys = { "zones", "frontVictories", "frontTruceResetEpoch", "outposts",
        "outpostTenants", "outpostCaptureCounts" }
    local pvp = world("pvp")
    OverlordDB = { lastResetTimestamp = 1000, lastSessionPool = "global",
        lastVictoryTimestamp = 900, lastVictoryFaction = "Horde", lastVictoryFrontId = "f" }
    for _, k in ipairs(keys) do OverlordDB[k] = pvp[k] end
    assert(newSession() and Overlord:SwapRulesetWorld("normal"), "Ruleset change did not swap the world")
    assert(OverlordDB.lastVictoryTimestamp == nil and OverlordDB.lastVictoryFaction == nil,
        "PvE alt inherited the PvP legacy victory")
    assert(OverlordDB.lastSessionPool == "normal", "Session pool not saved at the swap")
    for _, k in ipairs(keys) do
        assert(type(OverlordDB[k]) == "table" and next(OverlordDB[k]) == nil, "PvE alt saw PvP " .. k)
    end
    OverlordDB.zones.z = { owner = "pve" }
    OverlordDB.lastSessionPool = "normal"
    assert(newSession() and Overlord:SwapRulesetWorld("global"))
    for _, k in ipairs(keys) do assert(OverlordDB[k] == pvp[k], "PvP " .. k .. " not restored") end
    assert(OverlordDB.lastVictoryTimestamp == 900 and OverlordDB.lastVictoryFrontId == "f",
        "PvP legacy victory not restored")
    OverlordDB.lastSessionPool = "global"
    assert(newSession() and not Overlord:SwapRulesetWorld("global"), "Same ruleset swapped the world")
    -- Initialize restarting in the same session never swaps twice.
    local kept = OverlordDB.zones
    OverlordDB.lastSessionPool = "normal"
    assert(not Overlord:SwapRulesetWorld("global") and OverlordDB.zones == kept, "Second swap in one session")
    OverlordDB.lastSessionPool = "global"
    -- A reset anchor nudged mid-week (hours) still brings the world back.
    OverlordDB.lastSessionPool = "global"
    assert(newSession() and Overlord:SwapRulesetWorld("normal"))
    OverlordDB.lastResetTimestamp = 1000 + 3600
    assert(newSession() and Overlord:SwapRulesetWorld("global"))
    assert(OverlordDB.zones == pvp.zones, "A nudged reset anchor lost the PvP world")
    OverlordDB.lastResetTimestamp = 1000
    -- Weekly reset while on PvP: last week's PvE world never comes back.
    OverlordDB.lastResetTimestamp = 1000 + 7 * 24 * 3600
    assert(newSession() and Overlord:SwapRulesetWorld("normal"))
    assert(next(OverlordDB.zones) == nil, "Last week's PvE map came back after the reset")
    -- A Normal alt already logged before this check (lastSessionPool = normal)
    -- still holds PvP-stamped outposts: the stamp wins, the world is parked as PvP.
    local stale = world("pvp")
    OverlordDB = { lastResetTimestamp = 3000, lastSessionPool = "normal" }
    for _, k in ipairs(keys) do OverlordDB[k] = stale[k] end
    assert(newSession() and Overlord:SwapRulesetWorld("normal"), "PvP-stamped world stayed on the Normal alt")
    assert(next(OverlordDB.zones) == nil)
    OverlordDB.lastSessionPool = "normal"
    newSession(); Overlord:SwapRulesetWorld("global")
    assert(OverlordDB.zones == stale.zones and OverlordDB.outposts == stale.outposts,
        "PvP world parked from the Normal alt was lost")
    -- Every PvP login: unstamped rows on the same pool, nothing moves.
    OverlordDB = { lastResetTimestamp = 3000, lastSessionPool = "global", zones = { a = 1 } }
    assert(newSession() and not Overlord:SwapRulesetWorld("global") and OverlordDB.zones.a == 1
        and OverlordDB.worldsByPool == nil)
end
assert(Overlord:SavedVarsPoolFromLocaleTag("frFR") == nil)
local globalReset = Overlord:GetLastResetTimestamp()
region = 3
assert(Overlord:GetLastResetTimestamp() == globalReset, "EU and US clients chose different campaigns")

local zone = { id = "point", holdTimeRequired = 120, status = "locked" }
Overlord.ZoneDatabase = { zone }
Overlord.Fronts = {
    activeFrontId = "test", Registry = { test = { zones = { zone } } }, Order = {},
    GetZone = function(_, id) return id == zone.id and zone or nil end,
    GetCapitalId = function() return nil end,
    GetEnemyCapitalId = function() return nil end,
}
Overlord.Zones = {
    GetZone = function(_, id) return id == zone.id and zone or nil end,
    GetBaseZoneFixedOwner = function() return nil end,
    IsOnVictoryCooldown = function() return false end,
    UpdateAvailableZones = function() end,
}
Overlord.GetCurrentCampaignStartTs = function() return now - 3600 end
local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}; for k, v in pairs(t) do out[k] = copy(v) end; return out
end
OverlordDB = { lastResetTimestamp = now - 3600, zones = {}, config = {} }
zone.status, zone.owner, zone.capturedTime, zone.updatedAt = "captured", "Alliance", now - 30, now - 30
Overlord:SaveState()
Overlord.Popups:MarkSeen("welcome_first_install")
local disk = copy(OverlordDB)

-- A second character receives the same account save, just as the local bridge/native loader does.
OverlordDB = copy(disk)
zone.status, zone.owner, zone.capturedTime, zone.updatedAt = "locked", nil, nil, 0
Overlord.PlayerFaction = "Horde"
Overlord:RestoreZoneState()
assert(zone.owner == "Alliance" and zone.capturedTime == now - 30, "Alt lost the account capture")
assert(Overlord.Popups:HasSeen("welcome_first_install"), "Alt replayed a one-shot popup")
assert(not Overlord.Popups:HasSeen("forever_launch_1_0_0"), "Different popup incorrectly suppressed")

-- Saving a newer attack/neutral state must not resurrect the old capture.
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.updatedAt, zone.holdTimeElapsed = now, 20
Overlord:SaveState()
assert(OverlordDB.zones.point.status == "in_progress" and OverlordDB.zones.point.owner == "Horde")
zone.status, zone.owner, zone.capturedTime, zone.updatedAt = "available", nil, nil, now + 1
Overlord:SaveState()
assert(OverlordDB.zones.point.owner == nil and OverlordDB.zones.point.capturedTime == nil,
    "Old saved capture overrode a legitimate neutral state")

-- A capture from before the current campaign must expire.
OverlordDB = copy(disk)
OverlordDB.lastResetTimestamp = now
Overlord.GetCurrentCampaignStartTs = function() return now end
Overlord:RestoreZoneState()
assert(zone.owner == nil and zone.capturedTime == nil, "Old campaign capture was resurrected")

-- A real weekly rollover still resets a recently captured point exactly once.
OverlordDB = copy(disk)
OverlordDB.lastResetTimestamp = now - 604800
zone.owner, zone.status, zone.capturedTime = "Alliance", "captured", now - 30
Overlord.GetLastResetTimestamp = function() return now end
local resets = 0
Overlord.Leaderboard = {
    Reset = function(_, _, epoch)
        resets = resets + 1
        OverlordDB.pendingWeeklyArchive = { resetEpoch = epoch }
    end,
    MarkWeeklyResetCoreSideEffectsApplied = function()
        OverlordDB.pendingWeeklyArchive.coreSideEffectsApplied = true
    end,
    ResumePendingWeeklyArchive = function() OverlordDB.pendingWeeklyResetAt = nil end,
}
Overlord.PrintNotification = function() end
Overlord.L.WEEKLY_RESET = "Weekly reset"
Overlord.L.ALL_ZONES_RESET = "All zones reset"
Overlord:CheckWeeklyReset()
assert(resets == 1 and zone.owner == nil and OverlordDB.zones.point.owner == nil,
    "A recent capture prevented the legitimate weekly reset")
Overlord.Leaderboard:ResumePendingWeeklyArchive()
Overlord:CheckWeeklyReset()
assert(resets == 1, "Same campaign reset twice")
Overlord.Leaderboard = nil

-- ADDON_LOADED immediately calls Initialize. No invented 30-second binding delay.
local initialized = 0
Overlord.Initialize = function() initialized = initialized + 1 end
for _, callback in ipairs(events) do callback(nil, "ADDON_LOADED", "Overlord") end
assert(initialized == 1, "Initialization did not run at ADDON_LOADED")
print("Forever persistence: alt capture, one-shot flags, new attack, neutral state, campaign expiry, login and regions OK")

assert(loadfile("Sync.lua"))()
assert(loadfile("SyncAux.lua"))()
local sync = Overlord.Sync
assert(sync:CanonicalForeverName("Troma Orcbane") == "Troma Orcbane")
assert(sync:CanonicalForeverName("Troma Orcbane-Realm") == "Troma Orcbane")
assert(sync:CanonicalForeverName("Troma") == nil)
assert(sync:CanonicalForeverName("Troma-Realm") == nil)
assert(sync:CanonicalForeverName("Troma 123") == nil)
assert(sync:ForeverIdentitiesMatch("TromaOrcbane", "Troma Orcbane"))
assert(not sync:ForeverIdentitiesMatch("Troma", "Troma Orcbane"))
assert(not sync:ForeverIdentitiesMatch("Troma Orcbane", "Troma Other"))
assert(sync:IsValidWhisperTarget("Élodie Marteau"))
-- Some Windows C locales classify UTF-8 continuation byte 0xA0 as whitespace.
-- Identity normalization must trim ASCII separators without breaking accents.
assert(sync:CanonicalForeverName("Shàter Dogx") == "Shàter Dogx")
assert(sync:CanonicalForeverName("  Àlbert Chàrlà  ") == "Àlbert Chàrlà")
assert(sync:IsValidWhisperTarget("Иван Воин"))
assert(not sync:IsValidWhisperTarget("Troma Orcbane:payload"))
assert(sync:GetMyBand() == "Forever_global_H")
region = 1
assert(sync:GetMyBand() == "Forever_global_H")
assert(not sync:IsRPRealm())
print("Forever identity: full names, API suffix, compact sender, accents, Cyrillic and global routing OK")
