-- Outpost.lua - Avant-postes guilde en monde ouvert (copie fortin, 24/7)
Overlord = Overlord or {}
Overlord.Outpost = Overlord.Outpost or {}

local L = Overlord.L
local OUTPOST_HOLD_SECONDS = 86400
local OUTPOST_CAPTURE_SECONDS = 300
local OUTPOST_ZONE_CAPTURE_PENALTY_SECONDS = 30
Overlord.Outpost.DEFAULT_HOLD_TIME_REQUIRED = OUTPOST_CAPTURE_SECONDS
Overlord.Outpost.ZONE_CAPTURE_PENALTY_SECONDS = OUTPOST_ZONE_CAPTURE_PENALTY_SECONDS
Overlord.Outpost.NEUTRAL_ATLAS = "Warfronts-BaseMapIcons-Empty-Tower"
local OUTPOST_NEUTRAL_ATLAS = Overlord.Outpost.NEUTRAL_ATLAS
local OUTPOST_OBSERVER_STALE_BUFFER = 30
local observerStalePresentation = {}
local strategicSiteKeyByZoneId = {}

local function sanitizeGuildName(name)
    if type(name) ~= "string" or name == "" then return "" end
    name = (name:gsub("[|=:,]", ""):match("^%s*(.-)%s*$") or "")
    if name == "" then return "" end
    if utf8 and utf8.len and utf8.offset and utf8.len(name) > 24 then
        local cut = utf8.offset(name, 25)
        if cut then name = name:sub(1, cut - 1) end
    elseif #name > 24 then
        name = name:sub(1, 24)
    end
    return name
end

local function normalizeOutpostPoolTag(pool)
    if type(pool) ~= "string" or pool == "" then return "" end
    pool = pool:lower()
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    return ""
end

local function currentOutpostPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return normalizeOutpostPoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

-- Un avant-poste par front Forever, plus les sites autonomes en monde ouvert.
Overlord.OutpostSites = {
    silverpine = {
        id = "silverpine_outpost",
        siteKey = "silverpine",
        displayNameKey = "OUTPOST_SILVERPINE_NAME",
        standaloneOpenWorld = true,
        mapID = 1421,
        mapIDs = { [21] = true, [1421] = true },
        displayMapIDs = { [21] = true, [1421] = true },
        includeChildMaps = false,
        mapNameNeedles = { "silverpine", "pins-argent", "silberwald", "argenteos" },
        center = { 61.8, 64.4 },
        halfSize = 1.35,
    },
    arathi = {
        id = "arathi_outpost",
        siteKey = "arathi",
        displayNameKey = "OUTPOST_ARATHI_NAME",
        frontId = "arathi",
        mapID = 1417,
        mapIDs = { [14] = true, [1417] = true },
        mapNameNeedles = { "arathi" },
        -- Tour du Sage : terre, hors cercles Stromgarde / High Perch / Argorok.
        center = { 33.3, 27.8 },
        halfSize = 1.35,
    },
    loch_modan = {
        id = "loch_modan_outpost",
        siteKey = "loch_modan",
        displayNameKey = "OUTPOST_LOCH_MODAN_NAME",
        frontId = "loch_modan",
        mapID = 1432,
        mapIDs = { [48] = true, [1432] = true },
        mapNameNeedles = { "loch modan", "loch" },
        -- Retraite de Katrell : emplacement Retail restaure sur demande.
        center = { 40.3, 39.4 },
        halfSize = 1.35,
    },
    durotar = {
        id = "durotar_outpost",
        siteKey = "durotar",
        displayNameKey = "OUTPOST_DUROTAR_NAME",
        frontId = "durotar",
        mapID = 1411,
        mapIDs = { [1] = true, [1411] = true },
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = { "durotar" },
        -- Ferme des Tranchegroins : ouest de Tranchecolline, pas dans la Furie-du-Sud.
        center = { 47.8, 49.6 },
        halfSize = 1.35,
    },
    ashenvale = {
        id = "ashenvale_outpost",
        siteKey = "ashenvale",
        displayNameKey = "OUTPOST_ASHENVALE_NAME",
        frontId = "ashenvale",
        mapID = 1440,
        mapIDs = { [63] = true, [1440] = true },
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = { "ashenvale", "orneval", "vallefresno", "eschental" },
        -- Ruines d'Ordil'Aran (terre), pas le liseré nord / Strand de Zoram.
        center = { 29.0, 32.0 },
        halfSize = 1.35,
    },
}

local siteByKey = {}
local sitesByFront = {}
local standaloneSites = {}
local standaloneSiteByDisplayMapID = {}
local initializedOutpostDb = nil
local initializedOutpostRows = nil

local function outpostSiteMatchesMapID(site, mapID)
    if not site or not mapID then return false end
    if site.mapID == mapID then return true end
    if site.mapIDs and site.mapIDs[mapID] then return true end
    return false
end

local function mapDescendsFrom(mapID, ancestorMapID)
    mapID = tonumber(mapID)
    ancestorMapID = tonumber(ancestorMapID)
    if not mapID or not ancestorMapID then return false end
    local seen = {}
    while mapID > 0 and not seen[mapID] do
        if mapID == ancestorMapID then return true end
        seen[mapID] = true
        if not C_Map or not C_Map.GetMapInfo then break end
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if not ok or not info then break end
        mapID = tonumber(info.parentMapID) or 0
    end
    return false
end

local function standaloneSiteMatchesPlayerMap(site, mapID)
    if not site or not site.standaloneOpenWorld then return false end
    if outpostSiteMatchesMapID(site, mapID) then return true end
    if site.includeChildMaps == false then return false end
    return mapDescendsFrom(mapID, site.mapID)
end

local function standaloneSiteMatchesDisplayMap(site, mapID)
    if standaloneSiteMatchesPlayerMap(site, mapID) then return true end
    return site and site.displayMapIDs and site.displayMapIDs[mapID] == true
end

for key, site in pairs(Overlord.OutpostSites) do
    site.siteKey = site.siteKey or key
    siteByKey[key] = site
    if site.frontId then
        sitesByFront[site.frontId] = sitesByFront[site.frontId] or {}
        sitesByFront[site.frontId][key] = site
    end
    if site.standaloneOpenWorld then
        standaloneSites[key] = site
        for displayMapID in pairs(site.displayMapIDs or {}) do
            standaloneSiteByDisplayMapID[displayMapID] = site
        end
    end
end

local function defaultState()
    return {
        status = "neutral",
        ownerGuild = "",
        ownerFaction = nil,
        claimedAt = 0,
        expiresAt = 0,
        holdTimeElapsed = 0,
        updatedAt = 0,
        holdTimeRequired = OUTPOST_CAPTURE_SECONDS,
        isHolding = false,
        isPaused = false,
        isContested = false,
        holdAuthorityLocal = false,
        holdStartTime = nil,
        previousOwnerGuild = "",
        previousOwnerFaction = nil,
        previousClaimedAt = 0,
        previousExpiresAt = 0,
        previousOwnerPool = "",
        opRelayCapturerName = nil,
        opRelayCapturerShard = nil,
        opOfficialCapturerName = nil,
        pool = "",
    }
end

local function sanitizeOutpostState(st, site)
    if not st then return end
    st.ownerGuild = sanitizeGuildName(st.ownerGuild or "")
    st.previousOwnerGuild = sanitizeGuildName(st.previousOwnerGuild or "")
    if Overlord.Outpost.NormalizeHoldTimeRequired then
        st.holdTimeRequired = Overlord.Outpost:NormalizeHoldTimeRequired(
            st.holdTimeRequired, site)
    end
end

function Overlord.Outpost:ClearOpCapturerFields(st)
    if not st then return end
    st.opOfficialCapturerName = nil
    st.opRelayCapturerName = nil
    st.opRelayCapturerShard = nil
end

