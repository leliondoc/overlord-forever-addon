-- OutpostControl.lua - Capture et maintien des avant-postes (cartes de front, 24/7)
Overlord = Overlord or {}
Overlord.OutpostControl = Overlord.OutpostControl or {}

local L = Overlord.L
local OP = Overlord.Outpost
local ZS_BROADCAST_INTERVAL = 5
local lastOPBroadcast = {}
local lastNoGuildWarnAt = 0
local lastHoldStartedNotifyAt = 0
local NO_GUILD_WARN_GAP = 45
local HOLD_STARTED_NOTIFY_GAP = 60
local WAR_MODE_WARN_GAP = 45
local lastWarModeWarnAt = 0
local OUTPOST_CHAT_GAP = 45
local lastOutpostLeftChatAt = {}
local lastOutpostBackChatAt = {}
local lastOutpostContestedChatAt = {}
local lastOutpostBlockedAssaultAt = {}
local OUTPOST_BLOCKED_ASSAULT_GAP = 45
local outpostDefenseAlerted = {}
local lastOutpostDefenseEnemyAt = {}
local OUTPOST_DEFENSE_REARM_SECONDS = 120
local OUTPOST_CONTESTED_CHAT_GAP = 60
local OUTPOST_SCAN_CACHE_SECONDS = 2.0
local lastMarkDirtyHoldSec = {}
local outpostScanCache = { siteKey = nil, time = 0, friendly = 0, enemy = 0 }
local outpostScanCountedFriendly = {}
local outpostScanCountedEnemy = {}
local outpostScanCountedGroupUnit = {}
local outpostScanAuraResultByGUID = {}
local outpostUnitTokens = { raid = {}, party = {}, nameplate = {} }
for i = 1, 40 do
    outpostUnitTokens.raid[i] = "raid" .. i
    outpostUnitTokens.nameplate[i] = "nameplate" .. i
    if i <= 4 then outpostUnitTokens.party[i] = "party" .. i end
end

local function IsWarModeActive()
    -- Forever : pas de Warmode. Le PvP monde ouvert est toujours le contexte de capture.
    return true
end

local function IsPlayerInNonCaptureState()
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync then
        return Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync()
    end
    if IsMounted and IsMounted() then return true end
    if IsFlying and IsFlying() then return true end
    if IsStealthed and IsStealthed() then return true end
    if UnitIsDead("player") or UnitIsGhost("player") then return true end
    return false
end

local function IsUnitInNonCaptureState(unit, auraResultByGUID, unitGUID)
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync then
        return Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync(unit, auraResultByGUID, unitGUID)
    end
    if not unit or not UnitExists(unit) then return true end
    if UnitIsDead(unit) or UnitIsGhost(unit) then return true end
    if UnitIsMounted then
        local ok, mounted = pcall(UnitIsMounted, unit)
        if ok and mounted ~= nil then
            if canaccessvalue then
                local okAcc, accessible = pcall(canaccessvalue, mounted)
                if okAcc and not accessible then return true end
            end
            local okBool, isTrue = pcall(function() return mounted == true end)
            if okBool and isTrue then return true end
        end
    end
    if UnitIsFlying then
        local ok, flying = pcall(UnitIsFlying, unit)
        if ok and flying ~= nil then
            if canaccessvalue then
                local okAcc, accessible = pcall(canaccessvalue, flying)
                if okAcc and not accessible then return true end
            end
            local okBool, isTrue = pcall(function() return flying == true end)
            if okBool and isTrue then return true end
        end
    end
    return false
end

local function IsUnitIneligibleToContest(unit, auraResultByGUID, unitGUID)
    if Overlord.ZoneControl and Overlord.ZoneControl.IsUnitIneligibleToContestForSync then
        return Overlord.ZoneControl:IsUnitIneligibleToContestForSync(unit, auraResultByGUID, unitGUID)
    end
    return IsUnitInNonCaptureState(unit, auraResultByGUID, unitGUID)
end

local function UnitCountsForOutpost(unit)
    if not unit or not UnitExists(unit) then return 0 end
    if IsUnitInNonCaptureState(unit) then return 0 end
    return 1
end

local function RefreshOutpostHud()
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.RefreshHud then
        Overlord.ZoneIndicator:RefreshHud()
    end
