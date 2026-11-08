local now, serverNow = 100, 2000000000
local grouped, leader, suspended = true, true, false
local timers, tickers = {}, {}
local releases, resyncs, down = 0, 0, 0
function GetTime() return now end
function time() return serverNow end
function IsInGroup() return grouped end
function IsInRaid() return false end
function IsInInstance() return suspended end
function UnitIsGroupLeader(unit) return unit == "player" and leader end
function UnitExists() return false end
function InCombatLockdown() return false end
function wipe(values) for key in pairs(values) do values[key] = nil end end
local function expect(condition, message)
    if not condition then error(message, 2) end
end
local function timer(callback)
    return { callback = callback, Cancel = function(self) self.cancelled = true end }
end
C_Timer = {
    After = function(_, callback) timers[#timers + 1] = timer(callback) end,
    NewTimer = function(_, callback)
        local handle = timer(callback); timers[#timers + 1] = handle; return handle
    end,
    NewTicker = function(_, callback)
        local handle = timer(callback); tickers[#tickers + 1] = handle; return handle
    end,
}
local function drain()
    local count = 0
    while #timers > 0 do
        local handle = table.remove(timers, 1)
        if not handle.cancelled then handle.callback() end
        count = count + 1
        expect(count < 10000, "timer fanout did not converge")
    end
end
C_Map = {
    GetBestMapForUnit = function() return 1 end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.5, 0.5 end }
    end,
}
OverlordDB = { lastResetTimestamp = 77 }
Overlord = {
    L = {}, CommunityModeEnabled = false, PlayerFaction = "Alliance", InActiveFront = true,
    RealmPools = { GetOverlordPoolTag = function() return "eu" end },
    Zones = { IsWarFrontMapID = function() return true end },
    Sync = {
        GetPlayerFullName = function() return "Leader Tester" end,
        GetCaptureContributorDedupKey = function(_, name) return name and name:lower() end,
        FindCommunityClub = function() error("Forever must not query clubs") end,
    },
    GeneralSync = {
        BroadcastClaim = function() end,
        BroadcastPosition = function() end,
        BroadcastRelease = function() releases = releases + 1 end,
        BroadcastGroupResync = function() resyncs = resyncs + 1 end,
        BroadcastDown = function() down = down + 1 end,
    },
}
dofile("General.lua")
local general = Overlord.General
expect(general:TryClaim(true), "group leader on a front could not claim")
expect(general:IsLocalHolder() and OverlordDB.generalSession,
    "claim did not create active and persisted state")
Overlord.PlayerFaction = "Horde"
expect(general:GetLocalHolderFaction() == "Alliance",
    "holder faction followed the player faction before releasing the old claim")
Overlord.PlayerFaction = "Alliance"
drain()

local before = resyncs
for _ = 1, 1000 do general:OnGroupRosterUpdate() end
drain()
expect(resyncs == before + 1, "roster storm ran more than one group resync")
leader = false
general:OnGroupRosterUpdate()
drain()
expect(not general:IsLocalHolder() and not OverlordDB.generalSession and releases == 1,
    "leadership loss did not release and clear the saved session")
expect(tickers[1].cancelled, "leadership loss retained the position ticker")
expect(not general:TryClaim(true), "nonleader could claim")

leader = true
serverNow = serverNow + 1
expect(general:TryClaim(true), "new leader could not claim the released slot")
expect(general:ClearLocalOnDeath(), "death did not clear the general immediately")
expect(not general:IsLocalHolder() and not OverlordDB.generalSession,
    "death left general active or restorable")
expect(general:EmitPendingDown("Enemy Tester", "MAGE", "zone") and down == 1,
    "death proof was not sent")
expect(not general:EmitPendingDown("Enemy Tester", "MAGE", "zone") and down == 1,
    "death proof was emitted twice")

-- First GP may arrive before GE. Preserve its clock against older GP/GE copies.
leader = false
expect(general:ApplyRemotePosition("Remote Tester", "Horde", "eu", 60, 70, 1, 10, 20),
    "GP-before-GE did not recover the remote holder")
expect(not general:ApplyRemotePosition("Remote Tester", "Horde", "eu", 10, 10, 1, 10, 19),
    "first GP lost its position timestamp")
expect(general:ApplyRemoteClaim("Remote Tester", "Horde", "eu", 1, 1, 1, 10, false),
    "same-claim GE resync failed")
local slot = general:GetSlot("Horde")
expect(slot.mapX == 60 and slot.mapY == 70 and slot.lastPosTs == 20,
    "delayed GE reverted coordinates or erased the latest GP timestamp")
expect(not general:ApplyRemoteClaim("Remote Tester", "Horde", "eu", 1, 1, 1, 9, false),
    "older claim replaced the same holder's newer claim")

expect(general:ApplyRemoteRelease("Remote Tester", "Horde", "eu", 10),
    "remote release failed")
expect(not general:CanAcceptClaim("Horde", "Remote Tester", 10, "eu"),
    "released claim was resurrected")
general:OnCampaignReset()
expect(general:CanAcceptClaim("Horde", "Remote Tester", 10, "eu"),
    "campaign reset retained an old linked tombstone")
-- 1.7.7: the general role is volunteer only. A group leader of the same faction who
-- never pressed the button does not take command when the general dies or steps down.
leader, grouped = true, true
serverNow = serverNow + 10
expect(general:ApplyRemoteClaim("Ally General", "Alliance", "eu", 1, 1, 1, serverNow, false),
    "fixture: the allied general claim was refused")
expect(general:ApplyRemoteDown("Ally General", "Alliance", "eu", serverNow, "Enemy Tester", "MAGE", "zone"),
    "fixture: the general death was refused")
drain()
expect(not general:IsLocalHolder(), "a group leader became general when the general died, without opting in")
serverNow = serverNow + 10
expect(general:ApplyRemoteClaim("Ally General", "Alliance", "eu", 1, 1, 1, serverNow, false),
    "fixture: the second allied general claim was refused")
expect(general:ApplyRemoteRelease("Ally General", "Alliance", "eu", serverNow), "fixture: the release was refused")
drain()
expect(not general:IsLocalHolder(), "a group leader became general when the general stepped down, without opting in")

-- 2.0.2: an ally taking command is a chat line only; an enemy taking command is still
-- announced in the middle of the screen, without the raid warning sound. 2.0.3: a
-- general's fall too (no general alert plays the raid warning sound any more).
do
    local said, warned = {}, {}
    Overlord.L.GENERAL_RECEIVED = "%s commands in %s"
    Overlord.L.GENERAL_ENEMY_ASSUMED = "%s is the enemy commander in %s"
    Overlord.L.GENERAL_FALLEN = "%s fell to %s"
    Overlord.PrintNotification = function(_, text) said[#said + 1] = text end
    Overlord.PrintRaidWarning = function(_, text, silent)
        warned[#warned + 1] = (silent and "silent " or "loud ") .. text
    end
    local function count(list, needle)
        local n = 0
        for _, text in ipairs(list) do if text:find(needle, 1, true) then n = n + 1 end end
        return n
    end
    serverNow = serverNow + 10
    expect(general:ApplyRemoteClaim("Other General", "Alliance", "eu", 1, 1, 1, serverNow, true),
        "fixture: the allied claim was refused")
    expect(count(said, "Other General commands in") == 1, "an ally taking command is not said in the chat")
    expect(#warned == 0, "an ally taking command was announced as a raid warning: " .. tostring(warned[1]))
    serverNow = serverNow + 10
    expect(general:ApplyRemoteClaim("Horde General", "Horde", "eu", 1, 1, 1, serverNow, true),
        "fixture: the enemy claim was refused")
    expect(count(said, "Horde General is the enemy commander in") == 1, "an enemy taking command is not said in the chat")
    expect(#warned == 1 and warned[1]:find("^silent ") and warned[1]:find("Horde General is the enemy commander", 1, true),
        "an enemy taking command must be announced on screen once, without the sound: " .. tostring(warned[1]))
    expect(general:ApplyRemoteDown("Other General", "Alliance", "eu", serverNow - 10, "Enemy Tester", "MAGE", "zone"),
        "fixture: the general death was refused")
    drain()
    expect(count(warned, "fell to") == 1 and warned[#warned]:find("^silent "),
        "a general's fall must be announced on screen once, without the raid sound: " .. tostring(warned[#warned]))
end

-- 2.3.0: a player already in sight who takes command gets his nameplate badge at once.
-- His plate came before his claim (no NAME_PLATE_UNIT_ADDED follows); the refresh used
-- to repaint only the plates that had carried a badge before.
do
    local plateNames = { nameplate3 = "Plate General", nameplate4 = "Plate Bystander" }
    local plates, created = {}, {}
    local function texture()
        local t = {}
        function t:SetAllPoints() end
        function t:SetTexture() end
        function t:SetTexCoord() end
        function t:SetAtlas(atlas) self.atlas = atlas end
        return t
    end
    function CreateFrame(_, _, parent)
        local f = { parent = parent, shown = true }
        function f:SetSize() end
        function f:SetPoint() end
        function f:ClearAllPoints() end
        function f:SetParent(p) self.parent = p end
        function f:GetParent() return self.parent end
        function f:CreateTexture() return texture() end
        function f:Show() self.shown = true end
        function f:Hide() self.shown = false end
        created[#created + 1] = f
        return f
    end
    for unit in pairs(plateNames) do plates[unit] = { UnitFrame = { unit = unit } } end
    C_NamePlate = { GetNamePlateForUnit = function(unit) return plates[unit] end }
    local oldUnitExists = UnitExists
    function UnitExists(unit) return plateNames[unit] ~= nil end
    function UnitIsPlayer(unit) return plateNames[unit] ~= nil end
    Overlord.SafeUnitName = function(_, unit) return plateNames[unit] end
    dofile("GeneralNameplate.lua")
    local nameplates = Overlord.GeneralNameplate
    nameplates:OnNamePlateAdded("nameplate3")
    nameplates:OnNamePlateAdded("nameplate4")
    expect(#created == 0, "fixture: a plate got a badge before anyone took command")
    serverNow = serverNow + 10
    expect(general:ApplyRemoteClaim("Plate General", "Alliance", "eu", 1, 1, 1, serverNow, false),
        "fixture: the allied claim was refused")
    drain()
    local badge
    for _, f in ipairs(created) do
        if f.parent == plates.nameplate3.UnitFrame then badge = f end
        expect(f.parent ~= plates.nameplate4.UnitFrame, "a bystander's plate got a badge frame")
    end
    expect(badge and badge.shown and badge.icon
        and badge.icon.atlas == general:GetFactionBadgeAtlas("Alliance"),
        "a general already in sight got no badge on his nameplate when he took command")
    UnitExists = oldUnitExists
end
print("general_team_lifecycle_runtime: OK")
