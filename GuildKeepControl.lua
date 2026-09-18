-- GuildKeepControl.lua - Capture et maintien du Guild Keep (Wetlands)
Overlord = Overlord or {}
Overlord.GuildKeepControl = Overlord.GuildKeepControl or {}

local L = Overlord.L
local GK = Overlord.GuildKeep
local function NetworkNow()
    return GK and GK.GetNetworkTimestamp and GK:GetNetworkTimestamp() or time()
end
local function LocalFullName()
    return Overlord.Sync and Overlord.Sync.GetPlayerFullName
        and Overlord.Sync:GetPlayerFullName() or ""
end
local ZS_BROADCAST_INTERVAL = 5
local lastGKBroadcast = {}
local lastNoGuildWarnAt = 0
local lastHoldStartedNotifyAt = 0
local NO_GUILD_WARN_GAP = 45
local HOLD_STARTED_NOTIFY_GAP = 60
local WAR_MODE_WARN_GAP = 45
local lastWarModeWarnAt = 0
-- Alerte hors horaire : une seule fois par presence continue dans le carre.
-- Un cooldown temporel la faisait repartir indefiniment sur le ticker de position.
local siegeClosedWarnedPointSiteKey = nil
local factionHeldWarnedPointSiteKey = nil
local KEEP_CHAT_GAP = 45
local lastKeepLeftChatAt = {}
local lastKeepBackChatAt = {}
local lastKeepContestedChatAt = {}
-- Guilde deja notifiee pour l'assaut BLOQUANT en cours sur ce site (une seule fois par assaut,
-- pas de rappel periodique : un siege ennemi peut durer de longues minutes et repeter le meme
-- message toutes les 45s devenait un spam ininterrompu pour un joueur reste sur place).
local blockedAssaultNotifiedGuild = {}
local blockedAssaultInactiveSince = {}
local BLOCKED_ASSAULT_REARM_QUIET_SEC = 90
-- Duree CONTINUE (s) sans aucune preuve d'assaut vivant (ni ennemi present, ni GK in_progress
-- ennemi recu) au-dela de laquelle un joueur present considere l'assaut comme abandonne
-- (assaillant parti / hors ligne / autre shard). On NE s'appuie PAS sur st.updatedAt : quand un
-- defenseur est present, ShouldApplyRemoteKeepHold bloque la fusion du timer distant, donc
-- updatedAt cesse d'avancer meme si des GK ennemis arrivent encore -> on mesure plutot la reception
-- effective de GK ennemis (st._lastEnemyInProgressGkAt) et la presence locale.
local KEEP_ABANDONED_ASSAULT_SEC = 90
-- Debut de la fenetre continue "aucune preuve d'assaut vivant" par site (transitoire, par client).
local keepAbandonCandidateAt = {}
-- Defense locale : ennemis vus dans le carre de notre fortin tenu (re-arme apres accalmie)
local keepDefenseAlerted = {}
local lastKeepDefenseEnemyAt = {}
local KEEP_DEFENSE_REARM_SECONDS = 120
local lastGkHudRefreshAt = 0
local GK_HUD_REFRESH_INTERVAL = 1
local KEEP_CONTESTED_CHAT_GAP = 60
local KEEP_SCAN_CACHE_SECONDS = 2.0
local lastMarkDirtyHoldSec = {}
local lastResolveAuthorityKey = {}
local lastShardUnknownWarnAt = {}
local lastWrongShardWarnAt = {}
local SHARD_UNKNOWN_WARN_GAP = 20
local WRONG_SHARD_WARN_GAP = 20
local keepScanCache = {
    siteKey = nil, time = 0, contextKey = "", contextAt = -1,
    player = 0, friendly = 0, enemy = 0,
}
local capturerEligibilityCache = { stamp = -1, siteKey = nil, rows = {} }
local keepScanCountedFriendly = {}
local keepScanCountedEnemy = {}
local keepScanCountedFriendlyGroupUnit = {}
local keepScanAuraResultByGUID = {}
local keepUnitTokens = { raid = {}, party = {}, nameplate = {} }
for i = 1, 40 do
    keepUnitTokens.raid[i] = "raid" .. i
    keepUnitTokens.nameplate[i] = "nameplate" .. i
    if i <= 4 then keepUnitTokens.party[i] = "party" .. i end
end

local function IsWarModeActive()
    -- Forever : pas de Warmode. Le PvP monde ouvert est toujours le contexte de capture.
    return true
end

-- Memes regles que les zones de front (monture, vol, dragonriding, Travel Form, furtif)
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
        return Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync(
            unit, auraResultByGUID, unitGUID)
    end
    if not unit or not UnitExists(unit) then return true end
    if UnitIsDead(unit) or UnitIsGhost(unit) then return true end
    -- Sans ZoneControl, aucun API Retail documente ne prouve la monture/vol d'une unite
    -- distante. Un etat inconnu reste eligible pour ne pas casser le comptage ni l'election.
    return false
end

local function IsUnitIneligibleToContest(unit, auraResultByGUID, unitGUID)
    if Overlord.ZoneControl and Overlord.ZoneControl.IsUnitIneligibleToContestForSync then
        return Overlord.ZoneControl:IsUnitIneligibleToContestForSync(
            unit, auraResultByGUID, unitGUID)
    end
    if not unit or not UnitExists(unit) then return true end
    if UnitIsDead(unit) or UnitIsGhost(unit) then return true end
    -- Fallback sans ZoneControl : un etat distant inconnu reste contestataire.
    return false
end

local function UnitCountsForKeep(unit)
    if not unit or not UnitExists(unit) then return 0 end
    if IsUnitInNonCaptureState(unit) then return 0 end
    return 1
end

local function RefreshKeepHud()
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.RefreshHud then
        Overlord.ZoneIndicator:RefreshHud()
    end
end

-- WoW 12.0.5 : cle de table (nom joueur) : pas d'index si secret value.
local function ReadAccessibleStringKey(value)
    if value == nil or value == "" then return nil end
    return value
end

local function AccessibleStringKey(value)
    if canaccessvalue then
        local okAcc, accessible = pcall(canaccessvalue, value)
        if not okAcc or not accessible then return nil end
        return ReadAccessibleStringKey(value)
    end
    local ok, key = pcall(ReadAccessibleStringKey, value)
    if not ok then return nil end
    return key
end

local function ResolveKeepAssaultAuthority(siteKey, st)
    if not GK or not GK.ResolveCanonicalAssaultGuild or not st then return end
    local canon = GK.SanitizeGuildName and GK:SanitizeGuildName(st.canonicalAssaultGuild or "")
        or (st.canonicalAssaultGuild or "")
    if canon ~= "" then
        local defer = GK.ShouldDeferToRemoteKeepCapturer
            and GK:ShouldDeferToRemoteKeepCapturer(st)
        if not defer then
            local owner = GK.SanitizeGuildName and GK:SanitizeGuildName(st.ownerGuild or "")
                or (st.ownerGuild or "")
            if owner == canon then return end
        end
    end
    local resolveKey = string.format("%s|%s|%s|%s|%s|%s|%s",
        siteKey or "",
        st.ownerGuild or "",
        st.gkOfficialCapturerName or "",
        st.gkRelayCapturerName or "",
        st.canonicalAssaultGuild or "",
        math.floor(tonumber(st.canonicalAssaultStartedAt) or 0),
        math.floor(tonumber(st.assaultGenerationAt) or 0))
    if lastResolveAuthorityKey[siteKey] == resolveKey and canon ~= "" then return end
    lastResolveAuthorityKey[siteKey] = resolveKey
    GK:ResolveCanonicalAssaultGuild(st)
end

local function MarkDirtyIfHoldSecChanged(siteKey, st)
    local holdSec = math.floor(tonumber(st and st.holdTimeElapsed) or 0)
    if lastMarkDirtyHoldSec[siteKey] == holdSec then return end
    lastMarkDirtyHoldSec[siteKey] = holdSec
    Overlord:MarkDirty()
end

local function BroadcastGK(siteKey, force, allowInstance)
    if Overlord.InstanceSuspended then return end
    if not allowInstance and IsInInstance and IsInInstance() then return end
    if not Overlord.Sync or not Overlord.Sync.BroadcastGuildKeepState then return end
    local now = GetTime()
    if not force and lastGKBroadcast[siteKey] and now - lastGKBroadcast[siteKey] < ZS_BROADCAST_INTERVAL then
        return
    end
    lastGKBroadcast[siteKey] = now
    Overlord.Sync:BroadcastGuildKeepState(siteKey, force, allowInstance)
end

local function NotifySiegeClosedOnPoint(siteKey)
    siteKey = siteKey or "guild_keep"
    if siegeClosedWarnedPointSiteKey == siteKey then return end
    siegeClosedWarnedPointSiteKey = siteKey
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r "
        .. ((GK and GK.GetSiegeClosedMessage and GK:GetSiegeClosedMessage())
            or ((L and L.GUILD_KEEP_SIEGE_CLOSED)
                or "Guild Keeps are attackable from 21:00 to 22:00 server time.")))
end

local function RearmSiegeClosedPointWarning(siteKey)
    if not siteKey or siegeClosedWarnedPointSiteKey == siteKey then
        siegeClosedWarnedPointSiteKey = nil
    end
end

local function RearmKeepPointWarnings(siteKey)
    RearmSiegeClosedPointWarning(siteKey)
    if not siteKey or factionHeldWarnedPointSiteKey == siteKey then
        factionHeldWarnedPointSiteKey = nil
    end
