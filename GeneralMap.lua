-- GeneralMap.lua - Pins Généraux (allié + ennemi) : grande carte, continent, minimap
Overlord = Overlord or {}
Overlord.GeneralMap = {}

local L = Overlord.L

local generalWorldRoot = nil
local generalWorldPins = {}
local generalContinentRoot = nil
local generalContinentPins = {}
local generalMinimapPins = {}
local generalMinimapSeen = {}
local generalMinimapCacheMapID = nil
local generalMinimapCacheRevision = nil
local generalMinimapCacheEntries = nil

local MM_ICON_MIN = 18
local MM_ICON_MAX = 28
local MM_ICON_SCALE = 1.25
local WORLD_PIN_MIN = 24
local WORLD_PIN_MAX = 44
local WORLD_PIN_FRAC = 0.055
local CONTINENT_PIN_MIN = 24
local CONTINENT_PIN_MAX = 36
local CONTINENT_PIN_FRAC = 0.022

local function ResolveGeneralFactionAtlas(faction)
    if Overlord.General and Overlord.General.GetFactionBadgeAtlas then
        return Overlord.General:GetFactionBadgeAtlas(faction)
    end
end

local function ApplyPinFactionIcon(pin, entry)
    if not pin or not pin.icon or not entry or not entry.faction then return end
    local atlas = ResolveGeneralFactionAtlas(entry.faction)
    if not atlas or not pin.icon.SetAtlas then return end
    if pin._olAtlas ~= atlas then
        pcall(pin.icon.SetAtlas, pin.icon, atlas)
        pin._olAtlas = atlas
    end
end

local function SnapPinCoord(v)
    return math.floor((tonumber(v) or 0) * 2 + 0.5) / 2
end

local function GetOverlayPoint(canvas, parent, x, yDown)
    local mm = Overlord.MapMarkers
    if mm and mm.GetWorldMapOverlayPoint then
        return mm:GetWorldMapOverlayPoint(canvas, parent, x, yDown)
    end
    return nil, nil
end

local function PlaceMapPinCenter(pin, parent, ox, oy, iconSize)
    local mm = Overlord.MapMarkers
    if mm and mm.PlaceWorldMapPin then
        return mm:PlaceWorldMapPin(pin, parent, ox, oy, iconSize)
    end
    return false
end

local function SafeSetPassThroughButtons(frame)
    if not frame or frame:IsForbidden() then return end
    if Overlord.MapMarkers and Overlord.MapMarkers.QueuePassThroughButtons then
        Overlord.MapMarkers:QueuePassThroughButtons(frame)
        return
    end
    if InCombatLockdown() then return end
    pcall(function()
        frame:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton")
    end)
end

local function PinKey(entry)
    return entry.faction or entry.name
end

local function ShowGeneralTooltip(entry)
    if not entry then return end
    local hr, hg, hb = 1, 0.82, 0.2
    if Overlord.UI and Overlord.UI.TooltipPalette then
        local tp = Overlord.UI.TooltipPalette()
        if tp and tp.HL then hr, hg, hb = tp.HL[1], tp.HL[2], tp.HL[3] end
    end
    local short = (entry.name or "?"):match("^(.-)%-") or entry.name
    local isEnemy = entry.faction and entry.faction ~= Overlord.PlayerFaction
    if isEnemy and L and L.GENERAL_ENEMY_MAP_TOOLTIP then
        GameTooltip:AddLine(string.format(L.GENERAL_ENEMY_MAP_TOOLTIP, short), 1, 0.45, 0.45)
    elseif L and L.GENERAL_MAP_TOOLTIP then
        GameTooltip:AddLine(string.format(L.GENERAL_MAP_TOOLTIP, short), hr, hg, hb)
    else
        GameTooltip:AddLine(short, hr, hg, hb)
    end
    if L and L.GENERAL_SHARD_UNKNOWN and Overlord.Shard and Overlord.Shard.IsPlayerOnDifferentShard then
        if Overlord.Shard:IsPlayerOnDifferentShard(entry.name) then
            GameTooltip:AddLine(L.GENERAL_SHARD_UNKNOWN, 0.7, 0.7, 0.7)
        end
    end
    GameTooltip:Show()
end

local function TransformGeneralMapCoords(srcMapID, mapX, mapY, targetMapID)
    if not srcMapID or not targetMapID or mapX == nil or mapY == nil then return nil, nil end
    if srcMapID == targetMapID then return mapX, mapY end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, srcMapID, targetMapID)
    if not ok or not minX or not maxX or not minY or not maxY or maxX <= minX or maxY <= minY then
        return nil, nil
    end
    local nx = minX + (maxX - minX) * (mapX / 100)
    local ny = minY + (maxY - minY) * (mapY / 100)
    return nx * 100, ny * 100
