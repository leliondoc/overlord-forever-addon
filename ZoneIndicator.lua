-- ZoneIndicator.lua - HUD midscreen : prochain objectif + guidage vers la zone
Overlord = Overlord or {}
Overlord.ZoneIndicator = {}

local L = Overlord.L

local indicatorFrame = nil
local hudUserDismissed = false
local indicatorDragActive = false
-- Cache FindActiveZone : evite un scan C_Map sur toute la DB chaque seconde (5.4.14+).
local cachedActiveZone = nil
local cachedActiveZoneAt = 0
local cachedActiveZoneMapID = nil
local cachedActiveZoneQx = nil
local cachedActiveZoneQy = nil
local FIND_ACTIVE_ZONE_CACHE_SEC = 1.0
local lastGkIndicatorKey = nil
local lastOpIndicatorKey = nil
local lastZoneIndicatorKey = nil
local lastOutpostCaptureHudSyncAt = 0
local autoWaypointZone = nil
local autoWaypointFrontId = nil
local autoWaypointSuppressedKey = nil
local autoWaypointLastDesiredKey = nil

local function ReadPlayerMapQuantized(mapID)
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil, nil end
    local px, py = pos:GetXY()
    if px == nil or py == nil or (px == 0 and py == 0) then return nil, nil end
    return math.floor(px * 1000), math.floor(py * 1000)
end

local function ReadPlayerMapDistance(mapID, zx, zy, aspect)
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local px, py = pos:GetXY()
    if px == nil or py == nil or (px == 0 and py == 0) then return nil end
    px, py = px * 100, py * 100
    local dx = zx - px
    local dy = (zy - py) * aspect
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

local function GetPlayerMapCacheKey()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil, nil, nil end
    local ok2, qx, qy = pcall(ReadPlayerMapQuantized, mapID)
    if not ok2 then return mapID, nil, nil end
    -- ~0,1 % carte : invalide au deplacement sans rescanner a chaque frame.
    return mapID, qx, qy
end

local function StoreActiveZoneCache(zone, now, mapID, qx, qy)
    cachedActiveZone = zone
    cachedActiveZoneAt = now
    cachedActiveZoneMapID = mapID
    cachedActiveZoneQx = qx
    cachedActiveZoneQy = qy
end

function Overlord.ZoneIndicator:InvalidateActiveZoneCache()
    cachedActiveZone = nil
    cachedActiveZoneAt = 0
    cachedActiveZoneMapID = nil
    cachedActiveZoneQx = nil
    cachedActiveZoneQy = nil
    lastGkIndicatorKey = nil
    lastOpIndicatorKey = nil
    lastZoneIndicatorKey = nil
end

function Overlord.ZoneIndicator:IsHudVisible()
    return indicatorFrame and indicatorFrame:IsShown()
end
-- Bandeau arene BfA : le blason depasse au-dessus du cadre logique (~32 px).
local IND_CHROME_TOP_OVERHANG = 32
local IND_BELOW_ANCHOR_GAP = 2
local IND_PAD_TOP = 40
local IND_PAD_BOTTOM = 8
local IND_LINE_GAP = 4
local IND_DISTANCE_DROP = 7
local IND_TIMER_DROP = 3
local HUD_ENABLED_ALPHA = 1
local HUD_DISABLED_ALPHA = 0.42

local function ApplySharedHudChrome(frame)
    if Overlord.Ressources and Overlord.Ressources.ApplyTopHudChrome then
        Overlord.Ressources:ApplyTopHudChrome(frame, 0.9)
        return
    end
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    frame:SetBackdropColor(0.10, 0.10, 0.16, 0.92)
    frame:SetBackdropBorderColor(0.85, 0.68, 0.20, 0.9)
end

local IND_DEFAULT_TOP_Y = -(IND_CHROME_TOP_OVERHANG + IND_BELOW_ANCHOR_GAP)

local function IsIndicatorUserPlaced()
    return OverlordDB and OverlordDB.zoneIndicatorUserPlaced == true
end

local function EnableIndicatorDrag()
    if not indicatorFrame then return end
    indicatorFrame:SetMovable(true)
    indicatorFrame:RegisterForDrag("LeftButton", "RightButton")
end

-- Convertit l'ancre actuelle (parfois relative a goldHudRoot en mode empile) en un point
-- absolu par rapport a UIParent, AVANT de commencer un drag. Sans ca, StopMovingOrSizing
-- renvoie des offsets relatifs a goldHudRoot ("BOTTOM") que ApplySavedIndicatorPosition
-- reappliquait ensuite par rapport a UIParent : la position sauvee ne correspondait plus
-- du tout a l'endroit lache par le joueur ("il se remet en haut tout seul").
local function LockIndicatorToAbsoluteScreenPoint()
    if not indicatorFrame then return end
    local left, top = indicatorFrame:GetLeft(), indicatorFrame:GetTop()
    if not left or not top then return end
    local scale = indicatorFrame:GetEffectiveScale()
    local uiScale = UIParent:GetEffectiveScale()
    local x = left * scale / uiScale
    local y = top * scale / uiScale
    indicatorFrame:ClearAllPoints()
    indicatorFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    indicatorFrame._olLayoutMode = nil
end

local function SaveIndicatorPosition()
    if not indicatorFrame or not OverlordDB then return end
    local point, _, relPoint, x, y = indicatorFrame:GetPoint(1)
    if not point then return end
    OverlordDB.zoneIndicatorPos = {
        point = point,
        relPoint = relPoint or "TOPLEFT",
        x = x or 0,
        y = y or 0,
    }
    OverlordDB.zoneIndicatorUserPlaced = true
end

local function ApplySavedIndicatorPosition()
    if not indicatorFrame then return end
    local w = (Overlord.Ressources and Overlord.Ressources.GetHudPanelWidth
        and Overlord.Ressources:GetHudPanelWidth()) or 280
    local pos = OverlordDB and OverlordDB.zoneIndicatorPos
    local point = pos and (pos.point or "TOPLEFT") or "TOP"
    local relPoint = pos and (pos.relPoint or "BOTTOMLEFT") or "TOP"
    local x = pos and (pos.x or 0) or 0
    local y = pos and (pos.y or 0) or IND_DEFAULT_TOP_Y
    local key = point .. ":" .. relPoint .. ":" .. tostring(x) .. ":" .. tostring(y)
        .. ":" .. tostring(w)
    if indicatorFrame._olLayoutMode == "saved" and indicatorFrame._olLayoutKey == key then
        return
    end
    indicatorFrame._olLayoutMode = "saved"
    indicatorFrame._olLayoutKey = key
    indicatorFrame:ClearAllPoints()
    indicatorFrame:SetWidth(w)
    EnableIndicatorDrag()
    if pos then
        -- Toujours ancre a UIParent (jamais a goldHudRoot) : coherent avec ce qui a ete
        -- sauvegarde via LockIndicatorToAbsoluteScreenPoint.
        indicatorFrame:SetPoint(point, UIParent, relPoint, x, y)
    else
        indicatorFrame:SetPoint(point, UIParent, relPoint, x, y)
    end
end

-- Position par defaut en haut d'ecran (hors cluster or).
function Overlord.ZoneIndicator:RepositionDetached()
    if IsIndicatorUserPlaced() then
        ApplySavedIndicatorPosition()
        return
    end
    if not indicatorFrame then return end
    local w = (Overlord.Ressources and Overlord.Ressources.GetHudPanelWidth
        and Overlord.Ressources:GetHudPanelWidth()) or 280
    if indicatorFrame._olLayoutMode == "detached" and indicatorFrame._olLayoutWidth == w then
        return
    end
    indicatorFrame._olLayoutMode = "detached"
    indicatorFrame._olLayoutWidth = w
    indicatorFrame._olLayoutKey = nil
    indicatorFrame:ClearAllPoints()
    indicatorFrame:SetWidth(w)
    indicatorFrame:SetPoint("TOP", UIParent, "TOP", 0, IND_DEFAULT_TOP_Y)
    EnableIndicatorDrag()
end