end

-- WoW 12.0.5 : cle de table (nom joueur) : pas d'index si secret value.
local function ReadAccessibleStringKey(value)
    if value == nil or value == "" then return nil end
    if type(value) ~= "string" then return nil end
    return value
end

local function AccessibleStringKey(value)
    if canaccessvalue then
        local okAcc, accessible = pcall(canaccessvalue, value)
        if not okAcc or not accessible then return nil end
        return ReadAccessibleStringKey(value)
    end
    local ok, result = pcall(ReadAccessibleStringKey, value)
    return ok and result or nil
end

local function GetOutpostUnitIdentity(unit)
    if UnitGUID then
        local ok, value = pcall(UnitGUID, unit)
        local guid = ok and AccessibleStringKey(value)
        if guid then return guid, guid end
    end
    local name = AccessibleStringKey(Overlord.SafeGetUnitName
        and Overlord:SafeGetUnitName(unit, true))
    if name then return name:lower(), nil end
end

-- Identite secrete sur une nameplate : utiliser l'alias exact deja compte dans
-- le groupe. Le raid reste O(1), le groupe de cinq demande au plus quatre tests.
local function NameplateWasCountedFromGroup(unit)
    if IsInRaid() and UnitInRaid then
        local ok, index = pcall(function()
            local value = UnitInRaid(unit)
            if canaccessvalue and not canaccessvalue(value) then return nil end
            return tonumber(value)
        end)
        local token = ok and index and outpostUnitTokens.raid[math.floor(index)]
        return token and outpostScanCountedGroupUnit[token] == true or false
    end
    if IsInGroup() then
        for i = 1, 4 do
            local token = outpostUnitTokens.party[i]
            if outpostScanCountedGroupUnit[token] then
                local ok, same = pcall(function()
                    local value = UnitIsUnit(unit, token)
                    if canaccessvalue and not canaccessvalue(value) then return false end
                    return value == true
                end)
                if ok and same then return true end
            end
        end
    end
    return false
end

local function MarkDirtyIfHoldSecChanged(siteKey, st)
    local holdSec = math.floor(tonumber(st and st.holdTimeElapsed) or 0)
    if lastMarkDirtyHoldSec[siteKey] == holdSec then return end
    lastMarkDirtyHoldSec[siteKey] = holdSec
    Overlord:MarkDirty()
end

local function BroadcastOP(siteKey, force, allowInstance)
    if Overlord.InstanceSuspended then return end
    if not allowInstance and IsInInstance and IsInInstance() then return end
    if not Overlord.Sync or not Overlord.Sync.BroadcastOutpostState then return end
    local now = GetTime()
    if not force and lastOPBroadcast[siteKey] and now - lastOPBroadcast[siteKey] < ZS_BROADCAST_INTERVAL then
        return
    end
    lastOPBroadcast[siteKey] = now
    Overlord.Sync:BroadcastOutpostState(siteKey, force, allowInstance)
end

local function CanStartOutpostCapture(site, notify)
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then
        return false
    end
    if not OP:IsGameplayContextActive(site) then return false end
    if not IsWarModeActive() then
        if notify then
            local now = GetTime()
            if (now - lastWarModeWarnAt) >= WAR_MODE_WARN_GAP and L.OUTPOST_WAR_MODE then
                lastWarModeWarnAt = now
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.OUTPOST_WAR_MODE)
            end
        end
        return false
    end
    local gateTarget = {
        id = site and (site.id or site.siteKey) or "outpost",
        name = site and OP:GetDisplayName(site) or "Outpost",
    }
    if Overlord.CanStartLocalCapture and not Overlord:CanStartLocalCapture(gateTarget, notify) then
        return false
    end
    return true
end

local function TryChatOutpostLeftZone(site)
    if not site or not L.LEFT_ZONE then return end
    local key = site.siteKey or site.id or "outpost"
    local now = GetTime()
    if (now - (lastOutpostLeftChatAt[key] or 0)) < OUTPOST_CHAT_GAP then return end
    lastOutpostLeftChatAt[key] = now
    Overlord:PrintNotification(string.format("|cFFFF0000[Overlord]|r " .. L.LEFT_ZONE, OP:GetDisplayName(site)))
