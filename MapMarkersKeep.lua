-- MapMarkersKeep.lua - Fortins + avant-postes carte (chunk hors MapMarkers.lua, limite 200 locals)
Overlord = Overlord or {}
Overlord.MapMarkers = Overlord.MapMarkers or {}

local L = Overlord.L
local NEUTRAL_WARFRONT_ATLAS = "Warfronts-BaseMapIcons-Empty-Tower"
local ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B = 0.85, 0.75, 0.45

local MM = Overlord.MapMarkers

local function GetCanvas()
    local canvas, parent = MM:GetWorldMapCanvas()
    return canvas
end

local function GetOverlayParent()
    local _, parent = MM:GetWorldMapCanvas()
    return parent
end

local function GetOverlayPoint(canvas, parent, x, yDown)
    return MM:GetWorldMapOverlayPoint(canvas, parent, x, yDown)
end

local function PlaceMapPinCenter(pin, parent, ox, oy, iconSize)
    return MM:PlaceWorldMapPin(pin, parent, ox, oy, iconSize)
end

local function ClearMapPinLayoutCache(pin)
    MM:ClearWorldMapPinLayout(pin)
end

local function SafeSetPassThroughButtons(frame)
    MM:QueuePassThroughButtons(frame)
end

local function PlaceMinimapPinCenter(pin, pinX, pinY)
    MM:PlaceMinimapPinCenter(pin, pinX, pinY)
end

local function ResolveResourceMinimapMapID(mapID, isResourceMapID)
    return MM:ResolveResourceMinimapMapIDFor(mapID, isResourceMapID)
end

local function GetPlayerPositionForResourceMap(mapID)
    return MM:GetPlayerPositionOnResourceMap(mapID)
end

local function CalcResourceYardsPerPct(tbl, mapID)
    MM:CalcResourceYardsPerPctFor(tbl, mapID)
end

local function HideResourceMinimapPins(pins)
    MM:HideResourceMinimapPinsTable(pins)
end

local function GetMinePositionOnContinentMap(mine, continentMapID)
    return MM:GetMinePositionOnContinentMap(mine, continentMapID)
end

local function GetEKDominanceLogoSize(canvas, parent)
    return MM:GetEKDominanceLogoSizeFor(canvas, parent)
end

local function GetTrackedMapID()
    return MM:GetTrackedMapID()
end

local worldMapOverlayMode = nil

-- ============ Pins fortins de guilde sur la minimap (icone atlas, meme driver que mines / forets) ============

local minimapKeepPins = {}
local keepYardsPerPct = {}
local keepResolvedSourceMapID = nil
local keepResolvedMapID = nil
local KEEP_MINIMAP_ICON_MIN = 34
local KEEP_MINIMAP_ICON_MAX = 44

local AddKeepNeutralTooltipLines

local function GetKeepIconAtlas(st, site, displayMapID)
    if not st or not Overlord.GuildKeep then return NEUTRAL_WARFRONT_ATLAS end
    return Overlord.GuildKeep:GetKeepMapIconAtlas(st, site, displayMapID)
end

local function GetOutpostIconAtlas(st, site, displayMapID)
    if not st or not Overlord.Outpost then return NEUTRAL_WARFRONT_ATLAS end
    return Overlord.Outpost:GetOutpostMapIconAtlas(st, site, displayMapID)
end

local function CreateMinimapKeepIconPin()
    local pin = CreateFrame("Frame", nil, Minimap)
    pin:SetFrameStrata("MEDIUM")
    pin:SetFrameLevel(6)

    local icon = pin:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    pin.icon = icon

    pcall(function()
        local mmClip = pin:CreateMaskTexture()
        mmClip:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall",
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mmClip:SetPoint("TOPLEFT", Minimap, "TOPLEFT")
        mmClip:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT")
        icon:AddMaskTexture(mmClip)
    end)

    pin:Hide()
    return pin
end

local function StyleMinimapKeepIconPin(pin, iconSz, st, site, mapID)
    if pin._olSz ~= iconSz then
        pin:SetSize(iconSz, iconSz)
        pin.icon:SetSize(iconSz, iconSz)
        pin._olSz = iconSz
    end
    local atlas = GetKeepIconAtlas(st, site, mapID)
    if pin._olLastAtlas ~= atlas then
        pin.icon:SetAtlas(atlas)
        pin._olLastAtlas = atlas
    end
    if Overlord.GuildKeep then
        local vr, vg, vb = Overlord.GuildKeep:GetKeepIconVertexColor(st, site, mapID)
        if pin._olVR ~= vr or pin._olVG ~= vg or pin._olVB ~= vb then
            pin.icon:SetVertexColor(vr, vg, vb)
            pin._olVR, pin._olVG, pin._olVB = vr, vg, vb
        end
    end
end

local function UpdateMinimapKeepIconPin(pin, site, mapID, px, py, yppX, yppY, pxPerYard, halfMM,
    rotateMM, sinF, cosF)
    if not pin or not site or not site.center then return end
    local dx = (site.center[1] - px) * yppX
    local dy = (site.center[2] - py) * yppY
    local pinX = dx * pxPerYard
    local pinY = -dy * pxPerYard
    if rotateMM then
        pinX, pinY = pinX * cosF - pinY * sinF, pinX * sinF + pinY * cosF
    end

    local avgYPP = (yppX + yppY) / 2
    local iconSz = math.max(KEEP_MINIMAP_ICON_MIN,
        math.min(KEEP_MINIMAP_ICON_MAX, avgYPP * 1.15 * pxPerYard))
    local dist = math.sqrt(pinX * pinX + pinY * pinY)
    if dist - iconSz / 2 > halfMM then
        if pin:IsShown() then pin:Hide() end
        return
    end

    local st = Overlord.GuildKeep and Overlord.GuildKeep:GetState(site.siteKey)
    StyleMinimapKeepIconPin(pin, iconSz, st, site, mapID)
    PlaceMinimapPinCenter(pin, pinX, pinY)
    if not pin:IsShown() then pin:Show() end
end

local function ShowKeepMinimapTooltip(site)
    if not site or not Overlord.GuildKeep then return end
    local st = Overlord.GuildKeep:GetState(site.siteKey)
    local tp = Overlord.UI and Overlord.UI.TooltipPalette and Overlord.UI.TooltipPalette() or nil
    local hr, hg, hb = tp and tp.HL[1] or 1, tp and tp.HL[2] or 0.82, tp and tp.HL[3] or 0
    GameTooltip:AddLine(Overlord.GuildKeep:GetDisplayName(site), hr, hg, hb)
    local dg = select(1, Overlord.GuildKeep:GetKeepDisplayTenant(st, site and site.siteKey))
    local siegeActive = st and Overlord.GuildKeep.IsCurrentKeepSiegeState
        and Overlord.GuildKeep:IsCurrentKeepSiegeState(st)
    if siegeActive then
        local siegeLabel = Overlord.GuildKeep.GetKeepSiegeMapLabel
            and Overlord.GuildKeep:GetKeepSiegeMapLabel(st, site and site.siteKey)
            or (L.GUILD_KEEP_CAPTURING or "Capturing...")
        GameTooltip:AddLine(siegeLabel, 1, 0.55, 0.2)
    elseif dg ~= "" then
        GameTooltip:AddLine(dg, tp and tp.BODY[1] or 1, tp and tp.BODY[2] or 1, tp and tp.BODY[3] or 1)
    else
        GameTooltip:AddLine(L.GUILD_KEEP_NEUTRAL or "Unclaimed", tp and tp.MUTED[1] or 0.7, tp and tp.MUTED[2] or 0.7, tp and tp.MUTED[3] or 0.7)
        AddKeepNeutralTooltipLines(st, tp, site and site.siteKey)
    end
    if Overlord.GuildKeepImmersion and Overlord.GuildKeepImmersion.AppendKeepTooltipLines then
        Overlord.GuildKeepImmersion:AppendKeepTooltipLines(st, site, site.siteKey)
    end
    GameTooltip:Show()
