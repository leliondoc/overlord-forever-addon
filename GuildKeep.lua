-- GuildKeep.lua - Presentation facade for fortress sites in the shared Outpost engine.
-- No siege clock, authority protocol, proof ledger or second capture controller.
Overlord.GuildKeep = {}
local GK, OP = Overlord.GuildKeep, Overlord.Outpost
local L = Overlord.L
local siteByKey = Overlord.GuildKeepSites
GK.DEFAULT_HOLD_TIME_REQUIRED = 600
GK.NEUTRAL_ATLAS = "Warfronts-BaseMapIcons-Empty-MainHall"

local function GetDefaultSiteKey()
    local best
    for key in pairs(siteByKey) do if not best or key < best then best = key end end
    return best
end

local delegates = {
    GetState = "GetState", GetPlayerMapID = "GetPlayerMapID",
    GetGeometryMapID = "GetGeometryMapID", GetMapAspectRatio = "GetMapAspectRatio",
    GetDisplayName = "GetDisplayName", GetShortDisplayName = "GetShortDisplayName",
    SanitizeGuildName = "SanitizeGuildName", GetLocalPlayerGuild = "GetLocalPlayerGuild",
    GetEffectiveCapturerName = "GetEffectiveCapturerName",
    GetEffectiveCapturerShard = "GetEffectiveCapturerShard",
    GetDefaultHoldTimeRequired = "GetDefaultHoldTimeRequired",
    GetBaseHoldTimeRequired = "GetBaseHoldTimeRequired",
    GetMinimumHoldTimeRequired = "GetMinimumHoldTimeRequired",
    NormalizeHoldTimeRequired = "NormalizeHoldTimeRequired",
    IsPlayerInKeepGeometry = "IsPlayerInOutpostGeometry",
    IsPlayerInKeepGeometryForHud = "IsPlayerInOutpostGeometry",
    IsKeepSiteDisplayMap = "IsOutpostSiteDisplayMap",
    ShouldProjectPinOnMap = "ShouldProjectOutpostPinOnMap",
    ShouldShowInProgressOnMap = "ShouldShowInProgressOnMap",
    GetKeepDisplayTenant = "GetOutpostDisplayTenant",
    GetKeepMapIconAtlas = "GetOutpostMapIconAtlas",
    GetKeepIconVertexColor = "GetOutpostIconVertexColor",
    GetKeepMapSubtitle = "GetOutpostMapSubtitle", GetKeepHudLabel = "GetOutpostMapSubtitle",
    GetObserverHoldTimeElapsed = "GetObserverHoldTimeElapsed",
    CanPlayerStartCapture = "CanPlayerStartCapture",
    CanPlayerAssaultKeepState = "CanPlayerAssaultOutpostState",
    CanPlayerContestKeep = "CanPlayerContestOutpost",
    IsPlayerDefendingHeldKeep = "IsPlayerDefendingHeldOutpost",
    IsPlayerKeepAssailant = "IsPlayerOutpostAssailant",
    IsKeepStateAwaitingNetworkSnapshot = "IsOutpostStateAwaitingNetworkSnapshot",
    MarkDirty = "MarkDirty", SaveKeeps = "SaveOutposts",
}
for name, target in pairs(delegates) do
    local method = target
    GK[name] = function(_, ...) return OP[method](OP, ...) end
end
function GK:GetSite(key) return siteByKey[key] end
function GK:GetDefaultSiteKey() return GetDefaultSiteKey() end
function GK:GetDefaultSite() return siteByKey[GetDefaultSiteKey()] end
function GK:ResolveSiteByMapID(mapID)
    local site = OP:ResolveSiteByMapID(mapID)
    return site and site.isFortress and site or nil
end
function GK:IsPlayerOnKeepMap()
    local onMap, site = OP:IsPlayerOnOutpostMap()
    return onMap and site.isFortress == true, site and site.isFortress and site or nil,
        OP:GetPlayerMapID() ~= nil
