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
print("general_team_lifecycle_runtime: OK")
