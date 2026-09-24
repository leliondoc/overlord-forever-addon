-- MapMarkers.lua - Cercles de zones sur la carte du monde
-- Overlays sur un calque visible, positions recalculees depuis le canvas.
-- Taint 12.0 : trackedMapID evite de lire WorldMapFrame.mapID,
-- CacheCanvas() lit ScrollContainer.Child une seule fois (OnShow),
-- et le popup residuel est supprime dans Core.lua (SetAlpha(0)).
Overlord = Overlord or {}
Overlord.MapMarkers = {}
Overlord.MapMarkers._mmKeepMapActive = false

local L = Overlord.L

local overlays = {}
local pathLines = {}
-- Pools de reuse apres recreation du canvas carte : les frames/textures WoW ne sont jamais
-- garbage-collectees ; les abandonner a chaque rebuild du ScrollContainer est une fuite memoire.
local overlayFramePool = {}
local pathDotPool = {}
local overlayVisibleZoneIds = {}
local pathZoneById = {}
local pathVisibleConnIds = {}
local pathConnIdCache = {}
local ekVisibleFrontIds = {}
-- Couleur accent HUD « prochain objectif »
Overlord.MapMarkers.NEXT_OBJECTIVE_COLOR = { 0.85, 0.75, 0.45 }
-- Le calque complet suit le pan a chaque frame via une translation unique. Le zoom
-- conserve un layout borne pour respecter les icones dont la taille est fixe en pixels UI.
-- Le contenu reste cadence/event-driven : aucun parcours de pins pendant un pan.
-- Etat regroupe : MapMarkers est proche de la limite Lua 5.1 de 200 variables
-- locales par chunk, donc les drivers partagent une seule locale.
local driverState = {
    worldInterval = 0.50,
    worldDirtyInterval = 0.05,
    worldIdleInterval = 0.50,
    worldAccum = 0.05,
    worldGateSlow = false,
    forcedMinInterval = 0.25,
    forcedNotBefore = 0,
    lastContentRefreshAt = 0,
    canvasInvalidHidden = false,
    catchUpHidden = false,
    minimapIdleInterval = 0.50,
    minimapMovementActive = true,
    minimapPositionRefreshForced = true,
    mapLayoutValid = false,
    mapLayoutCw = 0,
    mapLayoutCh = 0,
    mapLayoutRatio = 0,
    mapLayoutCl = 0,
    mapLayoutCt = 0,
    mapLayoutRevision = 0,
    worldTransformValid = false,
    worldTransformCanvas = nil,
    worldTransformX = 0,
    worldTransformY = 0,
    worldTransformScale = 1,
    worldTransformW = 0,
    worldTransformH = 0,
    worldOverlayViewport = nil,
    worldLayoutPending = false,
}
local OVERLAY_REFRESH_INTERVAL = 0.50
-- Les rafales sync/UI peuvent appeler RequestOverlayRefresh des dizaines de fois
-- dans la meme seconde. Le contenu lourd est sale immediatement, mais ne peut etre
-- repeint plus de 4 fois/s ; le pan est independant et le zoom reste borne a 20 Hz.
local overlayRefreshAccum = 0
local overlayRefreshForced = false
-- Empreinte layout carte mise en cache sous forme de NOMBRES (pas de string).
-- La carte monde appelle MapLayoutChanged ~60x/s tant qu'elle est ouverte : formater une
-- string (string.format) a chaque frame creait une allocation/sec = pression GC inutile.
-- On compare directement les composantes numeriques, avec la meme quantification qu'avant
-- (cw/ch entiers, ratio a 3 decimales, coords snappees au demi-pixel) pour un comportement
-- strictement identique (pas de faux "layout change" du au jitter float du ratio).
-- Arrondi demi-pixel pour stabiliser layout et pins carte
local function SnapMapPinCoord(v)
    return math.floor((tonumber(v) or 0) * 2 + 0.5) / 2
end

-- Empreinte layout carte (zoom/dezoom/pan) : invalide quand le canvas ou son echelle bouge.
local function ResetMapLayoutKey()
    driverState.mapLayoutValid = false
end

local function MapLayoutChanged(canvas, parent)
    if not canvas then return false end
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    if not cw or cw == 0 then return false end
    local cs = canvas:GetEffectiveScale() or 1
    local ps = (parent and parent:GetEffectiveScale()) or 1
    -- Ratio quantifie a 3 decimales (equivalent de l'ancien %.3f) : sinon le jitter float
    -- de cs/ps declencherait un layout change a chaque frame.
    local ratio = (ps > 0) and (cs / ps) or 1
    ratio = math.floor(ratio * 1000 + 0.5) / 1000
    cw = math.floor(cw + 0.5)
    ch = math.floor(ch + 0.5)
    -- Comparer le decalage RELATIF, pas les positions absolues : le calque racine
    -- suit maintenant le canvas. Pendant un pan leurs deux GetLeft/GetTop bougent,
    -- mais leur geometrie interne reste identique et aucun enfant ne doit etre relaye.
    local cl, ct = canvas:GetLeft(), canvas:GetTop()
    local pl, pt = parent and parent:GetLeft(), parent and parent:GetTop()
    local offsetX, offsetY = 0, 0
    if cl and ct and pl and pt then
        offsetX = SnapMapPinCoord(((cl * cs) - (pl * ps)) / ps)
        offsetY = SnapMapPinCoord(((ct * cs) - (pt * ps)) / ps)
    end
    if driverState.mapLayoutValid
        and driverState.mapLayoutCw == cw and driverState.mapLayoutCh == ch
        and driverState.mapLayoutRatio == ratio
        and driverState.mapLayoutCl == offsetX and driverState.mapLayoutCt == offsetY then
        return false
    end
    driverState.mapLayoutValid = true
    driverState.mapLayoutCw, driverState.mapLayoutCh, driverState.mapLayoutRatio =
        cw, ch, ratio
    driverState.mapLayoutCl, driverState.mapLayoutCt = offsetX, offsetY
    driverState.mapLayoutRevision = driverState.mapLayoutRevision + 1
    return true
end

function Overlord.MapMarkers:WorldMapNeedsPeriodicContentRefresh(mapID)
    local front = Overlord.MapMarkers and Overlord.MapMarkers._renderFront
    for _, zone in ipairs((front and front.zones) or {}) do
        if zone.status == "in_progress" or zone.isHolding then
            return true
        end
    end
    if front and Overlord.Zones and Overlord.Zones.IsOnVictoryCooldown then
        local onCooldown = Overlord.Zones:IsOnVictoryCooldown(front.id, true)
        if onCooldown then return true end
    end
    if mapID and Overlord.Zones then
        if Overlord.Zones:IsMineMapID(mapID)
            or (Overlord.Zones.IsWoodMapID and Overlord.Zones:IsWoodMapID(mapID)) then
            return true
        end
    end
    local gk = Overlord.GuildKeep
    if mapID and gk and gk.ResolveSiteByMapID and gk:ResolveSiteByMapID(mapID)
        and gk.HasTimeSensitiveMaintenance and gk:HasTimeSensitiveMaintenance() then
        return true
    end
    local outpost = Overlord.Outpost
    if mapID and outpost and outpost.ResolveSiteByMapID and outpost.GetState then
        local site = outpost:ResolveSiteByMapID(mapID)
        local st = site and outpost:GetState(site.siteKey)
        if st and (st.status == "in_progress" or st.isHolding or st.holdAuthorityLocal) then
            return true
        end
    end
    return Overlord.IsInCatchUpPhase and Overlord:IsInCatchUpPhase() or false
end

-- Le contenu statique est evenementiel (RequestOverlayRefresh). Le rythme 2 Hz
-- reste uniquement pour les captures, treves et phases dont le texte evolue avec le temps.
local function ShouldRefreshWorldMapOverlays(elapsed, mapID)
    local now = GetTime()
    local need = overlayRefreshForced and now >= driverState.forcedNotBefore
    overlayRefreshAccum = overlayRefreshAccum + (elapsed or 0)
    if overlayRefreshAccum >= OVERLAY_REFRESH_INTERVAL then
        overlayRefreshAccum = 0
        need = need or Overlord.MapMarkers:WorldMapNeedsPeriodicContentRefresh(mapID)
    end
    if need then
        overlayRefreshForced = false
        driverState.lastContentRefreshAt = now
        return true
    end
    return false
end
local ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B = 0.85, 0.75, 0.45
local DOMINANCE_THRESHOLD = 0.8
local resolvedEKMapID = nil
local resolvedKalimdorMapID = nil
local cachedCanvas = nil
-- Mode overlays carte monde (SetWorldMapOverlayMode dans MapMarkersKeep.lua)
local cachedOverlayParent = nil
local worldOverlayParent = nil
local catchUpBanner = nil
-- Cache "playerOnFront" pour la banniere catch-up : invariant quasi tout le temps frame a frame ;
-- recalcule uniquement au rythme contentRefresh au lieu de C_Map.GetBestMapForUnit a 60 Hz.
local cachedPlayerOnFrontFrontId = nil
local cachedPlayerOnFront = false
local cachedCatchUpAt = 0
local cachedCatchUpValue = false
local CATCHUP_CACHE_TTL = 0.75
-- Cache IsEKMap / IsKalimdorMap pour le mapID affiche (walk parent coutueux).
local continentProbeMapID = nil
local continentProbeIsEK = false
local continentProbeIsKal = false
local continentProbeEKValid = false
local continentProbeKalValid = false
local woodOverlaysFullyHidden = false
-- Evite HideAll* a chaque layoutChanged (~60 Hz) tant que WM reste OFF carte ouverte.
local worldMapHiddenForNoWarMode = false
-- Un canvas invalide peut persister plusieurs frames pendant un chargement. Les couches
-- sont masquees une seule fois, puis le driver ne fait que retenter la recuperation.
-- Chromie Time / Party Sync peut rester actif longtemps : ne pas retraverser tous les
-- overlays a chaque tick tant que le mode catch-up ne change pas.

-- Affichage carte monde Overlord : Mode Guerre requis (meme regle que InActiveFront / minimap).
-- Masquage UI uniquement : aucun ecrit sync / SavedVariables.
local function IsWarModeActiveForOverlays()
    -- Forever : pas de Warmode. Les overlays s'affichent des qu'on est sur la carte du front.
    return true
end

local function HideAllOverlordWorldMapContent()
    Overlord.MapMarkers:SetWorldMapOverlayMode("none")
    Overlord.MapMarkers._renderFront = nil
    Overlord.MapMarkers:HideAllOverlays()
    Overlord.MapMarkers:HideEKDominance()
    if Overlord.MapMarkers.HideMineOverlays then
        Overlord.MapMarkers:HideMineOverlays()
    end
    if Overlord.MapMarkers.HideWoodOverlays then
        Overlord.MapMarkers:HideWoodOverlays()
    end
    if Overlord.MapMarkers.HideEKGoldMinePins then
        Overlord.MapMarkers:HideEKGoldMinePins()
    end
    if Overlord.MapMarkers.HideContinentWoodPins then
        Overlord.MapMarkers:HideContinentWoodPins()
    end
    if Overlord.MapMarkers.HideProjectedOutpostPins then
        Overlord.MapMarkers:HideProjectedOutpostPins()
    end
    if Overlord.BountyMap and Overlord.BountyMap.HideWorld then
        Overlord.BountyMap:HideWorld()
    end
    if Overlord.ManualBountyMap and Overlord.ManualBountyMap.HideWorld then
        Overlord.ManualBountyMap:HideWorld()
    end
    if Overlord.GeneralMap and Overlord.GeneralMap.HideWorld then
        Overlord.GeneralMap:HideWorld()
    end
    if Overlord.MapMarkers.HideCatchUpBanner then
        Overlord.MapMarkers:HideCatchUpBanner()
    end
end

local function HideZoneOverlayText(ov)
    if not ov then return end
    ov._olPaintValid = false
    ov._olRibbonKey = nil
    if ov.titleRibbonLeft then ov.titleRibbonLeft:Hide() end
    if ov.titleRibbonMid then ov.titleRibbonMid:Hide() end
    if ov.titleRibbonRight then ov.titleRibbonRight:Hide() end
    if ov.titleBg then ov.titleBg:Hide() end
    if ov.text then ov.text:Hide() end
    if ov.subtext then ov.subtext:Hide() end
    if ov.subtext2 then ov.subtext2:Hide() end
end

-- Ruban d'en-tete des options Warboard (PlayerChoice : UI-Frame-%s-Ribbon).
local ZONE_RIBBON_ATLAS = "UI-Frame-Neutral-Ribbon"
-- Police + marron natifs Warboard (PlayerChoiceNormalOptionTemplate / kit Horde).
local ZONE_TITLE_FONT = "Fonts\\FRIZQT__.TTF"
local ZONE_TITLE_PARCHMENT_R, ZONE_TITLE_PARCHMENT_G, ZONE_TITLE_PARCHMENT_B = 0.192, 0.051, 0.008
do
    if SystemFont_Med3 and SystemFont_Med3.GetFont then
        local path = SystemFont_Med3:GetFont()
        if path then ZONE_TITLE_FONT = path end
    end
    ZONE_TITLE_FONT = Overlord.UI.ResolveLocalizedFontPath(SystemFont_Med3, ZONE_TITLE_FONT)
end

local function InitZoneTitleRibbon(overlay)
    local bg = overlay.titleBg
    if not bg then return false end
    if overlay._olRibbonInit then return overlay._olRibbonOk end
    overlay._olRibbonInit = true
    local ok = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ZONE_RIBBON_ATLAS) ~= nil
    if ok then
        bg:SetAtlas(ZONE_RIBBON_ATLAS, false)
        bg:SetVertexColor(1, 1, 1, 1)
    end
    overlay._olRibbonOk = ok and true or false
    return overlay._olRibbonOk
end