end

local function TryChatOutpostBackInZone(site)
    if not site or not L.BACK_IN_ZONE then return end
    local key = site.siteKey or site.id or "outpost"
    local now = GetTime()
    if (now - (lastOutpostBackChatAt[key] or 0)) < OUTPOST_CHAT_GAP then return end
    lastOutpostBackChatAt[key] = now
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.BACK_IN_ZONE, OP:GetDisplayName(site)))
end

local function TryChatOutpostContested(site, enemyCount, friendlyCount)
    if not site then return end
    local key = site.siteKey or site.id or "outpost"
    local now = GetTime()
    if (now - (lastOutpostContestedChatAt[key] or 0)) < OUTPOST_CONTESTED_CHAT_GAP then return end
    lastOutpostContestedChatAt[key] = now
    local fmt
    if enemyCount > friendlyCount then
        fmt = L.OUTPOST_CONTESTED_OUTNUMBER or L.ZONE_CONTESTED_OUTNUMBER
    else
        fmt = L.OUTPOST_CONTESTED_EVEN or L.ZONE_CONTESTED_EVEN
    end
    if fmt then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. fmt,
            OP:GetDisplayName(site), enemyCount, friendlyCount))
    end
end

local function IsMapPointInOutpost(site, px, py)
    if not site or not px or not py then return false end
    local ar = (OP and OP.GetMapAspectRatio and OP:GetMapAspectRatio(site)) or 1
    for _, sq in ipairs(OP:GetOutpostSquares(site)) do
        local dx = math.abs(px - sq[1])
        local dy = math.abs((py - sq[2]) * ar)
        if dx <= sq[3] and dy <= sq[3] then
            return true
        end
    end
    return false
end

local function ReadUnitOutpostMapMembership(unit, site, mapID)
    if not unit or not site or not mapID then return false end
    local pos = C_Map.GetPlayerMapPosition(mapID, unit)
    if not pos then return nil end
    local ux, uy = pos:GetXY()
    if not ux or not uy or (ux == 0 and uy == 0) then return nil end
    return IsMapPointInOutpost(site, ux * 100, uy * 100)
end

local function GetUnitOutpostMapMembership(unit, site, mapID)
    local ok, inside = pcall(ReadUnitOutpostMapMembership, unit, site, mapID)
    if ok then return inside end
    return nil
end

local function IsUnitInOutpostByMapPosition(unit, site, mapID)
    return GetUnitOutpostMapMembership(unit, site, mapID) == true
end

-- Nameplates ennemis/hors-groupe : pas de position carte ; ancre sur le joueur dans le carre AP.
local function NameplateUnitContestsOutpost(unit, site, mapID, playerInOutpost)
    if not unit or not site or not mapID then return false end
    local inside = GetUnitOutpostMapMembership(unit, site, mapID)
    if inside ~= nil then return inside end
    return playerInOutpost and true or false
end

