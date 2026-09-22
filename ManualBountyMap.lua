-- ManualBountyMap.lua - Cibles des contrats en or sur carte et minimap
Overlord = Overlord or {}
Overlord.ManualBountyMap = {}

local L = Overlord.L
local worldLayer = { root = nil, pins = {}, pool = {}, free = {}, freeIndex = {} }
local continentLayer = { root = nil, pins = {}, pool = {}, free = {}, freeIndex = {} }
local worldBackLayer = { root = nil, pins = {}, pool = {}, free = {}, freeIndex = {} }
local continentBackLayer = { root = nil, pins = {}, pool = {}, free = {}, freeIndex = {} }
local minimapPins = {}
local minimapPool = {}
local minimapSeen = {}
local minimapCacheMapID = nil
local minimapCacheRevision = nil
local minimapCacheEntries = {}
local minimapBuildEntries = {}
local minimapSelectionAnchorX, minimapSelectionAnchorY
local minimapSelectionCommitted = false
local minimapSourceEntries = {}
local minimapSourceKeys = {}
local minimapSourceHead = 1
local minimapSourceCount = 0
local minimapBuildState = { token = 0, sourceVersion = 0 }
local continentSeen = {}
local worldSeen = {}
local worldBuildEntries = {}
local continentBuildEntries = {}

local WORLD_PIN_MIN = 24
local WORLD_PIN_MAX = 40
local WORLD_PIN_FRAC = 0.05
local CONTINENT_PIN_MIN = 20
local CONTINENT_PIN_MAX = 30
local CONTINENT_PIN_FRAC = 0.019
local MINIMAP_PIN_MIN = 16
local MINIMAP_PIN_MAX = 24
local MINIMAP_ACTIVE_PIN_MAX = 24
local MINIMAP_RESELECT_DISTANCE_YARDS = 180
local MINIMAP_REBUILD_BATCH = 16
local MINIMAP_SOURCE_MAX = 1024
local STATIC_MAP_REBUILD_BATCH = 16

local worldBuildState = {
    token = 0,
    kind = "world",
    activeLayer = worldLayer,
    buildLayer = worldBackLayer,
    seen = worldSeen,
    buffer = worldBuildEntries,
}
local continentBuildState = {
    token = 0,
    kind = "continent",
    activeLayer = continentLayer,
    buildLayer = continentBackLayer,
    seen = continentSeen,
    buffer = continentBuildEntries,
}

local function PinKey(entry)
    return entry and entry.name and entry.name:lower() or nil
end

local function TrackMinimapSourcePosition(name, mapX, mapY, mapID)
    local key = type(name) == "string" and name:lower() or nil
    if not key or key == "" then return end
    mapX, mapY, mapID = tonumber(mapX), tonumber(mapY), tonumber(mapID)
    if not mapX or not mapY or not mapID then return end
    local entry = minimapSourceEntries[key]
    local faction = Overlord.ManualBounty:GetTargetFaction(name)
    local changed = not entry or entry.name ~= name or entry.faction ~= faction
        or entry.mapX ~= mapX or entry.mapY ~= mapY or entry.mapID ~= mapID
    if not entry then
        if minimapSourceCount >= MINIMAP_SOURCE_MAX then
            local evictedKey = minimapSourceKeys[minimapSourceHead]
            if evictedKey then minimapSourceEntries[evictedKey] = nil end
            minimapSourceKeys[minimapSourceHead] = key
            minimapSourceHead = minimapSourceHead % MINIMAP_SOURCE_MAX + 1
        else
            local slot = (minimapSourceHead + minimapSourceCount - 1)
                % MINIMAP_SOURCE_MAX + 1
            minimapSourceKeys[slot] = key
            minimapSourceCount = minimapSourceCount + 1
        end
        entry = {}
        minimapSourceEntries[key] = entry
    end
    entry.name = name
    entry.faction = faction
    entry.mapX = mapX
    entry.mapY = mapY
    entry.mapID = mapID
    entry.receivedAt = GetTime()
    if changed then
        minimapBuildState.sourceVersion = minimapBuildState.sourceVersion + 1
    end
end