-- Coupe le nom en 1 ou 2 lignes equilibrees (jamais 3).
local function FormatZoneTitleTwoLines(text, rawName)
    if not text or not rawName or rawName == "" then return rawName, 0, 0 end
    local name = rawName:gsub("[\r\n]+", " "):gsub("%s+", " ")
    name = name:match("^%s*(.-)%s*$") or name
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:SetWordWrap(false)
    text:SetNonSpaceWrap(false)
    -- Largeur large pour mesurer sans troncature (SetWidth(0) coupe le texte).
    text:SetWidth(400)
    text:SetText(name)
    local fullW = text:GetStringWidth() or 0
    local _, titleSz = text:GetFont()
    titleSz = titleSz or 12
    -- Au-dela de ca, on passe a 2 lignes.
    local oneLineMax = math.max(110, math.floor(titleSz * 12.5 + 0.5))
    local formatted = name
    if fullW > oneLineMax then
        local words = {}
        for w in name:gmatch("%S+") do
            words[#words + 1] = w
        end
        if #words >= 2 then
            local bestI, bestScore = 1, math.huge
            for i = 1, #words - 1 do
                local line1 = table.concat(words, " ", 1, i)
                local line2 = table.concat(words, " ", i + 1, #words)
                text:SetText(line1)
                local w1 = text:GetStringWidth() or 0
                text:SetText(line2)
                local w2 = text:GetStringWidth() or 0
                local score = math.abs(w1 - w2) + math.max(w1, w2) * 0.08
                if score < bestScore then
                    bestScore = score
                    bestI = i
                end
            end
            formatted = table.concat(words, " ", 1, bestI) .. "\n" .. table.concat(words, " ", bestI + 1, #words)
        end
    end
    local tw = 0
    if formatted:find("\n", 1, true) then
        local line1, line2 = formatted:match("^(.-)\n(.*)$")
        text:SetText(line1 or "")
        local w1 = text:GetStringWidth() or 0
        text:SetText(line2 or "")
        local w2 = text:GetStringWidth() or 0
        tw = math.max(w1, w2)
    else
        text:SetText(formatted)
        tw = text:GetStringWidth() or fullW
    end
    text:SetWidth(math.max(1, math.ceil(tw)))
    text:SetText(formatted)
    local th = text:GetStringHeight() or 0
    return formatted, tw, th
end

local function ShouldShowMapZoneTitles()
    if OverlordDB and OverlordDB.config and OverlordDB.config.showMapZoneTitles == false then
        return false
    end
    return true
end

local function LayoutZoneTitleRibbon(overlay)
    local bg = overlay and overlay.titleBg
    local text = overlay and overlay.text
    if overlay.titleRibbonLeft then overlay.titleRibbonLeft:Hide() end
    if overlay.titleRibbonMid then overlay.titleRibbonMid:Hide() end
    if overlay.titleRibbonRight then overlay.titleRibbonRight:Hide() end
    if not ShouldShowMapZoneTitles() then
        if text then text:Hide() end
        if bg then bg:Hide() end
        -- Sans titre : recentrer le timer / statut sur le cercle.
        if overlay.subtext then
            overlay.subtext:ClearAllPoints()
            overlay.subtext:SetPoint("CENTER", overlay, "CENTER", 0, 4)
        end
        return
    end
    if not bg or not text or not text:IsShown() then
        if bg then bg:Hide() end
        return
    end
    if not InitZoneTitleRibbon(overlay) then
        bg:Hide()
        return
    end
    local rawName = (overlay.zone and overlay.zone.name)
        or (overlay.resource and overlay.resource.name)
        or text:GetText() or ""
    local _, tw, th = FormatZoneTitleTwoLines(text, rawName)
    if tw <= 0 or th <= 0 then
        bg:Hide()
        return
    end
    local _, titleSz = text:GetFont()
    titleSz = titleSz or 12
    -- Marge laterale genereuse : les plis du ruban mangent beaucoup plus que leur bord visible.
    local h = math.max(26, math.floor(th + titleSz * 1.25 + 0.5))
    local sidePad = math.max(42, math.floor(h * 0.85 + 0.5))
    local w = math.floor(tw + sidePad * 2 + 0.5)
    local key = w .. ":" .. h .. ":" .. rawName
    if overlay._olRibbonKey ~= key then
        overlay._olRibbonKey = key
        bg:SetSize(w, h)
        bg:ClearAllPoints()
        bg:SetPoint("CENTER", text, "CENTER", 0, 0)
        -- Sous-titre colle sous le ruban (remonte description + icone).
        if overlay.subtext then
            overlay.subtext:ClearAllPoints()
            overlay.subtext:SetPoint("TOP", bg, "BOTTOM", 0, 4)
        end
    end
    if not bg:IsShown() then bg:Show() end
end
-- Apres instance / loading, ScrollContainer.Child peut etre recree : GetWidth()==0 jusqu'a re-cache.
local lastCanvasRecoverAt = 0
local CANVAS_RECOVER_INTERVAL = 0.45

-- SetPassThroughButtons est bloque en combat (Retail 12+) : ADDON_ACTION_BLOCKED si la carte
-- rafraichit des pins pendant le lockdown (OnUpdate + ouverture monde).
local pendingPassThroughFrames = {}

local function FlushPendingPassThroughFrames()
    if InCombatLockdown() then return end
    -- Copie shallow : list doit etre une NOUVELLE table (sinon wipe vide la meme ref que ipairs).
    local list = {}
    for i = 1, #pendingPassThroughFrames do
        list[i] = pendingPassThroughFrames[i]
    end
    wipe(pendingPassThroughFrames)
    for _, f in ipairs(list) do
        if f and not f:IsForbidden() and f._overlordPassThroughPending then
            f._overlordPassThroughPending = nil
            pcall(function()
                f:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton")
            end)
        end
    end
end

-- Applique tout de suite hors combat, sinon file d'attente jusqu'a PLAYER_REGEN_ENABLED.
local function SafeSetPassThroughButtons(frame)
    if not frame or frame:IsForbidden() then return end
    if InCombatLockdown() then
        if not frame._overlordPassThroughPending then
            frame._overlordPassThroughPending = true
            pendingPassThroughFrames[#pendingPassThroughFrames + 1] = frame
        end
        return
    end
    frame._overlordPassThroughPending = nil
    pcall(function()
        frame:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton")
    end)
end

local function GetCanvas()
    return cachedCanvas
end

local function GetOverlayParent()
    return cachedOverlayParent
end

-- Les pins sont enfants d'un seul calque contenu qui reproduit le repere du canvas
-- Blizzard. Un pan ne deplace donc qu'une frame ; le zoom reveille le layout borne
-- sans reboucler au framerate sur zones, chemins, primes, fortins et avant-postes.
function Overlord.MapMarkers:SyncWorldOverlayTransform(canvas)
    local parent = worldOverlayParent
    local viewport = driverState.worldOverlayViewport
    if not canvas or not parent or not viewport then return false end

    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    local canvasLeft, canvasTop = canvas:GetLeft(), canvas:GetTop()
    local viewportLeft, viewportTop = viewport:GetLeft(), viewport:GetTop()
    local canvasScale = canvas:GetEffectiveScale()
    local viewportScale = viewport:GetEffectiveScale()
    if not cw or cw <= 0 or not ch or ch <= 0
        or not canvasLeft or not canvasTop or not viewportLeft or not viewportTop
        or not canvasScale or canvasScale <= 0 or not viewportScale or viewportScale <= 0 then
        return false
    end

    local scale = canvasScale / viewportScale
    local offsetX = ((canvasLeft * canvasScale) - (viewportLeft * viewportScale)) / viewportScale
    local offsetY = ((canvasTop * canvasScale) - (viewportTop * viewportScale)) / viewportScale
    local rootW, rootH = cw * scale, ch * scale
    local canvasChanged = driverState.worldTransformCanvas ~= canvas
    local positionChanged = not driverState.worldTransformValid or canvasChanged
        or math.abs(driverState.worldTransformX - offsetX) >= 0.015625
        or math.abs(driverState.worldTransformY - offsetY) >= 0.015625
    local scaleChanged = not driverState.worldTransformValid or canvasChanged
        or math.abs(driverState.worldTransformScale - scale) >= 0.00001
    local sizeChanged = not driverState.worldTransformValid or canvasChanged
        or math.abs(driverState.worldTransformW - rootW) >= 0.015625
        or math.abs(driverState.worldTransformH - rootH) >= 0.015625
    if driverState.worldTransformValid and not canvasChanged
        and not positionChanged and not scaleChanged and not sizeChanged then
        return false
    end

    driverState.worldTransformValid = true
    driverState.worldTransformCanvas = canvas
    driverState.worldTransformX = offsetX
    driverState.worldTransformY = offsetY
    driverState.worldTransformScale = scale
    driverState.worldTransformW = rootW
    driverState.worldTransformH = rootH
    -- Ne jamais scaler la racine : plusieurs icones/plaque utilisent volontairement
    -- une taille fixe en pixels UI. Seule son origine suit le pan ; le zoom est rebati
    -- a cadence bornee pour conserver exactement leurs tailles historiques.
    if sizeChanged then parent:SetSize(rootW, rootH) end
    if positionChanged then
        parent:ClearAllPoints()
        parent:SetPoint("TOPLEFT", viewport, "TOPLEFT", offsetX, offsetY)
    end
    if scaleChanged or sizeChanged then
        -- Zoom/maximisation : reveiller le layout borne. Le pan pur ne passe jamais
        -- ici et reste une unique translation de racine a chaque image.
        driverState.mapLayoutValid = false
        driverState.worldLayoutPending = true
    end
    return true
end

local function GetCanvasToOverlayScaleRatio(canvas, parent)
    if not canvas or not parent then return 1 end
    local canvasScale = canvas:GetEffectiveScale()
    local parentScale = parent:GetEffectiveScale()
    if canvasScale and canvasScale > 0 and parentScale and parentScale > 0 then
        return canvasScale / parentScale
    end
    return 1
end

local function GetOverlayPoint(canvas, parent, x, yDown)
    if not canvas or not parent then return nil, nil end
    local canvasLeft, canvasTop = canvas:GetLeft(), canvas:GetTop()
    local parentLeft, parentTop = parent:GetLeft(), parent:GetTop()
    -- Canvas pas encore ancre : ne pas placer (evite saut ~0,5 s quand les coords deviennent valides)
    if not canvasLeft or not canvasTop or not parentLeft or not parentTop then
        return nil, nil
    end

    -- Conversion du repere du canvas vers le calque visible.
    local canvasScale = canvas:GetEffectiveScale()
    local parentScale = parent:GetEffectiveScale()
    local scaleRatio = GetCanvasToOverlayScaleRatio(canvas, parent)
    local offsetX = ((canvasLeft * canvasScale) - (parentLeft * parentScale)) / parentScale
    local offsetY = ((canvasTop * canvasScale) - (parentTop * parentScale)) / parentScale
    return offsetX + (x * scaleRatio), offsetY - (yDown * scaleRatio)
end

-- Repositionne un pin carte seulement si les coords ont change (anti-sautillement au zoom)
local function PlaceMapPinCenter(pin, parent, ox, oy, iconSize)
    if not pin or not parent or ox == nil or oy == nil then return false end
    ox = SnapMapPinCoord(ox)
    oy = SnapMapPinCoord(oy)
    if iconSize then
        iconSize = math.floor(iconSize + 0.5)
    end
    if pin._olPinParent ~= parent then
        pin._olPinParent = parent
        pin._olLastOx = nil
        pin._olLastOy = nil
        pin._olLastSz = nil
    end
    if pin._olLastOx == ox and pin._olLastOy == oy
        and (not iconSize or pin._olLastSz == iconSize) then
        if not pin:IsShown() then pin:Show() end
        return true
    end
    pin._olLastOx = ox
    pin._olLastOy = oy
    if iconSize then
        pin._olLastSz = iconSize
        pin:SetSize(iconSize, iconSize)
    end
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", parent, "TOPLEFT", ox, oy)
    pin:Show()
    return true
end

local function ClearMapPinLayoutCache(pin)
    if not pin then return end
    pin._olLastOx = nil
    pin._olLastOy = nil
    pin._olLastSz = nil
    pin._olPinParent = nil
end

-- Capture unique du canvas au premier OnShow (une seule lecture de la propriete protegee).
-- WoW 12.0.5 : securecall au lieu de pcall pour ne pas propager le taint.
-- pcall attrape les erreurs mais LAISSE le taint se propager, ce qui taint
-- toutes les tables internes de la carte et cause des milliers d'erreurs en arene.
local function CacheCanvas()
    if cachedCanvas then
        local viewport = driverState.worldOverlayViewport
        if viewport and viewport.SetClipsChildren then
            pcall(viewport.SetClipsChildren, viewport, true)
        end
        Overlord.MapMarkers:SyncWorldOverlayTransform(cachedCanvas)
        return
    end
    securecall(function()
        if WorldMapFrame and WorldMapFrame.ScrollContainer then
            cachedCanvas = WorldMapFrame.ScrollContainer.Child
            local viewport = driverState.worldOverlayViewport
            if viewport and viewport:GetParent() ~= WorldMapFrame.ScrollContainer then
                viewport:Hide()
                viewport:SetParent(WorldMapFrame.ScrollContainer)
            end
            if not viewport then
                viewport = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer)
                driverState.worldOverlayViewport = viewport
            end
            viewport:ClearAllPoints()
            viewport:SetAllPoints(WorldMapFrame.ScrollContainer)
            viewport:SetFrameStrata(WorldMapFrame.ScrollContainer:GetFrameStrata())
            viewport:SetFrameLevel(WorldMapFrame.ScrollContainer:GetFrameLevel() + 100)
            if viewport.SetClipsChildren then
                pcall(viewport.SetClipsChildren, viewport, true)
            end
            viewport:Show()

            if worldOverlayParent and worldOverlayParent:GetParent() ~= viewport then
                worldOverlayParent:Hide()
                worldOverlayParent:SetParent(viewport)
                driverState.worldTransformValid = false
            end
            if not worldOverlayParent then
                local overlayParent = CreateFrame("Frame", nil, viewport)
                overlayParent:SetFrameStrata(viewport:GetFrameStrata())
                overlayParent:SetFrameLevel(viewport:GetFrameLevel() + 1)
                -- Clip au viewport ScrollContainer (evite pins hors carte au zoom/pan)
                overlayParent:Show()
                worldOverlayParent = overlayParent
                driverState.worldTransformValid = false
            else
                worldOverlayParent:SetFrameStrata(viewport:GetFrameStrata())
                worldOverlayParent:SetFrameLevel(viewport:GetFrameLevel() + 1)
                worldOverlayParent:Show()
            end
            cachedOverlayParent = worldOverlayParent
            Overlord.MapMarkers:SyncWorldOverlayTransform(cachedCanvas)
        end
    end)
end

-- Purge les overlays et paths quand le canvas change (WoW recree ScrollContainer.Child)
local function PurgeStaleOverlays(oldCanvas, newCanvas, oldParent, newParent)
    if oldCanvas == newCanvas and oldParent == newParent then return end
    for _, ov in pairs(overlays) do
        if ov then
            HideZoneOverlayText(ov)
            if ov.Hide then pcall(ov.Hide, ov) end
            overlayFramePool[#overlayFramePool + 1] = ov
        end
    end
    wipe(overlays)
    for _, path in pairs(pathLines) do
        if path.dots then
            for _, dot in ipairs(path.dots) do
                if dot.Hide then pcall(dot.Hide, dot) end
                pathDotPool[#pathDotPool + 1] = dot
            end
        end
    end
    wipe(pathLines)
end


-- Track le mapID affiche via hooksecurefunc au lieu de lire WorldMapFrame.mapID.
-- La lecture directe de .mapID taint l'execution addon en 12.0
-- et declenche un faux positif ADDON_ACTION_FORBIDDEN.
local trackedMapID = nil
local suppressFrontOverlaysUntilMapReopen = false

local function ReadDisplayedMapID()
    -- Quand la carte est deja ouverte pendant un changement de zone/front, GetMapID peut suivre
    -- la carte du joueur avant que le canvas visible ne change vraiment. Le hook SetMapID/OnShow
    -- est la source fiable de la carte effectivement affichee : evite de dessiner Loch sur Paluns.
    if trackedMapID then return trackedMapID end
    if WorldMapFrame and WorldMapFrame.GetMapID then
        local ok, mid = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
        if ok and mid and mid > 0 then
            if trackedMapID ~= mid then
                local oldFront = Overlord.Fronts and trackedMapID and Overlord.Fronts:ResolveFrontByOverlayMapID(trackedMapID)
                local newFront = Overlord.Fronts and Overlord.Fronts:ResolveFrontByOverlayMapID(mid)
                if oldFront and (not newFront or oldFront.id ~= newFront.id) then
                    Overlord.MapMarkers._renderFront = nil
                    Overlord.MapMarkers:HideAllOverlays()
                    Overlord.MapMarkers:HideAllPaths()
                end
            end
            trackedMapID = mid
            return mid
        end
    end
    return nil
end

local function GetFrontOverlayDiameter(zone, canvas, parent)
    local canvasWidth = canvas:GetWidth()
    if not canvasWidth or canvasWidth == 0 then return nil end
    local scaleRatio = GetCanvasToOverlayScaleRatio(canvas, parent)
    -- Meme conversion que les positions : taille en coordonnees du calque visible.
    return (zone.radius * 2 / 100) * canvasWidth * scaleRatio
end

local function GetFrontOverlayLabelDiameter(zone, canvas, parent)
    local canvasWidth = canvas:GetWidth()
    if not canvasWidth or canvasWidth == 0 then return nil end
    local scaleRatio = GetCanvasToOverlayScaleRatio(canvas, parent)
    local labelRadius = zone.labelRadius
    if not labelRadius then
        local scale = (Overlord.Fronts and Overlord.Fronts.CaptureRadiusScale) or 0.60
        labelRadius = zone.radius / scale
    end
    return (labelRadius * 2 / 100) * canvasWidth * scaleRatio
end

-- Cercles mine (carte region) : meme facteur scaleRatio que les zones de front.
local function GetMineOverlayDiameter(mine, canvas, parent)
    if not mine then return nil end
    local canvasWidth = canvas:GetWidth()
    if not canvasWidth or canvasWidth == 0 then return nil end
    local scaleRatio = GetCanvasToOverlayScaleRatio(canvas, parent)
    local circleScale = (Overlord.MineMapCircleScale) or 0.50
    return (mine.radius * 2 / 100) * canvasWidth * scaleRatio * circleScale
end

local function GetWoodOverlayDiameter(wood, canvas, parent)
    if not wood then return nil end
    local canvasWidth = canvas:GetWidth()
    if not canvasWidth or canvasWidth == 0 then return nil end
    local scaleRatio = GetCanvasToOverlayScaleRatio(canvas, parent)
    local circleScale = (Overlord.WoodMapCircleScale) or 1.0
    return (wood.radius * 2 / 100) * canvasWidth * scaleRatio * circleScale
end

local function PlaceWorldMapCircleOverlay(overlay, item, canvas, parent, diameterFunc)
    if not overlay or not item or not item.center or not diameterFunc then return nil end
    local cw = canvas and canvas:GetWidth()
    local ch = canvas and canvas:GetHeight()
    if not cw or cw == 0 or not ch or ch == 0 then return nil end
    local x = (item.center[1] / 100) * cw
    local yDown = (item.center[2] / 100) * ch
    local ox, oy = GetOverlayPoint(canvas, parent, x, yDown)
    local diameter = diameterFunc(item, canvas, parent)
    if not ox or not oy or not diameter then
        if overlay:IsShown() then overlay:Hide() end
        return nil
    end
    local snapOx = SnapMapPinCoord(ox)
    local snapOy = SnapMapPinCoord(oy)
    local snapD = math.floor(diameter + 0.5)
    if PlaceMapPinCenter(overlay, parent, snapOx, snapOy, snapD) then
        return diameter
    end
    return nil
end

local function GetActiveFrontMapID()
    -- Carte Zone canonique du front (coords % locales), pas le continent affiche sur la carte monde.
    if Overlord.Fronts then
        local canon = Overlord.Fronts:GetMapID()
        if canon then return canon end
    end
    if trackedMapID and Overlord.Zones and Overlord.Zones:IsActiveFrontMapID(trackedMapID) then
        return trackedMapID
    end
    return nil
end

-- La minimap affiche parfois une sous-carte (donjon, etage) : pas de cercles de capture dessus.
local function IsMinimapFrontOverlayMap(mapID)
    if not mapID or not Overlord.Fronts then return false end
    return Overlord.Fronts:ResolveFrontByOverlayMapID(mapID) ~= nil
end

function Overlord.MapMarkers:Initialize()
    if not self._minimapInitialized then
        self._minimapInitialized = true
        self:InitializeMinimap()
    end

    if self._worldMapInitialized then return end

    if not WorldMapFrame then
        if not self._worldMapRetryCount then self._worldMapRetryCount = 0 end
        if self._worldMapRetryCount < 20 then
            self._worldMapRetryCount = self._worldMapRetryCount + 1
            C_Timer.After(1, function()
                if Overlord.MapMarkers and not Overlord.MapMarkers._worldMapInitialized then
                    Overlord.MapMarkers:Initialize()
                end
            end)
        end
        if not self._worldMapRetryFrame then
            self._worldMapRetryFrame = CreateFrame("Frame")
            self._worldMapRetryFrame:RegisterEvent("ADDON_LOADED")
            self._worldMapRetryFrame:SetScript("OnEvent", function(_, _, addonName)
                if addonName == "Blizzard_WorldMap" and Overlord.MapMarkers then
                    Overlord.MapMarkers:Initialize()
                end
            end)
        end
        return
    end

    self._worldMapInitialized = true
    self._worldMapRetryCount = nil
    if self._worldMapRetryFrame then
        self._worldMapRetryFrame:UnregisterEvent("ADDON_LOADED")
        self._worldMapRetryFrame = nil
    end

    if not self._passThroughCombatFrame then
        self._passThroughCombatFrame = CreateFrame("Frame")
        self._passThroughCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        self._passThroughCombatFrame:SetScript("OnEvent", function()
            FlushPendingPassThroughFrames()
        end)
    end

    -- Capture le mapID en parametre du hook (jamais de lecture de .mapID)
    if WorldMapFrame.SetMapID then
        hooksecurefunc(WorldMapFrame, "SetMapID", function(_, newMapID)
            if Overlord.InstanceSuspended then return end
            if trackedMapID ~= newMapID then
                -- Coupe immédiatement les couches Overlord quand on quitte une carte de front.
                -- Le tick OnUpdate reste le filet de securite, mais le changement de map doit
                -- masquer sans latence visible (dezoom continent / Azeroth).
                local oldFront = Overlord.Fronts and trackedMapID and Overlord.Fronts:ResolveFrontByOverlayMapID(trackedMapID)
                local newFront = Overlord.Fronts and newMapID and Overlord.Fronts:ResolveFrontByOverlayMapID(newMapID)
                if oldFront and (not newFront or oldFront.id ~= newFront.id) then
                    Overlord.MapMarkers._renderFront = nil
                    Overlord.MapMarkers:HideAllOverlays()
                    Overlord.MapMarkers:HideAllPaths()
                end
                if not newFront then
                    Overlord.MapMarkers._renderFront = nil
                    Overlord.MapMarkers:HideAllOverlays()
                    Overlord.MapMarkers:HideAllPaths()
                end
                if not Overlord.MapMarkers:IsEKMap(newMapID) then
                    if Overlord.MapMarkers:IsKalimdorMap(newMapID) then
                        Overlord.MapMarkers:HideEKDominanceLogos()
                        Overlord.MapMarkers:HideEKGoldMinePins()
                        Overlord.MapMarkers:HideContinentBountyPins()
                        Overlord.MapMarkers:HideContinentManualBountyPins()
                        Overlord.MapMarkers:HideContinentGeneralPins()
                    else
                        Overlord.MapMarkers:HideEKDominance()
                    end
                end
                if not Overlord.MapMarkers:IsEKMap(newMapID)
                    and not Overlord.MapMarkers:IsKalimdorMap(newMapID) then
                    Overlord.MapMarkers:HideContinentWoodPins()
                end
                if not Overlord.Zones:IsMineMapID(newMapID) then
                    Overlord.MapMarkers:HideMineOverlays()
                end
                if not (Overlord.Zones.IsWoodMapID and Overlord.Zones:IsWoodMapID(newMapID)) then
                    Overlord.MapMarkers:HideWoodOverlays()
                end
                if newFront and Overlord.Sync and Overlord.Sync.RequestConsultFrontSync then
                    Overlord.Sync:RequestConsultFrontSync(newFront.id)
                end
            end
            trackedMapID = newMapID
            overlayRefreshForced = true
            overlayRefreshAccum = 0
            driverState.worldAccum = driverState.worldInterval
            driverState.canvasInvalidHidden = false
            driverState.catchUpHidden = false
            Overlord.MapMarkers:HideCatchUpBanner()
            ResetMapLayoutKey()
        end)
    end

    -- OnUpdate seulement quand la carte est ouverte
    local updateFrame = CreateFrame("Frame")
    updateFrame:Hide()
    self._updateFrame = updateFrame

    updateFrame:SetScript("OnUpdate", function(_, elapsed)
        if Overlord.InstanceSuspended then
            updateFrame:Hide()
            return
        end

        -- Chemin visuel chaud : une seule transformation de frame a chaque image.
        -- Aucune resolution de front, reconstruction de pin ou lecture de contenu ici.
        if not driverState.worldGateSlow and cachedCanvas then
            Overlord.MapMarkers:SyncWorldOverlayTransform(cachedCanvas)
        end

        driverState.worldAccum = driverState.worldAccum + (elapsed or 0)
        local worldDriverInterval = driverState.worldGateSlow and driverState.worldIdleInterval
            or ((overlayRefreshForced or driverState.worldLayoutPending)
                and driverState.worldDirtyInterval
                or driverState.worldInterval)
        if driverState.worldAccum < worldDriverInterval then return end
        local driverElapsed = driverState.worldAccum
        driverState.worldAccum = 0
        -- Gate WM avant canvas/layout : hors WM, un seul hide puis idle (~0 alloc/frame).
        if not IsWarModeActiveForOverlays() then
            driverState.worldGateSlow = true
            if not worldMapHiddenForNoWarMode then
                HideAllOverlordWorldMapContent()
                worldMapHiddenForNoWarMode = true
            end
            return
        end
        driverState.worldGateSlow = false
        worldMapHiddenForNoWarMode = false

        local canvas = GetCanvas()
        -- Ne PAS tester canvas:IsVisible() : dans WoW 12.0+, ScrollContainer.Child
        -- peut retourner visible=false alors que la carte est ouverte.
        -- Le ticker est deja controle par OnShow/OnHide de WorldMapFrame.
        if not canvas then
            -- OnShow peut preceder la creation de ScrollContainer.Child. Ne pas mettre
            -- nil en cache pour toute l'ouverture : retenter au meme rythme borne que
            -- le canvas de largeur nulle.
            local nowRec = GetTime()
            if nowRec - lastCanvasRecoverAt >= CANVAS_RECOVER_INTERVAL then
                lastCanvasRecoverAt = nowRec
                local oldParent = cachedOverlayParent
                cachedCanvas = nil
                cachedOverlayParent = nil
                CacheCanvas()
                PurgeStaleOverlays(nil, cachedCanvas, oldParent, cachedOverlayParent)
                canvas = GetCanvas()
            end
            if not canvas then
                driverState.worldGateSlow = true
                if not driverState.canvasInvalidHidden then
                    Overlord.MapMarkers:HideAllOverlays()
                    Overlord.MapMarkers:HideEKDominance()
                    Overlord.MapMarkers:HideCatchUpBanner()
                    driverState.canvasInvalidHidden = true
                    driverState.catchUpHidden = false
                end
                return
            end
        end

        local cw = canvas:GetWidth()
        if not cw or cw == 0 then
            -- Canvas stale (souvent sortie arene / M+) : forcer une relecture du Child.
            local nowRec = GetTime()
            if nowRec - lastCanvasRecoverAt >= CANVAS_RECOVER_INTERVAL then
                lastCanvasRecoverAt = nowRec
                local oldParent = cachedOverlayParent
                cachedCanvas = nil
                cachedOverlayParent = nil
                CacheCanvas()
                PurgeStaleOverlays(canvas, cachedCanvas, oldParent, cachedOverlayParent)
                canvas = GetCanvas()
                cw = canvas and canvas:GetWidth() or 0
            end
            if not cw or cw == 0 then
                driverState.worldGateSlow = true
                if not driverState.canvasInvalidHidden then
                    Overlord.MapMarkers:HideAllOverlays()
                    Overlord.MapMarkers:HideEKDominance()
                    Overlord.MapMarkers:HideCatchUpBanner()
                    driverState.canvasInvalidHidden = true
                    driverState.catchUpHidden = false
                end
                return
            end
        end
        driverState.worldGateSlow = false
        Overlord.MapMarkers:SyncWorldOverlayTransform(canvas)

        -- Ne jamais consommer l'invalidation initiale avant que le repere du canvas
        -- soit reellement utilisable. A l'ouverture, Child peut deja avoir une taille
        -- non nulle alors que ses ancres (ou celles du viewport) sont encore nil :
        -- RefreshOverlays ne cree alors aucun cercle et, le contenu statique etant
        -- evenementiel, la carte peut rester vide jusqu'au prochain /reload.
        if not driverState.worldTransformValid
            or driverState.worldTransformCanvas ~= canvas then
            driverState.worldGateSlow = true
            if not driverState.canvasInvalidHidden then
                Overlord.MapMarkers:HideAllOverlays()
                Overlord.MapMarkers:HideEKDominance()
                Overlord.MapMarkers:HideCatchUpBanner()
                driverState.canvasInvalidHidden = true
                driverState.catchUpHidden = false
            end
            return
        end

        -- La carte peut afficher un front different de celui du joueur.
        -- JAMAIS appeler Activate() ici : Core.lua gere le front actif (position joueur).
        local mapID = ReadDisplayedMapID()
        -- GetMapID peut devenir disponible une frame apres OnShow. Garder le dirty
        -- flag arme et retenter au rythme idle, sans boucle lourde ni polling 20 Hz.
        if not mapID then
            driverState.worldGateSlow = true
            if not driverState.canvasInvalidHidden then
                Overlord.MapMarkers:HideAllOverlays()
                Overlord.MapMarkers:HideEKDominance()
                Overlord.MapMarkers:HideCatchUpBanner()
                driverState.canvasInvalidHidden = true
                driverState.catchUpHidden = false
            end
            return
        end
        driverState.canvasInvalidHidden = false
        local parent = GetOverlayParent()
        local layoutChanged = MapLayoutChanged(canvas, parent)
        driverState.worldLayoutPending = false
        local contentRefresh = ShouldRefreshWorldMapOverlays(driverElapsed, mapID)
        local frontForMap = mapID and Overlord.Fronts and Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
        -- Une seule resolution GK : le elseif doit matcher UNIQUEMENT sur carte locale fortin,
        -- sinon la branche GuildKeep avale toute la chaine (mines, EK, Kalimdor jamais atteints).
        local gkSite = Overlord.GuildKeep and mapID and Overlord.GuildKeep:ResolveSiteByMapID(mapID)
        local standaloneOutpostMap = not frontForMap and Overlord.Outpost and mapID
            and Overlord.Outpost.IsStandaloneOpenWorldDisplayMap
            and Overlord.Outpost:IsStandaloneOpenWorldDisplayMap(mapID)
        if frontForMap then
            if suppressFrontOverlaysUntilMapReopen and layoutChanged then
                -- Le canvas visible a rattrape le changement de front : reprendre sans forcer
                -- l'utilisateur a fermer / rouvrir la carte.
                suppressFrontOverlaysUntilMapReopen = false
            end
            if suppressFrontOverlaysUntilMapReopen then
                -- Quand le joueur change de front carte ouverte, WoW peut mettre GetMapID()
                -- a jour avant de remplacer le canvas visible. Ne pas peindre un front
                -- neuf sur l'ancienne carte : l'utilisateur rouvre la carte pour repartir propre.
                Overlord.MapMarkers:SetWorldMapOverlayMode("none")
                Overlord.MapMarkers._renderFront = nil
                Overlord.MapMarkers:HideAllOverlays()
                Overlord.MapMarkers:HideAllPaths()
            else
                Overlord.MapMarkers:SetWorldMapOverlayMode(Overlord.Zones:IsMineMapID(mapID) and "front_mine" or "front")
                Overlord.MapMarkers._renderFront = frontForMap
                -- Recalcul seulement a contentRefresh (2 Hz pour le temporel, sinon evenementiel) :
                -- la carte du joueur ne change pas
                -- assez vite pour justifier un pcall(C_Map.GetBestMapForUnit) a 60 Hz (chaque frame
                -- OnUpdate tant que la carte du front reste ouverte).
                if contentRefresh or cachedPlayerOnFrontFrontId ~= frontForMap.id then
                    local playerMapOk, playerMapID = pcall(C_Map.GetBestMapForUnit, "player")
                    cachedPlayerOnFront = playerMapOk and playerMapID
                        and Overlord.Fronts:IsFrontMapID(playerMapID, frontForMap.id) or false
                    cachedPlayerOnFrontFrontId = frontForMap.id
                end
                local playerOnFront = cachedPlayerOnFront
                -- Banniere catch-up : cache TTL (pas Chromie/PartySync a 60 Hz).
                local nowCatchUp = GetTime()
                local catchUpChanged = false
                if contentRefresh or (nowCatchUp - cachedCatchUpAt) >= CATCHUP_CACHE_TTL then
                    cachedCatchUpAt = nowCatchUp
                    local nextCatchUpValue = Overlord:IsInCatchUpPhase()
                    catchUpChanged = cachedCatchUpValue ~= nextCatchUpValue
                    cachedCatchUpValue = nextCatchUpValue
                end
                -- En sortie de catch-up, repeindre immediatement les couches cachees.
                if catchUpChanged then contentRefresh = true end
                if cachedCatchUpValue and playerOnFront then
                    if not driverState.catchUpHidden then
                        Overlord.MapMarkers:HideAllOverlays()
                        Overlord.MapMarkers:HideAllPaths()
                        Overlord.MapMarkers:ShowCatchUpBanner()
                        driverState.catchUpHidden = true
                    end
                else
                    driverState.catchUpHidden = false
                    Overlord.MapMarkers:HideCatchUpBanner()
                    if contentRefresh then
                        Overlord.MapMarkers:RefreshPaths()
                        local overlaysReady = Overlord.MapMarkers:RefreshOverlays()
                        if not overlaysReady then
                            -- Une ancre peut devenir indisponible entre la barriere ci-dessus
                            -- et la creation des frames. Conserver l'invalidation et dormir a
                            -- 2 Hz jusqu'au prochain essai ; aucune reconstruction par frame.
                            overlayRefreshForced = true
                            driverState.forcedNotBefore = math.max(
                                driverState.forcedNotBefore,
                                GetTime() + driverState.worldIdleInterval)
                            driverState.worldGateSlow = true
                        end
                        if Overlord.Bounty and Overlord.Bounty.RefreshWorldMapPins then
                            Overlord.Bounty:RefreshWorldMapPins()
                        end
                        if Overlord.ManualBounty and Overlord.ManualBounty.RefreshWorldMapPins then
                            Overlord.ManualBounty:RefreshWorldMapPins()
                        end
                        if Overlord.General and Overlord.General.RefreshWorldMapPins then
                            Overlord.General:RefreshWorldMapPins()
                        end
                    elseif layoutChanged then
                        Overlord.MapMarkers:RefreshPathLayouts()
                        Overlord.MapMarkers:RefreshOverlayLayouts()
                        -- Layout seul : pas de RefreshContinent (scan pins hors carte).
                        if Overlord.BountyMap and Overlord.BountyMap.Refresh then
                            Overlord.BountyMap:Refresh()
                        end
                        if Overlord.ManualBountyMap and Overlord.ManualBountyMap.Refresh then
                            Overlord.ManualBountyMap:Refresh()
                        end
                        if Overlord.GeneralMap and Overlord.GeneralMap.Refresh then
                            Overlord.GeneralMap:Refresh()
                        end
                    end
                    if Overlord.Zones:IsMineMapID(mapID) and (contentRefresh or layoutChanged) then
                        Overlord.MapMarkers:RefreshMineOverlays(mapID)
                    end
                    if Overlord.Zones.IsWoodMapID and Overlord.Zones:IsWoodMapID(mapID)
                        and (contentRefresh or layoutChanged) then
                        Overlord.MapMarkers:RefreshWoodOverlays(mapID)
                    elseif Overlord.MapMarkers.HideWoodOverlays then
                        Overlord.MapMarkers:HideWoodOverlays()
                    end
                    if Overlord.Outpost and frontForMap
                        and (layoutChanged or contentRefresh
                            or (Overlord.MapMarkers.IsOutpostMapContentDirty
                                and Overlord.MapMarkers:IsOutpostMapContentDirty())) then
                        Overlord.MapMarkers:RefreshOutpostOverlays(mapID, frontForMap.id,
                            layoutChanged, contentRefresh)
                    end
                end
            end
        elseif standaloneOutpostMap then
            Overlord.MapMarkers:SetWorldMapOverlayMode("outpost")
            Overlord.MapMarkers._renderFront = nil
            local standaloneCacheKey = "outpost:" .. tostring(mapID)
            if contentRefresh or cachedPlayerOnFrontFrontId ~= standaloneCacheKey then
                local playerMapOk, playerMapID = pcall(C_Map.GetBestMapForUnit, "player")
                local playerSite = playerMapOk and playerMapID
                    and Overlord.Outpost:ResolveSiteByMapID(playerMapID) or nil
                cachedPlayerOnFront = playerSite and playerSite.standaloneOpenWorld == true or false
                cachedPlayerOnFrontFrontId = standaloneCacheKey
            end
            local nowCatchUp = GetTime()
            local catchUpChanged = false
            if contentRefresh or (nowCatchUp - cachedCatchUpAt) >= CATCHUP_CACHE_TTL then
                cachedCatchUpAt = nowCatchUp
                local nextCatchUpValue = Overlord:IsInCatchUpPhase(true)
                catchUpChanged = cachedCatchUpValue ~= nextCatchUpValue
                cachedCatchUpValue = nextCatchUpValue
            end
            if catchUpChanged then contentRefresh = true end
            if cachedCatchUpValue and cachedPlayerOnFront then
                if not driverState.catchUpHidden then
                    Overlord.MapMarkers:HideOutpostOverlays()
                    Overlord.MapMarkers:ShowCatchUpBanner()
                    driverState.catchUpHidden = true
                end
            else
                driverState.catchUpHidden = false
                Overlord.MapMarkers:HideCatchUpBanner()
                if layoutChanged or contentRefresh
                    or (Overlord.MapMarkers.IsOutpostMapContentDirty
                        and Overlord.MapMarkers:IsOutpostMapContentDirty()) then
                    Overlord.MapMarkers:RefreshOutpostOverlays(mapID, nil,
                        layoutChanged, contentRefresh)
                end
            end
        elseif gkSite and Overlord.GuildKeep:IsKeepSiteDisplayMap(mapID, gkSite) then
            Overlord.MapMarkers:SetWorldMapOverlayMode("gk")
            Overlord.MapMarkers._renderFront = nil
            if layoutChanged or Overlord.MapMarkers:IsGuildKeepMapContentDirty()
                or Overlord.MapMarkers:IsGuildKeepOverlayLabelsMissing()
                or contentRefresh then
                Overlord.MapMarkers:RefreshGuildKeepOverlays(mapID, layoutChanged, contentRefresh)
            end
            if Overlord.Zones.IsWoodMapID and Overlord.Zones:IsWoodMapID(mapID) then
                if contentRefresh or layoutChanged then
                    Overlord.MapMarkers:RefreshWoodOverlays(mapID)
                end
            elseif Overlord.MapMarkers.HideWoodOverlays then
                Overlord.MapMarkers:HideWoodOverlays()
            end
        elseif Overlord.Zones:IsMineMapID(mapID) then
            Overlord.MapMarkers:SetWorldMapOverlayMode("mine")
            Overlord.MapMarkers._renderFront = nil
            if contentRefresh or layoutChanged then
                Overlord.MapMarkers:RefreshMineOverlays(mapID)
            end
            if Overlord.Zones.IsWoodMapID and Overlord.Zones:IsWoodMapID(mapID) then
                if contentRefresh or layoutChanged then
                    Overlord.MapMarkers:RefreshWoodOverlays(mapID)
                end
            elseif Overlord.MapMarkers.HideWoodOverlays then
                Overlord.MapMarkers:HideWoodOverlays()
            end
        elseif Overlord.Zones.IsWoodMapID and Overlord.Zones:IsWoodMapID(mapID) then
            Overlord.MapMarkers:SetWorldMapOverlayMode("wood")
            Overlord.MapMarkers._renderFront = nil
            if contentRefresh or layoutChanged then
                Overlord.MapMarkers:RefreshWoodOverlays(mapID)
            end
        elseif Overlord.MapMarkers:IsEKMap(mapID) then
            Overlord.MapMarkers:SetWorldMapOverlayMode("ek")
            Overlord.MapMarkers._renderFront = nil
            local ekContent = contentRefresh
            local keepDirty = Overlord.MapMarkers.IsGuildKeepMapContentDirty
                and Overlord.MapMarkers:IsGuildKeepMapContentDirty()
            local outpostDirty = Overlord.MapMarkers.IsOutpostMapContentDirty
                and Overlord.MapMarkers:IsOutpostMapContentDirty()
            -- Un pan/zoom modifie l'empreinte layout. Hors changement de geometrie ou de
            -- donnees, les pins sont deja correctement places : ne pas reconstruire leurs
            -- listes ni leurs tables seen a chaque frame de la carte continentale.
            if layoutChanged or contentRefresh or keepDirty then
                Overlord.MapMarkers:RefreshGuildKeepOverlays(mapID, layoutChanged, contentRefresh)
            end
            if Overlord.Fronts and Overlord.Fronts.activeFrontId
                and (layoutChanged or ekContent or outpostDirty) then
                Overlord.MapMarkers:RefreshOutpostOverlays(mapID, Overlord.Fronts.activeFrontId,
                    layoutChanged, ekContent)
            end
            if layoutChanged or contentRefresh then
                Overlord.MapMarkers:RefreshEKGoldMinePins()
                Overlord.MapMarkers:RefreshContinentWoodPins()
                Overlord.MapMarkers:RefreshContinentBountyPins()
                Overlord.MapMarkers:RefreshContinentManualBountyPins()
                Overlord.MapMarkers:RefreshContinentGeneralPins()
            end
            -- Logos dominance : layout/contenu seulement (pas 60 Hz pan/zoom idle).
            if layoutChanged or contentRefresh then
                Overlord.MapMarkers:RefreshEKDominance(ekContent)
            end
        elseif Overlord.MapMarkers:IsKalimdorMap(mapID) then
            Overlord.MapMarkers:SetWorldMapOverlayMode("kalimdor")
            Overlord.MapMarkers._renderFront = nil
            local kalContent = contentRefresh
            local keepDirty = Overlord.MapMarkers.IsGuildKeepMapContentDirty
                and Overlord.MapMarkers:IsGuildKeepMapContentDirty()
            local outpostDirty = Overlord.MapMarkers.IsOutpostMapContentDirty
                and Overlord.MapMarkers:IsOutpostMapContentDirty()
            if layoutChanged or contentRefresh then
                Overlord.MapMarkers:RefreshContinentWoodPins()
            end
            if layoutChanged or contentRefresh or keepDirty then
                Overlord.MapMarkers:RefreshGuildKeepOverlays(mapID, layoutChanged, contentRefresh)
            end
            if Overlord.Fronts and Overlord.Fronts.activeFrontId
                and (layoutChanged or kalContent or outpostDirty) then
                Overlord.MapMarkers:RefreshOutpostOverlays(mapID, Overlord.Fronts.activeFrontId,
                    layoutChanged, kalContent)
            end
            if layoutChanged or contentRefresh then
                Overlord.MapMarkers:RefreshContinentBountyPins()
                Overlord.MapMarkers:RefreshContinentManualBountyPins()
                Overlord.MapMarkers:RefreshContinentGeneralPins()
            end
            if layoutChanged or contentRefresh then
                Overlord.MapMarkers:RefreshEKDominance(kalContent)
            end
        elseif Overlord.MapMarkers:IsGuildKeepProjectionMap(mapID)
            and not Overlord.MapMarkers:IsEKMap(mapID) then
            Overlord.MapMarkers:SetWorldMapOverlayMode("gk_region")
            Overlord.MapMarkers._renderFront = nil
            if layoutChanged or contentRefresh or Overlord.MapMarkers:IsGuildKeepMapContentDirty()
                or Overlord.MapMarkers:IsOutpostMapContentDirty() then
                Overlord.MapMarkers:RefreshGuildKeepOverlays(mapID, layoutChanged, contentRefresh)
                if Overlord.Fronts and Overlord.Fronts.activeFrontId then
                    Overlord.MapMarkers:RefreshOutpostOverlays(mapID, Overlord.Fronts.activeFrontId,
                        layoutChanged, contentRefresh)
                end
            end
        else
            local hadFrontRender = Overlord.MapMarkers._renderFront
            Overlord.MapMarkers:SetWorldMapOverlayMode("none")
            Overlord.MapMarkers._renderFront = nil
            if hadFrontRender then
                Overlord.MapMarkers:HideWarfrontOverlays()
            end
        end

        -- Hommage guilde (Durotar, Kalimdor…) : copie exacte pins fortin.
        -- layoutChanged (pas "true" fige) : RefreshGuildHonorOverlays fait un early-return sur
        -- (not layoutChanged and not contentRefresh) -- forcer true ici annulait ce garde-fou et
        -- relancait la boucle GuildHonorSites + le refresh complet a chaque frame (~60 Hz) tant que
        -- la carte EK/Kalimdor restait ouverte, meme sans pan/zoom ni changement de contenu.
        if Overlord.MapMarkers:IsEKMap(mapID) or Overlord.MapMarkers:IsKalimdorMap(mapID) then
            if Overlord.MapMarkers.RefreshGuildHonorOverlays then
                Overlord.MapMarkers:RefreshGuildHonorOverlays(mapID, layoutChanged, contentRefresh)
            end
        elseif layoutChanged or contentRefresh then
            if Overlord.MapMarkers.RefreshGuildHonorOverlays then
                Overlord.MapMarkers:RefreshGuildHonorOverlays(mapID, layoutChanged, contentRefresh)
            end
        end
    end)

    WorldMapFrame:HookScript("OnShow", function()
        if Overlord.InstanceSuspended then return end
        suppressFrontOverlaysUntilMapReopen = false
        -- Rafraichir trackedMapID sans le mettre a nil : le hook SetMapID a pu
        -- deja fournir la bonne valeur AVANT OnShow. Un reset a nil provoquait
        -- un clignotement (OnUpdate ne trouvait pas de front pendant ~0.3s).
        if WorldMapFrame.GetMapID then
            local ok, newID = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
            if ok and newID and newID > 0 then
                trackedMapID = newID
            end
        end
        local oldCanvas = cachedCanvas
        local oldParent = cachedOverlayParent
        cachedCanvas = nil
        cachedOverlayParent = nil
        CacheCanvas()
        PurgeStaleOverlays(oldCanvas, cachedCanvas, oldParent, cachedOverlayParent)
        overlayRefreshForced = true
        overlayRefreshAccum = 0
        driverState.worldAccum = driverState.worldInterval
        driverState.worldGateSlow = false
        driverState.canvasInvalidHidden = false
        driverState.catchUpHidden = false
        ResetMapLayoutKey()
        updateFrame:Show()
    end)
    WorldMapFrame:HookScript("OnHide", function()
        -- WoW 12.0.5 : ne rien faire en instance (evite taint)
        if Overlord.InstanceSuspended then return end
        suppressFrontOverlaysUntilMapReopen = false
        worldMapHiddenForNoWarMode = false
        driverState.worldAccum = driverState.worldInterval
        driverState.worldGateSlow = false
        driverState.canvasInvalidHidden = false
        driverState.catchUpHidden = false
        updateFrame:Hide()
        ResetMapLayoutKey()
        Overlord.MapMarkers:HideAllOverlays()
        Overlord.MapMarkers:HideEKDominance()
        Overlord.MapMarkers:HideMineOverlays()
        Overlord.MapMarkers:HideWoodOverlays()
        Overlord.MapMarkers:HideGuildKeepOverlays()
        if Overlord.MapMarkers.HideGuildHonorOverlays then
            Overlord.MapMarkers:HideGuildHonorOverlays()
        end
    end)

    -- Si la carte etait deja ouverte quand le module s'initialise, OnShow ne repasse pas.
    -- On demarre donc le ticker manuellement pour peindre les overlays du front courant.
    if WorldMapFrame:IsShown() then
        if WorldMapFrame.GetMapID then
            local ok, newID = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
            if ok and newID and newID > 0 then
                trackedMapID = newID
            end
        end
        local oldCanvas = cachedCanvas
        local oldParent = cachedOverlayParent
        cachedCanvas = nil
        cachedOverlayParent = nil
        CacheCanvas()
        PurgeStaleOverlays(oldCanvas, cachedCanvas, oldParent, cachedOverlayParent)
        overlayRefreshForced = true
        overlayRefreshAccum = 0
        driverState.worldAccum = driverState.worldInterval
        driverState.worldGateSlow = false
        driverState.canvasInvalidHidden = false
        driverState.catchUpHidden = false
        ResetMapLayoutKey()
        updateFrame:Show()
    end
end

local CIRCLE_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall"

local function AddCircleMask(frame, tex)
    pcall(function()
        local mask = frame:CreateMaskTexture()
        mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(tex)
        tex:AddMaskTexture(mask)
    end)
end

function Overlord.MapMarkers:CreateZoneOverlay(zone)
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return nil end

    -- Reutilise un overlay rendu au pool lors d'un changement de canvas : tous les
    -- visuels (tailles, couleurs, textes, position) sont reappliques par UpdateOverlay.
    local pooled = table.remove(overlayFramePool)
    if pooled then
        pooled:SetParent(parent)
        pooled:SetFrameStrata(parent:GetFrameStrata())
        pooled:SetFrameLevel(parent:GetFrameLevel() + 1)
        pooled.zone = zone
        pooled._olSnapD = nil
        pooled._olRibbonKey = nil
        pooled._olRibbonInit = nil
        pooled._olRibbonOk = nil
        if pooled.titleRibbonLeft then pooled.titleRibbonLeft:Hide() end
        if pooled.titleRibbonMid then pooled.titleRibbonMid:Hide() end
        if pooled.titleRibbonRight then pooled.titleRibbonRight:Hide() end
        if not pooled.titleBg then
            local titleBg = pooled:CreateTexture(nil, "ARTWORK", nil, 7)
            titleBg:Hide()
            pooled.titleBg = titleBg
        end
        pooled:Hide()
        return pooled
    end

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetFrameStrata(parent:GetFrameStrata())
    frame:SetFrameLevel(parent:GetFrameLevel() + 1)
    frame.zone = zone

    local fill = frame:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints()
    fill:SetColorTexture(1, 0, 0)
    fill:SetAlpha(0.25)
    frame.fill = fill
    AddCircleMask(frame, fill)

    local border = frame:CreateTexture(nil, "BORDER")
    border:SetPoint("CENTER")
    border:SetColorTexture(1, 0, 0)
    border:SetAlpha(0.5)
    frame.border = border

    AddCircleMask(frame, border)

    -- Ruban Warboard natif (UI-Frame-Neutral-Ribbon).
    local titleBg = frame:CreateTexture(nil, "ARTWORK", nil, 7)
    titleBg:Hide()
    frame.titleBg = titleBg

    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont(ZONE_TITLE_FONT, 14)
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:SetWordWrap(false)
    text:SetNonSpaceWrap(false)
    text:SetPoint("CENTER", 0, 14)
    text:SetShadowOffset(0, 0)
    frame.text = text

    local subtext = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtext:SetPoint("TOP", text, "BOTTOM", 0, -4)
    subtext:SetShadowOffset(0, 0)
    frame.subtext = subtext

    local subtext2 = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtext2:SetPoint("TOP", subtext, "BOTTOM", 0, -4)
    subtext2:SetShadowOffset(0, 0)
    frame.subtext2 = subtext2

    -- Icone warfront positionnee sous le sous-titre (masquee initialement)
    local iconTex = frame:CreateTexture(nil, "OVERLAY")
    iconTex:SetPoint("CENTER", 0, 0)
    iconTex:Hide()
    frame.iconTex = iconTex

    frame:Hide()
    return frame
end

-- Couleurs de zone basees sur le proprietaire (bleu=allie, rouge=ennemi)
-- Multiplicateur d'opacite carte monde (option utilisateur ; minimap et mines non concernes)
local function GetMapOverlayOpacityScale()
    local v = OverlordDB and OverlordDB.config and OverlordDB.config.mapOverlayOpacity
    if v == nil then return 1.0 end
    v = tonumber(v) or 1.0
    if v < 0.2 then v = 0.2 end
    if v > 1.0 then v = 1.0 end
    return v
end

-- Multiplicateur d'opacite cercles de capture sur la minimap (option utilisateur ; mines / forets non concernes)
local function GetMinimapOverlayOpacityScale()
    local v = OverlordDB and OverlordDB.config and OverlordDB.config.minimapOverlayOpacity
    if v == nil then return 1.0 end
    v = tonumber(v) or 1.0
    if v < 0.2 then v = 0.2 end
    if v > 1.0 then v = 1.0 end
    return v
end

local function GetFactionZoneColors(zone)
    if Overlord.IsLoginZoneDisplayPending and Overlord:IsLoginZoneDisplayPending(zone) then
        return 0.55, 0.55, 0.48, 0.12, 0.34
    end
    local pf = Overlord.PlayerFaction
    if zone.status == "in_progress" then
        return 1, 0.45, 0.05, 0.38, 0.72
    elseif not zone.owner then
        if zone.status == "available" then
            return 0.62, 0.65, 0.60, 0.34, 0.58
        end
        return 0.48, 0.51, 0.54, 0.10, 0.22
    elseif zone.owner == pf then
        if pf == "Alliance" then
            return 0.15, 0.45, 0.85, 0.25, 0.5
        else
            return 0.72, 0.12, 0.10, 0.25, 0.5
        end
    elseif zone.owner and zone.owner ~= pf then
        if pf == "Alliance" then
            return 0.85, 0.15, 0.15, 0.25, 0.5
        else
            return 0.20, 0.50, 0.90, 0.25, 0.5
        end
    elseif zone.status == "available" then
        return 1, 0.8, 0, 0.25, 0.55
    else
        return 0.4, 0.4, 0.4, 0.08, 0.2
    end
end

function Overlord.MapMarkers:UpdateOverlayLayout(overlay)
    local zone = overlay.zone
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return end

    local diameter = PlaceWorldMapCircleOverlay(overlay, zone, canvas, parent, GetFrontOverlayDiameter)
    if not diameter then return end
    local snapD = math.floor(diameter + 0.5)
    local labelDiameter = GetFrontOverlayLabelDiameter(zone, canvas, parent) or diameter
    local showTitles = ShouldShowMapZoneTitles()

    -- Pan sans zoom : le cercle bouge seul ; texte/icone suivent le frame sans ClearAllPoints.
    if overlay._olSnapD == snapD and overlay._olLabelDiameter == labelDiameter
        and overlay._olShowTitles == showTitles then
        return
    end
    if overlay._olShowTitles ~= showTitles then
        -- La branche d'affichage masque/reancre des FontString. Forcer un repaint
        -- de contenu lors de la reactivation pour restaurer texte et sous-titres.
        overlay._olPaintValid = false
    end
    overlay._olSnapD = snapD
    overlay._olLabelDiameter = labelDiameter
    overlay._olShowTitles = showTitles

    local borderScale = 1.08
    overlay.border:SetSize(snapD * borderScale, snapD * borderScale)

    local titleSz = math.max(9, math.min(24, labelDiameter * 0.14))
    local subSz = math.max(7, math.min(18, labelDiameter * 0.10))
    local titleYOffset = math.max(12, labelDiameter * 0.16)
    overlay.text:SetFont(ZONE_TITLE_FONT, titleSz)
    overlay.text:ClearAllPoints()
    overlay.text:SetPoint("CENTER", overlay, "CENTER", 0, titleYOffset)
    overlay.subtext:SetFont(Overlord.UI.ResolveLocalizedFontPath(GameFontNormalSmall, "Fonts\\FRIZQT__.TTF"), subSz, "")
    overlay.subtext:ClearAllPoints()
    overlay.subtext:SetPoint("TOP", overlay.text, "BOTTOM", 0, -math.max(1, subSz * 0.08))
    overlay.subtext2:SetFont(Overlord.UI.ResolveLocalizedFontPath(GameFontNormalSmall, "Fonts\\FRIZQT__.TTF"), subSz, "")
    overlay.subtext2:ClearAllPoints()
    overlay.subtext2:SetPoint("TOP", overlay.subtext, "BOTTOM", 0, -math.max(1, subSz * 0.06))

    if overlay.iconTex and overlay.iconTex:IsShown() then
        local anchorTarget = (overlay.subtext2:GetText() ~= "") and overlay.subtext2 or overlay.subtext
        local iconSize = math.max(10, labelDiameter * 0.28)
        overlay.iconTex:ClearAllPoints()
        overlay.iconTex:SetPoint("TOP", anchorTarget, "BOTTOM", 0, 1)
        overlay.iconTex:SetSize(iconSize, iconSize)
    end
    overlay._olRibbonKey = nil
    LayoutZoneTitleRibbon(overlay)
end

function Overlord.MapMarkers:UpdateOverlay(overlay)
    local zone = overlay.zone
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return end

    local cw = canvas:GetWidth()
    if not cw or cw == 0 then return end

    self:UpdateOverlayLayout(overlay)

    local diameter = overlay:GetWidth()
    local labelDiameter = overlay._olLabelDiameter or diameter
    local pf = Overlord.PlayerFaction
    local r, g, b, fa, ba = GetFactionZoneColors(zone)
    local st = ""
    local st2 = ""
    local renderFid = self._renderFront and self._renderFront.id
    local onTruce, truceRemaining = Overlord.Zones:IsFrontOnTruce(zone.id, renderFid, true)
    local loginPending = Overlord.IsLoginZoneDisplayPending
        and Overlord:IsLoginZoneDisplayPending(zone)

    if loginPending then
        st = L.MAP_SYNC_PENDING or L.MAP_NEUTRAL or "SYNC"
    elseif onTruce then
        st = string.format(L.SIEGE_COOLDOWN_LABEL, Overlord.Zones:FormatDuration(truceRemaining))
    elseif zone.status == "in_progress" then
        local elapsed = (Overlord.Zones and Overlord.Zones.GetObserverHoldTimeElapsed)
            and Overlord.Zones:GetObserverHoldTimeElapsed(zone) or (zone.holdTimeElapsed or 0)
        local rest = math.max(0, (zone.holdTimeRequired or 120) - elapsed)
        local timer = string.format("%d:%02d", math.floor(rest / 60), math.floor(rest % 60))
        st = timer
    elseif zone.owner == pf then
        st = pf
    elseif zone.owner and zone.owner ~= pf then
        st = zone.owner
    elseif not zone.owner and zone.status == "available" then
        st = L.MAP_AVAILABLE
    elseif not zone.owner then
        st = L.MAP_NEUTRAL
    elseif zone.status == "available" then
        st = L.MAP_AVAILABLE
    else
        st = L.MAP_LOCKED
    end

    if zone.isCapital and not onTruce and not loginPending then
        if zone.status == "in_progress" then
            if st2 == "" then st2 = L.MAP_CAPITAL_LABEL end
        elseif zone.owner then
            st = L.MAP_CAPITAL_LABEL
        end
    end

    local opacityScale = GetMapOverlayOpacityScale()
    local borderAlpha = ba * opacityScale
    local fillAlpha = fa * opacityScale
    local iconAtlas = Overlord.Zones:GetZoneMapIconAtlas(zone, true)
    if overlay._olPaintValid
        and overlay._olPaintName == zone.name
        and overlay._olPaintSt == st
        and overlay._olPaintSt2 == st2
        and overlay._olPaintR == r and overlay._olPaintG == g and overlay._olPaintB == b
        and overlay._olPaintFillAlpha == fillAlpha
        and overlay._olPaintBorderAlpha == borderAlpha
        and overlay._olPaintIconAtlas == iconAtlas then
        return
    end
    overlay._olPaintValid = true
    overlay._olPaintName = zone.name
    overlay._olPaintSt = st
    overlay._olPaintSt2 = st2
    overlay._olPaintR, overlay._olPaintG, overlay._olPaintB = r, g, b
    overlay._olPaintFillAlpha = fillAlpha
    overlay._olPaintBorderAlpha = borderAlpha
    overlay._olPaintIconAtlas = iconAtlas
    overlay.fill:Show()
    overlay.fill:SetColorTexture(r, g, b)
    overlay.fill:SetAlpha(fillAlpha)
    overlay.border:SetColorTexture(r, g, b)
    overlay.border:SetAlpha(borderAlpha)
    -- Titre sur ruban parchemin : brun fonce (style Warboard). Sous-titres restent dores.
    overlay.text:SetTextColor(ZONE_TITLE_PARCHMENT_R, ZONE_TITLE_PARCHMENT_G, ZONE_TITLE_PARCHMENT_B)
    overlay.text:SetShadowColor(0, 0, 0, 0)
    overlay.text:SetShadowOffset(0, 0)

    overlay.text:SetText(zone.name)
    overlay.subtext:SetText(st)
    overlay.subtext2:SetText(st2)
    overlay.text:Show()
    overlay.subtext:Show()
    overlay.subtext2:Show()
    LayoutZoneTitleRibbon(overlay)
    overlay.subtext:SetTextColor(ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B)
    overlay.subtext:SetShadowColor(0, 0, 0, 0)
    overlay.subtext:SetShadowOffset(0, 0)
    overlay.subtext2:SetTextColor(ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B)
    overlay.subtext2:SetShadowColor(0, 0, 0, 0)
    overlay.subtext2:SetShadowOffset(0, 0)

    -- Icone : bannieres Warfronts (objectifs) ; MainHall (capitales) ; masquee si conteste avec owner
    if overlay.iconTex then
        if iconAtlas then
            local iconSize = math.max(10, labelDiameter * 0.28)
            local anchorTarget = (st2 ~= "") and overlay.subtext2 or overlay.subtext
            local iconLayoutKey = (anchorTarget == overlay.subtext2 and "2" or "1") .. ":" .. iconSize
                .. ":" .. (iconAtlas or "")
            if overlay._olIconLayoutKey ~= iconLayoutKey then
                overlay._olIconLayoutKey = iconLayoutKey
                overlay.iconTex:ClearAllPoints()
                overlay.iconTex:SetPoint("TOP", anchorTarget, "BOTTOM", 0, 1)
                overlay.iconTex:SetSize(iconSize, iconSize)
            end
            Overlord.Zones:ApplyZoneMapIcon(overlay.iconTex, iconAtlas)
            overlay.iconTex:Show()
        else
            overlay.iconTex:Hide()
            overlay._olIconLayoutKey = nil
        end
    end
end

-- Repositionnement geometrique seul (zoom/dezoom) : pas de recalcul statuts / objectifs.
function Overlord.MapMarkers:RefreshOverlayLayouts()
    for _, ov in pairs(overlays) do
        if ov and ov:IsShown() and ov.zone then
            self:UpdateOverlayLayout(ov)
        end
    end
end

function Overlord.MapMarkers:RefreshPathLayouts()
    local zones = (self._renderFront and self._renderFront.zones) or Overlord.ZoneDatabase
    if not zones then return end
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return end
    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 then return end

    local zoneById = pathZoneById
    wipe(pathZoneById)
    for _, zone in ipairs(zones) do
        zoneById[zone.id] = zone
    end
    for _, zone in ipairs(zones) do
        if zone.prereqZones then
            for _, prereqId in ipairs(zone.prereqZones) do
                local prereq = zoneById[prereqId]
                if prereq then
                    -- Meme cle que GetPathConnId (local, defini plus bas - pas d'appel forward ref).
                    local connId = prereqId .. ">" .. zone.id
                    if pathLines[connId] then
                        self:UpdatePathLine(connId, prereq, zone, canvas, cw, ch)
                    end
                end
            end
        end
    end
end

-- Demande un repaint carte au prochain OnUpdate pour les changements declenches
-- par un evenement, sans attendre le rafraichissement periodique a 2 Hz.
function Overlord.MapMarkers:RequestOverlayRefresh(contentOnly)
    overlayRefreshForced = true
    local now = GetTime()
    driverState.forcedNotBefore = math.max(
        now, driverState.lastContentRefreshAt + driverState.forcedMinInterval)
    -- Si le repaint est deja autorise, reveiller le driver tout de suite. Sinon le
    -- Le polling 20 Hz ne se reveille que pendant cette courte attente ; au repos,
    -- la branche lourde de carte dort a 2 Hz.
    if driverState.forcedNotBefore <= now then
        driverState.worldAccum = driverState.worldInterval
    end
    if not contentOnly then
        ResetMapLayoutKey()
    end
end

function Overlord.MapMarkers:RefreshOverlays()
    local zones = self._renderFront and self._renderFront.zones
    if not zones then return false end

    local parent = GetOverlayParent()
    local expected, rendered = 0, 0
    wipe(overlayVisibleZoneIds)
    for _, zone in ipairs(zones) do
        expected = expected + 1
        overlayVisibleZoneIds[zone.id] = true
        local ov = overlays[zone.id]
        -- Si le canvas a change (re-creation du ScrollContainer.Child entre deux
        -- ouvertures de carte), rendre l'overlay au pool : CreateZoneOverlay le
        -- reattachera au nouveau parent au lieu de creer une frame de plus.
        if ov and parent and ov:GetParent() ~= parent then
            ov:Hide()
            overlayFramePool[#overlayFramePool + 1] = ov
            overlays[zone.id] = nil
            ov = nil
        end
        if not ov then
            ov = self:CreateZoneOverlay(zone)
            overlays[zone.id] = ov
        end
        if ov then
            self:UpdateOverlay(ov)
            ov:Show()
            rendered = rendered + 1
        end
    end
    for zoneId, ov in pairs(overlays) do
        if ov and not overlayVisibleZoneIds[zoneId] then
            HideZoneOverlayText(ov)
            ov:Hide()
        end
    end
    return expected > 0 and rendered == expected
end

-- Cercles / chemins de front uniquement (ne pas toucher au fortin : evite scintillement)
function Overlord.MapMarkers:HideWarfrontOverlays()
    for _, ov in pairs(overlays) do
        if ov then
            HideZoneOverlayText(ov)
            if ov:IsShown() then ov:Hide() end
        end
    end
    self:HideAllPaths()
    self:HideCatchUpBanner()
end

function Overlord.MapMarkers:HideAllOverlays()
    self:HideWarfrontOverlays()
    self:HideGuildKeepOverlays()
    if self.HideOutpostOverlays then self:HideOutpostOverlays() end
    self:HideProjectedKeepPins()
    if Overlord.BountyMap and Overlord.BountyMap.Hide then
        Overlord.BountyMap:Hide()
    end
    if Overlord.ManualBountyMap and Overlord.ManualBountyMap.Hide then
        Overlord.ManualBountyMap:Hide()
    end
    if Overlord.GeneralMap and Overlord.GeneralMap.Hide then
        Overlord.GeneralMap:Hide()
    end
    if Overlord.MapMarkers.HideGuildHonorOverlays then
        Overlord.MapMarkers:HideGuildHonorOverlays()
    end
end

-- Bandeau phase de rattrapage sur le canvas de la carte du monde
function Overlord.MapMarkers:ShowCatchUpBanner()
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return end
    if not catchUpBanner then
        catchUpBanner = CreateFrame("Frame", nil, parent)
        catchUpBanner:SetSize(340, 32)
        local bg = catchUpBanner:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.7)
        local text = catchUpBanner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        text:SetPoint("CENTER")
        text:SetTextColor(1, 0.82, 0)
        catchUpBanner._text = text
    end
    catchUpBanner._text:SetText(L and L.CATCHUP_MAP_BANNER or "Catch-up phase")
    catchUpBanner:ClearAllPoints()
    catchUpBanner:SetPoint("TOP", parent, "TOP", 0, -40)
    catchUpBanner:SetParent(parent)
    catchUpBanner:Show()
end

function Overlord.MapMarkers:HideCatchUpBanner()
    if catchUpBanner and catchUpBanner:IsShown() then catchUpBanner:Hide() end
end

-- Relance le rendu des overlays si la carte est deja ouverte.
-- Appele depuis ResumeFromInstance : si le joueur a ouvert la carte pendant que
-- InstanceSuspended etait encore true, le hook OnShow a ete ignore et les overlays
-- restent caches. Cette methode rattrape ce cas.
function Overlord.MapMarkers:ResumeWorldMapOverlays()
    if not self._updateFrame then return end
    local function kick()
        if Overlord.InstanceSuspended then return end
        if not WorldMapFrame then return end
        if WorldMapFrame.IsShown and not WorldMapFrame:IsShown() then return end
        if WorldMapFrame.GetMapID then
            local ok, newID = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
            if ok and newID and newID > 0 then
                trackedMapID = newID
            end
        end
        local oldCanvas = cachedCanvas
        local oldParent = cachedOverlayParent
        cachedCanvas = nil
        cachedOverlayParent = nil
        CacheCanvas()
        PurgeStaleOverlays(oldCanvas, cachedCanvas, oldParent, cachedOverlayParent)
        overlayRefreshForced = true
        overlayRefreshAccum = 0
        driverState.worldAccum = driverState.worldInterval
        driverState.canvasInvalidHidden = false
        driverState.catchUpHidden = false
        ResetMapLayoutKey()
        self._updateFrame:Show()
    end
    kick()
    -- Meme frame / frame suivante : le canvas n'est pas toujours pret au premier tick apres loading.
    C_Timer.After(0, kick)
    C_Timer.After(0.2, kick)
    C_Timer.After(0.6, kick)
end

-- ============ Pointilles entre zones (style ESO Cyrodiil) ============

local MAP_PATH_OPACITY_MIN = 1.0
local MAP_PATH_OPACITY_MAX = 3.0

local function GetMapPathOpacityScale()
    local v = OverlordDB and OverlordDB.config and OverlordDB.config.mapPathOpacity
    v = tonumber(v) or MAP_PATH_OPACITY_MIN
    if v < MAP_PATH_OPACITY_MIN then v = MAP_PATH_OPACITY_MIN end
    if v > MAP_PATH_OPACITY_MAX then v = MAP_PATH_OPACITY_MAX end
    return v
end

-- Couleur selon proprietaire (chemins objectif suivant : meme regles que le reste du reseau)
local function GetPathColor(fromZone, toZone)
    if Overlord.IsLoginZoneDisplayPending
        and (Overlord:IsLoginZoneDisplayPending(fromZone) or Overlord:IsLoginZoneDisplayPending(toZone)) then
        return 0.42, 0.42, 0.38, 0.30
    end
    local pf = Overlord.PlayerFaction
    local ef = Overlord.Zones:GetEnemyFaction()
    if fromZone.owner == pf and toZone.owner == pf then
        return 0.2, 0.5, 0.9, 0.48
    elseif fromZone.owner == pf then
        return 0.45, 0.50, 0.60, 0.42
    elseif fromZone.owner == ef and toZone.owner == ef then
        return 0.75, 0.15, 0.15, 0.40
    elseif fromZone.owner == ef or toZone.owner == ef then
        return 0.35, 0.35, 0.38, 0.40
    else
        return 0.32, 0.32, 0.35, 0.45
    end
end

local function GetPathConnId(prereqId, zoneId)
    local byPrereq = pathConnIdCache[prereqId]
    if not byPrereq then
        byPrereq = {}
        pathConnIdCache[prereqId] = byPrereq
    end
    local connId = byPrereq[zoneId]
    if not connId then
        connId = prereqId .. ">" .. zoneId
        byPrereq[zoneId] = connId
    end
    return connId
end

local function UpdatePathLineColors(path, fromZone, toZone)
    if not path or not path.dots then return end
    local numDots = path.visibleDots or #path.dots
    if numDots <= 0 then return end
    local pathScale = GetMapPathOpacityScale()
    local r, g, b, baseA = GetPathColor(fromZone, toZone)
    if path.visualDots == numDots and path.visualScale == pathScale
        and path.visualR == r and path.visualG == g and path.visualB == b
        and path.visualBaseAlpha == baseA then
        return
    end
    path.visualDots = numDots
    path.visualScale = pathScale
    path.visualR, path.visualG, path.visualB = r, g, b
    path.visualBaseAlpha = baseA
    for i = 1, numDots do
        local dot = path.dots[i]
        if dot then
            local t = (i - 0.5) / numDots
            local dotAlpha = math.min(1, baseA * pathScale * (0.55 + 0.45 * t))
            if dot._olR ~= r or dot._olG ~= g or dot._olB ~= b then
                dot:SetColorTexture(r, g, b)
                dot._olR, dot._olG, dot._olB = r, g, b
            end
            if dot._olAlpha ~= dotAlpha then
                dot:SetAlpha(dotAlpha)
                dot._olAlpha = dotAlpha
            end
            if not dot:IsShown() then dot:Show() end
        end
    end
end

function Overlord.MapMarkers:RefreshPaths()
    local zones = self._renderFront and self._renderFront.zones
    if not zones then return end
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return end
    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 then return end

    wipe(pathZoneById)
    wipe(pathVisibleConnIds)
    for _, zone in ipairs(zones) do
        pathZoneById[zone.id] = zone
    end

    for _, zone in ipairs(zones) do
        if zone.prereqZones then
            for _, prereqId in ipairs(zone.prereqZones) do
                local prereq = pathZoneById[prereqId]
                if prereq then
                    local connId = GetPathConnId(prereqId, zone.id)
                    pathVisibleConnIds[connId] = true
                    local path = pathLines[connId]
                    local pathScale = GetMapPathOpacityScale()
                    if path and path.layoutCw == cw and path.layoutCh == ch
                        and path.layoutRevision == driverState.mapLayoutRevision
                        and path.pathScale == pathScale then
                        UpdatePathLineColors(path, prereq, zone)
                    else
                        self:UpdatePathLine(connId, prereq, zone, canvas, cw, ch)
                    end
                end
            end
        end
    end
    for connId, path in pairs(pathLines) do
        if not pathVisibleConnIds[connId] and path.dots then
            for _, dot in ipairs(path.dots) do
                dot:Hide()
            end
            path.visible = false
            path.visualDots = nil
        end
    end
end

function Overlord.MapMarkers:UpdatePathLine(connId, fromZone, toZone, canvas, cw, ch)
    local parent = GetOverlayParent()
    if not canvas or not parent then return end

    local x1 = (fromZone.center[1] / 100) * cw
    local y1 = (fromZone.center[2] / 100) * ch
    local x2 = (toZone.center[1] / 100) * cw
    local y2 = (toZone.center[2] / 100) * ch

    local dx = x2 - x1
    local dy = y2 - y1
    local fullLen = math.sqrt(dx * dx + dy * dy)
    if fullLen < 1 then return end

    -- Raccourcit les extremites pour ne pas chevaucher les cercles de zone
    local nx, ny = dx / fullLen, dy / fullLen
    local d1 = GetFrontOverlayDiameter(fromZone, canvas, parent)
    local d2 = GetFrontOverlayDiameter(toZone, canvas, parent)
    if not d1 or not d2 then return end
    local scaleRatio = GetCanvasToOverlayScaleRatio(canvas, parent)
    local r1 = ((d1 / 2) * 1.15) / scaleRatio
    local r2 = ((d2 / 2) * 1.15) / scaleRatio
    x1 = x1 + nx * r1
    y1 = y1 + ny * r1
    x2 = x2 - nx * r2
    y2 = y2 - ny * r2

    dx = x2 - x1
    dy = y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 4 then return end

    local pathScale = GetMapPathOpacityScale()
    local r, g, b, baseA = GetPathColor(fromZone, toZone)

    local DOT_SIZE = 3 + pathScale
    local SPACING = math.max(5, 10 - math.floor(pathScale))
    local numDots = math.max(1, math.floor(len / SPACING))

    if not pathLines[connId] then
        pathLines[connId] = { dots = {} }
    end
    local path = pathLines[connId]
    path.layoutCw = cw
    path.layoutCh = ch
    path.layoutRevision = driverState.mapLayoutRevision
    path.pathScale = pathScale
    path.visibleDots = numDots
    path.visible = true
    path.visualDots = numDots
    path.visualScale = pathScale
    path.visualR, path.visualG, path.visualB = r, g, b
    path.visualBaseAlpha = baseA
    if path.line then
        path.line:Hide()
        path.line = nil
    end
    path.dots = path.dots or {}

    -- Cree les dots manquants (reuse du pool apres changement de canvas)
    while #path.dots < numDots do
        local dot = table.remove(pathDotPool)
        if dot then
            dot:SetParent(parent)
        else
            dot = parent:CreateTexture(nil, "ARTWORK")
            dot:SetColorTexture(1, 1, 1)
        end
        table.insert(path.dots, dot)
    end

    -- Positionne et colore chaque dot
    for i = 1, numDots do
        local t = (i - 0.5) / numDots
        local px = x1 + dx * t
        local py = y1 + dy * t
        -- Les dots grossissent legerement vers la destination (effet de direction)
        local sizeFactor = 0.7 + 0.6 * t
        local dotAlpha = math.min(1, baseA * pathScale * (0.55 + 0.45 * t))

        local dot = path.dots[i]
        local ox, oy = GetOverlayPoint(canvas, parent, px, py)
        if not ox or not oy then
            dot:Hide()
        else
            local dotSize = DOT_SIZE * sizeFactor
            PlaceMapPinCenter(dot, parent, ox, oy, dotSize)
            -- Meme methode que les cercles de zone : RGB + SetAlpha (le 4e arg de SetColorTexture
            -- n'est pas fiable sur la carte monde en 12.0.5, le curseur semblait ne rien faire).
            if dot._olR ~= r or dot._olG ~= g or dot._olB ~= b then
                dot:SetColorTexture(r, g, b)
                dot._olR, dot._olG, dot._olB = r, g, b
            end
            if dot._olAlpha ~= dotAlpha then
                dot:SetAlpha(dotAlpha)
                dot._olAlpha = dotAlpha
            end
        end
    end

    -- Masque les dots en trop
    for i = numDots + 1, #path.dots do
        path.dots[i]:Hide()
    end
end

function Overlord.MapMarkers:HideAllPaths()
    for _, path in pairs(pathLines) do
        if path.dots then
            for _, dot in ipairs(path.dots) do
                if dot:IsShown() then dot:Hide() end
            end
        end
        path.visualDots = nil
    end
end

function Overlord.MapMarkers:ShowAvailableZones()
    local pf = Overlord.PlayerFaction
    local ef = Overlord.Zones:GetEnemyFaction()
    local frontName = Overlord.Fronts and Overlord.Fronts:GetMapName()
    if not frontName or frontName == "" then return end
    Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. string.format(L.FRONT_ZONES_HEADER, frontName))
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        local c = string.format("%.1f, %.1f", zone.center[1], zone.center[2])
        if zone.status == "in_progress" then
            local elapsed = (Overlord.Zones and Overlord.Zones.GetObserverHoldTimeElapsed)
                and Overlord.Zones:GetObserverHoldTimeElapsed(zone) or (tonumber(zone.holdTimeElapsed) or 0)
            local r = math.max(0, (zone.holdTimeRequired or 120) - elapsed)
            Overlord:PrintNotification(string.format("  |cFFFFD100[~] %s|r - %d:%02d", zone.name, math.floor(r/60), math.floor(r%60)))
        elseif zone.owner == pf then
            Overlord:PrintNotification(string.format("  |cFF4488FF[%s] %s|r", pf, zone.name))
        elseif zone.owner == ef then
            local tag = zone.status == "available" and "!" or "X"
            Overlord:PrintNotification(string.format("  |cFFFF4444[%s] %s|r - %s", tag, zone.name, ef))
        elseif not zone.owner and zone.status == "available" then
            Overlord:PrintNotification(string.format("  |cFFB0B8B0[!] %s|r - %s", zone.name, c))
        elseif not zone.owner then
            Overlord:PrintNotification(string.format("  |cFF8A9098[X] %s|r - %s", zone.name, L.MM_NEUTRAL))
        elseif zone.status == "available" then
            Overlord:PrintNotification(string.format("  |cFFFFFF00[!] %s|r - %s", zone.name, c))
        else
            Overlord:PrintNotification(string.format("  |cFF888888[X] %s|r", zone.name))
        end
    end
end

-- ============ Bouton minimap + indicateurs minimap ============

local ADDON_ICON = "Interface\\AddOns\\Overlord\\Textures\\overlord_minimap"
local minimapButton = nil
local minimapPins = {}

local function IsMinimapButtonEnabled()
    return not (OverlordDB and OverlordDB.config
        and OverlordDB.config.showMinimapButton == false)
end

-- Echelle yards-par-pourcent de carte (calculee dynamiquement).
local mmYardsPerPctX, mmYardsPerPctY = nil, nil
local mmScaleCalculatedFor = nil
local mmScaleCalculatedMapID = nil
local mmFrame = nil  -- Garde une ref pour SetMinimapPinsVisible (appele depuis Core)
-- La position seule suit environ 60 Hz ; donnees, styles et reconciliations restent a 2 Hz.
-- Le pixel-cache de PlaceMinimapPinCenter evite tout SetPoint si un pin n'a pas bouge.
local MM_POS_INTERVAL = 1 / 60
local MM_DATA_INTERVAL = 0.5
local mmPosAcc = 0
local mmDataAcc = MM_DATA_INTERVAL
-- Zones, mines et keep partagent le meme driver mmFrame (meme cache position, ~60 Hz en mouvement).
-- mmMineMapActive : on est sur une carte a mines -> mmFrame doit tourner meme hors front actif.
local mmMineMapActive = false
local mmWoodMapActive = false
-- Cache position joueur (partagee entre zones/mines/keep pour eviter appels C_Map redondants)
local mmCachedMapID = nil
local mmCachedPX, mmCachedPY = 0, 0
local mmCachedFacing = 0
local mmCachedRotate = false
local mmCachedHalfMM = 0
local mmCachedPxPerYard = 0
local mmSharedDriverContext = {}

local function IsPlayerStationaryForMinimap()
    return GetUnitSpeed and (GetUnitSpeed("player") or 0) <= 0
end

function driverState.WakeMinimapDriver()
    driverState.minimapMovementActive = true
    driverState.minimapPositionRefreshForced = true
    mmPosAcc = MM_POS_INTERVAL
end

local function GetPlayerPositionForResourceMap(mapID)
    if not mapID then return nil, nil end
    if mapID == mmCachedMapID then
        return mmCachedPX, mmCachedPY
    end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or not pos then return nil, nil end
    local ok2, px, py = pcall(pos.GetXY, pos)
    if not ok2 or not px then return nil, nil end
    return px * 100, py * 100
end

local function ClampMinimapPinXY(pinX, pinY, halfMM, inset)
    inset = inset or 0
    local maxDist = math.max(0, halfMM - inset)
    local dist = math.sqrt(pinX * pinX + pinY * pinY)
    if dist > maxDist and dist > 0 then
        local s = maxDist / dist
        pinX, pinY = pinX * s, pinY * s
        dist = maxDist
    end
    return pinX, pinY, dist
end

local function PlaceMinimapPinCenter(pin, pinX, pinY)
    if not pin then return false end
    pinX = SnapMapPinCoord(pinX)
    pinY = SnapMapPinCoord(pinY)
    if pin._olMMX == pinX and pin._olMMY == pinY then
        return true
    end
    pin._olMMX = pinX
    pin._olMMY = pinY
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", Minimap, "CENTER", pinX, pinY)
    return true
end

local function AddMinimapClipMask(pin, tex)
    pcall(function()
        local mask = pin:CreateMaskTexture()
        mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetPoint("TOPLEFT", Minimap, "TOPLEFT")
        mask:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT")
        tex:AddMaskTexture(mask)
    end)
end

local function CreateMinimapCirclePin(fillColor, borderColor)
    local pin = CreateFrame("Frame", nil, Minimap)
    pin:SetFrameStrata("MEDIUM")
    pin:SetFrameLevel(6)

    local fill = pin:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints()
    fill:SetColorTexture(fillColor[1], fillColor[2], fillColor[3], fillColor[4])
    pin.fill = fill
    AddCircleMask(pin, fill)

    local border = pin:CreateTexture(nil, "BORDER")
    border:SetPoint("CENTER")
    border:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
    pin.border = border
    AddCircleMask(pin, border)

    AddMinimapClipMask(pin, fill)
    AddMinimapClipMask(pin, border)
    return pin
end

local function StyleMinimapCirclePin(pin, diameter, r, g, b, fillAlpha, borderAlpha, borderR, borderG, borderB)
    if pin._olDiam ~= diameter then
        pin:SetSize(diameter, diameter)
        if pin.border then pin.border:SetSize(diameter * 1.15, diameter * 1.15) end
        pin._olDiam = diameter
    end
    borderR, borderG, borderB = borderR or r, borderG or g, borderB or b
    if pin._olR ~= r or pin._olG ~= g or pin._olB ~= b
        or pin._olBR ~= borderR or pin._olBG ~= borderG or pin._olBB ~= borderB
        or pin._olFillAlpha ~= fillAlpha or pin._olBorderAlpha ~= borderAlpha then
        pin.fill:SetColorTexture(r, g, b, fillAlpha)
        if pin.border then pin.border:SetColorTexture(borderR, borderG, borderB, borderAlpha) end
        pin._olR, pin._olG, pin._olB = r, g, b
        pin._olBR, pin._olBG, pin._olBB = borderR, borderG, borderB
        pin._olFillAlpha, pin._olBorderAlpha = fillAlpha, borderAlpha
    end
end

local function UpdateMinimapCirclePin(pin, center, radius, radiusScale, minDiameter,
    px, py, yppX, yppY, pxPerYard, halfMM, rotateMM, sinF, cosF, r, g, b, fillAlpha, borderAlpha,
    borderR, borderG, borderB, restyle)
    if not pin or not center or not radius then return end
    local dx = (center[1] - px) * yppX
    local dy = (center[2] - py) * yppY
    local pinX = dx * pxPerYard
    local pinY = -dy * pxPerYard
    if rotateMM then
        pinX, pinY = pinX * cosF - pinY * sinF, pinX * sinF + pinY * cosF
    end

    local avgYPP = (yppX + yppY) / 2
    local diameter = math.max(minDiameter or 8, radius * (radiusScale or 1) * avgYPP * 2 * pxPerYard)
    local visibleRadius = halfMM + diameter / 2
    if pinX * pinX + pinY * pinY > visibleRadius * visibleRadius then
        if pin:IsShown() then pin:Hide() end
        return
    end

    if restyle or pin._olDiam == nil then
        StyleMinimapCirclePin(pin, diameter, r, g, b, fillAlpha, borderAlpha, borderR, borderG, borderB)
    end
    PlaceMinimapPinCenter(pin, pinX, pinY)
    if not pin:IsShown() then pin:Show() end
end

-- Appele par Core quand on entre/sort d'un front actif (les events seuls ne suffisent pas)
function Overlord.MapMarkers:SetMinimapPinsVisible(visible)
    if not mmFrame then return end
    if visible then
        driverState.WakeMinimapDriver()
        mmFrame:Show()
    else
        mmFrame:Hide()
        self:HideMinimapPins()
    end
    self:EnsureMinimapDriverVisible()
end

-- Appele par Fronts:Activate quand ZoneDatabase change (changement de front en jeu).
function Overlord.MapMarkers:OnActiveFrontChanged()
    mmScaleCalculatedFor = nil
    mmScaleCalculatedMapID = nil
    mmDataAcc = MM_DATA_INTERVAL
    driverState.WakeMinimapDriver()
    self:CreateMinimapPins()
    if WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown() then
        suppressFrontOverlaysUntilMapReopen = true
        self._renderFront = nil
        self:HideAllOverlays()
        self:HideAllPaths()
        self:RequestOverlayRefresh()
    end
    if mmFrame and Overlord.InActiveFront and not Overlord.InstanceSuspended then
        mmFrame:Show()
    end
end

function Overlord.MapMarkers:InitializeMinimap()
    self:CreateMinimapButton()
    self:CreateMinimapPins()
    self:CreateMinimapMinePins()
    self:CreateMinimapWoodPins()
    self:CreateMinimapKeepPin()
    self:CreateMinimapOutpostPin()
    self:CalcMinimapScale()

    mmFrame = CreateFrame("Frame")
    mmFrame:Hide()
    mmFrame:SetScript("OnUpdate", function(_, elapsed)
        if Overlord.InstanceSuspended then
            mmFrame:Hide()
            return
        end
        mmPosAcc = mmPosAcc + elapsed
        mmDataAcc = mmDataAcc + elapsed
        local tickInterval = driverState.minimapMovementActive
            and MM_POS_INTERVAL or driverState.minimapIdleInterval
        if mmPosAcc < tickInterval then return end
        -- Conserver le reliquat : remettre a zero transformait 60 Hz en ~48 Hz sur
        -- un ecran 144 Hz (3 frames par tick) et recreait un mouvement irregulier.
        mmPosAcc = math.min(math.max(0, mmPosAcc - tickInterval), tickInterval)

        local fullRefresh = mmDataAcc >= MM_DATA_INTERVAL
        if fullRefresh then
            mmDataAcc = math.min(math.max(0, mmDataAcc - MM_DATA_INTERVAL), MM_DATA_INTERVAL)
        end

        -- Le mouvement reel garde le driver fluide. A l'arret, le prochain tick passe
        -- a 2 Hz ; une rotation detectee le reveille tant que l'orientation continue a changer.
        local speedOk, stationary = pcall(IsPlayerStationaryForMinimap)
        local facing = mmCachedRotate and (GetPlayerFacing() or 0) or 0
        local facingChanged = facing ~= mmCachedFacing
        local moving = not speedOk or not stationary
        driverState.minimapMovementActive = moving or facingChanged
        local forcedRefresh = driverState.minimapPositionRefreshForced
        driverState.minimapPositionRefreshForced = false
        if not fullRefresh and not driverState.minimapMovementActive and not forcedRefresh then
            return
        end

        -- Position joueur : une seule fois par tick, partagee entre tous les pins
        local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if not ok or not mapID then
            Overlord.MapMarkers:HideMinimapPins()
            Overlord.MapMarkers:HideMinimapMinePins()
            Overlord.MapMarkers:HideMinimapWoodPins()
            Overlord.MapMarkers:HideMinimapKeepPin()
            Overlord.MapMarkers:HideMinimapOutpostPin()
            return
        end
        local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
        if not ok2 or not pos then
            Overlord.MapMarkers:HideMinimapPins()
            Overlord.MapMarkers:HideMinimapMinePins()
            Overlord.MapMarkers:HideMinimapWoodPins()
            Overlord.MapMarkers:HideMinimapKeepPin()
            Overlord.MapMarkers:HideMinimapOutpostPin()
            return
        end
        local px, py = pos:GetXY()
        mmCachedMapID = mapID
        mmCachedPX, mmCachedPY = px * 100, py * 100
        -- Taille, rayon et mode de rotation changent rarement. Les relire avec les
        -- donnees (2 Hz) plutot qu'a chaque mouvement evite trois appels API par tick.
        -- Le premier tick est toujours un fullRefresh (mmDataAcc initialise ci-dessus).
        if fullRefresh or mmCachedHalfMM <= 0 or mmCachedPxPerYard <= 0 then
            local nextRotate = GetCVar("rotateMinimap") == "1"
            if nextRotate and not mmCachedRotate then facing = GetPlayerFacing() or 0 end
            mmCachedRotate = nextRotate
            mmCachedHalfMM = Minimap:GetWidth() / 2
            local viewRadius = Overlord.MapMarkers:GetMinimapRadius()
            mmCachedPxPerYard = mmCachedHalfMM / viewRadius
        end
        mmCachedFacing = mmCachedRotate and facing or 0

        if Overlord.InActiveFront then
            Overlord.MapMarkers:UpdateMinimapPins(fullRefresh)
            -- Un seul contexte partage pour primes, contrats et generaux. Les trois couches
            -- lisaient auparavant la meme position et recalculaient sin/cos separement par couche.
            local context = Overlord.MapMarkers:GetMinimapDriverContext()
            Overlord.MapMarkers:UpdateMinimapBountyPins(context, fullRefresh)
            Overlord.MapMarkers:UpdateMinimapManualBountyPins(context, fullRefresh)
            Overlord.MapMarkers:UpdateMinimapGeneralPins(context, fullRefresh)
        end
        if mmMineMapActive then
            Overlord.MapMarkers:UpdateMinimapMinePins(fullRefresh)
        end
        if mmWoodMapActive then
            Overlord.MapMarkers:UpdateMinimapWoodPins(fullRefresh)
        end
        if Overlord.MapMarkers._mmKeepMapActive then
            Overlord.MapMarkers:UpdateMinimapKeepPin()
        end
        if Overlord.MapMarkers._mmOutpostMapActive then
            Overlord.MapMarkers:UpdateMinimapOutpostPin()
        end
    end)

    -- Events zone : frame leger toujours actif (mmFrame cache = pas d'OnUpdate, mais les events passent).
    -- ZONE_CHANGED couvre certains changements de sous-zone ou mapID que NEW_AREA ne signale pas.
    mmFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    mmFrame:RegisterEvent("ZONE_CHANGED")
    mmFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
    mmFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    mmFrame:RegisterEvent("PLAYER_STARTED_MOVING")
    mmFrame:RegisterEvent("PLAYER_STOPPED_MOVING")
    mmFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_STARTED_MOVING" or event == "PLAYER_STOPPED_MOVING" then
            driverState.WakeMinimapDriver()
            return
        end
        driverState.WakeMinimapDriver()
        if not Overlord.InActiveFront then
            Overlord.MapMarkers:HideMinimapPins()
        end
        Overlord.MapMarkers:CheckMineMinimap()
        Overlord.MapMarkers:CheckWoodMinimap()
        Overlord.MapMarkers:CheckGuildKeepMinimap()
        Overlord.MapMarkers:CheckOutpostMinimap()
        Overlord.MapMarkers:EnsureMinimapDriverVisible()
    end)

    -- Activation initiale si deja dans un front actif
    if Overlord.InActiveFront and not Overlord.InstanceSuspended then mmFrame:Show() end

    self:CheckMineMinimap()
    self:CheckWoodMinimap()
    self:CheckGuildKeepMinimap()
    self:CheckOutpostMinimap()
end

function Overlord.MapMarkers:EnsureMinimapDriverVisible()
    if not mmFrame then return end
    if Overlord.InstanceSuspended then
        mmFrame:Hide()
        return
    end
    if Overlord.InActiveFront or mmMineMapActive or mmWoodMapActive
        or Overlord.MapMarkers._mmKeepMapActive or Overlord.MapMarkers._mmOutpostMapActive then
        if not mmFrame:IsShown() then driverState.WakeMinimapDriver() end
        mmFrame:Show()
    else
        mmFrame:Hide()
    end
end

-- Conversion map pourcent -> yards pour le front affiche sur la minimap (une fois par front)
function Overlord.MapMarkers:CalcMinimapScale()
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    if not front then return end
    local frontId = front.id
    local mapID = GetActiveFrontMapID()
    if not mapID then return end
    if mmScaleCalculatedFor == frontId and mmScaleCalculatedMapID == mapID then return end
    pcall(function()
        if not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return end
        local _, w0 = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local _, wX = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 0))
        local _, wY = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 1))
        if w0 and wX and wY then
            local dX = math.sqrt((wX.x - w0.x) ^ 2 + (wX.y - w0.y) ^ 2)
            local dY = math.sqrt((wY.x - w0.x) ^ 2 + (wY.y - w0.y) ^ 2)
            if dX > 0 then mmYardsPerPctX = dX / 100 end
            if dY > 0 then mmYardsPerPctY = dY / 100 end
            mmScaleCalculatedFor = frontId
            mmScaleCalculatedMapID = mapID
        end
    end)
end

-- ---- Bouton minimap (style LibDBIcon) ----

function Overlord.MapMarkers:CreateMinimapButton()
    if minimapButton then
        self:RefreshMinimapButtonPosition()
        return minimapButton
    end

    -- Les gestionnaires de boutons (notamment MinimapButtonButton) detectent les
    -- boutons natifs par leur nom global. "OverlordMinimapBtn" ne correspondait
    -- pas a leur convention *MinimapButton* et le bouton etait en plus cree apres
    -- leurs scans de login. Core l'appelle desormais des ADDON_LOADED, puis garde
    -- des rattrapages idempotents a PLAYER_LOGIN et pendant l'init des pins.
    minimapButton = CreateFrame("Button", "OverlordMinimapButton", Minimap)
    minimapButton:SetSize(33, 33)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetClampedToScreen(true)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local bg = minimapButton:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture(ADDON_ICON)
    icon:SetTexCoord(0, 1, 0, 1)

    local angle = (OverlordDB and OverlordDB.minimapAngle) or math.rad(200)
    self:SetMinimapButtonPos(angle)

    minimapButton:RegisterForDrag("RightButton")
    minimapButton:RegisterForClicks("LeftButtonUp")

    minimapButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then return end
        if IsShiftKeyDown() and Overlord.Popups then
            Overlord.Popups:ShowQuickGuide()
            return
        end
        if Overlord.UI then Overlord.UI:Toggle() end
    end)

    local function OnDragUpdate(btn)
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local s = Minimap:GetEffectiveScale()
        local a = math.atan2(cy / s - my, cx / s - mx)
        Overlord.MapMarkers:SetMinimapButtonPos(a)
        if OverlordDB then OverlordDB.minimapAngle = a end
    end
    minimapButton:SetScript("OnDragStart", function(btn)
        btn:SetScript("OnUpdate", OnDragUpdate)
    end)
    minimapButton:SetScript("OnDragStop", function(btn)
        btn:SetScript("OnUpdate", nil)
    end)

    minimapButton:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:AddLine("Overlord", 1, 0.82, 0.2)
        if Overlord.InstanceSuspended then
            GameTooltip:AddLine(L.DISABLED_IN_INSTANCE, 0.6, 0.6, 0.6)
        else
            local fri = Overlord.Zones:GetCapturedCount()
            local ene = Overlord.Zones:GetEnemyCapturedCount()
            local tot = Overlord.Zones:GetTotalCount()
            GameTooltip:AddLine(string.format(L.TOOLTIP_FRIENDLY, fri, tot), 0.3, 0.6, 1)
            GameTooltip:AddLine(string.format(L.TOOLTIP_ENEMY, ene, tot), 1, 0.3, 0.3)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L.TOOLTIP_LEFT_CLICK, 0.7, 0.7, 0.7)
            GameTooltip:AddLine(L.TOOLTIP_SHIFT_GUIDE, 0.7, 0.7, 0.7)
            GameTooltip:AddLine(L.TOOLTIP_RIGHT_DRAG, 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    -- Le bouton est cree avant PLAYER_LOGIN, donc avant la restauration des
    -- dimensions de la minimap par le mode Edition et les addons d'interface.
    local function refreshPosition()
        Overlord.MapMarkers:RefreshMinimapButtonPosition()
    end
    Minimap:HookScript("OnSizeChanged", refreshPosition)
    Minimap:HookScript("OnShow", refreshPosition)
    C_Timer.After(0, refreshPosition)
    minimapButton:SetShown(IsMinimapButtonEnabled())
    return minimapButton
end

function Overlord.MapMarkers:RefreshMinimapButtonVisibility()
    local button = minimapButton or self:CreateMinimapButton()
    if not button then return end
    button:SetShown(IsMinimapButtonEnabled())
end

function Overlord.MapMarkers:SetMinimapButtonPos(angle)
    if not minimapButton then return end
    angle = tonumber(angle)
    if not angle or angle ~= angle or math.abs(angle) == math.huge then angle = math.rad(200) end
    minimapButton._overlordMinimapAngle = angle
    -- Meme marge de bord que les boutons LibDBIcon ; utiliser les deux axes
    -- pour ne pas eloigner le bouton d'une minimap rectangulaire/redimensionnee.
    local w, h = Minimap:GetWidth() / 2 + 5, Minimap:GetHeight() / 2 + 5
    local x, y = math.cos(angle), math.sin(angle)
    if GetMinimapShape and GetMinimapShape() == "SQUARE" then
        local edge = math.max(math.abs(x), math.abs(y))
        x, y = x / edge, y / edge
    end
    x, y = x * w, y * h
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function Overlord.MapMarkers:RefreshMinimapButtonPosition()
    if not minimapButton or minimapButton:GetParent() ~= Minimap then return end
    local _, relativeTo = minimapButton:GetPoint()
    -- Un button-bag peut garder le parent mais remplacer l'ancre : ne pas lui
    -- reprendre son icone lors d'un resize ou d'un nouvel appel d'initialisation.
    if relativeTo and relativeTo ~= Minimap then return end
    self:SetMinimapButtonPos(minimapButton._overlordMinimapAngle)
end

-- ---- Cercles de zone sur la minimap (comme la grande carte) ----

local function IsMinimapCaptureZonesEnabled()
    local v = OverlordDB and OverlordDB.config and OverlordDB.config.showMinimapCaptureZones
    if v == nil then return true end
    return v == true
end

-- Pas de souris : le survol des points Blizzard (chasseur, nourriture) passe a travers.
local function ConfigureMinimapCaptureZonePin(pin)
    if not pin then return end
    pin:EnableMouse(false)
    pin:SetScript("OnEnter", nil)
    pin:SetScript("OnLeave", nil)
end

function Overlord.MapMarkers:CreateMinimapPins()
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        if minimapPins[zone.id] then
            minimapPins[zone.id].zone = zone
            ConfigureMinimapCaptureZonePin(minimapPins[zone.id])
        else
            local pin = CreateMinimapCirclePin({ 1, 1, 1, 0.3 }, { 1, 1, 1, 0.5 })
            ConfigureMinimapCaptureZonePin(pin)
            pin.zone = zone
            pin:Hide()
            minimapPins[zone.id] = pin
        end
    end
end

function Overlord.MapMarkers:GetMinimapRadius()
    if C_Minimap and C_Minimap.GetViewRadius then
        local ok, r = pcall(C_Minimap.GetViewRadius)
        if ok and r then return r end
    end
    return 233
end

function Overlord.MapMarkers:UpdateMinimapPins(fullRefresh)
    if not Overlord.IsInitialized or not Overlord.InActiveFront then
        self:HideMinimapPins()
        return
    end

    if not IsMinimapCaptureZonesEnabled() then
        for _, pin in pairs(minimapPins) do
            if pin:IsShown() then pin:Hide() end
        end
        return
    end

    -- Garantir un pin par zone sans scanner/recreer sur le chemin position ~60 Hz.
    if fullRefresh then self:CreateMinimapPins() end

    -- Echelle et position via la carte Zone du front, pas la sous-carte joueur (donjon / etage).
    local frontMapID = GetActiveFrontMapID()
    if not frontMapID then
        self:HideMinimapPins()
        return
    end
    if not IsMinimapFrontOverlayMap(mmCachedMapID) then
        for _, pin in pairs(minimapPins) do
            if pin:IsShown() then pin:Hide() end
        end
        return
    end
    self:CalcMinimapScale()
    if not mmYardsPerPctX or not mmYardsPerPctY then
        self:HideMinimapPins()
        return
    end
    local px, py = GetPlayerPositionForResourceMap(frontMapID)
    if not px or not py then
        self:HideMinimapPins()
        return
    end
    local halfMM = mmCachedHalfMM
    local pxPerYard = mmCachedPxPerYard
    local rotateMM = mmCachedRotate
    local facing = mmCachedFacing

    local sinF, cosF
    if rotateMM then
        sinF, cosF = math.sin(-facing), math.cos(-facing)
    end

    local opacityScale = GetMinimapOverlayOpacityScale()
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        local pin = minimapPins[zone.id]
        if pin then
            if fullRefresh or pin._olZoneStyle == nil then
                local r, g, b, fa, ba = GetFactionZoneColors(zone)
                pin._olZoneStyle = true
                pin._olZR, pin._olZG, pin._olZB = r, g, b
                pin._olZFA, pin._olZBA = fa * opacityScale, ba * opacityScale
            end
            UpdateMinimapCirclePin(pin, zone.center, zone.radius, 1, 10,
                px, py, mmYardsPerPctX, mmYardsPerPctY, pxPerYard, halfMM,
                rotateMM, sinF, cosF, pin._olZR, pin._olZG, pin._olZB, pin._olZFA, pin._olZBA,
                nil, nil, nil, fullRefresh)
        end
    end
end

function Overlord.MapMarkers:HideMinimapPins()
    for _, pin in pairs(minimapPins) do
        if pin:IsShown() then pin:Hide() end
    end
    self:HideMinimapBountyPins()
    self:HideMinimapManualBountyPins()
    self:HideMinimapGeneralPins()
end

function Overlord.MapMarkers:RefreshMinimapOverlayOpacity()
    for _, pin in pairs(minimapPins) do
        if pin then
            pin._olFillAlpha = nil
            pin._olBorderAlpha = nil
            pin._olZoneStyle = nil
        end
    end
    if Overlord.InActiveFront then
        self:UpdateMinimapPins(true)
    end
end

function Overlord.MapMarkers:RefreshMinimapCaptureZonesVisibility()
    if Overlord.InActiveFront then
        self:UpdateMinimapPins(false)
    else
        for _, pin in pairs(minimapPins) do
            if pin:IsShown() then pin:Hide() end
        end
    end
end

-- ============ Pins ressources sur la minimap (mines / forets) ============

local minimapMinePins = {}
local mineYardsPerPct = {}
local minimapWoodPins = {}
local woodYardsPerPct = {}

local MINE_MINIMAP_FILL = { 1, 0.82, 0, 0.34 }
local MINE_MINIMAP_BORDER = { 1, 0.82, 0, 0.58 }
local WOOD_MINIMAP_FILL = { 0.42, 0.48, 0.16, 0.42 }
local WOOD_MINIMAP_BORDER = { 0.82, 0.88, 0.44, 0.58 }

local function ResolveResourceMinimapMapID(mapID, isResourceMapID)
    if not mapID or not isResourceMapID then return nil end
    local resolvedMapID = mapID
    local depth = 0
    while resolvedMapID and not isResourceMapID(resolvedMapID) and depth < 3 do
        local ok, info = pcall(C_Map.GetMapInfo, resolvedMapID)
        if not ok or not info or not info.parentMapID or info.parentMapID == 0 then break end
        resolvedMapID = info.parentMapID
        depth = depth + 1
    end
    if resolvedMapID and isResourceMapID(resolvedMapID) then return resolvedMapID end
    return nil
end

local function CalcResourceYardsPerPct(cache, mapID)
    if not cache or not mapID or cache[mapID] then return end
    pcall(function()
        if not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return end
        local _, w0 = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local _, wX = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 0))
        local _, wY = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 1))
        if w0 and wX and wY then
            local dX = math.sqrt((wX.x - w0.x) ^ 2 + (wX.y - w0.y) ^ 2)
            local dY = math.sqrt((wY.x - w0.x) ^ 2 + (wY.y - w0.y) ^ 2)
            if dX > 0 and dY > 0 then
                cache[mapID] = { x = dX / 100, y = dY / 100 }
            end
        end
    end)