local function ScanNearbyOutpostPlayers(site, forceFresh)
    local siteKey = site and (site.siteKey or site.id)
    local now = GetTime()
    local playerCount = UnitCountsForOutpost("player")
    local shard = Overlord.Shard
    local contextKey = tostring(shard and shard.localContextKey or "")
    local contextAt = tonumber(shard and shard.localContextStartedAt) or 0
    if not forceFresh and outpostScanCache.siteKey == siteKey
        and outpostScanCache.contextKey == contextKey
        and outpostScanCache.contextAt == contextAt
        and outpostScanCache.player == playerCount
        and now - outpostScanCache.time < OUTPOST_SCAN_CACHE_SECONDS then
        return outpostScanCache.friendly, outpostScanCache.enemy
    end

    local friendlyCount = playerCount
    local enemyCount = 0
    local enemyFaction = Overlord.Zones and Overlord.Zones.GetEnemyFaction
        and Overlord.Zones:GetEnemyFaction() or nil
    if not enemyFaction and Overlord.PlayerFaction then
        enemyFaction = (Overlord.PlayerFaction == "Alliance") and "Horde" or "Alliance"
    end

    wipe(outpostScanCountedFriendly)
    wipe(outpostScanCountedEnemy)
    wipe(outpostScanCountedGroupUnit)
    wipe(outpostScanAuraResultByGUID)
    local playerIdentity = GetOutpostUnitIdentity("player")
    if playerIdentity then outpostScanCountedFriendly[playerIdentity] = true end

    local mapID = (Overlord.Outpost and Overlord.Outpost.GetGeometryMapID
        and Overlord.Outpost:GetGeometryMapID(site)) or site and site.mapID
    if not mapID and C_Map and C_Map.GetBestMapForUnit then
        local ok, mid = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then mapID = mid end
    end
    if mapID then
        local prefix, count
        if IsInRaid() then
            prefix, count = "raid", 40
        elseif IsInGroup() then
            prefix, count = "party", 4
        end
        if prefix then
            for i = 1, count do
                local unit = outpostUnitTokens[prefix][i]
                if UnitExists(unit) and not UnitIsUnit(unit, "player")
                    and (not UnitIsConnected or UnitIsConnected(unit))
                    and (not UnitInPhase or UnitInPhase(unit) == true)
                    and IsUnitInOutpostByMapPosition(unit, site, mapID) then
                    local faction = UnitFactionGroup(unit)
                    local identity, guid = GetOutpostUnitIdentity(unit)
                    if faction == Overlord.PlayerFaction then
                        if (not identity or not outpostScanCountedFriendly[identity])
                            and not IsUnitInNonCaptureState(unit, outpostScanAuraResultByGUID, guid) then
                            friendlyCount = friendlyCount + 1
                            outpostScanCountedGroupUnit[unit] = true
                            if identity then outpostScanCountedFriendly[identity] = true end
                        end
                    elseif faction == enemyFaction then
                        if (not identity or not outpostScanCountedEnemy[identity])
                            and not IsUnitIneligibleToContest(unit, outpostScanAuraResultByGUID, guid) then
                            enemyCount = enemyCount + 1
                            outpostScanCountedGroupUnit[unit] = true
                            if identity then outpostScanCountedEnemy[identity] = true end
                        end
                    end
                end
            end
        end
    end

    local playerInOutpost = mapID and OP:IsPlayerInOutpostGeometry(site) or false
    for i = 1, 40 do
        local unit = outpostUnitTokens.nameplate[i]
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsDead(unit) and not UnitIsGhost(unit)
            and mapID and NameplateUnitContestsOutpost(unit, site, mapID, playerInOutpost) then
            local faction = UnitFactionGroup(unit)
            local identity, guid = GetOutpostUnitIdentity(unit)
            local duplicateGroupAlias = not guid and NameplateWasCountedFromGroup(unit)
            if not duplicateGroupAlias and faction == enemyFaction then
                if (not identity or not outpostScanCountedEnemy[identity])
                    and not IsUnitIneligibleToContest(unit, outpostScanAuraResultByGUID, guid) then
                    enemyCount = enemyCount + 1
                    if identity then outpostScanCountedEnemy[identity] = true end
                end
            elseif not duplicateGroupAlias and faction == Overlord.PlayerFaction
                and not UnitIsUnit(unit, "player") then
                if (not identity or not outpostScanCountedFriendly[identity])
                    and not IsUnitInNonCaptureState(unit, outpostScanAuraResultByGUID, guid) then
                    if identity then outpostScanCountedFriendly[identity] = true end
                    friendlyCount = friendlyCount + 1
                end
            end
        end
    end

    outpostScanCache.siteKey = siteKey
    outpostScanCache.time = now
    outpostScanCache.contextKey = contextKey
    outpostScanCache.contextAt = contextAt
    outpostScanCache.player = playerCount
    outpostScanCache.friendly = friendlyCount
    outpostScanCache.enemy = enemyCount
    return friendlyCount, enemyCount
end

function Overlord.OutpostControl:GetNearbyOutpostPlayerCounts(site)
    return ScanNearbyOutpostPlayers(site)
end