end

function Overlord.GuildKeepControl:OnKnownKeepMapExit()
    RearmKeepPointWarnings()
end

-- Meme gate que les zones de front (login / instance / settle 8 s)
local function CanStartKeepCapture(site, notify)
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then
        return false
    end
    if GK and GK.IsSiegeWindowOpen and not GK:IsSiegeWindowOpen() then
        if notify then
            NotifySiegeClosedOnPoint(site and (site.siteKey or site.id))
        end
        return false
    end
    if not IsWarModeActive() then
        if notify then
            local now = GetTime()
            if (now - lastWarModeWarnAt) >= WAR_MODE_WARN_GAP and L.GUILD_KEEP_WAR_MODE then
                lastWarModeWarnAt = now
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_WAR_MODE)
            end
        end
        return false
    end
    local defaultSite = GK and GK.GetDefaultSite and GK:GetDefaultSite()
    local gateTarget = {
        id = site and (site.id or site.siteKey) or (defaultSite and defaultSite.id) or "guild_keep",
        name = site and GK:GetDisplayName(site) or "Guild Keep",
    }
    if Overlord.CanStartLocalCapture and not Overlord:CanStartLocalCapture(gateTarget, notify) then
        return false
    end
    return true
end

local function CanFinishKeepCaptureBeforeWindowCloses(st, site)
    if not GK or not GK.GetSiegeSecondsRemaining then return false end
    local remaining = GK:GetSiegeSecondsRemaining()
    local req = GK:GetDefaultHoldTimeRequired(st, site)
    local elapsed = math.max(0, tonumber(st and st.holdTimeElapsed) or 0)
    -- La borne haute du siege est exclusive. Une capture qui finirait exactement a
    -- 22:00 serait ensuite rejetee par CompleteCapture et affichee unclaimed.
    return remaining > math.max(0, req - elapsed)
end

local function TryChatKeepLeftZone(site)
    if not site or not L.LEFT_ZONE then return end
    local key = site.siteKey or site.id or "keep"
    local now = GetTime()
    if (now - (lastKeepLeftChatAt[key] or 0)) < KEEP_CHAT_GAP then return end
    lastKeepLeftChatAt[key] = now
    Overlord:PrintNotification(string.format("|cFFFF0000[Overlord]|r " .. L.LEFT_ZONE, GK:GetDisplayName(site)))
end

local function TryChatKeepBackInZone(site)
    if not site or not L.BACK_IN_ZONE then return end
    local key = site.siteKey or site.id or "keep"
    local now = GetTime()
    if (now - (lastKeepBackChatAt[key] or 0)) < KEEP_CHAT_GAP then return end
    lastKeepBackChatAt[key] = now
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.BACK_IN_ZONE, GK:GetDisplayName(site)))
end

local function TryChatKeepContested(site, enemyCount, friendlyCount)
    if not site then return end
    local key = site.siteKey or site.id or "keep"
    local now = GetTime()
    if (now - (lastKeepContestedChatAt[key] or 0)) < KEEP_CONTESTED_CHAT_GAP then return end
    lastKeepContestedChatAt[key] = now
    local fmt
    if enemyCount > friendlyCount then
        fmt = L.GUILD_KEEP_CONTESTED_OUTNUMBER or L.ZONE_CONTESTED_OUTNUMBER
    else
        fmt = L.GUILD_KEEP_CONTESTED_EVEN or L.ZONE_CONTESTED_EVEN
    end
    if fmt then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. fmt,
            GK:GetDisplayName(site), enemyCount, friendlyCount))
    end
end

local function IsMapPointInKeep(site, px, py)
    if not site or not px or not py then return false, false end
    if GK and GK.IsMapPointInKeepGeometry then
        return GK:IsMapPointInKeepGeometry(site, px, py)
    end
    local ar = (GK and GK.GetMapAspectRatio and GK:GetMapAspectRatio(site)) or 1
    local halfSize = tonumber(site.captureHalfSize) or tonumber(site.halfSize) or 1.35
    if ar <= 0 then return false, false end
    local halfY = halfSize / ar
    return px >= site.center[1] - halfSize and px <= site.center[1] + halfSize
        and py >= site.center[2] - halfY and py <= site.center[2] + halfY, true
end

-- nil = Blizzard ne fournit pas une position exploitable ; booleen = mesure exacte. Toute
-- l'arithmetique reste dans le pcall car les coordonnees peuvent etre secret values en 12.x.
local function ReadUnitMapKeepMembership(unit, site, mapID)
    local pos = C_Map.GetPlayerMapPosition(mapID, unit)
    if not pos then return nil end
    local ux, uy = pos:GetXY()
    if ux == nil or uy == nil or (ux == 0 and uy == 0) then return nil end
    local inside, geometryKnown = IsMapPointInKeep(site, ux * 100, uy * 100)
    if not geometryKnown then return nil end
    return inside
end

local function GetUnitMapKeepMembership(unit, site, mapID)
    if not unit or not site or not mapID or not C_Map
        or not C_Map.GetPlayerMapPosition then return nil end
    local ok, inside = pcall(ReadUnitMapKeepMembership, unit, site, mapID)
    if not ok then return nil end
    return inside
end

local function IsUnitInKeepByMapPosition(unit, site, mapID)
    return GetUnitMapKeepMembership(unit, site, mapID) == true
end

local function CapturerRosterKey(name)
    name = AccessibleStringKey(name)
    if not name then return nil end
    if Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
        local key = Overlord.Sync:GetCaptureContributorDedupKey(name)
        if key and key ~= "" then return string.lower(key) end
    end
    return string.lower((name:gsub("%s+", "")))
end

local function GetKeepUnitIdentity(unit)
    local guid
    if UnitGUID then
        local ok, value = pcall(UnitGUID, unit)
        if ok then guid = AccessibleStringKey(value) end
    end
    if guid then return guid, guid end
    local full = Overlord.SafeGetUnitName and Overlord:SafeGetUnitName(unit, true)
    return CapturerRosterKey(full), nil
end

-- Un GUID de nameplate peut etre secret alors que le meme joueur a deja ete compte via
-- son token de groupe. UnitInRaid donne directement l'index sans rescanner les 40 slots ;
-- en groupe de cinq, quatre comparaisons UnitIsUnit au pire restent negligeables et exactes.
local function FriendlyNameplateWasCountedFromGroup(unit)
    if not unit then return false end
    if IsInRaid() and type(UnitInRaid) == "function" then
        local ok, raidIndex = pcall(UnitInRaid, unit)
        if ok then
            if canaccessvalue then
                local okAcc, accessible = pcall(canaccessvalue, raidIndex)
                if not okAcc or not accessible then return false end
            end
            if raidIndex ~= nil then
                local okIndex, index = pcall(tonumber, raidIndex)
                if okIndex and index then
                    local token = keepUnitTokens.raid[math.floor(index)]
                    return token ~= nil and keepScanCountedFriendlyGroupUnit[token] == true
                end
            end
        end
        return false
    end
    if IsInGroup() and type(UnitIsUnit) == "function" then
        for i = 1, 4 do
            local token = keepUnitTokens.party[i]
            if keepScanCountedFriendlyGroupUnit[token] then
                local ok, same = pcall(UnitIsUnit, unit, token)
                if ok and same then return true end
            end
        end
    end
    return false
end

-- Un seul resultat par capteur et par quart de seconde, partage par toutes les decisions
-- d'autorite du tick. On cherche d'abord le seul nom demande : scanner les auras des 40 slots
-- pour repondre sur un joueur provoquait jusqu'a 1 600 lectures inutiles par seconde.
-- Retour 2 = appartenance groupe connue ; retour 1 nil = position C_Map inconnue.
function Overlord.GuildKeepControl:IsGroupedCapturerEligibleForKeep(capturerName, siteKey)
    local site = GK and GK.GetSite and GK:GetSite(siteKey)
    if not site or not site.mapID then return nil, false end
    local want = CapturerRosterKey(capturerName)
    if not want or not IsInGroup() then return nil, false end
    local stamp = math.floor(GetTime() * 4)
    local shard = Overlord.Shard
    local contextKey = tostring(shard and shard.localContextKey or "")
    local contextAt = tonumber(shard and shard.localContextStartedAt) or 0
    if capturerEligibilityCache.stamp ~= stamp
        or capturerEligibilityCache.siteKey ~= siteKey
        or capturerEligibilityCache.contextKey ~= contextKey
        or capturerEligibilityCache.contextAt ~= contextAt then
        wipe(capturerEligibilityCache.rows)
        capturerEligibilityCache.stamp = stamp
        capturerEligibilityCache.siteKey = siteKey
        capturerEligibilityCache.contextKey = contextKey
        capturerEligibilityCache.contextAt = contextAt
    end
    local rows = capturerEligibilityCache.rows
    if rows[want] == nil then
        rows[want] = false -- absent du groupe, sauf si un slot correspondant est trouve ci-dessous
        local prefix, count = IsInRaid() and "raid" or "party", IsInRaid() and 40 or 4
        for i = 1, count do
            local unit = keepUnitTokens[prefix][i]
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local full = Overlord.SafeGetUnitName and Overlord:SafeGetUnitName(unit, true)
                local key = CapturerRosterKey(full)
                if key == want then
                    local eligible
                    if (type(UnitIsConnected) == "function" and not UnitIsConnected(unit))
                        or (type(UnitInPhase) == "function" and UnitInPhase(unit) ~= true)
                        or UnitIsDead(unit) or UnitIsGhost(unit)
                        or IsUnitInNonCaptureState(unit) then
                        eligible = false
                    else
                        local unitMap
                        if C_Map and C_Map.GetBestMapForUnit then
                            local mapOk, map = pcall(C_Map.GetBestMapForUnit, unit)
                            if mapOk then unitMap = map end
                        end
                        if unitMap and GK.IsKeepSiteDisplayMap
                            and not GK:IsKeepSiteDisplayMap(unitMap, site) then
                            eligible = false
                        else
                            local inside = GetUnitMapKeepMembership(unit, site, site.mapID)
                            if inside ~= nil then eligible = inside end
                            -- UnitIsVisible=false signifie aussi simplement « hors portee ».
                            -- Sans carte/coordonnees exactes, conserver nil : le heartbeat
                            -- direct reste candidat provisoire a l'election deterministe.
                        end
                    end
                    rows[want] = eligible == nil and "unknown"
                        or (eligible and "eligible" or "ineligible")
                    break
                end
            end
        end
    end
    local row = capturerEligibilityCache.rows[want]
    if row == false then return nil, false end
    if row == "unknown" then return nil, true end
    return row == "eligible", true