end

local function ShowMineResourceTooltip(mine)
    if not mine then return end
    local tp = Overlord.UI.TooltipPalette()
    GameTooltip:AddLine(mine.name, tp.HL[1], tp.HL[2], tp.HL[3])
    GameTooltip:AddLine(L.MINE_TOOLTIP, tp.MUTED[1], tp.MUTED[2], tp.MUTED[3])
    if Overlord.Ressources then
        local stock = Overlord.Ressources:GetMineStock(mine.id)
        local stockMax = Overlord.Ressources:GetMineStockMax()
        GameTooltip:AddLine(string.format(L.MINE_STOCK, stock, stockMax), tp.HL[1], tp.HL[2], tp.HL[3])
    end
    GameTooltip:Show()
end

local function ShowWoodResourceTooltip(wood)
    if not wood then return end
    local tp = Overlord.UI.TooltipPalette()
    GameTooltip:AddLine(wood.name, tp.HL[1], tp.HL[2], tp.HL[3])
    if Overlord.Ressources then
        local stock = Overlord.Ressources:GetWoodStock(wood.id)
        local stockMax = Overlord.Ressources:GetWoodStockMax()
        GameTooltip:AddLine(string.format(L.WOOD_STOCK, stock, stockMax), tp.HL[1], tp.HL[2], tp.HL[3])
    end
    GameTooltip:Show()