end
GK.GetPlayerKeepSiteForHud = GK.IsPlayerOnKeepMap
function GK:GetMainHallAtlasForFaction(faction)
    return OP:GetMainHallAtlasForFaction(faction, self:GetDefaultSite())
end
function GK:IsKeepCaptureInProgress(st, key)
    -- Tooltips/HUD use the same freshness window as the shared map renderer.
    -- This is presentation only: never finalize or revert a remote observation.
    local site = (key and self:GetSite(key)) or self:GetDefaultSite()
    return st ~= nil and st.status == "in_progress"
        and not OP:IsObserverOutpostCaptureStale(st, site)
end
function GK:IsKeepNeutralForDisplay(st, key)
    return not st or (not self:IsKeepCaptureInProgress(st, key)
        and select(1, self:GetKeepDisplayTenant(st, key)) == "")
end
function GK:GetKeepCaptureMapLabel(st, key)
    if self:IsKeepCaptureInProgress(st, key) then return L.OUTPOST_CAPTURING or "Capturing..." end
end
function GK:GetKeepCaptureAvailableHint() return L.FORTRESS_CAPTURE_AVAILABLE or "Available at any time" end
function GK:GetEffectiveHeldTenant(st, key)
    local guild, faction = self:GetKeepDisplayTenant(st, key)
    return guild, faction, st and (st.status == "in_progress" and st.previousClaimedAt or st.claimedAt)
end
function GK:GetGuildHeldSiteForPlayer()
    local guild = self:GetLocalPlayerGuild()
    if guild == "" then return end
    local best, site, latest = nil, nil, -1
    for key, candidate in pairs(siteByKey) do
        local st = self:GetState(key)
        local owner, _, at = self:GetEffectiveHeldTenant(st, key)
        if owner == guild and (at or 0) > latest then best, site, latest = st, candidate, at or 0 end
    end
    return best, site
end

function Overlord.GuildKeep:GetHudSite()
    local selKey = OverlordDB and OverlordDB.selectedKeepSiteKey
    if selKey and siteByKey[selKey] then
        return self:GetState(selKey), siteByKey[selKey]
    end
    local st, heldSite = self:GetGuildHeldSiteForPlayer()
    if st and heldSite then
        return st, heldSite
    end
    local onMap, site = self:IsPlayerOnKeepMap()
    if onMap and site then
        return self:GetState(site.siteKey), site
    end
    local defKey = GetDefaultSiteKey()
    local fallbackSite = defKey and siteByKey[defKey]
    if fallbackSite then
        return self:GetState(fallbackSite.siteKey), fallbackSite
    end
    return nil, nil
end

function Overlord.GuildKeep:SetSelectedKeepSite(siteKey)
    if not OverlordDB then return end
    if siteKey and not siteByKey[siteKey] then return end
    OverlordDB.selectedKeepSiteKey = siteKey
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    if Overlord.Ressources then
        if Overlord.Ressources.RefreshGuildKeepHUD then
            Overlord.Ressources:RefreshGuildKeepHUD(true)
        end
    end
end

function Overlord.GuildKeep:GetSelectedKeepSiteKey()
    local selKey = OverlordDB and OverlordDB.selectedKeepSiteKey
    if selKey and siteByKey[selKey] then return selKey end
    return nil
end

local cachedSortedSites

function Overlord.GuildKeep:GetSortedSiteList()
    if cachedSortedSites then return cachedSortedSites end
    local list = {}
    for key, site in pairs(Overlord.GuildKeepSites) do
        table.insert(list, site)
    end
    table.sort(list, function(a, b) return (a.siteKey or "") < (b.siteKey or "") end)
    cachedSortedSites = list
    return list
end

function GK:ShouldProjectPinOnMap(site, mapID)
    if not site then return false end
    if site.regionalMapIDs then return site.regionalMapIDs[mapID] == true end
    return mapID == 13 or mapID == 1415
end