end

-- C_Map.GetPlayerMapPosition ne renvoie une position QUE pour le joueur et son groupe/raid : un
-- ennemi (ou un allie hors-groupe) vu en nameplate n'a JAMAIS de position carte. Filtrer ces
-- nameplates par le carre via IsUnitInKeepByMapPosition les rejetait donc toujours -> enemyCount
-- restait structurellement a 0 et la capture n'etait jamais contestee. Comme le moteur de zones
-- (ZoneControl:ScanNearbyPlayers), on retombe alors sur la presence du JOUEUR dans le fortin.
-- Sans aucune position Blizzard, compter la nameplate visible est un choix conservateur : il peut
-- inclure un joueur proche hors carre, mais evite qu'une position volontairement indisponible
-- rende la defense invisible. Position resolvable = test exact du carre conserve.
local function GetKeepWorldBounds(site)
    if not GK or not GK.GetKeepWorldCaptureSquare then return nil end
    return GK:GetKeepWorldCaptureSquare(site)
end

local function ReadUnitWorldKeepMembership(unit, worldBounds)
    local ux, uy, _, instanceID = UnitPosition(unit)
    ux, uy, instanceID = tonumber(ux), tonumber(uy), tonumber(instanceID)
    if not ux or not uy then return nil end
    if worldBounds.continentID and instanceID
        and worldBounds.continentID ~= instanceID then return false end
    return ux >= worldBounds.minX and ux <= worldBounds.maxX
        and uy >= worldBounds.minY and uy <= worldBounds.maxY
end

local function NameplateUnitContestsKeep(unit, site, mapID, playerInKeep, worldBounds)
    if not unit or not site or not mapID then return false end
    -- UnitPosition fonctionne aussi pour certaines nameplates ennemies. Quand WoW livre cette
    -- position, le carre monde ecarte les joueurs visibles mais certainement hors du fortin.
    if worldBounds and UnitPosition then
        local ok, inside = pcall(ReadUnitWorldKeepMembership, unit, worldBounds)
        if ok and inside ~= nil then return inside end
    end
    -- Pour les unites de groupe, C_Map peut fournir une position exacte quand UnitPosition
    -- est indisponible. Les ennemis renvoient generalement nil ici.
    local mapInside = GetUnitMapKeepMembership(unit, site, mapID)
    if mapInside ~= nil then return mapInside end
    -- Valeur secret/inconnue : conserver le choix protecteur, sans faux negatif exploitable.
    return playerInKeep and true or false
end

local function ScanNearbyKeepPlayers(site, forceFresh)
    local siteKey = site and (site.siteKey or site.id)
    local now = GetTime()
    -- Ce check local est bon marche et invalide immediatement le cache de forces lors
    -- d'une mort, furtivite ou transformation ; sinon l'ancien +1 pouvait survivre deux
    -- secondes et masquer l'absence reelle de tout allie eligible.
    local playerCount = UnitCountsForKeep("player")
    local shard = Overlord.Shard
    local contextKey = tostring(shard and shard.localContextKey or "")
    local contextAt = tonumber(shard and shard.localContextStartedAt) or 0
    if not forceFresh and keepScanCache.siteKey == siteKey
        and keepScanCache.contextKey == contextKey
        and keepScanCache.contextAt == contextAt
        and keepScanCache.player == playerCount
        and now - keepScanCache.time < KEEP_SCAN_CACHE_SECONDS then
        return keepScanCache.friendly, keepScanCache.enemy, keepScanCache.time
    end

    local friendlyCount = playerCount
    local enemyCount = 0
    local enemyFaction = Overlord.Zones and Overlord.Zones.GetEnemyFaction
        and Overlord.Zones:GetEnemyFaction() or nil
    if not enemyFaction and Overlord.PlayerFaction then
        enemyFaction = (Overlord.PlayerFaction == "Alliance") and "Horde" or "Alliance"
    end

    wipe(keepScanCountedFriendly)
    wipe(keepScanCountedEnemy)
    wipe(keepScanCountedFriendlyGroupUnit)
    wipe(keepScanAuraResultByGUID)
    local playerIdentity = GetKeepUnitIdentity("player")
    if playerIdentity then keepScanCountedFriendly[playerIdentity] = true end

    local mapID = site and site.mapID
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
                local unit = keepUnitTokens[prefix][i]
                if UnitExists(unit) and not UnitIsUnit(unit, "player")
                    and (type(UnitIsConnected) ~= "function" or UnitIsConnected(unit))
                    and (type(UnitInPhase) ~= "function" or UnitInPhase(unit) == true) then
                    local faction = UnitFactionGroup(unit)
                    local identity, guid = GetKeepUnitIdentity(unit)
                    local alreadyCounted = identity and ((faction == Overlord.PlayerFaction
                        and keepScanCountedFriendly[identity]) or (faction == enemyFaction
                        and keepScanCountedEnemy[identity]))
                    if not alreadyCounted and IsUnitInKeepByMapPosition(unit, site, mapID) then
                        if faction == Overlord.PlayerFaction then
                            local blocked = IsUnitInNonCaptureState(
                                unit, keepScanAuraResultByGUID, guid)
                            if not blocked then
                                friendlyCount = friendlyCount + 1
                                keepScanCountedFriendlyGroupUnit[unit] = true
                                if identity then keepScanCountedFriendly[identity] = true end
                            end
                        elseif faction == enemyFaction then
                            local blocked = IsUnitIneligibleToContest(
                                unit, keepScanAuraResultByGUID, guid)
                            if not blocked then
                                enemyCount = enemyCount + 1
                                if identity then keepScanCountedEnemy[identity] = true end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Ancre de proximite pour les nameplates sans position carte (ennemis / allies hors-groupe) :
    -- on ne compte ces unites que si le joueur tient lui-meme le carre du fortin.
    local playerInKeep = mapID and GK:IsPlayerInKeepGeometry(site) or false
    local worldBounds = playerInKeep and GetKeepWorldBounds(site) or nil
    for i = 1, 40 do
        local unit = keepUnitTokens.nameplate[i]
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsDead(unit) and not UnitIsGhost(unit) then
            local faction = UnitFactionGroup(unit)
            local identity, guid = GetKeepUnitIdentity(unit)
            local alreadyCounted = identity and ((faction == Overlord.PlayerFaction
                and keepScanCountedFriendly[identity]) or (faction == enemyFaction
                and keepScanCountedEnemy[identity]))
            if not alreadyCounted and mapID and NameplateUnitContestsKeep(
                unit, site, mapID, playerInKeep, worldBounds) then
                if faction == enemyFaction then
                    local blocked = IsUnitIneligibleToContest(
                        unit, keepScanAuraResultByGUID, guid)
                    if not blocked then
                        enemyCount = enemyCount + 1
                        if identity then keepScanCountedEnemy[identity] = true end
                    end
                end
                if faction == Overlord.PlayerFaction and not UnitIsUnit(unit, "player") then
                    -- Un GUID secret ne permet pas le dedup par table. Utiliser d'abord
                    -- l'alias groupe exact, avant les lookups aura potentiellement couteux.
                    local duplicateGroupAlias = not guid
                        and FriendlyNameplateWasCountedFromGroup(unit)
                    local blocked = false
                    if not duplicateGroupAlias then
                        blocked = IsUnitInNonCaptureState(
                            unit, keepScanAuraResultByGUID, guid)
                    end
                    if not duplicateGroupAlias and not blocked then
                        -- En 12.x, un GUID/nameplate peut etre secret alors que la faction,
                        -- la vie et les auras restent lisibles. Ne jamais jeter cet allie :
                        -- c'est exactement ce qui transformait visuellement un 5v1 en 1v1.
                        if identity then keepScanCountedFriendly[identity] = true end
                        friendlyCount = friendlyCount + 1
                    end
                end
            end
        end
    end

    keepScanCache.siteKey = siteKey
    keepScanCache.time = now
    keepScanCache.contextKey = contextKey
    keepScanCache.contextAt = contextAt
    keepScanCache.player = playerCount
    keepScanCache.friendly = friendlyCount
    keepScanCache.enemy = enemyCount
    return friendlyCount, enemyCount, keepScanCache.time
end

function Overlord.GuildKeepControl:GetNearbyKeepPlayerCounts(site)
    return ScanNearbyKeepPlayers(site)