end

local function CreateResourceMinimapPins(cfg)
    local database = cfg.database()
    if not database then return end
    for _, resource in ipairs(database) do
        local existing = cfg.pins[resource.id]
        if existing then
            existing.resource = resource
            existing[cfg.field] = resource
        else
            -- Placeholder si getCircleColors fournit les vraies couleurs au premier tick (fortins).
            local fill = cfg.fillColor or { 0.62, 0.65, 0.60, 0.34 }
            local border = cfg.borderColor or { fill[1], fill[2], fill[3], 0.58 }
            local pin = CreateMinimapCirclePin(fill, border)
            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, cfg.tooltipAnchor or "ANCHOR_CURSOR")
                cfg.tooltip(self.resource or self[cfg.field])
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            pin.resource = resource
            pin[cfg.field] = resource
            pin:Hide()
            cfg.pins[resource.id] = pin
        end
    end
end

local function UpdateResourceMinimapPins(cfg, dataRefresh)
    local database = cfg.database()
    if not database then return false end
    local sourceMapID = mmCachedMapID
    local mapID = cfg._resolvedSourceMapID == sourceMapID and cfg._resolvedMapID or nil
    if not mapID then
        mapID = ResolveResourceMinimapMapID(sourceMapID, cfg.isMapID)
        if mapID then
            cfg._resolvedSourceMapID = sourceMapID
            cfg._resolvedMapID = mapID
        end
    end
    if not mapID then return false end
    local px, py = GetPlayerPositionForResourceMap(mapID)
    if not px or not py then return false end
    CalcResourceYardsPerPct(cfg.yardsPerPct, mapID)

    local halfMM = mmCachedHalfMM
    local pxPerYard = mmCachedPxPerYard
    local rotateMM = mmCachedRotate
    local facing = mmCachedFacing
    local ypp = cfg.yardsPerPct[mapID]
    local yppX = ypp and ypp.x or 30
    local yppY = ypp and ypp.y or 30
    local avgYPP = (yppX + yppY) / 2
    local minDiameter = cfg.minDiameter or 8
    local opacityScale = cfg.applyMinimapOpacity and GetMinimapOverlayOpacityScale() or 1

    local sinF, cosF
    if rotateMM then
        sinF, cosF = math.sin(-facing), math.cos(-facing)
    end

    for _, resource in ipairs(database) do
        local pin = cfg.pins[resource.id]
        if pin and Overlord.Zones:ResourceMatchesMap(resource, mapID) then
            if dataRefresh or pin._olResourceStyle == nil then
                local r, g, b, fa, ba, br, bg, bb
                if cfg.getCircleColors then
                    r, g, b, fa, ba, br, bg, bb = cfg.getCircleColors(resource, mapID)
                    br = br or r
                    bg = bg or g
                    bb = bb or b
                else
                    r = cfg.fillColor[1]
                    g = cfg.fillColor[2]
                    b = cfg.fillColor[3]
                    fa = cfg.fillColor[4]
                    ba = cfg.borderColor[4]
                    br = cfg.borderColor[1]
                    bg = cfg.borderColor[2]
                    bb = cfg.borderColor[3]
                end
                local radius, radiusScale
                if cfg.getRadius then
                    radius, radiusScale = cfg.getRadius(resource, avgYPP)
                else
                    radius = resource.radius
                    radiusScale = type(cfg.radiusScale) == "function" and cfg.radiusScale() or 1
                end
                pin._olResourceStyle = true
                pin._olRR, pin._olRG, pin._olRB = r, g, b
                pin._olRFA, pin._olRBA = fa * opacityScale, ba * opacityScale
                pin._olRBR, pin._olRBG, pin._olRBB = br, bg, bb
                pin._olRRadius, pin._olRRadiusScale = radius, radiusScale
            end
            UpdateMinimapCirclePin(pin, resource.center, pin._olRRadius, pin._olRRadiusScale, minDiameter,
                px, py, yppX, yppY, pxPerYard, halfMM, rotateMM, sinF, cosF,
                pin._olRR, pin._olRG, pin._olRB, pin._olRFA, pin._olRBA,
                pin._olRBR, pin._olRBG, pin._olRBB, dataRefresh)
        elseif pin and pin:IsShown() then
            pin:Hide()
        end
    end
    return true
