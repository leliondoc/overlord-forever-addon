-- Most Wanted (top five enemies, local only) and the network health indicator level.
local now = 1000
GetTime = function() return now end
IsInInstance = function() return false end
CreateFrame = nil -- no event frame in the harness: handlers are called directly
C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end }
local printed = {}
Overlord = {
    PlayerFaction = "Alliance",
    InstanceSuspended = false,
    L = {},
    PrintNotification = function(_, text) printed[#printed + 1] = text end,
    SafeGetUnitName = function(_, unit) return unit end,
    Zones = { GetEnemyFactionName = function() return "Horde" end },
    Sync = { CanonicalForeverName = function(_, name) return name end },
}
OverlordDB = { config = {} }
local units = {}
UnitExists = function(unit) return units[unit] ~= nil end
UnitIsPlayer = function(unit) return units[unit] ~= nil end
UnitFactionGroup = function(unit) return units[unit] end

-- Display cache already sorted by kills, with faction in meta[name][2].
Overlord.Leaderboard = { kills = {} }
Overlord.Leaderboard._displayCache = {
        sortedKills = {
            { name = "Ally One", kills = 9000 }, { name = "Horde One", kills = 8000 },
            { name = "Horde Two", kills = 7000 }, { name = "Ally Two", kills = 6500 },
            { name = "Horde Three", kills = 6000 }, { name = "Horde Four", kills = 5000 },
            { name = "Horde Five", kills = 4000 }, { name = "Horde Six", kills = 3000 },
        },
        meta = {
            ["Ally One"] = { "WARRIOR", "Alliance" }, ["Ally Two"] = { "MAGE", "Alliance" },
            ["Horde One"] = { "ROGUE", "Horde" }, ["Horde Two"] = { "SHAMAN", "Horde" },
            ["Horde Three"] = { "HUNTER", "Horde" }, ["Horde Four"] = { "WARLOCK", "Horde" },
            ["Horde Five"] = { "PRIEST", "Horde" }, ["Horde Six"] = { "DRUID", "Horde" },
        },
    killSource = Overlord.Leaderboard.kills,
}

assert(loadfile("MostWanted.lua"))()
local MW = Overlord.MostWanted
MW:Refresh(true)
assert(#MW.list == 5, "Most Wanted must hold five enemies")
assert(MW.list[1].name == "Horde One" and MW.list[1].rank == 1, "first enemy is not #1")
assert(MW:IsWanted("Horde Five") and not MW:IsWanted("Horde Six"), "sixth enemy listed")
assert(not MW:IsWanted("Ally One"), "an ally was listed as Most Wanted")

-- Alert once, then per-player and global delays.
units["Horde Two"], units["Horde Three"], units["Ally One"] = "Horde", "Horde", "Alliance"
MW:OnNameplateAdded("Horde Two")
assert(#printed == 1 and printed[1]:find("Horde Two", 1, true) and printed[1]:find("#2", 1, true),
    "Most Wanted alert missing or wrong rank")
MW:OnNameplateAdded("Horde Two")
assert(#printed == 1, "same enemy alerted twice")
now = now + 5
MW:OnNameplateAdded("Horde Three")
assert(#printed == 1, "global alert gap not respected")
now = now + 30
MW:OnNameplateAdded("Horde Three")
assert(#printed == 2, "second Most Wanted enemy not alerted after the global gap")
MW:OnNameplateAdded("Ally One")
assert(#printed == 2, "an ally triggered an alert")

-- Nothing in an instance; alerts can be switched off.
now = now + 1000
Overlord.InstanceSuspended = true
MW:OnNameplateAdded("Horde Two")
assert(#printed == 2, "Most Wanted alerted inside an instance")
Overlord.InstanceSuspended = false
MW:HandleCommand({ "wanted", "off" })
assert(OverlordDB.config.mostWantedAlerts == false, "/ov wanted off did not stick")
MW:OnNameplateAdded("Horde Two")
assert(#printed == 3, "/ov wanted must print its state")
MW:HandleCommand({ "wanted", "on" })

-- Weekly reset: a display cache of the previous campaign never names last week's players.
local lastWeek = Overlord.Leaderboard._displayCache
Overlord.Leaderboard.kills = {} -- the reset swaps in a new score table
local ensured = 0
Overlord.Leaderboard.EnsureDisplayCache = function() ensured = ensured + 1 end
MW:Refresh(true)
assert(#MW.list == 0 and not MW:IsWanted("Horde One"), "last week's Most Wanted survived the reset")
assert(ensured == 1, "a stale view did not ask for a fresh one")
-- The reset itself empties the list at once (no 60 s wait for the ticker).
lastWeek.killSource = Overlord.Leaderboard.kills
MW:Refresh(true)
assert(MW:IsWanted("Horde One"), "fixture: list not rebuilt")
MW:ResetForCampaign()
assert(#MW.list == 0 and not MW:IsWanted("Horde One"), "the weekly reset kept last week's Most Wanted")
lastWeek.killSource = Overlord.Leaderboard.kills
MW:Refresh(true)
assert(#MW.list == 5, "a current view was not used")

-- Skull on the Blizzard nameplate, right of the health bar; gone when the plate is
-- recycled, in an instance and at the weekly reset.
local function stubFrame()
    local f = { shown = false }
    function f:SetSize() end
    function f:SetPoint(_, anchor) self.anchor = anchor end
    function f:ClearAllPoints() end
    function f:SetParent(p) self.parent = p end
    function f:GetParent() return self.parent end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:CreateTexture() return { SetAllPoints = function() end, SetTexture = function() end } end
    return f
end
CreateFrame = function(_, _, parent) local f = stubFrame(); f.parent = parent; return f end
local plates = {}
C_NamePlate = { GetNamePlateForUnit = function(unit) return plates[unit] end }
plates["Horde Four"] = { UnitFrame = { healthBar = {} } }
units["Horde Four"] = "Horde"
now = now + 1000
MW:OnNameplateAdded("Horde Four")
local skull = MW.skulls["Horde Four"]
assert(skull and skull.shown and skull.anchor == plates["Horde Four"].UnitFrame.healthBar,
    "no skull next to the health bar of a Most Wanted enemy")
MW:HideSkull("Horde Four")
assert(not skull.shown, "the skull stayed on a recycled nameplate")
MW:OnNameplateAdded("Horde Four")
MW:OnInstanceSuspend()
assert(not skull.shown, "a skull stayed visible in an instance")
MW:OnNameplateAdded("Horde Four")
MW:ResetForCampaign()
assert(not skull.shown, "last week's skull survived the weekly reset")
assert(skull.anchor == plates["Horde Four"].UnitFrame.healthBar, "skull not anchored on the health bar")
CreateFrame, C_NamePlate = nil, nil

-- Network indicator: a stuck ladder round alone stays green; real losses turn it orange.
assert(loadfile("NetworkHealth.lua"))()
local NH = Overlord.NetworkHealth
Overlord.Sync._addonSendStats = { CHANNEL = { ok = 100, refused = 0 }, WHISPER = { ok = 50, refused = 0 } }
Overlord.Relay = { stats = { sent = 1000, dropped = 2, received = 900 },
    GetQueueSummary = function() return { total = 1, catchup = 0, catchupMax = 16, state = 0, stateMax = 24 } end }
Overlord.Sync.GetPagedLeaderboardSummary = function()
    return { status = "interrupted (no reply); bucket retained", pages = 3, rows = 30, protocol = 6 }
end
local level, rows, overall = NH:IndicatorLevel()
assert(level == "ok" and overall == "warn" and #rows == 4, "an interrupted catch-up colored the indicator")
Overlord.Relay.stats.dropped = 30 -- 3 % of 1000
level = NH:IndicatorLevel()
assert(level == "warn", "relay losses did not turn the indicator orange")
print("Most Wanted: top five enemies, alert delays, instance cutoff, toggle; network indicator levels OK")