end

-- Defense locale (tenant dans le carre) : le defenseur est une preuve physique que le fortin
-- est attaque, meme si aucun GK ennemi n'est encore arrive (whispers communaute echantillonnes).
-- Aucune ecriture d'etat sync : alerte chat + HUD + rattrapage reseau immediat ; le capteur
-- assaillant reste la seule autorite du timer.
local function CheckLocalKeepDefense(siteKey, st, site)
    if not st or st.status ~= "held" or not GK:IsPlayerDefendingHeldKeep(st, siteKey) then return end
    if GK.IsSiegeWindowOpen and not GK:IsSiegeWindowOpen() then return end
    if not IsWarModeActive() then return end
    local _, enemyCount = ScanNearbyKeepPlayers(site)
    local now = GetTime()
    if (enemyCount or 0) > 0 then
        lastKeepDefenseEnemyAt[siteKey] = now
        st.gkLocalDefenseSeenAt = now
        if not keepDefenseAlerted[siteKey] then
            keepDefenseAlerted[siteKey] = true
            local facLabel = (Overlord.Zones and Overlord.Zones.GetEnemyFactionName)
                and Overlord.Zones:GetEnemyFactionName()
                or ((Overlord.PlayerFaction == "Alliance") and "Horde" or "Alliance")
            -- Distinguer fortin de notre guilde vs fortin allie (meme faction, autre guilde).
            -- Alerte locale uniquement (on est dans la geometrie du fortin) : aucun cout reseau ajoute.
            local localGuild = GK.GetLocalPlayerGuild and GK:GetLocalPlayerGuild() or ""
            local ownerGuild = GK.GetEffectiveHeldTenant and select(1, GK:GetEffectiveHeldTenant(st, siteKey)) or ""
            if GK.SanitizeGuildName then
                localGuild = GK:SanitizeGuildName(localGuild or "")
                ownerGuild = GK:SanitizeGuildName(ownerGuild or "")
            end
            local isOwnGuild = ownerGuild ~= "" and localGuild ~= "" and ownerGuild == localGuild
            if (not isOwnGuild) and ownerGuild ~= "" and L.GUILD_KEEP_ALLIED_UNDER_ATTACK then
                -- Fortin allie : nom du fortin, guilde tenante, faction ennemie.
                Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_ALLIED_UNDER_ATTACK,
                    GK:GetDisplayName(site), ownerGuild, facLabel))
            elseif L.GUILD_KEEP_UNDER_ATTACK then
                Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_UNDER_ATTACK,
                    GK:GetDisplayName(site), facLabel))
            end
            if OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled then
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
            end
            -- Eviter le doublon quand le GK in_progress ennemi finira par arriver (merge).
            if Overlord.Sync and Overlord.Sync.NoteGuildKeepDefenderAlerted then
                Overlord.Sync:NoteGuildKeepDefenderAlerted(siteKey)
            end
            RefreshKeepHud()
        end
        -- L'assaut reel est connu du capteur ennemi : demander le GK seulement si notre
        -- etat est reellement stale (age reel, pas force). Etat held fige = updatedAt
        -- ancien = poll ; des que les GK coulent (~5 s), l'age retombe sous le seuil
        -- 22/45 s et les SR s'arretent (pas de resync inutile pendant tout le siege).
        if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
            Overlord.Sync:PollIfStaleObserverKeep(
                NetworkNow() - (tonumber(st.updatedAt) or 0), siteKey)
        end
    elseif keepDefenseAlerted[siteKey]
        and now - (lastKeepDefenseEnemyAt[siteKey] or 0) > KEEP_DEFENSE_REARM_SECONDS then
        keepDefenseAlerted[siteKey] = nil
        st.gkLocalDefenseSeenAt = nil
        RefreshKeepHud()
    end
end

-- Joueur dans le carre mais timer absent : demander un rattrapage GK sans ecrire d'etat.
-- Ce poll ne bloque plus StartHold. La gate login/instance commune protege deja le demarrage,
-- puis l'ordre total v8 remplace proprement une ancre locale tardive si un premier tag distant
-- arrive ensuite. L'ancien second verrou de 45 s faisait exactement l'inverse de 9.9.1 : sur
-- un fortin vierge, le vrai premier tagueur restait sans timer et sans Anchor.
local function RequestKeepCatchupIfHudLooksStale(siteKey, st, site)
    if not siteKey or not st or not site then return end
    if not Overlord.Sync or not Overlord.Sync.PollIfStaleObserverKeep then return end
    if GK.IsSiegeWindowOpen and not GK:IsSiegeWindowOpen() then return end
    if not IsWarModeActive() then return end
    if st.status == "in_progress" then return end

    local updatedAt = tonumber(st.updatedAt) or 0
    local neverSynced = updatedAt <= 0
    local needsCatchup = neverSynced
    if not needsCatchup and st.status == "held" and GK:IsPlayerDefendingHeldKeep(st, siteKey) then
        local _, enemyCount = ScanNearbyKeepPlayers(site)
        if (enemyCount or 0) > 0 then
            needsCatchup = true
        end
    elseif not needsCatchup and st.status == "neutral" then
        needsCatchup = (NetworkNow() - updatedAt) >= 22
    end

    if needsCatchup then
        Overlord.Sync:PollIfStaleObserverKeep(999, siteKey)
    end
end

local function NotifyWrongAssaultShard(siteKey, lock, contact)
    if not lock or not L.GUILD_KEEP_WRONG_ASSAULT_SHARD then return end
    local now = GetTime()
    local warnedAt = lastWrongShardWarnAt[siteKey]
    if warnedAt and now - warnedAt < WRONG_SHARD_WARN_GAP then return end
    lastWrongShardWarnAt[siteKey] = now
    local lockLabel = tostring(lock)
    if Overlord.Shard and Overlord.Shard.GetShardReference then
        local _, referenceRealm = Overlord.Shard:GetShardReference(lock)
        if referenceRealm and referenceRealm ~= "" then
            lockLabel = lockLabel .. " (" .. string.format(
                L.SHARD_BADGE_REFERENCE or "via %s", referenceRealm) .. ")"
        end
    end
    contact = tostring(contact or "")
    local fmt = contact ~= "" and L.GUILD_KEEP_WRONG_ASSAULT_SHARD_CONTACT or nil
    fmt = fmt or L.GUILD_KEEP_WRONG_ASSAULT_SHARD
    Overlord:PrintNotification(string.format(
        "|cFFFFD100[Overlord]|r " .. fmt, lockLabel, contact))
end