end

local function HideResourceMinimapPins(pins)
    for _, pin in pairs(pins) do
        if pin:IsShown() then pin:Hide() end
    end
end

local MINE_MINIMAP_CONFIG = {
    pins = minimapMinePins,
    yardsPerPct = mineYardsPerPct,
    field = "mine",
    fillColor = MINE_MINIMAP_FILL,
    borderColor = MINE_MINIMAP_BORDER,
    database = function() return Overlord.MineDatabase end,
    isMapID = function(mid) return Overlord.Zones and Overlord.Zones:IsMineMapID(mid) end,
    radiusScale = function() return Overlord.MineMapCircleScale or 0.50 end,
    tooltip = ShowMineResourceTooltip,
}

local WOOD_MINIMAP_CONFIG = {
    pins = minimapWoodPins,
    yardsPerPct = woodYardsPerPct,
    field = "wood",
    fillColor = WOOD_MINIMAP_FILL,
    borderColor = WOOD_MINIMAP_BORDER,
    database = function() return Overlord.WoodDatabase end,
    isMapID = function(mid)
        return Overlord.Zones and Overlord.Zones.IsWoodMapID and Overlord.Zones:IsWoodMapID(mid)
    end,
    radiusScale = function() return Overlord.WoodMapCircleScale or 1.0 end,
    tooltip = ShowWoodResourceTooltip,
}