local function CheckLocalOutpostDefense(siteKey, st, site)
    if not st or st.status ~= "held" or not OP:PlayerGuildOwnsOutpost(st) then return end
    if not IsWarModeActive() then return end
    local _, enemyCount = ScanNearbyOutpostPlayers(site)
    local now = GetTime()
    if (enemyCount or 0) > 0 then
        lastOutpostDefenseEnemyAt[siteKey] = now
        if not outpostDefenseAlerted[siteKey] then
            outpostDefenseAlerted[siteKey] = true
            local facLabel = (Overlord.Zones and Overlord.Zones.GetEnemyFactionName)
                and Overlord.Zones:GetEnemyFactionName()
                or ((Overlord.PlayerFaction == "Alliance") and "Horde" or "Alliance")
            if L.OUTPOST_UNDER_ATTACK then
                Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_UNDER_ATTACK,
                    OP:GetDisplayName(site), facLabel))
            end
            if OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled then
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
            end
            RefreshOutpostHud()
        end
        if Overlord.Sync and Overlord.Sync.PollIfStaleObserverOutpost then
            Overlord.Sync:PollIfStaleObserverOutpost(time() - (tonumber(st.updatedAt) or 0))
        end
    elseif outpostDefenseAlerted[siteKey]
        and now - (lastOutpostDefenseEnemyAt[siteKey] or 0) > OUTPOST_DEFENSE_REARM_SECONDS then
        outpostDefenseAlerted[siteKey] = nil
        RefreshOutpostHud()
    end
end

local function TryResumeLocalOutpostCapture(st, site)
    if not st or not site or st.status ~= "in_progress" or st.isHolding then return end
    if not CanStartOutpostCapture(site, false) then return end
    if not OP:IsPlayerInOutpostGeometry(site) or IsPlayerInNonCaptureState() then return end
    local guild = OP:GetLocalPlayerGuild()
    if guild == "" or not Overlord.PlayerFaction then return end
    if st.ownerGuild ~= guild or st.ownerFaction ~= Overlord.PlayerFaction then return end
    st.isHolding = true
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = true
    st.holdStartTime = GetTime() - (tonumber(st.holdTimeElapsed) or 0)
end

function Overlord.OutpostControl:StartHold(siteKey, st, site)
    if not st or not site then return end
    if not CanStartOutpostCapture(site, true) then return end
    local guild = OP:GetLocalPlayerGuild()
    if guild == "" then
        if L.OUTPOST_NO_GUILD then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.OUTPOST_NO_GUILD)
        end
        return
    end
    if st.status == "held" then
        st.previousOwnerGuild = OP:SanitizeGuildName(st.ownerGuild or "")
        st.previousOwnerFaction = st.ownerFaction
        st.previousClaimedAt = math.floor(tonumber(st.claimedAt) or 0)
        st.previousExpiresAt = math.floor(tonumber(st.expiresAt) or 0)
        st.previousOwnerPool = st.pool or ""
        st.claimedAt = 0
        st.expiresAt = 0
    end
    local resumeCapture = st.status == "in_progress"
        and OP:SanitizeGuildName(st.ownerGuild or "") == guild
        and st.ownerFaction == Overlord.PlayerFaction
        and (st.holdTimeElapsed or 0) > 0
    st.status = "in_progress"
    st.isHolding = true
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = true
    if resumeCapture then
        st.holdStartTime = GetTime() - (tonumber(st.holdTimeElapsed) or 0)
    else
        st.holdTimeElapsed = 0
        st.holdStartTime = GetTime()
        st.holdTimeRequired = OP:GetBaseHoldTimeRequired(site)
    end
    st.ownerGuild = guild
    st.ownerFaction = Overlord.PlayerFaction
    st.pool = (Overlord.GetCurrentSavedVarsPool and Overlord:GetCurrentSavedVarsPool()) or ""
    if st.pool == "" then
        self:RevertCapture(siteKey, st)
        return
    end
    if not resumeCapture and Overlord.Ressources
        and Overlord.Ressources.ConsumeCaptureReduction then
        st.holdTimeRequired = Overlord.Ressources:ConsumeCaptureReduction(
            st.holdTimeRequired, OP:GetMinimumHoldTimeRequired(site))
    end
    if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
        st.opOfficialCapturerName = Overlord.Sync:GetPlayerFullName()
    end
    st.updatedAt = time()
    OP:SaveOutposts()
    Overlord:MarkDirty()
    if Overlord.FrontActivity and Overlord.FrontActivity.RecordLocalByZoneRef then
        Overlord.FrontActivity:RecordLocalByZoneRef(siteKey, st.opOfficialCapturerName)
    end
    BroadcastOP(siteKey, true)
    if Overlord.ZoneIndicator then
        Overlord.ZoneIndicator:InvalidateActiveZoneCache()
        Overlord.ZoneIndicator:Show()
    end
    local now = GetTime()
    if L.OUTPOST_HOLD_STARTED and (now - lastHoldStartedNotifyAt) >= HOLD_STARTED_NOTIFY_GAP then
        lastHoldStartedNotifyAt = now
        Overlord:PrintNotification(string.format("|cFFFFFF00[Overlord]|r " .. L.OUTPOST_HOLD_STARTED,
            OP:GetDisplayName(site), math.floor(OP:GetDefaultHoldTimeRequired(st, site) / 60)))
    end
    OP:RefreshOutpostPresentation(siteKey)