function Overlord.GuildKeepControl:StartHold(siteKey, st, site)
    if not st or not site then return end
    local lineageCatchupUntil = math.floor(tonumber(st._gkLineageCatchupUntil) or 0)
    if lineageCatchupUntil > NetworkNow() then
        if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
            Overlord.Sync:PollIfStaleObserverKeep(999, siteKey)
        end
        return
    end
    st._gkLineageCatchupUntil = nil
    if not CanStartKeepCapture(site, true) then return end
    if not CanFinishKeepCaptureBeforeWindowCloses(st, site) then return end
    -- Assaut deja ancre sur une autre shard : hop obligatoire, pas de second timer local.
    if GK.IsLocalShardBlockedFromKeepAssault
        and GK:IsLocalShardBlockedFromKeepAssault(st, siteKey) then
        local lock = GK.GetAssaultShardId and GK:GetAssaultShardId(st)
        local contact = GK.GetAssaultShardPlayer and GK:GetAssaultShardPlayer(st) or ""
        NotifyWrongAssaultShard(siteKey, lock, contact)
        return
    end
    local guild = GK:GetLocalPlayerGuild()
    if guild == "" then
        if L.GUILD_KEEP_NO_GUILD then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_NO_GUILD)
        end
        return
    end
    local localShardId = Overlord.Shard and Overlord.Shard.GetCaptureLocalShardID
        and Overlord.Shard:GetCaptureLocalShardID("keep:" .. tostring(siteKey), 8) or nil
    if not localShardId then
        local now = GetTime()
        if L.GUILD_KEEP_SHARD_UNKNOWN
            and now - (lastShardUnknownWarnAt[siteKey] or 0) >= SHARD_UNKNOWN_WARN_GAP then
            lastShardUnknownWarnAt[siteKey] = now
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_SHARD_UNKNOWN)
        end
        return
    end
    -- Un snapshot incomplet sans tuple immuable reste observateur. Le reprendre ici
    -- recreerait artificiellement l'ancre sur la shard courante.
    if st.status == "in_progress" and GK.HasAssaultShardAnchor
        and not GK:HasAssaultShardAnchor(st) then
        if L.GUILD_KEEP_WAITING_ASSAULT_SHARD then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_WAITING_ASSAULT_SHARD)
        end
        return
    end
    local assaultBaseGuild, assaultBaseFaction, assaultBaseCapturedAt = "", nil, 0
    local previousOwnerGuild, previousOwnerFaction = "", nil
    local previousClaimedAt, previousExpiresAt = 0, 0
    do
        local prevGuild, prevFaction, prevClaimedAt, prevExpiresAt =
            GK:GetEffectiveHeldTenant(st, siteKey)
        if prevGuild == "" and GK.GetKeepDisplayTenant then
            prevGuild, prevFaction = GK:GetKeepDisplayTenant(st, siteKey)
            prevGuild = GK:SanitizeGuildName(prevGuild or "")
            if prevGuild ~= "" and prevClaimedAt <= 0 and GK.GetOfficialKeepTenant then
                local official = GK:GetOfficialKeepTenant(siteKey)
                if official then
                    prevClaimedAt = math.floor(tonumber(official.claimedAt) or 0)
                end
            end
        end
        if prevGuild == "" and st.status == "held" then
            -- Fallback si tenant officiel absent mais etat held local present.
            -- Faction stockee d'abord, vote heuristique en secours (anti-homonymie).
            prevGuild = GK:SanitizeGuildName(st.ownerGuild or "")
            prevFaction = (st.ownerFaction == "Alliance" or st.ownerFaction == "Horde")
                and st.ownerFaction or GK:GetKnownGuildFaction(prevGuild)
            prevClaimedAt = math.floor(tonumber(st.claimedAt) or 0)
            prevExpiresAt = math.floor(tonumber(st.expiresAt) or 0)
        end
        previousOwnerGuild, previousOwnerFaction = prevGuild, prevFaction
        previousClaimedAt, previousExpiresAt = prevClaimedAt, prevExpiresAt
        if prevGuild ~= "" and (prevFaction == "Alliance" or prevFaction == "Horde")
            and math.floor(tonumber(prevClaimedAt) or 0) > 0 then
            assaultBaseGuild = prevGuild
            assaultBaseFaction = prevFaction
            assaultBaseCapturedAt = math.floor(tonumber(prevClaimedAt) or 0)
        end
    end
    -- Reprise meme apres gate login : un autre membre de la guilde peut deja porter
    -- le timer GK. Ne jamais remettre a zero une capture in_progress de notre guilde.
    local assaultGuild = select(1, GK.GetCanonicalAssaultGuild and GK:GetCanonicalAssaultGuild(st) or "")
    if assaultGuild == "" then
        assaultGuild = GK:SanitizeGuildName(st.ownerGuild or "")
    end
    local resumeCapture = st.status == "in_progress"
        and assaultGuild == guild
        and st.ownerFaction == Overlord.PlayerFaction
        and (st.holdTimeElapsed or 0) > 0
    local nowEpoch = NetworkNow()
    local assaultStartedAt, assaultGenerationAt
    if resumeCapture then
        assaultStartedAt = GK:GetAssaultShardStartedAt(st)
        assaultGenerationAt = GK:GetAssaultGenerationAt(st)
    else
        local attemptNow = math.max(nowEpoch, assaultBaseCapturedAt)
        assaultGenerationAt, assaultStartedAt = GK:GetNextAssaultGenerationAt(
            st, assaultBaseGuild, assaultBaseFaction, assaultBaseCapturedAt,
            localShardId, attemptNow)
        -- Mauvais shard Anchor, ou retry dans la meme seconde que le GA : fail-closed.
        -- Le scan/tick suivant retentera tout seul une fois l'horloge serveur avancee.
        if assaultGenerationAt == nil or not assaultStartedAt then
            local retryShard, retryContact = GK.GetRequiredRetryShardInfo
                and GK:GetRequiredRetryShardInfo(
                    st, assaultBaseGuild, assaultBaseFaction,
                    assaultBaseCapturedAt, attemptNow) or nil
            if retryShard and retryShard ~= localShardId then
                NotifyWrongAssaultShard(siteKey, retryShard, retryContact)
            end
            return
        end
    end
    local prevStatus = st.status
    local deferredLineageOwnedBefore = GK.DeferredLineageOwnsCurrentState
        and GK:DeferredLineageOwnsCurrentState(st) or false
    if GK.RememberLocalGkCapturerCandidate then
        GK:RememberLocalGkCapturerCandidate(st)
    end
    -- Valider et poser l'identite avant toute mutation gameplay. Un retry refuse ne doit
    -- jamais laisser un etat in_progress sans ancre diffusable/finalisable.
    if not resumeCapture and (not GK.AdoptAssaultAnchor
        or not GK:AdoptAssaultAnchor(st, guild, Overlord.PlayerFaction,
            localShardId, assaultStartedAt, assaultGenerationAt,
            st.gkOfficialCapturerName, assaultBaseGuild,
            assaultBaseFaction, assaultBaseCapturedAt)) then
        return
    end
    st.status = "in_progress"
    st._gkStaleObserver = nil
    st._gkContestStreak = nil
    st.isHolding = true
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = true
    if resumeCapture then
        st.holdTimeElapsed = tonumber(st.holdTimeElapsed) or 0
        st.holdStartTime = GetTime() - (tonumber(st.holdTimeElapsed) or 0)
    else
        st.holdTimeElapsed = 0
        st.holdStartTime = GetTime()
        st.holdTimeRequired = GK:GetBaseHoldTimeRequired(site)
    end
    st.ownerGuild = guild
    st.ownerFaction = Overlord.PlayerFaction
    st.pool = Overlord.GetCurrentSavedVarsPool and Overlord:GetCurrentSavedVarsPool() or ""
    st.updatedAt = nowEpoch
    st.previousOwnerGuild = previousOwnerGuild
    st.previousOwnerFaction = previousOwnerFaction
    st.previousClaimedAt = previousClaimedAt
    st.previousExpiresAt = previousExpiresAt
    st.claimedAt = 0
    st.expiresAt = 0
    if GK.ResolveCanonicalAssaultGuild then
        GK:ResolveCanonicalAssaultGuild(st)
    end
    local canonGuild, canonFac = GK.GetCanonicalAssaultGuild
        and GK:GetCanonicalAssaultGuild(st) or "", nil
    local deferredToCanonical = false
    if canonGuild ~= "" and canonGuild ~= guild then
        st.ownerGuild = canonGuild
        st.ownerFaction = canonFac
        st.holdAuthorityLocal = false
        st.isHolding = false
        st.isPaused = false
        st.isContested = false
        st._gkContestStreak = nil
        st.holdStartTime = nil
        deferredToCanonical = true
    end
    if not resumeCapture and not deferredToCanonical and Overlord.Ressources
        and Overlord.Ressources.ConsumeCaptureReduction then
        st.holdTimeRequired = Overlord.Ressources:ConsumeCaptureReduction(
            st.holdTimeRequired, GK:GetMinimumHoldTimeRequired(site))
    end
    if GK.RememberDeferredLineageCurrentAssault then
        GK:RememberDeferredLineageCurrentAssault(st, deferredLineageOwnedBefore)
    end
    GK:SaveKeeps()
    Overlord:MarkDirty()
    if not deferredToCanonical and prevStatus ~= "in_progress" and Overlord.GuildKeepImmersion
        and Overlord.GuildKeepImmersion.OnSiegeAssaultBegan then
        Overlord.GuildKeepImmersion:OnSiegeAssaultBegan(siteKey, guild, Overlord.PlayerFaction)
    end
    ResolveKeepAssaultAuthority(siteKey, st)
    -- Le debut est deja reconnu comme transition critique par BroadcastGuildKeepState.
    -- Ne pas le faire passer pour un snapshot terminal forceFull : la transition conserve
    -- sa couverture 25/40, mais suit desormais la pompe lente/coalescee dediee au siege.
    BroadcastGK(siteKey, false)
    if Overlord.ZoneIndicator then
        Overlord.ZoneIndicator:InvalidateActiveZoneCache()
        Overlord.ZoneIndicator:Show()
    end
    local now = GetTime()
    if not deferredToCanonical and L.GUILD_KEEP_HOLD_STARTED
        and (now - lastHoldStartedNotifyAt) >= HOLD_STARTED_NOTIFY_GAP then
        lastHoldStartedNotifyAt = now
        Overlord:PrintNotification(string.format("|cFFFFFF00[Overlord]|r " .. L.GUILD_KEEP_HOLD_STARTED,
            GK:GetDisplayName(site), math.floor(GK:GetDefaultHoldTimeRequired(st, site) / 60)))
    end
    GK:RefreshKeepPresentation(siteKey)
    if Overlord.Ressources and Overlord.Ressources.RefreshGuildKeepHUD then
        Overlord.Ressources:RefreshGuildKeepHUD(true)
    end
end

function Overlord.GuildKeepControl:OnInstanceSuspend()
    if not GK then return end
    for key in pairs(Overlord.GuildKeepSites or {}) do
        local st = GK:GetState(key)
        if st and st.holdAuthorityLocal then
            self:RevertCapture(key, st, true)
        end
    end
end