function Overlord.MapMarkers:CalcMineYardsPerPct(mapID)
    CalcResourceYardsPerPct(mineYardsPerPct, mapID)
end

function Overlord.MapMarkers:CalcWoodYardsPerPct(mapID)
    CalcResourceYardsPerPct(woodYardsPerPct, mapID)
end

function Overlord.MapMarkers:CreateMinimapMinePins()
    CreateResourceMinimapPins(MINE_MINIMAP_CONFIG)
end

function Overlord.MapMarkers:CreateMinimapWoodPins()
    CreateResourceMinimapPins(WOOD_MINIMAP_CONFIG)
end

function Overlord.MapMarkers:CheckMineMinimap()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    local mineMapID = ok and ResolveResourceMinimapMapID(mapID, MINE_MINIMAP_CONFIG.isMapID) or nil
    if mineMapID and not Overlord.InstanceSuspended then
        MINE_MINIMAP_CONFIG._resolvedSourceMapID = mapID
        MINE_MINIMAP_CONFIG._resolvedMapID = mineMapID
        self:CreateMinimapMinePins()
        self:CalcMineYardsPerPct(mineMapID)
        mmMineMapActive = true
    else
        mmMineMapActive = false
        self:HideMinimapMinePins()
    end
    self:EnsureMinimapDriverVisible()
end

function Overlord.MapMarkers:UpdateMinimapMinePins(dataRefresh)
    if not UpdateResourceMinimapPins(MINE_MINIMAP_CONFIG, dataRefresh) then
        self:HideMinimapMinePins()
    end
end

function Overlord.MapMarkers:HideMinimapMinePins()
    HideResourceMinimapPins(minimapMinePins)
end

function Overlord.MapMarkers:CheckWoodMinimap()
    if not Overlord.Zones or not Overlord.Zones.IsWoodMapID then
        mmWoodMapActive = false
        self:HideMinimapWoodPins()
        self:EnsureMinimapDriverVisible()
        return
    end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    local woodMapID = ok and ResolveResourceMinimapMapID(mapID, WOOD_MINIMAP_CONFIG.isMapID) or nil
    if woodMapID and not Overlord.InstanceSuspended then
        WOOD_MINIMAP_CONFIG._resolvedSourceMapID = mapID
        WOOD_MINIMAP_CONFIG._resolvedMapID = woodMapID
        self:CreateMinimapWoodPins()
        self:CalcWoodYardsPerPct(woodMapID)
        mmWoodMapActive = true
    else
        mmWoodMapActive = false
        self:HideMinimapWoodPins()
    end
    self:EnsureMinimapDriverVisible()
end

function Overlord.MapMarkers:UpdateMinimapWoodPins(dataRefresh)
    if not Overlord.Zones or not Overlord.Zones.IsWoodMapID
        or not UpdateResourceMinimapPins(WOOD_MINIMAP_CONFIG, dataRefresh) then
        self:HideMinimapWoodPins()
    end
end

function Overlord.MapMarkers:HideMinimapWoodPins()
    HideResourceMinimapPins(minimapWoodPins)
end


-- Icones sur la carte continent EK (mines d'or + logos domination) : meme principe que les pins
-- (largeur canvas * fraction, bornee) - herite du zoom comme le calque carte ; pas SetIgnoreParentScale.
local EK_CONTINENT_MAP_PIN_MIN = 20
local EK_CONTINENT_MAP_PIN_MAX = 30
local EK_CONTINENT_MAP_PIN_FRAC = 0.019

local function GetEKContinentMapPinSize(cw)
    if not cw or cw == 0 then return EK_CONTINENT_MAP_PIN_MIN end
    return math.max(EK_CONTINENT_MAP_PIN_MIN, math.min(EK_CONTINENT_MAP_PIN_MAX, cw * EK_CONTINENT_MAP_PIN_FRAC))
end

-- Logos domination continent (EK / Kalimdor)
-- Domination >= 80 % : logos timer faction ; front conteste : bannieres assaut BfA (64x64 natif)
local DOMINANCE_ALLIANCE_ATLAS = "AllianceAssaultsMapBanner"
local DOMINANCE_HORDE_ATLAS = "HordeAssaultsMapBanner"
local DOMINANCE_ALLIANCE_TEXTURE = "Interface\\Timer\\Alliance-Logo"
local DOMINANCE_HORDE_TEXTURE = "Interface\\Timer\\Horde-Logo"
local DOMINANCE_ATLAS_NATIVE_SIZE = 64
-- Meme systeme que GetFrontOverlayDiameter (cercles de zone)
-- canvasWidth * fraction * scaleRatio = taille stable au zoom.
local EK_DOMINANCE_LOGO_BASE = 0.032
local EK_DOMINANCE_GAP_BASE = 0.012

local dominanceAtlasNativeSizeResolved = nil

local function ResolveDominanceAtlasNativeSize()
    if dominanceAtlasNativeSizeResolved then return dominanceAtlasNativeSizeResolved end
    local size = DOMINANCE_ATLAS_NATIVE_SIZE
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, info = pcall(C_Texture.GetAtlasInfo, DOMINANCE_ALLIANCE_ATLAS)
        if ok and info then
            local raw = info.rawSize
            if raw and raw.x and raw.x > 0 then
                size = math.max(raw.x, raw.y or 0)
            elseif info.width and info.width > 0 then
                size = math.max(info.width, info.height or info.width)
            end
        end
    end
    dominanceAtlasNativeSizeResolved = size
    return size
end

local function PrepareDominanceTexture(tex)
    if not tex then return end
    if tex.SetSnapToPixelGrid then
        pcall(tex.SetSnapToPixelGrid, tex, true)
    end
    if tex.SetTexelSnappingBias then
        pcall(tex.SetTexelSnappingBias, tex, 0)
    end
end

local function ApplyDominanceAssaultIcon(tex, faction)
    if not tex or not tex.SetAtlas then return end
    local atlas = (faction == "Horde") and DOMINANCE_HORDE_ATLAS or DOMINANCE_ALLIANCE_ATLAS
    PrepareDominanceTexture(tex)
    pcall(tex.SetAtlas, tex, atlas)
end

local function ApplyDominanceTimerLogo(tex, faction)
    if not tex or not tex.SetTexture then return end
    local path = (faction == "Horde") and DOMINANCE_HORDE_TEXTURE or DOMINANCE_ALLIANCE_TEXTURE
    PrepareDominanceTexture(tex)
    tex:SetTexture(path)
    tex:SetTexCoord(0, 1, 0, 1)
end

local function GetEKDominanceLogoSize(canvas, parent, capAssaultAtlas)
    if not canvas then return 50 end
    local cw = canvas:GetWidth()
    if not cw or cw == 0 then return 50 end
    local scaleRatio = 1
    if parent then
        local canvasScale = canvas:GetEffectiveScale()
        local parentScale = parent:GetEffectiveScale()
        if canvasScale and parentScale and parentScale > 0 then
            scaleRatio = canvasScale / parentScale
        end
    end
    local computed = cw * EK_DOMINANCE_LOGO_BASE * scaleRatio
    if capAssaultAtlas then
        return math.min(computed, ResolveDominanceAtlasNativeSize())
    end
    return computed
end

local function GetEKDominanceGap(canvas, parent)
    if not canvas then return 15 end
    local cw = canvas:GetWidth()
    if not cw or cw == 0 then return 15 end
    local scaleRatio = 1
    if parent then
        local canvasScale = canvas:GetEffectiveScale()
        local parentScale = parent:GetEffectiveScale()
        if canvasScale and parentScale and parentScale > 0 then
            scaleRatio = canvasScale / parentScale
        end
    end
    return cw * EK_DOMINANCE_GAP_BASE * scaleRatio
end

local function HideEKDominanceVisuals(overlay)
    if not overlay then return end
    if overlay.logo then overlay.logo:Hide() end
    if overlay.contestedA then overlay.contestedA:Hide() end
    if overlay.contestedH then overlay.contestedH:Hide() end
end

-- ============ Dominance sur cartes continent (EK / Kalimdor, dezoom) ============
-- Logo timer si une faction domine ; bannieres assaut BfA si le front est conteste.

local ekOverlays = {}

local EK_FRONT_LOGO_OFFSETS = {
    gilneas = { x = 0.008, y = 0 },
}

local function IsMapUnderAncestor(mapID, ancestorMapID)
    if not mapID or not ancestorMapID then return false end
    local cur, depth = mapID, 0
    while cur and cur > 0 and depth < 16 do
        if cur == ancestorMapID then return true end
        local ok, info = pcall(C_Map.GetMapInfo, cur)
        if not ok or not info then return false end
        cur = info.parentMapID
        depth = depth + 1
    end
    return false
end

function Overlord.MapMarkers:ResolveEKMapID()
    if resolvedEKMapID then
        local kalID = self:ResolveKalimdorMapID()
        if kalID and resolvedEKMapID == kalID then
            resolvedEKMapID = nil
        else
            return resolvedEKMapID
        end
    end
    pcall(function()
        local frontMapID = GetActiveFrontMapID()
        local kalID = self:ResolveKalimdorMapID()
        -- Front actif Kalimdor (ex. Barrens du Sud) : ne pas confondre continent EK et Kalimdor
        if frontMapID and kalID and IsMapUnderAncestor(frontMapID, kalID) then
            frontMapID = nil
        end
        -- Gilneas n'avait pas d'entree mapIDs : GetActiveFrontMapID pouvait etre nil et jamais de continent EK
        if not frontMapID and Overlord.Fronts and Overlord.Fronts.Order and Overlord.Fronts.Registry then
            for _, fid in ipairs(Overlord.Fronts.Order) do
                local f = Overlord.Fronts.Registry[fid]
                if f and f.mapIDs then
                    for mid in pairs(f.mapIDs) do
                        if not kalID or not IsMapUnderAncestor(mid, kalID) then
                            frontMapID = mid
                            break
                        end
                    end
                end
                if frontMapID then break end
            end
        end
        if not frontMapID then return end
        local info = C_Map.GetMapInfo(frontMapID)
        if info and info.parentMapID and info.parentMapID > 0 then
            resolvedEKMapID = info.parentMapID
        end
    end)
    return resolvedEKMapID
end

function Overlord.MapMarkers:ResolveKalimdorMapID()
    if resolvedKalimdorMapID then return resolvedKalimdorMapID end
    pcall(function()
        local info = C_Map.GetMapInfo(463)
        if info and info.parentMapID and info.parentMapID > 0 then
            local parentInfo = C_Map.GetMapInfo(info.parentMapID)
            if parentInfo and parentInfo.parentMapID and parentInfo.parentMapID > 0 then
                resolvedKalimdorMapID = parentInfo.parentMapID
            end
        end
        if not resolvedKalimdorMapID then
            resolvedKalimdorMapID = 12
        end
    end)
    return resolvedKalimdorMapID
end

-- Cartes ou les fortins sont des pins projetes (continent EK, Kalimdor, carte regionale type Durotar).
function Overlord.MapMarkers:IsGuildKeepProjectionMap(mapID)
    if not mapID then return false end
    if self:IsEKMap(mapID) then return true end
    local kalID = self:ResolveKalimdorMapID()
    if kalID and mapID == kalID then return true end
    if Overlord.GuildKeepSites then
        for _, site in pairs(Overlord.GuildKeepSites) do
            if site.regionalMapIDs and site.regionalMapIDs[mapID] then
                return true
            end
        end
    end
    if Overlord.OutpostSites then
        for _, site in pairs(Overlord.OutpostSites) do
            if site.regionalMapIDs and site.regionalMapIDs[mapID] then
                return true
            end
        end
    end
    if Overlord.GuildHonorSites then
        for _, site in pairs(Overlord.GuildHonorSites) do
            local visibleOnMap = not Overlord.GuildHonor
                or not Overlord.GuildHonor.IsVisibleOnMap
                or Overlord.GuildHonor:IsVisibleOnMap(site)
            if visibleOnMap then
                if site.mapID == mapID then return true end
                if site.mapIDs and site.mapIDs[mapID] then return true end
                if site.regionalMapIDs and site.regionalMapIDs[mapID] then return true end
                if Overlord.GuildHonor and Overlord.GuildHonor.ShouldProjectHonorPinOnMap
                    and Overlord.GuildHonor:ShouldProjectHonorPinOnMap(site, mapID) then
                    return true
                end
                if Overlord.GuildHonor and Overlord.GuildHonor.SiteMatchesMapID then
                    if Overlord.GuildHonor:SiteMatchesMapID(site, mapID) then return true end
                end
            end
        end
    end
    return false
end

function Overlord.MapMarkers:IsEKMap(mapID)
    if not mapID then return false end
    if continentProbeMapID == mapID and continentProbeEKValid then
        return continentProbeIsEK
    end
    local ekID = self:ResolveEKMapID()
    local isEK = false
    if ekID then
        if mapID == ekID then
            isEK = true
        else
            local cur, depth = mapID, 0
            while cur and cur > 0 and depth < 16 do
                local ok, info = pcall(C_Map.GetMapInfo, cur)
                if not ok or not info then break end
                cur = info.parentMapID
                depth = depth + 1
                if cur == ekID then
                    isEK = true
                    break
                end
            end
        end
    end
    if continentProbeMapID ~= mapID then
        continentProbeMapID = mapID
        continentProbeKalValid = false
    end
    continentProbeIsEK = isEK
    continentProbeEKValid = true
    return isEK
end

function Overlord.MapMarkers:IsKalimdorMap(mapID)
    if not mapID then return false end
    if continentProbeMapID == mapID and continentProbeKalValid then
        return continentProbeIsKal
    end
    local kalID = self:ResolveKalimdorMapID()
    local isKal = false
    if kalID then
        if mapID == kalID then
            isKal = true
        else
            local cur, depth = mapID, 0
            while cur and cur > 0 and depth < 16 do
                local ok, info = pcall(C_Map.GetMapInfo, cur)
                if not ok or not info then break end
                cur = info.parentMapID
                depth = depth + 1
                if cur == kalID then
                    isKal = true
                    break
                end
            end
        end
    end
    if continentProbeMapID ~= mapID then
        continentProbeMapID = mapID
        continentProbeEKValid = false
    end
    continentProbeIsKal = isKal
    continentProbeKalValid = true
    return isKal
end

-- Cache session (frontMapID|continentMapID -> nx, ny) : geometrie continentale statique.
-- RefreshEKDominance n'est plus appele a 60 Hz (seulement layout/content), mais le cache
-- evite quand meme C_Map.GetMapRectOnMap a chaque pan/zoom.
local frontContinentPosCache = {}
-- Pool de frames dominance EK (SetParent(nil) sans pool = fuite frames WoW).
local ekDominanceFramePool = {}

local function GetFrontPositionOnContinentMap(front, continentMapID)
    local frontMapID = front and Overlord.Fronts and Overlord.Fronts:GetMapID(front.id)
    if not frontMapID or not continentMapID or not C_Map.GetMapRectOnMap then
        return nil, nil
    end
    local cacheKey = frontMapID .. "|" .. continentMapID
    local cached = frontContinentPosCache[cacheKey]
    if cached then
        return cached[1], cached[2]
    end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, frontMapID, continentMapID)
    if ok and minX and maxX and minY and maxY and maxX > minX and maxY > minY then
        local nx, ny = (minX + maxX) / 2, (minY + maxY) / 2
        frontContinentPosCache[cacheKey] = { nx, ny }
        return nx, ny
    end
    return nil, nil