-- Nom capteur affiche (alertes, popup shard) : capteur local ou dernier relais OP.
function Overlord.Outpost:GetEffectiveCapturerName(st)
    if not st then return "" end
    if st.holdAuthorityLocal and st.isHolding and st.ownerFaction == Overlord.PlayerFaction then
        if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
            return Overlord.Sync:GetPlayerFullName() or ""
        end
    end
    local official = st.opOfficialCapturerName
    if official and type(official) == "string" then
        local t = official:match("^%s*(.-)%s*$") or ""
        if t ~= "" and #t >= 2 and #t <= 50 then return t end
    end
    local relay = st.opRelayCapturerName
    if relay and type(relay) == "string" then
        local t = relay:match("^%s*(.-)%s*$") or ""
        if t ~= "" and #t >= 2 and #t <= 50 then return t end
    end
    return ""
end

function Overlord.Outpost:GetEffectiveCapturerShard(st)
    if not st then return nil end
    local sid = tonumber(st.opRelayCapturerShard)
    if sid then return sid end
    local name = self:GetEffectiveCapturerName(st)
    if name ~= "" and Overlord.Shard and Overlord.Shard.ResolveKnownShardPlayer then
        local _, resolvedSid = Overlord.Shard:ResolveKnownShardPlayer(name, true)
        return tonumber(resolvedSid)
    end
    return nil
end

function Overlord.Outpost:GetSite(siteKey)
    return siteByKey[siteKey]
end

function Overlord.Outpost:GetSitesForFront(frontId)
    return sitesByFront[frontId] or {}
end

function Overlord.Outpost:IsStandaloneOpenWorldSite(site)
    return site and site.standaloneOpenWorld == true
end

function Overlord.Outpost:IsStandaloneOpenWorldDisplayMap(mapID)
    if not mapID then return false end
    if standaloneSiteByDisplayMapID[mapID] then return true end
    for _, site in pairs(standaloneSites) do
        if standaloneSiteMatchesDisplayMap(site, mapID) then return true end
    end
    return false
end

function Overlord.Outpost:GetSitesOnMap(mapID, frontId)
    local list = {}
    if not mapID then return list end
    for _, site in pairs(standaloneSites) do
        if standaloneSiteMatchesDisplayMap(site, mapID) then
            list[#list + 1] = site
        end
    end
    if not Overlord.Fronts then return list end
    -- Carte affichee = overlay Zone du front OU toute carte de la hierarchie (comme la minimap).
    local front = Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
        or Overlord.Fronts:ResolveFrontByMapID(mapID)
    if not front then return list end
    if frontId and front.id ~= frontId then return list end
    for _, site in pairs(self:GetSitesForFront(front.id)) do
        list[#list + 1] = site
    end
    return list
end

function Overlord.Outpost:ResolveSiteByMapID(mapID)
    if not mapID then return nil end
    for _, site in pairs(standaloneSites) do
        if standaloneSiteMatchesPlayerMap(site, mapID) then return site end
    end
    if not Overlord.Fronts then return nil end
    local frontId = Overlord.Fronts.activeFrontId
    if not frontId then return nil end
    local bucket = sitesByFront[frontId]
    if not bucket then return nil end
    local resolvedFront = Overlord.Fronts:ResolveFrontByMapID(mapID)
    if not resolvedFront or resolvedFront.id ~= frontId then return nil end
    for _, site in pairs(bucket) do
        if outpostSiteMatchesMapID(site, mapID) then
            return site
        end
    end
    for _, site in pairs(bucket) do
        return site
    end
    return nil
end

function Overlord.Outpost:IsGameplayContextActive(site)
    if not site or Overlord.InstanceSuspended then return false end
    if IsInInstance and IsInInstance() then return false end
    if GetInstanceInfo then
        local ok, _, instanceType = pcall(GetInstanceInfo)
        if ok and instanceType and instanceType ~= "none" and instanceType ~= "" then
            return false
        end
    end
    if site.standaloneOpenWorld then
        if Overlord.IsInCatchUpPhase and Overlord:IsInCatchUpPhase(true) then return false end
        local mapID = self:GetPlayerMapID()
        return mapID and standaloneSiteMatchesPlayerMap(site, mapID) or false
    end
    return Overlord.InActiveFront == true
end

function Overlord.Outpost:GetPlayerMapID()
    if Overlord.InstanceSuspended then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if ok and mapID then return mapID end
    return nil
end

-- Meme micro-fenetre que les fortins : deux GetTime() successifs ne sont pas
-- garantis identiques, meme dans un seul tick de capture.
local OUTPOST_SPATIAL_SAMPLE_CACHE_SEC = 0.05

local function GetOutpostSpatialCacheContext()
    local shard = Overlord.Shard
    return tostring(shard and shard.localContextKey or ""),
        tonumber(shard and shard.localContextStartedAt) or 0,
        Overlord.InActiveFront == true,
        Overlord.InstanceSuspended == true
end

local onOutpostMapCache = {
    at = -1, contextKey = "", contextAt = -1, frontActive = false,
    suspended = false, onMap = false, site = nil,
}

function Overlord.Outpost:IsPlayerOnOutpostMap()
    local now = GetTime()
    local contextKey, contextAt, frontActive, suspended = GetOutpostSpatialCacheContext()
    local cacheAge = now - onOutpostMapCache.at
    if cacheAge >= 0 and cacheAge <= OUTPOST_SPATIAL_SAMPLE_CACHE_SEC
        and onOutpostMapCache.contextKey == contextKey
        and onOutpostMapCache.contextAt == contextAt
        and onOutpostMapCache.frontActive == frontActive
        and onOutpostMapCache.suspended == suspended then
        return onOutpostMapCache.onMap, onOutpostMapCache.site
    end
    if Overlord.InstanceSuspended then
        onOutpostMapCache.at = now
        onOutpostMapCache.contextKey = contextKey
        onOutpostMapCache.contextAt = contextAt
        onOutpostMapCache.frontActive = frontActive
        onOutpostMapCache.suspended = suspended
        onOutpostMapCache.onMap = false
        onOutpostMapCache.site = nil
        return false, nil
    end
    local mapID = self:GetPlayerMapID()
    if not mapID then
        onOutpostMapCache.at = now
        onOutpostMapCache.contextKey = contextKey
        onOutpostMapCache.contextAt = contextAt
        onOutpostMapCache.frontActive = frontActive
        onOutpostMapCache.suspended = suspended
        onOutpostMapCache.onMap = false
        onOutpostMapCache.site = nil
        return false, nil
    end
    local site = self:ResolveSiteByMapID(mapID)
    if site and not self:IsGameplayContextActive(site) then site = nil end
    onOutpostMapCache.at = now
    onOutpostMapCache.contextKey = contextKey
    onOutpostMapCache.contextAt = contextAt
    onOutpostMapCache.frontActive = frontActive
    onOutpostMapCache.suspended = suspended
    onOutpostMapCache.onMap = site ~= nil
    onOutpostMapCache.site = site
    return site ~= nil, site
end

function Overlord.Outpost:IsOutpostSiteDisplayMap(mapID, site)
    if not site or not mapID then return false end
    if site.standaloneOpenWorld then
        return standaloneSiteMatchesDisplayMap(site, mapID)
    end
    if outpostSiteMatchesMapID(site, mapID) then return true end
    if Overlord.Fronts and site.frontId then
        local front = Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
        return front and front.id == site.frontId
    end
    return false
end

local keepMapAspectRatio = {}
local function GetMapAspectRatio(mapID)
    if not mapID then return 1 end
    if keepMapAspectRatio[mapID] then return keepMapAspectRatio[mapID] end
    local ratio = 1
    pcall(function()
        if not C_Map or not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return end
        local _, w0 = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local _, wX = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 0))
        local _, wY = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 1))
        if w0 and wX and wY then
            local dX = math.sqrt((wX.x - w0.x) ^ 2 + (wX.y - w0.y) ^ 2)
            local dY = math.sqrt((wY.x - w0.x) ^ 2 + (wY.y - w0.y) ^ 2)
            if dX > 0 and dY > 0 then ratio = dY / dX end
        end
    end)
    keepMapAspectRatio[mapID] = ratio
    return ratio
