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
    GetDefaultHoldTimeRequired = "GetDefaultHoldTimeRequired",
    GetBaseHoldTimeRequired = "GetBaseHoldTimeRequired",
    GetMinimumHoldTimeRequired = "GetMinimumHoldTimeRequired",
    NormalizeHoldTimeRequired = "NormalizeHoldTimeRequired",
    IsPlayerInKeepGeometry = "IsPlayerInOutpostGeometry",
    IsKeepSiteDisplayMap = "IsOutpostSiteDisplayMap",
    ShouldProjectPinOnMap = "ShouldProjectOutpostPinOnMap",
    ShouldShowInProgressOnMap = "ShouldShowInProgressOnMap",
    GetKeepDisplayTenant = "GetOutpostDisplayTenant",
    GetKeepMapIconAtlas = "GetOutpostMapIconAtlas",
    GetKeepIconVertexColor = "GetOutpostIconVertexColor",
    GetKeepMapSubtitle = "GetOutpostMapSubtitle",
    GetObserverHoldTimeElapsed = "GetObserverHoldTimeElapsed",
    CanPlayerStartCapture = "CanPlayerStartCapture",
    MarkDirty = "MarkDirty",
}
for name, target in pairs(delegates) do
    local method = target
    GK[name] = function(_, ...) return OP[method](OP, ...) end
end
function GK:GetSite(key) return siteByKey[key] end
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

function GK:ShouldProjectPinOnMap(site, mapID)
    if not site then return false end
    if site.regionalMapIDs then return site.regionalMapIDs[mapID] == true end
    return mapID == 13 or mapID == 1415
end