-- Empile sous le cluster or ; ignore si le joueur a deplace l'indicateur lui-meme.
local function ApplyAutoStackIndicatorPosition()
    if not indicatorFrame then return end
    local anchor = Overlord.Ressources and Overlord.Ressources.GetGoldHUDStackBottom
        and Overlord.Ressources:GetGoldHUDStackBottom() or nil
    if indicatorFrame._olLayoutMode == "stack" and indicatorFrame._olLayoutAnchor == anchor then
        return
    end
    indicatorFrame._olLayoutMode = "stack"
    indicatorFrame._olLayoutAnchor = anchor
    indicatorFrame._olLayoutKey = nil
    indicatorFrame:ClearAllPoints()
    if anchor then
        indicatorFrame:SetPoint("TOP", anchor, "BOTTOM", 0, -(IND_CHROME_TOP_OVERHANG + IND_BELOW_ANCHOR_GAP))
        EnableIndicatorDrag()
    else
        indicatorFrame:SetPoint("TOP", UIParent, "TOP", 0, IND_DEFAULT_TOP_Y)
        EnableIndicatorDrag()
    end
end

function Overlord.ZoneIndicator:RepositionInStack()
    if not indicatorFrame or indicatorDragActive then return end
    if IsIndicatorUserPlaced() then
        ApplySavedIndicatorPosition()
        return
    end
    ApplyAutoStackIndicatorPosition()
end

-- RefreshHud : ne reancre pas un indicateur deplace manuellement (evite le snap 1 Hz en haut).
function Overlord.ZoneIndicator:EnsureIndicatorLayout()
    if not indicatorFrame or IsIndicatorUserPlaced() or indicatorDragActive then return end
    self:RepositionInStack()
end

local function SetIndicatorHudEnabled(enabled)
    if not indicatorFrame then return end
    local nextEnabled = enabled ~= false
    if indicatorFrame._hudEnabled == nextEnabled then return end
    indicatorFrame._hudEnabled = nextEnabled
    indicatorFrame:SetAlpha(indicatorFrame._hudEnabled and HUD_ENABLED_ALPHA or HUD_DISABLED_ALPHA)
    if indicatorFrame._hudEnabled then
        indicatorFrame:EnableMouse(true)
    else
        indicatorFrame:EnableMouse(false)
    end
end

local function GetCurrentFrontId()
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    return front and front.id
end

local function AutoWaypointEnabled()
    return OverlordDB and OverlordDB.config
        and OverlordDB.config.autoWaypointNextObjective == true
end

local function AutoWaypointKey(zone, frontId)
    if not zone or not zone.id then return nil end
    return tostring(frontId or "") .. ":" .. tostring(zone.id)
end

function Overlord.ZoneIndicator:ClearAutoObjectiveWaypoint()
    if autoWaypointZone and Overlord.MapMarkers
        and Overlord.MapMarkers.ClearUserWaypointForFrontZone then
        Overlord.MapMarkers:ClearUserWaypointForFrontZone(autoWaypointZone, autoWaypointFrontId)
    end
    autoWaypointZone = nil
    autoWaypointFrontId = nil
end

function Overlord.ZoneIndicator:ResetAutoWaypointSuppression()
    autoWaypointSuppressedKey = nil
end

function Overlord.ZoneIndicator:SyncAutoObjectiveWaypoint(zone, frontId)
    if not AutoWaypointEnabled() or not Overlord.InActiveFront
        or not zone or zone.status ~= "available" then
        self:ClearAutoObjectiveWaypoint()
        autoWaypointLastDesiredKey = nil
        return
    end
    if not Overlord.MapMarkers or not Overlord.MapMarkers.SetUserWaypointForFrontZone then
        return
    end

    local key = AutoWaypointKey(zone, frontId)
    if not key then
        return
    end

    if autoWaypointLastDesiredKey ~= key then
        autoWaypointSuppressedKey = nil
        autoWaypointLastDesiredKey = key
    end

    if autoWaypointZone and AutoWaypointKey(autoWaypointZone, autoWaypointFrontId) ~= key then
        self:ClearAutoObjectiveWaypoint()
    end

    if autoWaypointSuppressedKey == key then
        return
    end

    if autoWaypointZone and AutoWaypointKey(autoWaypointZone, autoWaypointFrontId) == key
        and Overlord.MapMarkers.UserWaypointMatchesFrontZone then
        if Overlord.MapMarkers:UserWaypointMatchesFrontZone(zone, frontId) then
            return
        end
        -- Le joueur a retire ou remplace le repere : ne pas le reposer avant changement d'objectif.
        autoWaypointSuppressedKey = key
        autoWaypointZone = nil
        autoWaypointFrontId = nil
        return
    end

    local ok = Overlord.MapMarkers:SetUserWaypointForFrontZone(zone, frontId, {
        noToggle = true,
        silent = true,
    })
    if ok then
        autoWaypointZone = zone
        autoWaypointFrontId = frontId
    end
end

function Overlord.ZoneIndicator:OnAutoWaypointSettingChanged(enabled)
    self:ResetAutoWaypointSuppression()
    if enabled then
        self:RefreshHud()
    else
        self:ClearAutoObjectiveWaypoint()
    end
end

-- Repere carte : fortin, avant-poste ou zone de front active
local function PlaceIndicatorWaypoint()
    if not indicatorFrame then return end
    local zone = indicatorFrame.hudTarget
    if zone and zone._guildKeep then
        local site = zone._keepSite
            or (Overlord.GuildKeep and Overlord.GuildKeep.GetDefaultSite and Overlord.GuildKeep:GetDefaultSite())
        if site and Overlord.MapMarkers and Overlord.MapMarkers.SetUserWaypointForGuildKeepSite then
            Overlord.MapMarkers:SetUserWaypointForGuildKeepSite(site)
            return
        end
    end
    if zone and zone._outpost then
        local site = zone._outpostSite
            or (Overlord.Outpost and Overlord.Outpost.GetSite
                and Overlord.Outpost:GetSite(zone._outpostSiteKey))
        if site and Overlord.MapMarkers and Overlord.MapMarkers.SetUserWaypointForOutpostSite then
            Overlord.MapMarkers:SetUserWaypointForOutpostSite(site)
            return
        end
    end
    if not zone then
        zone = Overlord.ZoneIndicator:FindActiveZone()
    end
    local frontId = GetCurrentFrontId()
    if zone and Overlord.MapMarkers and Overlord.MapMarkers.SetUserWaypointForFrontZone then
        Overlord.MapMarkers:SetUserWaypointForFrontZone(zone, frontId)
    end
end

local function IsLocallyHolding()
    if Overlord.GuildKeep then
        local onMap, site = Overlord.GuildKeep:IsPlayerOnKeepMap()
        if onMap and site then
            local st = Overlord.GuildKeep:GetState(site.siteKey)
            if st and st.isHolding then return true end
        end
    end
    if not Overlord.ZoneDatabase then return false end
    local cz = Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone
        and Overlord.Zones:GetCurrentPlayerZone()
    if cz and cz.isHolding then return true end
    local frontId = GetCurrentFrontId()
    if frontId and Overlord.Zones and Overlord.Zones.GetDisplayOrderForFront then
        for _, zone in ipairs(Overlord.Zones:GetDisplayOrderForFront(frontId)) do
            if zone.isHolding then return true end
        end
        return false
    end
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        if zone.isHolding then return true end
    end
    return false
end

-- Verifie legerement si le HUD front pourrait s'afficher (evite FindActiveZone 1 Hz quand rien a montrer).
local function FrontHasVisibleHudCandidate(frontId, holdingCached)
    if holdingCached == nil then holdingCached = IsLocallyHolding() end
    if holdingCached then return true end
    if Overlord.Zones and Overlord.Zones.GetNextObjectiveZone then
        local nextZ = Overlord.Zones:GetNextObjectiveZone(frontId)
        if nextZ and nextZ.status == "available" then return true end
    end
    if not frontId or not Overlord.Zones or not Overlord.Zones.GetDisplayOrderForFront then
        return false
    end
    for _, zone in ipairs(Overlord.Zones:GetDisplayOrderForFront(frontId)) do
        if zone.status == "in_progress" then
            if not zone._guildKeep then return true end
            if Overlord.GuildKeep and Overlord.GuildKeep.IsSiegeWindowOpen
                and Overlord.GuildKeep:IsSiegeWindowOpen() then
                return true
            end
        end
    end
    return false
end