end

function Overlord.OutpostControl:OnInstanceSuspend()
    if not OP then return end
    for key in pairs(Overlord.OutpostSites or {}) do
        local st = OP:GetState(key)
        if st and st.holdAuthorityLocal then
            self:RevertCapture(key, st, true)
        end
    end
end

function Overlord.OutpostControl:RevertCapture(siteKey, st, allowInstanceBroadcast)
    if not st then return end
    st.isContested = false
    if OP.ClearOpCapturerFields then
        OP:ClearOpCapturerFields(st)
    end
    local site = OP:GetSite(siteKey)
    local view = OP:CaptureStateToZoneView(st, site)
    if view and Overlord.Zones and Overlord.Zones.RevertInterruptedCapture then
        view.status = "in_progress"
        view.holdTimeElapsed = st.holdTimeElapsed or 0
        Overlord.Zones:RevertInterruptedCapture(view, false)
        OP:ApplyOutpostRestoreZoneView(st, view, site)
    else
        st.isHolding = false
        st.isPaused = false
        st.isContested = false
        st.holdAuthorityLocal = false
        st.holdStartTime = nil
        st.holdTimeElapsed = 0
        st.status = "neutral"
        st.ownerGuild = ""
        st.ownerFaction = nil
        st.previousOwnerGuild = ""
        st.previousOwnerFaction = nil
        st.previousOwnerPool = ""
        st.updatedAt = time()
    end
    OP:SaveOutposts()
    if Overlord.SaveState then Overlord:SaveState() end
    BroadcastOP(siteKey, true, allowInstanceBroadcast)
    OP:RefreshOutpostPresentation(siteKey)
    RefreshOutpostHud()
end

function Overlord.OutpostControl:CompleteCapture(siteKey, st, site)
    local capturer = st.opOfficialCapturerName
    if (not capturer or capturer == "") and Overlord.Sync
        and Overlord.Sync.GetPlayerFullName then
        capturer = Overlord.Sync:GetPlayerFullName()
    end
    local guild = OP:SanitizeGuildName(st.ownerGuild or "")
    if guild == "" then
        guild = OP:GetLocalPlayerGuild()
    end
    local fac = st.ownerFaction or Overlord.PlayerFaction
    if not OP:IsCaptureTakeoverAllowed(st, guild, fac, time()) then return end
    if not OP:CompleteCapture(siteKey, guild, fac) then return end
    if capturer and capturer ~= "" and site and site.id and Overlord.Leaderboard
        and Overlord.Leaderboard.CreditPlayerObjectiveCapture then
        local _, classToken = UnitClass("player")
        Overlord.Leaderboard:CreditPlayerObjectiveCapture(
            capturer, site.id, fac, st.claimedAt, false, classToken)
    end
    BroadcastOP(siteKey, true)
    if Overlord.Sync and Overlord.Sync.BroadcastOutpostCapture then
        Overlord.Sync:BroadcastOutpostCapture(siteKey, guild, fac, st.claimedAt)
    end
    if Overlord.ZoneIndicator then
        Overlord.ZoneIndicator:InvalidateActiveZoneCache()
    end
end

local function ShouldTickOutpostHoldTimer(st)
    if not st then return false end
    if not st.holdAuthorityLocal then return false end
    return st.isHolding or st.isPaused
end