end

local function GetZoneMapPinPosition(entry, viewedMapID, canvasW, canvasH)
    if not entry or not viewedMapID or not canvasW or not canvasH then return nil, nil end
    local px, py = TransformGeneralMapCoords(entry.mapID, entry.mapX, entry.mapY, viewedMapID)
    if not px or not py then return nil, nil end
    return px * canvasW / 100, py * canvasH / 100
end

local function GeneralMapIDsMatch(entryMapID, viewedMapID)
    if Overlord.General and Overlord.General.MapIDsMatchForDisplay then
        return Overlord.General.MapIDsMatchForDisplay(entryMapID, viewedMapID)
    end
    return entryMapID == viewedMapID
end

local function GetContinentPosition(entry, continentMapID)
    if not entry or not continentMapID or not entry.mapID
        or not entry.mapX or not entry.mapY then
        return nil, nil
    end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, entry.mapID, continentMapID)
    if ok and minX and maxX and minY and maxY and maxX > minX and maxY > minY then
        local nx = minX + (maxX - minX) * (entry.mapX / 100)
        local ny = minY + (maxY - minY) * (entry.mapY / 100)
        return nx, ny
    end
    return nil, nil
end

local function IsContinentMapID(mapID)
    local mm = Overlord.MapMarkers
    if not mm or not mapID then return false end
    return (mm.IsEKMap and mm:IsEKMap(mapID)) or (mm.IsKalimdorMap and mm:IsKalimdorMap(mapID))
end

local function EnsureWorldPin(key, faction, parent)
    if not parent then return nil end
    if generalWorldRoot and generalWorldRoot:GetParent() ~= parent then
        generalWorldRoot:SetParent(parent)
        generalWorldRoot:SetAllPoints()
        generalWorldRoot:SetFrameStrata(parent:GetFrameStrata())
        generalWorldRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 31)
    end
    if not generalWorldRoot then
        generalWorldRoot = CreateFrame("Frame", nil, parent)
        generalWorldRoot:SetAllPoints()
        generalWorldRoot:SetFrameStrata(parent:GetFrameStrata())
        generalWorldRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 31)
    end

    local pin = generalWorldPins[key]
    if not pin then
        pin = CreateFrame("Frame", nil, generalWorldRoot)
        pin:SetFrameLevel(generalWorldRoot:GetFrameLevel() + 1)
        local icon = pin:CreateTexture(nil, "OVERLAY", nil, 3)
        icon:SetAllPoints()
        pin.icon = icon
        pin:EnableMouse(true)
        SafeSetPassThroughButtons(pin)
        pin:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            ShowGeneralTooltip(self.entry)
        end)
        pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
        generalWorldPins[key] = pin
    end
    ApplyPinFactionIcon(pin, { faction = faction })
    return pin
end

local function EnsureContinentPin(key, faction, parent)
    if not parent then return nil end
    if generalContinentRoot and generalContinentRoot:GetParent() ~= parent then
        generalContinentRoot:SetParent(parent)
        generalContinentRoot:SetAllPoints()
        generalContinentRoot:SetFrameStrata(parent:GetFrameStrata())
        generalContinentRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 27)
    end
    if not generalContinentRoot then
        generalContinentRoot = CreateFrame("Frame", nil, parent)
        generalContinentRoot:SetAllPoints()
        generalContinentRoot:SetFrameStrata(parent:GetFrameStrata())
        generalContinentRoot:SetFrameLevel((parent:GetFrameLevel() or 0) + 27)
    end

    local pin = generalContinentPins[key]
    if not pin then
        pin = CreateFrame("Frame", nil, generalContinentRoot)
        pin:SetFrameLevel(generalContinentRoot:GetFrameLevel() + 1)
        local icon = pin:CreateTexture(nil, "OVERLAY", nil, 3)
        icon:SetAllPoints()
        pin.icon = icon
        pin:EnableMouse(true)
        SafeSetPassThroughButtons(pin)
        pin:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            ShowGeneralTooltip(self.entry)
        end)
        pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
        generalContinentPins[key] = pin
    end
    ApplyPinFactionIcon(pin, { faction = faction })
    return pin
end

local function CreateMinimapGeneralIconPin()
    local pin = CreateFrame("Frame", nil, Minimap)
    pin:SetFrameStrata("MEDIUM")
    pin:SetFrameLevel(7)
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