function Overlord.GuildKeepControl:RevertCapture(siteKey, st, allowInstanceBroadcast)
    if not st then return end
    local attemptStartedAt = GK.GetCurrentAssaultAttemptStartedAt
        and GK:GetCurrentAssaultAttemptStartedAt(st) or GK:GetAssaultShardStartedAt(st)
    local abortTs = math.max(NetworkNow(), attemptStartedAt)
    local guild = GK:SanitizeGuildName(st.assaultShardGuild or st.ownerGuild or "")
    local faction = st.assaultShardFaction or st.ownerFaction
    local anchorShard = GK:GetAssaultShardId(st)
    local anchorStartedAt = GK:GetAssaultShardStartedAt(st)
    local anchorGenerationAt = GK:GetAssaultGenerationAt(st)
    local anchorPlayer = GK:GetAssaultShardPlayer(st)
    local baseGuild = GK:SanitizeGuildName(st.assaultBaseGuild or "")
    local baseFaction = st.assaultBaseFaction
    local baseCapturedAt = math.floor(tonumber(st.assaultBaseCapturedAt) or 0)
    local aborted = anchorShard and GK:AbortAssault(
        siteKey, guild, faction, abortTs, anchorShard, anchorStartedAt,
        anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, LocalFullName())
    if aborted and Overlord.Sync and Overlord.Sync.BroadcastGuildKeepAbort then
        Overlord.Sync:BroadcastGuildKeepAbort(
            siteKey, guild, faction, abortTs, anchorShard, anchorStartedAt,
            anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
    elseif not aborted then return end
    GK:RefreshKeepPresentation(siteKey)
    RefreshKeepHud()
end

function Overlord.GuildKeepControl:CompleteCapture(siteKey, st, site)
    if GK.IsSiegeCaptureTimestampAllowed and not GK:IsSiegeCaptureTimestampAllowed(NetworkNow()) then
        self:RevertCapture(siteKey, st)
        return
    end
    if GK.ResolveCanonicalAssaultGuild then
        GK:ResolveCanonicalAssaultGuild(st)
    end
    local guild = select(1, GK.GetCanonicalAssaultGuild and GK:GetCanonicalAssaultGuild(st) or "")
    if guild == "" then
        guild = GK:SanitizeGuildName(st.ownerGuild or "")
    end
    if guild == "" then
        guild = GK:GetLocalPlayerGuild()
    end
    local fac = st.ownerFaction or Overlord.PlayerFaction
    local anchorShard = GK.GetAssaultShardId and GK:GetAssaultShardId(st) or nil
    local anchorStartedAt = math.floor(tonumber(st.assaultShardStartedAt) or 0)
    local anchorGenerationAt = GK.GetAssaultGenerationAt and GK:GetAssaultGenerationAt(st) or 0
    local anchorPlayer = GK.GetAssaultShardPlayer and GK:GetAssaultShardPlayer(st) or ""
    local baseGuild = GK:SanitizeGuildName(st.assaultBaseGuild or "")
    local baseFaction = st.assaultBaseFaction
    local baseCapturedAt = math.floor(tonumber(st.assaultBaseCapturedAt) or 0)
    -- Une capture locale sans preuve d'ancre ne peut pas produire de final global.
    if not anchorShard or anchorStartedAt <= 0 or anchorPlayer == "" then return end
    if GK.IsLocalShardBlockedFromKeepAssault
        and GK:IsLocalShardBlockedFromKeepAssault(st, siteKey) then return end
    local attemptStartedAt = GK.GetAssaultAttemptStartedAt
        and GK:GetAssaultAttemptStartedAt(anchorStartedAt, anchorGenerationAt)
        or anchorStartedAt
    local captureTs = math.max(NetworkNow(), attemptStartedAt
        + GK:GetDefaultHoldTimeRequired(st, site))
    if not GK:CompleteCapture(siteKey, guild, fac, captureTs,
        anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, LocalFullName()) then return end
    if site and site.id and Overlord.Leaderboard
        and Overlord.Leaderboard.CreditPlayerObjectiveCapture then
        local _, classToken = UnitClass("player")
        Overlord.Leaderboard:CreditPlayerObjectiveCapture(
            LocalFullName(), site.id, fac, st.claimedAt, false, classToken)
    end
    if Overlord.Sync and Overlord.Sync.BroadcastGuildKeepCapture then
        Overlord.Sync:BroadcastGuildKeepCapture(siteKey, guild, fac, st.claimedAt,
            anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
    end
    if Overlord.ZoneIndicator then
        Overlord.ZoneIndicator:InvalidateActiveZoneCache()
    end
end

-- Timer fortin : CAPTURING (monte), CONTESTE (recule selon les forces), LOSING (hors carre).
-- Le comptage et la regle numerique restent ceux du moteur de zones ; seule la forme est carree.
local function ShouldTickKeepHoldTimer(siteKey, st)
    if not st then return false end
    if not st.holdAuthorityLocal then return false end
    if GK and GK.IsLocalShardBlockedFromKeepAssault
        and GK:IsLocalShardBlockedFromKeepAssault(st, siteKey) then
        if GK.StripLocalAuthorityIfWrongAssaultShard then
            GK:StripLocalAuthorityIfWrongAssaultShard(st, siteKey)
        end
        return false
    end
    return st.isHolding or st.isPaused
end

function Overlord.GuildKeepControl:UpdateHoldTimer(siteKey, st, site, deltaTime, inGeomOverride)
    if not ShouldTickKeepHoldTimer(siteKey, st) then return end
    -- Echantillonner le porteur local avant l'election. Quand il est confirme hors du
    -- carre (ou non capturable), il sort de l'ordre lexical et un co-capteur confirme
    -- peut reprendre le timer meme si son nom est lexicalement superieur.
    local sampledInGeom, geomSampleKnown = GK:IsPlayerInKeepGeometry(site)
    -- Un trou C_Map n'est ni CAPTURING ni LOSING. Geler ce tick empeche deux
    -- clients du meme raid de faire diverger leurs timers et interdit un faux GA.
    if not geomSampleKnown then return end
    local inGeom = inGeomOverride
    if inGeom == nil then inGeom = sampledInGeom end
    local localNonCapture = IsPlayerInNonCaptureState()
        or UnitIsDead("player") or UnitIsGhost("player")
    local localEligible
    if localNonCapture then
        localEligible = false
    elseif geomSampleKnown then
        localEligible = inGeom and true or false
    end
    if st.holdAuthorityLocal and GK.ShouldDeferToRemoteKeepCapturer then
        if GK:ShouldDeferToRemoteKeepCapturer(st, localEligible) then
            st.holdAuthorityLocal = false
            st.isHolding = false
            st.isPaused = false
            st.isContested = false
            st._gkContestStreak = nil
            ResolveKeepAssaultAuthority(siteKey, st)
            return
        end
    end
    local canProgress = st.holdAuthorityLocal and st.isHolding and not st.isPaused
    local canDecay = st.holdAuthorityLocal
    if st.holdAuthorityLocal and not IsWarModeActive() then
        self:RevertCapture(siteKey, st)
        return
    end
    if st.holdAuthorityLocal and GK.IsSiegeWindowOpen and not GK:IsSiegeWindowOpen() then
        self:RevertCapture(siteKey, st)
        if L and L.GUILD_KEEP_CAPTURE_LOST then
            Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_CAPTURE_LOST)
        end
        return
    end
    local req = GK:GetDefaultHoldTimeRequired(st, site)
    if not CanFinishKeepCaptureBeforeWindowCloses(st, site) then
        self:RevertCapture(siteKey, st)
        if L and L.GUILD_KEEP_CAPTURE_LOST then
            Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_CAPTURE_LOST)
        end
        return
    end

    local friendlyCount, enemyCount
    if inGeom then
        -- Au tick susceptible de finaliser la capture, ignorer volontairement le cache 2 s :
        -- un defenseur entre apres le dernier scan ne doit jamais laisser passer le terminal.
        local forceFresh = st.holdAuthorityLocal and st.isHolding and not st.isPaused
            and ((tonumber(st.holdTimeElapsed) or 0) + deltaTime >= req)
        friendlyCount, enemyCount = ScanNearbyKeepPlayers(site, forceFresh)
        -- Mort, furtivite, monture ou forme de voyage excluent uniquement le capteur local.
        -- Tant qu'au moins un autre allie eligible reste dans le carre, ce client peut
        -- continuer a servir de capteur du groupe. La 9.9.17 convertissait toute la force
        -- en LOSING des que l'autorite locale changeait d'etat, meme en 5v1.
        if localNonCapture and (tonumber(friendlyCount) or 0) <= 0 then
            inGeom = false
        end
    end

    if inGeom then
        local rawContested, contestPull
        if Overlord.ZoneControl and Overlord.ZoneControl.EvaluateCaptureForces then
            rawContested, contestPull = Overlord.ZoneControl:EvaluateCaptureForces(
                friendlyCount, enemyCount, false)
        else
            rawContested = enemyCount > 0 and enemyCount >= friendlyCount
            contestPull = friendlyCount > 0 and math.max(1, enemyCount / friendlyCount) or 1
        end
        -- Meme bascule immediate que les zones, a l'entree comme a la sortie.
        local contested = rawContested
        if contested then
            if not st.isContested then
                st.isContested = true
                st.isPaused = false
                TryChatKeepContested(site, enemyCount, friendlyCount)
            end
            st.updatedAt = NetworkNow()
            MarkDirtyIfHoldSecChanged(siteKey, st)
            -- Meme recul que les zones : 1x a egalite, ratio complet en surnombre.
            st.holdTimeElapsed = math.max(
                0, (st.holdTimeElapsed or 0) - deltaTime * contestPull)
            if st.holdTimeElapsed <= 0 then
                st.holdTimeElapsed = 0
                st.isHolding = false
                st.isPaused = false
                st.isContested = false
                st.holdStartTime = nil
                self:RevertCapture(siteKey, st)
                if L.GUILD_KEEP_CAPTURE_LOST then
                    Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_CAPTURE_LOST)
                end
            else
                ResolveKeepAssaultAuthority(siteKey, st)
                BroadcastGK(siteKey, false)
                GK:RefreshKeepPresentation(siteKey)
            end
            return
        elseif st.isContested then
            st.isContested = false
            TryChatKeepBackInZone(site)
        end
        if st.isPaused then
            st.isPaused = false
            TryChatKeepBackInZone(site)
        end
        if canProgress then
            st.holdTimeElapsed = (st.holdTimeElapsed or 0) + deltaTime
            st.updatedAt = NetworkNow()
            MarkDirtyIfHoldSecChanged(siteKey, st)
            ResolveKeepAssaultAuthority(siteKey, st)
            BroadcastGK(siteKey, false)
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
            TryChatKeepLeftZone(site)
        end
        st.isContested = false
        -- isContested force hors hysteresis : purger le streak, sinon un residu positif fait
        -- rebasculer CONTESTE au premier scan apres retour dans le carre.
        st._gkContestStreak = nil
        st.holdTimeElapsed = (st.holdTimeElapsed or 0) - deltaTime
        st.updatedAt = NetworkNow()
        MarkDirtyIfHoldSecChanged(siteKey, st)
        if st.holdTimeElapsed <= 0 then
            st.holdTimeElapsed = 0
            if GK.HasFreshRemoteDirectCapturer
                and GK:HasFreshRemoteDirectCapturer(st, 12) then
                -- Un co-capteur direct diffuse encore le meme tuple. Garder ce client
                -- a zero quelques secondes laisse son prochain hold croissant gagner,
                -- au lieu d'emettre un GA contradictoire pendant qu'il capture toujours.
                ResolveKeepAssaultAuthority(siteKey, st)
                BroadcastGK(siteKey, false)
                GK:RefreshKeepPresentation(siteKey)
            else
                st.isPaused = false
                st.isHolding = false
                st.holdStartTime = nil
                self:RevertCapture(siteKey, st)
                if L.GUILD_KEEP_CAPTURE_LOST then
                    Overlord:PrintNotification(
                        "|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_CAPTURE_LOST)
                end
            end
        else
            ResolveKeepAssaultAuthority(siteKey, st)
            BroadcastGK(siteKey, false)
            GK:RefreshKeepPresentation(siteKey)
        end
    end
end

-- Reprise apres GK sync ou /reload : in_progress + notre guilde mais isHolding perdu
local function TryResumeLocalKeepCapture(st, site)
    if not st or not site or st.status ~= "in_progress" or st.isHolding then return end
    if not CanStartKeepCapture(site, false) then return end
    if not CanFinishKeepCaptureBeforeWindowCloses(st, site) then return end
    -- Jamais ressusciter un assaut zombie : l'etat in_progress doit dater du siege du JOUR
    -- (fenetre ouverte, updatedAt du jour, pas marque observateur stale). Sans ce garde, un
    -- in_progress persiste d'un soir precedent redemarrait tout seul en entrant dans le carre.
    if not GK:IsCurrentKeepSiegeState(st) then return end
    if not GK:IsPlayerInKeepGeometry(site) or IsPlayerInNonCaptureState() then return end
    local guild = GK:GetLocalPlayerGuild()
    if guild == "" or not Overlord.PlayerFaction then return end
    local assaultGuild = select(1, GK.GetCanonicalAssaultGuild and GK:GetCanonicalAssaultGuild(st) or "")
    if assaultGuild == "" then
        assaultGuild = GK:SanitizeGuildName(st.ownerGuild or "")
    end
    if st.ownerFaction ~= Overlord.PlayerFaction then return end
    if not (GK.HasAssaultShardAnchor and GK:HasAssaultShardAnchor(st)) then return end
    local crossShardTakeover = false
    local wrongShard = GK.IsLocalShardBlockedFromKeepAssault
        and GK:IsLocalShardBlockedFromKeepAssault(st, site.siteKey or site.id)
    -- Reprise normale : guilde assaillante uniquement. Apres expiration du heartbeat
    -- cross-shard, une guilde alliee peut aussi porter le capteur de secours, sans changer
    -- la guilde creditee par l'Anchor.
    if assaultGuild ~= guild and not wrongShard then return end
    if wrongShard then
        local localShardId = Overlord.Shard and Overlord.Shard.GetCaptureLocalShardID
            and Overlord.Shard:GetCaptureLocalShardID(
                "keep:" .. tostring(site.siteKey or site.id), 8) or nil
        if not localShardId or not GK.GrantLocalCrossShardTakeover
            or not GK:GrantLocalCrossShardTakeover(st, localShardId, NetworkNow()) then
            return
        end
        crossShardTakeover = true
    end
    if GK.ShouldDeferToRemoteKeepCapturer
        and GK:ShouldDeferToRemoteKeepCapturer(st) then
        return
    end
    st.isHolding = true
    st.isPaused = false
    st.isContested = false
    st._gkContestStreak = nil
    st.holdAuthorityLocal = true
    st.holdStartTime = GetTime() - (tonumber(st.holdTimeElapsed) or 0)
    if GK.RememberLocalGkCapturerCandidate then
        GK:RememberLocalGkCapturerCandidate(st)
    end
    if crossShardTakeover then
        -- Reprise rare et critique : publier immediatement le nouveau heartbeat direct.
        -- L'Anchor causale reste intacte, mais les observateurs cessent de suivre le
        -- snapshot fige et le nouveau porteur peut terminer les minutes deja acquises.
        st.updatedAt = NetworkNow()
        GK:SaveKeeps()
        Overlord:MarkDirty()
        ResolveKeepAssaultAuthority(site.siteKey or site.id, st)
        BroadcastGK(site.siteKey or site.id, true)
        GK:RefreshKeepPresentation(site.siteKey or site.id, true)
    end
end

-- Un assaut ennemi peut rester fige en in_progress pour toujours quand l'assaillant disparait
-- (parti / hors ligne / autre shard) : aucun pair ne peut revert l'etat a distance (les GK/GC de
-- retour au tenant precedent sont rejetes par dessein anti-regression), donc seul un joueur
-- PHYSIQUEMENT PRESENT peut trancher. Conditions strictes pour ne jamais casser un assaut reel :
--   - assaut ennemi (faction != joueur), pas notre propre cote ; pas notre capteur/autorite
--   - joueur dans la geometrie, en etat de capture (pas monture / mort / furtif)
--   - timer pas quasi termine (sinon laisser le GC/GK reel trancher la fin)
--   - AUCUNE preuve d'assaut vivant : ni ennemi present localement, ni GK in_progress ennemi recu
--     depuis KEEP_ABANDONED_ASSAULT_SEC (cross-shard / furtif : invisible au scan mais le capteur
--     diffuse encore -> st._lastEnemyInProgressGkAt, stampe a la reception dans SyncGuildKeep)
--   - et cette absence de preuve dure de facon CONTINUE depuis KEEP_ABANDONED_ASSAULT_SEC
--     (compteur par site, repart a zero des qu'une preuve reapparait ; robuste au /reload)
-- Emet alors un abandon ancre : les pairs ne l'appliquent qu'a cette identite exacte.
function Overlord.GuildKeepControl:TryResolveAbandonedKeepAssault(siteKey, st, site)
    if not siteKey or not st or not site then return false end
    local now = NetworkNow()
    local eligible = st.status == "in_progress"
        and not st.holdAuthorityLocal and not st.isHolding
        and not GK:IsPlayerKeepAssailant(st)
        and st.ownerFaction ~= Overlord.PlayerFaction
        -- Seule la shard verrouillee peut conclure qu'un assaut a ete abandonne.
        -- Une copie stale sur une autre shard ne doit jamais fabriquer un GA.
        and (not GK.IsLocalShardBlockedFromKeepAssault
            or not GK:IsLocalShardBlockedFromKeepAssault(st, siteKey))
        and (not GK.IsSiegeWindowOpen or GK:IsSiegeWindowOpen())
        and IsWarModeActive()
        and GK:IsPlayerInKeepGeometry(site)
        and not IsPlayerInNonCaptureState()
    if eligible then
        -- Capture quasi terminee : ne pas trancher, laisser le GC/GK reel acter la fin.
        local req = GK:GetDefaultHoldTimeRequired(st, site)
        if (tonumber(st.holdTimeElapsed) or 0) >= req - 1 then
            eligible = false
        end
        -- Apres l'instant ou un GC valide a pu etre produit, un observateur qui a manque
        -- ce terminal ne peut plus distinguer un abandon d'une capture. Il demande une
        -- reparation reseau et ne fabrique jamais de GA negatif au nom de l'ancre.
        local attemptStartedAt = GK.GetCurrentAssaultAttemptStartedAt
            and GK:GetCurrentAssaultAttemptStartedAt(st) or 0
        if eligible and attemptStartedAt > 0 and now >= attemptStartedAt + req - 1 then
            keepAbandonCandidateAt[siteKey] = nil
            if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
                Overlord.Sync:PollIfStaleObserverKeep(999, siteKey)
            end
            return false
        end
    end
    if eligible then
        -- Preuve d'assaut vivant : ennemi present (meme shard) OU GK in_progress ennemi recent.
        local _, enemyCount = ScanNearbyKeepPlayers(site)
        local lastEnemyGk = tonumber(st._lastEnemyInProgressGkAt) or 0
        if (enemyCount or 0) > 0
            or (lastEnemyGk > 0 and (now - lastEnemyGk) < KEEP_ABANDONED_ASSAULT_SEC) then
            eligible = false
        end
    end
    if not eligible then
        keepAbandonCandidateAt[siteKey] = nil
        return false
    end
    -- Aucune preuve : demarrer / poursuivre la fenetre continue d'abandon.
    local since = keepAbandonCandidateAt[siteKey]
    if not since then
        keepAbandonCandidateAt[siteKey] = now
        return false
    end
    if (now - since) < KEEP_ABANDONED_ASSAULT_SEC then return false end
    keepAbandonCandidateAt[siteKey] = nil
    self:RevertCapture(siteKey, st)
    return true
end

-- Refus silencieux depuis le carre : le joueur est sur le point, rien ne se passe et rien
-- ne l'explique (retour joueur "Badlands Keep: no timer, no action"). Le message fenetre
-- fermee existait dans CanStartKeepCapture(site, true) mais etait inatteignable ici :
-- CanPlayerStartCapture echoue avant, sans notification.
local function NotifySilentKeepRefusal(siteKey, st, site)
    if not st or st.status == "in_progress" then return end
    if GK.IsSiegeWindowOpen and not GK:IsSiegeWindowOpen() then
        -- Pas de message au defenseur de son propre fortin tenu.
        if st.status == "held" and GK.CanPlayerContestKeep and not GK:CanPlayerContestKeep(st, siteKey) then
            return
        end
        NotifySiegeClosedOnPoint(siteKey)
        return
    end
    -- Fenetre ouverte, etat neutre mais tenant affiche de notre faction : refus voulu
    -- (pas de vol same-faction) mais jusqu'ici muet.
    if st.status == "neutral" and GK.GetKeepDisplayTenant and L and L.GUILD_KEEP_FACTION_HELD then
        local dg, df = GK:GetKeepDisplayTenant(st, siteKey)
        dg = GK.SanitizeGuildName and GK:SanitizeGuildName(dg or "") or (dg or "")
        local pf = Overlord.PlayerFaction
        if dg ~= "" and pf and (dg == GK:GetLocalPlayerGuild() or df == pf) then
            if factionHeldWarnedPointSiteKey ~= siteKey then
                factionHeldWarnedPointSiteKey = siteKey
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_FACTION_HELD)
            end
        end
    end