end

function Overlord.MapMarkers:GetDominantFaction(front)
    if not Overlord.IsInitialized then return nil end
    local zones = front and front.zones
    if not zones then return nil end
    local total = #zones
    if total == 0 then return nil end
    local alliance = 0
    local horde = 0
    for _, zone in ipairs(zones) do
        if zone.owner == "Alliance" then
            alliance = alliance + 1
        elseif zone.owner == "Horde" then
            horde = horde + 1
        end
    end
    local threshold = math.ceil(total * DOMINANCE_THRESHOLD)
    if alliance >= threshold then return "Alliance" end
    if horde >= threshold then return "Horde" end
    return nil
end

function Overlord.MapMarkers:CreateEKDominanceOverlay(canvas)
    local parent = GetOverlayParent()
    if not parent then return nil end
    -- Pivot sur le calque carte : position fiable, taille compensee au refresh.
    local root = table.remove(ekDominanceFramePool)
    if root then
        root:SetParent(parent)
        HideEKDominanceVisuals(root)
        root._ekDominanceFaction = nil
    else
        root = CreateFrame("Frame", nil, parent)
        root._ekDominanceAnchorV2 = true
        root._ekDominanceScaleCompensated = true
        root._ekDominanceAssaultIcon = true

        local logo = root:CreateTexture(nil, "OVERLAY", nil, 3)
        PrepareDominanceTexture(logo)
        logo:SetAlpha(0.85)
        logo:Hide()
        root.logo = logo

        local contestedA = root:CreateTexture(nil, "OVERLAY", nil, 3)
        PrepareDominanceTexture(contestedA)
        contestedA:SetAlpha(0.85)
        contestedA:Hide()
        root.contestedA = contestedA

        local contestedH = root:CreateTexture(nil, "OVERLAY", nil, 3)
        PrepareDominanceTexture(contestedH)
        contestedH:SetAlpha(0.85)
        contestedH:Hide()
        root.contestedH = contestedH
    end
    root:SetFrameStrata(parent:GetFrameStrata())
    root:SetFrameLevel((parent:GetFrameLevel() or 0) + 40)
    root:SetSize(2, 2)
    root:Hide()
    return root
end

function Overlord.MapMarkers:RefreshEKDominance(recomputeFaction)
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then
        self:HideEKDominance()
        return
    end

    if not Overlord.IsInitialized then
        self:HideEKDominance()
        return
    end

    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 then
        return
    end

    wipe(ekVisibleFrontIds)
    if not Overlord.Fronts or not Overlord.Fronts.Order or not Overlord.Fronts.Registry then
        self:HideEKDominance()
        return
    end
    for _, frontId in ipairs(Overlord.Fronts.Order) do
        local front = Overlord.Fronts.Registry[frontId]
        if front then
            local nx, ny = GetFrontPositionOnContinentMap(front, trackedMapID)
            if nx and ny then
                ekVisibleFrontIds[front.id] = true
                local overlay = ekOverlays[front.id]
                if overlay and (overlay:GetParent() ~= parent or not overlay._ekDominanceAnchorV2
                    or not overlay._ekDominanceScaleCompensated or not overlay._ekDominanceAssaultIcon) then
                    overlay:Hide()
                    HideEKDominanceVisuals(overlay)
                    overlay._ekDominanceFaction = nil
                    pcall(overlay.SetParent, overlay, nil)
                    ekDominanceFramePool[#ekDominanceFramePool + 1] = overlay
                    ekOverlays[front.id] = nil
                    overlay = nil
                end
                if not overlay then
                    overlay = self:CreateEKDominanceOverlay(canvas)
                    ekOverlays[front.id] = overlay
                end
                if overlay then
                    overlay:SetFrameStrata(parent:GetFrameStrata())
                    overlay:SetFrameLevel((parent:GetFrameLevel() or 0) + 40)
                    local offset = EK_FRONT_LOGO_OFFSETS[front.id]
                    if offset then
                        nx = nx + offset.x
                        ny = ny + offset.y
                    end
                    local x = nx * cw
                    local yDown = ny * ch
                    local ox, oy = GetOverlayPoint(canvas, parent, x, yDown)
                    if ox and oy then
                        ox = math.floor(ox + 0.5)
                        oy = math.floor(oy + 0.5)
                        overlay:ClearAllPoints()
                        overlay:SetSize(2, 2)
                        overlay:SetPoint("CENTER", parent, "TOPLEFT", ox, oy)
                        local logoSize = math.floor(GetEKDominanceLogoSize(canvas, parent, false) + 0.5)
                        local contestedLogoSize = math.floor(GetEKDominanceLogoSize(canvas, parent, true) + 0.5)
                        local halfSize = math.floor(contestedLogoSize * 0.84 + 0.5)
                        local gap = math.floor(GetEKDominanceGap(canvas, parent) + 0.5)
                        local faction = overlay._ekDominanceFaction
                        if recomputeFaction or faction == nil then
                            faction = self:GetDominantFaction(front)
                            overlay._ekDominanceFaction = faction
                        end
                        if faction then
                            -- Domination claire : logo timer faction (comme avant).
                            ApplyDominanceTimerLogo(overlay.logo, faction)
                            overlay.logo:SetSize(logoSize, logoSize)
                            overlay.logo:ClearAllPoints()
                            overlay.logo:SetPoint("CENTER", overlay, "CENTER", 0, 0)
                            overlay.logo:Show()
                            overlay.contestedA:Hide()
                            overlay.contestedH:Hide()
                        else
                            -- Front conteste : deux bannieres assaut BfA autour du pivot.
                            overlay.logo:Hide()

                            ApplyDominanceAssaultIcon(overlay.contestedA, "Alliance")
                            ApplyDominanceAssaultIcon(overlay.contestedH, "Horde")
                            overlay.contestedA:SetSize(halfSize, halfSize)
                            overlay.contestedA:ClearAllPoints()
                            overlay.contestedA:SetPoint("CENTER", overlay, "CENTER", -gap, 0)
                            overlay.contestedA:Show()

                            overlay.contestedH:SetSize(halfSize, halfSize)
                            overlay.contestedH:ClearAllPoints()
                            overlay.contestedH:SetPoint("CENTER", overlay, "CENTER", gap, 0)
                            overlay.contestedH:Show()
                        end
                        overlay:Show()
                    else
                        overlay:Hide()
                        HideEKDominanceVisuals(overlay)
                    end
                end
            end
        end
    end
    for frontId, overlay in pairs(ekOverlays) do
        if overlay and not ekVisibleFrontIds[frontId] then
            overlay:Hide()
            HideEKDominanceVisuals(overlay)
        end
    end
end

function Overlord.MapMarkers:HideEKDominanceLogos()
    for _, overlay in pairs(ekOverlays) do
        if overlay then
            overlay:Hide()
            HideEKDominanceVisuals(overlay)
        end
    end
end

function Overlord.MapMarkers:HideEKDominance()
    self:HideEKDominanceLogos()
    Overlord.MapMarkers:HideEKGoldMinePins()
    Overlord.MapMarkers:HideContinentWoodPins()
    Overlord.MapMarkers:HideContinentBountyPins()
    Overlord.MapMarkers:HideContinentManualBountyPins()
    Overlord.MapMarkers:HideContinentGeneralPins()
    Overlord.MapMarkers:HideProjectedKeepPins()
end

function Overlord.MapMarkers:RefreshContinentBountyPins()
    if Overlord.BountyMap and Overlord.BountyMap.RefreshContinent then
        Overlord.BountyMap:RefreshContinent()
    end
end

function Overlord.MapMarkers:RefreshContinentManualBountyPins()
    if Overlord.ManualBountyMap and Overlord.ManualBountyMap.RefreshContinent then
        Overlord.ManualBountyMap:RefreshContinent()
    end
end

function Overlord.MapMarkers:HideContinentBountyPins()
    if Overlord.BountyMap and Overlord.BountyMap.HideContinent then
        Overlord.BountyMap:HideContinent()
    end
end

function Overlord.MapMarkers:HideContinentManualBountyPins()
    if Overlord.ManualBountyMap and Overlord.ManualBountyMap.HideContinent then
        Overlord.ManualBountyMap:HideContinent()
    end
end

function Overlord.MapMarkers:RefreshContinentGeneralPins()
    if Overlord.GeneralMap and Overlord.GeneralMap.RefreshContinent then
        Overlord.GeneralMap:RefreshContinent()
    end
end

function Overlord.MapMarkers:HideContinentGeneralPins()
    if Overlord.GeneralMap and Overlord.GeneralMap.HideContinent then
        Overlord.GeneralMap:HideContinent()
    end
end

-- ============ Icones mine sur la carte Eastern Kingdoms (dezoom), meme atlas que les cercles mine ============

local ekGoldRoot = nil
local ekGoldPins = {}
local mineContinentPosCache = {}

local function GetMinePositionOnContinentMap(mine, continentMapID)
    if not mine or not continentMapID then return nil, nil end
    local cacheKey = (mine.mapID or 0) .. "|" .. continentMapID .. "|"
        .. (mine.center and mine.center[1] or 0) .. "|" .. (mine.center and mine.center[2] or 0)
    local cached = mineContinentPosCache[cacheKey]
    if cached then
        return cached[1], cached[2]
    end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, mine.mapID, continentMapID)
    if ok and minX and maxX and minY and maxY and maxX > minX and maxY > minY then
        local nx = minX + (maxX - minX) * (mine.center[1] / 100)
        local ny = minY + (maxY - minY) * (mine.center[2] / 100)
        mineContinentPosCache[cacheKey] = { nx, ny }
        return nx, ny
    end
    return nil, nil
end

function Overlord.MapMarkers:EnsureEKGoldMinePins(canvas)
    local parent = GetOverlayParent()
    if not Overlord.MineDatabase or not canvas or not parent then return end
    if ekGoldRoot and ekGoldRoot:GetParent() ~= parent then
        ekGoldRoot:SetParent(parent)
    end
    if not ekGoldRoot then
        ekGoldRoot = CreateFrame("Frame", nil, parent)
        ekGoldRoot:SetAllPoints()
    end
    -- Meme strata que le calque carte (pas TOOLTIP + niveau 500 : ecrasait les logos faction)
    ekGoldRoot:SetFrameStrata(parent:GetFrameStrata())
    ekGoldRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 25)
    for _, mine in ipairs(Overlord.MineDatabase) do
        local existing = ekGoldPins[mine.id]
        -- Ancienne version texte : recreer le pin avec icone seule
        if existing and not existing.icon then
            existing:SetParent(nil)
            ekGoldPins[mine.id] = nil
        end
        if not ekGoldPins[mine.id] then
            local pin = CreateFrame("Frame", nil, ekGoldRoot)
            pin:SetFrameStrata(ekGoldRoot:GetFrameStrata())
            pin:SetFrameLevel(ekGoldRoot:GetFrameLevel() + 1)
            pin.mine = mine

            local icon = pin:CreateTexture(nil, "OVERLAY", nil, 2)
            icon:SetAllPoints()
            pcall(function()
                icon:SetAtlas("Warfronts-FieldMapIcons-Empty-Mine")
            end)
            pin.icon = icon

            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                local tp = Overlord.UI.TooltipPalette()
                GameTooltip:AddLine(self.mine.name, tp.HL[1], tp.HL[2], tp.HL[3])
                GameTooltip:AddLine(L.MINE_TOOLTIP, tp.MUTED[1], tp.MUTED[2], tp.MUTED[3], true)
                local res = Overlord.Ressources
                if res then
                    local stock = res:GetMineStock(self.mine.id)
                    local stockMax = res:GetMineStockMax()
                    if stock < stockMax then
                        GameTooltip:AddLine(string.format(L.MINE_STOCK, stock, stockMax), tp.HL[1], tp.HL[2], tp.HL[3])
                    end
                end
                GameTooltip:Show()
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            ekGoldPins[mine.id] = pin
        end
    end
end

function Overlord.MapMarkers:RefreshEKGoldMinePins()
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then
        self:HideEKGoldMinePins()
        return
    end
    local mapID = trackedMapID
    if not self:IsEKMap(mapID) then
        self:HideEKGoldMinePins()
        return
    end
    -- Carte affichee = continent courant (IsEKMap garantit coherence avec ResolveEKMapID)
    local continentMapID = trackedMapID

    self:EnsureEKGoldMinePins(canvas)

    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 then return end

    local iconSize = GetEKContinentMapPinSize(cw)

    local anyMineShown = false
    for _, mine in ipairs(Overlord.MineDatabase) do
        local pin = ekGoldPins[mine.id]
        if pin and pin.icon then
            local nx, ny = GetMinePositionOnContinentMap(mine, continentMapID)
            if nx and ny then
                local x = nx * cw
                local yDown = ny * ch
                local ox, oy = GetOverlayPoint(canvas, parent, x, yDown)
                -- Ne pas interrompre tout le refresh si une conversion echoue un frame
                if ox and oy then
                    if PlaceMapPinCenter(pin, parent, ox, oy, iconSize) then
                        anyMineShown = true
                    end
                else
                    pin:Hide()
                end
            else
                pin:Hide()
            end
        end
    end
    if ekGoldRoot then
        if anyMineShown then
            ekGoldRoot:Show()
        else
            ekGoldRoot:Hide()
        end
    end
end

function Overlord.MapMarkers:HideEKGoldMinePins()
    if ekGoldRoot and ekGoldRoot:IsShown() then
        ekGoldRoot:Hide()
    end
    for _, pin in pairs(ekGoldPins) do
        if pin and pin:IsShown() then pin:Hide() end
    end
end

-- ============ Icones foret sur cartes continent (EK / Kalimdor), meme principe que les mines ============

local continentWoodRoot = nil
local continentWoodPins = {}

local WOOD_CONTINENT_ICON_ATLASES = {
    "Warfronts-FieldMapIcons-Empty-LumberMill",
    "Warfronts-FieldMapIcons-Empty-Lumbermill",
    "Warfronts-FieldMapIcons-Empty-Lumber",
    "Warfronts-FieldMapIcons-Empty-Wood",
}

local function ApplyContinentWoodPinAtlas(icon)
    if not icon then return false end
    for _, atlas in ipairs(WOOD_CONTINENT_ICON_ATLASES) do
        if atlas and atlas ~= "" and pcall(icon.SetAtlas, icon, atlas) then
            return true
        end
    end
    return false
end

function Overlord.MapMarkers:EnsureContinentWoodPins(canvas)
    local parent = GetOverlayParent()
    if not Overlord.WoodDatabase or not canvas or not parent then return end
    if continentWoodRoot and continentWoodRoot:GetParent() ~= parent then
        continentWoodRoot:SetParent(parent)
    end
    if not continentWoodRoot then
        continentWoodRoot = CreateFrame("Frame", nil, parent)
        continentWoodRoot:SetAllPoints()
    end
    continentWoodRoot:SetFrameStrata(parent:GetFrameStrata())
    continentWoodRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 25)
    for _, wood in ipairs(Overlord.WoodDatabase) do
        if not continentWoodPins[wood.id] then
            local pin = CreateFrame("Frame", nil, continentWoodRoot)
            pin:SetFrameStrata(continentWoodRoot:GetFrameStrata())
            pin:SetFrameLevel(continentWoodRoot:GetFrameLevel() + 1)
            pin.wood = wood

            local icon = pin:CreateTexture(nil, "OVERLAY", nil, 2)
            icon:SetAllPoints()
            ApplyContinentWoodPinAtlas(icon)
            pin.icon = icon

            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                local tp = Overlord.UI.TooltipPalette()
                GameTooltip:AddLine(self.wood.name, tp.HL[1], tp.HL[2], tp.HL[3])
                local res = Overlord.Ressources
                if res and self.wood then
                    local stock = res:GetWoodStock(self.wood.id)
                    local stockMax = res:GetWoodStockMax()
                    if stock < stockMax then
                        GameTooltip:AddLine(string.format(L.WOOD_STOCK, stock, stockMax),
                            tp.HL[1], tp.HL[2], tp.HL[3])
                    end
                end
                GameTooltip:Show()
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            continentWoodPins[wood.id] = pin
        end
    end
end

function Overlord.MapMarkers:RefreshContinentWoodPins()
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then
        self:HideContinentWoodPins()
        return
    end
    local mapID = trackedMapID
    if not self:IsEKMap(mapID) and not self:IsKalimdorMap(mapID) then
        self:HideContinentWoodPins()
        return
    end
    local continentMapID = trackedMapID

    self:EnsureContinentWoodPins(canvas)

    local cw = canvas:GetWidth()
    local ch = canvas:GetHeight()
    if not cw or cw == 0 then return end

    local iconSize = GetEKContinentMapPinSize(cw)

    local anyWoodShown = false
    for _, wood in ipairs(Overlord.WoodDatabase) do
        local pin = continentWoodPins[wood.id]
        if pin and pin.icon then
            local nx, ny = GetMinePositionOnContinentMap(wood, continentMapID)
            if nx and ny then
                local x = nx * cw
                local yDown = ny * ch
                local ox, oy = GetOverlayPoint(canvas, parent, x, yDown)
                if ox and oy then
                    if PlaceMapPinCenter(pin, parent, ox, oy, iconSize) then
                        anyWoodShown = true
                    end
                else
                    pin:Hide()
                end
            else
                pin:Hide()
            end
        end
    end
    if continentWoodRoot then
        if anyWoodShown then
            continentWoodRoot:Show()
        else
            continentWoodRoot:Hide()
        end
    end
end

function Overlord.MapMarkers:HideContinentWoodPins()
    if continentWoodRoot and continentWoodRoot:IsShown() then
        continentWoodRoot:Hide()
    end
    for _, pin in pairs(continentWoodPins) do
        if pin and pin:IsShown() then pin:Hide() end
    end
end