-- Le registre interne de ManualBounty est volontairement prive. Observer ses
-- applications acceptees permet a la minimap de maintenir une source iterable
-- par tranches, sans rappeler GetTargetPositions (scan jusqu'a 1024) dans un tick.
local originalApplyTargetPosition = Overlord.ManualBounty.ApplyTargetPosition
function Overlord.ManualBounty:ApplyTargetPosition(name, mapX, mapY, mapID, sentAt)
    local accepted = originalApplyTargetPosition(self, name, mapX, mapY, mapID, sentAt)
    if accepted then TrackMinimapSourcePosition(name, mapX, mapY, mapID) end
    return accepted
end

local function ResolveAtlas(faction)
    if faction == "Alliance" then return "Quest-Alliance-WaxSeal" end
    if faction == "Horde" then return "Quest-Horde-WaxSeal" end
    return nil
end

local function SafeSetPassThroughButtons(frame)
    if not frame or frame:IsForbidden() then return end
    if Overlord.MapMarkers and Overlord.MapMarkers.QueuePassThroughButtons then
        Overlord.MapMarkers:QueuePassThroughButtons(frame)
    end
end

local function ShowTooltip(entry)
    if not entry then return end
    local shortName = (entry.name or "?"):match("^(.-)%-") or entry.name
    GameTooltip:AddLine(string.format(L.MB_MAP_TOOLTIP, shortName), 1, 0.82, 0.2)
    GameTooltip:Show()
end

local function TransformCoords(srcMapID, mapX, mapY, targetMapID)
    if not srcMapID or not targetMapID or mapX == nil or mapY == nil then return nil, nil end
    if srcMapID == targetMapID then return mapX, mapY end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, srcMapID, targetMapID)
    if not ok or not minX or not maxX or not minY or not maxY
        or maxX <= minX or maxY <= minY then
        return nil, nil
    end
    return (minX + (maxX - minX) * mapX / 100) * 100,
        (minY + (maxY - minY) * mapY / 100) * 100
end

local function MapIDsMatch(entryMapID, viewedMapID)
    return Overlord.General and Overlord.General.MapIDsMatchForDisplay
        and Overlord.General.MapIDsMatchForDisplay(entryMapID, viewedMapID) or false
end

local function EnsureRoot(layer, parent, levelOffset)
    if not layer.root then
        layer.root = CreateFrame("Frame", nil, parent)
        layer.root:SetAllPoints(parent)
    elseif layer.root:GetParent() ~= parent then
        layer.root:SetParent(parent)
        layer.root:ClearAllPoints()
        layer.root:SetAllPoints(parent)
    end
    layer.root:SetFrameStrata(parent:GetFrameStrata())
    layer.root:SetFrameLevel((parent:GetFrameLevel() or 0) + levelOffset)
    return layer.root
end

local function SetLayerPinFree(layer, pin, shouldBeFree)
    local index = layer.freeIndex[pin]
    if shouldBeFree then
        if index then return end
        index = #layer.free + 1
        layer.free[index] = pin
        layer.freeIndex[pin] = index
        return
    end
    if not index then return end
    local lastIndex = #layer.free
    local lastPin = layer.free[lastIndex]
    layer.free[lastIndex] = nil
    layer.freeIndex[pin] = nil
    if index < lastIndex then
        layer.free[index] = lastPin
        layer.freeIndex[lastPin] = index
    end
end

local function TakeLayerPinFromFree(layer)
    local index = #layer.free
    if index == 0 then return nil end
    local pin = layer.free[index]
    layer.free[index] = nil
    layer.freeIndex[pin] = nil
    return pin
end