function Overlord.OutpostControl:UpdateHoldTimer(siteKey, st, site, deltaTime, inGeomOverride)
    if not ShouldTickOutpostHoldTimer(st) then return end
    local inGeom = inGeomOverride
    if inGeom == nil then
        inGeom = OP:IsPlayerInOutpostGeometry(site)
    end
    local canProgress = st.holdAuthorityLocal and st.isHolding and not st.isPaused
    local canDecay = st.holdAuthorityLocal
    if st.holdAuthorityLocal and not IsWarModeActive() then
        self:RevertCapture(siteKey, st)
        return
    end
    if inGeom and IsPlayerInNonCaptureState() then
        inGeom = false
    end
    if inGeom and (UnitIsDead("player") or UnitIsGhost("player")) then
        inGeom = false
    end

    local req = OP:GetDefaultHoldTimeRequired(st, site)

    if inGeom then
        -- Une presence ennemie apparue dans les deux dernieres secondes doit
        -- etre prise en compte avant le terminal, meme avec un cache encore frais.
        local forceFresh = canProgress and (tonumber(st.holdTimeElapsed) or 0) + deltaTime >= req
        local friendlyCount, enemyCount = ScanNearbyOutpostPlayers(site, forceFresh)
        local contested = enemyCount > 0 and enemyCount >= friendlyCount
        if contested then
            if not st.isContested then
                st.isContested = true
                st.isPaused = false
                TryChatOutpostContested(site, enemyCount, friendlyCount)
            end
            st.updatedAt = time()
            MarkDirtyIfHoldSecChanged(siteKey, st)
            if enemyCount > friendlyCount then
                local contestPull = 1
                if friendlyCount > 0 then
                    contestPull = math.max(1, enemyCount / friendlyCount)
                end
                st.holdTimeElapsed = math.max(0, (st.holdTimeElapsed or 0) - deltaTime * contestPull)
                if st.holdTimeElapsed <= 0 then
                    st.holdTimeElapsed = 0
                    st.isHolding = false
                    st.isPaused = false
                    st.isContested = false
                    st.holdStartTime = nil
                    self:RevertCapture(siteKey, st)
                    if L.OUTPOST_CAPTURE_LOST then
                        Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. L.OUTPOST_CAPTURE_LOST)
                    end
                else
                    BroadcastOP(siteKey, false)
                    OP:RefreshOutpostPresentation(siteKey)
                end
            else
                BroadcastOP(siteKey, false)
                OP:RefreshOutpostPresentation(siteKey)
            end
            return
        elseif st.isContested then
            st.isContested = false
            TryChatOutpostBackInZone(site)
        end
        if st.isPaused then
            st.isPaused = false
            TryChatOutpostBackInZone(site)
        end
        if canProgress then
            st.holdTimeElapsed = (st.holdTimeElapsed or 0) + deltaTime
            st.updatedAt = time()
            MarkDirtyIfHoldSecChanged(siteKey, st)
            BroadcastOP(siteKey, false)
            if st.holdTimeElapsed >= req then
                local beforeStatus = st.status
                self:CompleteCapture(siteKey, st, site)
                if beforeStatus == "in_progress" and st.status ~= "held" then
                    self:RevertCapture(siteKey, st)
                end
            end
        end
    elseif canDecay then
        if st.holdAuthorityLocal and not st.isPaused then
            st.isPaused = true
            TryChatOutpostLeftZone(site)
        end
        st.isContested = false
        st.holdTimeElapsed = (st.holdTimeElapsed or 0) - deltaTime
        st.updatedAt = time()
        MarkDirtyIfHoldSecChanged(siteKey, st)
        if st.holdTimeElapsed <= 0 then
            st.holdTimeElapsed = 0
            st.isPaused = false
            st.isHolding = false
            st.holdStartTime = nil
            self:RevertCapture(siteKey, st)
            if L.OUTPOST_CAPTURE_LOST then
                Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. L.OUTPOST_CAPTURE_LOST)
            end
        else
            BroadcastOP(siteKey, false)
            OP:RefreshOutpostPresentation(siteKey)
        end
    end
end

