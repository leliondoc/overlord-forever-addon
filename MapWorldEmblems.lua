-- MapWorldEmblems.lua - Blasons de continent sur la carte du monde (1.8.0)
-- Sur la carte Azeroth, un grand logo de faction sur Kalimdor et sur les Royaumes de
-- l'Est : la faction qui domine le plus de fronts du continent (les fronts qui portent
-- son logo de domination sur la carte du continent). Egalite, ou aucun front domine :
-- pas de blason. Chunk separe : MapMarkers.lua est proche de la limite de 200 locales.
-- Aucun OnUpdate propre : le driver de la carte appelle RefreshWorldEmblems a chaque
-- tick ; hors carte du monde c'est une comparaison d'id, et le blason n'est repeint
-- qu'au changement de layout (zoom, taille) ou de contenu (captures).
Overlord = Overlord or {}
Overlord.MapMarkers = Overlord.MapMarkers or {}

local MM = Overlord.MapMarkers

local EMBLEM_TEXTURE = {
    Alliance = "Interface\\Timer\\Alliance-Logo",
    Horde = "Interface\\Timer\\Horde-Logo",
}
-- Fraction de la largeur du canvas (les logos de front sur un continent : 0.032).
local EMBLEM_SIZE_FRAC = 0.09
local EMBLEM_ALPHA = 0.85
-- Centre du blason : une zone de reference dans le haut du continent, au-dessus de son
-- nom (Classic puis Retail), a defaut le centre du continent. Racines = ids de continent.
-- Les deux blasons partagent la meme hauteur (moyenne des deux), les zones de reference
-- n'etant pas au meme niveau sur la carte.
local CONTINENTS = {
    { key = "K", roots = { 1414, 12 }, anchors = { 1440, 63 } },  -- Kalimdor : Orneval
    { key = "EK", roots = { 1415, 13 }, anchors = { 1417, 14 } }, -- Royaumes de l'Est : Arathi
}
local RETRY_SEC = 30

local state = {
    painted = false,
    worldMapID = nil,
    worldRetryAt = 0,
    pointRetryAt = 0,
    points = {},
    frames = {},
}

-- Carte du monde = parent d'une carte de continent. Echec (donnees de carte pas
-- encore lues) : nouvel essai au plus toutes les 30 s.
local function ResolveWorldMapID()
    if state.worldMapID then return state.worldMapID end
    if GetTime() < state.worldRetryAt or not C_Map or not C_Map.GetMapInfo then return nil end
    for _, continent in ipairs(CONTINENTS) do
        for _, root in ipairs(continent.roots) do
            local ok, info = pcall(C_Map.GetMapInfo, root)
            local parentID = ok and type(info) == "table" and tonumber(info.parentMapID) or nil
            if parentID and parentID > 0 then
                state.worldMapID = parentID
                return parentID
            end
        end
    end
    state.worldRetryAt = GetTime() + RETRY_SEC
    return nil
end

local function RectCenter(mapID, worldID)
    if not C_Map or not C_Map.GetMapRectOnMap then return nil end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, mapID, worldID)
    if ok and minX and maxX and minY and maxY and maxX > minX and maxY > minY then
        return (minX + maxX) / 2, (minY + maxY) / 2
    end
    return nil
end

-- Position normalisee sur la carte du monde (geometrie statique : gardee une fois lue).
local function ContinentPoint(continent, worldID)
    local point = state.points[continent.key]
    if point then return point[1], point[2] end
    if GetTime() < state.pointRetryAt then return nil end
    for _, list in ipairs({ continent.anchors, continent.roots }) do
        for _, mapID in ipairs(list) do
            local x, y = RectCenter(mapID, worldID)
            if x then
                state.points[continent.key] = { x, y }
                return x, y
            end
        end
    end
    state.pointRetryAt = GetTime() + RETRY_SEC
    return nil
end