end

-- Tooltip vivant : l'etat d'un fortin peut changer pendant que la souris reste sur le pin
-- (assaut qui demarre, capture, retour a neutre) ; le tooltip construit une seule fois au
-- OnEnter restait fige sur l'etat perime. Reconstruction throttlee a 1 s, active UNIQUEMENT
-- tant que le tooltip appartient au pin (OnUpdate retire des la sortie : cout nul au repos).
local function StopLiveKeepTooltip(pin)
    pin._gkTipElapsed = 0
    pin:SetScript("OnUpdate", nil)
    if GameTooltip:IsShown() and GameTooltip:GetOwner() == pin then
        GameTooltip:Hide()
    end
end

local function AttachLiveKeepTooltip(pin, rebuild)
    -- Closure OnUpdate creee UNE fois par pin (pas par survol) : regle perf du projet.
    local function onTipUpdate(s, dt)
        s._gkTipElapsed = (s._gkTipElapsed or 0) + dt
        if s._gkTipElapsed < 1 then return end
        s._gkTipElapsed = 0
        if not s:IsVisible() or not GameTooltip:IsShown() or GameTooltip:GetOwner() ~= s then
            StopLiveKeepTooltip(s)
            return
        end
        GameTooltip:ClearLines()
        rebuild(s)
    end
    pin:HookScript("OnEnter", function(self)
        self._gkTipElapsed = 0
        self:SetScript("OnUpdate", onTipUpdate)
    end)
    pin:HookScript("OnLeave", function(self)
        StopLiveKeepTooltip(self)
    end)
    pin:HookScript("OnHide", function(self)
        StopLiveKeepTooltip(self)
    end)
end

local keepMinimapDbCache = nil