end

function Overlord.Outpost:GetMapAspectRatio(siteOrMapID)
    local mapID = type(siteOrMapID) == "table" and siteOrMapID.mapID or siteOrMapID
    return GetMapAspectRatio(mapID)
end

function Overlord.Outpost:GetOutpostSquares(site)
    if not site or not site.center then return {} end
    local cx, cy = site.center[1], site.center[2]
    local hs = site.halfSize or 1.35
    local cached = site._outpostSquaresCache
    local square = cached and cached[1]
    if square and square[1] == cx and square[2] == cy and square[3] == hs then
        return cached
    end
    cached = { { cx, cy, hs } }
    site._outpostSquaresCache = cached
    return cached
end

local function pointInSquare(px, py, cx, cy, halfSize, ar)
    local dx = math.abs(px - cx)
    local dy = math.abs((py - cy) * ar)
    return dx <= halfSize and dy <= halfSize
end

function Overlord.Outpost:GetGeometryMapID(site)
    if not site then return nil end
    if Overlord.Fronts and site.frontId then
        local frontMapID = Overlord.Fronts:GetMapID(site.frontId)
        if frontMapID then return frontMapID end
    end
    return site.mapID
end

-- Micro-cache partage par Update, CheckPosition, HUD et scan.
local outpostGeomCache = {
    at = -1, contextKey = "", contextAt = -1, frontActive = false,
    suspended = false, siteKey = nil, result = false,
}

function Overlord.Outpost:IsPlayerInOutpostGeometry(site)
    if not site or not site.center then return false end
    local siteKey = site.siteKey or site.id
    local now = GetTime()
    local contextKey, contextAt, frontActive, suspended = GetOutpostSpatialCacheContext()
    local cacheAge = now - outpostGeomCache.at
    if cacheAge >= 0 and cacheAge <= OUTPOST_SPATIAL_SAMPLE_CACHE_SEC
        and outpostGeomCache.contextKey == contextKey
        and outpostGeomCache.contextAt == contextAt
        and outpostGeomCache.frontActive == frontActive
        and outpostGeomCache.suspended == suspended
        and outpostGeomCache.siteKey == siteKey then
        return outpostGeomCache.result
    end
    local onMap, resolvedSite = self:IsPlayerOnOutpostMap()
    if not onMap then
        outpostGeomCache.at = now
        outpostGeomCache.contextKey = contextKey
        outpostGeomCache.contextAt = contextAt
        outpostGeomCache.frontActive = frontActive
        outpostGeomCache.suspended = suspended
        outpostGeomCache.siteKey = siteKey
        outpostGeomCache.result = false
        return false
    end
    local resolvedKey = resolvedSite and (resolvedSite.siteKey or resolvedSite.id)
    if resolvedKey and siteKey and resolvedKey ~= siteKey then
        outpostGeomCache.at = now
        outpostGeomCache.contextKey = contextKey
        outpostGeomCache.contextAt = contextAt
        outpostGeomCache.frontActive = frontActive
        outpostGeomCache.suspended = suspended
        outpostGeomCache.siteKey = siteKey
        outpostGeomCache.result = false
        return false
    end
    site = resolvedSite or site
    local result = false
    local mapID = self:GetGeometryMapID(site)
    if mapID then
        local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
        if ok2 and pos then
            local ok3, px, py = pcall(pos.GetXY, pos)
            if ok3 and px then
                px, py = px * 100, py * 100
                local ar = GetMapAspectRatio(mapID)
                for _, sq in ipairs(self:GetOutpostSquares(site)) do
                    if pointInSquare(px, py, sq[1], sq[2], sq[3], ar) then
                        result = true
                        break
                    end
                end
            end
        end
    end
    outpostGeomCache.at = now
    outpostGeomCache.contextKey = contextKey
    outpostGeomCache.contextAt = contextAt
    outpostGeomCache.frontActive = frontActive
    outpostGeomCache.suspended = suspended
    outpostGeomCache.siteKey = siteKey
    outpostGeomCache.result = result
    return result
end

function Overlord.Outpost:EnsureDB()
    OverlordDB = OverlordDB or {}
    if type(OverlordDB.outposts) ~= "table" then OverlordDB.outposts = {} end
    if initializedOutpostDb == OverlordDB
        and initializedOutpostRows == OverlordDB.outposts then return end
    for key in pairs(Overlord.OutpostSites) do
        local st = OverlordDB.outposts[key]
        if type(st) ~= "table" then
            st = defaultState()
            OverlordDB.outposts[key] = st
        end
        -- Frontiere SavedVariables : sanitation unique par identite de DB. Les
        -- mutations live passent deja par les normaliseurs Outpost/SyncOutpost.
        sanitizeOutpostState(st, siteByKey[key])
    end
    initializedOutpostDb = OverlordDB
    initializedOutpostRows = OverlordDB.outposts
end

function Overlord.Outpost:GetState(siteKey)
    self:EnsureDB()
    local st = OverlordDB.outposts[siteKey]
    if not st then
        st = defaultState()
        OverlordDB.outposts[siteKey] = st
    end
    return st
end

function Overlord.Outpost:MarkDirty()
    -- Un heartbeat OP modifie l'etat territorial, pas le classement. Le brancher sur
    -- Leaderboard:MarkDirty invalidait le tri, CharacterStats et le snapshot top-150
    -- toutes les cinq secondes pendant une capture. Les vraies mutations LO/LOC/OC
    -- se marquent deja dans leurs methodes Leaderboard respectives.
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

function Overlord.Outpost:SaveOutposts()
    self:EnsureDB()
    -- Autosave differee (MarkDirty + ticker 30 s) : evite SaveState() complet a chaque OP recu.
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

function Overlord.Outpost:GetBaseHoldTimeRequired(site)
    return math.max(1, math.floor(tonumber(site and site.holdTimeRequired)
        or OUTPOST_CAPTURE_SECONDS))
end

function Overlord.Outpost:GetMinimumHoldTimeRequired(site)
    local base = self:GetBaseHoldTimeRequired(site)
    local constants = Overlord.RessourcesConstants or {}
    local reduction = math.max(0, tonumber(constants.REINFORCE_REDUCTION) or 60)
    local minimum = math.max(1, tonumber(constants.REINFORCE_MIN_HOLD) or 30)
    return math.max(minimum, base - reduction)
end

-- Le reseau ne peut choisir qu'entre le contrat canonique et sa variante -60 s.
-- Toute autre duree retombe sur la valeur canonique (anti-spoof / SavedVariables).
function Overlord.Outpost:NormalizeHoldTimeRequired(value, site)
    local base = self:GetBaseHoldTimeRequired(site)
    local reduced = self:GetMinimumHoldTimeRequired(site)
    value = tonumber(value)
    if value and value == math.floor(value) and value == reduced then return reduced end
    return base
end

function Overlord.Outpost:GetDefaultHoldTimeRequired(st, site)
    return self:NormalizeHoldTimeRequired(st and st.holdTimeRequired, site)
end