-- Faction qui domine le plus de fronts du continent ; nil a egalite.
local function ContinentDominantFaction(continentKey)
    local fronts = Overlord.Fronts
    if not fronts or not fronts.Order or not fronts.Registry or not fronts.GetMapID
        or not Overlord.GetMapContinent then
        return nil
    end
    local alliance, horde = 0, 0
    for _, frontId in ipairs(fronts.Order) do
        local front = fronts.Registry[frontId]
        local mapID = front and fronts:GetMapID(front.id)
        if mapID and Overlord:GetMapContinent(mapID) == continentKey then
            local faction = MM:GetDominantFaction(front)
            if faction == "Alliance" then
                alliance = alliance + 1
            elseif faction == "Horde" then
                horde = horde + 1
            end
        end
    end
    if alliance > horde then return "Alliance" end
    if horde > alliance then return "Horde" end
    return nil
end

local function EmblemFrame(key, parent)
    local frame = state.frames[key]
    if not frame then
        frame = CreateFrame("Frame", nil, parent)
        local logo = frame:CreateTexture(nil, "ARTWORK")
        logo:SetAllPoints(frame)
        logo:SetAlpha(EMBLEM_ALPHA)
        frame.logo = logo
        state.frames[key] = frame
    elseif frame:GetParent() ~= parent then
        frame:SetParent(parent)
    end
    -- Sous les autres pins Overlord (logos de front : +40).
    frame:SetFrameStrata(parent:GetFrameStrata())
    frame:SetFrameLevel((parent:GetFrameLevel() or 0) + 2)
    return frame
end

function MM:HideWorldEmblems()
    state.painted = false
    for _, frame in pairs(state.frames) do
        frame:Hide()
    end
end

function MM:RefreshWorldEmblems(mapID, layoutChanged, contentRefresh)
    local worldID = mapID and ResolveWorldMapID()
    if not worldID or mapID ~= worldID or Overlord.InstanceSuspended or not Overlord.IsInitialized then
        if state.painted then self:HideWorldEmblems() end
        return
    end
    if state.painted and not layoutChanged and not contentRefresh then return end
    local canvas, parent = self:GetWorldMapCanvas()
    local cw = canvas and canvas:GetWidth()
    local ch = canvas and canvas:GetHeight()
    if not parent or not cw or cw <= 0 or not ch or ch <= 0 then
        self:HideWorldEmblems()
        return
    end
    local scaleRatio = 1
    local canvasScale, parentScale = canvas:GetEffectiveScale(), parent:GetEffectiveScale()
    if canvasScale and canvasScale > 0 and parentScale and parentScale > 0 then
        scaleRatio = canvasScale / parentScale
    end
    local size = math.floor(cw * EMBLEM_SIZE_FRAC * scaleRatio * MM.GetMapIconScale() + 0.5)
    local rowY, rows = 0, 0
    for _, continent in ipairs(CONTINENTS) do
        local _, y = ContinentPoint(continent, worldID)
        if y then rowY, rows = rowY + y, rows + 1 end
    end
    local placed = true
    for _, continent in ipairs(CONTINENTS) do
        local faction = ContinentDominantFaction(continent.key)
        local nx = ContinentPoint(continent, worldID)
        local ny = rows > 0 and rowY / rows or nil
        local ox, oy
        if faction and nx then
            ox, oy = self:GetWorldMapOverlayPoint(canvas, parent, nx * cw, ny * ch)
        end
        if ox and oy then
            local frame = EmblemFrame(continent.key, parent)
            if frame._faction ~= faction then
                frame.logo:SetTexture(EMBLEM_TEXTURE[faction])
                frame._faction = faction
            end
            frame:SetSize(size, size)
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", parent, "TOPLEFT", math.floor(ox + 0.5), math.floor(oy + 0.5))
            frame:Show()
        else
            -- Canvas pas encore ancre : nouvel essai au tick suivant.
            if faction and nx then placed = false end
            if state.frames[continent.key] then state.frames[continent.key]:Hide() end
        end
    end
    state.painted = placed
end