end

function Overlord.GuildKeepControl:CheckPosition(deltaTime)
    deltaTime = deltaTime or 1
    local onMap, site, mapSampleKnown = GK:IsPlayerOnKeepMap()
    if not onMap or not site then
        -- Un trou API n'est pas une sortie du point et ne rearme aucune notification.
        if mapSampleKnown then RearmKeepPointWarnings() end
        return
    end
    local siteKey = site.siteKey
    local st = GK:GetState(siteKey)

    TryResumeLocalKeepCapture(st, site)

    local inGeom, geomSampleKnown = GK:IsPlayerInKeepGeometry(site)
    if Overlord.GuildKeepImmersion and Overlord.GuildKeepImmersion.OnKeepPositionCheck then
        Overlord.GuildKeepImmersion:OnKeepPositionCheck(siteKey, site, st, inGeom)
    end
    if not inGeom then
        if not geomSampleKnown then return end
        if geomSampleKnown then RearmKeepPointWarnings(siteKey) end
        if st.holdAuthorityLocal and st.isHolding and not st.isPaused then
            st.isPaused = true
            st.isContested = false
            st._gkContestStreak = nil
        end
        if ShouldTickKeepHoldTimer(siteKey, st) then
            self:UpdateHoldTimer(siteKey, st, site, deltaTime, false)
        end
        return
    end

    -- Une ouverture de siege rearme l'alerte pour une future fermeture, meme si
    -- le joueur ne bouge pas entre les deux transitions.
    if not GK.IsSiegeWindowOpen or GK:IsSiegeWindowOpen() then
        RearmSiegeClosedPointWarning(siteKey)
    end

    -- Le hop de shard est une information d'entree, pas une action de capture : le
    -- proposer aussi a cheval/en vol/furtif, avant le rejet gameplay correspondant.
    if Overlord.Shard and Overlord.Shard.TryAutoPromptOnGuildKeepEntry then
        Overlord.Shard:TryAutoPromptOnGuildKeepEntry(siteKey, site, st)
    end

    if IsPlayerInNonCaptureState() then
        if ShouldTickKeepHoldTimer(siteKey, st) then
            self:UpdateHoldTimer(siteKey, st, site, deltaTime, true)
        end
        return
    end

    local guild = GK:GetLocalPlayerGuild()
    if guild == "" then
        local now = GetTime()
        if now - lastNoGuildWarnAt >= NO_GUILD_WARN_GAP then
            lastNoGuildWarnAt = now
            if L.GUILD_KEEP_NO_GUILD then
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_NO_GUILD)
            end
        end
        return
    end

    CheckLocalKeepDefense(siteKey, st, site)
    RequestKeepCatchupIfHudLooksStale(siteKey, st, site)

    if GK:CanPlayerStartCapture(st, true, siteKey) then
        if not st.isHolding then
            self:StartHold(siteKey, st, site)
        end
        blockedAssaultNotifiedGuild[siteKey] = nil
        blockedAssaultInactiveSince[siteKey] = nil
    elseif st.status == "in_progress" and not GK:IsPlayerKeepAssailant(st) then
        -- Assaut abandonne (assaillant disparu) : le joueur present le tranche au lieu de spammer.
        if self:TryResolveAbandonedKeepAssault(siteKey, st, site) then
            return
        end
        local assaultGuild = select(1, GK.GetCanonicalAssaultGuild and GK:GetCanonicalAssaultGuild(st) or "")
        if assaultGuild == "" then
            assaultGuild = GK:SanitizeGuildName(st.ownerGuild or "")
        end
        local inactiveSince = blockedAssaultInactiveSince[siteKey]
        if inactiveSince and GetTime() - inactiveSince >= BLOCKED_ASSAULT_REARM_QUIET_SEC then
            blockedAssaultNotifiedGuild[siteKey] = nil
        end
        blockedAssaultInactiveSince[siteKey] = nil
        -- Ne jamais annoncer un assaut sans guilde connue (etat in_progress fantome "(guild )").
        -- Une seule notification par assaut (memoire par guilde, pas par delai) : un joueur reste
        -- sur place pendant tout un siege ennemi ne doit pas revoir le meme message toutes les 45s.
        if assaultGuild ~= "" and blockedAssaultNotifiedGuild[siteKey] ~= assaultGuild
            and L and L.GUILD_KEEP_BLOCKED_ASSAULT then
            blockedAssaultNotifiedGuild[siteKey] = assaultGuild
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_BLOCKED_ASSAULT,
                GK:GetDisplayName(site), assaultGuild))
        end
    else
        -- Un snapshot held/neutral isole appartient encore a la meme vague. Re-armer
        -- seulement apres une accalmie continue, comme les alertes sync.
        if not blockedAssaultInactiveSince[siteKey] then
            blockedAssaultInactiveSince[siteKey] = GetTime()
        end
        NotifySilentKeepRefusal(siteKey, st, site)
    end