local function PlaceMinimapGeneralPinCenter(pin, pinX, pinY)
    if not pin then return false end
    pinX = SnapPinCoord(pinX)
    pinY = SnapPinCoord(pinY)
    if pin._olMMX == pinX and pin._olMMY == pinY then
        return true
    end
    pin._olMMX = pinX
    pin._olMMY = pinY
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", Minimap, "CENTER", pinX, pinY)
    return true
end

local function EnsureMinimapPin(key)
    local pin = generalMinimapPins[key]
    if pin then return pin end
    pin = CreateMinimapGeneralIconPin()
    pin:EnableMouse(true)
    SafeSetPassThroughButtons(pin)
    pin:SetScript("OnEnter", function(self)
        if not self.entry then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        ShowGeneralTooltip(self.entry)
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    generalMinimapPins[key] = pin
    return pin
end

function Overlord.GeneralMap:HideWorld()
    if generalWorldRoot and generalWorldRoot:IsShown() then generalWorldRoot:Hide() end
    for _, pin in pairs(generalWorldPins) do
        if pin and pin:IsShown() then pin:Hide() end
    end
end

function Overlord.GeneralMap:HideContinent()
    if generalContinentRoot and generalContinentRoot:IsShown() then generalContinentRoot:Hide() end
    for _, pin in pairs(generalContinentPins) do
        if pin and pin:IsShown() then pin:Hide() end
    end
end

function Overlord.GeneralMap:HideMinimapPins()
    for _, pin in pairs(generalMinimapPins) do
        if pin and pin:IsShown() then pin:Hide() end
    end
end

function Overlord.GeneralMap:RefreshContinent()
    local mm = Overlord.MapMarkers
    if not mm or not mm.WithWorldMapPinLayer then
        self:HideContinent()
        return
    end
    mm:WithWorldMapPinLayer(function(canvas, parent, mapID)
        if not mapID or not IsContinentMapID(mapID) then
            Overlord.GeneralMap:HideContinent()
            return
        end
        local entries = Overlord.General and Overlord.General:GetActiveList() or {}
        local cw = canvas:GetWidth()
        local ch = canvas:GetHeight()
        if not cw or cw == 0 or not ch or ch == 0 then
            Overlord.GeneralMap:HideContinent()
            return
        end
        local iconSize = math.max(CONTINENT_PIN_MIN, math.min(CONTINENT_PIN_MAX, cw * CONTINENT_PIN_FRAC))
        local seen = {}
        local anyShown = false

        for i = 1, #entries do
            local entry = entries[i]
            local key = PinKey(entry)
            if key and entry.mapX and entry.mapY and entry.mapID then
                local nx, ny = GetContinentPosition(entry, mapID)
                if nx and ny then
                    seen[key] = true
                    local pin = EnsureContinentPin(key, entry.faction, parent)
                    if pin then
                        pin.entry = entry
                        local ox, oy = GetOverlayPoint(canvas, parent, nx * cw, ny * ch)
                        if ox and oy and PlaceMapPinCenter(pin, parent, ox, oy, iconSize) then
                            anyShown = true
                        else
                            pin:Hide()
                        end
                    end
                end
            end
        end

        for key, pin in pairs(generalContinentPins) do
            if not seen[key] and pin then pin:Hide() end
        end

        if generalContinentRoot then
            if anyShown then generalContinentRoot:Show() else generalContinentRoot:Hide() end
        end
    end)
end

function Overlord.GeneralMap:Refresh()
    local mm = Overlord.MapMarkers
    if not mm or not mm.WithWorldMapPinLayer then
        self:HideWorld()
        return
    end
    mm:WithWorldMapPinLayer(function(canvas, parent, mapID)
        local front = Overlord.Fronts and (
            Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
            or (Overlord.Fronts.ResolveFrontByMapID and Overlord.Fronts:ResolveFrontByMapID(mapID))
        )
        if not mapID or not front then
            Overlord.GeneralMap:HideWorld()
            return
        end
        local entries = Overlord.General and Overlord.General:GetActiveList() or {}
        local cw = canvas:GetWidth()
        local ch = canvas:GetHeight()
        if not cw or cw == 0 or not ch or ch == 0 then
            Overlord.GeneralMap:HideWorld()
            return
        end
        local iconSize = math.max(WORLD_PIN_MIN, math.min(WORLD_PIN_MAX, cw * WORLD_PIN_FRAC))
        local seen = {}
        local anyShown = false

        for i = 1, #entries do
            local entry = entries[i]
            local key = PinKey(entry)
            if key and entry.mapX and entry.mapY and entry.mapID
                and GeneralMapIDsMatch(entry.mapID, mapID) then
                seen[key] = true
                local pin = EnsureWorldPin(key, entry.faction, parent)
                if pin then
                    pin.entry = entry
                    local x, yDown = GetZoneMapPinPosition(entry, mapID, cw, ch)
                    local ox, oy = GetOverlayPoint(canvas, parent, x, yDown)
                    if ox and oy and PlaceMapPinCenter(pin, parent, ox, oy, iconSize) then
                        anyShown = true
                    else
                        pin:Hide()
                    end
                end
            end
        end

        for key, pin in pairs(generalWorldPins) do
            if not seen[key] and pin then pin:Hide() end
        end

        if generalWorldRoot then
            if anyShown then generalWorldRoot:Show() else generalWorldRoot:Hide() end
        end
    end)
end

function Overlord.GeneralMap:UpdateMinimapPins(ctx, dataRefresh)
    local onFront = Overlord.General and Overlord.General.IsGeneralFrontContext
        and Overlord.General:IsGeneralFrontContext()
    if not onFront or Overlord.InstanceSuspended then
        self:HideMinimapPins()
        return
    end
    if not ctx or not ctx.mapID then
        self:HideMinimapPins()
        return
    end
        local revision = Overlord.General.GetRevision and Overlord.General:GetRevision() or 0
        local cacheChanged = generalMinimapCacheMapID ~= ctx.mapID
            or generalMinimapCacheRevision ~= revision
        local reconcile = cacheChanged
        if cacheChanged then
            generalMinimapCacheMapID = ctx.mapID
            generalMinimapCacheRevision = revision
            generalMinimapCacheEntries = {}
            local rawEntries = Overlord.General:GetEntriesForMap(ctx.mapID)
            for i = 1, #rawEntries do
                local entry = rawEntries[i]
                local mapX, mapY = TransformGeneralMapCoords(entry.mapID, entry.mapX, entry.mapY, ctx.mapID)
                local key = PinKey(entry)
                if key and mapX and mapY then
                    generalMinimapCacheEntries[#generalMinimapCacheEntries + 1] = {
                        entry = entry,
                        key = key,
                        mapX = mapX,
                        mapY = mapY,
                    }
                end
            end
        end
        local entries = generalMinimapCacheEntries or {}
        if reconcile then wipe(generalMinimapSeen) end

        for i = 1, #entries do
            local cached = entries[i]
            local entry = cached.entry
            local key = cached.key
            if key then
                if reconcile then generalMinimapSeen[key] = true end
                local genX, genY = cached.mapX, cached.mapY
                local pin = generalMinimapPins[key]
                if reconcile and not pin then pin = EnsureMinimapPin(key) end
                if pin then
                    local dx = (genX - ctx.px) * ctx.yppX
                    local dy = (genY - ctx.py) * ctx.yppY
                    local pinX = dx * ctx.pxPerYard
                    local pinY = -dy * ctx.pxPerYard
                    if ctx.rotateMM and ctx.sinF and ctx.cosF then
                        pinX, pinY = pinX * ctx.cosF - pinY * ctx.sinF,
                            pinX * ctx.sinF + pinY * ctx.cosF
                    end
                    local avgYPP = (ctx.yppX + ctx.yppY) / 2
                    local iconSz = math.max(MM_ICON_MIN,
                        math.min(MM_ICON_MAX, avgYPP * MM_ICON_SCALE * ctx.pxPerYard))
                    local visibleRadius = ctx.halfMM + iconSz / 2
                    if pinX * pinX + pinY * pinY > visibleRadius * visibleRadius then
                        pin:Hide()
                    else
                        if pin._olSz ~= iconSz then
                            pin:SetSize(iconSz, iconSz)
                            pin.icon:SetSize(iconSz, iconSz)
                            pin._olSz = iconSz
                        end
                        ApplyPinFactionIcon(pin, entry)
                        PlaceMinimapGeneralPinCenter(pin, pinX, pinY)
                        pin.entry = entry
                        pin:Show()
                    end
                end
            end
        end

        if reconcile then
            for key, pin in pairs(generalMinimapPins) do
                if not generalMinimapSeen[key] and pin and pin:IsShown() then
                    pin:Hide()
                end
            end
        end
end

function Overlord.GeneralMap:Hide()
    self:HideWorld()
    self:HideContinent()
    self:HideMinimapPins()
end