-- Cible HUD midscreen pour le fortin (etat lu en direct dans UpdateIndicator)
local function BuildGuildKeepHudTarget(site)
    if not site then return nil end
    return {
        _guildKeep = true,
        _keepSite = site,
        _keepSiteKey = site.siteKey,
        name = Overlord.GuildKeep:GetDisplayName(site),
        center = site.center,
        radius = (Overlord.GuildKeep.GetKeepCaptureHalfSizePercent
            and Overlord.GuildKeep:GetKeepCaptureHalfSizePercent(site))
            or site.halfSize or 1.35,
    }
end

-- Synchronise status / timer depuis GetState (evite snapshot BuildGuildKeepHudTarget)
local function RefreshGuildKeepHudLiveFields(activeZone)
    if not activeZone or not activeZone._guildKeep or not Overlord.GuildKeep then return activeZone end
    local key = activeZone._keepSiteKey or (activeZone._keepSite and activeZone._keepSite.siteKey)
    local site = activeZone._keepSite or Overlord.GuildKeep:GetSite(key)
    local st = Overlord.GuildKeep:GetState(key)
    if not site or not st then return activeZone end
    activeZone._keepSite = site
    activeZone._keepState = st
    activeZone.status = st.status
    activeZone.isHolding = st.isHolding
    activeZone.isPaused = st.isPaused
    activeZone.isContested = st.isContested or false
    activeZone.holdTimeRequired = (Overlord.GuildKeep and Overlord.GuildKeep.GetDefaultHoldTimeRequired
        and Overlord.GuildKeep:GetDefaultHoldTimeRequired(st, site))
        or (Overlord.GuildKeep and Overlord.GuildKeep.DEFAULT_HOLD_TIME_REQUIRED)
        or 900
    return activeZone
end

-- visible = panneau capture dans le carre ; monture/furtif = texte dedie (pas alpha 0.42 des fronts)
local function EvaluateGuildKeepHud()
    if not Overlord.GuildKeep or Overlord.InstanceSuspended then
        return false, false, nil
    end
    local onMap, site
    if Overlord.GuildKeep.GetPlayerKeepSiteForHud then
        onMap, site = Overlord.GuildKeep:GetPlayerKeepSiteForHud()
    else
        onMap, site = Overlord.GuildKeep:IsPlayerOnKeepMap()
    end
    if not onMap or not site then return false, false, nil end
    local st = Overlord.GuildKeep:GetState(site.siteKey)
    if not st then return false, false, nil end
    -- Sur la carte du fortin sans etre dans le carre = pas de HUD capture.
    local inHudGeometry = Overlord.GuildKeep.IsPlayerInKeepGeometryForHud
        and Overlord.GuildKeep:IsPlayerInKeepGeometryForHud(site)
        or Overlord.GuildKeep:IsPlayerInKeepGeometry(site)
    if not inHudGeometry then
        return false, false, nil
    end
    local siteKey = site and site.siteKey
    local canParticipate = st.isHolding or Overlord.GuildKeep:CanPlayerStartCapture(st, nil, siteKey)
        or Overlord.GuildKeep:CanPlayerAssaultKeepState(st, siteKey)
        or Overlord.GuildKeep:CanPlayerObserveKeepSiege(st, siteKey)
        or Overlord.GuildKeep:IsPlayerDefendingHeldKeep(st, siteKey)
    if not canParticipate then
        return false, false, nil
    end
    return true, true, BuildGuildKeepHudTarget(site)
end

-- Cible HUD midscreen pour avant-poste (front actif ou site open-world autonome, 24/7)
local function BuildOutpostHudTarget(site)
    if not site then return nil end
    return {
        _outpost = true,
        _outpostSite = site,
        _outpostSiteKey = site.siteKey,
        name = Overlord.Outpost:GetDisplayName(site),
        center = site.center,
        radius = site.halfSize or 1.35,
    }
end

local function RefreshOutpostHudLiveFields(activeZone)
    if not activeZone or not activeZone._outpost or not Overlord.Outpost then return activeZone end
    local key = activeZone._outpostSiteKey or (activeZone._outpostSite and activeZone._outpostSite.siteKey)
    local site = activeZone._outpostSite or Overlord.Outpost:GetSite(key)
    local st = Overlord.Outpost:GetState(key)
    if not site or not st then return activeZone end
    activeZone._outpostSite = site
    activeZone._outpostState = st
    activeZone.status = st.status
    activeZone.owner = st.ownerFaction
    activeZone.holdTimeElapsed = tonumber(st.holdTimeElapsed) or 0
    activeZone.isHolding = st.isHolding
    activeZone.isPaused = st.isPaused
    activeZone.isContested = st.isContested or false
    activeZone.holdTimeRequired = (Overlord.Outpost.GetDefaultHoldTimeRequired
        and Overlord.Outpost:GetDefaultHoldTimeRequired(st, site))
        or Overlord.Outpost.DEFAULT_HOLD_TIME_REQUIRED
        or 300
    return activeZone
end

local outpostHudEvalCache = { at = -1, visible = false, inGeom = false, target = nil }
local OUTPOST_HUD_EVAL_CACHE_SEC = 0.05

local function EvaluateOutpostHud()
    if not Overlord.Outpost or Overlord.InstanceSuspended then
        return false, false, nil
    end
    local onMap, site = Overlord.Outpost:IsPlayerOnOutpostMap()
    if not onMap or not site then return false, false, nil end
    local st = Overlord.Outpost:GetState(site.siteKey)
    if not st then return false, false, nil end
    if not Overlord.Outpost:IsPlayerInOutpostGeometry(site) then
        return false, false, nil
    end
    local canParticipate = st.isHolding or Overlord.Outpost:CanPlayerStartCapture(st)
        or Overlord.Outpost:CanPlayerAssaultOutpostState(st)
        or Overlord.Outpost:IsPlayerDefendingHeldOutpost(st)
    if not canParticipate then
        return false, false, nil
    end
    return true, true, BuildOutpostHudTarget(site)
end

local function EvaluateOutpostHudCached()
    if Overlord.InstanceSuspended then return false, false, nil end
    local now = GetTime()
    local cacheAge = now - outpostHudEvalCache.at
    if cacheAge >= 0 and cacheAge <= OUTPOST_HUD_EVAL_CACHE_SEC then
        return outpostHudEvalCache.visible, outpostHudEvalCache.inGeom, outpostHudEvalCache.target
    end
    local visible, inGeom, target = EvaluateOutpostHud()
    outpostHudEvalCache.at = now
    outpostHudEvalCache.visible = visible
    outpostHudEvalCache.inGeom = inGeom
    outpostHudEvalCache.target = target
    return visible, inGeom, target
end

local function IsSquareCaptureHud(activeZone)
    return activeZone and (activeZone._guildKeep or activeZone._outpost)
end

-- Panneau capture fortin visible (meme logique que EvaluateGuildKeepHud)
function Overlord.ZoneIndicator:ShouldRefreshGuildKeepCaptureHud()
    return select(1, EvaluateGuildKeepHud())
end

-- 1 Hz sur carte fortin : refresh timer ou masque si plus dans le carre
function Overlord.ZoneIndicator:SyncGuildKeepCaptureHud()
    if Overlord.InActiveFront or Overlord.InstanceSuspended then return end
    if self:ShouldRefreshGuildKeepCaptureHud() then
        self:RefreshHud()
    elseif indicatorFrame and indicatorFrame:IsShown() then
        self:Hide()
    end
end

-- Evite RefreshHud 1 Hz quand le panneau fortin n'a rien a faire (ex. capture distante)
function Overlord.ZoneIndicator:GuildKeepHudNeedsRefresh()
    if Overlord.InActiveFront or not Overlord.GuildKeep then return false end
    -- Panneau ouvert : re-evaluer chaque tick pour masquer si sortie du carre / fin decay
    if indicatorFrame and indicatorFrame:IsShown() then
        return true
    end
    local onMap, site
    if Overlord.GuildKeep.GetPlayerKeepSiteForHud then
        onMap, site = Overlord.GuildKeep:GetPlayerKeepSiteForHud()
    else
        onMap, site = Overlord.GuildKeep:IsPlayerOnKeepMap()
    end
    if not onMap or not site then return false end
    local inHudGeometry = Overlord.GuildKeep.IsPlayerInKeepGeometryForHud
        and Overlord.GuildKeep:IsPlayerInKeepGeometryForHud(site)
        or Overlord.GuildKeep:IsPlayerInKeepGeometry(site)
    if inHudGeometry then
        return select(1, EvaluateGuildKeepHud())
    end
    -- Observateur sur la carte du fortin : rafraichir si un assaut distant est connu.
    local st = Overlord.GuildKeep:GetState(site.siteKey)
    if st and Overlord.GuildKeep.CanPlayerObserveKeepSiege
        and Overlord.GuildKeep:CanPlayerObserveKeepSiege(st, site.siteKey) then
        return true
    end
    return false