-- L'assaut peut commencer des la prise precedente. Sa finale doit toujours
-- respecter au moins le plus court contrat legal (attaque d'or) depuis cette prise.
function Overlord.Outpost:IsRecaptureTerminalAllowed(st, captureTs)
    if not st then return false end
    local baseClaimedAt = 0
    if st.status == "held" then
        baseClaimedAt = math.floor(tonumber(st.claimedAt) or 0)
    elseif st.status == "in_progress" then
        baseClaimedAt = math.floor(tonumber(st.previousClaimedAt) or 0)
    end
    if baseClaimedAt <= 0 then return true end
    captureTs = math.floor(tonumber(captureTs) or time())
    return captureTs >= baseClaimedAt + self:GetMinimumHoldTimeRequired(nil)
end

local function ResolveStrategicOutpostSiteKey(zone)
    local zoneId = zone and zone.id
    if not zoneId or zoneId == "" then return nil end
    local cached = strategicSiteKeyByZoneId[zoneId]
    if cached == false then return nil end
    if cached then return cached end
    local front
    if Overlord.Fronts and Overlord.Fronts.GetZone then
        local _, resolvedFront = Overlord.Fronts:GetZone(zoneId)
        front = resolvedFront
    end
    local siteKey = front and front.id
    if not siteKey or not siteByKey[siteKey] then
        strategicSiteKeyByZoneId[zoneId] = false
        return nil
    end
    strategicSiteKeyByZoneId[zoneId] = siteKey
    return siteKey
end

-- Bonus strategique de l'avant-poste du front : une tentative ennemie sur un
-- point normal demande 30 s de plus. La valeur est lue une seule fois au debut
-- de la vague puis voyage dans holdTimeRequired, comme Renfort/Barricade.
function Overlord.Outpost:GetZoneCapturePenaltySeconds(zone, attackingFaction)
    if not zone or zone.isCapital
        or (attackingFaction ~= "Alliance" and attackingFaction ~= "Horde") then
        return 0
    end
    local siteKey = ResolveStrategicOutpostSiteKey(zone)
    if not siteKey then return 0 end
    local st = self:GetState(siteKey)
    if not st then return 0 end
    if st.status == "held" and self:IsOutpostStateAwaitingNetworkSnapshot(st) then
        return 0
    end
    local _, ownerFaction = self:GetOutpostDisplayTenant(st, siteKey)
    if ownerFaction and ownerFaction ~= attackingFaction then
        return OUTPOST_ZONE_CAPTURE_PENALTY_SECONDS
    end
    return 0
end

function Overlord.Outpost:GetLocalPlayerGuild()
    local guild = GetGuildInfo and GetGuildInfo("player")
    return sanitizeGuildName(guild or "")
end

function Overlord.Outpost:GetKnownGuildFaction(guild)
    guild = sanitizeGuildName(guild or "")
    if guild == "" then return nil end
    local lb = Overlord.Leaderboard
    if lb and lb.guildFactionCache then
        local fac = lb.guildFactionCache[guild:lower()]
        if fac == "Alliance" or fac == "Horde" then return fac end
    end
    if Overlord.GuildKeep and Overlord.GuildKeep.GetKnownGuildFaction then
        return Overlord.GuildKeep:GetKnownGuildFaction(guild)
    end
    return nil
end

function Overlord.Outpost:GetEffectiveGuildFaction(guild, fallbackFaction)
    local known = self:GetKnownGuildFaction(guild)
    if known then return known end
    if fallbackFaction == "Alliance" or fallbackFaction == "Horde" then return fallbackFaction end
    return nil
end

function Overlord.Outpost:IsOutpostStateAwaitingNetworkSnapshot(st)
    if not st or st.status ~= "held" then return false end
    if sanitizeGuildName(st.ownerGuild or "") == "" then return false end
    if st._loginSyncUnconfirmed then return true end
    if (tonumber(st.updatedAt) or 0) > 0 then return false end
    if (tonumber(st.claimedAt) or 0) > 0 then return false end
    return true
end

function Overlord.Outpost:PlayerGuildOwnsOutpost(st)
    if not st or st.status ~= "held" then return false end
    local g = self:GetLocalPlayerGuild()
    return g ~= "" and g == sanitizeGuildName(st.ownerGuild or "")
end

function Overlord.Outpost:IsLocalOutpostCaptureActive(st)
    return st and st.status == "in_progress" and st.isHolding and st.holdAuthorityLocal
end

function Overlord.Outpost:IsPlayerOutpostAssailant(st)
    if not st or st.status ~= "in_progress" then return false end
    local guild = self:GetLocalPlayerGuild()
    if guild == "" then return false end
    if sanitizeGuildName(st.ownerGuild or "") ~= guild then return false end
    if st.ownerFaction and Overlord.PlayerFaction and st.ownerFaction ~= Overlord.PlayerFaction then
        return false
    end
    return true
end

function Overlord.Outpost:CanPlayerContestOutpost(st)
    local playerGuild = self:GetLocalPlayerGuild()
    if playerGuild == "" then return false end
    if not st or st.status ~= "held" then return false end
    -- La faction du joueur local est CERTAINE (client WoW) : jamais surchargee par le vote.
    local guildFaction = Overlord.PlayerFaction or self:GetKnownGuildFaction(playerGuild)
    if not guildFaction or not st.ownerFaction then return false end
    return guildFaction ~= st.ownerFaction
end

function Overlord.Outpost:IsPlayerDefendingHeldOutpost(st)
    if not st or st.status ~= "held" then return false end
    local pf = Overlord.PlayerFaction
    if not pf or not st.ownerFaction or pf ~= st.ownerFaction then return false end
    return true
end

function Overlord.Outpost:CanPlayerAssaultOutpostState(st)
    if not st then return false end
    local guild = self:GetLocalPlayerGuild()
    if guild == "" or not Overlord.PlayerFaction then return false end
    if st.status == "neutral" then return true end
    if st.status == "held" then
        return self:CanPlayerContestOutpost(st)
    end
    if st.status == "in_progress" and self:IsObserverOutpostCaptureStale(st) then
        -- Le bail d'affichage distant a expire. Gameplay local : raisonner sur
        -- son socle stable sans diffuser de faux revert observateur.
        local previousFaction = st.previousOwnerFaction
        if not previousFaction then return true end
        return previousFaction ~= Overlord.PlayerFaction
    end
    return false
end

function Overlord.Outpost:CanPlayerStartCapture(st)
    return self:CanPlayerAssaultOutpostState(st)
end

function Overlord.Outpost:GetOutpostDisplayTenant(st, siteKey)
    if not st then return "", nil end
    if st.status == "held" then
        return sanitizeGuildName(st.ownerGuild or ""), st.ownerFaction
    end
    if st.status == "in_progress" then
        return sanitizeGuildName(st.previousOwnerGuild or ""), st.previousOwnerFaction
    end
    return "", nil
end

local function outpostTowerAtlasForFaction(fac)
    if fac == "Alliance" then return "Warfronts-BaseMapIcons-Alliance-Tower" end
    if fac == "Horde" then return "Warfronts-BaseMapIcons-Horde-Tower" end
    return nil
end

-- Leaderboard : icone tour (comme les nodes de zone, pas MainHall des fortins).
function Overlord.Outpost:GetMainHallAtlasForFaction(fac)
    return outpostTowerAtlasForFaction(fac)
end

function Overlord.Outpost:GetOutpostMapIconAtlas(st, site, displayMapID)
    if not st then return OUTPOST_NEUTRAL_ATLAS end
    if st.status == "held" then
        local atlas = outpostTowerAtlasForFaction(st.ownerFaction)
        return atlas or OUTPOST_NEUTRAL_ATLAS
    end
    if st.status == "in_progress" then
        if self:IsObserverOutpostCaptureStale(st, site) then
            local staleAtlas = outpostTowerAtlasForFaction(st.previousOwnerFaction)
            return staleAtlas or OUTPOST_NEUTRAL_ATLAS
        end
        local fac = st.previousOwnerFaction or st.ownerFaction
        local atlas = outpostTowerAtlasForFaction(fac)
        return atlas or OUTPOST_NEUTRAL_ATLAS
    end
    return OUTPOST_NEUTRAL_ATLAS
end

function Overlord.Outpost:GetOutpostIconVertexColor(st, site, displayMapID)
    if not st then return 0.65, 0.65, 0.7 end
    if st.status == "in_progress" then
        if self:IsObserverOutpostCaptureStale(st, site) then
            if sanitizeGuildName(st.previousOwnerGuild or "") ~= "" then
                return 1, 1, 1
            end
            return 0.65, 0.65, 0.7
        end
        -- Conteste (rouge) vs capture qui progresse (or), comme fortins et zones warfront.
        if st.isContested then
            return 1, 0.35, 0.15
        end
        return 1, 0.82, 0
    end
    if st.status == "held" then
        return 1, 1, 1
    end
    return 0.65, 0.65, 0.7
end

local function PollIfOutpostStateNeedsCatchup(st)
    if not st or not Overlord.Sync or not Overlord.Sync.PollIfStaleObserverOutpost then return end
    local ts = tonumber(st.updatedAt) or 0
    if st.status == "in_progress" then
        if ts <= 0 then
            Overlord.Sync:PollIfStaleObserverOutpost(999)
        end
        return
    end
    if st.status == "held" and Overlord.Outpost:IsOutpostStateAwaitingNetworkSnapshot(st) then
        Overlord.Sync:PollIfStaleObserverOutpost(999)
        return
    end
    if st.status ~= "neutral" then return end
    if ts > 0 or (st.ownerGuild or "") ~= "" or (tonumber(st.claimedAt) or 0) > 0 then return end
    Overlord.Sync:PollIfStaleObserverOutpost(999)
end

-- Un OP distant n'est qu'une observation. Le dernier heartbeat contient deja
-- la progression acquise ; son delai maximal restant vaut donc req - hold, et
-- non une nouvelle duree complete de cinq minutes a partir du dernier paquet.
-- Cette expiration est d'abord une vue UI : aucun observateur ne fabrique ni
-- ne diffuse un etat final, ce qui conserve le correctif de convergence 7.2.2.
function Overlord.Outpost:IsObserverOutpostCaptureStale(st, site, now)
    if not st or st.status ~= "in_progress" then return false end
    if st.holdAuthorityLocal and (st.isHolding or st.isPaused) then return false end
    local ts = tonumber(st.updatedAt) or 0
    if ts <= 0 then return true end
    now = tonumber(now) or time()
    local age = math.max(0, now - ts)
    local req = self:GetDefaultHoldTimeRequired(st, site)
    local hold = math.max(0, math.min(tonumber(st.holdTimeElapsed) or 0, req))
    local remaining = math.max(0, req - hold)
    return age > remaining + OUTPOST_OBSERVER_STALE_BUFFER
end

function Overlord.Outpost:GetOutpostMapSubtitle(st, site, displayMapID)
    if not st or not site then return (L and L.OUTPOST_NEUTRAL) or "Unclaimed" end
    if st.status == "in_progress" then
        if self:IsObserverOutpostCaptureStale(st, site) then
            local previousGuild = sanitizeGuildName(st.previousOwnerGuild or "")
            if previousGuild ~= "" then return previousGuild end
            return (L and L.OUTPOST_NEUTRAL) or "Unclaimed"
        end
        return (L and L.OUTPOST_CAPTURING) or "Capturing..."
    end
    if st.status == "held" then
        local g = sanitizeGuildName(st.ownerGuild or "")
        if g ~= "" then return g end
    end
    return (L and L.OUTPOST_NEUTRAL) or "Unclaimed"
end

function Overlord.Outpost:ShouldShowInProgressOnMap(st, site, mapID)
    if not st or st.status ~= "in_progress" then return false end
    if self:IsObserverOutpostCaptureStale(st, site) then return false end
    mapID = mapID or self:GetPlayerMapID()
    return self:IsOutpostSiteDisplayMap(mapID, site)
end

-- Pin projete sur carte parente ou continent (EK / Kalimdor), pas sur la carte detail du site.
function Overlord.Outpost:ShouldProjectOutpostPinOnMap(site, projectionMapID)
    if not site or not projectionMapID or not site.mapID then return false end
    if projectionMapID == site.mapID then return false end
    if site.mapIDs and site.mapIDs[projectionMapID] then return false end
    if site.regionalMapIDs and site.regionalMapIDs[projectionMapID] then return true end
    local MM = Overlord.MapMarkers
    if not MM then return false end
    local kalID = MM.ResolveKalimdorMapID and MM:ResolveKalimdorMapID()
    if kalID and projectionMapID == kalID and site.regionalMapIDs then return true end
    if MM.IsEKMap and MM:IsEKMap(projectionMapID) and not site.regionalMapIDs then return true end
    return false
end

function Overlord.Outpost:GetLocalOutpostContestState(site)
    if not site or not self:IsPlayerInOutpostGeometry(site) then return nil end
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync
        and Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync() then
        return nil
    end
    if UnitIsDead("player") or UnitIsGhost("player") then return nil end
    if not Overlord.OutpostControl or not Overlord.OutpostControl.GetNearbyOutpostPlayerCounts then
        return nil
    end
    local friendlyCount, enemyCount = Overlord.OutpostControl:GetNearbyOutpostPlayerCounts(site)
    friendlyCount = tonumber(friendlyCount)
    enemyCount = tonumber(enemyCount)
    if not friendlyCount or not enemyCount then return nil end
    return enemyCount > 0 and enemyCount >= friendlyCount, friendlyCount, enemyCount
end

function Overlord.Outpost:ShouldApplyRemoteOutpostHold(st, siteKey, ht, fromSync, remoteTs)
    if not fromSync or not st then return true, ht end
    ht = tonumber(ht) or 0
    remoteTs = tonumber(remoteTs) or 0
    local localTs = tonumber(st.updatedAt) or 0
    if remoteTs > 0 and localTs > 0 and remoteTs < localTs then
        return false, ht
    end
    if st.holdAuthorityLocal and (st.isPaused or st.isContested) then
        return false, ht
    end
    local site = self:GetSite(siteKey)
    if st.holdAuthorityLocal and st.isHolding and site and self:IsPlayerInOutpostGeometry(site) then
        local req = self:GetDefaultHoldTimeRequired(st, site)
        local timeInZone = st.holdStartTime and (GetTime() - st.holdStartTime) or 0
        if timeInZone < 1 then timeInZone = 5 end
        local maxAllowed = math.min(timeInZone + 15, math.max(req - 1, 0))
        return true, math.max(tonumber(st.holdTimeElapsed) or 0, math.min(ht, maxAllowed))
    end
    if site and st.status == "in_progress" and st.ownerFaction and Overlord.PlayerFaction
        and st.ownerFaction ~= Overlord.PlayerFaction then
        local localContested, friendlyCount, enemyCount = self:GetLocalOutpostContestState(site)
        if localContested ~= nil and (friendlyCount or 0) >= (enemyCount or 0) then
            return false, ht
        end
    end
    if not self:IsPlayerOutpostAssailant(st) then
        return true, ht
    end
    local req = self:GetDefaultHoldTimeRequired(st, site)
    local timeInZone = st.holdStartTime and (GetTime() - st.holdStartTime) or 0
    if timeInZone < 1 then timeInZone = 5 end
    local maxAllowed = math.min(timeInZone + 15, math.max(req - 1, 0))
    return true, math.max(tonumber(st.holdTimeElapsed) or 0, math.min(ht, maxAllowed))
end

function Overlord.Outpost:CaptureStateToZoneView(st, site)
    if not st then return nil end
    local req = self:GetDefaultHoldTimeRequired(st, site)
    local zStatus = "available"
    if st.status == "held" then zStatus = "captured"
    elseif st.status == "in_progress" then zStatus = "in_progress" end
    return {
        id = (site and site.id) or (site and site.siteKey) or "outpost",
        status = zStatus,
        owner = st.ownerFaction,
        holdTimeElapsed = tonumber(st.holdTimeElapsed) or 0,
        holdTimeRequired = req,
        capturedTime = (tonumber(st.claimedAt) or 0) > 0 and tonumber(st.claimedAt) or 0,
        updatedAt = tonumber(st.updatedAt) or 0,
        previousOwner = st.previousOwnerFaction,
        isCapital = false,
        isHolding = st.isHolding or false,
        isPaused = st.isPaused or false,
    }
end

function Overlord.Outpost:ApplyOutpostRestoreZoneView(st, view, site)
    if not st or not view then return end
    st.isHolding = false
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = false
    st.holdStartTime = nil
    local req = self:GetDefaultHoldTimeRequired(st, site)
    st.holdTimeElapsed = math.min(tonumber(view.holdTimeElapsed) or 0, req)
    if view.status == "captured" then
        st.status = "held"
        local pg = sanitizeGuildName(st.previousOwnerGuild or "")
        if pg ~= "" and st.previousOwnerFaction then
            st.ownerGuild = pg
            st.ownerFaction = st.previousOwnerFaction
        else
            st.ownerFaction = view.owner
        end
        st.holdTimeElapsed = 0
        local prevCa = math.floor(tonumber(st.previousClaimedAt) or 0)
        if prevCa > 0 then
            st.claimedAt = prevCa
            st.expiresAt = 0
        end
        local previousPool = normalizeOutpostPoolTag(st.previousOwnerPool)
        if previousPool ~= "" then st.pool = previousPool end
        st.previousOwnerGuild = ""
        st.previousOwnerFaction = nil
        st.previousClaimedAt = 0
        st.previousExpiresAt = 0
        st.previousOwnerPool = ""
        st.updatedAt = time()
    elseif view.status == "in_progress" then
        st.status = "in_progress"
        st.ownerFaction = view.owner
    else
        st.status = "neutral"
        st.ownerGuild = ""
        st.ownerFaction = nil
        st.holdTimeElapsed = 0
        st.previousOwnerGuild = ""
        st.previousOwnerFaction = nil
        st.previousClaimedAt = 0
        st.previousExpiresAt = 0
        st.previousOwnerPool = ""
    end
    if view._restoredInProgress then
        st.updatedAt = time()
    end
end

local function RestoreInterruptedOutpostCapture(st, site, wasInProgress)
    if not st or not site or not Overlord.Zones then return end
    local view = Overlord.Outpost:CaptureStateToZoneView(st, site)
    if not view then return end
    if wasInProgress or st.status == "in_progress" then
        Overlord.Zones:RestoreInProgressAfterOffline(view)
        Overlord.Outpost:ApplyOutpostRestoreZoneView(st, view, site)
    end
end

function Overlord.Outpost:RestoreOutposts()
    self:EnsureDB()
    local loginSyncUnconfirmed = Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive()
    for key in pairs(Overlord.OutpostSites) do
        local saved = OverlordDB.outposts[key]
        local site = siteByKey[key]
        local st = self:GetState(key)
        local wasInProgress = saved and saved.status == "in_progress"
        if saved then
            for k, v in pairs(saved) do
                if k ~= "isHolding" and k ~= "isPaused" and k ~= "holdAuthorityLocal" and k ~= "holdStartTime" then
                    st[k] = v
                end
            end
        end
        st.isHolding = false
        st.isPaused = false
        st.holdAuthorityLocal = false
        st.holdStartTime = nil
        if wasInProgress or st.status == "in_progress" then
            RestoreInterruptedOutpostCapture(st, site, wasInProgress)
        end
        sanitizeOutpostState(st, site)
        if loginSyncUnconfirmed and st.status == "held" and sanitizeGuildName(st.ownerGuild or "") ~= "" then
            local claimedAt = math.floor(tonumber(st.claimedAt) or 0)
            local campaignStart = Overlord.Leaderboard and Overlord.Leaderboard.GetCurrentCampaignStart
                and Overlord.Leaderboard:GetCurrentCampaignStart() or (OverlordDB.lastResetTimestamp or 0)
            if claimedAt <= 0 or claimedAt < (tonumber(campaignStart) or 0) then
                st._loginSyncUnconfirmed = true
                st.updatedAt = 0
            end
        else
            st._loginSyncUnconfirmed = nil
        end
    end
end

function Overlord.Outpost:ResetOutpostsForCampaign()
    self:EnsureDB()
    for key in pairs(Overlord.OutpostSites) do
        OverlordDB.outposts[key] = defaultState()
    end
    if OverlordDB.outpostTenants then wipe(OverlordDB.outpostTenants) end
    if OverlordDB.outpostCaptureCounts then wipe(OverlordDB.outpostCaptureCounts) end
end

function Overlord.Outpost:IsCaptureTakeoverAllowed(st, guild, faction, captureTs)
    if not st or not faction then return false end
    guild = sanitizeGuildName(guild or "")
    if guild == "" then return false end
    -- Faction declaree du capturant d'abord, vote heuristique en secours (anti-homonymie),
    -- meme regle que GuildKeep:IsCaptureTakeoverAllowed.
    local effectiveFaction = (faction == "Alliance" or faction == "Horde")
        and faction or self:GetKnownGuildFaction(guild)
    if not effectiveFaction then return false end
    if not self:IsRecaptureTerminalAllowed(st, captureTs) then return false end
    if st.status == "held" then
        local tg = sanitizeGuildName(st.ownerGuild or "")
        if tg ~= "" and guild == tg then return false end
        if tg ~= "" and st.ownerFaction == effectiveFaction and guild ~= tg then return false end
    elseif st.status == "in_progress" then
        local pg = sanitizeGuildName(st.previousOwnerGuild or "")
        local pf = st.previousOwnerFaction
        if pg ~= "" and guild == pg then return false end
        if pg ~= "" and pf == effectiveFaction and guild ~= pg then return false end
        if st.ownerFaction == effectiveFaction and pg ~= "" and pf == effectiveFaction then return false end
    end
    return true
end

function Overlord.Outpost:CompleteCapture(siteKey, guild, faction, captureTs, capturePool, suppressLeaderboard)
    local st = self:GetState(siteKey)
    local now = (captureTs and captureTs > 0) and captureTs or time()
    if not self:IsCaptureTakeoverAllowed(st, guild, faction, now) then return false end
    local newGuild = sanitizeGuildName(guild or "")
    capturePool = normalizeOutpostPoolTag(capturePool)
    if capturePool == "" then capturePool = currentOutpostPoolTag() end
    if capturePool == "" then return false end
    st.status = "held"
    st.ownerGuild = newGuild
    st.ownerFaction = faction
    self:ClearOpCapturerFields(st)
    st.claimedAt = now
    st.expiresAt = now + OUTPOST_HOLD_SECONDS
    st.holdTimeElapsed = 0
    st.holdTimeRequired = self:GetBaseHoldTimeRequired(self:GetSite(siteKey))
    st.isHolding = false
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = false
    st.holdStartTime = nil
    st.previousOwnerGuild = ""
    st.previousOwnerFaction = nil
    st.previousClaimedAt = 0
    st.previousExpiresAt = 0
    st.previousOwnerPool = ""
    st._loginSyncUnconfirmed = nil
    st.pool = capturePool
    st.updatedAt = now
    self:SaveOutposts()
    self:MarkDirty()
    if Overlord.SaveState then Overlord:SaveState() end
    self:RefreshOutpostPresentation(siteKey)
    if Overlord.Sync and Overlord.Sync.PrintOutpostCaptureAlert then
        Overlord.Sync:PrintOutpostCaptureAlert(siteKey, st.ownerGuild, faction, now)
    end
    if not suppressLeaderboard and Overlord.Leaderboard and Overlord.Leaderboard.RecordOutpostCapture then
        Overlord.Leaderboard:RecordOutpostCapture(siteKey, st.ownerGuild, faction, now, capturePool)
    end
    return true
end

function Overlord.Outpost:ApplyRemoteState(siteKey, remote, fromSync)
    local st = self:GetState(siteKey)
    if not st or not remote then return end
    local remoteTs = tonumber(remote.updatedAt) or 0
    local localTs = tonumber(st.updatedAt) or 0
    -- Pendant un assaut, claimedAt vaut 0 par construction : la tenure stable
    -- a comparer aux heartbeats held reste celle de previousClaimedAt.
    local localStableClaimedAt = st.status == "in_progress"
        and math.floor(tonumber(st.previousClaimedAt) or 0)
        or math.floor(tonumber(st.claimedAt) or 0)
    local hadLocalAuthority = st.holdAuthorityLocal and (st.isHolding or st.isPaused)

    if fromSync and remoteTs > 0 and remoteTs == localTs then
        local remoteStatus, localStatus = tostring(remote.status or ""), tostring(st.status or "")
        local remoteGuild = sanitizeGuildName(remote.ownerGuild or "")
        local localGuild = sanitizeGuildName(st.ownerGuild or "")
        local remoteFac, localFac = tostring(remote.ownerFaction or ""), tostring(st.ownerFaction or "")
        local contentDiffers = remoteStatus ~= localStatus or remoteGuild ~= localGuild
            or remoteFac ~= localFac
        if contentDiffers then
            local rc = math.floor(tonumber(remote.claimedAt) or 0)
            local lc = math.floor(tonumber(st.claimedAt) or 0)
            if rc < lc then return end
            if rc == lc then
                local remoteTie = remoteStatus .. ":" .. remoteGuild:lower() .. ":" .. remoteFac
                local localTie = localStatus .. ":" .. localGuild:lower() .. ":" .. localFac
                if remoteTie >= localTie then return end
            end
            localTs = 0
        end
    end

    if fromSync and hadLocalAuthority and remoteTs > 0 and localTs > remoteTs then
        if remote.status == "held" and sanitizeGuildName(remote.ownerGuild or "") ~= "" then
            local rc = math.floor(tonumber(remote.claimedAt) or 0)
            if rc <= localStableClaimedAt then return false end
        else
            return false
        end
    end

    if fromSync and remote.status == "held" and sanitizeGuildName(remote.ownerGuild or "") ~= "" then
        local rc = math.floor(tonumber(remote.claimedAt) or 0)
        if rc > localStableClaimedAt then localTs = 0 end
    end

    if fromSync and remoteTs > 0 and localTs > remoteTs then return end
    -- OP neutral sans timestamp : ne pas effacer un etat local plus avance (SR partiel / relais).
    if fromSync and remoteTs <= 0 and remote.status == "neutral" then
        if st.status == "in_progress" or st.status == "held"
            or (tonumber(st.holdTimeElapsed) or 0) > 0
            or sanitizeGuildName(st.ownerGuild or "") ~= "" then
            return
        end
    end

    local rStatus = remote.status
    local rGuild = remote.ownerGuild
    local rFac = remote.ownerFaction
    local rHold = remote.holdTimeElapsed
    if fromSync and rFac ~= "Alliance" and rFac ~= "Horde" then
        -- Meme regle que GuildKeep:ApplyRemoteState : la faction declaree du paquet prime,
        -- l'heuristique de vote (empoisonnable par guildes homonymes cross-royaume) ne sert
        -- que de secours quand le paquet n'a pas de faction valide.
        rFac = self:GetEffectiveGuildFaction(rGuild or "", rFac) or rFac
    end

    -- OP held est un snapshot repetable, mais il peut aussi etre le premier paquet
    -- annoncant une prise. Une transition de tenant doit respecter la meme borne
    -- terminale que OC ; sinon un heartbeat held pourrait imposer une capture
    -- plus courte que le contrat minimal apres le rejet de sa finale one-shot.
    if fromSync and rStatus == "held" and sanitizeGuildName(rGuild or "") ~= ""
        and (rFac == "Alliance" or rFac == "Horde") then
        local remoteGuild = sanitizeGuildName(rGuild or "")
        local stableSnapshot = st.status == "held"
            and remoteGuild == sanitizeGuildName(st.ownerGuild or "")
            and rFac == st.ownerFaction
        if not stableSnapshot and st.status == "in_progress" then
            stableSnapshot = remoteGuild == sanitizeGuildName(st.previousOwnerGuild or "")
                and rFac == st.previousOwnerFaction
        end
        local captureTs = math.floor(tonumber(remote.claimedAt) or 0)
        if captureTs <= 0 then captureTs = remoteTs end
        if not stableSnapshot
            and not self:IsCaptureTakeoverAllowed(st, remoteGuild, rFac, captureTs) then
            return false
        end
    end

    local localAuthorityRejected = false
    local localAssaultActive = st.status == "in_progress"
        and st.holdAuthorityLocal and (st.isHolding or st.isPaused)

    -- Assaut local : un OP held du tenant assiege ne doit pas annuler la capture en cours
    -- (retour feedback Cairne's Gate : reset timer + « assaut possible »).
    if fromSync and st.status == "in_progress" and rStatus == "held" then
        local prevGuild = sanitizeGuildName(st.previousOwnerGuild or "")
        local remoteGuild = sanitizeGuildName(rGuild or "")
        local remoteClaimed = math.floor(tonumber(remote.claimedAt) or 0)
        if not (remoteClaimed > localStableClaimedAt and remoteClaimed > 0) then
            if (prevGuild ~= "" and remoteGuild == prevGuild)
                or localAssaultActive
                or (self:IsPlayerOutpostAssailant(st) and (tonumber(st.holdTimeElapsed) or 0) > 0) then
                rStatus = nil
                rGuild = nil
                rFac = nil
                rHold = nil
                localAuthorityRejected = true
            end
        end
    end

    if fromSync and rStatus == "in_progress" then
        local assaultGuild = sanitizeGuildName(rGuild or "")
        if assaultGuild ~= "" then
            local heldGuild = sanitizeGuildName(st.ownerGuild or "")
            local previousGuild = sanitizeGuildName(st.previousOwnerGuild or "")
            -- Faction d'assaut = rFac (resolution unique ci-dessus), pas l'heuristique.
            local assaultFaction = rFac
            if (st.status == "held" and heldGuild == assaultGuild)
                or (st.status == "held" and assaultFaction and assaultFaction == st.ownerFaction)
                or (st.status == "in_progress" and previousGuild == assaultGuild)
                or (st.status == "in_progress" and assaultFaction and assaultFaction == st.previousOwnerFaction) then
                rStatus = nil
                rGuild = nil
                rFac = nil
                rHold = nil
                localAuthorityRejected = true
            end
        end
    end

    if fromSync and hadLocalAuthority then
        local rf = rFac
        local pf = Overlord.PlayerFaction
        if rf and pf and rf ~= pf then
            if rStatus == "in_progress" then
                rStatus = nil
                rGuild = nil
                rFac = nil
                rHold = nil
                localAuthorityRejected = true
            elseif rStatus ~= "held" then
                rStatus = nil
                rGuild = nil
                rFac = nil
                rHold = nil
                localAuthorityRejected = true
            elseif st.status == "in_progress" then
                rStatus = nil
                rGuild = nil
                rFac = nil
                rHold = nil
                localAuthorityRejected = true
            else
                st.holdAuthorityLocal = false
                st.isHolding = false
                st.isPaused = false
                st.isContested = false
                st.holdStartTime = nil
                hadLocalAuthority = false
            end
        elseif rf and pf and rf == pf then
            local rg = sanitizeGuildName(rGuild or "")
            local lg = sanitizeGuildName(st.ownerGuild or "")
            if rg ~= "" and lg ~= "" and rg ~= lg then
                rStatus = nil
                rGuild = nil
                rFac = nil
                rHold = nil
                localAuthorityRejected = true
            end
        end
    end

    -- Un paquet dont le contenu territorial a ete refuse ne doit pas tout de meme
    -- effacer previousOwner*, changer le pool/claimedAt ou faire travailler l'UI.
    if localAuthorityRejected then return false end

    if rStatus == "in_progress" and st.status == "held" then
        st.previousOwnerPool = normalizeOutpostPoolTag(st.pool)
    elseif rStatus == "held" or rStatus == "neutral" then
        st.previousOwnerPool = ""
    end
    if rStatus then st.status = rStatus end
    if rGuild then st.ownerGuild = sanitizeGuildName(rGuild) end
    if rFac then st.ownerFaction = rFac end
    if rHold then
        local applyHold, mergedHold = self:ShouldApplyRemoteOutpostHold(
            st, siteKey, rHold, fromSync, remoteTs)
        if applyHold then
            st.holdTimeElapsed = tonumber(mergedHold) or 0
        end
    end
    if remote.claimedAt then st.claimedAt = math.floor(tonumber(remote.claimedAt) or 0) end
    if remote.expiresAt then st.expiresAt = math.floor(tonumber(remote.expiresAt) or 0) end
    -- Contrat borne : le reseau peut transporter uniquement 5 min ou la variante
    -- officielle reduite de 60 s. Un co-capteur ne doit jamais rallonger une vague
    -- dont l'attaque d'or a deja ete attestee par un heartbeat valide.
    local canonicalSite = self:GetSite(siteKey)
    local remoteRequirement = self:NormalizeHoldTimeRequired(
        remote.holdTimeRequired, canonicalSite)
    if st.status == "in_progress" then
        local localRequirement = self:GetDefaultHoldTimeRequired(st, canonicalSite)
        st.holdTimeRequired = localAssaultActive
            and math.min(localRequirement, remoteRequirement) or remoteRequirement
    else
        st.holdTimeRequired = self:GetBaseHoldTimeRequired(canonicalSite)
    end
    if remote.isContested ~= nil then st.isContested = remote.isContested end
    if remote.previousOwnerGuild then st.previousOwnerGuild = sanitizeGuildName(remote.previousOwnerGuild) end
    if remote.previousOwnerFaction then st.previousOwnerFaction = remote.previousOwnerFaction end
    if remote.previousClaimedAt then st.previousClaimedAt = math.floor(tonumber(remote.previousClaimedAt) or 0) end
    if remote.previousExpiresAt then st.previousExpiresAt = math.floor(tonumber(remote.previousExpiresAt) or 0) end
    if remote.pool then st.pool = normalizeOutpostPoolTag(remote.pool) end
    if remote.opRelayCapturerName then st.opRelayCapturerName = remote.opRelayCapturerName end
    if remote.opRelayCapturerShard then st.opRelayCapturerShard = remote.opRelayCapturerShard end
    if fromSync then
        -- Ne pas retirer l'autorite locale pendant un assaut actif (aligne Guild Keep).
        if not localAuthorityRejected and not localAssaultActive then
            st.isHolding = false
            st.isPaused = false
            st.holdAuthorityLocal = false
            st.holdStartTime = nil
        end
        if remoteTs > 0 then st.updatedAt = remoteTs end
        st._loginSyncUnconfirmed = nil
    end
    sanitizeOutpostState(st, siteByKey[siteKey])
    self:SaveOutposts()
    self:MarkDirty()
    self:RefreshOutpostPresentation(siteKey)
end

function Overlord.Outpost:TickMaintenance()
    local now = time()
    local anyChanged = false
    for key in pairs(Overlord.OutpostSites) do
        local st = self:GetState(key)
        if st.status == "held" and (tonumber(st.expiresAt) or 0) ~= 0 then
            st.expiresAt = 0
            anyChanged = true
        elseif st.status == "in_progress" and not st.holdAuthorityLocal and not st.isHolding then
            local age = now - (tonumber(st.updatedAt) or 0)
            local stale = self:IsObserverOutpostCaptureStale(st, self:GetSite(key), now)
            if stale then
                -- Observateur : poll SR uniquement, jamais d'ecriture d'etat gameplay (regression 6.3.0).
                if Overlord.Sync and Overlord.Sync.PollIfStaleObserverOutpost then
                    Overlord.Sync:PollIfStaleObserverOutpost(age)
                end
            else
                PollIfOutpostStateNeedsCatchup(st)
            end
            if observerStalePresentation[key] ~= stale then
                observerStalePresentation[key] = stale
                self:RefreshOutpostPresentation(key)
            end
        elseif st.status == "held" and self:IsOutpostStateAwaitingNetworkSnapshot(st) then
            PollIfOutpostStateNeedsCatchup(st)
            observerStalePresentation[key] = nil
        else
            observerStalePresentation[key] = nil
        end
    end
    if anyChanged then
        self:MarkDirty()
        self:SaveOutposts()
        for key in pairs(Overlord.OutpostSites) do
            self:RefreshOutpostPresentation(key)
        end
    end
end

function Overlord.Outpost:GetObserverHoldTimeElapsed(st, site)
    if not st or not site or st.status ~= "in_progress" then
        return tonumber(st and st.holdTimeElapsed) or 0
    end
    if st.holdAuthorityLocal and (st.isHolding or st.isPaused) then
        return tonumber(st.holdTimeElapsed) or 0
    end
    if self:IsPlayerOutpostAssailant(st) then
        return tonumber(st.holdTimeElapsed) or 0
    end
    if not self:IsPlayerInOutpostGeometry(site) then
        return tonumber(st.holdTimeElapsed) or 0
    end
    local ts = tonumber(st.updatedAt) or 0
    if ts <= 0 then
        return tonumber(st.holdTimeElapsed) or 0
    end
    local age = time() - ts
    -- Extrapolation AFFICHAGE SEUL entre deux OP (meme garde rising que Guild Keep).
    local hold = tonumber(st.holdTimeElapsed) or 0
    local mem = self._obsHoldDisplayMem
    if not mem then
        mem = {}
        self._obsHoldDisplayMem = mem
    end
    local siteKey = site and (site.siteKey or site.id) or "outpost"
    local m = mem[siteKey]
    if not m then
        m = { ts = 0, hold = 0, rising = false }
        mem[siteKey] = m
    end
    if ts ~= m.ts then
        m.rising = (m.ts > 0) and (ts > m.ts) and (hold > m.hold)
        m.ts = ts
        m.hold = hold
    end
    if st.isContested or not m.rising then
        return hold
    end
    local extra = math.min(age, 45)
    if extra <= 0 then return hold end
    local req = self:GetDefaultHoldTimeRequired(st, site)
    return math.min(hold + extra, math.max(req - 1, hold))
end

local lastPresentationRefresh = {}
local PRESENTATION_THROTTLE = 2

function Overlord.Outpost:RefreshOutpostPresentation(siteKey)
    local now = GetTime()
    local key = siteKey or ""
    local throttled = lastPresentationRefresh[key]
        and (now - lastPresentationRefresh[key]) < PRESENTATION_THROTTLE
    if not throttled then
        lastPresentationRefresh[key] = now
        if Overlord.MapMarkers and Overlord.MapMarkers.RefreshOutpostMapIfOpen then
            Overlord.MapMarkers:RefreshOutpostMapIfOpen()
        end
        if Overlord.MapMarkers and Overlord.MapMarkers.CheckOutpostMinimap then
            Overlord.MapMarkers:CheckOutpostMinimap()
        end
        if Overlord.ZoneIndicator and Overlord.ZoneIndicator.RefreshHud then
            Overlord.ZoneIndicator:RefreshHud()
        end
        if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
            Overlord.LeaderboardUI:RefreshIfVisible()
        end
    end
end

function Overlord.Outpost:GetDisplayName(site)
    if site and site.displayNameKey and L and L[site.displayNameKey] then
        return L[site.displayNameKey]
    end
    return (L and L.OUTPOST_SHORT) or (site and site.id) or "Outpost"
end

function Overlord.Outpost:GetShortDisplayName(site)
    return self:GetDisplayName(site)
end

function Overlord.Outpost:SanitizeGuildName(name)
    return sanitizeGuildName(name)
end