local function BuildKeepMinimapDatabase()
    if keepMinimapDbCache then return keepMinimapDbCache end
    local list = {}
    if not Overlord.GuildKeepSites then
        keepMinimapDbCache = list
        return list
    end
    for key, site in pairs(Overlord.GuildKeepSites) do
        if site and site.center and site.mapID then
            site.id = site.id or site.siteKey or key
            site.siteKey = site.siteKey or key
            list[#list + 1] = site
        end
    end
    table.sort(list, function(a, b)
        return (a.siteKey or a.id or "") < (b.siteKey or b.id or "")
    end)
    keepMinimapDbCache = list
    return list
end

local function KeepMinimapIsMapID(mapID)
    if not Overlord.GuildKeep then return false end
    local site = Overlord.GuildKeep:ResolveSiteByMapID(mapID)
    return site and Overlord.GuildKeep:IsKeepSiteDisplayMap(mapID, site) or false
end

local function ResolveKeepMinimapMapID(sourceMapID)
    if sourceMapID == keepResolvedSourceMapID and keepResolvedMapID then
        return keepResolvedMapID
    end
    local resolved = ResolveResourceMinimapMapID(sourceMapID, KeepMinimapIsMapID)
    -- Ne memoriser que le positif : C_Map peut etre transitoirement vide au chargement.
    if resolved then
        keepResolvedSourceMapID = sourceMapID
        keepResolvedMapID = resolved
    end
    return resolved
end

local function CreateKeepMinimapPins()
    for _, site in ipairs(BuildKeepMinimapDatabase()) do
        local existing = minimapKeepPins[site.id]
        if existing then
            existing.keepSite = site
        else
            local pin = CreateMinimapKeepIconPin()
            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
                ShowKeepMinimapTooltip(self.keepSite)
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            AttachLiveKeepTooltip(pin, function(self)
                ShowKeepMinimapTooltip(self.keepSite)
            end)
            pin.keepSite = site
            minimapKeepPins[site.id] = pin
        end
    end
end

local function UpdateKeepMinimapPins()
    if not Overlord.GuildKeep then return false end
    local mm = MM:GetMinimapCacheState()
    if not mm then return false end
    local mapID = ResolveKeepMinimapMapID(mm.mapID)
    if not mapID then return false end
    local px, py = GetPlayerPositionForResourceMap(mapID)
    if not px or not py then return false end
    CalcResourceYardsPerPct(keepYardsPerPct, mapID)

    local halfMM = mm.halfMM
    local pxPerYard = mm.pxPerYard
    local rotateMM = mm.rotate
    local facing = mm.facing
    local ypp = keepYardsPerPct[mapID]
    local yppX = ypp and ypp.x or 30
    local yppY = ypp and ypp.y or 30

    local sinF, cosF
    if rotateMM then
        sinF, cosF = math.sin(-facing), math.cos(-facing)
    end

    for _, site in ipairs(BuildKeepMinimapDatabase()) do
        local pin = minimapKeepPins[site.id]
        if pin and site.mapID == mapID then
            UpdateMinimapKeepIconPin(pin, site, mapID, px, py, yppX, yppY, pxPerYard, halfMM,
                rotateMM, sinF, cosF)
        elseif pin and pin:IsShown() then
            pin:Hide()
        end
    end
    return true
end

function Overlord.MapMarkers:CreateMinimapKeepPin()
    CreateKeepMinimapPins()
end

function Overlord.MapMarkers:CheckGuildKeepMinimap()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    local keepMapID = ok and ResolveKeepMinimapMapID(mapID) or nil
    if keepMapID and not Overlord.InstanceSuspended then
        self:CreateMinimapKeepPin()
        CalcResourceYardsPerPct(keepYardsPerPct, keepMapID)
        MM._mmKeepMapActive = true
    else
        MM._mmKeepMapActive = false
        self:HideMinimapKeepPin()
    end
    self:EnsureMinimapDriverVisible()
end

function Overlord.MapMarkers:UpdateMinimapKeepPin()
    if not Overlord.GuildKeep or Overlord.InstanceSuspended
        or not UpdateKeepMinimapPins() then
        self:HideMinimapKeepPin()
    end
end

function Overlord.MapMarkers:HideMinimapKeepPin()
    HideResourceMinimapPins(minimapKeepPins)
end

-- ============ Pins avant-postes sur la minimap (icone tour, comme fortins) ============

local minimapOutpostPins = {}
local outpostYardsPerPct = {}
local outpostResolvedSourceMapID = nil
local outpostResolvedMapID = nil

local function OutpostMinimapIsMapID(mapID)
    if not mapID or not Overlord.Outpost then return false end
    local site = Overlord.Outpost:ResolveSiteByMapID(mapID)
    if not site then return false end
    return Overlord.Outpost:GetGeometryMapID(site) == mapID
end

local function ResolveOutpostMinimapMapID(sourceMapID)
    if sourceMapID == outpostResolvedSourceMapID and outpostResolvedMapID then
        return outpostResolvedMapID
    end
    local resolved = ResolveResourceMinimapMapID(sourceMapID, OutpostMinimapIsMapID)
    if resolved then
        outpostResolvedSourceMapID = sourceMapID
        outpostResolvedMapID = resolved
    end
    return resolved
end

local outpostMinimapDbCache = nil
local outpostMinimapDbCacheContextKey = nil
local outpostMinimapStandaloneSite = nil

local function BuildOutpostMinimapDatabase(standaloneSite)
    local activeId = Overlord.Fronts and Overlord.Fronts.activeFrontId
    local contextKey = standaloneSite and ("standalone:" .. tostring(standaloneSite.siteKey))
        or (Overlord.InActiveFront and activeId) or ""
    if outpostMinimapDbCache and outpostMinimapDbCacheContextKey == contextKey then
        return outpostMinimapDbCache
    end
    -- Un changement direct de contexte peut ne pas produire de tick intermediaire
    -- sans avant-poste : masquer les pins de l'ancien registre avant de le remplacer.
    HideResourceMinimapPins(minimapOutpostPins)
    local list = {}
    if not Overlord.OutpostSites then
        outpostMinimapDbCache = list
        outpostMinimapDbCacheContextKey = contextKey
        return list
    end
    if standaloneSite then
        list[#list + 1] = standaloneSite
    elseif activeId and Overlord.InActiveFront then
        for key, site in pairs(Overlord.OutpostSites) do
            if site and site.center and site.mapID and site.frontId == activeId then
                site.id = site.id or site.siteKey or key
                site.siteKey = site.siteKey or key
                list[#list + 1] = site
            end
        end
    end
    outpostMinimapDbCache = list
    outpostMinimapDbCacheContextKey = contextKey
    return list
end

local function StyleMinimapOutpostIconPin(pin, iconSz, st, site, mapID)
    if pin._olSz ~= iconSz then
        pin:SetSize(iconSz, iconSz)
        pin.icon:SetSize(iconSz, iconSz)
        pin._olSz = iconSz
    end
    local atlas = GetOutpostIconAtlas(st, site, mapID)
    if pin._olLastAtlas ~= atlas then
        pin.icon:SetAtlas(atlas)
        pin._olLastAtlas = atlas
    end
    if Overlord.Outpost then
        local vr, vg, vb = Overlord.Outpost:GetOutpostIconVertexColor(st, site, mapID)
        if pin._olVR ~= vr or pin._olVG ~= vg or pin._olVB ~= vb then
            pin.icon:SetVertexColor(vr, vg, vb)
            pin._olVR, pin._olVG, pin._olVB = vr, vg, vb
        end
    end
end

local function ShowOutpostMinimapTooltip(site)
    if not site or not Overlord.Outpost then return end
    local st = Overlord.Outpost:GetState(site.siteKey)
    local tp = Overlord.UI and Overlord.UI.TooltipPalette and Overlord.UI.TooltipPalette() or nil
    local hr, hg, hb = tp and tp.HL[1] or 1, tp and tp.HL[2] or 0.82, tp and tp.HL[3] or 0
    GameTooltip:AddLine(Overlord.Outpost:GetDisplayName(site), hr, hg, hb)
    local sub = Overlord.Outpost:GetOutpostMapSubtitle(st, site, site.mapID)
    if sub and sub ~= "" then
        GameTooltip:AddLine(sub, tp and tp.BODY[1] or 1, tp and tp.BODY[2] or 1, tp and tp.BODY[3] or 1)
    end
    GameTooltip:Show()
end

local function UpdateMinimapOutpostIconPin(pin, site, mapID, px, py, yppX, yppY, pxPerYard, halfMM,
    rotateMM, sinF, cosF)
    if not pin or not site or not site.center then return end
    local dx = (site.center[1] - px) * yppX
    local dy = (site.center[2] - py) * yppY
    local pinX = dx * pxPerYard
    local pinY = -dy * pxPerYard
    if rotateMM then
        pinX, pinY = pinX * cosF - pinY * sinF, pinX * sinF + pinY * cosF
    end

    local avgYPP = (yppX + yppY) / 2
    local iconSz = math.max(KEEP_MINIMAP_ICON_MIN,
        math.min(KEEP_MINIMAP_ICON_MAX, avgYPP * 1.15 * pxPerYard))
    local dist = math.sqrt(pinX * pinX + pinY * pinY)
    if dist - iconSz / 2 > halfMM then
        if pin:IsShown() then pin:Hide() end
        return
    end

    local st = Overlord.Outpost and Overlord.Outpost:GetState(site.siteKey)
    StyleMinimapOutpostIconPin(pin, iconSz, st, site, mapID)
    PlaceMinimapPinCenter(pin, pinX, pinY)
    if not pin:IsShown() then pin:Show() end
end

local function CreateOutpostMinimapPins()
    for _, site in ipairs(BuildOutpostMinimapDatabase(outpostMinimapStandaloneSite)) do
        local existing = minimapOutpostPins[site.id]
        if existing then
            existing.outpostSite = site
        else
            local pin = CreateMinimapKeepIconPin()
            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
                ShowOutpostMinimapTooltip(self.outpostSite)
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            AttachLiveKeepTooltip(pin, function(self)
                ShowOutpostMinimapTooltip(self.outpostSite)
            end)
            pin.outpostSite = site
            minimapOutpostPins[site.id] = pin
        end
    end
end

local function UpdateOutpostMinimapPins()
    if not Overlord.Outpost then return false end
    local mm = MM:GetMinimapCacheState()
    if not mm then return false end
    local mapID = ResolveOutpostMinimapMapID(mm.mapID)
    if not mapID then return false end
    local px, py = GetPlayerPositionForResourceMap(mapID)
    if not px or not py then return false end
    CalcResourceYardsPerPct(outpostYardsPerPct, mapID)

    local halfMM = mm.halfMM
    local pxPerYard = mm.pxPerYard
    local rotateMM = mm.rotate
    local facing = mm.facing
    local ypp = outpostYardsPerPct[mapID]
    local yppX = ypp and ypp.x or 30
    local yppY = ypp and ypp.y or 30

    local sinF, cosF
    if rotateMM then
        sinF, cosF = math.sin(-facing), math.cos(-facing)
    end

    for _, site in ipairs(BuildOutpostMinimapDatabase(outpostMinimapStandaloneSite)) do
        local pin = minimapOutpostPins[site.id]
        local geomMapID = Overlord.Outpost:GetGeometryMapID(site)
        if pin and geomMapID == mapID then
            UpdateMinimapOutpostIconPin(pin, site, mapID, px, py, yppX, yppY, pxPerYard, halfMM,
                rotateMM, sinF, cosF)
        elseif pin and pin:IsShown() then
            pin:Hide()
        end
    end
    return true
end

function Overlord.MapMarkers:CreateMinimapOutpostPin()
    CreateOutpostMinimapPins()
end

function Overlord.MapMarkers:CheckOutpostMinimap()
    local onZoneMap, site = false, nil
    if Overlord.Outpost and Overlord.Outpost.IsPlayerOnOutpostMap then
        onZoneMap, site = Overlord.Outpost:IsPlayerOnOutpostMap()
    end
    outpostMinimapStandaloneSite = not Overlord.InActiveFront and site
        and site.standaloneOpenWorld and site or nil
    local sourceMapID = onZoneMap and site and Overlord.Outpost:GetGeometryMapID(site) or nil
    local outpostMapID = sourceMapID and ResolveOutpostMinimapMapID(sourceMapID) or nil
    if outpostMapID and not Overlord.InstanceSuspended then
        self:CreateMinimapOutpostPin()
        CalcResourceYardsPerPct(outpostYardsPerPct, outpostMapID)
        MM._mmOutpostMapActive = true
    else
        MM._mmOutpostMapActive = false
        self:HideMinimapOutpostPin()
    end
    self:EnsureMinimapDriverVisible()
end

function Overlord.MapMarkers:UpdateMinimapOutpostPin()
    if not Overlord.Outpost or Overlord.InstanceSuspended
        or not UpdateOutpostMinimapPins() then
        self:HideMinimapOutpostPin()
    end
end

function Overlord.MapMarkers:HideMinimapOutpostPin()
    HideResourceMinimapPins(minimapOutpostPins)
end

-- Constantes libelles fortin (declarees avant pins projetes : HideProjectedKeepPins utilise HideKeepMapLabels)
-- Fortin carte locale (site / zone) plus petit qu'avant ; projection continent/regional inchangee.
local KEEP_MAP_ICON_FRAC = 0.038
local KEEP_MAP_ICON_MIN = 36
local KEEP_MAP_ICON_MAX = 52
local KEEP_MAP_TITLE_MIN = 14
local KEEP_MAP_TITLE_MAX = 20
local KEEP_MAP_TITLE_FRAC = 0.27
local KEEP_MAP_SUB_MIN = 11
local KEEP_MAP_SUB_MAX = 16
local KEEP_MAP_SUB_FRAC = 0.20

local function HideKeepMapLabels(holder)
    if not holder then return end
    if holder.mapTitle then holder.mapTitle:Hide() end
    if holder.mapSub then holder.mapSub:Hide() end
    if holder.mapSub2 then holder.mapSub2:Hide() end
end

local function ClearKeepMapLabels(holder)
    if not holder then return end
    HideKeepMapLabels(holder)
    holder.mapTitle = nil
    holder.mapSub = nil
    holder.mapSub2 = nil
    holder._olLabelParent = nil
end

-- Sous-titre carte / tooltip : guilde proprietaire uniquement une fois le fortin tenu (held).
local function GetKeepGuildDisplayLine(st, site, mapID)
    if not st or not Overlord.GuildKeep then return L.GUILD_KEEP_NEUTRAL or "Unclaimed" end
    return Overlord.GuildKeep:GetKeepMapSubtitle(st, site, mapID)
end

local function GetKeepSiegeHintLine(st, siteKey)
    if not st or not Overlord.GuildKeep then return nil end
    if not Overlord.GuildKeep.IsKeepNeutralForDisplay
        or not Overlord.GuildKeep:IsKeepNeutralForDisplay(st, siteKey) then
        return nil
    end
    return Overlord.GuildKeep:GetKeepSiegeAvailableHint()
end

AddKeepNeutralTooltipLines = function(st, tp, siteKey)
    if not st or not Overlord.GuildKeep then return end
    if not Overlord.GuildKeep.IsKeepNeutralForDisplay
        or not Overlord.GuildKeep:IsKeepNeutralForDisplay(st, siteKey) then
        return
    end
    local hint = Overlord.GuildKeep:GetKeepSiegeAvailableHint()
    if not hint or hint == "" then return end
    local mr, mg, mb = 0.82, 0.82, 0.82
    if tp and tp.MUTED then
        mr, mg, mb = tp.MUTED[1], tp.MUTED[2], tp.MUTED[3]
    end
    GameTooltip:AddLine(hint, mr, mg, mb)
end

-- Libelles sur le calque carte (pas dans le frame icone)
local function UpdateKeepMapLabels(holder, parent, ox, oy, iconSz, title, guildLine, siegeLine)
    if not holder or not parent or ox == nil or oy == nil then return end
    iconSz = math.max(24, iconSz or KEEP_MAP_ICON_MIN)
    if holder._olLabelParent ~= parent then
        ClearKeepMapLabels(holder)
    end
    if not holder.mapTitle then
        holder.mapTitle = parent:CreateFontString(nil, "OVERLAY")
        holder.mapSub = parent:CreateFontString(nil, "OVERLAY")
        holder.mapSub2 = parent:CreateFontString(nil, "OVERLAY")
        holder.mapTitle:SetDrawLayer("OVERLAY", 7)
        holder.mapSub:SetDrawLayer("OVERLAY", 7)
        holder.mapSub2:SetDrawLayer("OVERLAY", 7)
        holder.mapTitle:SetShadowOffset(2, -2)
        holder.mapSub:SetShadowOffset(2, -2)
        holder.mapSub2:SetShadowOffset(2, -2)
        holder._olLabelParent = parent
    end
    local titleSz = math.max(KEEP_MAP_TITLE_MIN, math.min(KEEP_MAP_TITLE_MAX, iconSz * KEEP_MAP_TITLE_FRAC))
    local subSz = math.max(KEEP_MAP_SUB_MIN, math.min(KEEP_MAP_SUB_MAX, iconSz * KEEP_MAP_SUB_FRAC))
    local topY = oy - (iconSz * 0.5) - math.max(6, titleSz * 0.35)
    holder.mapTitle:SetFont(Overlord.UI.ResolveLocalizedFontPath(Fancy24Font, "Fonts\\MORPHEUS.TTF"), titleSz)
    holder.mapTitle:ClearAllPoints()
    holder.mapTitle:SetPoint("TOP", parent, "TOPLEFT", ox, topY)
    holder.mapTitle:SetTextColor(ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B)
    holder.mapTitle:SetText(title or "")
    holder.mapTitle:Show()
    holder.mapSub:SetFont(Overlord.UI.ResolveLocalizedFontPath(GameFontNormalSmall, "Fonts\\FRIZQT__.TTF"), subSz, "")
    holder.mapSub:ClearAllPoints()
    holder.mapSub:SetPoint("TOP", holder.mapTitle, "BOTTOM", 0, -math.max(2, subSz * 0.15))
    holder.mapSub:SetTextColor(ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B)
    holder.mapSub:SetText(guildLine or "")
    if guildLine and guildLine ~= "" then
        holder.mapSub:Show()
    else
        holder.mapSub:Hide()
    end
    if siegeLine and siegeLine ~= "" then
        local hintSz = math.max(KEEP_MAP_SUB_MIN - 1, math.min(KEEP_MAP_SUB_MAX - 2, subSz * 0.92))
        holder.mapSub2:SetFont(Overlord.UI.ResolveLocalizedFontPath(GameFontNormalSmall, "Fonts\\FRIZQT__.TTF"), hintSz, "")
        holder.mapSub2:ClearAllPoints()
        local anchor = (guildLine and guildLine ~= "") and holder.mapSub or holder.mapTitle
        holder.mapSub2:SetPoint("TOP", anchor, "BOTTOM", 0, -math.max(2, hintSz * 0.15))
        holder.mapSub2:SetTextColor(0.88, 0.88, 0.88)
        holder.mapSub2:SetText(siegeLine)
        holder.mapSub2:Show()
    elseif holder.mapSub2 then
        holder.mapSub2:Hide()
    end
end

-- ============ Icones fortins projetes (EK / Kalimdor / cartes regionales) ============

local projectedKeepRoot = nil
local projectedKeepPins = {}

-- Meme echelle que les logos domination EK (pas les pins mine ~20 px)
local function GetProjectedKeepPinSize(canvas, parent)
    return math.floor(GetEKDominanceLogoSize(canvas, parent) + 0.5)
end

function Overlord.MapMarkers:EnsureProjectedKeepPins(canvas)
    local parent = GetOverlayParent()
    if not Overlord.GuildKeep or not Overlord.GuildKeepSites or not canvas or not parent then return end
    if projectedKeepRoot and projectedKeepRoot:GetParent() ~= parent then
        projectedKeepRoot:SetParent(parent)
    end
    if not projectedKeepRoot then
        projectedKeepRoot = CreateFrame("Frame", nil, parent)
        projectedKeepRoot:SetAllPoints()
    end
    projectedKeepRoot:SetFrameStrata(parent:GetFrameStrata())
    projectedKeepRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 28)

    for siteKey, site in pairs(Overlord.GuildKeepSites) do
        if not projectedKeepPins[siteKey] then
            local pin = CreateFrame("Frame", nil, projectedKeepRoot)
            pin:SetFrameStrata(projectedKeepRoot:GetFrameStrata())
            pin:SetFrameLevel(projectedKeepRoot:GetFrameLevel() + 1)
            pin.siteKey = siteKey
            pin.site = site

            pin:SetClipsChildren(false)
            local icon = pin:CreateTexture(nil, "OVERLAY", nil, 2)
            icon:SetPoint("CENTER")
            pin.icon = icon

            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            local function BuildProjectedKeepTooltip(self)
                if not Overlord.GuildKeep then return end
                local st = Overlord.GuildKeep:GetState(self.siteKey)
                local siteRef = self.site
                if not st or not siteRef then return end
                local tp = Overlord.UI.TooltipPalette()
                GameTooltip:AddLine(Overlord.GuildKeep:GetDisplayName(siteRef), tp.HL[1], tp.HL[2], tp.HL[3])
                local dg = select(1, Overlord.GuildKeep:GetKeepDisplayTenant(st, siteRef and siteRef.siteKey))
                local siegeActive = Overlord.GuildKeep.IsCurrentKeepSiegeState
                    and Overlord.GuildKeep:IsCurrentKeepSiegeState(st)
                if siegeActive then
                    local siegeLabel = Overlord.GuildKeep.GetKeepSiegeMapLabel
                        and Overlord.GuildKeep:GetKeepSiegeMapLabel(st, siteRef and siteRef.siteKey)
                        or (L.GUILD_KEEP_CAPTURING or "Capturing...")
                    GameTooltip:AddLine(siegeLabel, 1, 0.55, 0.2)
                elseif dg ~= "" then
                    GameTooltip:AddLine(dg, tp.BODY[1], tp.BODY[2], tp.BODY[3])
                else
                    GameTooltip:AddLine(L.GUILD_KEEP_NEUTRAL or "Unclaimed", tp.MUTED[1], tp.MUTED[2], tp.MUTED[3])
                    AddKeepNeutralTooltipLines(st, tp, siteRef and siteRef.siteKey)
                end
                if Overlord.GuildKeepImmersion and Overlord.GuildKeepImmersion.AppendKeepTooltipLines then
                    Overlord.GuildKeepImmersion:AppendKeepTooltipLines(st, siteRef, self.siteKey)
                end
                GameTooltip:Show()
            end
            pin:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                BuildProjectedKeepTooltip(self)
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            AttachLiveKeepTooltip(pin, BuildProjectedKeepTooltip)
            projectedKeepPins[siteKey] = pin
        else
            projectedKeepPins[siteKey].site = site
        end
    end
end

function Overlord.MapMarkers:RefreshProjectedKeepPins()
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent or not Overlord.GuildKeep then
        self:HideProjectedKeepPins()
        return false
    end
    if not self:IsGuildKeepProjectionMap(GetTrackedMapID()) then
        self:HideProjectedKeepPins()
        return false
    end

    self:EnsureProjectedKeepPins(canvas)
    local projectionMapID = GetTrackedMapID()
    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 or not ch or ch == 0 then return false end

    local iconSize = GetProjectedKeepPinSize(canvas, parent)
    local shownPins = 0
    local expectedPins = 0

    for siteKey, site in pairs(Overlord.GuildKeepSites) do
        local pin = projectedKeepPins[siteKey]
        if site and site.mapID and site.center
            and Overlord.GuildKeep:ShouldProjectPinOnMap(site, projectionMapID) then
            expectedPins = expectedPins + 1
            if pin and pin.icon then
                local nx, ny = GetMinePositionOnContinentMap(
                    { mapID = site.mapID, center = site.center }, projectionMapID)
                if nx and ny then
                    local x = nx * cw
                    local yDown = ny * ch
                    local ox, oy = GetOverlayPoint(canvas, parent, x, yDown)
                    if ox and oy then
                        local st = Overlord.GuildKeep:GetState(siteKey)
                        if PlaceMapPinCenter(pin, parent, ox, oy, iconSize) then
                            local painted = pcall(function()
                                pin.icon:SetSize(iconSize, iconSize)
                                pin.icon:SetAtlas(GetKeepIconAtlas(st, site, projectionMapID))
                                local vr, vg, vb = Overlord.GuildKeep:GetKeepIconVertexColor(st, site, projectionMapID)
                                pin.icon:SetVertexColor(vr, vg, vb)
                            end)
                            if painted then
                                -- Continent / region : icone seule, sans creer de libelles vides.
                                HideKeepMapLabels(pin)
                                pin:Show()
                                shownPins = shownPins + 1
                            else
                                pin:Hide()
                            end
                        else
                            pin:Hide()
                        end
                    else
                        pin:Hide()
                    end
                else
                    pin:Hide()
                end
            end
        elseif pin then
            pin:Hide()
        end
    end

    if projectedKeepRoot then
        if shownPins > 0 then projectedKeepRoot:Show() else projectedKeepRoot:Hide() end
    end
    return shownPins == expectedPins
end

function Overlord.MapMarkers:HideProjectedKeepPins()
    if projectedKeepRoot and projectedKeepRoot:IsShown() then projectedKeepRoot:Hide() end
    for _, pin in pairs(projectedKeepPins) do
        if pin then
            ClearMapPinLayoutCache(pin)
            HideKeepMapLabels(pin)
            if pin:IsShown() then pin:Hide() end
        end
    end
end

-- ============ Avant-postes projetés (continent / régional, comme fortins) ============

local projectedOutpostRoot = nil
local projectedOutpostPins = {}

local function ShowOutpostMapTooltip(site, st)
    if not site or not Overlord.Outpost then return end
    st = st or Overlord.Outpost:GetState(site.siteKey)
    local tp = Overlord.UI and Overlord.UI.TooltipPalette and Overlord.UI.TooltipPalette() or nil
    GameTooltip:AddLine(Overlord.Outpost:GetDisplayName(site), tp and tp.HL[1] or 1,
        tp and tp.HL[2] or 0.82, tp and tp.HL[3] or 0)
    local sub = Overlord.Outpost:GetOutpostMapSubtitle(st, site, site.mapID)
    if sub and sub ~= "" then
        GameTooltip:AddLine(sub, tp and tp.BODY[1] or 1, tp and tp.BODY[2] or 1, tp and tp.BODY[3] or 1)
    else
        GameTooltip:AddLine(L.OUTPOST_NEUTRAL or "Unclaimed", tp and tp.MUTED[1] or 0.7,
            tp and tp.MUTED[2] or 0.7, tp and tp.MUTED[3] or 0.7)
    end
    GameTooltip:Show()
end

function Overlord.MapMarkers:EnsureProjectedOutpostPins(canvas)
    local parent = GetOverlayParent()
    if not Overlord.Outpost or not canvas or not parent then return end
    if projectedOutpostRoot and projectedOutpostRoot:GetParent() ~= parent then
        projectedOutpostRoot:SetParent(parent)
    end
    if not projectedOutpostRoot then
        projectedOutpostRoot = CreateFrame("Frame", nil, parent)
        projectedOutpostRoot:SetAllPoints()
    end
    projectedOutpostRoot:SetFrameStrata(parent:GetFrameStrata())
    projectedOutpostRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 29)

    for siteKey, site in pairs(Overlord.OutpostSites) do
        if not projectedOutpostPins[siteKey] then
            local pin = CreateFrame("Frame", nil, projectedOutpostRoot)
            pin:SetFrameStrata(projectedOutpostRoot:GetFrameStrata())
            pin:SetFrameLevel(projectedOutpostRoot:GetFrameLevel() + 1)
            pin.siteKey = siteKey
            pin.site = site
            pin:SetClipsChildren(false)
            local icon = pin:CreateTexture(nil, "OVERLAY", nil, 2)
            icon:SetPoint("CENTER")
            pin.icon = icon
            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                if not Overlord.Outpost then return end
                local siteRef = self.site
                if not siteRef then return end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                ShowOutpostMapTooltip(siteRef, Overlord.Outpost:GetState(self.siteKey))
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            AttachLiveKeepTooltip(pin, function(self)
                if not Overlord.Outpost or not self.site then return end
                ShowOutpostMapTooltip(self.site, Overlord.Outpost:GetState(self.siteKey))
            end)
            projectedOutpostPins[siteKey] = pin
        else
            projectedOutpostPins[siteKey].site = site
        end
    end
end

function Overlord.MapMarkers:RefreshProjectedOutpostPins()
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent or not Overlord.Outpost then
        self:HideProjectedOutpostPins()
        return false
    end
    if not self:IsGuildKeepProjectionMap(GetTrackedMapID()) then
        self:HideProjectedOutpostPins()
        return false
    end

    self:EnsureProjectedOutpostPins(canvas)
    local projectionMapID = GetTrackedMapID()
    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 or not ch or ch == 0 then return false end

    local iconSize = GetProjectedKeepPinSize(canvas, parent)
    local shownPins = 0
    local expectedPins = 0

    for siteKey, site in pairs(Overlord.OutpostSites) do
        local pin = projectedOutpostPins[siteKey]
        if site and site.mapID and site.center
            and Overlord.Outpost:ShouldProjectOutpostPinOnMap(site, projectionMapID) then
            expectedPins = expectedPins + 1
            if pin and pin.icon then
                local nx, ny = GetMinePositionOnContinentMap(
                    { mapID = site.mapID, center = site.center }, projectionMapID)
                if nx and ny then
                    local x = nx * cw
                    local yDown = ny * ch
                    local ox, oy = GetOverlayPoint(canvas, parent, x, yDown)
                    if ox and oy then
                        local st = Overlord.Outpost:GetState(siteKey)
                        if PlaceMapPinCenter(pin, parent, ox, oy, iconSize) then
                            local painted = pcall(function()
                                pin.icon:SetSize(iconSize, iconSize)
                                pin.icon:SetAtlas(GetOutpostIconAtlas(st, site, projectionMapID))
                                local vr, vg, vb = Overlord.Outpost:GetOutpostIconVertexColor(
                                    st, site, projectionMapID)
                                pin.icon:SetVertexColor(vr, vg, vb)
                            end)
                            if painted then
                                HideKeepMapLabels(pin)
                                pin:Show()
                                shownPins = shownPins + 1
                            else
                                pin:Hide()
                            end
                        else
                            pin:Hide()
                        end
                    else
                        pin:Hide()
                    end
                else
                    pin:Hide()
                end
            end
        elseif pin then
            pin:Hide()
        end
    end

    if projectedOutpostRoot then
        if shownPins > 0 then projectedOutpostRoot:Show() else projectedOutpostRoot:Hide() end
    end
    return shownPins == expectedPins
end

function Overlord.MapMarkers:HideProjectedOutpostPins()
    if projectedOutpostRoot and projectedOutpostRoot:IsShown() then projectedOutpostRoot:Hide() end
    for _, pin in pairs(projectedOutpostPins) do
        if pin then
            ClearMapPinLayoutCache(pin)
            HideKeepMapLabels(pin)
            if pin:IsShown() then pin:Hide() end
        end
    end
end


-- ============ Guild Keep (Wetlands) - icone forteresse + libelles (pas de cercle de zone) ============
local guildKeepOverlay = nil
local guildKeepMapContentDirty = false
local guildKeepMapVisualKey = nil
local outpostPinRoot = nil
local outpostPins = {}
local outpostMapContentDirty = false
local outpostMapVisualKey = nil

local function IsWarfrontOverlayMode(m)
    return m == "front" or m == "front_mine"
end

function Overlord.MapMarkers:SetWorldMapOverlayMode(mode)
    if worldMapOverlayMode == mode then return end
    local prev = worldMapOverlayMode
    worldMapOverlayMode = mode
    if IsWarfrontOverlayMode(prev) and not IsWarfrontOverlayMode(mode) then
        Overlord.MapMarkers:HideWarfrontOverlays()
        Overlord.MapMarkers:HideOutpostOverlays()
        -- Ces couches ne sont peuplees que sur une carte de front. Les masquer une
        -- seule fois a la transition evite de reparcourir leurs caches a chaque frame
        -- sur toutes les autres cartes.
        if Overlord.BountyMap and Overlord.BountyMap.HideWorld then
            Overlord.BountyMap:HideWorld()
        end
        if Overlord.ManualBountyMap and Overlord.ManualBountyMap.HideWorld then
            Overlord.ManualBountyMap:HideWorld()
        end
        if Overlord.GeneralMap and Overlord.GeneralMap.HideWorld then
            Overlord.GeneralMap:HideWorld()
        end
    end
    if prev == "outpost" and mode ~= "outpost" then
        Overlord.MapMarkers:HideOutpostOverlays()
    end
    if (prev == "gk" or prev == "ek") and mode ~= "gk" and mode ~= "ek" then
        Overlord.MapMarkers:HideGuildKeepOverlays()
    end
    if (prev == "ek" or prev == "kalimdor" or prev == "gk_region")
        and mode ~= "ek" and mode ~= "kalimdor" and mode ~= "gk_region" then
        Overlord.MapMarkers:HideProjectedKeepPins()
        Overlord.MapMarkers:HideProjectedOutpostPins()
    end
    if prev == "mine" and mode ~= "mine" and mode ~= "front_mine" then
        Overlord.MapMarkers:HideMineOverlays()
    end
    if mode ~= "wood" and mode ~= "gk" and mode ~= "mine" and not IsWarfrontOverlayMode(mode) then
        Overlord.MapMarkers:HideWoodOverlays()
    end
    if (prev == "ek" or prev == "kalimdor")
        and mode ~= "ek" and mode ~= "kalimdor" then
        Overlord.MapMarkers:HideEKDominance()
    end
end

local GUILD_KEEP_MAP_ID = 56

local function GetKeepMapIconSize(canvas, parent)
    if not canvas then return KEEP_MAP_ICON_MIN end
    local cw = canvas:GetWidth()
    if not cw or cw == 0 then return KEEP_MAP_ICON_MIN end
    local scaleRatio = 1
    if parent then
        local canvasScale = canvas:GetEffectiveScale()
        local parentScale = parent:GetEffectiveScale()
        if canvasScale and parentScale and parentScale > 0 then
            scaleRatio = canvasScale / parentScale
        end
    end
    return math.max(KEEP_MAP_ICON_MIN,
        math.min(KEEP_MAP_ICON_MAX, cw * KEEP_MAP_ICON_FRAC * scaleRatio))
end

local function GetKeepMapVisualKey(st, site, displayMapID)
    if not st then return "" end
    local disp = st.status or ""
    local dg, df = Overlord.GuildKeep:GetKeepDisplayTenant(st, site and site.siteKey)
    local localCap = Overlord.GuildKeep:ShouldUseAssaultKeepMapVisual(st, site, displayMapID) and 1 or 0
    local contested = st.isContested and 1 or 0
    local renderedLabel = Overlord.GuildKeep.GetKeepMapSubtitle
        and Overlord.GuildKeep:GetKeepMapSubtitle(st, site, displayMapID) or ""
    return string.format("%s|%s|%s|%s|%d|%d",
        disp, df or "", dg or "", renderedLabel or "", localCap, contested)
end

local function GetKeepMapPinPosition(site, canvas, parent)
    if not site or not site.center or not canvas or not parent then return nil, nil end
    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 or not ch or ch == 0 then return nil, nil end
    local x = (site.center[1] / 100) * cw
    local yDown = (site.center[2] / 100) * ch
    return GetOverlayPoint(canvas, parent, x, yDown)
end

-- Position du pin avant-poste sur la carte monde affichee. Toujours partir de la carte
-- geometrique du site (GetGeometryMapID, comme la minimap), puis projeter si besoin.
local function GetOutpostMapPinPosition(site, displayMapID, canvas, parent)
    if not site or not site.center or not canvas or not parent then return nil, nil end
    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 or not ch or ch == 0 then return nil, nil end
    local geomMapID = (Overlord.Outpost and Overlord.Outpost.GetGeometryMapID)
        and Overlord.Outpost:GetGeometryMapID(site) or site.mapID
    if not geomMapID or not displayMapID then return nil, nil end

    local nx, ny
    if displayMapID == geomMapID or (site.mapIDs and site.mapIDs[displayMapID]) then
        nx = site.center[1] / 100
        ny = site.center[2] / 100
    else
        nx, ny = GetMinePositionOnContinentMap(
            { mapID = geomMapID, center = site.center }, displayMapID)
    end
    if not nx or not ny then return nil, nil end
    return GetOverlayPoint(canvas, parent, nx * cw, ny * ch)
end

local function LayoutKeepMarker(root, site, canvas, parent)
    local ox, oy = GetKeepMapPinPosition(site, canvas, parent)
    if not ox or not oy then return nil, nil end
    PlaceMapPinCenter(root, parent, ox, oy, nil)
    return ox, oy
end

function Overlord.MapMarkers:CreateGuildKeepOverlay(site)
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent or not site then return nil end

    local root = CreateFrame("Frame", nil, parent)
    root:SetFrameStrata(parent:GetFrameStrata())
    root:SetFrameLevel(parent:GetFrameLevel() + 2)
    root:SetSize(KEEP_MAP_ICON_MIN, KEEP_MAP_ICON_MIN)
    root:SetClipsChildren(false)
    root.site = site

    local iconTex = root:CreateTexture(nil, "OVERLAY")
    iconTex:SetSize(KEEP_MAP_ICON_MIN, KEEP_MAP_ICON_MIN)
    iconTex:SetPoint("CENTER", root, "CENTER", 0, 0)
    root.iconTex = iconTex

    root:Hide()
    return root
end

function Overlord.MapMarkers:UpdateGuildKeepOverlay(ov, layoutOnly)
    if not ov or not ov.site or not Overlord.GuildKeep then return false end
    local site = ov.site
    local siteKey = site.siteKey
    local st = Overlord.GuildKeep:GetState(siteKey)
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return false end

    local iconSz = GetKeepMapIconSize(canvas, parent)
    local ox, oy = GetKeepMapPinPosition(site, canvas, parent)
    if not ox or not oy then return false end

    local displayMapID = GetTrackedMapID() or site.mapID
    local visualKey = GetKeepMapVisualKey(st, site, displayMapID)
    -- Carte detail : pas le nom de zone (deja sur la carte Blizzard), guilde / etat seulement.
    local onDetailMap = Overlord.GuildKeep:IsKeepSiteDisplayMap(displayMapID, site)
    local title = onDetailMap and nil or Overlord.GuildKeep:GetDisplayName(site)
    local guildLine = GetKeepGuildDisplayLine(st, site, displayMapID)
    local siegeLine = GetKeepSiegeHintLine(st, site and site.siteKey)
    local labelsMissing = not ov.mapTitle or not ov.mapTitle:IsShown()

    if layoutOnly then
        if PlaceMapPinCenter(ov, parent, ox, oy, nil) ~= true then return false end
        if ov.iconTex and ov._olLastIconSz ~= iconSz then
            ov._olLastIconSz = iconSz
            ov.iconTex:SetSize(iconSz, iconSz)
        end
        UpdateKeepMapLabels(ov, parent, ox, oy, iconSz, title, guildLine, siegeLine)
        return true
    end

    if visualKey == ov._olLastVisualKey and not labelsMissing
        and ov.iconTex and ov.iconTex:IsShown() and ov._olLastIconSz == iconSz then
        return true
    end

    if PlaceMapPinCenter(ov, parent, ox, oy, nil) ~= true then return false end
    ov.iconTex:SetSize(iconSz, iconSz)
    local atlas = GetKeepIconAtlas(st, site, displayMapID)
    local painted = pcall(function()
        if ov._olLastAtlas ~= atlas then
            ov.iconTex:SetAtlas(atlas)
            ov._olLastAtlas = atlas
        end
        local vr, vg, vb = Overlord.GuildKeep:GetKeepIconVertexColor(st, site, displayMapID)
        ov.iconTex:SetVertexColor(vr, vg, vb)
        ov.iconTex:Show()
    end)
    if not painted then return false end
    ov._olLastVisualKey = visualKey
    ov._olLastIconSz = iconSz
    UpdateKeepMapLabels(ov, parent, ox, oy, iconSz, title, guildLine, siegeLine)
    return true
end

-- Rafraichit icone/libelles sans ResetMapLayoutKey (evite sautillement carte)
function Overlord.MapMarkers:RefreshGuildKeepMapIfOpen()
    if not WorldMapFrame or not WorldMapFrame.IsShown or not WorldMapFrame:IsShown() then return end
    if not Overlord.GuildKeep then return end
    local mapID = GetTrackedMapID()
    local site = mapID and Overlord.GuildKeep:ResolveSiteByMapID(mapID)
    local st = site and Overlord.GuildKeep:GetState(site.siteKey)
    local visualKey = GetKeepMapVisualKey(st, site, mapID)
    local labelsMissing = not guildKeepOverlay or not guildKeepOverlay.mapTitle
        or not guildKeepOverlay.mapTitle:IsShown()
    if visualKey == guildKeepMapVisualKey
        and guildKeepOverlay and guildKeepOverlay:IsShown() and not labelsMissing then
        return
    end
    guildKeepMapVisualKey = visualKey
    guildKeepMapContentDirty = true
    local mapID = GetTrackedMapID()
    if not mapID then return end
    local parent = GetOverlayParent()
    local needLayout = not guildKeepOverlay
        or (parent and guildKeepOverlay:GetParent() ~= parent)
    if site and Overlord.GuildKeep:IsKeepSiteDisplayMap(mapID, site) then
        self:RefreshGuildKeepOverlays(mapID, needLayout, true)
        return
    end
    if self:IsGuildKeepProjectionMap(mapID) then
        self:RefreshGuildKeepOverlays(mapID, needLayout, true)
    end
end

function Overlord.MapMarkers:RefreshGuildKeepOverlays(mapID, layoutChanged, contentRefresh)
    if not Overlord.GuildKeep then return false end
    local displayMapID = mapID or GetTrackedMapID() or GUILD_KEEP_MAP_ID
    local site = Overlord.GuildKeep:ResolveSiteByMapID(displayMapID)

    -- Carte locale du site (Paluns / sous-cartes) : overlay avec nom de guilde
    if site and Overlord.GuildKeep:IsKeepSiteDisplayMap(displayMapID, site) then
        self:HideProjectedKeepPins()
        local canvas = GetCanvas()
        local parent = GetOverlayParent()
        if not canvas or not parent then
            guildKeepMapContentDirty = true
            return false
        end
        local cw = canvas:GetWidth()
        if not cw or cw == 0 then
            guildKeepMapContentDirty = true
            return false
        end

        if guildKeepOverlay and guildKeepOverlay:GetParent() ~= parent then
            ClearMapPinLayoutCache(guildKeepOverlay)
            ClearKeepMapLabels(guildKeepOverlay)
            guildKeepOverlay._olLastVisualKey = nil
            guildKeepOverlay._olLastAtlas = nil
            guildKeepOverlay:Hide()
            guildKeepOverlay:SetParent(parent)
        end
        if not guildKeepOverlay then
            guildKeepOverlay = self:CreateGuildKeepOverlay(site)
            layoutChanged = true
            contentRefresh = true
        end
        local ready = guildKeepOverlay ~= nil
        if guildKeepOverlay then
            guildKeepOverlay.site = site
            if layoutChanged then
                ready = self:UpdateGuildKeepOverlay(guildKeepOverlay, true) == true
            end
            if ready and (contentRefresh or guildKeepMapContentDirty) then
                ready = self:UpdateGuildKeepOverlay(guildKeepOverlay, false) == true
            end
            if ready then
                guildKeepOverlay:Show()
            else
                guildKeepOverlay:Hide()
            end
        end
        guildKeepMapContentDirty = not ready
        return ready == true
    end

    -- Carte regionale / continent (Durotar, Kalimdor, EK) : pin projete sans overlay detail
    if self:IsGuildKeepProjectionMap(displayMapID)
        and not (site and Overlord.GuildKeep:IsKeepSiteDisplayMap(displayMapID, site)) then
        self:HideGuildKeepOverlays()
        -- Toujours repositionner : le pan/zoom doit suivre le canvas a chaque frame.
        local ready = self:RefreshProjectedKeepPins()
        guildKeepMapContentDirty = ready ~= true
        return ready == true
    end
    self:HideGuildKeepOverlays()
    guildKeepMapContentDirty = false
    return true
end

function Overlord.MapMarkers:HideGuildKeepOverlays()
    guildKeepMapVisualKey = nil
    if guildKeepOverlay then
        guildKeepOverlay._olLastVisualKey = nil
        guildKeepOverlay._olLastAtlas = nil
        HideKeepMapLabels(guildKeepOverlay)
        if guildKeepOverlay:IsShown() then
            guildKeepOverlay:Hide()
        end
    end
end

function Overlord.MapMarkers:EnsureOutpostPins(canvas)
    local parent = GetOverlayParent()
    if not canvas or not parent or not Overlord.Outpost then return end
    if outpostPinRoot and outpostPinRoot:GetParent() ~= parent then
        outpostPinRoot:SetParent(parent)
    end
    if not outpostPinRoot then
        outpostPinRoot = CreateFrame("Frame", nil, parent)
        outpostPinRoot:SetAllPoints()
    end
    outpostPinRoot:SetFrameStrata(parent:GetFrameStrata())
    outpostPinRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 27)
    for siteKey, site in pairs(Overlord.OutpostSites) do
        if not outpostPins[siteKey] then
            local pin = CreateFrame("Frame", nil, outpostPinRoot)
            pin:SetFrameStrata(outpostPinRoot:GetFrameStrata())
            pin:SetFrameLevel(outpostPinRoot:GetFrameLevel() + 1)
            local icon = pin:CreateTexture(nil, "OVERLAY")
            icon:SetPoint("CENTER")
            pin.icon = icon
            pin.siteKey = siteKey
            pin.site = site
            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                if not Overlord.Outpost then return end
                local siteRef = self.site
                if not siteRef then return end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                ShowOutpostMapTooltip(siteRef, Overlord.Outpost:GetState(self.siteKey))
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            AttachLiveKeepTooltip(pin, function(self)
                if not Overlord.Outpost or not self.site then return end
                ShowOutpostMapTooltip(self.site, Overlord.Outpost:GetState(self.siteKey))
            end)
            pin:Hide()
            outpostPins[siteKey] = pin
        else
            outpostPins[siteKey].site = site
        end
    end