function Overlord.OutpostControl:CheckPosition(deltaTime)
    deltaTime = deltaTime or 1
    local onMap, site = OP:IsPlayerOnOutpostMap()
    if not onMap or not site then return end
    local siteKey = site.siteKey
    local st = OP:GetState(siteKey)

    TryResumeLocalOutpostCapture(st, site)

    local inGeom = OP:IsPlayerInOutpostGeometry(site)
    if not inGeom then
        if st.holdAuthorityLocal and st.isHolding and not st.isPaused then
            st.isPaused = true
            st.isContested = false
        end
        if ShouldTickOutpostHoldTimer(st) then
            self:UpdateHoldTimer(siteKey, st, site, deltaTime, false)
        end
        return
    end

    if IsPlayerInNonCaptureState() then
        if ShouldTickOutpostHoldTimer(st) then
            self:UpdateHoldTimer(siteKey, st, site, deltaTime, true)
        end
        return
    end

    if Overlord.Shard and Overlord.Shard.TryAutoPromptOnOutpostEntry then
        Overlord.Shard:TryAutoPromptOnOutpostEntry(siteKey, site, st)
    end

    local guild = OP:GetLocalPlayerGuild()
    if guild == "" then
        local now = GetTime()
        if now - lastNoGuildWarnAt >= NO_GUILD_WARN_GAP then
            lastNoGuildWarnAt = now
            if L.OUTPOST_NO_GUILD then
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.OUTPOST_NO_GUILD)
            end
        end
        return
    end

    CheckLocalOutpostDefense(siteKey, st, site)

    if OP:CanPlayerStartCapture(st) then
        if not st.isHolding then
            self:StartHold(siteKey, st, site)
        end
    elseif st.status == "in_progress" and not OP:IsPlayerOutpostAssailant(st) then
        local now = GetTime()
        if (now - (lastOutpostBlockedAssaultAt[siteKey] or 0)) >= OUTPOST_BLOCKED_ASSAULT_GAP
            and L and L.OUTPOST_BLOCKED_ASSAULT then
            lastOutpostBlockedAssaultAt[siteKey] = now
            local assaultGuild = OP:SanitizeGuildName(st.ownerGuild or "")
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.OUTPOST_BLOCKED_ASSAULT,
                OP:GetDisplayName(site), assaultGuild))
        end
    end
end

-- Chemin de sommeil du tick global : lecture brute et bornee de la DB, sans
-- EnsureDB/GetState qui rescanneraient tout le registre pour chaque site.
function Overlord.OutpostControl:HasLocalAuthority(excludeKey)
    local states = OverlordDB and OverlordDB.outposts
    if type(states) ~= "table" then return false end
    for siteKey in pairs(Overlord.OutpostSites or {}) do
        local st = states[siteKey]
        if siteKey ~= excludeKey and type(st) == "table"
            and st.status == "in_progress" and st.holdAuthorityLocal
            and (st.isHolding or st.isPaused) then
            return true
        end
    end
    return false
end

function Overlord.OutpostControl:TickOffMapAuthority(deltaTime, excludeKey)
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
    for siteKey, site in pairs(Overlord.OutpostSites or {}) do
        if siteKey ~= excludeKey then
            local st = OP:GetState(siteKey)
            if st and st.status == "in_progress" and ShouldTickOutpostHoldTimer(st) then
                -- Decay seulement si vraiment hors carre (micro-carte / continent).
                local inGeom = OP:IsPlayerInOutpostGeometry(site)
                self:UpdateHoldTimer(siteKey, st, site, deltaTime or 1, inGeom)
            end
        end
    end
end

function Overlord.OutpostControl:Update(deltaTime)
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end

    local onMap, site = OP:IsPlayerOnOutpostMap()
    if not onMap or not site then return end

    local siteKey = site.siteKey
    local st = OP:GetState(siteKey)

    self:CheckPosition(deltaTime)
    local inGeom = OP:IsPlayerInOutpostGeometry(site)
    local canAct = inGeom
        and not IsPlayerInNonCaptureState()
        and not UnitIsDead("player")
        and not UnitIsGhost("player")
    if canAct and ShouldTickOutpostHoldTimer(st) then
        self:UpdateHoldTimer(siteKey, st, site, deltaTime or 1, true)
    end
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.SyncOutpostCaptureHud
        and Overlord.ZoneIndicator.OutpostHudNeedsRefresh
        and Overlord.ZoneIndicator:OutpostHudNeedsRefresh() then
        Overlord.ZoneIndicator:SyncOutpostCaptureHud()
    end
end