local function EnsureMapPin(layer, key, entry, parent, levelOffset)
    local atlas = ResolveAtlas(entry.faction)
    if not atlas then return nil end
    local root = EnsureRoot(layer, parent, levelOffset)
    local pin = layer.pins[key]
    if pin then
        SetLayerPinFree(layer, pin, false)
    else
        pin = TakeLayerPinFromFree(layer)
        if pin then
            if pin._key then layer.pins[pin._key] = nil end
        else
            pin = CreateFrame("Frame", nil, root)
            local icon = pin:CreateTexture(nil, "OVERLAY", nil, 3)
            icon:SetAllPoints()
            icon:SetAlpha(0.95)
            pin.icon = icon
            pin:EnableMouse(true)
            SafeSetPassThroughButtons(pin)
            pin:SetScript("OnEnter", function(self)
                if not self.entry then return end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                ShowTooltip(self.entry)
            end)
            pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
            layer.pool[#layer.pool + 1] = pin
        end
        pin._key = key
        layer.pins[key] = pin
    end
    if pin:GetParent() ~= root then
        pin:SetParent(root)
    end
    pin:SetFrameStrata(root:GetFrameStrata())
    pin:SetFrameLevel(root:GetFrameLevel() + 1)
    if pin._atlas ~= atlas then
        pin.icon:SetAtlas(atlas)
        pin._atlas = atlas
    end
    pin.entry = entry
    return pin
end

local function HideLayer(layer)
    if layer.root then layer.root:Hide() end
end

local function PlaceWorldPin(pin, canvas, parent, x, y, size)
    local mm = Overlord.MapMarkers
    if not mm or not x or not y then return false end
    local ox, oy = mm:GetWorldMapOverlayPoint(canvas, parent, x, y)
    if not ox or not oy then return false end
    return mm:PlaceWorldMapPin(pin, parent, ox, oy, size)
end

local RequestStaticMapBuild

local function CancelStaticMapBuild(state)
    state.token = state.token + 1
    state.pending = false
    state.committedMapID = nil
end

local function AbortStaticMapBuild(state)
    state.pending = false
    state.committedMapID = nil
    local root = state.buildLayer and state.buildLayer.root
    if root then root:Hide() end
end

local function AddStaticMapBuildRow(state, entry, key, mapX, mapY)
    if state.seen[key] then return end
    state.seen[key] = true
    state.selectedCount = state.selectedCount + 1
    local row = state.buffer[state.selectedCount] or {}
    row.entry, row.key = entry, key
    row.mapX, row.mapY = mapX, mapY
    state.buffer[state.selectedCount] = row
end

local function ProcessStaticMapBuildSlice(state, token)
    if token ~= state.token or not state.pending then return end
    local processed = 0
    if state.phase == "clear" then
        while processed < STATIC_MAP_REBUILD_BATCH do
            local ok, key = pcall(next, state.seen, state.seenCursor)
            if not ok then AbortStaticMapBuild(state); return end
            if state.pendingSeenDelete then
                state.seen[state.pendingSeenDelete] = nil
                state.pendingSeenDelete = nil
            end
            if key == nil then
                state.phase, state.cursorKey = "scan", nil
                C_Timer.After(0, function() ProcessStaticMapBuildSlice(state, token) end)
                return
            end
            state.seenCursor, state.pendingSeenDelete = key, key
            processed = processed + 1
        end
    elseif state.phase == "scan" then
        while processed < STATIC_MAP_REBUILD_BATCH do
            local ok, key, entry = pcall(next, state.source, state.cursorKey)
            if not ok then
                -- Une suppression de la cle courante entre deux frames invalide
                -- next(table, key) en Lua 5.1. Repartir du debut est borne et les
                -- lignes deja vues sont dedupliquees ; apres plusieurs rafales on
                -- publie quand meme la vue complete obtenue puis on la rattrape.
                state.sourceRestarts = (state.sourceRestarts or 0) + 1
                if state.sourceRestarts <= 8 then
                    state.cursorKey = nil
                else
                    -- Un parcours qui n'a jamais atteint `nil` n'est pas un
                    -- snapshot complet. Ne jamais remplacer la vue active par ce
                    -- buffer partiel (notamment au premier build sur un back-layer
                    -- vide) : conserver l'ancien root et retenter plus tard.
                    state.pending = false
                    if state.buildLayer.root then state.buildLayer.root:Hide() end
                    C_Timer.After(0.25, function()
                        if token ~= state.token or state.pending then return end
                        RequestStaticMapBuild(
                            state, state.canvas, state.parent, state.mapID)
                    end)
                    return
                end
                C_Timer.After(0, function() ProcessStaticMapBuildSlice(state, token) end)
                return
            end
            if key == nil then
                state.phase, state.pinCursor = "hide", nil
                local latestRevision = Overlord.ManualBounty:GetPositionRevision()
                state.preserveUnseen = latestRevision ~= state.revision
                C_Timer.After(0, function() ProcessStaticMapBuildSlice(state, token) end)
                return
            end
            state.cursorKey = key
            processed = processed + 1
            if entry and entry.name and entry.mapID and entry.mapX and entry.mapY
                and state.now - (entry.receivedAt or 0) <= state.staleSec
                and Overlord.ManualBounty:HasLocalClaimableContractForTarget(entry.name) then
                local mapX, mapY
                if state.kind == "world" then
                    if MapIDsMatch(entry.mapID, state.mapID) then
                        mapX, mapY = TransformCoords(
                            entry.mapID, entry.mapX, entry.mapY, state.mapID)
                    end
                else
                    mapX, mapY = TransformCoords(
                        entry.mapID, entry.mapX, entry.mapY, state.mapID)
                end
                local displayKey = PinKey(entry)
                if displayKey and mapX and mapY then
                    AddStaticMapBuildRow(state, entry, displayKey, mapX, mapY)
                end
            end
        end
    elseif state.phase == "hide" then
        while processed < STATIC_MAP_REBUILD_BATCH do
            local ok, key, pin = pcall(next, state.buildLayer.pins, state.pinCursor)
            if not ok then AbortStaticMapBuild(state); return end
            if key == nil then
                state.phase, state.placeIndex, state.anyShown = "place", 1, false
                C_Timer.After(0, function() ProcessStaticMapBuildSlice(state, token) end)
                return
            end
            state.pinCursor = key
            if not state.preserveUnseen and not state.seen[key] and pin then
                pin:Hide()
                SetLayerPinFree(state.buildLayer, pin, true)
            end
            processed = processed + 1
        end
    elseif state.phase == "place" then
        while processed < STATIC_MAP_REBUILD_BATCH
            and state.placeIndex <= state.selectedCount do
            local row = state.buffer[state.placeIndex]
            local entry, key = row and row.entry, row and row.key
            local pin = entry and key and EnsureMapPin(
                state.buildLayer, key, entry, state.parent,
                state.kind == "world" and 32 or 28)
            if state.buildLayer.root then state.buildLayer.root:Hide() end
            local shown = pin and PlaceWorldPin(
                pin, state.canvas, state.parent,
                row.mapX * state.width / 100,
                row.mapY * state.height / 100,
                state.iconSize)
            if shown then
                state.anyShown = true
            elseif pin then
                pin:Hide()
                SetLayerPinFree(state.buildLayer, pin, true)
            end
            state.placeIndex = state.placeIndex + 1
            processed = processed + 1
        end
        if state.placeIndex > state.selectedCount then
            local previousLayer, committedLayer = state.activeLayer, state.buildLayer
            local commitShown = state.anyShown
                or (state.preserveUnseen and committedLayer.anyShown)
            if previousLayer.root then previousLayer.root:Hide() end
            if committedLayer.root then
                if commitShown then committedLayer.root:Show() else committedLayer.root:Hide() end
            end
            committedLayer.anyShown = commitShown
            state.activeLayer, state.buildLayer = committedLayer, previousLayer
            state.pending = false
            state.committedMapID, state.committedRevision = state.mapID, state.revision
            state.committedCanvas, state.committedParent = state.canvas, state.parent
            state.committedWidth, state.committedHeight = state.width, state.height
            state.committedAnyShown = commitShown
            local latestRevision = Overlord.ManualBounty:GetPositionRevision()
            local needsFollowup = state.forceFollowup or state.preserveUnseen
                or latestRevision ~= state.revision
            state.forceFollowup, state.preserveUnseen = nil, nil
            if needsFollowup then
                state.committedRevision = nil
                C_Timer.After(0, function()
                    if token ~= state.token or state.pending then return end
                    RequestStaticMapBuild(
                        state, state.canvas, state.parent, state.mapID)
                end)
            end
            return
        end
    end
    C_Timer.After(0, function() ProcessStaticMapBuildSlice(state, token) end)
end

RequestStaticMapBuild = function(state, canvas, parent, mapID)
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    if not width or width == 0 or not height or height == 0 then return false end
    local source, revision = Overlord.ManualBounty:GetTargetPositionsSourceForSlicedRead()
    if type(source) ~= "table" then return false end
    local sameCommitted = not state.pending and state.committedMapID == mapID
        and state.committedRevision == revision and state.committedCanvas == canvas
        and state.committedParent == parent and state.committedWidth == width
        and state.committedHeight == height
    if sameCommitted then return true end
    local samePending = state.pending and state.mapID == mapID
        and state.canvas == canvas and state.parent == parent
        and state.width == width and state.height == height
    if samePending then
        state.followupRevision = revision
        return true
    end

    state.token = state.token + 1
    state.pending = true
    state.mapID, state.revision = mapID, revision
    state.canvas, state.parent = canvas, parent
    state.width, state.height = width, height
    state.iconSize = state.kind == "world"
        and math.max(WORLD_PIN_MIN, math.min(WORLD_PIN_MAX, width * WORLD_PIN_FRAC))
        or math.max(CONTINENT_PIN_MIN,
            math.min(CONTINENT_PIN_MAX, width * CONTINENT_PIN_FRAC))
    state.source = source
    if state.buildLayer.root then state.buildLayer.root:Hide() end
    state.now = GetTime()
    state.staleSec = Overlord.ManualBounty.POSITION_STALE_SEC
    state.selectedCount, state.sourceRestarts = 0, 0
    state.forceFollowup, state.preserveUnseen = nil, nil
    state.phase, state.seenCursor, state.pendingSeenDelete = "clear", nil, nil
    ProcessStaticMapBuildSlice(state, state.token)
    return true
end

function Overlord.ManualBountyMap:HideWorld()
    CancelStaticMapBuild(worldBuildState)
    HideLayer(worldBuildState.activeLayer)
    HideLayer(worldBuildState.buildLayer)
end

function Overlord.ManualBountyMap:HideContinent()
    CancelStaticMapBuild(continentBuildState)
    HideLayer(continentBuildState.activeLayer)
    HideLayer(continentBuildState.buildLayer)
end

function Overlord.ManualBountyMap:Refresh()
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
        self:HideWorld()
        return
    end
    local mm = Overlord.MapMarkers
    if not mm or not mm.WithWorldMapPinLayer then
        self:HideWorld()
        return
    end
    mm:WithWorldMapPinLayer(function(canvas, parent, mapID)
        local front = mapID and Overlord.Fronts and (
            Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
            or (Overlord.Fronts.ResolveFrontByMapID and Overlord.Fronts:ResolveFrontByMapID(mapID))
        )
        if not front then
            Overlord.ManualBountyMap:HideWorld()
            return
        end
        Overlord.ManualBountyMap:HideContinent()
        local width, height = canvas:GetWidth(), canvas:GetHeight()
        if not width or width == 0 or not height or height == 0 then
            Overlord.ManualBountyMap:HideWorld()
            return
        end
        if not RequestStaticMapBuild(worldBuildState, canvas, parent, mapID) then
            Overlord.ManualBountyMap:HideWorld()
        end
    end)
end

local function RefreshContinentWithLayer(canvas, parent, mapID)
    local mm = Overlord.MapMarkers
    local isContinent = mapID and (
        (mm.IsEKMap and mm:IsEKMap(mapID))
        or (mm.IsKalimdorMap and mm:IsKalimdorMap(mapID))
    )
    if not isContinent then
        Overlord.ManualBountyMap:HideContinent()
        return
    end
    Overlord.ManualBountyMap:HideWorld()
    if not RequestStaticMapBuild(continentBuildState, canvas, parent, mapID) then
        Overlord.ManualBountyMap:HideContinent()
    end
end

function Overlord.ManualBountyMap:RefreshContinent()
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
        self:HideContinent()
        return
    end
    local mm = Overlord.MapMarkers
    if not mm or not mm.WithWorldMapPinLayer then
        self:HideContinent()
        return
    end
    mm:WithWorldMapPinLayer(RefreshContinentWithLayer)
end

local function EnsureMinimapPin(key)
    local pin = minimapPins[key]
    if pin then return pin end
    for i = 1, #minimapPool do
        local pooled = minimapPool[i]
        if pooled and not pooled:IsShown() then
            pin = pooled
            break
        end
    end
    if pin then
        if pin._key then minimapPins[pin._key] = nil end
    else
        pin = CreateFrame("Frame", nil, Minimap)
        pin:SetFrameStrata("MEDIUM")
        pin:SetFrameLevel(8)
        local icon = pin:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("CENTER")
        icon:SetAlpha(0.95)
        pin.icon = icon
        pin:EnableMouse(true)
        SafeSetPassThroughButtons(pin)
        pin:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            ShowTooltip(self.entry)
        end)
        pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
        local mask = pin:CreateMaskTexture()
        mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall",
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetPoint("TOPLEFT", Minimap, "TOPLEFT")
        mask:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT")
        icon:AddMaskTexture(mask)
        pin:Hide()
        minimapPool[#minimapPool + 1] = pin
    end
    pin._key = key
    minimapPins[key] = pin
    return pin
end

function Overlord.ManualBountyMap:HideMinimapPins()
    for _, pin in pairs(minimapPins) do
        pin:Hide()
    end
end

local function ConsiderMinimapBuildCandidate(entry, key, mapX, mapY, distanceSq)
    local state = minimapBuildState
    local slot
    if state.selectedCount < MINIMAP_ACTIVE_PIN_MAX then
        state.selectedCount = state.selectedCount + 1
        slot = state.selectedCount
    else
        local farthestSlot = 1
        local farthest = minimapBuildEntries[1]
            and minimapBuildEntries[1].distanceSq or -1
        for candidateSlot = 2, MINIMAP_ACTIVE_PIN_MAX do
            local candidate = minimapBuildEntries[candidateSlot]
            local candidateDistance = candidate and candidate.distanceSq or -1
            local candidateKey = candidate and candidate.key or ""
            local farthestKey = minimapBuildEntries[farthestSlot]
                and minimapBuildEntries[farthestSlot].key or ""
            if candidateDistance > farthest
                or (candidateDistance == farthest and candidateKey > farthestKey) then
                farthest = candidateDistance
                farthestSlot = candidateSlot
            end
        end
        local farthestEntry = minimapBuildEntries[farthestSlot]
        if distanceSq < farthest
            or (distanceSq == farthest and farthestEntry
                and key < (farthestEntry.key or key)) then
            slot = farthestSlot
        end
    end
    if not slot then return end
    local cached = minimapBuildEntries[slot] or {}
    cached.entry, cached.key = entry, key
    cached.mapX, cached.mapY = mapX, mapY
    cached.distanceSq = distanceSq
    minimapBuildEntries[slot] = cached
end

local function ProcessMinimapSelectionSlice(token)
    local state = minimapBuildState
    if token ~= state.token then
        state.running = false
        return
    end
    if Overlord.InstanceSuspended then
        state.running = false
        return
    end
    local processed = 0
    while processed < MINIMAP_REBUILD_BATCH
        and state.cursorOffset < state.sourceCount do
        local slot = (state.sourceHead + state.cursorOffset - 1)
            % MINIMAP_SOURCE_MAX + 1
        state.cursorOffset = state.cursorOffset + 1
        processed = processed + 1
        local key = minimapSourceKeys[slot]
        local entry = key and minimapSourceEntries[key]
        if entry and state.now - (entry.receivedAt or 0)
                <= Overlord.ManualBounty.POSITION_STALE_SEC
            and Overlord.ManualBounty:HasLocalClaimableContractForTarget(entry.name) then
            local mapX, mapY = TransformCoords(
                entry.mapID, entry.mapX, entry.mapY, state.mapID)
            if mapX and mapY then
                local dx = (mapX - state.anchorX) * state.yppX
                local dy = (mapY - state.anchorY) * state.yppY
                ConsiderMinimapBuildCandidate(
                    entry, key, mapX, mapY, dx * dx + dy * dy)
            end
        end
    end
    if state.cursorOffset < state.sourceCount then
        C_Timer.After(0, function()
            ProcessMinimapSelectionSlice(token)
        end)
        return
    end
    if token ~= state.token then
        state.running = false
        return
    end
    local previous = minimapCacheEntries
    minimapCacheEntries = minimapBuildEntries
    minimapBuildEntries = previous
    minimapCacheMapID = state.mapID
    minimapCacheRevision = state.revision
    minimapSelectionAnchorX = state.anchorX
    minimapSelectionAnchorY = state.anchorY
    state.committedSourceVersion = state.buildSourceVersion
    state.running = false
    minimapSelectionCommitted = true
    if state.forceFollowup or state.sourceVersion ~= state.buildSourceVersion then
        -- Toujours publier la selection complete obtenue. Le tick minimap suivant
        -- voit ces sentinelles et lance une seule generation de rattrapage, meme si
        -- des PM de position ont continue a arriver pendant les N/16 tranches.
        minimapCacheRevision = nil
        state.committedSourceVersion = nil
    end
    state.forceFollowup = nil
end

local function RequestMinimapSelectionBuild(ctx, revision, force)
    local state = minimapBuildState
    if state.running then
        local sameSpatial = state.mapID == ctx.mapID
        if sameSpatial and state.anchorX and state.anchorY then
            local movedX = (ctx.px - state.anchorX) * ctx.yppX
            local movedY = (ctx.py - state.anchorY) * ctx.yppY
            sameSpatial = movedX * movedX + movedY * movedY
                < MINIMAP_RESELECT_DISTANCE_YARDS * MINIMAP_RESELECT_DISTANCE_YARDS
        end
        if sameSpatial then
            state.requestedRevision = revision
            state.requestedSourceVersion = state.sourceVersion
            if force then state.forceFollowup = true end
            return
        end
        state.token = state.token + 1
        state.running = false
    end
    local sameRequest = not force and state.requestedMapID == ctx.mapID
        and state.requestedRevision == revision
        and state.requestedSourceVersion == state.sourceVersion
    if sameRequest and state.requestedAnchorX and state.requestedAnchorY then
        local movedX = (ctx.px - state.requestedAnchorX) * ctx.yppX
        local movedY = (ctx.py - state.requestedAnchorY) * ctx.yppY
        sameRequest = movedX * movedX + movedY * movedY
            < MINIMAP_RESELECT_DISTANCE_YARDS * MINIMAP_RESELECT_DISTANCE_YARDS
    end
    if sameRequest then return end

    state.token = state.token + 1
    state.requestedMapID = ctx.mapID
    state.requestedRevision = revision
    state.requestedSourceVersion = state.sourceVersion
    state.requestedAnchorX = ctx.px
    state.requestedAnchorY = ctx.py
    state.requestedYppX = ctx.yppX
    state.requestedYppY = ctx.yppY
    if state.scheduled then return end
    state.scheduled = true
    C_Timer.After(0, function()
        state.scheduled = false
        local token = state.token
        state.running = true
        state.mapID = state.requestedMapID
        state.revision = state.requestedRevision
        state.buildSourceVersion = state.requestedSourceVersion
        state.anchorX = state.requestedAnchorX
        state.anchorY = state.requestedAnchorY
        state.yppX = state.requestedYppX
        state.yppY = state.requestedYppY
        state.sourceHead = minimapSourceHead
        state.sourceCount = minimapSourceCount
        state.cursorOffset = 0
        state.selectedCount = 0
        state.now = GetTime()
        wipe(minimapBuildEntries)
        ProcessMinimapSelectionSlice(token)
    end)
end

local function UpdateMinimapWithContext(ctx, dataRefresh)
    if not ctx.mapID then
        Overlord.ManualBountyMap:HideMinimapPins()
        return
    end
    local revision = Overlord.ManualBounty:GetPositionRevision()
    local cacheChanged = minimapCacheMapID ~= ctx.mapID or minimapCacheRevision ~= revision
        or minimapBuildState.committedSourceVersion ~= minimapBuildState.sourceVersion
    local selectionMoved = false
    if not cacheChanged and minimapSelectionAnchorX and minimapSelectionAnchorY then
        local movedX = (ctx.px - minimapSelectionAnchorX) * ctx.yppX
        local movedY = (ctx.py - minimapSelectionAnchorY) * ctx.yppY
        selectionMoved = movedX * movedX + movedY * movedY
            >= MINIMAP_RESELECT_DISTANCE_YARDS * MINIMAP_RESELECT_DISTANCE_YARDS
    end
    if cacheChanged or selectionMoved then
        RequestMinimapSelectionBuild(ctx, revision)
    end
    local reconcile = minimapSelectionCommitted
    minimapSelectionCommitted = false
    if reconcile then
        wipe(minimapSeen)
        -- Liberer d'abord les anciens pins afin que la nouvelle selection bornee
        -- reutilise le pool au lieu de le faire grossir lors d'un changement complet.
        for _, pin in pairs(minimapPins) do pin:Hide() end
    end
    local now = GetTime()
    local staleSec = Overlord.ManualBounty.POSITION_STALE_SEC
    local selectionExpired = false
    local activeCount = math.min(#minimapCacheEntries, MINIMAP_ACTIVE_PIN_MAX)
    for i = 1, activeCount do
        local cached = minimapCacheEntries[i]
        local entry = cached.entry
        local key = cached.key
        if now - (entry.receivedAt or 0) <= staleSec then
            if reconcile then minimapSeen[key] = true end
            local dx = (cached.mapX - ctx.px) * ctx.yppX
            local dy = (cached.mapY - ctx.py) * ctx.yppY
            local pinX = dx * ctx.pxPerYard
            local pinY = -dy * ctx.pxPerYard
            if ctx.rotateMM and ctx.sinF and ctx.cosF then
                pinX, pinY = pinX * ctx.cosF - pinY * ctx.sinF,
                    pinX * ctx.sinF + pinY * ctx.cosF
            end
            local avgYPP = (ctx.yppX + ctx.yppY) / 2
            local size = math.max(MINIMAP_PIN_MIN,
                math.min(MINIMAP_PIN_MAX, avgYPP * 1.1 * ctx.pxPerYard))
            local pin = minimapPins[key]
            if reconcile and not pin then pin = EnsureMinimapPin(key) end
            if pin then
                local visibleRadius = ctx.halfMM + size / 2
                if pinX * pinX + pinY * pinY <= visibleRadius * visibleRadius then
                    local atlas = ResolveAtlas(entry.faction)
                    if atlas and pin._atlas ~= atlas then
                        pin.icon:SetAtlas(atlas)
                        pin._atlas = atlas
                    end
                    local snappedX = math.floor(pinX * 2 + 0.5) / 2
                    local snappedY = math.floor(pinY * 2 + 0.5) / 2
                    local snappedSize = math.floor(size + 0.5)
                    if pin._size ~= snappedSize then
                        pin:SetSize(snappedSize, snappedSize)
                        pin.icon:SetSize(snappedSize, snappedSize)
                        pin._size = snappedSize
                    end
                    if pin._mapX ~= snappedX or pin._mapY ~= snappedY then
                        pin:ClearAllPoints()
                        pin:SetPoint("CENTER", Minimap, "CENTER", snappedX, snappedY)
                        pin._mapX = snappedX
                        pin._mapY = snappedY
                    end
                    pin.entry = entry
                    pin:Show()
                else
                    pin:Hide()
                end
            end
        elseif dataRefresh then
            local stalePin = minimapPins[key]
            if stalePin and stalePin:IsShown() then stalePin:Hide() end
            selectionExpired = true
        end
    end
    if selectionExpired then
        -- La 25e cible peut encore etre fraiche : reconstruire le nearest-N afin
        -- qu'une selection expiree ne laisse pas durablement un trou visible.
        RequestMinimapSelectionBuild(ctx, revision, true)
    end
    if reconcile then
        for key, pin in pairs(minimapPins) do
            if not minimapSeen[key] then pin:Hide() end
        end
    end
end

function Overlord.ManualBountyMap:UpdateMinimapPins(context, dataRefresh)
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then
        self:HideMinimapPins()
        return
    end
    if not context then
        self:HideMinimapPins()
        return
    end
    UpdateMinimapWithContext(context, dataRefresh)
end

function Overlord.ManualBountyMap:Hide()
    self:HideWorld()
    self:HideContinent()
    self:HideMinimapPins()
end