end

function Overlord.MapMarkers:RefreshOutpostOverlays(mapID, frontId, layoutChanged, contentRefresh)
    if not Overlord.Outpost or not mapID then
        self:HideOutpostOverlays()
        return false
    end

    local sites = Overlord.Outpost:GetSitesOnMap(mapID, frontId)
    if #sites > 0 then
        self:HideProjectedOutpostPins()
        local canvas = GetCanvas()
        local parent = GetOverlayParent()
        if not canvas or not parent then
            outpostMapContentDirty = true
            return false
        end
        local cw = canvas:GetWidth()
        local ch = canvas:GetHeight()
        if not cw or cw == 0 or not ch or ch == 0 then
            outpostMapContentDirty = true
            return false
        end

        self:EnsureOutpostPins(canvas)
        local iconSize = GetKeepMapIconSize(canvas, parent)
        local shownPins = 0
        local expectedPins = 0
        local displayMapID = mapID

        for _, site in ipairs(sites) do
            local siteKey = site.siteKey
            local pin = outpostPins[siteKey]
            if site.center then expectedPins = expectedPins + 1 end
            if pin and pin.icon and site.center then
                local ox, oy = GetOutpostMapPinPosition(site, displayMapID, canvas, parent)
                if ox and oy then
                    local st = Overlord.Outpost:GetState(siteKey)
                    if PlaceMapPinCenter(pin, parent, ox, oy, iconSize) then
                        local painted = pcall(function()
                            pin.icon:SetSize(iconSize, iconSize)
                            pin.icon:SetAtlas(GetOutpostIconAtlas(st, site, displayMapID))
                            local vr, vg, vb = Overlord.Outpost:GetOutpostIconVertexColor(
                                st, site, displayMapID)
                            pin.icon:SetVertexColor(vr, vg, vb)
                        end)
                        if painted then
                            HideKeepMapLabels(pin)
                            pin:Show()
                            shownPins = shownPins + 1
                        else
                            pin:Hide()
                        end
                    else
                        pin:Hide()
                    end
                elseif pin then
                    pin:Hide()
                end
            elseif pin then
                pin:Hide()
            end
        end

        for siteKey, pin in pairs(outpostPins) do
            local onMap = false
            for _, site in ipairs(sites) do
                if site.siteKey == siteKey then
                    onMap = true
                    break
                end
            end
            if not onMap and pin then
                pin:Hide()
            end
        end

        if outpostPinRoot then
            if shownPins > 0 then outpostPinRoot:Show() else outpostPinRoot:Hide() end
        end
        local ready = expectedPins > 0 and shownPins == expectedPins
        if shownPins == 0 and self:IsGuildKeepProjectionMap(displayMapID) then
            ready = self:RefreshProjectedOutpostPins() == true
        end
        outpostMapContentDirty = not ready
        return ready
    end

    if outpostPinRoot and outpostPinRoot:IsShown() then outpostPinRoot:Hide() end
    for _, pin in pairs(outpostPins) do
        if pin and pin:IsShown() then pin:Hide() end
    end

    if self:IsGuildKeepProjectionMap(mapID) then
        local ready = self:RefreshProjectedOutpostPins()
        outpostMapContentDirty = ready ~= true
        return ready == true
    end

    self:HideProjectedOutpostPins()
    outpostMapContentDirty = false
    return true