end

function Overlord.ZoneIndicator:ShouldRefreshOutpostCaptureHud()
    return select(1, EvaluateOutpostHudCached())
end

function Overlord.ZoneIndicator:SyncOutpostCaptureHud()
    if Overlord.InstanceSuspended then return end
    if select(1, EvaluateOutpostHudCached()) then
        lastOutpostCaptureHudSyncAt = GetTime()
        self:RefreshHud()
    elseif indicatorFrame and indicatorFrame:IsShown()
        and indicatorFrame.hudTarget and indicatorFrame.hudTarget._outpost then
        self:Hide()
    end
end

function Overlord.ZoneIndicator:WasOutpostCaptureHudSyncedRecently(threshold)
    return (GetTime() - lastOutpostCaptureHudSyncAt) < (threshold or 0.5)
end

function Overlord.ZoneIndicator:OutpostHudNeedsRefresh()
    if not Overlord.Outpost then return false end
    if indicatorFrame and indicatorFrame:IsShown()
        and indicatorFrame.hudTarget and indicatorFrame.hudTarget._outpost then
        return true
    end
    return select(1, EvaluateOutpostHudCached())
end

function Overlord.ZoneIndicator:FrontLateIndicatorNeedsRefresh()
    if Overlord:IsPlayerDeadOrGhost() then return false end
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then return false end
    if Overlord.Outpost and Overlord.Outpost:IsPlayerOnOutpostMap() then
        return not self:WasOutpostCaptureHudSyncedRecently(0.5)
    end
    local frontId = GetCurrentFrontId()
    local holding = IsLocallyHolding()
    if not FrontHasVisibleHudCandidate(frontId, holding) then return false end
    if not indicatorFrame or not indicatorFrame:IsShown() then return true end
    local target = indicatorFrame.hudTarget
    if not target or target._guildKeep or target._outpost then return true end
    if target.status == "available" and not holding then return false end
    return true
end

function Overlord.ZoneIndicator:GetDistanceToOutpost(site)
    if not site or not site.center then return nil end
    local mapID = site.mapID
    if not mapID then
        local ok, mid = pcall(C_Map.GetBestMapForUnit, "player")
        if not ok or not mid then return nil end
        mapID = mid
    end
    local zx, zy = site.center[1], site.center[2]
    local ar = (Overlord.Outpost and Overlord.Outpost.GetMapAspectRatio)
        and Overlord.Outpost:GetMapAspectRatio(site) or 1
    local ok3, distance, dx, dy = pcall(ReadPlayerMapDistance, mapID, zx, zy, ar)
    if not ok3 then return nil end
    return distance, dx, dy
end

function Overlord.ZoneIndicator:GetDistanceToGuildKeep(site)
    if not site or not site.center then return nil end
    local mapID = site.mapID
    if not mapID then
        local ok, mid = pcall(C_Map.GetBestMapForUnit, "player")
        if not ok or not mid then return nil end
        mapID = mid
    end
    local zx, zy = site.center[1], site.center[2]
    local ar = (Overlord.GuildKeep and Overlord.GuildKeep.GetMapAspectRatio)
        and Overlord.GuildKeep:GetMapAspectRatio(site) or 1
    local ok3, distance, dx, dy = pcall(ReadPlayerMapDistance, mapID, zx, zy, ar)
    if not ok3 then return nil end
    return distance, dx, dy
end

-- Initialise l'indicateur
function Overlord.ZoneIndicator:Initialize()
    self:CreateIndicatorFrame()
end

