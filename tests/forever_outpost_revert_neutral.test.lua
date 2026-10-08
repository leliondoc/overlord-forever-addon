-- An interrupted capture that reverts to neutral (no previous owner) must reach peers
-- that saw the assault start. It used to reuse the assault-start timestamp, so the
-- neutral OP tied with the in_progress OP and the tie-break kept peers stuck.
local now = 1790018000
local mapID, guild, faction = 1418, "Fortress Guild", "Alliance"
function time() return now end
function GetServerTime() return now end
function GetTime() return now - 1790016000 end
function GetGuildInfo() return guild end
function IsInInstance() return false end
function IsInGroup() return false end
function IsInRaid() return false end
function UnitIsDead() return false end
function UnitIsGhost() return false end
function UnitExists(unit) return unit == "player" end
function UnitGUID(unit) return unit == "player" and "Player-1-TEST" end
function UnitFactionGroup() return faction end
function UnitIsPlayer() return true end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function IsWarModeActive() return true end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return unpack(fields)
end
C_Map = {
    GetBestMapForUnit = function() return mapID end,
    GetMapInfo = function() return { parentMapID = 0, name = "Badlands" } end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.430, 0.308 end }
    end,
}
Overlord = Overlord or {}
Overlord.L = setmetatable({}, { __index = function(_, k) return k end })
Overlord.ZoneControl = nil
assert(loadfile("Zones.lua"))()
Overlord.Fronts = Overlord.Fronts or {}
Overlord.Fronts.ResolveFrontByOverlayMapID = function() return nil end
Overlord.Fronts.ResolveFrontByMapID = function() return nil end
Overlord.Fronts.Activate = function() end
Overlord.Fronts.GetZone = function() return nil end
Overlord.InActiveFront, Overlord.WaitingForSync, Overlord.InstanceSuspended = false, false, false
Overlord.IsInCatchUpPhase = function() return false end
Overlord.CanStartLocalCapture = function() return true end
Overlord.IsCaptureSyncGateActive = function() return false end
Overlord.IsCaptureSyncPending = function() return false end
Overlord.SaveState = function() end
Overlord.PlayerFaction = faction
Overlord.MarkDirty = function() end
Overlord.PrintNotification = function() end
Overlord.GetCurrentSavedVarsPool = function() return "global" end
OverlordDB = { lastResetTimestamp = 1789527600, config = {},
    outposts = {},
}
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Outpost.lua"))()
assert(loadfile("OutpostControl.lua"))()

local OP, OC = Overlord.Outpost, Overlord.OutpostControl
OP:EnsureDB()

local siteKey = "badlands" -- fortress, never held before (no previous owner)
local site = OP:GetSite(siteKey)
local st = OP:GetState(siteKey)

local sentPayloads = {}
local function snapshotRemote(st2)
    return {
        status = st2.status,
        holdTimeElapsed = st2.holdTimeElapsed or 0,
        ownerGuild = st2.ownerGuild or "",
        ownerFaction = st2.ownerFaction,
        claimedAt = st2.claimedAt or 0,
        expiresAt = st2.expiresAt or 0,
        updatedAt = st2.updatedAt or 0,
        holdTimeRequired = st2.holdTimeRequired,
        isContested = st2.isContested or false,
        previousOwnerGuild = st2.previousOwnerGuild or "",
        previousOwnerFaction = st2.previousOwnerFaction,
        previousClaimedAt = st2.previousClaimedAt or 0,
        previousExpiresAt = st2.previousExpiresAt or 0,
        pool = st2.pool or "global",
    }
end
Overlord.Sync = {
    BroadcastOutpostState = function(self2, key, force, allowInstance)
        local st2 = OP:GetState(key)
        table.insert(sentPayloads, snapshotRemote(st2))
    end,
    GetPlayerFullName = function() return "Tester-Realm" end,
}


-- 1) Local player starts an assault on a never-held fortress.
OC:StartHold(siteKey, st, site)

local startTs = st.updatedAt
now = now + 45 -- assault runs for 45s then gets interrupted (e.g. player leaves zone)

-- 2) Assault interrupted, no previous owner -> should revert fully to neutral.
OC:RevertCapture(siteKey, st, false)


assert(sentPayloads[1].status == "in_progress", "expected first broadcast in_progress")
assert(sentPayloads[2].status == "neutral", "expected second broadcast neutral")

assert(sentPayloads[2].updatedAt > sentPayloads[1].updatedAt,
    "Neutral revert reused the assault-start timestamp: " .. tostring(sentPayloads[2].updatedAt))

-- Part 2: simulate a peer (e.g. cross-faction relay observer) who received the
-- in_progress broadcast, then receives the neutral revert broadcast afterward.
OverlordDB.outposts[siteKey] = nil -- fresh peer, never touched this site
assert(OP:GetState(siteKey).status == "neutral", "Fresh peer fixture is not neutral")
Overlord.Outpost:ApplyRemoteState(siteKey, sentPayloads[1], true)
assert(OP:GetState(siteKey).status == "in_progress", "Peer did not take the assault start")
Overlord.Outpost:ApplyRemoteState(siteKey, sentPayloads[2], true)
local peerFinal = OP:GetState(siteKey)
assert(peerFinal.status == "neutral" and (peerFinal.ownerGuild or "") == "",
    "Peer stayed on the aborted assault: " .. tostring(peerFinal.status))
print("Outpost revert to neutral: dated and applied by peers that saw the assault")

-- An observer logs out during the assault, then returns after the real capture
-- completed. Offline decay is only a local guess, never a fresh neutral event.
local observed = snapshotRemote(sentPayloads[1])
observed.holdTimeElapsed = 30
OverlordDB.outposts[siteKey] = observed
OverlordDB.lastSessionTimestamp = startTs + 30
now = startTs + 1000
OP:RestoreOutposts()
local restored = snapshotRemote(OP:GetState(siteKey))
assert(restored.status == "neutral", "Offline assault did not decay in the fixture")
assert(restored.updatedAt == startTs,
    "Offline decay invented a neutral event at login")

-- Replay the restored snapshot to a client that saw the actual completion.
OverlordDB.outposts[siteKey] = nil
assert(OP:CompleteCapture(siteKey, guild, faction, startTs + 600, "global", true, "Tester Capper"))
OP:ApplyRemoteState(siteKey, restored, true)
assert(OP:GetState(siteKey).status == "held" and OP:GetState(siteKey).ownerGuild == guild,
    "Returning observer erased a capture completed while offline")
print("Outpost offline restore: stale neutral preserves the real completed capture")