-- Icones sur la carte continent EK (mines d'or + logos domination) : meme principe que les pins

local mineOverlays = {}
local woodOverlays = {}

local MINE_OVERLAY_FILL = { 1, 0.82, 0, 0.38 }
local MINE_OVERLAY_TEXT = { 1, 0.82, 0 }
local WOOD_OVERLAY_FILL = { 0.42, 0.48, 0.16, 0.40 }
local WOOD_OVERLAY_TEXT = { 0.82, 0.88, 0.44 }

local MINE_WORLD_CONFIG
local WOOD_WORLD_CONFIG

local function CreateResourceOverlay(resource, cfg)
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return nil end

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetFrameStrata("HIGH")
    frame.resource = resource
    frame[cfg.field] = resource

    local fill = frame:CreateTexture(nil, "ARTWORK", nil, 2)
    fill:SetTexture(CIRCLE_MASK)
    fill:SetAllPoints()
    fill:SetVertexColor(cfg.fillColor[1], cfg.fillColor[2], cfg.fillColor[3], cfg.fillColor[4])
    frame.fill = fill

    -- Ruban Warboard (meme style que les zones de capture).
    local titleBg = frame:CreateTexture(nil, "ARTWORK", nil, 7)
    titleBg:Hide()
    frame.titleBg = titleBg

    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont(ZONE_TITLE_FONT, 11)
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:SetWordWrap(false)
    text:SetNonSpaceWrap(false)
    text:SetPoint("CENTER", 0, 6)
    text:SetShadowOffset(0, 0)
    text:SetTextColor(ZONE_TITLE_PARCHMENT_R, ZONE_TITLE_PARCHMENT_G, ZONE_TITLE_PARCHMENT_B)
    frame.text = text

    local subtext = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtext:SetPoint("TOP", text, "BOTTOM", 0, -1)
    subtext:SetShadowOffset(0, 0)
    subtext:SetTextColor(ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B)
    frame.subtext = subtext

    if cfg.iconAtlas or cfg.iconAtlases then
        local iconTex = frame:CreateTexture(nil, "OVERLAY")
        iconTex:SetPoint("CENTER", 0, 0)
        iconTex:Hide()
        frame.iconTex = iconTex
    end

    frame:EnableMouse(true)
    SafeSetPassThroughButtons(frame)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        cfg.tooltip(self.resource)
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame:Hide()
    return frame
end

local function ResolveResourceIconAtlas(cfg, tex)
    if not cfg or not tex then return nil end
    if cfg._resolvedIconAtlas ~= nil then
        return cfg._resolvedIconAtlas or nil
    end
    if cfg.iconAtlases then
        for _, atlas in ipairs(cfg.iconAtlases) do
            if atlas and atlas ~= "" and pcall(tex.SetAtlas, tex, atlas) then
                cfg._resolvedIconAtlas = atlas
                return atlas
            end
        end
    elseif cfg.iconAtlas and cfg.iconAtlas ~= "" and pcall(tex.SetAtlas, tex, cfg.iconAtlas) then
        cfg._resolvedIconAtlas = cfg.iconAtlas
        return cfg.iconAtlas
    end
    cfg._resolvedIconAtlas = false
    return nil
end

local function UpdateResourceOverlayVisuals(ov, resource, diameter, cfg)
    if not ov.titleBg then
        local titleBg = ov:CreateTexture(nil, "ARTWORK", nil, 7)
        titleBg:Hide()
        ov.titleBg = titleBg
        ov._olRibbonInit = nil
        ov._olRibbonOk = nil
        ov._olRibbonKey = nil
    end
    local snappedDiameter = math.floor(diameter * 10 + 0.5) / 10
    local layoutChanged = ov._olResourceLayoutDiameter ~= snappedDiameter
    local titlesEnabled = ShouldShowMapZoneTitles()
    local titleModeChanged = ov._olResourceTitlesEnabled ~= titlesEnabled
    if titleModeChanged then
        ov._olResourceTitlesEnabled = titlesEnabled
        ov._olRibbonKey = nil
        if titlesEnabled then
            if not ov.text:IsShown() then ov.text:Show() end
            if not ov.subtext:IsShown() then ov.subtext:Show() end
        end
    end
    if layoutChanged then
        ov._olResourceLayoutDiameter = snappedDiameter
        local titleSz = math.max(7, math.min(22, diameter * 0.22))
        local subSz = math.max(6, math.min(16, diameter * 0.16))
        local titleYOffset = math.max(10, diameter * 0.16)
        ov.text:SetFont(ZONE_TITLE_FONT, titleSz)
        ov.text:SetShadowOffset(0, 0)
        ov.text:SetTextColor(ZONE_TITLE_PARCHMENT_R, ZONE_TITLE_PARCHMENT_G, ZONE_TITLE_PARCHMENT_B)
        ov.text:ClearAllPoints()
        ov.text:SetPoint("CENTER", ov, "CENTER", 0, titleYOffset)
        ov.subtext:SetFont(Overlord.UI.ResolveLocalizedFontPath(GameFontNormalSmall, "Fonts\\FRIZQT__.TTF"), subSz, "")
        ov.subtext:SetShadowOffset(0, 0)
        ov.subtext:SetTextColor(ZONE_TEXT_GOLD_R, ZONE_TEXT_GOLD_G, ZONE_TEXT_GOLD_B)
        ov.subtext:ClearAllPoints()
        ov.subtext:SetPoint("TOP", ov.text, "BOTTOM", 0, -math.max(1, subSz * 0.08))
        if ov.iconTex then
            local iconSize = math.max(10, diameter * 0.30)
            ov.iconTex:ClearAllPoints()
            ov.iconTex:SetPoint("TOP", ov.subtext, "BOTTOM", 0, 1)
            ov.iconTex:SetSize(iconSize, iconSize)
            local atlas = ResolveResourceIconAtlas(cfg, ov.iconTex)
            if atlas then
                if ov._olLastResourceIconAtlas ~= atlas then
                    pcall(ov.iconTex.SetAtlas, ov.iconTex, atlas)
                    ov._olLastResourceIconAtlas = atlas
                end
                ov.iconTex:Show()
            else
                ov.iconTex:Hide()
            end
        end
        ov._olRibbonKey = nil
    end
    if ov._olResourceName ~= resource.name then
        ov._olResourceName = resource.name
        ov.text:SetText(resource.name)
        ov._olRibbonKey = nil
    end
    if not ov.text:IsShown() then ov.text:Show() end
    cfg.updateText(ov, resource, diameter)
    if not ov.subtext:IsShown() then ov.subtext:Show() end
    if layoutChanged or titleModeChanged or ov._olRibbonKey == nil then
        LayoutZoneTitleRibbon(ov)
    end
end

local HideResourceOverlays

HideResourceOverlays = function(overlayTable)
    for _, ov in pairs(overlayTable) do
        if ov and ov:IsShown() then ov:Hide() end
    end
end

local function RefreshResourceOverlays(mapID, database, overlayTable, cfg)
    if overlayTable == woodOverlays then
        woodOverlaysFullyHidden = false
    end
    if not database then return end
    if trackedMapID ~= mapID then
        HideResourceOverlays(overlayTable)
        if overlayTable == woodOverlays then
            woodOverlaysFullyHidden = true
        end
        return
    end
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent then return end

    for _, resource in ipairs(database) do
        if Overlord.Zones:ResourceMatchesMap(resource, mapID) then
            local ov = overlayTable[resource.id]
            if ov and ov:GetParent() ~= parent then
                ov:Hide()
                ov:SetParent(parent)
                ClearMapPinLayoutCache(ov)
                ov._olResourceLayoutDiameter = nil
                ov._olRibbonKey = nil
            end
            if not ov then
                ov = CreateResourceOverlay(resource, cfg)
                overlayTable[resource.id] = ov
            end
            if ov then
                ov.resource = resource
                ov[cfg.field] = resource
                local diameter = PlaceWorldMapCircleOverlay(ov, resource, canvas, parent, cfg.diameter)
                if diameter then
                    UpdateResourceOverlayVisuals(ov, resource, diameter, cfg)
                else
                    ov:Hide()
                end
            end
        else
            local ov = overlayTable[resource.id]
            if ov and ov:IsShown() then ov:Hide() end
        end
    end
end

local function UpdateMineOverlayText(ov, mine, diameter, subSz)
    local res = Overlord.Ressources
    local stock = res and res:GetMineStock(mine.id) or 100
    local stockMax = res and res:GetMineStockMax() or 100
    local key = tostring(stock) .. ":" .. tostring(stockMax)
    if ov._olResourceTextKey ~= key then
        ov._olResourceTextKey = key
        ov.subtext:SetText(string.format(L.MINE_STOCK, stock, stockMax))
    end
end

local function UpdateWoodOverlayText(ov, wood, diameter, subSz)
    local res = Overlord.Ressources
    local stock = res and wood and res:GetWoodStock(wood.id) or 100
    local stockMax = res and res:GetWoodStockMax() or 100
    local key = tostring(stock) .. ":" .. tostring(stockMax)
    if ov._olResourceTextKey ~= key then
        ov._olResourceTextKey = key
        ov.subtext:SetText(string.format(L.WOOD_STOCK, stock, stockMax))
    end
end

MINE_WORLD_CONFIG = {
    field = "mine",
    fillColor = MINE_OVERLAY_FILL,
    textColor = MINE_OVERLAY_TEXT,
    iconAtlas = "Warfronts-FieldMapIcons-Empty-Mine",
    diameter = GetMineOverlayDiameter,
    tooltip = ShowMineResourceTooltip,
    updateText = UpdateMineOverlayText,
}

WOOD_WORLD_CONFIG = {
    field = "wood",
    fillColor = WOOD_OVERLAY_FILL,
    textColor = WOOD_OVERLAY_TEXT,
    iconAtlases = {
        "Warfronts-FieldMapIcons-Empty-LumberMill",
        "Warfronts-FieldMapIcons-Empty-Lumbermill",
        "Warfronts-FieldMapIcons-Empty-Lumber",
        "Warfronts-FieldMapIcons-Empty-Wood",
    },
    diameter = GetWoodOverlayDiameter,
    tooltip = ShowWoodResourceTooltip,
    updateText = UpdateWoodOverlayText,
}

function Overlord.MapMarkers:CreateMineOverlay(mine)
    return CreateResourceOverlay(mine, MINE_WORLD_CONFIG)
end

function Overlord.MapMarkers:CreateWoodOverlay(wood)
    return CreateResourceOverlay(wood, WOOD_WORLD_CONFIG)
end

function Overlord.MapMarkers:RefreshMineOverlays(mapID)
    RefreshResourceOverlays(mapID, Overlord.MineDatabase, mineOverlays, MINE_WORLD_CONFIG)
end

function Overlord.MapMarkers:RefreshWoodOverlays(mapID)
    RefreshResourceOverlays(mapID, Overlord.WoodDatabase, woodOverlays, WOOD_WORLD_CONFIG)
end

function Overlord.MapMarkers:HideMineOverlays()
    HideResourceOverlays(mineOverlays)
end

function Overlord.MapMarkers:HideWoodOverlays()
    if woodOverlaysFullyHidden then return end
    HideResourceOverlays(woodOverlays)
    woodOverlaysFullyHidden = true
end


-- Derniere zone de front pour laquelle on a pose un repere (secours si l'API GetUserWaypoint echoue)
local lastFrontWaypointZoneId = nil

local function ClearUserWaypointTracking()
    if C_Map and C_Map.ClearUserWaypoint then
        pcall(C_Map.ClearUserWaypoint)
    end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false)
    end
end

-- True si le repere utilisateur actuel correspond au centre de cette zone (meme carte + coords proches)
local function UserWaypointMatchesFrontZone(zone, expectedMapID)
    if not zone or not zone.center or not C_Map or not C_Map.GetUserWaypoint then
        return false
    end
    local ok, wp = pcall(C_Map.GetUserWaypoint)
    if not ok or not wp then
        return false
    end
    local mapID = (wp.GetUIMapID and wp:GetUIMapID()) or wp.uiMapID
    if mapID ~= expectedMapID then
        return false
    end
    local pos = (wp.GetPosition and wp:GetPosition()) or wp.position
    if not pos then
        return false
    end
    local x = pos.x
    local y = pos.y
    if (type(x) ~= "number" or type(y) ~= "number") and pos.GetXY then
        x, y = pos:GetXY()
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    local zx, zy = zone.center[1] / 100, zone.center[2] / 100
    -- Epsilon : meme point que UiMapPoint.CreateFromVector2D (flottants)
    local eps = 0.004
    return math.abs(x - zx) < eps and math.abs(y - zy) < eps
end

-- Repere utilisateur Blizzard sur le centre d'une zone (memes coords % que les cercles sur la carte).
-- Second clic sur la meme zone : retire le repere (comportement demande par les joueurs).
-- Carte autorisee pour un repere utilisateur (Retail peut refuser la zone 56 en jeu)
local function MapAllowsUserWaypoint(mapID)
    if not mapID then return false end
    if C_Map.CanSetUserWaypointOnMap then
        local ok, allowed = pcall(C_Map.CanSetUserWaypointOnMap, mapID)
        if ok then return allowed and true or false end
    end
    return true
end

-- Carte + coords du repere fortin : EK puis Paluns puis carte joueur
local function ResolveGuildKeepWaypointPoint(site)
    if not site or not site.mapID or not site.center then return nil, nil, nil end
    local zoneMapID = site.mapID
    local nx = site.center[1] / 100
    local ny = site.center[2] / 100
    local candidates = {}

    local ekID = Overlord.MapMarkers:ResolveEKMapID()
    if ekID then
        local cx, cy = GetMinePositionOnContinentMap(
            { mapID = zoneMapID, center = site.center }, ekID)
        if cx and cy then
            candidates[#candidates + 1] = { ekID, cx, cy }
        end
    end
    local kalID = Overlord.MapMarkers:ResolveKalimdorMapID()
    if kalID then
        local cx, cy = GetMinePositionOnContinentMap(
            { mapID = zoneMapID, center = site.center }, kalID)
        if cx and cy then
            candidates[#candidates + 1] = { kalID, cx, cy }
        end
    end
    if site.regionalMapIDs then
        for regionalMapID in pairs(site.regionalMapIDs) do
            local cx, cy = GetMinePositionOnContinentMap(
                { mapID = zoneMapID, center = site.center }, regionalMapID)
            if cx and cy then
                candidates[#candidates + 1] = { regionalMapID, cx, cy }
            end
        end
    end
    candidates[#candidates + 1] = { zoneMapID, nx, ny }

    local ok, playerMap = pcall(C_Map.GetBestMapForUnit, "player")
    if ok and playerMap and playerMap ~= zoneMapID
        and Overlord.GuildKeep and Overlord.GuildKeep:ResolveSiteByMapID(playerMap) then
        candidates[#candidates + 1] = { playerMap, nx, ny }
    end

    for i = 1, #candidates do
        local mid, x, y = candidates[i][1], candidates[i][2], candidates[i][3]
        if MapAllowsUserWaypoint(mid) then
            return mid, x, y
        end
    end
    if candidates[1] then
        return candidates[1][1], candidates[1][2], candidates[1][3]
    end
    return nil, nil, nil
end

local function ResolveFrontWaypointMapID(frontIdForMap)
    local mapID
    if frontIdForMap and Overlord.Fronts and Overlord.Fronts.GetMapID then
        mapID = Overlord.Fronts:GetMapID(frontIdForMap)
    end
    if not mapID then
        mapID = GetActiveFrontMapID()
    end
    return mapID
end

-- Repere sur le centre du fortin (Les Paluns, carte separee des fronts).
function Overlord.MapMarkers:SetUserWaypointForGuildKeepSite(site)
    if not site or not site.center then return false end
    local mapID, nx, ny = ResolveGuildKeepWaypointPoint(site)
    if not mapID or not nx or not ny then
        Overlord:PrintNotification(L.ZONE_WAYPOINT_BLOCKED)
        return false
    end
    local defaultId = (Overlord.GuildKeep and Overlord.GuildKeep.GetDefaultSite
        and (Overlord.GuildKeep:GetDefaultSite() or {}).id) or "guild_keep"
    local pseudo = { center = { nx * 100, ny * 100 }, id = site.id or defaultId }
    if UserWaypointMatchesFrontZone(pseudo, mapID) and C_Map.ClearUserWaypoint then
        ClearUserWaypointTracking()
        return true
    end
    if not MapAllowsUserWaypoint(mapID) then
        Overlord:PrintNotification(L.ZONE_WAYPOINT_BLOCKED)
        return false
    end
    local okCreate, mapPoint = pcall(function()
        return UiMapPoint.CreateFromVector2D(mapID, CreateVector2D(nx, ny))
    end)
    if not okCreate or not mapPoint then
        Overlord:PrintNotification(L.ZONE_WAYPOINT_FAIL)
        return false
    end
    local okSet = pcall(C_Map.SetUserWaypoint, mapPoint)
    if not okSet then
        Overlord:PrintNotification(L.ZONE_WAYPOINT_FAIL)
        return false
    end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

-- Repere sur le centre d'un avant-poste autonome. Les avant-postes de front
-- continuent d'utiliser la carte de leur front via SetUserWaypointForFrontZone.
function Overlord.MapMarkers:SetUserWaypointForOutpostSite(site)
    if not site or not site.center then return false end
    if not site.standaloneOpenWorld then
        return self:SetUserWaypointForFrontZone(site, site.frontId)
    end
    local mapID = site.mapID
    if not mapID or not MapAllowsUserWaypoint(mapID) then
        Overlord:PrintNotification(L.ZONE_WAYPOINT_BLOCKED)
        return false
    end
    if UserWaypointMatchesFrontZone(site, mapID) and C_Map.ClearUserWaypoint then
        ClearUserWaypointTracking()
        return true
    end
    local nx = site.center[1] / 100
    local ny = site.center[2] / 100
    local okCreate, mapPoint = pcall(function()
        return UiMapPoint.CreateFromVector2D(mapID, CreateVector2D(nx, ny))
    end)
    if not okCreate or not mapPoint then
        Overlord:PrintNotification(L.ZONE_WAYPOINT_FAIL)
        return false
    end
    local okSet = pcall(C_Map.SetUserWaypoint, mapPoint)
    if not okSet then
        Overlord:PrintNotification(L.ZONE_WAYPOINT_FAIL)
        return false
    end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

function Overlord.MapMarkers:UserWaypointMatchesFrontZone(zone, frontIdForMap)
    local mapID = ResolveFrontWaypointMapID(frontIdForMap)
    if not mapID then return false end
    return UserWaypointMatchesFrontZone(zone, mapID)
end

function Overlord.MapMarkers:ClearUserWaypointForFrontZone(zone, frontIdForMap)
    if not zone then return false end
    local mapID = ResolveFrontWaypointMapID(frontIdForMap)
    if mapID and UserWaypointMatchesFrontZone(zone, mapID) and C_Map and C_Map.ClearUserWaypoint then
        ClearUserWaypointTracking()
        if lastFrontWaypointZoneId == zone.id then
            lastFrontWaypointZoneId = nil
        end
        return true
    end
    return false
end

function Overlord.MapMarkers:SetUserWaypointForFrontZone(zone, frontIdForMap, opts)
    opts = opts or {}
    if not zone or not zone.center then
        return false
    end
    local mapID = ResolveFrontWaypointMapID(frontIdForMap)
    if not mapID then
        if not opts.silent then
            Overlord:PrintNotification(L.ZONE_WAYPOINT_BLOCKED)
        end
        return false
    end

    -- Uniquement si le repere correspond deja au centre de cette zone :
    -- evite d'effacer un repere pose ailleurs sur la carte du front).
    if UserWaypointMatchesFrontZone(zone, mapID) and C_Map.ClearUserWaypoint then
        if opts.noToggle then
            lastFrontWaypointZoneId = zone.id
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
            end
            return true
        end
        ClearUserWaypointTracking()
        lastFrontWaypointZoneId = nil
        return true
    end

    if not MapAllowsUserWaypoint(mapID) then
        if not opts.silent then
            Overlord:PrintNotification(L.ZONE_WAYPOINT_BLOCKED)
        end
        return false
    end
    local nx = zone.center[1] / 100
    local ny = zone.center[2] / 100
    local okCreate, mapPoint = pcall(function()
        return UiMapPoint.CreateFromVector2D(mapID, CreateVector2D(nx, ny))
    end)
    if not okCreate or not mapPoint then
        if not opts.silent then
            Overlord:PrintNotification(L.ZONE_WAYPOINT_FAIL)
        end
        return false
    end
    local okSet = pcall(C_Map.SetUserWaypoint, mapPoint)
    if not okSet then
        if not opts.silent then
            Overlord:PrintNotification(L.ZONE_WAYPOINT_FAIL)
        end
        return false
    end
    lastFrontWaypointZoneId = zone.id
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

-- Pont vers BountyMap.lua (évite de dépasser la limite 200 locals de ce chunk)
function Overlord.MapMarkers:WithWorldMapPinLayer(fn)
    CacheCanvas()
    local canvas = GetCanvas()
    local parent = GetOverlayParent()
    if not canvas or not parent or not fn then return end
    fn(canvas, parent, ReadDisplayedMapID())
end

-- Pont placement pins (GeneralMap / BountyMap) : meme repere que zones / fortins.
function Overlord.MapMarkers:GetWorldMapOverlayPoint(canvas, parent, x, yDown)
    return GetOverlayPoint(canvas, parent, x, yDown)
end

function Overlord.MapMarkers:PlaceWorldMapPin(pin, parent, ox, oy, iconSize)
    return PlaceMapPinCenter(pin, parent, ox, oy, iconSize)
end

function Overlord.MapMarkers:ClearWorldMapPinLayout(pin)
    ClearMapPinLayoutCache(pin)
end

function Overlord.MapMarkers:GetWorldMapCanvas()
    CacheCanvas()
    return GetCanvas(), GetOverlayParent()
end

function Overlord.MapMarkers:IsMinimapFrontOverlayMap(mapID)
    return IsMinimapFrontOverlayMap(mapID)
end

function Overlord.MapMarkers:GetTrackedMapID()
    return trackedMapID
end

function Overlord.MapMarkers:ResolveResourceMinimapMapIDFor(mapID, isResourceMapID)
    return ResolveResourceMinimapMapID(mapID, isResourceMapID)
end

function Overlord.MapMarkers:GetPlayerPositionOnResourceMap(mapID)
    return GetPlayerPositionForResourceMap(mapID)
end

function Overlord.MapMarkers:CalcResourceYardsPerPctFor(tbl, mapID)
    CalcResourceYardsPerPct(tbl, mapID)
end

function Overlord.MapMarkers:HideResourceMinimapPinsTable(pins)
    HideResourceMinimapPins(pins)
end

function Overlord.MapMarkers:GetMinePositionOnContinentMap(mine, continentMapID)
    return GetMinePositionOnContinentMap(mine, continentMapID)
end

function Overlord.MapMarkers:GetEKDominanceLogoSizeFor(canvas, parent)
    return GetEKDominanceLogoSize(canvas, parent)
end

function Overlord.MapMarkers:PlaceMinimapPinCenter(pin, pinX, pinY)
    PlaceMinimapPinCenter(pin, pinX, pinY)
end

function Overlord.MapMarkers:GetMinimapCacheState()
    -- Keep/Outpost consultent cet etat jusqu'a ~60 Hz. Reutiliser la meme table :
    -- les consommateurs lisent les champs immediatement et ne la conservent pas.
    local state = self._minimapCacheState
    if not state then
        state = {}
        self._minimapCacheState = state
    end
    state.mapID = mmCachedMapID
    state.halfMM = mmCachedHalfMM
    state.pxPerYard = mmCachedPxPerYard
    state.rotate = mmCachedRotate
    state.facing = mmCachedFacing
    return state
end

function Overlord.MapMarkers:GetMinimapDriverContext()
    if not Overlord.InActiveFront or not Overlord.IsInitialized then return nil end
    local mapID = GetActiveFrontMapID()
    if not mapID then return nil end
    self:CalcMinimapScale()
    if not mmYardsPerPctX or not mmYardsPerPctY then return nil end
    local px, py = GetPlayerPositionForResourceMap(mapID)
    if not px or not py then return nil end
    local rotateMM = mmCachedRotate
    local sinF, cosF
    if rotateMM then
        sinF, cosF = math.sin(-mmCachedFacing), math.cos(-mmCachedFacing)
    end
    local context = mmSharedDriverContext
    context.mapID = mapID
    context.px = px
    context.py = py
    context.yppX = mmYardsPerPctX
    context.yppY = mmYardsPerPctY
    context.pxPerYard = mmCachedPxPerYard
    context.halfMM = mmCachedHalfMM
    context.rotateMM = rotateMM
    context.sinF = sinF
    context.cosF = cosF
    return context
end

-- Compatibilite pour d'eventuels modules externes : meme contrat, mais sans table temporaire.
function Overlord.MapMarkers:WithMinimapDriver(fn)
    if not fn then return end
    local context = self:GetMinimapDriverContext()
    if context then fn(context) end
end

function Overlord.MapMarkers:QueuePassThroughButtons(frame)
    SafeSetPassThroughButtons(frame)
end

function Overlord.MapMarkers:UpdateMinimapBountyPins(context, dataRefresh)
    if Overlord.BountyMap and Overlord.BountyMap.UpdateMinimapPins then
        Overlord.BountyMap:UpdateMinimapPins(context, dataRefresh)
    end
end

function Overlord.MapMarkers:UpdateMinimapManualBountyPins(context, dataRefresh)
    if Overlord.ManualBountyMap and Overlord.ManualBountyMap.UpdateMinimapPins then
        Overlord.ManualBountyMap:UpdateMinimapPins(context, dataRefresh)
    end
end

function Overlord.MapMarkers:HideMinimapBountyPins()
    if Overlord.BountyMap and Overlord.BountyMap.HideMinimapPins then
        Overlord.BountyMap:HideMinimapPins()
    end
end

function Overlord.MapMarkers:HideMinimapManualBountyPins()
    if Overlord.ManualBountyMap and Overlord.ManualBountyMap.HideMinimapPins then
        Overlord.ManualBountyMap:HideMinimapPins()
    end
end

function Overlord.MapMarkers:UpdateMinimapGeneralPins(context, dataRefresh)
    if Overlord.GeneralMap and Overlord.GeneralMap.UpdateMinimapPins then
        Overlord.GeneralMap:UpdateMinimapPins(context, dataRefresh)
    end
end

function Overlord.MapMarkers:HideMinimapGeneralPins()
    if Overlord.GeneralMap and Overlord.GeneralMap.HideMinimapPins then
        Overlord.GeneralMap:HideMinimapPins()
    end
end