-- Cree le frame indicateur
function Overlord.ZoneIndicator:CreateIndicatorFrame()
    if indicatorFrame then return end
    local panelW = (Overlord.Ressources and Overlord.Ressources.GetHudPanelWidth
        and Overlord.Ressources:GetHudPanelWidth()) or 280
    indicatorFrame = CreateFrame("Button", "OverlordZoneIndicator", UIParent, "BackdropTemplate")
    indicatorFrame:SetSize(panelW, 88)
    if indicatorFrame.SetClipsChildren then indicatorFrame:SetClipsChildren(false) end
    if Overlord.UI and Overlord.UI.ApplyScenarioArenaBannerChrome then
        Overlord.UI.ApplyScenarioArenaBannerChrome(indicatorFrame, {
            width = panelW,
            keepTopPx = 118,
            trimBottomPx = 6,
            cropSidePx = 8,
            wingPad = 12,
            crestLift = 8,
            alpha = 1,
        })
    else
        ApplySharedHudChrome(indicatorFrame)
    end
    indicatorFrame:SetFrameStrata("HIGH")
    indicatorFrame:EnableMouse(true)
    indicatorFrame:SetMovable(true)
    indicatorFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    indicatorFrame:SetScript("OnDragStart", function(self)
        if self:IsMovable() then
            indicatorDragActive = true
            -- Detache d'un eventuel ancrage a goldHudRoot avant de bouger : garantit que
            -- StopMovingOrSizing renverra une position relative a UIParent, coherente avec
            -- ce que ApplySavedIndicatorPosition restaure ensuite.
            LockIndicatorToAbsoluteScreenPoint()
            self:StartMoving()
        end
    end)
    indicatorFrame:SetScript("OnDragStop", function(self)
        if self:IsMovable() then
            self:StopMovingOrSizing()
            indicatorDragActive = false
            SaveIndicatorPosition()
        end
    end)
    EnableIndicatorDrag()
    indicatorFrame:SetClampedToScreen(true)
    indicatorFrame:Hide()

    indicatorFrame:SetScript("OnClick", function(_, button)
        if button == "RightButton" then return end
        PlaceIndicatorWaypoint()
    end)
    indicatorFrame:SetScript("OnEnter", function(self)
        if not L.INDICATOR_CLICK_WAYPOINT or L.INDICATOR_CLICK_WAYPOINT == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(L.INDICATOR_CLICK_WAYPOINT, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    indicatorFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Titre (dans le ruban du bandeau scenario)
    local title = indicatorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", indicatorFrame, "TOP", 0, -IND_PAD_TOP)
    title:SetShadowOffset(2, -2)
    title:SetText(L.INDICATOR_TITLE)
    indicatorFrame.title = title

    -- Nom de la zone
    local zoneName = indicatorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneName:SetPoint("TOP", title, "BOTTOM", 0, -IND_LINE_GAP)
    zoneName:SetShadowOffset(1, -1)
    zoneName:SetText("")
    indicatorFrame.zoneName = zoneName

    -- Distance / statut
    local distance = indicatorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    distance:SetPoint("TOP", zoneName, "BOTTOM", 0, -(IND_LINE_GAP + IND_DISTANCE_DROP))
    distance:SetShadowOffset(1, -1)
    distance:SetText("")
    indicatorFrame.distance = distance

    -- Timer de capture (mm:ss / mm:ss)
    local timer = indicatorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timer:SetPoint("TOP", distance, "BOTTOM", 0, -(IND_LINE_GAP + IND_TIMER_DROP))
    timer:SetShadowOffset(1, -1)
    timer:SetText("")
    indicatorFrame.timer = timer

    -- Bouton pour cacher (custom, pas UIPanelCloseButton qui cause du taint)
    local hideBtn = CreateFrame("Button", nil, indicatorFrame)
    hideBtn:SetSize(16, 16)
    hideBtn:SetPoint("TOPRIGHT", -4, -10)
    hideBtn:SetNormalFontObject("GameFontNormalSmall")
    hideBtn:SetText("X")
    hideBtn:SetScript("OnClick", function()
        hudUserDismissed = true
        Overlord.ZoneIndicator:Hide()
    end)
    hideBtn:SetScript("OnEnter", function(btn)
        btn:SetText("|cFFFF4444X|r")
    end)
    hideBtn:SetScript("OnLeave", function(btn)
        btn:SetText("X")
    end)

    self:RepositionInStack()
end

-- Calcule la distance entre le joueur et une zone (avec correction d'aspect ratio)
function Overlord.ZoneIndicator:GetDistanceToZone(zone)
    if not zone or not zone.center then return nil end

    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil end
    local front = Overlord.Fronts and Overlord.Fronts:ResolveFrontByMapID(mapID)
    if not front then return nil end
    local playMapID = front.resolvedMapID or (Overlord.Fronts.GetMapID and Overlord.Fronts:GetMapID(front.id)) or mapID

    local zx, zy = zone.center[1], zone.center[2]
    local ar = Overlord.Zones:GetMapAspectRatio()
    local ok3, distance, dx, dy = pcall(ReadPlayerMapDistance, playMapID, zx, zy, ar)
    if not ok3 then return nil end
    return distance, dx, dy
end

-- Zone a afficher : position joueur > capture en cours > prochain objectif (chaine prereq)
function Overlord.ZoneIndicator:FindActiveZone(forceRefresh)
    local now = GetTime()
    local mapID, qx, qy = GetPlayerMapCacheKey()
    if not forceRefresh and cachedActiveZone and (now - cachedActiveZoneAt) < FIND_ACTIVE_ZONE_CACHE_SEC
        and cachedActiveZoneMapID == mapID and cachedActiveZoneQx == qx and cachedActiveZoneQy == qy then
        return cachedActiveZone
    end

    if Overlord.Outpost then
        local onMap = Overlord.Outpost:IsPlayerOnOutpostMap()
        if onMap then
            local outVisible, _, outTarget = EvaluateOutpostHudCached()
            if outVisible and outTarget then
                StoreActiveZoneCache(outTarget, now, mapID, qx, qy)
                return outTarget
            end
        end
    end

    local currentZone = Overlord.Zones:GetCurrentPlayerZone()
    if currentZone and (currentZone.status == "available" or currentZone.status == "in_progress") then
        StoreActiveZoneCache(currentZone, now, mapID, qx, qy)
        return currentZone
    end

    local bestZone = nil
    local bestDist = math.huge
    local bestPrio = 0

    local scanZones = Overlord.ZoneDatabase
    local frontId = GetCurrentFrontId()
    if frontId and Overlord.Zones and Overlord.Zones.GetDisplayOrderForFront then
        scanZones = Overlord.Zones:GetDisplayOrderForFront(frontId) or scanZones
    end

    local soleInProgress = nil
    local inProgressCount = 0
    for _, zone in ipairs(scanZones) do
        if zone.status == "in_progress" and not zone._guildKeep then
            inProgressCount = inProgressCount + 1
            soleInProgress = zone
            if inProgressCount > 1 then break end
        end
    end
    if inProgressCount == 1 and soleInProgress then
        -- Ne prend le raccourci que si la distance reste calculable (meme carte) ;
        -- sinon repli sur la boucle complete (comportement d'origine : ignore la zone
        -- si le joueur n'est pas sur une carte compatible, retombe sur nextObjective).
        if self:GetDistanceToZone(soleInProgress) ~= nil then
            StoreActiveZoneCache(soleInProgress, now, mapID, qx, qy)
            return soleInProgress
        end
    end

    for _, zone in ipairs(scanZones) do
        local prio = 0
        if zone.status == "in_progress" then prio = 2
        elseif zone.status == "available" then prio = 1 end

        if prio > 0 then
            local dist = self:GetDistanceToZone(zone)
            if dist ~= nil then
                if prio > bestPrio or (prio == bestPrio and dist < bestDist) then
                    bestZone = zone
                    bestDist = dist
                    bestPrio = prio
                end
            end
        end
    end

    if bestZone and bestZone.status == "in_progress" then
        StoreActiveZoneCache(bestZone, now, mapID, qx, qy)
        return bestZone
    end

    if frontId and Overlord.Zones and Overlord.Zones.GetNextObjectiveZone then
        local nextZ = Overlord.Zones:GetNextObjectiveZone(frontId)
        if nextZ then
            StoreActiveZoneCache(nextZ, now, mapID, qx, qy)
            return nextZ
        end
    end

    StoreActiveZoneCache(bestZone, now, mapID, qx, qy)
    return bestZone
end

-- Formate un nombre de secondes en "m:ss"
local function FormatTime(seconds)
    seconds = math.floor(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function EnsureIndicatorTextAnchors()
    if not indicatorFrame or indicatorFrame._olTextAnchorsReady then return end
    indicatorFrame._olTextAnchorsReady = true
    indicatorFrame.zoneName:ClearAllPoints()
    indicatorFrame.zoneName:SetPoint("TOP", indicatorFrame.title, "BOTTOM", 0, -IND_LINE_GAP)
end

local function SetIndicatorHeight(height)
    if not indicatorFrame or indicatorFrame._olIndicatorHeight == height then return end
    indicatorFrame._olIndicatorHeight = height
    indicatorFrame:SetHeight(height)
end

-- Met a jour l'indicateur (activeZone optionnel : evite un second FindActiveZone depuis RefreshHud).
function Overlord.ZoneIndicator:UpdateIndicator(activeZone)
    if not indicatorFrame or not indicatorFrame:IsShown() then return end
    indicatorFrame.hudTarget = activeZone
    local isSquareHud = IsSquareCaptureHud(activeZone)
    if not Overlord.InActiveFront and not isSquareHud then
        self:Hide()
        return
    end

    if not activeZone then
        activeZone = self:FindActiveZone()
    end

    if not activeZone then
        self:Hide()
        return
    end

    if not activeZone._guildKeep and not activeZone._outpost
        and Overlord.IsLoginZoneDisplayPending
        and Overlord:IsLoginZoneDisplayPending(activeZone) then
        local pendingKey = "sync|" .. tostring(activeZone.id or activeZone.name or "")
        if lastZoneIndicatorKey == pendingKey then return end
        lastZoneIndicatorKey = pendingKey
        lastGkIndicatorKey = nil
        lastOpIndicatorKey = nil
        EnsureIndicatorTextAnchors()
        indicatorFrame.title:SetText(L.MAP_SYNC_PENDING or "SYNC")
        indicatorFrame.title:SetTextColor(0.75, 0.75, 0.70)
        indicatorFrame.zoneName:SetText(activeZone.name or "")
        indicatorFrame.zoneName:SetTextColor(0.65, 0.68, 0.70)
        indicatorFrame.distance:SetText("")
        indicatorFrame.timer:Hide()
        SetIndicatorHeight(IND_PAD_TOP + IND_PAD_BOTTOM + 16 + IND_LINE_GAP + 12)
        return
    end

    if activeZone._guildKeep then
        activeZone = RefreshGuildKeepHudLiveFields(activeZone)
    elseif activeZone._outpost then
        activeZone = RefreshOutpostHudLiveFields(activeZone)
    end

    local hudDisabled = indicatorFrame and indicatorFrame._hudEnabled == false
    local dim = 0.55

    local dist
    if activeZone._guildKeep and activeZone._keepSite then
        dist = self:GetDistanceToGuildKeep(activeZone._keepSite)
    elseif activeZone._outpost and activeZone._outpostSite then
        dist = self:GetDistanceToOutpost(activeZone._outpostSite)
    else
        dist = self:GetDistanceToZone(activeZone)
    end
    local guidanceOnly = not isSquareHud
        and (activeZone.status == "available" and not activeZone.isHolding)

    if guidanceOnly then
        local guidanceKey = "guide|" .. tostring(activeZone.id or activeZone.name or "")
        if lastZoneIndicatorKey == guidanceKey then return end
        lastZoneIndicatorKey = guidanceKey
        lastGkIndicatorKey = nil
        lastOpIndicatorKey = nil
        EnsureIndicatorTextAnchors()
        indicatorFrame.title:SetText(L.NEXT_OBJECTIVE_HEADER or L.INDICATOR_TITLE)
        indicatorFrame.title:SetTextColor(0.95, 0.82, 0.30)
        indicatorFrame.zoneName:SetText(activeZone.name)
        local o = (Overlord.MapMarkers and Overlord.MapMarkers.NEXT_OBJECTIVE_COLOR) or { 0.95, 0.82, 0.30 }
        indicatorFrame.zoneName:SetTextColor(o[1], o[2], o[3])
        indicatorFrame.distance:SetText("")
        indicatorFrame.timer:Hide()
        SetIndicatorHeight(IND_PAD_TOP + IND_PAD_BOTTOM + 16 + IND_LINE_GAP + 12)
        return
    end

    local inCaptureGeom = false
    if activeZone._guildKeep and activeZone._keepSite and Overlord.GuildKeep then
        inCaptureGeom = Overlord.GuildKeep.IsPlayerInKeepGeometryForHud
            and Overlord.GuildKeep:IsPlayerInKeepGeometryForHud(activeZone._keepSite)
            or Overlord.GuildKeep:IsPlayerInKeepGeometry(activeZone._keepSite)
    elseif activeZone._outpost and activeZone._outpostSite and Overlord.Outpost then
        inCaptureGeom = Overlord.Outpost:IsPlayerInOutpostGeometry(activeZone._outpostSite)
    elseif dist ~= nil then
        inCaptureGeom = dist < activeZone.radius
    end

    local blockCap = false
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync then
        if isSquareHud or activeZone.status == "in_progress" then
            blockCap = Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync()
        end
    end

    if activeZone._guildKeep then
        local elapsedKey = 0
        if activeZone.status == "in_progress" and activeZone._keepState
            and activeZone._keepSite and Overlord.GuildKeep then
            elapsedKey = math.floor(Overlord.GuildKeep:GetObserverHoldTimeElapsed(
                activeZone._keepState, activeZone._keepSite, inCaptureGeom))
        end
        local distKey = dist and math.floor(dist * 10) or (inCaptureGeom and "in" or "out")
        local keepState = activeZone._keepState
        local keepSiteKey = activeZone._keepSite
            and (activeZone._keepSite.siteKey or activeZone._keepSite.id) or ""
        local tenantGuild, tenantFaction = "", ""
        local siegeLabel = ""
        if keepState and Overlord.GuildKeep then
            tenantGuild, tenantFaction = Overlord.GuildKeep:GetKeepDisplayTenant(
                keepState, keepSiteKey)
            if Overlord.GuildKeep.GetKeepSiegeMapLabel then
                siegeLabel = Overlord.GuildKeep:GetKeepSiegeMapLabel(keepState, keepSiteKey) or ""
            end
        end
        local localDefenseActive = keepState and keepState.gkLocalDefenseSeenAt
            and (GetTime() - keepState.gkLocalDefenseSeenAt) < 10
        local indicatorKey = string.format("gk|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s",
            tostring(keepSiteKey),
            activeZone.status or "",
            activeZone.isContested and 1 or 0,
            activeZone.isPaused and 1 or 0,
            blockCap and 1 or 0,
            inCaptureGeom and 1 or 0,
            elapsedKey,
            tostring(distKey),
            tostring(activeZone.name or ""),
            tostring(tenantGuild or ""),
            tostring(tenantFaction or ""),
            tostring(siegeLabel),
            localDefenseActive and 1 or 0)
        if lastGkIndicatorKey == indicatorKey then return end
        lastGkIndicatorKey = indicatorKey
        lastOpIndicatorKey = nil
    elseif activeZone._outpost then
        local elapsedKey = 0
        if activeZone.status == "in_progress" and activeZone._outpostState
            and activeZone._outpostSite and Overlord.Outpost then
            elapsedKey = math.floor(Overlord.Outpost:GetObserverHoldTimeElapsed(
                activeZone._outpostState, activeZone._outpostSite))
        end
        local distKey = dist and math.floor(dist * 10) or (inCaptureGeom and "in" or "out")
        local indicatorKey = string.format("op|%s|%s|%s|%s|%s|%s|%s",
            activeZone.status or "",
            activeZone.isContested and 1 or 0,
            activeZone.isPaused and 1 or 0,
            blockCap and 1 or 0,
            inCaptureGeom and 1 or 0,
            elapsedKey,
            tostring(distKey))
        if lastOpIndicatorKey == indicatorKey then return end
        lastOpIndicatorKey = indicatorKey
        lastGkIndicatorKey = nil
        lastZoneIndicatorKey = nil
    elseif not activeZone._guildKeep and not activeZone._outpost then
        local elapsedKey = 0
        if activeZone.status == "in_progress" then
            if Overlord.Zones and Overlord.Zones.GetObserverHoldTimeElapsed then
                elapsedKey = math.floor(Overlord.Zones:GetObserverHoldTimeElapsed(activeZone))
            else
                elapsedKey = math.floor(activeZone.holdTimeElapsed or 0)
            end
        end
        local distKey = dist and math.floor(dist * 10) or (inCaptureGeom and "in" or "out")
        local indicatorKey = string.format("z|%s|%s|%s|%s|%s|%s|%s|%s",
            activeZone.id or activeZone.name or "",
            activeZone.status or "",
            activeZone.isContested and 1 or 0,
            activeZone.isPaused and 1 or 0,
            blockCap and 1 or 0,
            inCaptureGeom and 1 or 0,
            elapsedKey,
            tostring(distKey))
        if lastZoneIndicatorKey == indicatorKey then return end
        lastZoneIndicatorKey = indicatorKey
        lastGkIndicatorKey = nil
        lastOpIndicatorKey = nil
    else
        lastGkIndicatorKey = nil
        lastOpIndicatorKey = nil
        lastZoneIndicatorKey = nil
    end

    EnsureIndicatorTextAnchors()
    if activeZone._guildKeep then
        local kstTitle = activeZone._keepState
        if kstTitle and kstTitle.status == "held" and Overlord.GuildKeep
            and Overlord.GuildKeep:IsPlayerDefendingHeldKeep(kstTitle,
                activeZone._keepSite and activeZone._keepSite.siteKey) then
            indicatorFrame.title:SetText(
                L.GUILD_KEEP_DEFENSE_TITLE or L.GUILD_KEEP_INDICATOR_TITLE or L.INDICATOR_TITLE)
        else
            indicatorFrame.title:SetText(L.GUILD_KEEP_INDICATOR_TITLE or L.INDICATOR_TITLE)
        end
    elseif activeZone._outpost then
        local ostTitle = activeZone._outpostState
        if ostTitle and ostTitle.status == "held" and Overlord.Outpost
            and Overlord.Outpost:IsPlayerDefendingHeldOutpost(ostTitle) then
            indicatorFrame.title:SetText(
                L.OUTPOST_DEFENSE_TITLE or L.OUTPOST_INDICATOR_TITLE or L.INDICATOR_TITLE)
        else
            indicatorFrame.title:SetText(L.OUTPOST_INDICATOR_TITLE or L.INDICATOR_TITLE)
        end
    else
        indicatorFrame.title:SetText(L.INDICATOR_TITLE)
    end
    if hudDisabled and not isSquareHud then
        indicatorFrame.title:SetTextColor(dim, dim, dim)
    else
        indicatorFrame.title:SetTextColor(1, 1, 1)
    end

    if hudDisabled and not isSquareHud then
        indicatorFrame.zoneName:SetText(activeZone.name)
        indicatorFrame.zoneName:SetTextColor(dim, dim, dim)
        indicatorFrame.distance:SetText(L.INDICATOR_HUD_DISABLED or "Return to the capture zone.")
        indicatorFrame.distance:SetTextColor(dim, dim, dim, 1)
    elseif dist ~= nil or inCaptureGeom then
        indicatorFrame.zoneName:SetText(activeZone.name)
        indicatorFrame.zoneName:SetTextColor(1, 1, 1)

        local inGeomForHud = inCaptureGeom
        if dist ~= nil and activeZone.radius and not activeZone._guildKeep and not activeZone._outpost then
            inGeomForHud = dist < activeZone.radius
        end

        if inGeomForHud and blockCap and (isSquareHud or activeZone.status == "in_progress") then
            local capMsg = L.INDICATOR_DISMOUNT_TO_CAPTURE
            if IsStealthed and IsStealthed() and L.INDICATOR_STEALTH_TO_CAPTURE then
                capMsg = L.INDICATOR_STEALTH_TO_CAPTURE
            end
            indicatorFrame.distance:SetText(capMsg)
            indicatorFrame.distance:SetTextColor(1, 0.55, 0.2, 1)
        elseif inCaptureGeom and not blockCap then
            local assaultReady = false
            if activeZone._guildKeep and activeZone._keepState and Overlord.GuildKeep then
                local kst = activeZone._keepState
                if kst.status == "in_progress" and Overlord.GuildKeep.IsCurrentKeepSiegeState
                    and Overlord.GuildKeep:IsCurrentKeepSiegeState(kst)
                    and Overlord.GuildKeep.GetKeepSiegeMapLabel then
                    local siegeLabel = Overlord.GuildKeep:GetKeepSiegeMapLabel(kst,
                        activeZone._keepSite and activeZone._keepSite.siteKey)
                    if siegeLabel and siegeLabel ~= "" then
                        indicatorFrame.distance:SetText(siegeLabel)
                        if kst.ownerFaction and Overlord.PlayerFaction and kst.ownerFaction ~= Overlord.PlayerFaction then
                            indicatorFrame.distance:SetTextColor(1, 0.35, 0.2, 1)
                        else
                            indicatorFrame.distance:SetTextColor(1, 0.82, 0.2, 1)
                        end
                        assaultReady = true
                    end
                elseif kst.status == "held" and Overlord.GuildKeep:CanPlayerStartCapture(kst, nil,
                    activeZone._keepSite and activeZone._keepSite.siteKey)
                    and Overlord.GuildKeep:IsSiegeWindowOpen()
                    and L.GUILD_KEEP_ASSAULT_READY then
                    assaultReady = true
                    local reqMin = math.floor((kst.holdTimeRequired or 900) / 60)
                    indicatorFrame.distance:SetText(string.format(L.GUILD_KEEP_ASSAULT_READY, reqMin))
                    indicatorFrame.distance:SetTextColor(1, 0.82, 0.2, 1)
                elseif kst.status == "held" and Overlord.GuildKeep:IsPlayerDefendingHeldKeep(kst,
                    activeZone._keepSite and activeZone._keepSite.siteKey)
                    and L.GUILD_KEEP_ON_POINT then
                    -- Defense locale : ennemis vus dans le carre (GuildKeepControl), avant
                    -- meme que le GK in_progress ennemi soit arrive par le reseau.
                    local underLocalAttack = kst.gkLocalDefenseSeenAt
                        and (GetTime() - kst.gkLocalDefenseSeenAt) < 10
                    if underLocalAttack and L.GUILD_KEEP_DEFEND_UNDER_ATTACK then
                        indicatorFrame.distance:SetText(L.GUILD_KEEP_DEFEND_UNDER_ATTACK)
                        indicatorFrame.distance:SetTextColor(1, 0.25, 0.25, 1)
                    else
                        indicatorFrame.distance:SetText(L.GUILD_KEEP_ON_POINT)
                        indicatorFrame.distance:SetTextColor(0, 1, 0, 1)
                    end
                    assaultReady = true
                end
            elseif activeZone._outpost and activeZone._outpostState and Overlord.Outpost then
                local ost = activeZone._outpostState
                if ost.status == "held" and Overlord.Outpost:CanPlayerStartCapture(ost)
                    and L.OUTPOST_ASSAULT_READY then
                    assaultReady = true
                    local reqMin = math.floor((ost.holdTimeRequired or Overlord.Outpost.DEFAULT_HOLD_TIME_REQUIRED or 300) / 60)
                    indicatorFrame.distance:SetText(string.format(L.OUTPOST_ASSAULT_READY, reqMin))
                    indicatorFrame.distance:SetTextColor(1, 0.82, 0.2, 1)
                elseif ost.status == "held" and Overlord.Outpost:IsPlayerDefendingHeldOutpost(ost)
                    and L.OUTPOST_ON_POINT then
                    assaultReady = true
                    indicatorFrame.distance:SetText(L.OUTPOST_ON_POINT)
                    indicatorFrame.distance:SetTextColor(0, 1, 0, 1)
                end
            end
            if not assaultReady then
                indicatorFrame.distance:SetText(L.IN_THE_ZONE)
                indicatorFrame.distance:SetTextColor(0, 1, 0, 1)
            end
        elseif dist ~= nil then
            indicatorFrame.distance:SetText(string.format(L.DISTANCE_FORMAT, dist * 25))
            indicatorFrame.distance:SetTextColor(1, 1, 1, 1)
        end
    else
        indicatorFrame.zoneName:SetText(activeZone.name)
        indicatorFrame.zoneName:SetTextColor(1, 1, 1)
        indicatorFrame.distance:SetText(string.format(L.COORDS_FORMAT,
            activeZone.center[1], activeZone.center[2]))
    end

    local showTimer = false
    local showHeldAssaultHint = false
    if activeZone._guildKeep and activeZone._keepState and activeZone.status == "held"
        and Overlord.GuildKeep and Overlord.GuildKeep:CanPlayerStartCapture(activeZone._keepState, nil,
            activeZone._keepSite and activeZone._keepSite.siteKey)
        and Overlord.GuildKeep:IsSiegeWindowOpen() and inCaptureGeom and not hudDisabled then
        local dg = select(1, Overlord.GuildKeep:GetKeepDisplayTenant(activeZone._keepState,
            activeZone._keepSite and activeZone._keepSite.siteKey))
        if dg ~= "" and L.GUILD_KEEP_PANEL_HELD then
            indicatorFrame.timer:SetText(string.format(L.GUILD_KEEP_PANEL_HELD, dg))
            indicatorFrame.timer:SetTextColor(1, 0.82, 0.2)
            showHeldAssaultHint = true
        end
    elseif activeZone._guildKeep and activeZone._keepState and activeZone.status == "held"
        and Overlord.GuildKeep and Overlord.GuildKeep:IsPlayerDefendingHeldKeep(activeZone._keepState,
            activeZone._keepSite and activeZone._keepSite.siteKey)
        and inCaptureGeom and not hudDisabled then
        local kstHeld = activeZone._keepState
        local dg = select(1, Overlord.GuildKeep:GetKeepDisplayTenant(kstHeld,
            activeZone._keepSite and activeZone._keepSite.siteKey))
        if dg ~= "" and L.GUILD_KEEP_PANEL_HELD then
            indicatorFrame.timer:SetText(string.format(L.GUILD_KEEP_PANEL_HELD, dg))
            if kstHeld.gkLocalDefenseSeenAt and (GetTime() - kstHeld.gkLocalDefenseSeenAt) < 10 then
                indicatorFrame.timer:SetTextColor(1, 0.25, 0.25)
            else
                indicatorFrame.timer:SetTextColor(0.3, 0.9, 0.3)
            end
            showHeldAssaultHint = true
        end
    elseif activeZone._outpost and activeZone._outpostState and activeZone.status == "held"
        and Overlord.Outpost and Overlord.Outpost:IsPlayerDefendingHeldOutpost(activeZone._outpostState)
        and inCaptureGeom and not hudDisabled then
        local dg = select(1, Overlord.Outpost:GetOutpostDisplayTenant(activeZone._outpostState,
            activeZone._outpostSite and activeZone._outpostSite.siteKey))
        if dg ~= "" and L.OUTPOST_PANEL_HELD then
            indicatorFrame.timer:SetText(string.format(L.OUTPOST_PANEL_HELD, dg))
            indicatorFrame.timer:SetTextColor(0.3, 0.9, 0.3)
            showHeldAssaultHint = true
        end
    elseif activeZone.status == "in_progress" and not hudDisabled
        and (not activeZone._guildKeep or not Overlord.GuildKeep
            or (activeZone._keepState and Overlord.GuildKeep.IsCurrentKeepSiegeState
                and Overlord.GuildKeep:IsCurrentKeepSiegeState(activeZone._keepState))) then
        local elapsed
        if activeZone._outpost and activeZone._outpostState and activeZone._outpostSite and Overlord.Outpost then
            elapsed = Overlord.Outpost:GetObserverHoldTimeElapsed(activeZone._outpostState, activeZone._outpostSite)
        elseif activeZone._guildKeep and activeZone._keepState and activeZone._keepSite and Overlord.GuildKeep then
            elapsed = Overlord.GuildKeep:GetObserverHoldTimeElapsed(
                activeZone._keepState, activeZone._keepSite, inCaptureGeom)
        else
            elapsed = (Overlord.Zones and Overlord.Zones.GetObserverHoldTimeElapsed)
                and Overlord.Zones:GetObserverHoldTimeElapsed(activeZone)
                or (activeZone.holdTimeElapsed or 0)
        end
        local required = activeZone.holdTimeRequired
        if not required then
            if activeZone._outpost and Overlord.Outpost then
                required = Overlord.Outpost.DEFAULT_HOLD_TIME_REQUIRED or 300
            elseif activeZone._guildKeep and Overlord.GuildKeep then
                required = Overlord.GuildKeep.DEFAULT_HOLD_TIME_REQUIRED or 900
            else
                required = 300
            end
        end
        if required > 0 then
            showTimer = true
            local pct = math.min(elapsed / required, 1)
            indicatorFrame.timer:SetText(FormatTime(elapsed) .. " / " .. FormatTime(required))
            if pct < 0.5 then
                indicatorFrame.timer:SetTextColor(1.0, 0.82, 0.0)
            else
                indicatorFrame.timer:SetTextColor(1.0 - (pct - 0.5) * 1.4, 1.0, 0.0)
            end
            if activeZone.isContested then
                indicatorFrame.timer:SetTextColor(1.0, 0.2, 0.2)
            end
        end
    end

    local showExtraLine = showTimer or showHeldAssaultHint
    if showExtraLine then
        if not indicatorFrame._olTimerAnchored then
            indicatorFrame._olTimerAnchored = true
            indicatorFrame.timer:ClearAllPoints()
            indicatorFrame.timer:SetPoint(
                "TOP", indicatorFrame.distance, "BOTTOM", 0, -(IND_LINE_GAP + IND_TIMER_DROP))
        end
        if not indicatorFrame.timer:IsShown() then indicatorFrame.timer:Show() end
    else
        if indicatorFrame.timer:IsShown() then indicatorFrame.timer:Hide() end
    end
    -- Hauteur = padding haut/bas + lignes (repere : tooltip au survol, pas dans le cadre)
    local lineTitle, lineBody, lineTimer = 16, 12, 12
    local h = IND_PAD_TOP + IND_PAD_BOTTOM + lineTitle + IND_LINE_GAP + lineBody
        + IND_LINE_GAP + IND_DISTANCE_DROP + lineBody
    if showExtraLine then
        h = h + IND_LINE_GAP + lineTimer + IND_TIMER_DROP
    end
    SetIndicatorHeight(h)
end

-- Affiche / met a jour le HUD midscreen selon le front et l'objectif
function Overlord.ZoneIndicator:RefreshHud()
    if Overlord:IsPlayerDeadOrGhost() then
        if indicatorFrame and indicatorFrame:IsShown() then
            indicatorFrame:Hide()
        end
        return
    end
    if Overlord.InstanceSuspended then
        self:SyncAutoObjectiveWaypoint(nil, nil)
        if indicatorFrame and indicatorFrame:IsShown() then
            self:Hide()
        end
        return
    end

    -- Sites autonomes hors front : l'avant-poste a priorite sur le fortin si les
    -- deux detections se chevauchent exceptionnellement.
    if not Overlord.InActiveFront then
        self:SyncAutoObjectiveWaypoint(nil, nil)
        if hudUserDismissed then
            if indicatorFrame and indicatorFrame:IsShown() then
                self:Hide()
            end
            return
        end
        local outVisible, _, outTarget = EvaluateOutpostHudCached()
        local keepVisible, _, keepTarget = EvaluateGuildKeepHud()
        local visible = outVisible or keepVisible
        local hudTarget = outVisible and outTarget or keepTarget
        if not visible then
            self:Hide()
            return
        end
        if not indicatorFrame then
            self:CreateIndicatorFrame()
        end
        if not indicatorFrame:IsShown() then
            indicatorFrame:Show()
        end
        -- Capture carree : alpha pleine ; monture/furtif geres dans UpdateIndicator.
        SetIndicatorHudEnabled(true)
        self:EnsureIndicatorLayout()
        self:UpdateIndicator(hudTarget)
        return
    end

    if hudUserDismissed then
        self:SyncAutoObjectiveWaypoint(nil, nil)
        if indicatorFrame and indicatorFrame:IsShown() then
            self:Hide()
        end
        return
    end

    local frontId = GetCurrentFrontId()
    local holding = IsLocallyHolding()
    if indicatorFrame and not indicatorFrame:IsShown() and not holding
        and not FrontHasVisibleHudCandidate(frontId, holding) then
        self:SyncAutoObjectiveWaypoint(nil, frontId)
        return
    end

    local outVisible, _, outTarget = false, false, nil
    if Overlord.Outpost and Overlord.Outpost:IsPlayerOnOutpostMap() then
        outVisible, _, outTarget = EvaluateOutpostHudCached()
    end
    if outVisible and outTarget then
        if not indicatorFrame then
            self:CreateIndicatorFrame()
        end
        if not indicatorFrame:IsShown() then
            indicatorFrame:Show()
        end
        SetIndicatorHudEnabled(true)
        self:EnsureIndicatorLayout()
        self:UpdateIndicator(outTarget)
        return
    end

    local resolvedActiveZone = holding and self:FindActiveZone() or nil
    local activeZone = resolvedActiveZone
    local nextZ = (not holding and Overlord.Zones and Overlord.Zones.GetNextObjectiveZone)
        and Overlord.Zones:GetNextObjectiveZone(frontId) or nil
    if not holding and nextZ and nextZ.status == "available" then
        self:SyncAutoObjectiveWaypoint(nextZ, frontId)
    else
        self:SyncAutoObjectiveWaypoint(nil, frontId)
    end
    local shouldShow = false
    if holding then
        shouldShow = true
        activeZone = resolvedActiveZone or self:FindActiveZone()
    elseif nextZ and nextZ.status == "available" then
        shouldShow = true
        activeZone = nextZ
    else
        activeZone = resolvedActiveZone or self:FindActiveZone()
        shouldShow = activeZone and activeZone.status == "in_progress"
            and (not activeZone._guildKeep or (Overlord.GuildKeep
                and Overlord.GuildKeep.IsSiegeWindowOpen
                and Overlord.GuildKeep:IsSiegeWindowOpen()))
    end

    if not shouldShow then
        if indicatorFrame and indicatorFrame:IsShown() then
            self:Hide()
        end
        return
    end

    if not indicatorFrame then
        self:CreateIndicatorFrame()
    end
    if not indicatorFrame:IsShown() then
        indicatorFrame:Show()
    end
    SetIndicatorHudEnabled(true)
    self:EnsureIndicatorLayout()
    self:UpdateIndicator(activeZone)
end

-- Affiche l'indicateur (commande / capture)
function Overlord.ZoneIndicator:Show()
    if not indicatorFrame then
        self:CreateIndicatorFrame()
    end
    hudUserDismissed = false
    indicatorFrame:Show()
    SetIndicatorHudEnabled(true)
    self:EnsureIndicatorLayout()
    self:InvalidateActiveZoneCache()
    local outVisible, _, outTarget = EvaluateOutpostHudCached()
    local keepVisible, _, keepTarget = EvaluateGuildKeepHud()
    local squareTarget = outVisible and outTarget or (keepVisible and keepTarget or nil)
    if squareTarget then
        SetIndicatorHudEnabled(true)
        self:EnsureIndicatorLayout()
        self:UpdateIndicator(squareTarget)
    else
        self:UpdateIndicator(self:FindActiveZone(true))
    end
end

function Overlord.ZoneIndicator:Hide()
    if indicatorFrame then
        indicatorFrame.hudTarget = nil
        indicatorFrame:Hide()
    end
    lastGkIndicatorKey = nil
    lastOpIndicatorKey = nil
    lastZoneIndicatorKey = nil
end

local ghostIndicatorWasShown = false

-- Cache l'indicateur « Prochain objectif » pendant mort/fantome (ne touche pas hudUserDismissed).
function Overlord.ZoneIndicator:SuppressForGhost()
    if not indicatorFrame then return end
    ghostIndicatorWasShown = indicatorFrame:IsShown()
    if ghostIndicatorWasShown then
        indicatorFrame:Hide()
    end
end

function Overlord.ZoneIndicator:RestoreAfterGhost()
    if ghostIndicatorWasShown then
        ghostIndicatorWasShown = false
        self:RefreshHud()
    else
        ghostIndicatorWasShown = false
    end
end

function Overlord.ZoneIndicator:Toggle()
    if not indicatorFrame then
        self:Show()
        return
    end

    if indicatorFrame:IsShown() then
        hudUserDismissed = true
        self:Hide()
    else
        hudUserDismissed = false
        self:Show()
    end
end