end

-- Chemin de sommeil du tick global : ne pas resoudre/saniter les six fortins
-- quand aucune capture locale ne demande de progression ou de decay.
function Overlord.GuildKeepControl:HasLocalAuthority(excludeKey)
    local states = OverlordDB and OverlordDB.guildKeeps
    if type(states) ~= "table" then return false end
    for siteKey in pairs(Overlord.GuildKeepSites or {}) do
        local st = states[siteKey]
        if siteKey ~= excludeKey and type(st) == "table"
            and st.status == "in_progress" and st.holdAuthorityLocal
            and (st.isHolding or st.isPaused) then
            return true
        end
    end
    return false
end

-- Tick decay captures locales hors carte courante (ou toutes si excludeKey = nil)
function Overlord.GuildKeepControl:TickOffMapAuthority(deltaTime, excludeKey)
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
    for siteKey, site in pairs(Overlord.GuildKeepSites or {}) do
        if siteKey ~= excludeKey then
            local st = GK:GetState(siteKey)
            if not st or st.status ~= "in_progress" then
                -- rien
            elseif ShouldTickKeepHoldTimer(siteKey, st) then
                local inGeom, sampleKnown = GK:IsPlayerInKeepGeometry(site)
                if sampleKnown then
                    self:UpdateHoldTimer(siteKey, st, site, deltaTime or 1, inGeom)
                end
            end
        end
    end
end

function Overlord.GuildKeepControl:Update(deltaTime)
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then
        return
    end

    local onMap, site = GK:IsPlayerOnKeepMap()
    if not onMap or not site then
        return
    end

    local siteKey = site.siteKey
    local st = GK:GetState(siteKey)

    self:CheckPosition(deltaTime)
    -- Progression uniquement si dans le carre actif.
    -- CheckPosition gere deja le decay hors carre et les etats non capturables.
    local inGeom = GK:IsPlayerInKeepGeometry(site)
    local canActOnKeep = inGeom
        and not IsPlayerInNonCaptureState()
        and not UnitIsDead("player")
        and not UnitIsGhost("player")
    if canActOnKeep and ShouldTickKeepHoldTimer(siteKey, st) then
        self:UpdateHoldTimer(siteKey, st, site, deltaTime or 1, true)
    end

    if Overlord.Ressources and Overlord.Ressources.RefreshGuildKeepHUD
        and Overlord.Ressources.ShouldShowGuildKeepHUD
        and Overlord.Ressources:ShouldShowGuildKeepHUD() then
        local nowHud = GetTime()
        if (nowHud - lastGkHudRefreshAt) >= GK_HUD_REFRESH_INTERVAL then
            lastGkHudRefreshAt = nowHud
            Overlord.Ressources:RefreshGuildKeepHUD()
        end
    end
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.SyncGuildKeepCaptureHud
        and Overlord.ZoneIndicator.GuildKeepHudNeedsRefresh
        and Overlord.ZoneIndicator:GuildKeepHudNeedsRefresh() then
        Overlord.ZoneIndicator:SyncGuildKeepCaptureHud()
    end
end