end

function Overlord.MapMarkers:HideOutpostOverlays()
    self:HideProjectedOutpostPins()
    if outpostPinRoot and outpostPinRoot:IsShown() then outpostPinRoot:Hide() end
    for _, pin in pairs(outpostPins) do
        if pin then
            ClearMapPinLayoutCache(pin)
            HideKeepMapLabels(pin)
            if pin:IsShown() then pin:Hide() end
        end
    end
end

function Overlord.MapMarkers:RefreshOutpostMapIfOpen()
    if not WorldMapFrame or not WorldMapFrame.IsShown or not WorldMapFrame:IsShown() then return end
    if not Overlord.Outpost then return end
    local mapID = GetTrackedMapID()
    if not mapID then return end
    local frontForMap = Overlord.Fronts and Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
    local frontId = frontForMap and frontForMap.id or nil
    local sites = Overlord.Outpost:GetSitesOnMap(mapID, frontId)
    if #sites == 0 then return end
    local visualKey = mapID .. ":" .. (frontId or "standalone")
    for _, site in ipairs(sites) do
        local st = Overlord.Outpost:GetState(site.siteKey)
        visualKey = visualKey .. ":" .. site.siteKey .. ":" .. (st and st.status or "")
            .. ":" .. (st and st.ownerGuild or "") .. ":" .. (st and st.ownerFaction or "")
            .. ":" .. (st and st.isContested and 1 or 0)
    end
    if visualKey == outpostMapVisualKey and not outpostMapContentDirty then return end
    outpostMapVisualKey = visualKey
    outpostMapContentDirty = true
    local parent = GetOverlayParent()
    local needLayout = not outpostPinRoot
        or (parent and outpostPinRoot:GetParent() ~= parent)
    self:RefreshOutpostOverlays(mapID, frontId, needLayout, true)
end

function Overlord.MapMarkers:IsGuildKeepOverlayLabelsMissing()
    if not guildKeepOverlay then return true end
    if not guildKeepOverlay:IsShown() then return true end
    return not guildKeepOverlay.mapTitle or not guildKeepOverlay.mapTitle:IsShown()
end

function Overlord.MapMarkers:IsGuildKeepMapContentDirty()
    return guildKeepMapContentDirty
end

function Overlord.MapMarkers:IsOutpostMapContentDirty()
    return outpostMapContentDirty
end
