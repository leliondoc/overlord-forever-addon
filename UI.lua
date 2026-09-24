-- UI.lua - Interface Overlord, theme WC3 Human (design tokens wc3ui.banteg.xyz)
Overlord = Overlord or {}
Overlord.UI = Overlord.UI or {}
Overlord.UI.SHARD_POPUP_VIRTUAL_BUTTONS = 12
Overlord.UI.SHARD_TOOLTIP_PLAYER_MAX = 12
Overlord.UI.SHARD_TOOLTIP_SCAN_MAX = 48

local L = Overlord.L

local mainFrame = nil
-- Le cache de placement WoW est restaure avant PLAYER_LOGIN. Creer seulement
-- le cadre ici permet de le recuperer meme si les SavedVariables sont absentes ;
-- le contenu du panneau reste construit dans l'etape UI differee.
local mainFrameShell = CreateFrame("Frame", "OverlordMainFrame", UIParent, "BackdropTemplate")
mainFrameShell:SetSize(340, 520)
mainFrameShell:SetMovable(true)
mainFrameShell:SetDontSavePosition(false)
mainFrameShell:Hide()
local zoneListFrame = nil
local activeZoneFrame = nil

-- Partages aussi par les fonctions de creation/invalidation definies plus haut
-- que leurs lecteurs. Une declaration tardive creerait deux caches distincts
-- (global accidentel et upvalue locale), donc une invalidation sans effet.
local lastCommunityLayoutKey = nil
local lastCommunityLayoutClubState = nil
local lastForcesOffZone = false
local lastForcesDisplayKey = nil
local lastHeaderBandHeight = nil
local lastDominationPaintKey = nil

-- Palette Alliance - WC3 Human design tokens
local C_ALLIANCE = {
    bg       = {0.165, 0.165, 0.227, 0.95},
    panelBg  = {0.118, 0.118, 0.188, 0.85},
    gold     = {0.85, 0.68, 0.20},
    goldDim  = {0.55, 0.42, 0.12},
    blue     = {0.290, 0.478, 0.749},
    blueBright = {0.427, 0.702, 0.949},
    enemy    = {0.85, 0.15, 0.15},
    green    = {0.290, 0.870, 0.502},
    greenDim = {0.10, 0.50, 0.12},
    orange   = {1.0, 0.82, 0.0},   -- or (#FFD100) : or UI Blizzard (ex-capture orange)
    gray     = {0.502, 0.533, 0.627},
    white    = {0.925, 0.937, 0.969},
    barBg    = {0.118, 0.118, 0.188, 0.9},
}

-- Palette Horde - WC3 Orc design tokens
local C_HORDE = {
    bg       = {0.165, 0.122, 0.102, 0.95},
    panelBg  = {0.12, 0.05, 0.04, 0.85},
    gold     = {0.82, 0.22, 0.12},
    goldDim  = {0.52, 0.14, 0.08},
    blue     = {0.749, 0.290, 0.290},
    blueBright = {1.0, 0.40, 0.27},
    enemy    = {0.20, 0.50, 0.90},
    green    = {0.290, 0.870, 0.502},
    greenDim = {0.10, 0.50, 0.12},
    orange   = {1.0, 0.82, 0.0},   -- or (#FFD100) : or UI Blizzard (ex-capture orange)
    gray     = {0.502, 0.478, 0.455},
    white    = {0.941, 0.878, 0.753},
    barBg    = {0.10, 0.06, 0.05, 0.9},
}

local C = C_ALLIANCE

local PANEL_LINK = "addon:Overlord:panel"
-- Hook unique sur SetItemRef pour traiter les clics sur ces liens
local shardInviteSetItemRefHooked = false
-- Anti-spam whisper : une explication par cible toutes les 90 s
local SHARD_INVITE_WHISPER_COOLDOWN = 90
-- Les cibles viennent du cache SH borne (512 + reserve groupe 64). Garder la
-- meme borne ici et une LRU explicite evite le full-scan `pairs()` a chaque clic.
local SHARD_INVITE_WHISPER_MAX = 576
local shardInviteWhisperNodes = {}
local shardInviteWhisperHead, shardInviteWhisperTail, shardInviteWhisperCount

local function IsShardHelperActive()
    if Overlord.IsShardHelperActive then
        return Overlord:IsShardHelperActive()
    end
    return Overlord.InActiveFront == true
end

-- Cibles whisper / invite (upvalues pour securecall sans closure anonyme)
local shardInviteWhisperTarget
local shardInviteWhisperText
local shardInvitePartyTarget

local function NormalizeShardInviteTarget(fullName)
    if not fullName or type(fullName) ~= "string" then return nil end
    fullName = fullName:match("^%s*(.-)%s*$") or ""
    if fullName == "" or #fullName < 2 or #fullName > 50 then return nil end
    if fullName:find("[%c:|]") then return nil end
    if fullName:sub(1, 5) == "BNet-" or fullName:sub(1, 7) == "Bridge-" then return nil end
    if Overlord.Sync and Overlord.Sync.NormalizeContributorFullName then
        fullName = Overlord.Sync:NormalizeContributorFullName(fullName) or fullName
    end
    if fullName == "" or #fullName < 2 then return nil end
    return fullName
end

local function UnlinkShardInviteWhisperNode(node)
    if node.prev then node.prev.next = node.next else shardInviteWhisperHead = node.next end
    if node.next then node.next.prev = node.prev else shardInviteWhisperTail = node.prev end
    node.prev, node.next = nil, nil
end

local function RemoveShardInviteWhisperNode(node)
    if not node then return end
    UnlinkShardInviteWhisperNode(node)
    shardInviteWhisperNodes[node.key] = nil
    shardInviteWhisperCount = math.max(0, (tonumber(shardInviteWhisperCount) or 1) - 1)
end

local function ShardInviteWhisperOnCooldown(fullName)
    local key = fullName:lower()
    local node = shardInviteWhisperNodes[key]
    if not node then return false end
    if GetTime() - (tonumber(node.at) or 0) >= SHARD_INVITE_WHISPER_COOLDOWN then
        RemoveShardInviteWhisperNode(node)
        return false
    end
    return true
end

local function MarkShardInviteWhisperSent(fullName)
    local key = fullName:lower()
    local node = shardInviteWhisperNodes[key]
    if node then
        UnlinkShardInviteWhisperNode(node)
    else
        node = { key = key }
        shardInviteWhisperNodes[key] = node
        shardInviteWhisperCount = (tonumber(shardInviteWhisperCount) or 0) + 1
    end
    node.at = GetTime()
    node.prev = shardInviteWhisperTail
    if shardInviteWhisperTail then shardInviteWhisperTail.next = node
    else shardInviteWhisperHead = node end
    shardInviteWhisperTail = node
    if shardInviteWhisperCount > SHARD_INVITE_WHISPER_MAX then
        RemoveShardInviteWhisperNode(shardInviteWhisperHead)
    end
end

local function GetShardInviteTargetFaction(fullName)
    if Overlord.Leaderboard and Overlord.Leaderboard.GetExportPlayerMeta then
        local _, faction = Overlord.Leaderboard:GetExportPlayerMeta(fullName)
        if faction == "Alliance" or faction == "Horde" then
            return faction
        end
    end
    return nil
end

-- Couleur nom joueur dans le popup shard (bleu Alliance, rouge Horde)
local function GetShardInviteNameColor(faction)
    if faction == "Alliance" then
        return 0.427, 0.702, 0.949
    elseif faction == "Horde" then
        return 1.0, 0.40, 0.27
    end
    return nil
end

-- Prefix |cff pour hyperliens tooltip shard
local function GetShardInviteNameColorEscape(faction)
    local r, g, b = GetShardInviteNameColor(faction)
    if not r then return "|cffff7359" end
    return string.format("|cff%02x%02x%02x",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function BuildShardDisplayTag(shardId)
    local tag = "#" .. tostring(shardId)
    local shardMod = Overlord.Shard
    local _, realm = shardMod and shardMod.GetShardReference
        and shardMod:GetShardReference(shardId)
    if realm and realm ~= "" then
        return tag .. " " .. string.format(L.SHARD_BADGE_REFERENCE, realm)
    end
    return tag
end

local function ApplyShardInviteButtonLabel(
    btn, playerName, shardId, defaultR, defaultG, defaultB, requestInvite)
    local label = requestInvite
        and string.format(L.SHARD_POPUP_REQUEST_BUTTON, playerName, BuildShardDisplayTag(shardId))
        or string.format("%s (%s)", playerName, BuildShardDisplayTag(shardId))
    if btn.label then
        btn.label:SetText(label)
    elseif btn.SetText then
        btn:SetText(label)
    end
    local fs = btn.label or (btn.GetFontString and btn:GetFontString())
    if not fs then return end
    local fr, fg, fb = GetShardInviteNameColor(GetShardInviteTargetFaction(playerName))
    if fr then
        fs:SetTextColor(fr, fg, fb)
        btn.baseTextColor = { fr, fg, fb }
    elseif defaultR then
        fs:SetTextColor(defaultR, defaultG, defaultB)
        btn.baseTextColor = { defaultR, defaultG, defaultB }
    end
end

local function ShardInviteTargetAlreadyGrouped(fullName)
    return Overlord.Shard and Overlord.Shard.IsPlayerAlreadyGrouped
        and Overlord.Shard:IsPlayerAlreadyGrouped(fullName)
end

local function ShardInviteTargetIsOnCurrentShard(targetShardId)
    local target = tonumber(targetShardId)
    local current = Overlord.Shard and Overlord.Shard.GetFreshLocalShardID
        and Overlord.Shard:GetFreshLocalShardID(8) or nil
    return target and current and target == current or false
end

local SHARD_INVITE_WHISPER_FR = {
    ALLY    = "[Overlord] Invitation groupe : je suis sur la couche n°%s (front de guerre). Acceptez pour vous phaser avec moi !",
    ENEMY   = "[Overlord] Je suis sur la couche n°%s. Rejoignez ma phase pour du JcJ !",
    NEUTRAL = "[Overlord] Invitation : je suis sur la couche n°%s. Acceptez pour vous phaser ensemble.",
}

local function ResolveShardInviteWhisperFormat(kind)
    local loc = Overlord.L or L
    local key = "SHARD_INVITE_WHISPER_" .. kind
    local fmt = loc and loc[key]
    if fmt and Overlord.IsFrenchLocale and Overlord.IsFrenchLocale() then
        if fmt:find("Join my layer", 1, true) or fmt:find("I'm on shard", 1, true) then
            fmt = SHARD_INVITE_WHISPER_FR[kind]
        end
    end
    return fmt
end

local function BuildShardInviteWhisperText(fullName)
    local myShard = Overlord.Shard and Overlord.Shard:GetCurrentShardID()
    local shardStr = (myShard ~= nil) and tostring(myShard) or "?"
    local pf = Overlord.PlayerFaction
    local tf = GetShardInviteTargetFaction(fullName)
    local fmt
    if tf and pf and tf ~= pf then
        fmt = ResolveShardInviteWhisperFormat("ENEMY")
    elseif tf and pf and tf == pf then
        fmt = ResolveShardInviteWhisperFormat("ALLY")
    else
        fmt = ResolveShardInviteWhisperFormat("NEUTRAL")
    end
    if fmt then
        return string.format(fmt, shardStr)
    end
    return nil
end

local function ExecuteShardInviteWhisper()
    if not SendChatMessage or not shardInviteWhisperTarget or not shardInviteWhisperText then return end
    if InCombatLockdown and InCombatLockdown() then return end
    -- Enregistre la cible dans le filtre d'erreurs whisper de Sync.lua :
    -- masque "Aucun joueur nomme 'X'..." si le joueur est offline ou cross-faction hors communaute.
    if Overlord.Sync and Overlord.Sync.RegisterRecentWhisperTarget then
        Overlord.Sync:RegisterRecentWhisperTarget(shardInviteWhisperTarget)
    end
    SendChatMessage(shardInviteWhisperText, "WHISPER", nil, shardInviteWhisperTarget)
end

local function ExecuteShardPartyInvite()
    if not shardInvitePartyTarget then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(shardInvitePartyTarget)
    elseif InviteUnit then
        InviteUnit(shardInvitePartyTarget)
    end
end

-- Whisper explicatif + invitation groupe (meme faction ou faction inconnue).
function Overlord.UI:InviteShardPlayer(fullName, targetShardId)
    if Overlord.InstanceSuspended then return end
    if not IsShardHelperActive() then return end
    if IsInInstance and IsInInstance() then return end

    fullName = NormalizeShardInviteTarget(fullName)
    if not fullName then return end
    if ShardInviteTargetAlreadyGrouped(fullName) then return end

    if not ShardInviteWhisperOnCooldown(fullName) then
        local text = BuildShardInviteWhisperText(fullName)
        if text and text ~= "" then
            shardInviteWhisperTarget = fullName
            shardInviteWhisperText = text
            securecall(ExecuteShardInviteWhisper)
            shardInviteWhisperTarget = nil
            shardInviteWhisperText = nil
            MarkShardInviteWhisperSent(fullName)
        end
    end

    -- Invite groupe meme cross-faction : phasing tire l'invite sur notre shard local.
    shardInvitePartyTarget = fullName
    securecall(ExecuteShardPartyInvite)
    shardInvitePartyTarget = nil
end

-- Mauvaise shard GK : le retardataire ne doit jamais inviter le porteur de l'ancre,
-- car cela tirerait ce dernier sur la mauvaise couche. Il lui demande de l'inviter.
function Overlord.UI:RequestShardInvite(fullName, targetShardId, zoneName)
    if Overlord.InstanceSuspended or not IsShardHelperActive() then return end
    if IsInInstance and IsInInstance() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    fullName = NormalizeShardInviteTarget(fullName)
    if not fullName or ShardInviteTargetAlreadyGrouped(fullName) then return end
    if ShardInviteTargetIsOnCurrentShard(targetShardId) then return end

    if ShardInviteWhisperOnCooldown(fullName) then return end
    local shardLabel = BuildShardDisplayTag(targetShardId or "?")
    local text = string.format(L.SHARD_INVITE_REQUEST_WHISPER, zoneName or "?", shardLabel)
    shardInviteWhisperTarget = fullName
    shardInviteWhisperText = text
    securecall(ExecuteShardInviteWhisper)
    shardInviteWhisperTarget = nil
    shardInviteWhisperText = nil
    MarkShardInviteWhisperSent(fullName)
end

local function InviteShardPlayerFromUI(fullName, targetShardId)
    if ShardInviteTargetAlreadyGrouped(fullName) then return end
    if Overlord.UI and Overlord.UI.InviteShardPlayer then
        Overlord.UI:InviteShardPlayer(fullName, targetShardId)
    end
end

local function RequestShardInviteFromUI(fullName, targetShardId, zoneName)
    if ShardInviteTargetAlreadyGrouped(fullName) then return end
    if Overlord.UI and Overlord.UI.RequestShardInvite then
        Overlord.UI:RequestShardInvite(fullName, targetShardId, zoneName)
    end
end

function Overlord.UI:OpenPanelFromLink(button)
    if button and button ~= "LeftButton" then return end
    if Overlord.InstanceSuspended then
        if L and L.DISABLED_IN_INSTANCE then
            Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.DISABLED_IN_INSTANCE)
        end
        return
    end
    if not mainFrame and self.Initialize then
        self:Initialize()
    end
    if self.Show then self:Show() end
end

function Overlord.UI:IsPanelAddonLink(link)
    if type(link) ~= "string" or link == "" then return false end
    if link == PANEL_LINK then return true end
    local linkType, addonName, linkData = strsplit(":", link, 3)
    return linkType == "addon" and addonName == "Overlord" and linkData == "panel"
end

local function RegisterShardTooltipInviteLinkHandler()
    if shardInviteSetItemRefHooked then return end
    shardInviteSetItemRefHooked = true
    hooksecurefunc("SetItemRef", function(link, _, button)
        if button ~= "LeftButton" or type(link) ~= "string" then return end
        if Overlord.UI and Overlord.UI.IsPanelAddonLink and Overlord.UI:IsPanelAddonLink(link) then
            Overlord.UI:OpenPanelFromLink(button)
            return
        end
        local requestPrefix = Overlord.Shard and Overlord.Shard.KEEP_INVITE_REQUEST_LINK_PREFIX
            or "addon:Overlord:requestkeep:"
        if link:sub(1, #requestPrefix) == requestPrefix then
            local siteKey, shardStr, fullName = strsplit(":", link:sub(#requestPrefix + 1), 3)
            local targetShard = tonumber(shardStr)
            local site = siteKey and Overlord.GuildKeepSites
                and Overlord.GuildKeepSites[siteKey] or nil
            fullName = NormalizeShardInviteTarget(fullName)
            if not site or not targetShard or not fullName then return end
            if Overlord.InstanceSuspended or not IsShardHelperActive() then return end
            local zoneName = Overlord.GuildKeep and Overlord.GuildKeep.GetDisplayName
                and Overlord.GuildKeep:GetDisplayName(site) or siteKey
            RequestShardInviteFromUI(fullName, targetShard, zoneName)
            return
        end
        local invitePrefix = Overlord.Shard and Overlord.Shard.INVITE_LINK_PREFIX
            or "addon:Overlord:invite:"
        if link:sub(1, #invitePrefix) ~= invitePrefix then return end
        local fullName = link:sub(#invitePrefix + 1)
        if fullName == "" then return end
        if Overlord.InstanceSuspended or not IsShardHelperActive() then return end
        InviteShardPlayerFromUI(fullName, nil)
    end)
end

function Overlord.UI:EnsureAddonLinkHandlers()
    RegisterShardTooltipInviteLinkHandler()
end

-- Scroll molette + fleches haut/bas (meme principe que LeaderboardUI).
local SCROLL_IND_UP   = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up"
local SCROLL_IND_DOWN = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up"

function Overlord.UI:UpdateWheelScrollIndicators(scroll, upT, downT)
    if not scroll or not upT or not downT then return end
    local maxS = scroll:GetVerticalScrollRange() or 0
    local cur = scroll:GetVerticalScroll() or 0
    local can = maxS > 2
    downT:SetShown(can and cur < maxS - 1)
    upT:SetShown(can and cur > 1)
end

function Overlord.UI:CreateWC3WheelScroll(parent, contentWidth, wheelStep)
    wheelStep = wheelStep or 24
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 6)
    scroll:EnableMouse(true)

    local scrollIndUp = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    scrollIndUp:SetTexture(SCROLL_IND_UP)
    scrollIndUp:SetSize(18, 18)
    scrollIndUp:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -2, -2)
    scrollIndUp:SetAlpha(0.8)
    scrollIndUp:Hide()

    local scrollIndDown = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    scrollIndDown:SetTexture(SCROLL_IND_DOWN)
    scrollIndDown:SetSize(18, 18)
    scrollIndDown:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -2, 2)
    scrollIndDown:SetAlpha(0.8)
    scrollIndDown:Hide()

    local ui = Overlord.UI
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local newVal = cur - delta * wheelStep
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
        ui:UpdateWheelScrollIndicators(self, scrollIndUp, scrollIndDown)
    end)
    scroll:HookScript("OnVerticalScroll", function()
        ui:UpdateWheelScrollIndicators(scroll, scrollIndUp, scrollIndDown)
    end)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(contentWidth or 248)
    scroll:SetScrollChild(content)

    return scroll, content, scrollIndUp, scrollIndDown
end

-- Scroll compact partageable : meme rail draggable que les contrats/classements,
-- sans template Blizzard ni allocation pendant le defilement.
function Overlord.UI:CreateCleanScroll(parent, width, height, wheelStep, showFades)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    wheelStep = math.max(1, tonumber(wheelStep) or 34)

    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetSize(width, height)
    scroll:EnableMouseWheel(true)
    scroll:EnableMouse(true)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(width, 1)
    scroll:SetScrollChild(child)

    local topFade = scroll:CreateTexture(nil, "OVERLAY")
    topFade:SetPoint("TOPLEFT")
    topFade:SetPoint("TOPRIGHT")
    topFade:SetHeight(10)
    topFade:SetColorTexture(0, 0, 0, 0.28)
    topFade:Hide()

    local bottomFade = scroll:CreateTexture(nil, "OVERLAY")
    bottomFade:SetPoint("BOTTOMLEFT")
    bottomFade:SetPoint("BOTTOMRIGHT")
    bottomFade:SetHeight(10)
    bottomFade:SetColorTexture(0, 0, 0, 0.32)
    bottomFade:Hide()

    local up = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    up:SetTexture(SCROLL_IND_UP)
    up:SetSize(18, 18)
    up:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 1, -2)
    up:Hide()

    local down = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    down:SetTexture(SCROLL_IND_DOWN)
    down:SetSize(18, 18)
    down:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 1, 2)
    down:Hide()

    local track = parent:CreateTexture(nil, "OVERLAY", nil, 5)
    track:SetWidth(3)
    track:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, -22)
    track:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 8, 22)
    track:SetColorTexture(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.34)
    track:Hide()

    local thumb = CreateFrame("Button", nil, parent)
    thumb:SetSize(14, 18)
    thumb:SetFrameLevel(scroll:GetFrameLevel() + 4)
    thumb:EnableMouse(true)
    thumb:RegisterForDrag("LeftButton")
    local thumbBar = thumb:CreateTexture(nil, "OVERLAY", nil, 6)
    thumbBar:SetWidth(5)
    thumbBar:SetPoint("TOP", 0, -1)
    thumbBar:SetPoint("BOTTOM", 0, 1)
    thumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.88)
    thumb:Hide()

    local function RefreshRail()
        local current = scroll:GetVerticalScroll() or 0
        local maximum = scroll:GetVerticalScrollRange() or 0
        local hasScroll = scroll._overlordHasOverflow
        if hasScroll == nil then hasScroll = maximum > 2 end
        topFade:SetShown(showFades ~= false and hasScroll and current > 1)
        bottomFade:SetShown(showFades ~= false and hasScroll and current < maximum - 1)
        up:SetShown(hasScroll)
        down:SetShown(hasScroll)
        up:SetAlpha(current > 1 and 0.85 or 0.28)
        down:SetAlpha(current < maximum - 1 and 0.85 or 0.28)
        track:SetShown(hasScroll)
        thumb:SetShown(hasScroll)
        if hasScroll then
            local viewportH = math.max(1, scroll:GetHeight() or height)
            local contentH = math.max(viewportH,
                tonumber(scroll._overlordContentHeight) or (viewportH + maximum))
            local trackH = math.max(1, viewportH - 44)
            local thumbH = math.max(18, math.min(trackH, trackH * viewportH / contentH))
            local travel = math.max(0, trackH - thumbH)
            local offset = maximum > 0 and travel * current / maximum or 0
            thumb:ClearAllPoints()
            thumb:SetSize(14, thumbH)
            thumb:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 2.5, -22 - offset)
        end
    end

    local function GetScaledCursorY()
        local _, cursorY = GetCursorPosition()
        local scale = UIParent and UIParent:GetEffectiveScale() or 1
        if not scale or scale <= 0 then scale = 1 end
        return cursorY / scale
    end

    local function StopThumbDrag(self)
        self.dragging = false
        self.dragOffset = nil
        self:SetScript("OnUpdate", nil)
        thumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.88)
    end

    thumb:SetScript("OnDragStart", function(self)
        if (scroll:GetVerticalScrollRange() or 0) <= 2 then return end
        local cursorY = GetScaledCursorY()
        self.dragOffset = (self:GetTop() or cursorY) - cursorY
        self.dragging = true
        thumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
        self:SetScript("OnUpdate", function(button)
            local maximum = scroll:GetVerticalScrollRange() or 0
            local trackTop = (scroll:GetTop() or 0) - 22
            local trackH = math.max(1, (scroll:GetHeight() or height) - 44)
            local travel = math.max(0, trackH - (button:GetHeight() or 18))
            if maximum <= 2 or travel <= 0 then return end
            local wantedTop = GetScaledCursorY() + (button.dragOffset or 0)
            local offset = math.max(0, math.min(travel, trackTop - wantedTop))
            scroll:SetVerticalScroll(maximum * offset / travel)
            RefreshRail()
        end)
    end)
    thumb:SetScript("OnDragStop", StopThumbDrag)
    thumb:SetScript("OnHide", StopThumbDrag)
    thumb:SetScript("OnEnter", function()
        thumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
    end)
    thumb:SetScript("OnLeave", function(self)
        if not self.dragging then
            thumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.88)
        end
    end)

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maximum = self:GetVerticalScrollRange() or 0
        local nextValue = (self:GetVerticalScroll() or 0) - delta * wheelStep
        self:SetVerticalScroll(math.max(0, math.min(maximum, nextValue)))
        RefreshRail()
    end)
    scroll:HookScript("OnVerticalScroll", RefreshRail)
    scroll:HookScript("OnScrollRangeChanged", RefreshRail)
    scroll:HookScript("OnSizeChanged", RefreshRail)
    scroll.RefreshCleanRail = RefreshRail
    scroll.content = child
    return scroll, child
end

-- Cree une fois la fenetre liste + voile clic exterieur (style WC3 comme guide / export).
local function HideShardMismatchPopup(ui)
    if ui._shardMismatchPopup then ui._shardMismatchPopup:Hide() end
end

-- Position libre du popup shard : ne plus recentrer a chaque ouverture une fois deplace.
local function IsShardPopupUserPlaced()
    return OverlordDB and OverlordDB.shardPopupUserPlaced == true
end

local function IsShardPopupLocked()
    return OverlordDB and OverlordDB.shardPopupLocked == true
end

local function SaveShardPopupPosition(f)
    if not f or not OverlordDB then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    OverlordDB.shardPopupPos = {
        point = point,
        relPoint = relPoint or "BOTTOMLEFT",
        x = x or 0,
        y = y or 0,
    }
    OverlordDB.shardPopupUserPlaced = true
end

local function ApplyShardPopupDefaultPosition(f)
    f:ClearAllPoints()
    local anchor = f._openAnchorFrame
    -- Clic badge : sous le badge (meme famille que l'ouvreur manuel).
    if anchor and anchor.IsShown and anchor:IsShown() then
        f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
        return
    end
    -- Meme placement que "Players on another shard" (ouvreur badge) : centre du panneau,
    -- meme si le panneau est cache (alertes keep / cercle). Plus de milieu d'ecran.
    if mainFrame then
        f:SetPoint("CENTER", mainFrame, "CENTER", 0, 0)
        return
    end
    -- Panneau pas encore cree : meme coin droit que UpdatePanelAnchor par defaut.
    f:SetPoint("RIGHT", UIParent, "RIGHT", -220, 0)
end

local function ApplyShardPopupPosition(f)
    if not f then return end
    local pos = OverlordDB and OverlordDB.shardPopupPos
    if IsShardPopupUserPlaced() and pos
        and type(pos.point) == "string"
        and type(pos.x) == "number" and type(pos.y) == "number" then
        f:ClearAllPoints()
        f:SetPoint(pos.point, UIParent, pos.relPoint or "BOTTOMLEFT", pos.x, pos.y)
        return
    end
    ApplyShardPopupDefaultPosition(f)
end

local function ToggleShardPopupLocked()
    if not OverlordDB then return end
    OverlordDB.shardPopupLocked = not IsShardPopupLocked()
    local msg = IsShardPopupLocked() and L.SHARD_POPUP_LOCKED or L.SHARD_POPUP_UNLOCKED
    if Overlord.PrintNotification and msg then
        Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. msg)
    end
end

local function EnsureShardMismatchPopup(ui)
    if ui._shardMismatchPopup then return end

    local f = CreateFrame("Frame", "OverlordShardMismatchPopup", UIParent, "BackdropTemplate")
    f:SetSize(320, 280)
    Overlord.UI.ApplyWoodDialogBackdrop(f)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(6100)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if IsShardPopupLocked() then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if IsShardPopupLocked() then return end
        SaveShardPopupPosition(self)
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            ToggleShardPopupLocked()
        end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:AddLine(L.SHARD_POPUP_MOVE_HINT or "", 1, 1, 1, true)
        if IsShardPopupLocked() and L.SHARD_POPUP_LOCKED then
            GameTooltip:AddLine(L.SHARD_POPUP_LOCKED, 1, 0.82, 0.2, true)
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    f:SetClampedToScreen(true)
    f:Hide()

    tinsert(UISpecialFrames, f:GetName())

    local blocker = CreateFrame("Button", nil, UIParent)
    blocker:SetFrameStrata("FULLSCREEN_DIALOG")
    blocker:SetFrameLevel(6098)
    blocker:SetAllPoints(UIParent)
    blocker:EnableMouse(true)
    blocker:Hide()
    blocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    blocker:SetScript("OnClick", function()
        local pop = ui._shardMismatchPopup
        -- Popup auto entree cercle : fermer seulement via Fermer / X / Echap (sauf nonBlocking).
        if pop and pop._zoneEntryMode and not pop._nonBlocking then return end
        HideShardMismatchPopup(ui)
    end)

    -- Modalite (blocker + strata) factorisee : OnShow ne se redeclenche PAS si la
    -- frame est deja visible quand OpenShardMismatchPopup est rappele avec une autre modalite
    -- (ex. popup bloquant ouvert par-dessus une alerte nonBlocking) ; il faut donc pouvoir la
    -- re-appliquer explicitement, sinon le blocker garde l'etat de l'ancien mode.
    f.ApplyShardPopupModality = function(self)
        if blocker then
            if self._nonBlocking then blocker:Hide() else blocker:Show() end
        end
        if self._nonBlocking then
            self:SetFrameStrata("DIALOG")
        else
            self:SetFrameStrata("FULLSCREEN_DIALOG")
        end
    end
    f:SetScript("OnShow", function(self)
        self:ApplyShardPopupModality()
        if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
        if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
            self:SetScale(Overlord.UI:GetEffectiveUiScale())
        else
            self:SetScale(1)
        end
        -- Apres le scale : restaure la position joueur (sinon recentrage centre a chaque alerte).
        ApplyShardPopupPosition(self)
    end)
    f:SetScript("OnHide", function()
        ui:CancelShardMismatchRowsBuild()
        if blocker then blocker:Hide() end
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
    end)

    local titleFs = f:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    titleFs:SetPoint("TOPLEFT", 36, -14)
    titleFs:SetPoint("TOPRIGHT", -36, -14)
    titleFs:SetJustifyH("CENTER")
    titleFs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    titleFs:SetShadowOffset(2, -2)

    local subFs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    subFs:SetPoint("TOPLEFT", 18, -46)
    subFs:SetPoint("TOPRIGHT", -18, -46)
    subFs:SetJustifyH("LEFT")
    subFs:SetWordWrap(true)

    local hintFs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintFs:SetPoint("TOPLEFT", subFs, "BOTTOMLEFT", 0, -8)
    hintFs:SetPoint("TOPRIGHT", subFs, "BOTTOMRIGHT", 0, -8)
    hintFs:SetJustifyH("LEFT")
    hintFs:SetWordWrap(true)

    local listPanel = Overlord.UI.CreateWC3SubPanel(f, 284, 160, {
        panelBg = C.panelBg,
        borderColor = C.goldDim,
        borderAlpha = 0.5,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    listPanel:SetPoint("TOP", 0, -120)

    local scroll, content, scrollIndUp, scrollIndDown = Overlord.UI:CreateWC3WheelScroll(listPanel, 248, 26)

    local emptyFs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyFs:SetPoint("TOPLEFT", 8, -8)
    emptyFs:SetPoint("TOPRIGHT", -8, -8)
    emptyFs:SetJustifyH("LEFT")
    emptyFs:SetWordWrap(true)

    local closeBtn = Overlord.UI.CreateWC3Button(
        f, 140, 28, L.GUIDE_CLOSE or L.EXPORT_CLOSE or "Close",
        function() HideShardMismatchPopup(ui) end,
        nil, { gold = C.gold, white = C.white }
    )
    closeBtn:SetPoint("BOTTOM", 0, 14)

    Overlord.UI.CreateWC3CloseButton(f, function() HideShardMismatchPopup(ui) end, { gold = C.gold })
        :SetPoint("TOPRIGHT", -8, -8)

    -- ESC ferme via UISpecialFrames (deja enregistre ci-dessus), pas de EnableKeyboard/OnKeyDown :
    -- capter le clavier bloquait TOUTES les touches (deplacement, sorts) tant que le popup restait
    -- ouvert, car SetPropagateKeyboardInput(true) est interdit en combat (restriction WoW 10.1.5+)
    -- et ne relachait donc plus le clavier avant un clic souris sur Fermer/X (perte de controle joueur).
    ui._shardMismatchPopup = f
    ui._shardMismatchPopupBlocker = blocker
    ui._shardMismatchListPanel = listPanel
    ui._shardMismatchTitleFs = titleFs
    ui._shardMismatchSubFs = subFs
    ui._shardMismatchHintFs = hintFs
    ui._shardMismatchScroll = scroll
    ui._shardMismatchScrollChild = content
    ui._shardMismatchScrollIndUp = scrollIndUp
    ui._shardMismatchScrollIndDown = scrollIndDown
    ui._shardMismatchEmptyFs = emptyFs
    ui._shardMismatchBtns = {}
    scroll:HookScript("OnVerticalScroll", function()
        if Overlord.UI and Overlord.UI.RefreshShardMismatchVirtualRows then
            Overlord.UI:RefreshShardMismatchVirtualRows()
        end
    end)
end

-- Creation lazy au login / entree front : evite le hitch a la premiere alerte combat.
function Overlord.UI:PrewarmShardMismatchPopup()
    EnsureShardMismatchPopup(self)
end

function Overlord.UI:ShardMismatchRowLess(a, b)
    local aShard, bShard = tonumber(a and a.shard), tonumber(b and b.shard)
    if aShard and bShard and aShard ~= bShard then return aShard < bShard end
    local aTag, bTag = tostring(a and a.shard or ""), tostring(b and b.shard or "")
    if aTag ~= bTag then return aTag < bTag end
    return string.lower(tostring(a and a.player or ""))
        < string.lower(tostring(b and b.player or ""))
end

-- Publie une generation complete sans masquer l'ancienne pendant le scan/tri.
function Overlord.UI:ApplyShardMismatchRows(rows, complete)
    rows = type(rows) == "table" and rows or {}
    local content, panel, frame = self._shardMismatchScrollChild,
        self._shardMismatchListPanel, self._shardMismatchPopup
    if not content or not frame then return end
    self._shardMismatchRows = rows
    if #rows == 0 then
        self._shardMismatchEmptyFs:SetText(complete
            and (self._shardMismatchEmptyText or L.SHARD_POPUP_EMPTY) or "...")
        self._shardMismatchEmptyFs:Show()
        content:SetHeight(48)
    else
        self._shardMismatchEmptyFs:Hide()
        content:SetHeight(math.max(46, 8 + #rows * (self._shardMismatchRowH or 26)))
    end
    local listH = math.min(math.max(56, content:GetHeight() + 16), 200)
    if panel then panel:SetHeight(listH) end
    frame:SetHeight(math.min((self._shardMismatchListTop or 88) + listH + 56,
        self._shardMismatchFrameMaxH or 400))
    self:RefreshShardMismatchVirtualRows()
    self:UpdateWheelScrollIndicators(self._shardMismatchScroll,
        self._shardMismatchScrollIndUp, self._shardMismatchScrollIndDown)
end

-- Le cache SH peut contenir plus de 500 joueurs. Scan, filtre et tri se font par
-- tranches; une mutation concurrente laisse la generation terminee visible puis
-- programme un unique rattrapage, ce qui evite la famine sous rafale SH.
function Overlord.UI:CancelShardMismatchRowsBuild()
    -- Les preparateurs de notifications (onComplete) sont independants. Seul
    -- le worker du popup ferme/remplace doit cesser de scanner/trier en arriere-plan.
    self._shardMismatchBuildToken = (tonumber(self._shardMismatchBuildToken) or 0) + 1
    self._shardMismatchBuildPending = nil
    self._shardMismatchFollowupPending = nil
end

function Overlord.UI:RequestShardMismatchRowsBuild(sourceRows, viewKey, onComplete)
    if not C_Timer or not C_Timer.After or not coroutine or not coroutine.create then return end
    local token
    if not onComplete then
        self._shardMismatchBuildToken = (tonumber(self._shardMismatchBuildToken) or 0) + 1
        token = self._shardMismatchBuildToken
    end
    local work, started = 0, 0
    local shard = Overlord.Shard
    local descriptor = type(sourceRows) == "table"
        and sourceRows._overlordShardRowSource == true and sourceRows or nil
    local peerSource = descriptor and descriptor.source
        or (not sourceRows and shard and shard.knownShards) or nil
    local peerRevision = descriptor and descriptor.getRevision
        and descriptor.getRevision() or (shard and tonumber(shard._gkPromptPeerRevision) or 0)
    local peerCount = shard and tonumber(shard.peerCount) or 0
    local sourceCount = not descriptor and type(sourceRows) == "table" and #sourceRows or 0
    local worker = coroutine.create(function()
        local rows = {}
        local scanIncomplete = false
        local meta, seen = { groupedContact = "" }, {}
        local function yieldWork()
            work = work + 1
            if work >= 64 or (debugprofilestop and debugprofilestop() - started >= 1) then
                coroutine.yield()
            end
        end
        local function consider(player, sid, isAnchor)
            player = type(player) == "string" and player or ""
            local key = string.lower(player)
            if player == "" or seen[key] then yieldWork(); return end
            seen[key] = true
            local accept, grouped = true, false
            if descriptor and descriptor.accept then
                accept, grouped = descriptor.accept(player, sid, isAnchor == true)
            else
                grouped = ShardInviteTargetAlreadyGrouped(player)
                accept = not grouped
            end
            if grouped and meta.groupedContact == "" then meta.groupedContact = player end
            if accept then
                rows[#rows + 1] = { player = player, shard = sid }
            end
            yieldWork()
        end
        if descriptor and descriptor.anchorPlayer then
            consider(descriptor.anchorPlayer, descriptor.anchorShard, true)
        end
        if not descriptor and type(sourceRows) == "table" then
            for i = 1, #sourceRows do
                local row = sourceRows[i]
                if type(row) == "table" then consider(row.player, row.shard) else yieldWork() end
            end
        elseif type(peerSource) == "table" and shard then
            local currentShard = tonumber(shard:GetCurrentShardID())
            local cursor, restarts = nil, 0
            while true do
                local ok, player, sid = pcall(next, peerSource, cursor)
                if not ok then
                    cursor, restarts = nil, restarts + 1
                    if restarts > 8 then scanIncomplete = true; break end
                    yieldWork()
                elseif player == nil then
                    break
                else
                    cursor = player
                    if not seen[string.lower(tostring(player))] then
                        local node = shard.peerNodes and shard.peerNodes[player]
                        local fresh = not node or (tonumber(node.expiresAt) or 0) > GetTime()
                        local usable = not shard.PartyInviteTargetIsUsable
                            or shard:PartyInviteTargetIsUsable(player)
                        local targetOk = not descriptor or not descriptor.targetShard
                            or tonumber(sid) == tonumber(descriptor.targetShard)
                        local differentOk = not descriptor or not descriptor.differentCurrent
                            or tonumber(sid) ~= currentShard
                        if fresh and usable and targetOk and differentOk
                            and (descriptor or tonumber(sid) ~= currentShard) then
                            consider(player, sid)
                        else
                            seen[string.lower(tostring(player))] = true
                            yieldWork()
                        end
                    else
                        yieldWork()
                    end
                end
            end
        end

        -- Merge-sort cooperatif : table.sort sur 10k lignes monopolise autrement une frame.
        local less = descriptor and descriptor.less
            or function(a, b) return self:ShardMismatchRowLess(a, b) end
        local count, width, input, output = #rows, 1, rows, {}
        while width < count do
            local first = 1
            while first <= count do
                local middle = math.min(first + width, count + 1)
                local finish = math.min(first + width * 2 - 1, count)
                local left, right, out = first, middle, first
                while left < middle or right <= finish do
                    if right > finish or (left < middle
                        and (less(input[left], input[right])
                            or not less(input[right], input[left]))) then
                        output[out], left = input[left], left + 1
                    else
                        output[out], right = input[right], right + 1
                    end
                    out = out + 1
                    yieldWork()
                end
                first = first + width * 2
            end
            input, output, width = output, input, width * 2
        end
        if input ~= rows then
            for i = 1, count do rows[i] = input[i]; yieldWork() end
        end
        return rows, scanIncomplete, meta
    end)

    local function inputChanged()
        return not descriptor and type(sourceRows) == "table" and #sourceRows ~= sourceCount
            or (descriptor and descriptor.getRevision
                and descriptor.getRevision() ~= peerRevision)
            or (not sourceRows and shard and (shard.knownShards ~= peerSource
                or tonumber(shard._gkPromptPeerRevision) ~= peerRevision
                or tonumber(shard.peerCount) ~= peerCount))
    end

    local function scheduleBoundedRetry()
        self._shardMismatchBuildPending = nil
        if onComplete then
            C_Timer.After(0.25, function()
                self:RequestShardMismatchRowsBuild(sourceRows, viewKey, onComplete)
            end)
            return
        end
        if self._shardMismatchViewKey == viewKey
            and not self._shardMismatchFollowupPending then
            self._shardMismatchFollowupPending = true
            C_Timer.After(0.25, function()
                self._shardMismatchFollowupPending = nil
                if token == self._shardMismatchBuildToken
                    and self._shardMismatchViewKey == viewKey then
                    self:RequestShardMismatchRowsBuild(sourceRows, viewKey)
                end
            end)
        end
    end

    local function runSlice()
        if not onComplete and token ~= self._shardMismatchBuildToken then return end
        -- Une revision changee entre deux tranches invalide aussi le curseur de
        -- `next`. Abandonner avant de le reutiliser evite un scan partiel et un
        -- grand nombre de redemarrages synchrones sous une rafale SH.
        if inputChanged() then
            scheduleBoundedRetry()
            return
        end
        work, started = 0, debugprofilestop and debugprofilestop() or 0
        local result = { coroutine.resume(worker) }
        if not result[1] then
            self._shardMismatchBuildPending = nil
            return
        end
        if coroutine.status(worker) ~= "dead" then C_Timer.After(0, runSlice); return end
        self._shardMismatchBuildPending = nil
        if result[3] then
            scheduleBoundedRetry()
            return
        end
        local changed = inputChanged()
        if onComplete then
            if changed then
                scheduleBoundedRetry()
                return
            end
            onComplete(result[2], result[4], changed)
            return
        end
        if self._shardMismatchViewKey == viewKey then self:ApplyShardMismatchRows(result[2], true) end
        if changed and self._shardMismatchViewKey == viewKey
            and not self._shardMismatchFollowupPending then
            self._shardMismatchFollowupPending = true
            C_Timer.After(0, function()
                self._shardMismatchFollowupPending = nil
                if self._shardMismatchViewKey == viewKey then
                    self:RequestShardMismatchRowsBuild(sourceRows, viewKey)
                end
            end)
        end
    end
    self._shardMismatchBuildPending = true
    C_Timer.After(0, runSlice)
end

-- Toutes les lignes restent accessibles dans le scroll, mais seuls les boutons du
-- viewport existent reellement. Un cache SH plein ne cree donc pas 576 frames au clic.
function Overlord.UI:RefreshShardMismatchVirtualRows()
    local rows = self._shardMismatchRows or {}
    local scroll, content = self._shardMismatchScroll, self._shardMismatchScrollChild
    if not scroll or not content then return end
    local rowH = tonumber(self._shardMismatchRowH) or 26
    local first = math.max(1, math.floor((scroll:GetVerticalScroll() or 0) / rowH) + 1)
    local tp = Overlord.UI.TooltipPalette()
    for slot = 1, (tonumber(self.SHARD_POPUP_VIRTUAL_BUTTONS) or 12) do
        local rowIndex = first + slot - 1
        local row = rows[rowIndex]
        local btn = self._shardMismatchBtns[slot]
        if row and not btn then
            btn = Overlord.UI.CreateWC3Button(
                content, self._shardMismatchBtnW or 240, self._shardMismatchBtnH or 24,
                "", nil, nil, { gold = C.gold, white = C.white })
            local wc3Enter = btn:GetScript("OnEnter")
            local wc3Leave = btn:GetScript("OnLeave")
            btn:SetScript("OnClick", function(b)
                if Overlord.InstanceSuspended or not IsShardHelperActive() then return end
                local name = b._inviteName
                if name and name ~= "" and not ShardInviteTargetAlreadyGrouped(name) then
                    if b._requestInvite then
                        RequestShardInviteFromUI(name, b._inviteShard, b._requestZoneName)
                    else
                        InviteShardPlayerFromUI(name, b._inviteShard)
                    end
                end
            end)
            btn:SetScript("OnEnter", function(b)
                if wc3Enter then wc3Enter(b) end
                GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                local palette = Overlord.UI.TooltipPalette()
                local tf = GetShardInviteTargetFaction(b._inviteName)
                local nr, ng, nb = GetShardInviteNameColor(tf)
                GameTooltip:SetText(b._inviteName, nr or palette.BODY[1],
                    ng or palette.BODY[2], nb or palette.BODY[3])
                local hint = b._requestInvite and L.SHARD_POPUP_REQUEST_HINT
                    or L.SHARD_POPUP_BTN_HINT
                GameTooltip:AddLine(hint, palette.HL[1], palette.HL[2], palette.HL[3], true)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function(b)
                if wc3Leave then wc3Leave(b) end
                GameTooltip:Hide()
            end)
            self._shardMismatchBtns[slot] = btn
        end
        if btn then
            if row then
                btn._inviteName = row.player
                btn._inviteShard = (self._shardMismatchRequestInvite
                    and self._shardMismatchTargetShard) or row.shard
                btn._requestInvite = self._shardMismatchRequestInvite == true
                btn._requestZoneName = self._shardMismatchZoneName
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4 - (rowIndex - 1) * rowH)
                if btn.SetSize then
                    btn:SetSize(self._shardMismatchBtnW or 240,
                        self._shardMismatchBtnH or 24)
                end
                ApplyShardInviteButtonLabel(btn, row.player, btn._inviteShard,
                    tp.BODY[1], tp.BODY[2], tp.BODY[3], btn._requestInvite)
                btn:Show()
            else
                btn:Hide()
            end
        end
    end
end

-- Ouvre ou rafraichit la liste des joueurs sur un autre shard (invites hors tooltip).
-- anchorFrame : badge shard si clic panneau. Sinon meme ancre que l'ouvreur badge (centre panneau).
-- opts.zoneEntry + opts.rows : popup auto a l'entree cercle (capture ennemie ou alliee, shard different).
function Overlord.UI:OpenShardMismatchPopup(anchorFrame, opts)
    RegisterShardTooltipInviteLinkHandler()
    if Overlord.InstanceSuspended or not IsShardHelperActive() then return end
    EnsureShardMismatchPopup(self)

    GameTooltip_Hide()

    opts = opts or {}
    -- Une vue rowsReady remplace aussi une ancienne construction de meme viewKey.
    -- Sans annulation, son ancien resultat pouvait ecraser les contacts deja prets.
    self:CancelShardMismatchRowsBuild()

    local f = self._shardMismatchPopup
    f._openAnchorFrame = anchorFrame

    local tp = Overlord.UI.TooltipPalette()
    self._shardMismatchHintFs:SetTextColor(tp.HL[1], tp.HL[2], tp.HL[3])

    local sourceRows
    local viewKey
    if opts.zoneEntry and opts.rows then
        local zoneTitle = opts.title
            or (opts.promptKind == "ally" and L.SHARD_POPUP_ZONE_TITLE_ALLY)
            or L.SHARD_POPUP_ZONE_TITLE
            or L.SHARD_POPUP_TITLE
        self._shardMismatchTitleFs:SetText(zoneTitle)
        if opts.subText then
            self._shardMismatchSubFs:SetText(opts.subText)
        else
            local zoneLabel = opts.zoneName or "?"
            self._shardMismatchSubFs:SetText(string.format(L.SHARD_POPUP_ZONE_SUB or L.SHARD_POPUP_YOUR_SHARD, zoneLabel))
        end
        self._shardMismatchSubFs:SetTextColor(tp.BODY[1], tp.BODY[2], tp.BODY[3])
        sourceRows = not opts.rowsReady and opts.rows or nil
        viewKey = table.concat({ "zone", tostring(opts.zoneName or ""),
            tostring(opts.targetShard or ""), tostring(opts.requestInvite == true) }, ":")
    else
        self._shardMismatchTitleFs:SetText(L.SHARD_POPUP_TITLE)
        local shardMod = Overlord.Shard
        local myShard = shardMod and shardMod:GetCurrentShardID()
        if myShard ~= nil then
            local _, referenceRealm = shardMod:GetCurrentShardReference()
            local text = referenceRealm
                and string.format(L.SHARD_POPUP_YOUR_SHARD_REFERENCE, tostring(myShard), referenceRealm)
                or string.format(L.SHARD_POPUP_YOUR_SHARD, tostring(myShard))
            self._shardMismatchSubFs:SetText(text)
            self._shardMismatchSubFs:SetTextColor(tp.BODY[1], tp.BODY[2], tp.BODY[3])
        else
            self._shardMismatchSubFs:SetText(L.SHARD_POPUP_YOUR_UNKNOWN)
            self._shardMismatchSubFs:SetTextColor(tp.HL[1], tp.HL[2], tp.HL[3])
        end
        viewKey = "all"
    end
    self._shardMismatchTitleFs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    self._shardMismatchHintFs:SetText(opts.hintText
        or (opts.requestInvite and L.SHARD_POPUP_REQUEST_HINT or L.SHARD_POPUP_BTN_HINT))

    local titleFs = self._shardMismatchTitleFs
    local subFs = self._shardMismatchSubFs
    local hintFs = self._shardMismatchHintFs
    local listPanel = self._shardMismatchListPanel
    local frameW, headerH, listTop

    if opts.zoneEntry then
        frameW = 380
        titleFs:ClearAllPoints()
        titleFs:SetPoint("TOPLEFT", f, "TOPLEFT", 36, -14)
        titleFs:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -14)
        titleFs:SetJustifyH("CENTER")
        titleFs:SetWordWrap(true)
        subFs:SetWordWrap(true)
        hintFs:SetWordWrap(true)
        f:SetWidth(frameW)
        subFs:SetWidth(frameW - 36)
        hintFs:SetWidth(frameW - 36)
        local titleH = titleFs:GetStringHeight() or 24
        local subH = subFs:GetStringHeight() or 16
        local hintH = hintFs:GetStringHeight() or 12
        subFs:ClearAllPoints()
        subFs:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -(14 + titleH + 8))
        subFs:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -(14 + titleH + 8))
        hintFs:ClearAllPoints()
        hintFs:SetPoint("TOPLEFT", subFs, "BOTTOMLEFT", 0, -8)
        hintFs:SetPoint("TOPRIGHT", subFs, "BOTTOMRIGHT", 0, -8)
        headerH = 14 + titleH + 8 + subH + 8 + hintH + 10
        listTop = headerH
    else
        frameW = 320
        titleFs:ClearAllPoints()
        titleFs:SetPoint("TOP", f, "TOP", 0, -14)
        titleFs:SetJustifyH("CENTER")
        titleFs:SetWordWrap(false)
        subFs:ClearAllPoints()
        subFs:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -46)
        subFs:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -46)
        subFs:SetJustifyH("LEFT")
        subFs:SetWordWrap(false)
        subFs:SetWidth(frameW - 36)
        hintFs:ClearAllPoints()
        hintFs:SetPoint("TOPLEFT", subFs, "BOTTOMLEFT", 0, -4)
        hintFs:SetPoint("TOPRIGHT", subFs, "BOTTOMRIGHT", 0, -4)
        hintFs:SetJustifyH("LEFT")
        hintFs:SetWordWrap(false)
        hintFs:SetWidth(frameW - 36)
        f:SetWidth(frameW)
        headerH = 88
        listTop = 88
    end

    local content = self._shardMismatchScrollChild
    -- Gouttiere droite reservee aux indicateurs de scroll (fleches haut/bas) ancrees au
    -- bord droit du scroll : sans elle, les boutons d'invite s'etendaient sous les fleches.
    local SCROLL_IND_GUTTER = 22
    local btnW, btnH, gapY = frameW - 52 - SCROLL_IND_GUTTER, 24, -26

    local sameView = self._shardMismatchViewKey == viewKey
    local rows = opts.rowsReady and opts.rows
        or (sameView and self._shardMismatchRows or {})
    self._shardMismatchViewKey = viewKey
    self._shardMismatchEmptyFs:SetTextColor(tp.MUTED[1], tp.MUTED[2], tp.MUTED[3])
    local listH = math.min(math.max(56,
        (#rows > 0 and (8 + #rows * (-gapY)) or 48) + 16), 200)
    if listPanel then
        listPanel:SetWidth(frameW - 36)
        listPanel:SetHeight(listH)
        listPanel:ClearAllPoints()
        listPanel:SetPoint("TOP", f, "TOP", 0, -listTop)
    end
    content:SetWidth(btnW)
    self._shardMismatchRows = rows
    self._shardMismatchRowH = -gapY
    self._shardMismatchBtnW = btnW
    self._shardMismatchBtnH = btnH
    self._shardMismatchRequestInvite = opts.requestInvite == true
    self._shardMismatchTargetShard = opts.targetShard
    self._shardMismatchZoneName = opts.zoneName
    self._shardMismatchEmptyText = opts.emptyText or L.SHARD_POPUP_EMPTY
    self._shardMismatchListTop = listTop
    self._shardMismatchFrameMaxH = opts.zoneEntry and 440 or 400
    pcall(function() self._shardMismatchScroll:SetVerticalScroll(0) end)
    self:ApplyShardMismatchRows(rows, false)
    if not opts.rowsReady then self:RequestShardMismatchRowsBuild(sourceRows, viewKey) end

    f._zoneEntryMode = opts.zoneEntry and true or false
    -- Popup auto (zone / fort) : notification ambiante, pas de voile plein ecran (souris, cam, sorts).
    f._nonBlocking = opts.nonBlocking == true or f._zoneEntryMode
    if f:IsShown() then
        -- Deja visible : OnShow ne se redeclenchera pas, re-appliquer modalite + ancre.
        f:ApplyShardPopupModality()
        ApplyShardPopupPosition(f)
    else
        -- Position appliquee dans OnShow (apres SetScale).
        f:Show()
    end
end

-- Layout lignes de zone (2 colonnes) - declare avant SetZoneLineWarfrontIcon / LayoutZoneLineAnchors.
local ZONE_LINE_ICON = 20
local ZONE_LINE_NORMAL_H = 24
local ZONE_LINE_ROW_GAP = 2
local ZONES_PANEL_W = 312
local ZONES_COL_PAD = 4
local ZONES_COL_GAP = 6
local ZONE_LINE_NAME_GAP = 3
local ZONE_LINE_STATUS_GAP = 4
local ZONES_CONTENT_TOP = -22
local ZONES_TRUCE_CONTENT_TOP = -38

-- Icone principale de ligne (gauche) : banniere Warfronts ou MainHall (capitales).
-- ApplyZoneMapIcon utilise useAtlasSize=true (carte) : ici taille fixe obligatoire.
local function SetZoneLineWarfrontIcon(tex, zone)
    if not tex then return end
    local Z = Overlord.Zones
    local atlas = Z and Z.GetZoneMapIconAtlas and Z:GetZoneMapIconAtlas(zone, false)
        or (Z and Z.OBJECTIVE_NEUTRAL_ATLAS) or "Warfronts-FieldMapIcons-Empty-Banner"
    if tex._zoneLineAtlas == atlas then return end
    tex._zoneLineAtlas = atlas
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetVertexColor(1, 1, 1, 1)
    if tex.SetAtlas then
        pcall(tex.SetAtlas, tex, atlas, false)
    end
    tex:SetSize(ZONE_LINE_ICON, ZONE_LINE_ICON)
end

-- Cle stable pour eviter un repaint complet de la ligne a chaque sync (timers via UpdateZoneListTimers).
local function BuildZoneLinePaintKey(z, frontOnTruce, loginPending, pf, ef)
    if loginPending then
        return "login|" .. z.id
    end
    if frontOnTruce then
        return "truce|" .. z.id
    end
    local isEnemy = z.owner and z.owner == ef
    if z.status == "in_progress" then
        return z.id .. "|ip"
    end
    if z.owner == pf then
        return z.id .. "|own|" .. pf
    end
    if isEnemy and z.status == "available" then
        return z.id .. "|eatk"
    end
    if isEnemy then
        return z.id .. "|enemy|" .. ef
    end
    if not z.owner and z.status == "available" then
        return z.id .. "|navail"
    end
    if not z.owner then
        return z.id .. "|neutral"
    end
    if z.status == "available" then
        return z.id .. "|avail"
    end
    return z.id .. "|locked"
end

-- Peinture d'une ligne de zone (partagee RefreshZoneList / survol).
local function PaintZoneLineVisual(line, z, frontOnTruce, loginPending, pf, ef, isEnemy)
    if loginPending then
        line.icon:SetDesaturated(true)
        line.icon:SetAlpha(0.65)
        line.icon:SetVertexColor(0.75, 0.75, 0.70)
        line.name:SetTextColor(C.gray[1], C.gray[2], C.gray[3])
        line.progress:SetText(L.MAP_SYNC_PENDING or "SYNC")
        line.progress:SetTextColor(C.gray[1], C.gray[2], C.gray[3], 0.85)
    elseif frontOnTruce then
        line.icon:SetDesaturated(true)
        line.icon:SetAlpha(0.65)
        line.icon:SetVertexColor(0.75, 0.75, 0.75)
        line.name:SetTextColor(C.gray[1], C.gray[2], C.gray[3])
        -- La treve concerne tout le front : son minuteur est affiche une seule fois
        -- sous le titre de la carte, pas repete sous chacune des dix zones.
        line.progress:SetText("")
        line.progress:SetTextColor(C.gray[1], C.gray[2], C.gray[3])
    elseif z.status == "in_progress" then
        line.icon:SetDesaturated(false)
        line.icon:SetAlpha(1.0)
        line.icon:SetVertexColor(1, 1, 1)
        local hr = tonumber(z.holdTimeRequired) or 0
        local he = (Overlord.Zones and Overlord.Zones.GetObserverHoldTimeElapsed)
            and Overlord.Zones:GetObserverHoldTimeElapsed(z) or (tonumber(z.holdTimeElapsed) or 0)
        local rest = math.max(0, hr - he)
        line.name:SetTextColor(C.orange[1], C.orange[2], C.orange[3])
        line.progress:SetText(string.format("%d:%02d", math.floor(rest / 60), math.floor(rest % 60)))
        line.progress:SetTextColor(C.orange[1], C.orange[2], C.orange[3])
    elseif z.owner == pf then
        line.icon:SetDesaturated(false)
        line.icon:SetAlpha(1.0)
        line.icon:SetVertexColor(1, 1, 1)
        line.name:SetTextColor(C.blueBright[1], C.blueBright[2], C.blueBright[3])
        line.progress:SetText(pf)
        line.progress:SetTextColor(C.blue[1], C.blue[2], C.blue[3], 0.7)
    elseif isEnemy and z.status == "available" then
        line.icon:SetDesaturated(false)
        line.icon:SetAlpha(1.0)
        line.icon:SetVertexColor(1, 0.5, 0.5)
        line.name:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        line.progress:SetText(L.ATTACK)
        line.progress:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    elseif isEnemy then
        line.icon:SetDesaturated(false)
        line.icon:SetAlpha(0.7)
        line.icon:SetVertexColor(0.8, 0.5, 0.5)
        line.name:SetTextColor(C.enemy[1], C.enemy[2], C.enemy[3], 0.7)
        line.progress:SetText(ef)
        line.progress:SetTextColor(C.enemy[1], C.enemy[2], C.enemy[3], 0.5)
    elseif not z.owner and z.status == "available" then
        line.icon:SetDesaturated(false)
        line.icon:SetAlpha(1.0)
        line.icon:SetVertexColor(0.88, 0.90, 0.91)
        line.name:SetTextColor(0.78, 0.80, 0.76)
        line.progress:SetText(L.MAP_AVAILABLE)
        line.progress:SetTextColor(0.62, 0.64, 0.60)
    elseif not z.owner then
        line.icon:SetDesaturated(false)
        line.icon:SetAlpha(0.88)
        line.icon:SetVertexColor(0.82, 0.84, 0.86)
        line.name:SetTextColor(0.65, 0.68, 0.70)
        line.progress:SetText(L.ZONE_NEUTRAL)
        line.progress:SetTextColor(0.55, 0.58, 0.62, 0.85)
    elseif z.status == "available" then
        line.icon:SetDesaturated(false)
        line.icon:SetAlpha(1.0)
        line.icon:SetVertexColor(1, 1, 1)
        line.name:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        line.progress:SetText(L.ATTACK)
        line.progress:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    else
        line.icon:SetDesaturated(true)
        line.icon:SetAlpha(0.5)
        line.icon:SetVertexColor(1, 1, 1)
        line.name:SetTextColor(C.gray[1], C.gray[2], C.gray[3])
        line.progress:SetText(L.LOCKED)
        line.progress:SetTextColor(C.gray[1], C.gray[2], C.gray[3], 0.5)
    end
end

local function ApplyZoneLineUnderline(line, z, loginPending)
    if line._zoneLineHover and z.status == "available" and not loginPending then
        line.icon:SetVertexColor(1.0, 1.0, 0.85)
        line.name:SetTextColor(1.0, 0.94, 0.52)
        line.underline:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.35)
    else
        line.underline:SetColorTexture(1, 1, 1, 0.06)
    end
end

-- Utilitaire : panneau sombre avec bordure doree fine (style WC3 sub-panel)
local function CreateDarkPanel(parent, w, h)
    return Overlord.UI.CreateWC3SubPanel(parent, w, h, {
        panelBg = C.panelBg,
        borderColor = C.goldDim,
        borderAlpha = 0.5,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
end

local function CreateWC3Button(parent, w, h, text, icon)
    return Overlord.UI.CreateWC3Button(parent, w, h, text, nil, icon, { gold = C.gold, white = C.white })
end

local function AttachGridButtonTooltip(btn, text)
    if Overlord.UI.AttachWC3GridButtonTooltip then
        Overlord.UI.AttachWC3GridButtonTooltip(btn, text, { gold = C.gold, white = C.white })
    end
end

-- Ancrage : une ligne (nom + statut). En treve, le statut global vit sous le titre.
local function LayoutZoneLineAnchors(line, frontOnTruce)
    if not line or not line.icon or not line.name or not line.progress then return end
    local truceLayout = frontOnTruce and true or false
    if line._layoutTruce == truceLayout then return end
    line.icon:SetSize(ZONE_LINE_ICON, ZONE_LINE_ICON)
    line.icon:ClearAllPoints()
    line.name:ClearAllPoints()
    line.progress:ClearAllPoints()
    line.name:SetWordWrap(false)
    line.name:SetMaxLines(1)
    line.progress:SetWordWrap(false)
    line.progress:SetMaxLines(1)
    if frontOnTruce then
        line.icon:SetPoint("LEFT", 0, 0)
        line.name:SetPoint("LEFT", line.icon, "RIGHT", ZONE_LINE_NAME_GAP, 0)
        line.name:SetPoint("RIGHT", line, "RIGHT", 0, 0)
        line.name:SetJustifyH("LEFT")
    else
        line.icon:SetPoint("LEFT", 0, 0)
        line.progress:SetPoint("RIGHT", 0, 0)
        line.name:SetPoint("LEFT", line.icon, "RIGHT", ZONE_LINE_NAME_GAP, 0)
        line.name:SetPoint("RIGHT", line.progress, "LEFT", -ZONE_LINE_STATUS_GAP, 0)
        line.name:SetJustifyH("LEFT")
        line.progress:SetJustifyH("RIGHT")
    end
    line._layoutTruce = frontOnTruce and true or false
end

-- Badge selecteur de front (en-tete) : largeur dynamique, vignette WarBoard, chevron menu.
local FRONT_PICKER_PAD_LEFT = 0
local FRONT_PICKER_PAD_RIGHT = 4
local FRONT_PICKER_CHEVRON = 8
local FRONT_PICKER_TEXT_GAP = 4
local FRONT_PICKER_MIN_W = 68
local FRONT_PICKER_SINGLE_H = 26
local FRONT_PICKER_TEXT_MIN_W = 30

-- Zone horizontale dans le bandeau (sans bordure bois) jusqu'au bord gauche du chevalier Alliance.
local function GetFrontPickerZoneBounds(headerBand)
    local bandW = headerBand:GetWidth() or 312
    local emblemSize, emblemGap = 48, 6
    local knightLeft = (bandW / 2) - emblemGap - emblemSize
    return 0, knightLeft
end

-- Aspect paysage du crop WarBoard (Popups.lua : 244 x 104) ; sert au rognage carre centre.
local FRONT_ART_DISPLAY_ASPECT = 244 / 104

-- Rogne le crop paysage en carre centre (largeur) sans etirer la texture.
local function SquareCropFrontArtTexCoord(tc)
    if not tc or #tc < 4 then return 0, 1, 0, 1 end
    local u1, u2, v1, v2 = tc[1], tc[2], tc[3], tc[4]
    local uSpan = u2 - u1
    local uSpanSq = uSpan / FRONT_ART_DISPLAY_ASPECT
    if uSpanSq >= uSpan then
        return u1, u2, v1, v2
    end
    local uCenter = (u1 + u2) / 2
    return uCenter - uSpanSq / 2, uCenter + uSpanSq / 2, v1, v2
end

-- Taille vignette carree, reduite si besoin pour laisser place au nom.
local function GetFrontPickerVignetteSize(btnH, maxBtnW)
    local chromeW = FRONT_PICKER_PAD_LEFT + FRONT_PICKER_TEXT_GAP + FRONT_PICKER_CHEVRON + FRONT_PICKER_PAD_RIGHT
    local maxVignetteW = maxBtnW - chromeW - FRONT_PICKER_TEXT_MIN_W
    local size = math.min(btnH - 4, 22)
    if size > maxVignetteW and maxVignetteW > 0 then
        size = math.max(12, maxVignetteW)
    end
    return size, size
end

local function ApplyFrontPickerVignette(tex, frontId)
    if not tex then return end
    local spec = Overlord.Fronts and Overlord.Fronts.GetFrontActivityIcon
        and Overlord.Fronts:GetFrontActivityIcon(frontId)
    if not spec or not spec.path then
        tex:Hide()
        tex._frontIconKey = nil
        return
    end
    local sqU1, sqU2, sqV1, sqV2 = SquareCropFrontArtTexCoord(spec.texCoord)
    local key = spec.path .. "\31" .. string.format("%.4f:%.4f:%.4f:%.4f", sqU1, sqU2, sqV1, sqV2)
    if tex._frontIconKey == key then return end
    tex._frontIconKey = key
    tex:Show()
    tex:SetVertexColor(1, 1, 1, 1)
    tex:SetTexCoord(sqU1, sqU2, sqV1, sqV2)
    if tex.SetAtlas then tex:SetAtlas(nil) end
    tex:SetTexture(spec.path)
end

local function TruncateFontStringToWidth(fs, maxW, suffix)
    if not fs or not maxW or maxW <= 0 then return end
    suffix = suffix or "..."
    local text = fs._fullText or fs:GetText() or ""
    local truncKey = text .. "\31" .. maxW
    if fs._truncKey == truncKey then return end
    fs:SetText(text)
    if (fs:GetStringWidth() or 0) <= maxW then
        fs._truncKey = truncKey
        return
    end
    local lo, hi, best = 1, #text, suffix
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local candidate = text:sub(1, mid) .. suffix
        fs:SetText(candidate)
        if (fs:GetStringWidth() or 0) <= maxW then
            best = candidate
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    fs:SetText(best)
    fs._truncKey = truncKey
end

local function CreateFrontPickerButton(parent)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn._olFrontPickerBadge = true
    btn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    btn:SetBackdropColor(0.06, 0.06, 0.10, 0.72)
    btn:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.38)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.12)
    btn:SetHighlightTexture(highlight)

    btn.vignette = btn:CreateTexture(nil, "ARTWORK")

    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.label:SetJustifyH("LEFT")
    btn.label:SetWordWrap(false)
    btn.label:SetMaxLines(1)

    btn.chevron = btn:CreateTexture(nil, "ARTWORK")
    btn.chevron:SetSize(FRONT_PICKER_CHEVRON, FRONT_PICKER_CHEVRON)
    btn.chevron:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    btn.chevron:SetVertexColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    return btn
end

function Overlord.UI:ApplyFrontPickerChrome(btn, readonly, menuOpen)
    if not btn then return end
    readonly = readonly and true or false
    menuOpen = menuOpen and true or false
    local chromeKey = (readonly and "1" or "0") .. "|" .. (menuOpen and "1" or "0")
    if btn._chromeKey == chromeKey then return end
    btn._chromeKey = chromeKey
    if menuOpen then
        btn:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 0.85)
        btn:SetBackdropColor(0.10, 0.10, 0.14, 0.82)
    elseif readonly then
        btn:SetBackdropBorderColor(0.82, 0.65, 0.28, 0.52)
        btn:SetBackdropColor(0.08, 0.07, 0.05, 0.78)
    else
        btn:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.38)
        btn:SetBackdropColor(0.06, 0.06, 0.10, 0.72)
    end
    if btn.vignette then
        btn.vignette:SetAlpha(readonly and 0.78 or 1)
    end
    if btn.label then
        if readonly then
            btn.label:SetTextColor(0.95, 0.88, 0.65)
        else
            btn.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        end
    end
    if btn.chevron then
        local c = menuOpen and C.gold or C.goldDim
        btn.chevron:SetVertexColor(c[1], c[2], c[3])
    end
end

-- Vignette + libelle + chevron ; largeur selon le nom, plafonnee avant les emblemes.
function Overlord.UI:LayoutFrontPickerButton()
    local btn = self.frontPickerBtn
    if not btn or not btn.label then return end
    local band = self.headerBand
    local zoneLeft, zoneRight = GetFrontPickerZoneBounds(band)
    local maxW = math.max(FRONT_PICKER_MIN_W, math.floor(zoneRight - zoneLeft - 4))
    local readonly = self:IsFrontPanelReadOnly()
    local menuOpen = btn._olPanelOpenState == true
    local layoutKey = (btn._fullLabel or "") .. "|" .. maxW .. "|"
        .. (readonly and "1" or "0") .. "|" .. (menuOpen and "1" or "0")
    if btn._layoutKey == layoutKey then return end
    btn._layoutKey = layoutKey
    local btnH = FRONT_PICKER_SINGLE_H
    local vignetteW, vignetteH = GetFrontPickerVignetteSize(btnH, maxW)
    local fixedW = FRONT_PICKER_PAD_LEFT + vignetteW + FRONT_PICKER_TEXT_GAP
        + FRONT_PICKER_CHEVRON + FRONT_PICKER_PAD_RIGHT
    local textMaxW = maxW - fixedW

    btn.label._fullText = btn._fullLabel or btn.label:GetText() or "?"
    TruncateFontStringToWidth(btn.label, textMaxW)

    local textW = btn.label:GetStringWidth() or 0
    local btnW = math.min(maxW, math.max(FRONT_PICKER_MIN_W, fixedW + math.ceil(textW)))
    btn:SetSize(btnW, btnH)

    btn.vignette:SetSize(vignetteW, vignetteH)
    btn.vignette:ClearAllPoints()
    btn.vignette:SetPoint("LEFT", btn, "LEFT", FRONT_PICKER_PAD_LEFT, 0)
    btn.label:ClearAllPoints()
    btn.chevron:ClearAllPoints()
    btn.label:SetPoint("LEFT", btn.vignette, "RIGHT", FRONT_PICKER_TEXT_GAP, 0)
    btn.label:SetPoint("TOP", btn, "TOP", 0, 0)
    btn.label:SetPoint("BOTTOM", btn, "BOTTOM", 0, 0)
    btn.chevron:SetPoint("RIGHT", btn, "RIGHT", -FRONT_PICKER_PAD_RIGHT, 0)

    btn._readonlyChrome = readonly
    self:ApplyFrontPickerChrome(btn, readonly, btn._olPanelOpenState)

    local emblemSize = 48
    local fpTopY = -5 - math.floor((emblemSize - btnH) / 2)
    local centerX = (zoneLeft + zoneRight) / 2
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", band, "TOPLEFT", math.floor(centerX - btnW / 2), fpTopY)
end

-- Indique si le joueur a manuellement deplace le panel (= position custom a respecter)
local userMovedPanel = false

-- Echelle du panneau principal + classement (0.8-1.2, 1 au centre du curseur)
local UI_SCALE_MIN = 0.8
local UI_SCALE_MAX = 1.2

function Overlord.UI:GetEffectiveUiScale()
    local s = (OverlordDB and OverlordDB.config and tonumber(OverlordDB.config.uiScale)) or 1.0
    if s < UI_SCALE_MIN then s = UI_SCALE_MIN end
    if s > UI_SCALE_MAX then s = UI_SCALE_MAX end
    return math.floor(s * 10 + 0.5) / 10
end

function Overlord.UI:ApplyUiScale()
    if not mainFrame then return end
    local sc = self:GetEffectiveUiScale()
    mainFrame:SetScale(sc)
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.ApplyFrameScale then
        Overlord.LeaderboardUI:ApplyFrameScale(sc)
    end
end

function Overlord.UI:UpdateUiScaleSlider()
    if Overlord.SettingsPanel and Overlord.SettingsPanel.SyncUiScaleWithSettingsAPI then
        Overlord.SettingsPanel:SyncUiScaleWithSettingsAPI()
    end
end

-- Sauvegarde position comme Classic Quest Log : GetLeft/GetBottom en espace UIParent.
-- GetLeft() renvoie des coords dans l'espace du parent, mais il faut corriger si le panel a
-- un scale != 1, car la position visuelle reelle est GetLeft() * frameScale.
-- La sauvegarde reste en coordonnees UIParent, independamment de l'echelle du panneau.
local function SaveFramePosition()
    if not mainFrame then return end
    mainFrame:SetUserPlaced(true)
    if not OverlordDB then return end
    local left, bottom = mainFrame:GetLeft(), mainFrame:GetBottom()
    if left == nil or bottom == nil then return end
    local frameScale = mainFrame:GetScale()
    if frameScale and frameScale ~= 1 and frameScale > 0 then
        -- Convertit en coordonnees UIParent ; RestoreFramePosition fait l'inverse.
        left   = left   * frameScale
        bottom = bottom * frameScale
    end
    OverlordDB.panelAnchor = { left = left, bottom = bottom }
    OverlordDB.panelPos = nil
end

-- Restaure la position sauvegardee (meme convention que Classic Quest Log : BOTTOMLEFT UIParent)
local function RestoreFramePosition()
    if not mainFrame or not OverlordDB then return false end
    local a = OverlordDB.panelAnchor
    -- Migration : anciennes saves panelPos.x/y = left*uiScale, bottom*uiScale
    if not a and OverlordDB.panelPos then
        local px = OverlordDB.panelPos
        if type(px.x) == "number" and type(px.y) == "number" then
            local uiScale = UIParent:GetEffectiveScale()
            a = { left = px.x / uiScale, bottom = px.y / uiScale }
            OverlordDB.panelAnchor = a
            OverlordDB.panelPos = nil
        end
    end
    if not a or type(a.left) ~= "number" or type(a.bottom) ~= "number" then return false end
    mainFrame:ClearAllPoints()
    Overlord.UI:ApplyUiScale()
    local scale = mainFrame:GetScale()
    mainFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", a.left / scale, a.bottom / scale)
    mainFrame:SetUserPlaced(true)
    return true
end

function Overlord.UI:Initialize()
    if mainFrame then return end
    C = (Overlord.PlayerFaction == "Horde") and C_HORDE or C_ALLIANCE
    self:CreateMainFrame()
    -- Restaure la position sauvegardee si le joueur avait deplace le panel (ou migration panelPos)
    if OverlordDB and (OverlordDB.panelAnchor or OverlordDB.panelPos) then
        if RestoreFramePosition() then
            userMovedPanel = true
        end
    end
    if userMovedPanel then SaveFramePosition() end
end

-- Ancrage initial : carte ouverte a droite de la map, sinon bord droit ecran.
-- Plus de scale auto selon la hauteur de la map (mode reduit) : le panel reste a l'echelle 1,
-- comme un cadre classique (Classic Quest Log ne redimensionne pas selon la carte).
function Overlord.UI:UpdatePanelAnchor()
    if not mainFrame then return end

    -- Position manuelle : ne pas re-ancrer (hooks carte / Show ne doivent pas deplacer le panel)
    if userMovedPanel or mainFrame:IsUserPlaced() then
        userMovedPanel = true
        return
    end

    mainFrame:SetScale(1)
    mainFrame:ClearAllPoints()
    if WorldMapFrame and WorldMapFrame:IsVisible() then
        local isMax = WorldMapFrame.IsMaximized and WorldMapFrame:IsMaximized()
        if isMax then
            mainFrame:SetPoint("RIGHT", WorldMapFrame, "RIGHT", -20, 0)
        else
            mainFrame:SetPoint("LEFT", WorldMapFrame, "RIGHT", 4, 0)
        end
    else
        mainFrame:SetPoint("RIGHT", UIParent, "RIGHT", -120, 0)
    end
    self:ApplyUiScale()
end
local worldMapPanelRetryFrame
local worldMapPanelFrameHooked = false
local worldMapMaximizeHooked = false
local worldMapMinimizeHooked = false

local function ReanchorPanelForWorldMap()
    if Overlord.InstanceSuspended then return end
    if Overlord.UI and Overlord.UI.UpdatePanelAnchor then
        Overlord.UI:UpdatePanelAnchor()
    end
end

local function InstallWorldMapPanelHooks()
    if not WorldMapFrame then return false end
    if not worldMapPanelFrameHooked then
        worldMapPanelFrameHooked = true
        WorldMapFrame:HookScript("OnShow", ReanchorPanelForWorldMap)
        WorldMapFrame:HookScript("OnHide", ReanchorPanelForWorldMap)
        WorldMapFrame:HookScript("OnSizeChanged", ReanchorPanelForWorldMap)
    end
    local mmf = WorldMapFrame.MaximizeMinimizeFrame
    if mmf and mmf.MaximizeButton and not worldMapMaximizeHooked then
        worldMapMaximizeHooked = true
        mmf.MaximizeButton:HookScript("OnClick", ReanchorPanelForWorldMap)
    end
    if mmf and mmf.MinimizeButton and not worldMapMinimizeHooked then
        worldMapMinimizeHooked = true
        mmf.MinimizeButton:HookScript("OnClick", ReanchorPanelForWorldMap)
    end
    return true
end

local function EnsureWorldMapPanelHooks()
    if InstallWorldMapPanelHooks() then
        if worldMapPanelRetryFrame then
            worldMapPanelRetryFrame:UnregisterEvent("ADDON_LOADED")
        end
        return
    end
    if worldMapPanelRetryFrame then return end
    worldMapPanelRetryFrame = CreateFrame("Frame")
    worldMapPanelRetryFrame:RegisterEvent("ADDON_LOADED")
    worldMapPanelRetryFrame:SetScript("OnEvent", function()
        InstallWorldMapPanelHooks()
        if WorldMapFrame then
            worldMapPanelRetryFrame:UnregisterEvent("ADDON_LOADED")
        end
    end)
end

function Overlord.UI:CreateMainFrame()
    RegisterShardTooltipInviteLinkHandler()
    mainFrame = mainFrameShell
    userMovedPanel = mainFrame:IsUserPlaced()
    -- Largeur fixe. Hauteur initiale : sera recalculée par ApplyCommunityHintLayout (plus de vide sous la progression).
    mainFrame:SetSize(340, 520)
    self:ApplyUiScale()
    self:UpdatePanelAnchor()

    -- Re-ancre le panel quand la carte s'ouvre/ferme/resize. Blizzard_WorldMap est
    -- charge a la demande sur certains clients : ADDON_LOADED rattrape ce cas.
    EnsureWorldMapPanelHooks()
    C_Timer.After(1, EnsureWorldMapPanelHooks)
    -- Fond type bois (UIShared.lua)
    Overlord.UI.ApplyWoodDialogBackdrop(mainFrame, {
        fallbackBg = C.bg,
        borderColor = C.gold,
        borderAlpha = 0.8,
    })
    Overlord.UI.ApplyPerksHordeVsAllianceChrome(mainFrame, {
        topOverhangSide = 6,
        bottomOverhangSide = 4,
        topOverlap = 39,
        bottomOverlap = 74,
        alpha = 1,
    })
    mainFrame:EnableMouse(true)
    mainFrame:SetMovable(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", function(self)
        userMovedPanel = true
        self:StartMoving()
    end)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        userMovedPanel = true
        SaveFramePosition()
    end)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetClampedToScreen(true)

    -- Titre principal : police Fancy* (style fantasy / titres WoW), pas GameFont sans-serif.
    local title = mainFrame:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    title:SetPoint("TOP", 0, -31)
    title:SetText("Overlord")
    title:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    mainFrame.titleFs = title

    local versionFs = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionFs:SetPoint("LEFT", title, "RIGHT", 6, -4)
    versionFs:SetJustifyH("LEFT")
    local addonVer = Overlord and Overlord.Version
    versionFs:SetText(addonVer and ("v" .. addonVer) or "")
    versionFs:SetTextColor(C.gold[1] * 0.55, C.gold[2] * 0.55, C.gold[3] * 0.55)
    mainFrame.versionFs = versionFs
    self.versionFs = versionFs

    -- Bandeau d'en-tete : selecteur de front (coin), portraits A/H, statuts.
    local emblemSize = 48
    local emblemGap = 6

    local headerBand = CreateFrame("Frame", nil, mainFrame)
    headerBand:SetSize(312, 66)
    headerBand:SetPoint("TOP", mainFrame, "TOP", 0, -50)
    self.headerBand = headerBand

    local emblemCluster = CreateFrame("Frame", nil, headerBand)
    emblemCluster:SetSize(emblemSize * 2 + emblemGap, emblemSize)
    emblemCluster:SetPoint("TOP", headerBand, "TOP", 0, -5)
    self.emblemCluster = emblemCluster

    local texPath = "Interface\\AddOns\\Overlord\\Textures\\"

    local knightTex = emblemCluster:CreateTexture(nil, "ARTWORK", nil, 0)
    knightTex:SetSize(emblemSize, emblemSize)
    knightTex:SetPoint("RIGHT", emblemCluster, "CENTER", -emblemGap, 0)
    knightTex:SetTexture(texPath .. "knight")
    knightTex:SetAlpha(0.6)

    local knightMask = emblemCluster:CreateMaskTexture()
    knightMask:SetPoint("TOPLEFT", knightTex, "TOPLEFT", -6, 6)
    knightMask:SetPoint("BOTTOMRIGHT", knightTex, "BOTTOMRIGHT", 6, -6)
    knightMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    knightTex:AddMaskTexture(knightMask)
    self.knightTex = knightTex

    local gruntTex = emblemCluster:CreateTexture(nil, "ARTWORK", nil, 0)
    gruntTex:SetSize(emblemSize, emblemSize)
    gruntTex:SetPoint("LEFT", emblemCluster, "CENTER", emblemGap, 0)
    gruntTex:SetTexture(texPath .. "grunt")
    gruntTex:SetAlpha(0.6)

    local gruntMask = emblemCluster:CreateMaskTexture()
    gruntMask:SetPoint("TOPLEFT", gruntTex, "TOPLEFT", -6, 6)
    gruntMask:SetPoint("BOTTOMRIGHT", gruntTex, "BOTTOMRIGHT", 6, -6)
    gruntMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    gruntTex:AddMaskTexture(gruntMask)
    self.gruntTex = gruntTex

    -- Selecteur de front : badge leger coin haut-gauche (hors titre centre / emblemes).
    self.frontPickerBtn = CreateFrontPickerButton(headerBand)
    self.frontPickerBtn:SetScript("OnClick", function(btn)
        Overlord.UI:OpenFrontPickerMenu(btn)
    end)
    self.frontPickerBtn:SetScript("OnEnter", function(btn)
        btn:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 0.75)
        if btn.label then
            btn.label:SetTextColor(C.white[1], C.white[2], C.white[3])
        end
        GameTooltip:SetOwner(btn, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("BOTTOMLEFT", btn, "TOPLEFT", 0, 8)
        GameTooltip:SetText(L.UI_FRONT_SELECT, 1, 1, 1)
        GameTooltip:AddLine(L.UI_FRONT_PICKER_TOOLTIP, nil, nil, nil, true)
        if btn._fullLabel and btn._fullLabel ~= (btn.label and btn.label:GetText()) then
            GameTooltip:AddLine(btn._fullLabel, 0.85, 0.85, 0.85, true)
        end
        if Overlord.UI:IsFrontPanelReadOnly() then
            GameTooltip:AddLine(L.UI_FRONT_READONLY_TOOLTIP, 0.9, 0.75, 0.45, true)
        end
        GameTooltip:Show()
    end)
    self.frontPickerBtn:SetScript("OnLeave", function(btn)
        Overlord.UI:ApplyFrontPickerChrome(btn, btn._readonlyChrome, btn._olPanelOpenState)
        GameTooltip_Hide()
    end)

    self.frontReadOnlyLabel = headerBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.frontReadOnlyLabel:SetPoint("TOP", emblemCluster, "BOTTOM", 0, -2)
    self.frontReadOnlyLabel:SetWidth(280)
    self.frontReadOnlyLabel:SetJustifyH("CENTER")
    self.frontReadOnlyLabel:SetWordWrap(false)
    self.frontReadOnlyLabel:SetMaxLines(1)
    self.frontReadOnlyLabel:SetTextColor(0.92, 0.78, 0.42, 0.95)
    self.frontReadOnlyLabel:Hide()

    local forcesText = headerBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    forcesText:SetPoint("TOP", emblemCluster, "BOTTOM", 0, -2)
    forcesText:SetWidth(280)
    forcesText:SetJustifyH("CENTER")
    forcesText:SetTextColor(0.85, 0.75, 0.45, 0.9)
    forcesText:SetText("")
    self.forcesText = forcesText

    -- Indicateur de shard : coin haut-gauche du panneau (hors titre centre).
    local SHARD_BADGE_ICON = 14
    local SHARD_BADGE_TEXT = 11
    local SHARD_BADGE_REALM = 10
    local shardFrame = CreateFrame("Button", nil, mainFrame)
    shardFrame:SetSize(40, 20)
    shardFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 12, -24)
    do
        local ntex = shardFrame:CreateTexture()
        ntex:SetColorTexture(0, 0, 0, 0)
        ntex:SetAllPoints(shardFrame)
        shardFrame:SetNormalTexture(ntex)
        local htex = shardFrame:CreateTexture()
        htex:SetColorTexture(0.45, 0.62, 0.88, 0.14)
        htex:SetAllPoints(shardFrame)
        shardFrame:SetHighlightTexture(htex)
        shardFrame:SetPushedTexture(ntex)
    end
    local shardIcon = shardFrame:CreateTexture(nil, "ARTWORK")
    shardIcon:SetSize(SHARD_BADGE_ICON, SHARD_BADGE_ICON)
    shardIcon:SetPoint("LEFT", 0, 0)
    shardIcon:SetTexture("Interface\\Icons\\Spell_Arcane_PortalShattrath")
    shardIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    shardIcon:SetVertexColor(0.7, 0.85, 1.0, 0.9)
    local shardText = shardFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    shardText:SetPoint("LEFT", shardIcon, "RIGHT", 4, 0)
    shardText:SetTextColor(0.65, 0.75, 0.85, 0.9)
    shardText:SetFont(shardText:GetFont(), SHARD_BADGE_TEXT)
    shardText:SetText("")
    local shardRealmText = shardFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Sous l'icone portail (pas sous #66) : evite le debordement dans la bordure gauche.
    shardRealmText:SetPoint("TOPLEFT", shardIcon, "BOTTOMLEFT", 0, -1)
    shardRealmText:SetJustifyH("LEFT")
    shardRealmText:SetTextColor(0.55, 0.65, 0.78, 0.9)
    shardRealmText:SetFont(shardRealmText:GetFont(), SHARD_BADGE_REALM)
    shardRealmText:SetText("")
    shardRealmText:Hide()
    shardFrame:Hide()
    shardFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local tp = Overlord.UI.TooltipPalette()
        GameTooltip:AddLine(L.SHARD_TOOLTIP_TITLE, tp.HL[1], tp.HL[2], tp.HL[3])
        GameTooltip:AddLine(L.SHARD_TOOLTIP_CLICK_OPEN, tp.HL[1], tp.HL[2], tp.HL[3], true)
        GameTooltip:AddLine(" ", tp.BODY[1], tp.BODY[2], tp.BODY[3])
        local shardMod = Overlord.Shard
        local shardID = shardMod and shardMod:GetCurrentShardID()
        if shardID ~= nil then
            GameTooltip:AddLine(string.format(L.SHARD_TOOLTIP_CURRENT, tostring(shardID)), tp.BODY[1], tp.BODY[2], tp.BODY[3], true)
            local referencePlayer = shardMod:GetCurrentShardReference()
            if referencePlayer then
                GameTooltip:AddLine(string.format(L.SHARD_TOOLTIP_REFERENCE_REALM, referencePlayer), tp.MUTED[1], tp.MUTED[2], tp.MUTED[3], true)
            end
            GameTooltip:AddLine(" ", tp.BODY[1], tp.BODY[2], tp.BODY[3])
            local count, preview, inspected = 0, {}, 0
            local node = shardMod.peerTail
            local previewMax = tonumber(Overlord.UI.SHARD_TOOLTIP_PLAYER_MAX) or 12
            local scanMax = tonumber(Overlord.UI.SHARD_TOOLTIP_SCAN_MAX) or 48
            while node and inspected < scanMax and #preview < previewMax do
                local player = node.key
                local sid = player and shardMod.knownShards[player]
                inspected = inspected + 1
                if player and sid ~= nil and (tonumber(node.expiresAt) or 0) > GetTime()
                    and tonumber(sid) ~= tonumber(shardID)
                    and (not shardMod.PartyInviteTargetIsUsable
                        or shardMod:PartyInviteTargetIsUsable(player))
                    and not ShardInviteTargetAlreadyGrouped(player) then
                    count = count + 1
                    preview[#preview + 1] = { player = player, shard = sid }
                end
                node = node.prev
            end
            if count > 0 then
                GameTooltip:AddLine(L.SHARD_TOOLTIP_PLAYERS_HEADER, tp.HL[1], tp.HL[2], tp.HL[3])
                for _, row in ipairs(preview) do
                    local player, sid = row.player, row.shard
                    local colorEsc = GetShardInviteNameColorEscape(GetShardInviteTargetFaction(player))
                    local hl = Overlord.Shard and Overlord.Shard.BuildInviteHyperlink
                        and Overlord.Shard:BuildInviteHyperlink(player, colorEsc) or player
                    GameTooltip:AddLine(string.format("  %s (%s)", hl, BuildShardDisplayTag(sid)), tp.MUTED[1], tp.MUTED[2], tp.MUTED[3])
                end
                if node then
                    GameTooltip:AddLine("  ...", tp.MUTED[1], tp.MUTED[2], tp.MUTED[3])
                end
                GameTooltip:AddLine(" ", tp.BODY[1], tp.BODY[2], tp.BODY[3])
                GameTooltip:AddLine(L.SHARD_TOOLTIP_INVITE_RAID, tp.MUTED[1], tp.MUTED[2], tp.MUTED[3], true)
                GameTooltip:AddLine(L.SHARD_TOOLTIP_CLICK_INVITE, tp.HL[1], tp.HL[2], tp.HL[3], true)
            elseif node then
                -- Apercu volontairement borne; le clic ouvre toujours la liste complete
                -- construite par la coroutine, donc aucun contact n'est inaccessible.
                GameTooltip:AddLine("  ...", tp.MUTED[1], tp.MUTED[2], tp.MUTED[3])
            else
                GameTooltip:AddLine(L.SHARD_TOOLTIP_ALL_SAME, tp.BODY[1], tp.BODY[2], tp.BODY[3])
            end
        else
            GameTooltip:AddLine(L.SHARD_TOOLTIP_UNDETECTED, tp.MUTED[1], tp.MUTED[2], tp.MUTED[3], true)
        end
        GameTooltip:Show()
    end)
    shardFrame:SetScript("OnLeave", GameTooltip_Hide)
    shardFrame:EnableMouse(true)
    shardFrame:RegisterForClicks("LeftButtonUp")
    shardFrame:SetScript("OnClick", function(sf)
        if Overlord.UI and Overlord.UI.OpenShardMismatchPopup then
            Overlord.UI:OpenShardMismatchPopup(sf)
        end
    end)
    self.shardFrame = shardFrame
    self.shardText = shardText
    self.shardRealmText = shardRealmText
    self.shardIcon = shardIcon
    self.shardBadgeIconSize = SHARD_BADGE_ICON

    self:CreateZoneListSection(mainFrame)
    self:CreateActiveZoneSection(mainFrame)
    self:SyncFrontPickerButtonText()
    self:SyncHeaderLayout()
    lastCommunityLayoutKey = nil
    self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)

    -- Bouton fermer WC3
    Overlord.UI.CreateWC3CloseButton(mainFrame, function() Overlord.UI:Hide() end, { gold = C.gold })
        :SetPoint("TOPRIGHT", 4, -4)

    if Overlord.Popups and Overlord.Popups.SyncFeaturedFrontDock then
        Overlord.Popups:SyncFeaturedFrontDock()
    end

    -- Panel persistent : Echap ne ferme pas le panel (carte de campagne, pas un popup)
    mainFrame:Hide()
end

-- Variables partagees entre CreateZoneListSection, ApplyCommunityHintLayout et RefreshCommunityButton
local communityBtn = nil
local communityHintLabel = nil
local communityHintSubLabel = nil
local communityHintPanel = nil
local communityHintIcon = nil
local communityHintCta = nil
local communitySuccessUntil = 0
local COMMUNITY_CLUB_POLL_INTERVAL = 10
local COMMUNITY_STATS_INTERVAL = 5
local lastCommunityClubPollAt = 0
local cachedCommunityClubId = nil
local lastCommunityStatsAt = 0
local cachedCommunityOnline = nil
local communityMembershipEventFrame = nil
local communityMembershipRefreshPending = false
local GK_HUD_REFRESH_INTERVAL = 15
local lastGkHudRefreshAt = 0
local lastMainFrameHeight = nil
local lastForcesAnchorMode = nil
local lastFrontEmblemKey = nil
local lastActiveZoneStatusKey = nil
local lastActiveZoneTimerAt = 0
local ACTIVE_ZONE_TIMER_INTERVAL = 1.0
local cachedRefreshActiveZone = nil
local cachedRefreshActiveZoneAt = 0
local REFRESH_ACTIVE_ZONE_LOOKUP_SEC = 1.0
local lastShardScanFromUiAt = 0
local SHARD_UI_SCAN_INTERVAL = 3.0
-- Au login C_Club n'est pas charge immediatement : on bloque l'affichage du panneau rouge pendant 3 s
-- pour eviter le flash parasite chez les membres. Les non-membres verront le panneau apres ce delai.
local communityCheckReady = false

-- Libelle court du bouton choix de front (dropdown).
local function FrontPickerDropdownLabel(front)
    return (front and (front.dropdownLabel or front.mapName)) or "?"
end

-- Front affiche dans le panneau (consultation d'un autre front possible).
function Overlord.UI:GetPanelViewFrontId()
    if not Overlord.Fronts then return nil end
    if OverlordDB then
        OverlordDB.config = OverlordDB.config or {}
    end
    local sel = OverlordDB and OverlordDB.config and OverlordDB.config.uiPanelFrontId
    if sel and Overlord.Fronts:GetFront(sel) then
        return sel
    end
    return Overlord.Fronts.activeFrontId
end

-- Lecture seule : carte liste != carte de combat, ou hors front (pas de capture).
function Overlord.UI:IsFrontPanelReadOnly()
    if not Overlord.Fronts then return true end
    if not Overlord.InActiveFront then return true end
    return self:GetPanelViewFrontId() ~= Overlord.Fronts.activeFrontId
end

function Overlord.UI:SyncFrontPickerButtonText()
    local btn = self.frontPickerBtn
    if not btn then return end
    local order = Overlord.Fronts and Overlord.Fronts.Order or {}
    local orderCount = #order
    local shouldShow = orderCount > 1
    if OverlordDB then OverlordDB.config = OverlordDB.config or {} end
    local fid = self:GetPanelViewFrontId()
    local fr = Overlord.Fronts and Overlord.Fronts:GetFront(fid)
    local label = FrontPickerDropdownLabel(fr)
    local readonly = self:IsFrontPanelReadOnly()
    local syncKey = tostring(fid) .. "|" .. label .. "|" .. orderCount .. "|" .. (readonly and 1 or 0)
    if btn._pickerSyncKey == syncKey and btn:IsShown() == shouldShow then return end
    btn._pickerSyncKey = syncKey
    btn._fullLabel = label
    if shouldShow then
        btn:Show()
    else
        btn:Hide()
    end
    if btn.vignette then
        ApplyFrontPickerVignette(btn.vignette, fid)
    end
    btn._layoutKey = nil
    self:LayoutFrontPickerButton()
    if self.frontReadOnlyLabel then
        self.frontReadOnlyLabel:Hide()
    end
end

-- Hauteur du bandeau d'en-tete et ancrage de la liste de zones.
function Overlord.UI:SyncHeaderLayout()
    local band = self.headerBand
    if not band then return end
    local h = 66
    band:SetHeight(h)
    if self.forcesText then
        local anchorMode = self.emblemCluster and "emblem" or "fallback"
        if anchorMode ~= lastForcesAnchorMode then
            lastForcesAnchorMode = anchorMode
            self.forcesText:ClearAllPoints()
            if anchorMode == "emblem" then
                self.forcesText:SetPoint("TOP", self.emblemCluster, "BOTTOM", 0, -2)
            else
                self.forcesText:SetPoint("TOP", band, "TOP", 0, -56)
            end
            self.forcesText:SetWidth(280)
            self.forcesText:SetJustifyH("CENTER")
        end
    end
    if h ~= lastHeaderBandHeight then
        lastHeaderBandHeight = h
        if zoneListFrame and mainFrame then
            zoneListFrame:ClearAllPoints()
            zoneListFrame:SetPoint("TOP", band, "BOTTOM", 0, -6)
        end
        self:SyncMainFrameHeight()
    end
end

-- WoW 11+ : EasyMenu supprime - MenuUtil.CreateContextMenu ; secours : popup locale.
function Overlord.UI:OpenFrontPickerMenu(anchor)
    if not anchor or not Overlord.Fronts then return end
    local order = Overlord.Fronts.Order or {}
    if #order <= 1 then return end

    if MenuUtil and MenuUtil.CreateContextMenu then
        local ok = pcall(function()
            MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
                for _, fid in ipairs(order) do
                    local fr = Overlord.Fronts:GetFront(fid)
                    if fr then
                        rootDescription:CreateButton(FrontPickerDropdownLabel(fr), function()
                            if OverlordDB then
                                OverlordDB.config = OverlordDB.config or {}
                                OverlordDB.config.uiPanelFrontId = fid
                            end
                            if Overlord.Sync and Overlord.Sync.RequestConsultFrontSync then
                                Overlord.Sync:RequestConsultFrontSync(fid)
                            end
                            if Overlord.CheckActiveFrontZone then
                                Overlord:CheckActiveFrontZone()
                            end
                            self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
                            self:Refresh()
                        end)
                    end
                end
            end)
        end)
        if ok then return end
    end

    self:OpenFrontPickerMenuFallback(anchor)
end

function Overlord.UI:OpenFrontPickerMenuFallback(anchor)
    if not self._frontPickerPopup then
        local f = CreateFrame("Frame", "OverlordFrontPickerPopup", UIParent, "BackdropTemplate")
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile     = true, tileSize = 16, edgeSize = 12,
            insets   = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0.08, 0.08, 0.1, 0.97)
        f:SetBackdropBorderColor(0.55, 0.48, 0.35, 0.9)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(5000)
        f:EnableMouse(true)
        f:Hide()
        self._frontPickerPopup = f
        self._frontPickerPopupButtons = {}

        local blocker = CreateFrame("Button", nil, UIParent)
        blocker:SetFrameStrata("FULLSCREEN_DIALOG")
        blocker:SetFrameLevel(4998)
        blocker:SetAllPoints(UIParent)
        blocker:EnableMouse(true)
        blocker:Hide()
        blocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        blocker:SetScript("OnClick", function()
            if self._frontPickerPopup then self._frontPickerPopup:Hide() end
            blocker:Hide()
        end)
        self._frontPickerPopupBlocker = blocker
        f:SetScript("OnShow", function()
            if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
            if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
                Overlord.UI:ScheduleActionGridActiveRefresh()
            end
        end)
        f:SetScript("OnHide", function()
            if self._frontPickerPopupBlocker then self._frontPickerPopupBlocker:Hide() end
            if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
            if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
                Overlord.UI:ScheduleActionGridActiveRefresh()
            end
        end)
    end

    for _, b in ipairs(self._frontPickerPopupButtons) do
        b:Hide()
    end
    local f = self._frontPickerPopup
    local y = -8
    local count = 0
    for _, fid in ipairs(Overlord.Fronts.Order or {}) do
        local fr = Overlord.Fronts:GetFront(fid)
        if fr then
            count = count + 1
            local row = self._frontPickerPopupButtons[count]
            if not row then
                row = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
                row:SetSize(100, 20)
                self._frontPickerPopupButtons[count] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f, "TOPLEFT", 8, y)
            y = y - 24
            row:SetText(FrontPickerDropdownLabel(fr))
            row:Show()
            row:SetScript("OnClick", function()
                f:Hide()
                if OverlordDB then
                    OverlordDB.config = OverlordDB.config or {}
                    OverlordDB.config.uiPanelFrontId = fid
                end
                if Overlord.Sync and Overlord.Sync.RequestConsultFrontSync then
                    Overlord.Sync:RequestConsultFrontSync(fid)
                end
                if Overlord.CheckActiveFrontZone then
                    Overlord:CheckActiveFrontZone()
                end
                self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
                self:ForceZoneListRefresh()
                self:Refresh()
            end)
        end
    end
    if count == 0 then return end
    f:SetSize(116, 14 + count * 24)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
    if self._frontPickerPopupBlocker then self._frontPickerPopupBlocker:Show() end
    f:Show()
end

-- ---------- Section liste des zones ----------
function Overlord.UI:CreateZoneListSection(parent)
    zoneListFrame = CreateFrame("Frame", nil, parent)
    -- +16px : bandeau rouge hors-communaute sous les boutons Classement / Communaute
    -- Hauteur initiale provisoire, sera recalee par ApplyCommunityHintLayout
    zoneListFrame:SetSize(320, 330)
    if self.headerBand then
        zoneListFrame:SetPoint("TOP", self.headerBand, "BOTTOM", 0, -6)
    else
        zoneListFrame:SetPoint("TOP", parent, "TOP", 0, -108)
    end

    -- Grille d'actions placee sous l'etat du front par ApplyCommunityHintLayout.
    local ACTIONS_CARD_W = 304
    local btnWidth = 145
    local btnHeight = 28
    local btnGapX = 6
    local btnGapY = 6
    local gridRow0Gap = 6
    local gridRowGap = 3
    local btnRows = 5
    local gridPadTop = 8
    local gridPadBottom = 6
    local actionsCardH = gridPadTop + btnRows * btnHeight
        + gridRow0Gap + (btnRows - 2) * gridRowGap + gridPadBottom

    local actionsCard = CreateDarkPanel(zoneListFrame, ACTIONS_CARD_W, actionsCardH)
    actionsCard:SetPoint("TOP", zoneListFrame, "TOP", 0, -220)
    zoneListFrame.actionsCard = actionsCard
    self.actionsCard = actionsCard

    local gridTop = -gridPadTop
    zoneListFrame._actionGridBottom = actionsCardH + 4
    local function ActionGridRowY(row)
        if row <= 0 then return gridTop end
        return gridTop - (btnHeight + gridRow0Gap) - (row - 1) * (btnHeight + gridRowGap)
    end
    local lbBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.LB_BUTTON, "Interface\\Icons\\INV_Helmet_08")
    lbBtn:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 4, gridTop)
    AttachGridButtonTooltip(lbBtn, L.LB_BUTTON_TOOLTIP or L.LB_BUTTON)
    lbBtn:SetScript("OnClick", function()
        if Overlord.LeaderboardUI then Overlord.LeaderboardUI:Toggle() end
    end)
    zoneListFrame.lbBtn = lbBtn

    communityBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.COMMUNITY_BTN_JOIN, "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend")
    communityBtn:SetPoint("TOPRIGHT", actionsCard, "TOPRIGHT", -4, gridTop)
    AttachGridButtonTooltip(communityBtn, L.COMMUNITY_BTN_TOOLTIP or L.COMMUNITY_BTN_JOIN)
    communityBtn:SetScript("OnClick", function()
        Overlord.UI:OnCommunityButtonClick()
    end)
    zoneListFrame.communityBtn = communityBtn
    if Overlord.CommunityModeEnabled == false and self.SetWC3ButtonUnavailable then
        self.SetWC3ButtonUnavailable(communityBtn, L.COMMUNITY_BETA_DISABLED)
    end

    local exportBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.CHECK_PVP_BUTTON, "Interface\\Icons\\INV_Misc_Note_01")
    exportBtn:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 4, ActionGridRowY(4))
    AttachGridButtonTooltip(exportBtn, L.EXPORT_TOOLTIP or L.CHECK_PVP_BUTTON)
    exportBtn:SetScript("OnClick", function()
        if Overlord.Export then Overlord.Export:ShowUI() end
    end)
    zoneListFrame.exportBtn = exportBtn

    local discordBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.DISCORD_BUTTON, "Interface\\ChatFrame\\UIChatIcon")
    if discordBtn.icon and discordBtn.icon.SetAtlas then
        discordBtn.icon:SetTexture(nil)
        discordBtn.icon:SetAtlas(Overlord.DISCORD_BUTTON_ATLAS or "UI-ChatIcon-Discord", false)
        discordBtn.icon:SetTexCoord(0, 1, 0, 1)
    end
    discordBtn:SetPoint("TOPRIGHT", actionsCard, "TOPRIGHT", -4, ActionGridRowY(4))
    AttachGridButtonTooltip(discordBtn, L.DISCORD_BUTTON_TOOLTIP or L.DISCORD_BUTTON)
    discordBtn:SetScript("OnClick", function()
        Overlord.UI:OnDiscordButtonClick()
    end)
    zoneListFrame.discordBtn = discordBtn

    local hofBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.HOF_BUTTON, "Interface\\Icons\\Achievement_LegionPVPTier4")
    hofBtn:SetPoint("TOPRIGHT", actionsCard, "TOPRIGHT", -4, ActionGridRowY(1))
    AttachGridButtonTooltip(hofBtn, L.HOF_BUTTON_TOOLTIP or L.HOF_BUTTON)
    hofBtn:SetScript("OnClick", function()
        if Overlord.HallOfFameUI then Overlord.HallOfFameUI:Toggle() end
    end)
    zoneListFrame.hofBtn = hofBtn

    local tutorialBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.GUIDE_BAR_LABEL, "Interface\\Icons\\INV_Misc_Book_09")
    tutorialBtn:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 4, ActionGridRowY(2))
    AttachGridButtonTooltip(tutorialBtn, L.GUIDE_BTN_TOOLTIP or L.GUIDE_BAR_LABEL)
    tutorialBtn:SetScript("OnClick", function()
        if Overlord.Popups and Overlord.Popups.ToggleQuickGuide then
            Overlord.Popups:ToggleQuickGuide()
        end
    end)
    zoneListFrame.tutorialBtn = tutorialBtn

    local factionBannerIcon = (Overlord.PlayerFaction == "Horde")
        and "Interface\\Icons\\INV_BannerPVP_01"
        or "Interface\\Icons\\INV_BannerPVP_02"
    local hornBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.FACTION_CALL_BUTTON, factionBannerIcon)
    hornBtn:SetPoint("TOPRIGHT", actionsCard, "TOPRIGHT", -4, ActionGridRowY(2))
    AttachGridButtonTooltip(hornBtn, L.FACTION_CALL_TOOLTIP_TITLE or L.FACTION_CALL_BUTTON)

    local generalTip = (Overlord.PlayerFaction == "Horde")
        and L.GENERAL_TOOLTIP_TITLE_HORDE
        or L.GENERAL_TOOLTIP_TITLE_ALLIANCE
    local generalBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.GENERAL_BUTTON, "Interface\\Icons\\Ability_Warrior_RallyingCry")
    generalBtn:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 4, ActionGridRowY(3))
    AttachGridButtonTooltip(generalBtn, generalTip)
    zoneListFrame.factionCallBtn = hornBtn
    zoneListFrame.generalBtn = generalBtn
    if Overlord.Button and Overlord.Button.AttachActionGridButtons then
        Overlord.Button:AttachActionGridButtons(hornBtn, generalBtn)
    end

    local settingsBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.SETTINGS_BUTTON, "Interface\\Icons\\INV_Misc_Gear_01")
    settingsBtn:SetPoint("TOPRIGHT", actionsCard, "TOPRIGHT", -4, ActionGridRowY(3))
    AttachGridButtonTooltip(settingsBtn, L.SETTINGS_BUTTON_TOOLTIP or L.SETTINGS_BUTTON)
    settingsBtn:SetScript("OnClick", function()
        if Overlord.SettingsPanel and Overlord.SettingsPanel.Toggle then
            Overlord.SettingsPanel:Toggle()
        end
    end)
    zoneListFrame.settingsBtn = settingsBtn

    local mbBtn = CreateWC3Button(actionsCard, btnWidth, btnHeight,
        L.MB_BUTTON, "Interface\\Icons\\INV_Misc_Coin_01")
    mbBtn:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 4, ActionGridRowY(1))
    AttachGridButtonTooltip(mbBtn, L.MB_BUTTON_TOOLTIP)
    mbBtn:SetScript("OnClick", function()
        if Overlord.ManualBountyUI and Overlord.ManualBountyUI.Toggle then
            Overlord.ManualBountyUI:Toggle()
        end
    end)
    zoneListFrame.mbBtn = mbBtn

    -- Keep optional module buttons unavailable only when the module is absent.
    local foreverUnavailable = L.FOREVER_FEATURE_UNAVAILABLE
        or "Unavailable on Overlord Forever."
    if self.SetWC3ButtonUnavailable then
        if not Overlord.Export then
            self.SetWC3ButtonUnavailable(exportBtn, foreverUnavailable)
        end
        if not Overlord.HallOfFameUI then
            self.SetWC3ButtonUnavailable(hofBtn, foreverUnavailable)
        end
        if not Overlord.ManualBountyUI then
            self.SetWC3ButtonUnavailable(mbBtn, foreverUnavailable)
        end
        if not Overlord.General then
            self.SetWC3ButtonUnavailable(generalBtn, foreverUnavailable)
        end
    end

    if self.RefreshActionGridActiveState then
        self:RefreshActionGridActiveState()
    end

    -- Carte de statut communaute : placee dans l'en-tete, directement sous
    -- les portraits et le compteur de forces, pour rester impossible a rater.
    communityHintPanel = CreateFrame("Frame", nil, self.headerBand or zoneListFrame, "BackdropTemplate")
    communityHintPanel:SetSize(304, 42)
    communityHintPanel:SetPoint("TOP", self.headerBand or zoneListFrame, "TOP", 0, -68)
    communityHintPanel:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 10,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    communityHintPanel:SetBackdropColor(0.16, 0.035, 0.035, 0.96)
    communityHintPanel:SetBackdropBorderColor(0.82, 0.22, 0.16, 0.92)
    communityHintPanel:EnableMouse(true)
    communityHintPanel:Hide()
    communityHintPanel:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if self._communitySuccess then
            GameTooltip:SetText(L.COMMUNITY_SYNC_ACTIVE, 0.38, 1, 0.58, 1, true)
        else
            GameTooltip:SetText(L.COMMUNITY_HINT_TOOLTIP, 1, 0.92, 0.82, 1, true)
        end
        GameTooltip:Show()
    end)
    communityHintPanel:SetScript("OnLeave", function() GameTooltip:Hide() end)
    communityHintPanel:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then Overlord.UI:OnCommunityButtonClick() end
    end)

    communityHintIcon = communityHintPanel:CreateTexture(nil, "ARTWORK")
    communityHintIcon:SetSize(24, 24)
    communityHintIcon:SetPoint("LEFT", communityHintPanel, "LEFT", 12, 0)
    communityHintIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    communityHintIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    communityHintLabel = communityHintPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    communityHintLabel:SetPoint("TOPLEFT", communityHintIcon, "TOPRIGHT", 7, 1)
    communityHintLabel:SetWidth(164)
    communityHintLabel:SetJustifyH("LEFT")
    communityHintLabel:SetWordWrap(false)
    communityHintLabel:SetMaxLines(1)
    communityHintLabel:SetTextColor(1, 0.38, 0.25)
    communityHintLabel:SetShadowOffset(1, -1)
    local _, sz = communityHintLabel:GetFont()
    if sz then communityHintLabel:SetFont(communityHintLabel:GetFont(), math.max(10, sz)) end

    communityHintSubLabel = communityHintPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    communityHintSubLabel:SetPoint("TOPLEFT", communityHintLabel, "BOTTOMLEFT", 0, -2)
    communityHintSubLabel:SetWidth(164)
    communityHintSubLabel:SetJustifyH("LEFT")
    communityHintSubLabel:SetWordWrap(false)
    communityHintSubLabel:SetMaxLines(1)
    communityHintSubLabel:SetTextColor(0.92, 0.76, 0.60, 0.95)
    communityHintSubLabel:SetShadowOffset(1, -1)

    communityHintCta = CreateWC3Button(communityHintPanel, 88, 24, L.COMMUNITY_SYNC_JOIN)
    communityHintCta:SetPoint("RIGHT", communityHintPanel, "RIGHT", -8, 0)
    communityHintCta:SetScript("OnClick", function()
        Overlord.UI:OnCommunityButtonClick()
    end)

    -- Barre de domination hebdomadaire (Alliance vs Horde), en tete de la section.
    local domBar = CreateFrame("Frame", nil, zoneListFrame, "BackdropTemplate")
    domBar:SetSize(300, 16)
    domBar:SetPoint("TOP", zoneListFrame, "TOP", 0, -14)
    domBar:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    domBar:SetBackdropColor(0.08, 0.08, 0.10, 0.75)
    domBar:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.45)

    local domBg = domBar:CreateTexture(nil, "BACKGROUND", nil, -1)
    domBg:SetPoint("TOPLEFT", 3, -3)
    domBg:SetPoint("BOTTOMRIGHT", -3, 3)
    domBg:SetColorTexture(0.1, 0.1, 0.1, 0.55)

    local domAlly = domBar:CreateTexture(nil, "ARTWORK")
    domAlly:SetPoint("TOPLEFT", 3, -3)
    domAlly:SetPoint("BOTTOMLEFT", 3, 3)
    domAlly:SetColorTexture(0.2, 0.45, 0.85, 0.85)
    domBar.allyFill = domAlly

    local domHorde = domBar:CreateTexture(nil, "ARTWORK")
    domHorde:SetPoint("TOPRIGHT", -3, -3)
    domHorde:SetPoint("BOTTOMRIGHT", -3, 3)
    domHorde:SetColorTexture(0.75, 0.15, 0.15, 0.85)
    domBar.hordeFill = domHorde

    local domLabel = domBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    domLabel:SetPoint("CENTER")
    domLabel:SetTextColor(0.95, 0.92, 0.82)
    domLabel:SetShadowOffset(1, -1)
    domLabel:SetFont(domLabel:GetFont(), 10)
    domBar.label = domLabel

    local domTitle = zoneListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- BOTTOMLEFT + BOTTOMRIGHT sur domBar : largeur = 300 px, texte center, pas de debordement
    domTitle:SetPoint("BOTTOMLEFT",  domBar, "TOPLEFT",  0, 2)
    domTitle:SetPoint("BOTTOMRIGHT", domBar, "TOPRIGHT", 0, 2)
    domTitle:SetJustifyH("CENTER")
    domTitle:SetText(L.DOMINATION_LABEL)
    domTitle:SetTextColor(0.82, 0.74, 0.52, 0.95)
    domTitle:SetFont(domTitle:GetFont(), 10)

    -- Largeur de reference : GetWidth() peut etre 0 avant layout / premier Show (barre invisible).
    domBar._nominalWidth = 300
    Overlord.UI.domBar = domBar
    zoneListFrame.communityHintPanel = communityHintPanel
    zoneListFrame.domTitleLabel = domTitle
    zoneListFrame.domBarFrame = domBar

    -- Sous-panneau zones de controle (deux colonnes)
    local zonesPanel = CreateDarkPanel(zoneListFrame, ZONES_PANEL_W, 180)
    zonesPanel:SetPoint("TOP", domBar, "BOTTOM", 0, -8)
    zoneListFrame.zonesPanel = zonesPanel

    local header = zonesPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOP", zonesPanel, "TOP", 0, -8)
    header:SetText(L.CONTROL_ZONES)
    header:SetTextColor(C.gold[1], C.gold[2], C.gold[3], 0.95)
    header:SetJustifyH("CENTER")
    zoneListFrame.zoneListHeader = header

    local truceLabel = zonesPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    truceLabel:SetPoint("TOPLEFT", zonesPanel, "TOPLEFT", 8, -20)
    truceLabel:SetPoint("TOPRIGHT", zonesPanel, "TOPRIGHT", -8, -20)
    truceLabel:SetJustifyH("CENTER")
    truceLabel:SetWordWrap(false)
    truceLabel:SetMaxLines(1)
    truceLabel:SetTextColor(C.gray[1], C.gray[2], C.gray[3], 0.9)
    truceLabel:Hide()
    zoneListFrame.zoneListTruceLabel = truceLabel

    zoneListFrame.zoneLines = {}
    for _, zone in ipairs(Overlord.Zones:GetDisplayOrderForFront(self:GetPanelViewFrontId())) do
        local line = self:CreateZoneLine(zonesPanel, zone)
        table.insert(zoneListFrame.zoneLines, line)
    end

    zoneListFrame._communityLayoutReady = true
    -- Premiere peinture des fills (CheckWeeklyReset peut avoir eu lieu avant l'init UI).
    self:RefreshDomination()
    -- Toujours demarrer panneau cache (C_Club pas encore charge au login).
    -- Apres 3 s C_Club est pret : on applique le vrai etat. Les non-membres voient le panneau a ce moment.
    self:ApplyCommunityHintLayout(true)
    lastCommunityLayoutClubState = true
    C_Timer.After(3, function()
        communityCheckReady = true
        if not Overlord.UI or not zoneListFrame then return end
        local inClub = Overlord.Sync and Overlord.Sync.HasCommunityClub
            and Overlord.Sync:HasCommunityClub()
        if lastCommunityLayoutClubState ~= inClub then
            lastCommunityLayoutClubState = inClub
            Overlord.UI:ApplyCommunityHintLayout(inClub)
        end
        if Overlord.Sync then
            if inClub then
                if Overlord.Sync.HandleCommunityMembershipDetected then
                    Overlord.Sync:HandleCommunityMembershipDetected()
                end
            elseif Overlord.Sync.HandleCommunityMembershipLost then
                Overlord.Sync:HandleCommunityMembershipLost()
            end
        end
    end)
end

local function ApplyCommunityHintVisual(success)
    if not communityHintPanel then return end
    if success then
        communityHintPanel._communitySuccess = true
        communityHintPanel:SetBackdropColor(0.035, 0.13, 0.07, 0.96)
        communityHintPanel:SetBackdropBorderColor(0.20, 0.72, 0.38, 0.92)
        if communityHintIcon then
            communityHintIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
            communityHintIcon:SetTexCoord(0, 1, 0, 1)
        end
        if communityHintLabel then
            communityHintLabel:SetWidth(246)
            communityHintLabel:SetText(L.COMMUNITY_SYNC_ACTIVE)
            communityHintLabel:SetTextColor(0.38, 1, 0.58)
        end
        if communityHintSubLabel then
            communityHintSubLabel:SetWidth(246)
            communityHintSubLabel:SetText(L.COMMUNITY_SYNC_ACTIVE_SUB)
            communityHintSubLabel:SetTextColor(0.68, 0.90, 0.74, 0.95)
        end
        if communityHintCta then communityHintCta:Hide() end
    else
        communityHintPanel._communitySuccess = false
        communityHintPanel:SetBackdropColor(0.16, 0.035, 0.035, 0.96)
        communityHintPanel:SetBackdropBorderColor(0.82, 0.22, 0.16, 0.92)
        if communityHintIcon then
            communityHintIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
            communityHintIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        if communityHintLabel then
            communityHintLabel:SetWidth(164)
            communityHintLabel:SetText(L.COMMUNITY_SYNC_DISABLED)
            communityHintLabel:SetTextColor(1, 0.38, 0.25)
        end
        if communityHintSubLabel then
            communityHintSubLabel:SetWidth(164)
            communityHintSubLabel:SetText(L.COMMUNITY_SYNC_REQUIRED)
            communityHintSubLabel:SetTextColor(0.92, 0.76, 0.60, 0.95)
        end
        if communityHintCta then
            communityHintCta:Show()
            if communityHintCta.label then communityHintCta.label:SetText(L.COMMUNITY_SYNC_JOIN) end
        end
    end
end

local function ShowCommunityJoinSuccess()
    communitySuccessUntil = GetTime() + 4
    lastCommunityLayoutKey = nil
    if C_Timer and C_Timer.After then
        C_Timer.After(4.1, function()
            if not Overlord.UI or GetTime() < communitySuccessUntil then return end
            communitySuccessUntil = 0
            lastCommunityLayoutKey = nil
            -- Respecter l'etat courant : si l'adhesion a ete perdue pendant
            -- l'animation verte, l'avertissement rouge doit rester visible.
            Overlord.UI:ApplyCommunityHintLayout(lastCommunityLayoutClubState == true)
        end)
    end
end

-- Recalcule domination, contenu principal, actions, bandeau communaute et hauteur totale.
function Overlord.UI:ApplyCommunityHintLayout(memberOfClub)
    if Overlord.CommunityModeEnabled == false then memberOfClub = true; communitySuccessUntil = 0 end
    local zf = zoneListFrame
    if not zf or not zf._communityLayoutReady or not zf.domBarFrame or not zf.domTitleLabel or not zf.zonesPanel or not zf.zoneListHeader then
        return
    end
    local inClub = memberOfClub and true or false
    local gridBottom = zf._actionGridBottom or 102
    local actionsH = zf.actionsCard and zf.actionsCard:GetHeight() or math.max(0, gridBottom - 4)
    local nZones = 0
    if zf.zoneLines then
        for _, line in ipairs(zf.zoneLines) do
            if line:IsShown() then nZones = nZones + 1 end
        end
    end
    local viewFrontId = self:GetPanelViewFrontId()
    local frontOnTruce, truceRemaining = false, 0
    if viewFrontId and Overlord.Zones and Overlord.Zones.IsOnVictoryCooldown then
        frontOnTruce, truceRemaining = Overlord.Zones:IsOnVictoryCooldown(viewFrontId, true)
    end
    local lineH = ZONE_LINE_NORMAL_H
    local activeVisible = activeZoneFrame and activeZoneFrame:IsShown()
    local activeH = activeVisible and (activeZoneFrame:GetHeight() or 64) or 0
    local showSuccess = inClub and GetTime() < communitySuccessUntil
    local showCommunityHint = not inClub or showSuccess
    local communityMode = showSuccess and "success" or (inClub and "hidden" or "warning")
    local layoutKey = communityMode .. "|" .. gridBottom .. "|" .. nZones .. "|" .. lineH
        .. "|" .. (frontOnTruce and "truce" or "normal")
        .. "|" .. (activeVisible and "1" or "0") .. "|" .. activeH
    if layoutKey == lastCommunityLayoutKey then
        return
    end
    lastCommunityLayoutKey = layoutKey
    lastMainFrameHeight = nil
    local domBar = zf.domBarFrame
    local domTitle = zf.domTitleLabel
    local domTop = 14
    local zonesGap = 8
    local activeZoneGap = 6
    local actionsGap = 8

    if self.headerBand then
        self.headerBand:SetHeight(showCommunityHint and 116 or 66)
    end

    domBar:ClearAllPoints()
    domTitle:ClearAllPoints()
    domBar:SetPoint("TOP", zf, "TOP", 0, -domTop)
    domTitle:SetPoint("BOTTOMLEFT", domBar, "TOPLEFT", 0, 1)
    domTitle:SetPoint("BOTTOMRIGHT", domBar, "TOPRIGHT", 0, 1)
    if zf.communityHintPanel then
        zf.communityHintPanel:SetShown(showCommunityHint)
        if showCommunityHint then ApplyCommunityHintVisual(showSuccess) end
    end
    domBar:SetAlpha(inClub and 1 or 0.62)
    domTitle:SetAlpha(inClub and 1 or 0.68)

    zf.zonesPanel:ClearAllPoints()
    zf.zonesPanel:SetPoint("TOP", domBar, "BOTTOM", 0, -zonesGap)

    local panelW = zf.zonesPanel:GetWidth() or ZONES_PANEL_W
    local colW = math.floor((panelW - ZONES_COL_PAD * 2 - ZONES_COL_GAP) / 2)
    local contentTop = frontOnTruce and ZONES_TRUCE_CONTENT_TOP or ZONES_CONTENT_TOP
    local rowStep = lineH + ZONE_LINE_ROW_GAP
    local half = math.max(1, math.ceil(nZones / 2))
    local maxRows = half

    if zf.zoneLines and nZones > 0 then
        local visIdx = 0
        for _, line in ipairs(zf.zoneLines) do
            if line:IsShown() then
                visIdx = visIdx + 1
                local col, row
                if visIdx <= half then
                    col = 0
                    row = visIdx - 1
                else
                    col = 1
                    row = visIdx - half - 1
                end
                local x = ZONES_COL_PAD + col * (colW + ZONES_COL_GAP)
                line:ClearAllPoints()
                line:SetSize(colW, lineH)
                line:SetPoint("TOPLEFT", zf.zonesPanel, "TOPLEFT", x, contentTop - row * rowStep)
                if line.underline then
                    line.underline:SetSize(colW - 2, 1)
                    line.underline:ClearAllPoints()
                    line.underline:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", 0, 1)
                end
                LayoutZoneLineAnchors(line, frontOnTruce)
            end
        end
        local rightRows = nZones - half
        if rightRows > maxRows then maxRows = rightRows end
    end

    if zf.zoneListTruceLabel then
        zf.zoneListTruceLabel:SetShown(frontOnTruce)
        if frontOnTruce then
            zf.zoneListTruceLabel:SetText(string.format(L.SIEGE_COOLDOWN_LABEL,
                Overlord.Zones:FormatDuration(truceRemaining)))
        end
    end

    local contentInset = math.abs(contentTop)
    local panelH = contentInset + maxRows * rowStep + 6
    zf.zonesPanel:SetHeight(panelH)

    local anchorBelowZones = zf.zonesPanel
    if activeZoneFrame then
        activeZoneFrame:ClearAllPoints()
        activeZoneFrame:SetPoint("TOP", zf.zonesPanel, "BOTTOM", 0, -activeZoneGap)
        if activeVisible then
            anchorBelowZones = activeZoneFrame
        end
    end

    if zf.actionsCard then
        zf.actionsCard:ClearAllPoints()
        zf.actionsCard:SetPoint("TOP", anchorBelowZones, "BOTTOM", 0, -actionsGap)
        zf.actionsCard:Show()
        actionsH = zf.actionsCard:GetHeight() or actionsH
    end
    local activeBlockH = activeVisible and (activeZoneGap + activeH) or 0
    local actionsBlockH = actionsGap + actionsH
    local zfHeight = domTop + domBar:GetHeight() + zonesGap + panelH
        + activeBlockH + actionsBlockH + 8
    zf:SetSize(320, zfHeight)

    self:SyncMainFrameHeight()
    if Overlord.Popups and Overlord.Popups.RefreshFeaturedFrontBountyButton then
        Overlord.Popups:RefreshFeaturedFrontBountyButton()
    end
end

-- Ajuste la hauteur du panneau au contenu.
function Overlord.UI:SyncMainFrameHeight()
    if not mainFrame or not zoneListFrame then return end
    local topToZoneList = 108
    if self.headerBand then
        -- 50 = offset TOP->headerBand (garder synchro avec le SetPoint de headerBand ci-dessus)
        topToZoneList = 50 + self.headerBand:GetHeight() + 6
    end
    local bottomPad = 10
    local h = math.max(380, topToZoneList + zoneListFrame:GetHeight() + bottomPad)
    if h == lastMainFrameHeight then return end
    lastMainFrameHeight = h
    mainFrame:SetHeight(h)
end

-- Guild Keep : affichage dans le cluster HUD haut (Ressources.lua)
function Overlord.UI:RefreshGuildKeepRow(force)
    if not force then
        local now = GetTime()
        if now - lastGkHudRefreshAt < GK_HUD_REFRESH_INTERVAL then return end
        lastGkHudRefreshAt = now
    end
    if Overlord.Ressources and Overlord.Ressources.RefreshGuildKeepHUD then
        Overlord.Ressources:RefreshGuildKeepHUD()
    end
end

function Overlord.UI:CreateZoneLine(parent, zone)
    local line = CreateFrame("Button", nil, parent)
    line:SetSize(148, ZONE_LINE_NORMAL_H)
    line.zone = zone

    line.icon = line:CreateTexture(nil, "ARTWORK")
    line.icon:SetSize(ZONE_LINE_ICON, ZONE_LINE_ICON)
    SetZoneLineWarfrontIcon(line.icon, zone)

    line.progress = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    line.name = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    line.name:SetText(zone.name)

    LayoutZoneLineAnchors(line, false)

    line.underline = line:CreateTexture(nil, "ARTWORK")
    line.underline:SetSize(144, 1)
    line.underline:SetPoint("BOTTOMLEFT", 0, 1)
    line.underline:SetColorTexture(1, 1, 1, 0.06)

    line:SetScript("OnClick", function(self)
        local z = self.zone
        local viewFront = Overlord.UI:GetPanelViewFrontId()
        -- Repere sur la carte du front choisi (consultation ou combat).
        if Overlord.MapMarkers and Overlord.MapMarkers.SetUserWaypointForFrontZone then
            Overlord.MapMarkers:SetUserWaypointForFrontZone(z, viewFront)
        end
        if Overlord.UI:IsFrontPanelReadOnly() then
            if z.status == "available" then
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.UI_CAPTURE_READONLY)
            end
            return
        end
        local pf = Overlord.PlayerFaction
        if z.status == "available" then
            if Overlord.CanStartLocalCapture and not Overlord:CanStartLocalCapture(z, true) then
                return
            end
            local playerZone = Overlord.Zones:GetCurrentPlayerZone()
            if playerZone and playerZone.id == z.id then
                if not Overlord.Zones:IsZoneAvailable(z.id) then
                    Overlord:PrintNotification(string.format("|cFFFF0000[Overlord]|r " .. L.CAPTURE_BLOCKED_RULES, z.name))
                    return
                end
                z.holdTimeElapsed = 0
                z.holdStartTime = nil
                z.isContested = false
                z.isPaused = false
                z.status = "in_progress"
                Overlord.ZoneControl:StartHoldTimer(z)
                Overlord.UI:Refresh()
                local msg = z.owner and z.owner ~= pf
                    and L.ASSAULT_LAUNCHED or L.CAPTURE_LAUNCHED
                Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. msg, z.name))
            else
                local cx, cy = z.center and z.center[1], z.center and z.center[2]
                if cx and cy then
                    Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.GO_TO_ZONE, z.name, cx, cy))
                else
                    Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.ZONE_IS_LOCKED, z.name))
                end
                if Overlord.ZoneIndicator then
                    Overlord.ZoneIndicator:Show()
                end
            end
        elseif z.status == "locked" then
            if z.owner and z.owner ~= pf then
                Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.ENEMY_CONTROL_MSG, z.name))
            else
                Overlord:PrintNotification(string.format("|cFF666666[Overlord]|r " .. L.ZONE_IS_LOCKED, z.name))
            end
        elseif z.status == "in_progress" then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.ALREADY_IN_PROGRESS, z.name))
        elseif z.owner == pf then
            Overlord:PrintNotification(string.format("|cFF4488FF[Overlord]|r " .. L.ZONE_UNDER_CONTROL, z.name, pf))
        end
    end)

    -- Flag : RefreshZoneList() tourne souvent ; sans ca le survol serait ecrase a chaque tick
    line._zoneLineHover = false
    line:SetScript("OnEnter", function(self)
        local z = self.zone
        if z then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(z.name or "?", 1, 1, 1)
            local status = self.progress and self.progress:GetText()
            if status and status ~= "" then
                GameTooltip:AddLine(status, 0.82, 0.82, 0.82)
            end
            GameTooltip:Show()
        end
        if z and z.status == "available" and not self._zoneLineHover then
            self._zoneLineHover = true
            Overlord.UI:RepaintZoneLine(self)
        end
    end)

    line:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if self._zoneLineHover then
            self._zoneLineHover = false
            if self.zone.status == "available" then
                Overlord.UI:RepaintZoneLine(self)
            end
        end
    end)

    return line
end

-- ---------- Section zone active ----------
function Overlord.UI:CreateActiveZoneSection(parent)
    if not zoneListFrame then return end
    activeZoneFrame = CreateDarkPanel(zoneListFrame, 304, 64)

    local header = activeZoneFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOP", 0, -6)
    header:SetText(L.ACTIVE_ZONE)
    header:SetTextColor(C.blueBright[1], C.blueBright[2], C.blueBright[3])

    activeZoneFrame.zoneName = activeZoneFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    activeZoneFrame.zoneName:SetPoint("TOP", header, "BOTTOM", 0, -2)
    activeZoneFrame.zoneName:SetText(L.NO_ACTIVE_ZONE)
    activeZoneFrame.zoneName:SetTextColor(C.white[1], C.white[2], C.white[3])

    -- Ligne maintien + timer (meme Y, ancres fixes sur le panneau)
    local holdLabel = activeZoneFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    holdLabel:SetPoint("TOPLEFT", 12, -38)
    holdLabel:SetText(L.HOLD_LABEL)
    holdLabel:SetTextColor(C.blueBright[1], C.blueBright[2], C.blueBright[3], 0.9)

    activeZoneFrame.holdText = activeZoneFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    activeZoneFrame.holdText:SetPoint("TOPRIGHT", -12, -38)
    activeZoneFrame.holdText:SetTextColor(C.white[1], C.white[2], C.white[3])

    local holdBar = CreateFrame("Frame", nil, activeZoneFrame)
    holdBar:SetSize(296, 11)
    holdBar:SetPoint("TOP", 0, -50)

    local holdBg = holdBar:CreateTexture(nil, "BACKGROUND")
    holdBg:SetAllPoints()
    holdBg:SetColorTexture(0.1, 0.1, 0.1, 0.6)

    local holdFill = holdBar:CreateTexture(nil, "ARTWORK")
    holdFill:SetPoint("TOPLEFT")
    holdFill:SetPoint("BOTTOMLEFT")
    holdFill:SetWidth(1)
    holdFill:SetColorTexture(C.blue[1], C.blue[2], C.blue[3], 0.8)
    holdBar.fill = holdFill

    local holdPct = holdBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    holdPct:SetPoint("CENTER")
    holdPct:SetTextColor(0.9, 0.85, 0.7)
    holdPct:SetShadowOffset(1, -1)
    holdPct:SetFont(holdPct:GetFont(), 9)
    holdBar.label = holdPct

    activeZoneFrame.holdBar = holdBar

    -- Status indicator (en pause / actif) - sous la barre, hauteur panneau ajustee au refresh
    activeZoneFrame.statusTag = activeZoneFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    activeZoneFrame.statusTag:SetPoint("TOP", holdBar, "BOTTOM", 0, -3)
    activeZoneFrame.statusTag:SetPoint("LEFT", activeZoneFrame, "LEFT", 12, 0)
    activeZoneFrame.statusTag:SetPoint("RIGHT", activeZoneFrame, "RIGHT", -12, 0)
    activeZoneFrame.statusTag:SetWordWrap(true)
    activeZoneFrame.statusTag:SetJustifyH("CENTER")

    activeZoneFrame.baseHeight = 64
    activeZoneFrame:Hide()
    zoneListFrame.activeZoneFrame = activeZoneFrame
    self.activeZoneFrame = activeZoneFrame
    lastCommunityLayoutKey = nil
end

-- Ajuste la hauteur du panneau zone active (pas de bande vide si pas de statut).
local lastActiveZoneTagText = nil
local lastActiveZoneFrameHeight = nil
local lastActiveZoneIdle = false
function Overlord.UI:SyncActiveZoneFrameHeight()
    if not activeZoneFrame then return end
    local baseH = activeZoneFrame.baseHeight or 64
    local tag = activeZoneFrame.statusTag
    local tagText = (tag and tag:GetText()) or ""
    if tagText == lastActiveZoneTagText and lastActiveZoneFrameHeight then
        if activeZoneFrame:GetHeight() ~= lastActiveZoneFrameHeight then
            activeZoneFrame:SetHeight(lastActiveZoneFrameHeight)
            lastCommunityLayoutKey = nil
            lastMainFrameHeight = nil
            self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
        end
        return
    end
    lastActiveZoneTagText = tagText
    local h = baseH
    if tagText ~= "" then
        tag:Show()
        local tagH = tag:GetStringHeight()
        if not tagH or tagH < 1 then tagH = 14 end
        h = baseH + 3 + tagH + 4
    else
        tag:Hide()
    end
    lastActiveZoneFrameHeight = h
    activeZoneFrame:SetHeight(h)
    lastCommunityLayoutKey = nil
    lastMainFrameHeight = nil
    self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
end

-- ---------- Bouton communaute ----------

-- Popup de copie du code : necessaire car le ticket doit entrer dans le flux protege
-- par une action utilisateur native. Un appel addon a CommunitiesHyperlink taint le
-- callback CLUB_TICKET_RECEIVED et Blizzard bloque GetLastTicketResponse().
local communityPopupFrame = nil

local function OpenCommunitiesAddFlow()
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "arena" or instanceType == "pvp") then return end
    if InCombatLockdown() then return end

    C_Timer.After(0, function()
        if InCombatLockdown() then return end
        if AddCommunitiesFlow_IsShown and AddCommunitiesFlow_IsShown() then return end

        -- Charge l'interface Blizzard uniquement lorsque le joueur ferme la popup.
        if UIParentLoadAddOn then
            pcall(UIParentLoadAddOn, "Blizzard_Communities")
        end

        if AddCommunitiesFlow_IsShown and AddCommunitiesFlow_IsShown() then return end
        if AddCommunitiesFlow_Toggle then
            securecall(AddCommunitiesFlow_Toggle)
        end
    end)
end

local function CreateCommunityPopupFrame()
    local f = CreateFrame("Frame", "OverlordCommunityPopup", UIParent, "BackdropTemplate")
    f:SetSize(460, 200)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.10, 0.97)
    f:SetBackdropBorderColor(0.85, 0.68, 0.20, 0.85)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText(L.COMMUNITY_POPUP_TITLE)
    title:SetTextColor(0.85, 0.68, 0.20)

    local step1 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    step1:SetPoint("TOPLEFT", 18, -40)
    step1:SetText(L.COMMUNITY_POPUP_STEP1)
    step1:SetTextColor(0.9, 0.9, 0.9)

    local step2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    step2:SetPoint("TOPLEFT", 18, -56)
    step2:SetText(L.COMMUNITY_POPUP_STEP2)
    step2:SetTextColor(0.9, 0.9, 0.9)

    local step3 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    step3:SetPoint("TOPLEFT", 18, -72)
    step3:SetText(L.COMMUNITY_POPUP_STEP3)
    step3:SetTextColor(0.9, 0.9, 0.9)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 18, -96)
    hint:SetText(L.COMMUNITY_POPUP_HINT)
    hint:SetTextColor(0.50, 0.50, 0.50)

    local eb = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    eb:SetMultiLine(false)
    eb:SetAutoFocus(false)
    eb:SetFontObject(GameFontHighlightSmall)
    eb:SetPoint("TOPLEFT",  f, "TOPLEFT",  18, -116)
    eb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -116)
    eb:SetHeight(26)
    eb:SetTextInsets(6, 6, 2, 2)
    eb:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 12,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    eb:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
    eb:SetBackdropBorderColor(0.50, 0.42, 0.18, 0.7)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
    f.editBox = eb

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetSize(90, 22)
    closeBtn:SetPoint("BOTTOM", 0, 14)
    closeBtn:SetText(L.EXPORT_CLOSE)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    Overlord.UI.CreateWC3CloseButton(f, function() f:Hide() end)
        :SetPoint("TOPRIGHT", -8, -8)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:EnableKeyboard(true)
    f:SetScript("OnShow", function()
        if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)
    f:SetScript("OnHide", function()
        if eb then eb:ClearFocus() end
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        OpenCommunitiesAddFlow()
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)

    return f
end

function Overlord.UI:ShowCommunityPopup()
    if Overlord.CommunityModeEnabled == false then return end
    if not Overlord.Sync then return end
    if not communityPopupFrame then
        communityPopupFrame = CreateCommunityPopupFrame()
    end

    communityPopupFrame.editBox:SetText(Overlord.Sync:GetCommunityInviteCode())
    communityPopupFrame:Show()

    C_Timer.After(0.05, function()
        if communityPopupFrame and communityPopupFrame:IsShown() then
            communityPopupFrame.editBox:SetFocus()
            communityPopupFrame.editBox:HighlightText()
        end
    end)
end

-- ---------- Popup Discord (lien a copier-coller, meme logique que l'export Check PvP) ----------

local discordPopupFrame = nil

local function GetDiscordInviteUrl()
    return Overlord.DISCORD_INVITE_URL or ""
end

local function RefreshDiscordUrlField()
    if not discordPopupFrame or not discordPopupFrame.urlEditBox then return end
    discordPopupFrame.urlEditBox:SetText(GetDiscordInviteUrl())
end

local function CreateDiscordPopupFrame()
    local f = CreateFrame("Frame", "OverlordDiscordPopup", UIParent, "BackdropTemplate")
    local labelW = 424
    f:SetSize(460, 168)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.10, 0.97)
    f:SetBackdropBorderColor(0.85, 0.68, 0.20, 0.85)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText(L.DISCORD_POPUP_TITLE)
    title:SetTextColor(0.85, 0.68, 0.20)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 18, -40)
    hint:SetWidth(labelW)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText(L.DISCORD_POPUP_HINT)
    hint:SetTextColor(0.9, 0.9, 0.9)

    local urlLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    urlLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    urlLabel:SetWidth(labelW)
    urlLabel:SetJustifyH("LEFT")
    urlLabel:SetText(L.DISCORD_URL_LABEL)
    urlLabel:SetTextColor(0.75, 0.70, 0.45)

    local urlEb = CreateFrame("EditBox", "OverlordDiscordUrlEdit", f, "BackdropTemplate")
    urlEb:SetMultiLine(false)
    urlEb:SetAutoFocus(false)
    urlEb:SetFontObject(GameFontHighlightSmall)
    urlEb:SetPoint("TOPLEFT", urlLabel, "BOTTOMLEFT", 0, -4)
    urlEb:SetPoint("TOPRIGHT", urlLabel, "BOTTOMRIGHT", 0, -4)
    urlEb:SetHeight(26)
    urlEb:SetTextInsets(6, 6, 2, 2)
    urlEb:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 12,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    urlEb:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
    urlEb:SetBackdropBorderColor(0.50, 0.42, 0.18, 0.7)
    urlEb:SetScript("OnEditFocusGained", function(self)
        self:HighlightText()
    end)
    urlEb:SetScript("OnMouseUp", function(self)
        if self:IsMouseOver() and not self:HasFocus() then
            self:SetFocus()
            self:HighlightText()
        end
    end)
    urlEb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    urlEb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    urlEb:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(GetDiscordInviteUrl())
        end
    end)
    f.urlEditBox = urlEb

    local copyHint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyHint:SetPoint("TOPLEFT", urlEb, "BOTTOMLEFT", 0, -2)
    copyHint:SetWidth(labelW)
    copyHint:SetJustifyH("LEFT")
    copyHint:SetText(L.DISCORD_POPUP_COPY_HINT)
    copyHint:SetTextColor(0.50, 0.50, 0.50)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetSize(90, 22)
    closeBtn:SetPoint("BOTTOM", 0, 14)
    closeBtn:SetText(L.EXPORT_CLOSE)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    Overlord.UI.CreateWC3CloseButton(f, function() f:Hide() end)
        :SetPoint("TOPRIGHT", -8, -8)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:EnableKeyboard(true)
    f:SetScript("OnShow", function()
        RefreshDiscordUrlField()
        if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)
    f:SetScript("OnHide", function()
        if urlEb then urlEb:ClearFocus() end
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)

    return f
end

function Overlord.UI:ShowDiscordPopup()
    local url = GetDiscordInviteUrl()
    if url == "" then return end
    if not discordPopupFrame then
        discordPopupFrame = CreateDiscordPopupFrame()
    end
    RefreshDiscordUrlField()
    discordPopupFrame:Show()
    C_Timer.After(0.05, function()
        if discordPopupFrame and discordPopupFrame:IsShown() and discordPopupFrame.urlEditBox then
            discordPopupFrame.urlEditBox:SetFocus()
            discordPopupFrame.urlEditBox:HighlightText()
        end
    end)
end

function Overlord.UI:OnDiscordButtonClick()
    self:ShowDiscordPopup()
end

function Overlord.UI:OnCommunityButtonClick()
    if Overlord.CommunityModeEnabled == false then return end
    if not Overlord.Sync or not Overlord.Sync.FindCommunityClub then return end
    lastCommunityClubPollAt = 0
    -- A join can happen after the last background scan. The click must inspect
    -- Blizzard's current club list instead of reusing the five-minute cache.
    local clubId = Overlord.Sync:FindCommunityClub(true)
    cachedCommunityClubId = clubId
    if clubId then
        if Overlord.Sync.HandleCommunityMembershipDetected then
            Overlord.Sync:HandleCommunityMembershipDetected()
        end
        local inInstance, instanceType = IsInInstance()
        if inInstance and (instanceType == "arena" or instanceType == "pvp") then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.CANNOT_IN_COMBAT)
            return
        end
        if InCombatLockdown() then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.CANNOT_IN_COMBAT)
            return
        end
        if ToggleCommunitiesFrame then
            if not CommunitiesFrame or not CommunitiesFrame:IsShown() then
                securecall(ToggleCommunitiesFrame)
            end
            if CommunitiesFrame and CommunitiesFrame.SelectClub then
                securecall(CommunitiesFrame.SelectClub, CommunitiesFrame, clubId)
            end
        end
        return
    end

    self:ShowCommunityPopup()
end

local function OnCommunityMembershipChanged()
    if Overlord.CommunityModeEnabled == false or not Overlord.Sync
        or communityMembershipRefreshPending then return end
    communityMembershipRefreshPending = true
    -- CLUB_ADDED can fire before GetSubscribedClubs has finished updating.
    C_Timer.After(0.2, function()
        communityMembershipRefreshPending = false
        if not Overlord.Sync or not Overlord.UI then return end
        Overlord.Sync:ResetCommunitySearch()
        cachedCommunityClubId = Overlord.Sync:FindCommunityClub(true)
        lastCommunityClubPollAt = GetTime()
        if Overlord.UI.RefreshCommunityButton then
            Overlord.UI:RefreshCommunityButton()
        end
    end)
end

communityMembershipEventFrame = CreateFrame("Frame")
communityMembershipEventFrame:RegisterEvent("CLUB_ADDED")
communityMembershipEventFrame:RegisterEvent("CLUB_REMOVED")
communityMembershipEventFrame:SetScript("OnEvent", OnCommunityMembershipChanged)

function Overlord.UI:RefreshCommunityButton()
    if Overlord.CommunityModeEnabled == false then
        if communityHintPanel then communityHintPanel:Hide() end
        if lastCommunityLayoutClubState ~= true then
            lastCommunityLayoutClubState = true
            self:ApplyCommunityHintLayout(true)
        end
        return
    end
    if not communityBtn or not Overlord.Sync or not Overlord.Sync.FindCommunityClub then return end
    local now = GetTime()
    if now - lastCommunityClubPollAt >= COMMUNITY_CLUB_POLL_INTERVAL then
        lastCommunityClubPollAt = now
        cachedCommunityClubId = Overlord.Sync:FindCommunityClub()
    end
    local clubId = cachedCommunityClubId
    local hovered = communityBtn:IsMouseOver()
    if clubId then
        if now - lastCommunityStatsAt >= COMMUNITY_STATS_INTERVAL then
            lastCommunityStatsAt = now
            local _, online = Overlord.Sync:GetCommunityStats()
            cachedCommunityOnline = online
        end
        local online = cachedCommunityOnline
        local btnText
        if online and online > 0 then
            btnText = string.format(L.COMMUNITY_BTN_ONLINE, online)
        else
            btnText = L.COMMUNITY_BTN_JOIN
        end
        if communityBtn.label:GetText() ~= btnText then
            communityBtn.label:SetText(btnText)
        end
        communityBtn.baseTextColor = C.blueBright
        if not hovered then
            communityBtn.label:SetTextColor(C.blueBright[1], C.blueBright[2], C.blueBright[3])
        end
    else
        communityBtn.label:SetText(L.COMMUNITY_BTN_JOIN)
        communityBtn.baseTextColor = C.gold
        if not hovered then
            communityBtn.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        end
    end
    -- Ne recaler les ancres que si l'etat communaute change (pas a chaque seconde).
    -- Pendant le delai de demarrage (3 s) on n'autorise que la transition vers "membre" (masquer le panneau),
    -- jamais vers "non-membre" (evite le flash rouge parasite au login).
    local inClub = clubId ~= nil
    if lastCommunityLayoutClubState ~= inClub then
        if inClub or communityCheckReady then
            if inClub and lastCommunityLayoutClubState == false then
                ShowCommunityJoinSuccess()
            end
            lastCommunityLayoutClubState = inClub
            self:ApplyCommunityHintLayout(inClub)
            if Overlord.Sync then
                if inClub and Overlord.Sync.HandleCommunityMembershipDetected then
                    Overlord.Sync:HandleCommunityMembershipDetected()
                elseif communityCheckReady and Overlord.Sync.HandleCommunityMembershipLost then
                    Overlord.Sync:HandleCommunityMembershipLost()
                end
            end
        end
    end
end

-- ============ Refresh logique ============

-- Deux decimales : avec des totaux hebdo enormes, une decimale restait figee longtemps (pas lie au warfront).
local function FormatDominationPctLine(allyPct, hordePct)
    local a = string.format("%.2f", allyPct * 100)
    local h = string.format("%.2f", hordePct * 100)
    if Overlord.UsesCommaDecimalLocale and Overlord.UsesCommaDecimalLocale() then
        a = a:gsub("%.", ",")
        h = h:gsub("%.", ",")
    end
    return a .. "% / " .. h .. "%"
end

function Overlord.UI:Update()
    if not mainFrame or not mainFrame:IsShown() then return end
    self:UpdateTick()
end

-- Cache etat panel : evite SyncFrontPicker / emblemes a chaque tick (perf .18).
local lastPanelStateKey = nil
local lastShardBadgeID = nil
local lastShardBadgeRealm = nil
local lastZoneListRefreshAt = 0
local ZONE_LIST_REFRESH_INTERVAL = 2.0
local ZONE_LIST_SYNC_INTERVAL = 0.25
local lastZoneListSyncRefreshAt = 0
local zoneListRefreshForced = false

-- Tick leger (1/s) : timers, barre active, compteur forces (scan nameplates throttle 2 s).
function Overlord.UI:UpdateTick()
    if not mainFrame or not mainFrame:IsShown() then return end
    self:RefreshActiveZone()
    self:UpdateZoneListTimers()
    self:RefreshForces()
    self:RefreshCommunityButton()
end

-- Picker « pas sur ce front » + emblemes ; forces seulement si l'etat a change (pas chaque seconde).
function Overlord.UI:RefreshPanelState(force)
    if not mainFrame or not mainFrame:IsShown() or Overlord.InstanceSuspended then return end
    local viewId = self:GetPanelViewFrontId() or ""
    local activeId = (Overlord.Fronts and Overlord.Fronts.activeFrontId) or ""
    local key = tostring(Overlord.InActiveFront) .. "|" .. activeId .. "|" .. viewId
    if not force and key == lastPanelStateKey then return end
    lastPanelStateKey = key
    self:SyncFrontPickerButtonText()
    self:RefreshFrontEmblems()
    self:RefreshForces()
end

function Overlord.UI:InvalidatePanelStateCache()
    lastPanelStateKey = nil
    lastForcesOffZone = false
    lastForcesDisplayKey = nil
    lastActiveZoneIdle = false
    lastHeaderBandHeight = nil
    lastDominationPaintKey = nil
    lastShardBadgeID = nil
    lastShardBadgeRealm = nil
    lastCommunityLayoutKey = nil
    lastMainFrameHeight = nil
    lastForcesAnchorMode = nil
    lastFrontEmblemKey = nil
    lastActiveZoneStatusKey = nil
    cachedRefreshActiveZone = nil
    cachedRefreshActiveZoneAt = 0
    lastCommunityClubPollAt = 0
    cachedCommunityClubId = nil
    lastCommunityStatsAt = 0
    cachedCommunityOnline = nil
    lastGkHudRefreshAt = 0
    if zoneListFrame and zoneListFrame.zoneLines then
        for _, line in ipairs(zoneListFrame.zoneLines) do
            line._paintKey = nil
        end
    end
end

-- MAJ texte minuteur / treve sur les lignes deja peintes (evite un Refresh() complet chaque seconde).
function Overlord.UI:UpdateZoneListTimers()
    if not zoneListFrame or not zoneListFrame.zoneLines then return end
    local viewFrontId = self:GetPanelViewFrontId()
    local frontOnTruce, truceRemaining = false, 0
    if viewFrontId and Overlord.Zones and Overlord.Zones.IsOnVictoryCooldown then
        frontOnTruce, truceRemaining = Overlord.Zones:IsOnVictoryCooldown(viewFrontId, true)
    end
    if zoneListFrame.zoneListTruceLabel and frontOnTruce then
        local txt = string.format(L.SIEGE_COOLDOWN_LABEL,
            Overlord.Zones:FormatDuration(truceRemaining))
        if zoneListFrame.zoneListTruceLabel:GetText() ~= txt then
            zoneListFrame.zoneListTruceLabel:SetText(txt)
        end
    end
    for _, line in ipairs(zoneListFrame.zoneLines) do
        if line:IsShown() and line.zone then
            local z = line.zone
            local loginPending = Overlord.IsLoginZoneDisplayPending
                and Overlord:IsLoginZoneDisplayPending(z)
            if loginPending or frontOnTruce or z.status == "in_progress" then
                if loginPending then
                    local txt = L.MAP_SYNC_PENDING or "SYNC"
                    if line.progress:GetText() ~= txt then
                        line.progress:SetText(txt)
                        line.progress:SetTextColor(C.gray[1], C.gray[2], C.gray[3], 0.85)
                    end
                elseif frontOnTruce then
                    if line.progress:GetText() ~= "" then
                        line.progress:SetText("")
                    end
                elseif z.status == "in_progress" then
                    local hr = tonumber(z.holdTimeRequired) or 0
                    local he = (Overlord.Zones and Overlord.Zones.GetObserverHoldTimeElapsed)
                        and Overlord.Zones:GetObserverHoldTimeElapsed(z) or (tonumber(z.holdTimeElapsed) or 0)
                    local rest = math.max(0, hr - he)
                    local txt = string.format("%d:%02d", math.floor(rest / 60), math.floor(rest % 60))
                    if line.progress:GetText() ~= txt then
                        line.progress:SetText(txt)
                    end
                end
            end
        end
    end
end

-- Rafraichissement differe (combat / sync) : evite plusieurs Refresh() d'affilee.
local uiRefreshPending = false
local uiRefreshLastAt = 0
local UI_REFRESH_MIN_INTERVAL = 0.25
local actionGridRefreshPending = false
local lastIndicatorInvalidateAt = 0
local INDICATOR_INVALIDATE_INTERVAL = 1.0
local mapOverlayRefreshPending = false
local mapOverlayRefreshLastAt = 0
local MAP_OVERLAY_REFRESH_MIN_INTERVAL = 0.25

local function ScheduleVisibleWorldMapRefresh()
    if not WorldMapFrame or not WorldMapFrame.IsShown or not WorldMapFrame:IsShown()
        or mapOverlayRefreshPending then
        return
    end
    local now = GetTime()
    local delay = math.max(0.01,
        MAP_OVERLAY_REFRESH_MIN_INTERVAL - (now - mapOverlayRefreshLastAt))
    mapOverlayRefreshPending = true
    C_Timer.After(delay, function()
        mapOverlayRefreshPending = false
        if not WorldMapFrame or not WorldMapFrame.IsShown or not WorldMapFrame:IsShown() then
            return
        end
        mapOverlayRefreshLastAt = GetTime()
        if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
            Overlord.MapMarkers:RequestOverlayRefresh(true)
        end
    end)
end

function Overlord.UI:RequestRefresh()
    if Overlord.InstanceSuspended then return end
    local uiVisible = mainFrame and mainFrame:IsShown()
    local indVisible = Overlord.ZoneIndicator and Overlord.ZoneIndicator.IsHudVisible
        and Overlord.ZoneIndicator:IsHudVisible()
    -- La carte a son propre dirty flag. Coalescer les rafales UI/sync avant de le
    -- lever evite un repaint complet a chaque paquet quand la carte est ouverte.
    ScheduleVisibleWorldMapRefresh()
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.InvalidateActiveZoneCache then
        if uiVisible or indVisible then
            local nowInv = GetTime()
            if nowInv - lastIndicatorInvalidateAt >= INDICATOR_INVALIDATE_INTERVAL then
                lastIndicatorInvalidateAt = nowInv
                Overlord.ZoneIndicator:InvalidateActiveZoneCache()
            end
        end
    end
    if not mainFrame or not mainFrame:IsShown() then
        return
    end
    zoneListRefreshForced = true
    local now = GetTime()
    if now - uiRefreshLastAt >= UI_REFRESH_MIN_INTERVAL then
        uiRefreshLastAt = now
        uiRefreshPending = false
        self:Refresh()
        return
    end
    if uiRefreshPending then return end
    uiRefreshPending = true
    local delay = math.max(0.01, UI_REFRESH_MIN_INTERVAL - (now - uiRefreshLastAt))
    C_Timer.After(delay, function()
        uiRefreshPending = false
        if Overlord.UI and mainFrame and mainFrame:IsShown() then
            uiRefreshLastAt = GetTime()
            Overlord.UI:Refresh()
        end
    end)
end

function Overlord.UI:ScheduleActionGridActiveRefresh()
    if actionGridRefreshPending then return end
    actionGridRefreshPending = true
    C_Timer.After(0, function()
        actionGridRefreshPending = false
        if Overlord.UI and Overlord.UI.RefreshActionGridActiveState then
            Overlord.UI:RefreshActionGridActiveState()
        end
    end)
end

function Overlord.UI:RefreshActionGridActiveState()
    if not zoneListFrame or not self.SetWC3ButtonActive then return end
    local nextState = {
        lb = Overlord.LeaderboardUI and Overlord.LeaderboardUI.IsShown and Overlord.LeaderboardUI:IsShown() or false,
        export = Overlord.Export and Overlord.Export.IsShown and Overlord.Export:IsShown() or false,
        mb = Overlord.ManualBountyUI and Overlord.ManualBountyUI.IsShown and Overlord.ManualBountyUI:IsShown() or false,
        hof = Overlord.HallOfFameUI and Overlord.HallOfFameUI.IsShown and Overlord.HallOfFameUI:IsShown() or false,
        tutorial = Overlord.Popups and Overlord.Popups.IsQuickGuideShown and Overlord.Popups:IsQuickGuideShown() or false,
        community = communityPopupFrame and communityPopupFrame:IsShown() or false,
        discord = discordPopupFrame and discordPopupFrame:IsShown() or false,
        front = self._frontPickerPopup and self._frontPickerPopup:IsShown() or false,
        settings = Overlord.SettingsPanel and Overlord.SettingsPanel.IsOpen and Overlord.SettingsPanel:IsOpen() or false,
    }
    local prev = self._actionGridOpenState
    if prev then
        local same = true
        for k, v in pairs(nextState) do
            if prev[k] ~= v then
                same = false
                break
            end
        end
        if same then
            return
        end
    end
    self._actionGridOpenState = nextState

    local opts = { gold = C.gold, white = C.white }
    local function panelOpen(btn, open)
        if not btn or btn._olUnavailable then return end
        local isOpen = open == true
        if btn._olFrontPickerBadge then
            if btn._olPanelOpenState ~= isOpen then
                btn._olPanelOpenState = isOpen
                self:ApplyFrontPickerChrome(btn, btn._readonlyChrome, isOpen)
            end
            return
        end
        if btn._olPanelOpenState ~= isOpen then
            btn._olPanelOpenState = isOpen
            self.SetWC3ButtonActive(btn, isOpen, opts)
            if btn._gridTooltip and self.RefreshWC3GridButtonTooltip then
                self.RefreshWC3GridButtonTooltip(btn, opts)
            end
        end
        local bc = btn.baseTextColor
        if bc and btn.label and not btn:IsMouseOver() then
            btn.label:SetTextColor(bc[1], bc[2], bc[3])
        end
    end
    panelOpen(zoneListFrame.lbBtn, nextState.lb)
    panelOpen(zoneListFrame.exportBtn, nextState.export)
    panelOpen(zoneListFrame.mbBtn, nextState.mb)
    panelOpen(zoneListFrame.hofBtn, nextState.hof)
    panelOpen(zoneListFrame.tutorialBtn, nextState.tutorial)
    panelOpen(zoneListFrame.communityBtn, nextState.community)
    panelOpen(zoneListFrame.discordBtn, nextState.discord)
    panelOpen(self.frontPickerBtn, nextState.front)
    panelOpen(zoneListFrame.settingsBtn, nextState.settings)
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
end

function Overlord.UI:RefreshActionGridLabels()
    if not zoneListFrame then return end
    local hornBtn = zoneListFrame.factionCallBtn
    if hornBtn and hornBtn.label and L.FACTION_CALL_BUTTON then
        hornBtn.label:SetText(L.FACTION_CALL_BUTTON)
    end
    local generalBtn = zoneListFrame.generalBtn
    if generalBtn and generalBtn.label and L.GENERAL_BUTTON then
        generalBtn.label:SetText(L.GENERAL_BUTTON)
    end
    local settingsBtn = zoneListFrame.settingsBtn
    if settingsBtn and settingsBtn.label and L.SETTINGS_BUTTON then
        settingsBtn.label:SetText(L.SETTINGS_BUTTON)
    end
    local discordBtn = zoneListFrame.discordBtn
    if discordBtn and discordBtn.label and L.DISCORD_BUTTON then
        discordBtn.label:SetText(L.DISCORD_BUTTON)
    end
end

function Overlord.UI:ForceZoneListRefresh()
    zoneListRefreshForced = true
end

function Overlord.UI:RefreshZoneListIfNeeded()
    if not zoneListFrame or not zoneListFrame.zoneLines then return end
    local now = GetTime()
    local due = false
    if zoneListRefreshForced and (now - lastZoneListSyncRefreshAt) >= ZONE_LIST_SYNC_INTERVAL then
        due = true
        lastZoneListSyncRefreshAt = now
        zoneListRefreshForced = false
    elseif (now - lastZoneListRefreshAt) >= ZONE_LIST_REFRESH_INTERVAL then
        due = true
    end
    if due then
        lastZoneListRefreshAt = now
        self:RefreshZoneList()
    end
end

function Overlord.UI:Refresh()
    if not mainFrame or Overlord.InstanceSuspended then return end
    -- Court-circuit si l'UI est cachee : evite RefreshForces (scan 40 nameplates)
    -- et RefreshCommunityButton (securecalls C_Club) en combat ou hors front.
    if not mainFrame:IsShown() then return end
    self:RefreshPanelState()
    self:RefreshZoneListIfNeeded()
    self:RefreshGuildKeepRow()
    self:RefreshActiveZone()
    self:RefreshShardBadge()
    self:RefreshDomination()
    self:RefreshActionGridLabels()
    self:ScheduleActionGridActiveRefresh()
    self:RefreshCommunityButton()
end

function Overlord.UI:RefreshFrontEmblems()
    if not self.knightTex or not self.gruntTex then return end

    local frontId = self:GetPanelViewFrontId() or ""
    local panelFront = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    local heads = panelFront and panelFront.panelHeads
    local emblemKey = frontId
    if heads then
        emblemKey = frontId .. "|" .. tostring(heads.Alliance) .. "|" .. tostring(heads.Horde or heads.HordeIcon)
            .. "|" .. tostring(heads.faceInward) .. "|" .. tostring(heads.allianceMirror) .. "|" .. tostring(heads.hordeMirror)
    end
    if emblemKey == lastFrontEmblemKey then return end
    lastFrontEmblemKey = emblemKey

    if heads then
        -- knightTex = ancre TOPRIGHT du centre (portrait a gauche a l'ecran)
        -- gruntTex = ancre TOPLEFT du centre (portrait a droite a l'ecran)
        local faceInward = heads.faceInward ~= false
        local allianceTex = self.knightTex
        local hordeTex = self.gruntTex
        -- Meme logique qu'avant SetTexCoord plein cadre, appliquee au crop Classic.
        local function WantsHorizontalFlip(mirror)
            if faceInward then
                return mirror == true
            end
            return mirror ~= true
        end
        local function ApplyPanelHead(tex, head, mirror)
            if not tex or head == nil then return end
            local flip = WantsHorizontalFlip(mirror)
            if type(head) == "number" then
                if tex.SetAtlas then pcall(tex.SetAtlas, tex, nil) end
                tex:SetTexture(head)
                if flip then
                    tex:SetTexCoord(1, 0, 0, 1)
                else
                    tex:SetTexCoord(0, 1, 0, 1)
                end
                return
            end
            if Overlord.UI.SetClassicRaceIcon and Overlord.UI.SetClassicRaceIcon(tex, head, flip) then
                return
            end
            -- Repli atlas Retail si la cle Classic est inconnue.
            if type(head) == "string" then
                tex:SetTexture(nil)
                if tex.SetAtlas then tex:SetAtlas(head) end
                if flip then
                    tex:SetTexCoord(1, 0, 0, 1)
                else
                    tex:SetTexCoord(0, 1, 0, 1)
                end
            end
        end
        local allianceMirror = heads.allianceMirror == true
        ApplyPanelHead(allianceTex, heads.Alliance, allianceMirror)
        local hordeMirror = heads.hordeMirror
        if hordeMirror == nil then hordeMirror = true end
        ApplyPanelHead(hordeTex, heads.HordeIcon or heads.Horde, hordeMirror)
    else
        local texPath = "Interface\\AddOns\\Overlord\\Textures\\"
        self.knightTex:SetAtlas(nil)
        self.knightTex:SetTexture(texPath .. "knight")
        self.knightTex:SetTexCoord(0, 1, 0, 1)
        self.gruntTex:SetAtlas(nil)
        self.gruntTex:SetTexture(texPath .. "grunt")
        self.gruntTex:SetTexCoord(0, 1, 0, 1)
    end
end

function Overlord.UI:RefreshDomination()
    if not self.domBar then return end
    if not OverlordDB then return end
    local allyTime, hordeTime
    if Overlord.GetDominationTotals then
        allyTime, hordeTime = Overlord:GetDominationTotals()
    else
        local dom = OverlordDB.dominationTime
        if not dom then return end
        allyTime = dom.Alliance or 0
        hordeTime = dom.Horde or 0
    end
    local total = allyTime + hordeTime
    local barWidth = self.domBar:GetWidth()
    local nominal = self.domBar._nominalWidth or 300
    if (not barWidth) or barWidth < 2 then
        barWidth = nominal
    end
    local innerWidth = math.max(1, barWidth - 6)

    if total == 0 then
        local paintKey = "zero|" .. innerWidth
        if paintKey == lastDominationPaintKey then return end
        lastDominationPaintKey = paintKey
        local halfL = math.floor(innerWidth / 2)
        local halfR = innerWidth - halfL
        self.domBar.allyFill:SetWidth(math.max(1, halfL))
        self.domBar.allyFill:Show()
        self.domBar.hordeFill:SetWidth(math.max(1, halfR))
        self.domBar.hordeFill:Show()
        self.domBar.label:SetText(L.DOMINATION_PCT_ZERO)
        return
    end

    local allyPct, hordePct = Overlord:GetDominationDisplayFractions()
    local allyW = math.floor(innerWidth * allyPct + 0.5)
    if allyW < 0 then allyW = 0 end
    if allyW > innerWidth then allyW = innerWidth end
    local hordeW = innerWidth - allyW
    local label = FormatDominationPctLine(allyPct, hordePct)
    local paintKey = label .. "|" .. allyW .. "|" .. hordeW
    if paintKey == lastDominationPaintKey then return end
    lastDominationPaintKey = paintKey
    if allyW > 0 then
        self.domBar.allyFill:SetWidth(allyW)
        self.domBar.allyFill:Show()
    else
        self.domBar.allyFill:Hide()
    end
    if hordeW > 0 then
        self.domBar.hordeFill:SetWidth(hordeW)
        self.domBar.hordeFill:Show()
    else
        self.domBar.hordeFill:Hide()
    end
    self.domBar.label:SetText(label)
end

-- Cache du scan ennemis pour eviter de rescanner 40 raids+40 nameplates chaque seconde
-- (UpdateHoldTimer scanne deja dans ZoneControl:Update au meme tick)
local lastForcesScan = 0
local cachedEnemyCount = 0
local FORCES_SCAN_INTERVAL = 2
local lastForcesDisplayScan = 0
local cachedDisplayEnemyCount = 0
local lastForcesButtonRefreshCount = nil

-- Affichage HUD « X Horde à proximité » : nameplates visibles (montés inclus).
-- Distinct du scan contestation (ZoneControl) utilise pour l'appel de faction.
local function CountVisibleEnemyNameplates()
    local ef = Overlord.Zones and Overlord.Zones:GetEnemyFaction()
    if not ef then return 0 end
    local n = 0
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsPlayer(unit)
            and not UnitIsDead(unit) and not UnitIsGhost(unit)
            and UnitFactionGroup(unit) == ef then
            n = n + 1
        end
    end
    return n
end

function Overlord.UI:GetDisplayedNearbyEnemyCount(forceRefresh)
    if not Overlord.InActiveFront then
        cachedDisplayEnemyCount = 0
        return 0
    end
    local now = GetTime()
    if forceRefresh or now - lastForcesDisplayScan >= FORCES_SCAN_INTERVAL then
        lastForcesDisplayScan = now
        local zone = Overlord.Zones and Overlord.Zones:GetCurrentPlayerZone()
        if zone and Overlord.ZoneControl and Overlord.ZoneControl.GetCachedScan then
            local cached = Overlord.ZoneControl:GetCachedScan()
            if cached.zoneId == zone.id and now - cached.time < 2 and cached.visibleEnemy ~= nil then
                cachedDisplayEnemyCount = cached.visibleEnemy
            else
                self:GetNearbyEnemyCount(true)
                cached = Overlord.ZoneControl:GetCachedScan()
                cachedDisplayEnemyCount = (cached.visibleEnemy ~= nil) and cached.visibleEnemy or cachedDisplayEnemyCount
            end
        else
            cachedDisplayEnemyCount = CountVisibleEnemyNameplates()
        end
    end
    return cachedDisplayEnemyCount
end

-- Compte les ennemis pour l'appel de faction (regles contestation : pas monte / vol).
function Overlord.UI:GetNearbyEnemyCount(forceRefresh)
    if not Overlord.InActiveFront then
        cachedEnemyCount = 0
        return 0
    end
    local now = GetTime()
    if forceRefresh or now - lastForcesScan >= FORCES_SCAN_INTERVAL then
        lastForcesScan = now
        cachedEnemyCount = 0
        local ef = Overlord.Zones:GetEnemyFaction()
        local zone = Overlord.Zones:GetCurrentPlayerZone()

        if zone then
            local cached = Overlord.ZoneControl:GetCachedScan()
            if not forceRefresh and cached.zoneId == zone.id and now - cached.time < 2 then
                cachedEnemyCount = cached.enemy
            else
                _, cachedEnemyCount = Overlord.ZoneControl:ScanNearbyPlayers(zone)
            end
        else
            for i = 1, 40 do
                local unit = "nameplate" .. i
                if UnitExists(unit) and UnitIsPlayer(unit)
                    and not UnitIsDead(unit) and not UnitIsGhost(unit)
                    and UnitFactionGroup(unit) == ef then
                    cachedEnemyCount = cachedEnemyCount + 1
                end
            end
        end
    end
    return cachedEnemyCount
end

-- Joueurs ennemis reels (sans multiplicateur siege) - condition appel de faction.
function Overlord.UI:GetNearbyEnemyCountRaw(forceRefresh)
    self:GetNearbyEnemyCount(forceRefresh)
    if Overlord.ZoneControl and Overlord.ZoneControl.GetCachedScan then
        local cached = Overlord.ZoneControl:GetCachedScan()
        local zone = Overlord.Zones and Overlord.Zones:GetCurrentPlayerZone()
        if zone and cached.zoneId == zone.id and cached.enemyRaw ~= nil then
            return cached.enemyRaw
        end
    end
    return cachedEnemyCount
end

function Overlord.UI:RefreshForces()
    if not self.forcesText then return end
    if not Overlord.InActiveFront then
        if not lastForcesOffZone then
            lastForcesOffZone = true
            lastForcesDisplayKey = nil
            self.forcesText:SetText(L.NOT_IN_WARZONE)
            self.forcesText:SetTextColor(0.58, 0.58, 0.58, 0.85)
            if self.knightTex then self.knightTex:SetAlpha(0.6) end
            if self.gruntTex then self.gruntTex:SetAlpha(0.6) end
            lastForcesButtonRefreshCount = nil
            if Overlord.Button and Overlord.Button.Refresh then
                Overlord.Button:Refresh()
            end
        end
        return
    end
    lastForcesOffZone = false
    if self.knightTex then self.knightTex:SetAlpha(0.85) end
    if self.gruntTex then self.gruntTex:SetAlpha(0.85) end
    self.forcesText:SetTextColor(0.88, 0.78, 0.48, 0.95)
    local nearby = self:GetDisplayedNearbyEnemyCount(false)
    local ef = Overlord.Zones:GetEnemyFaction()
    local displayKey = tostring(nearby) .. "|" .. tostring(ef or "")
    if displayKey ~= lastForcesDisplayKey then
        lastForcesDisplayKey = displayKey
        self.forcesText:SetText(string.format(L.FORCES_PRESENT, nearby, ef or ""))
    end
    -- Bouton appel de faction : scan contestation (ennemis au sol, pas montes)
    self:GetNearbyEnemyCount(false)
    if Overlord.Button and Overlord.Button.Refresh then
        if lastForcesButtonRefreshCount ~= cachedEnemyCount then
            lastForcesButtonRefreshCount = cachedEnemyCount
            Overlord.Button:Refresh()
        end
    end
end

-- Cle d'etat statique de la zone active (hors minuteur de capture).
local function BuildActiveZoneStatusKey(az, ef)
    if not az then return "idle" end
    if Overlord.IsLoginZoneDisplayPending and Overlord:IsLoginZoneDisplayPending(az) then
        return (az.id or "?") .. "|sync"
    end
    return (az.id or "?") .. "|" .. (az.status or "") .. "|" .. (az.owner or "") .. "|"
        .. (az.isContested and 1 or 0) .. (az.isPaused and 1 or 0) .. (az.isHolding and 1 or 0)
        .. ((az.status == "in_progress" and az.owner == ef) and 1 or 0)
end

-- Le target Outpost du HUD est un objet de vue reutilise. Le panneau principal ne
-- doit jamais dependre du fait que ZoneIndicator l'ait deja repeint dans la meme
-- seconde : relire directement l'unique etat du site est O(1) et garantit que le
-- chrono Warchief's Watch demarre des la premiere seconde de capture.
function Overlord.UI:RefreshActiveOutpostZoneView(az)
    if not az or not az._outpost or not Overlord.Outpost then return az end
    local site = az._outpostSite
        or (Overlord.Outpost.GetSite and Overlord.Outpost:GetSite(az._outpostSiteKey))
    local siteKey = site and (site.siteKey or site.id) or az._outpostSiteKey
    local st = siteKey and Overlord.Outpost:GetState(siteKey) or nil
    if not site or not st then return az end
    az._outpostSite = site
    az._outpostSiteKey = siteKey
    az._outpostState = st
    az.status = st.status
    az.owner = st.ownerFaction
    az.holdTimeElapsed = tonumber(st.holdTimeElapsed) or 0
    az.holdTimeRequired = Overlord.Outpost:GetDefaultHoldTimeRequired(st, site)
    az.isHolding = st.isHolding or false
    az.isPaused = st.isPaused or false
    az.isContested = st.isContested or false
    return az
end

-- Repaint d'une seule ligne (survol sans RefreshZoneList complet).
function Overlord.UI:RepaintZoneLine(line)
    if not line or not line.zone then return end
    local z = line.zone
    local viewFrontId = self:GetPanelViewFrontId()
    local frontOnTruce = false
    if viewFrontId and Overlord.Zones and Overlord.Zones.IsOnVictoryCooldown then
        frontOnTruce = select(1, Overlord.Zones:IsOnVictoryCooldown(viewFrontId, true))
    end
    local pf = Overlord.PlayerFaction
    local ef = Overlord.Zones:GetEnemyFaction()
    local isEnemy = z.owner and z.owner == ef
    local loginPending = Overlord.IsLoginZoneDisplayPending
        and Overlord:IsLoginZoneDisplayPending(z)
    local paintKey = BuildZoneLinePaintKey(z, frontOnTruce, loginPending, pf, ef)
    line._paintKey = paintKey
    line.name:SetText(z.name)
    SetZoneLineWarfrontIcon(line.icon, z)
    PaintZoneLineVisual(line, z, frontOnTruce, loginPending, pf, ef, isEnemy)
    ApplyZoneLineUnderline(line, z, loginPending)
end

function Overlord.UI:RefreshZoneList()
    if not zoneListFrame or not zoneListFrame.zoneLines then return end

    local viewFrontId = self:GetPanelViewFrontId()
    local frontOnTruce = false
    if viewFrontId and Overlord.Zones and Overlord.Zones.IsOnVictoryCooldown then
        frontOnTruce = select(1, Overlord.Zones:IsOnVictoryCooldown(viewFrontId, true))
    end
    local truceToken = frontOnTruce and "t" or "n"
    local truceLayoutChanged = zoneListFrame._lastTruceLayoutToken ~= truceToken
    if truceLayoutChanged then
        zoneListFrame._lastTruceLayoutToken = truceToken
        lastCommunityLayoutKey = nil
    end

    local orderedZones = Overlord.Zones:GetDisplayOrderForFront(viewFrontId)
    local needsRebind = #zoneListFrame.zoneLines ~= #orderedZones
    if not needsRebind then
        for i, zone in ipairs(orderedZones) do
            local line = zoneListFrame.zoneLines[i]
            if not line or not line.zone or line.zone.id ~= zone.id then
                needsRebind = true
                break
            end
        end
    end
    if needsRebind then
        lastCommunityLayoutKey = nil
        for i, zone in ipairs(orderedZones) do
            local line = zoneListFrame.zoneLines[i]
            if not line then
                local zonesParent = zoneListFrame.zonesPanel or zoneListFrame
                line = self:CreateZoneLine(zonesParent, zone)
                zoneListFrame.zoneLines[i] = line
            end
            line.zone = zone
            line.name:SetText(zone.name)
            line._zoneLineHover = false
            line._paintKey = nil
            line:Show()
        end
        for i = #orderedZones + 1, #zoneListFrame.zoneLines do
            if zoneListFrame.zoneLines[i] then
                zoneListFrame.zoneLines[i]:Hide()
            end
        end
        self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
    elseif truceLayoutChanged then
        self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
    end

    local pf = Overlord.PlayerFaction
    local ef = Overlord.Zones:GetEnemyFaction()

    for _, line in ipairs(zoneListFrame.zoneLines) do
        if not line:IsShown() then
            -- Ligne gardée en réserve après un changement de front.
        else
        local z = line.zone
        local isEnemy = z.owner and z.owner == ef
        local loginPending = Overlord.IsLoginZoneDisplayPending
            and Overlord:IsLoginZoneDisplayPending(z)
        local paintKey = BuildZoneLinePaintKey(z, frontOnTruce, loginPending, pf, ef)
        if line._paintKey ~= paintKey then
            line._paintKey = paintKey
            line.name:SetText(z.name)
            SetZoneLineWarfrontIcon(line.icon, z)
            PaintZoneLineVisual(line, z, frontOnTruce, loginPending, pf, ef, isEnemy)
        end
        local underlineKey = (line._zoneLineHover and "h" or "")
            .. tostring(z.status or "") .. (loginPending and "p" or "")
        if line._underlineKey ~= underlineKey then
            line._underlineKey = underlineKey
            ApplyZoneLineUnderline(line, z, loginPending)
        end
        end
    end
end

function Overlord.UI:RefreshActiveZone()
    if not activeZoneFrame then return end
    local now = GetTime()
    local az
    if cachedRefreshActiveZone ~= nil and (now - cachedRefreshActiveZoneAt) < REFRESH_ACTIVE_ZONE_LOOKUP_SEC then
        az = cachedRefreshActiveZone
    else
        az = self:GetActiveZone()
        cachedRefreshActiveZone = az
        cachedRefreshActiveZoneAt = now
    end
    az = self:RefreshActiveOutpostZoneView(az)

    if not az then
        if lastActiveZoneIdle then return end
        lastActiveZoneIdle = true
        lastActiveZoneStatusKey = "idle"
        activeZoneFrame.statusTag:SetText("")
        lastActiveZoneTagText = ""
        lastActiveZoneFrameHeight = nil
        activeZoneFrame:Hide()
        lastCommunityLayoutKey = nil
        lastMainFrameHeight = nil
        self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
        return
    end
    lastActiveZoneIdle = false
    if not activeZoneFrame:IsShown() then
        activeZoneFrame:Show()
        lastCommunityLayoutKey = nil
        lastMainFrameHeight = nil
        self:ApplyCommunityHintLayout(lastCommunityLayoutClubState ~= false)
    end

    if Overlord.IsLoginZoneDisplayPending and Overlord:IsLoginZoneDisplayPending(az) then
        local syncKey = (az.id or "?") .. "|sync"
        if syncKey == lastActiveZoneStatusKey then return end
        lastActiveZoneStatusKey = syncKey
        activeZoneFrame.zoneName:SetText(az.name or "?")
        activeZoneFrame.zoneName:SetTextColor(C.gray[1], C.gray[2], C.gray[3])
        activeZoneFrame.holdText:SetText(L.MAP_SYNC_PENDING or "SYNC")
        activeZoneFrame.holdBar.fill:SetWidth(1)
        activeZoneFrame.holdBar.fill:SetColorTexture(C.gray[1], C.gray[2], C.gray[3], 0.8)
        activeZoneFrame.holdBar.label:SetText("")
        activeZoneFrame.statusTag:SetText(L.MAP_SYNC_PENDING or "SYNC")
        activeZoneFrame.statusTag:SetTextColor(C.gray[1], C.gray[2], C.gray[3])
        self:SyncActiveZoneFrameHeight()
        return
    end

    local ef = Overlord.Zones:GetEnemyFaction()
    local statusKey = BuildActiveZoneStatusKey(az, ef)
    local statusChanged = statusKey ~= lastActiveZoneStatusKey
    if statusChanged then
        lastActiveZoneStatusKey = statusKey
        activeZoneFrame.zoneName:SetText(az.name or "?")
        activeZoneFrame.zoneName:SetTextColor(C.white[1], C.white[2], C.white[3])
    end

    local hr = tonumber(az.holdTimeRequired) or 0
    local hc = 0
    if az.status == "in_progress" then
        if az._outpost and az._outpostState and az._outpostSite and Overlord.Outpost then
            hc = Overlord.Outpost:GetObserverHoldTimeElapsed(az._outpostState, az._outpostSite)
        else
            hc = (Overlord.Zones and Overlord.Zones.GetObserverHoldTimeElapsed)
                and Overlord.Zones:GetObserverHoldTimeElapsed(az)
                or (tonumber(az.holdTimeElapsed) or 0)
        end
    end
    if az.status == "in_progress" then
        local now = GetTime()
        if statusChanged or (now - lastActiveZoneTimerAt) >= ACTIVE_ZONE_TIMER_INTERVAL then
            lastActiveZoneTimerAt = now
            local ratio = (hr > 0) and math.min(hc / hr, 1) or 0
            local hpct = math.floor(ratio * 100)
            local holdStr = string.format("%d:%02d / %d:%02d",
                math.floor(hc / 60), math.floor(hc % 60),
                math.floor(hr / 60), math.floor(hr % 60))
            if activeZoneFrame.holdText:GetText() ~= holdStr then
                activeZoneFrame.holdText:SetText(holdStr)
            end
            local barWidth = activeZoneFrame.holdBar:GetWidth()
            activeZoneFrame.holdBar.fill:SetWidth(math.max(1, barWidth * ratio))
            local pctStr = hpct .. "%"
            if activeZoneFrame.holdBar.label:GetText() ~= pctStr then
                activeZoneFrame.holdBar.label:SetText(pctStr)
            end
        end
    elseif statusChanged then
        activeZoneFrame.holdBar.fill:SetWidth(1)
        activeZoneFrame.holdBar.label:SetText("")
        activeZoneFrame.holdText:SetText("")
    end

    if not statusChanged then return end

    local enemyCapturing = (az.status == "in_progress" and az.owner == ef)

    -- Couleur du fill selon l'etat
    if az.isContested then
        activeZoneFrame.holdBar.fill:SetColorTexture(C.enemy[1], C.enemy[2], C.enemy[3], 0.8)
        activeZoneFrame.statusTag:SetText(L.UI_CONTESTED)
        activeZoneFrame.statusTag:SetTextColor(C.enemy[1], C.enemy[2], C.enemy[3])
    elseif az.isPaused then
        activeZoneFrame.holdBar.fill:SetColorTexture(C.orange[1], C.orange[2], C.orange[3], 0.8)
        activeZoneFrame.statusTag:SetText(L.UI_PAUSED)
        activeZoneFrame.statusTag:SetTextColor(C.orange[1], C.orange[2], C.orange[3])
    elseif az.isHolding then
        activeZoneFrame.holdBar.fill:SetColorTexture(C.blue[1], C.blue[2], C.blue[3], 0.8)
        activeZoneFrame.statusTag:SetText(L.UI_IN_PROGRESS)
        activeZoneFrame.statusTag:SetTextColor(C.blueBright[1], C.blueBright[2], C.blueBright[3])
    elseif enemyCapturing then
        activeZoneFrame.holdBar.fill:SetColorTexture(C.orange[1], C.orange[2], C.orange[3], 0.8)
        activeZoneFrame.statusTag:SetText(L.UI_ENEMY_CAPTURING)
        activeZoneFrame.statusTag:SetTextColor(C.orange[1], C.orange[2], C.orange[3])
    elseif hc >= hr and hr > 0 then
        -- Maintien plein : or du theme (pas le vert type quete WoW)
        activeZoneFrame.holdBar.fill:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.85)
        activeZoneFrame.statusTag:SetText(L.UI_COMPLETE)
        activeZoneFrame.statusTag:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    else
        activeZoneFrame.holdBar.fill:SetColorTexture(C.gray[1], C.gray[2], C.gray[3], 0.8)
        activeZoneFrame.statusTag:SetText("")
    end
    self:SyncActiveZoneFrameHeight()
end

function Overlord.UI:GetActiveZone()
    local zones
    local readOnlyPanel = self:IsFrontPanelReadOnly()
    if readOnlyPanel and Overlord.Zones and Overlord.Zones.GetDisplayOrderForFront then
        zones = Overlord.Zones:GetDisplayOrderForFront(self:GetPanelViewFrontId())
    elseif Overlord.ZoneIndicator and Overlord.ZoneIndicator.FindActiveZone then
        local hudZone = Overlord.ZoneIndicator:FindActiveZone(false)
        if hudZone and not hudZone._guildKeep then
            return hudZone
        end
        if Overlord.Zones and Overlord.Zones.GetDisplayOrderForFront then
            zones = Overlord.Zones:GetDisplayOrderForFront(
                (Overlord.Fronts and Overlord.Fronts.activeFrontId) or self:GetPanelViewFrontId())
        end
    end
    zones = zones or Overlord.ZoneDatabase or {}
    -- Priorite 1 : notre capture active (on est physiquement dans la zone)
    for _, zone in ipairs(zones) do
        if zone.status == "in_progress" and zone.isHolding then return zone end
    end
    -- Priorite 2 : toute zone en cours (allie ou ennemi)
    for _, zone in ipairs(zones) do
        if zone.status == "in_progress" then return zone end
    end
    -- Priorite 3 : prochaine zone disponible
    for _, zone in ipairs(zones) do
        if zone.status == "available" then return zone end
    end
    return nil
end

function Overlord.UI:RefreshShardBadge()
    if not self.shardFrame or not self.shardText or not self.shardRealmText then return end
    local active = IsShardHelperActive()
    local shardMod = Overlord.Shard
    if shardMod and active and shardMod:GetCurrentShardID() == nil then
        local now = GetTime()
        if now - lastShardScanFromUiAt >= SHARD_UI_SCAN_INTERVAL then
            lastShardScanFromUiAt = now
            shardMod:Update()
        end
    end
    local shardID = shardMod and shardMod:GetCurrentShardID()
    local referenceRealm
    if shardID ~= nil then
        local _
        _, referenceRealm = shardMod:GetCurrentShardReference()
    end
    local visibleShardID = active and shardID or nil
    referenceRealm = visibleShardID and referenceRealm or nil
    if visibleShardID == lastShardBadgeID and referenceRealm == lastShardBadgeRealm then return end
    lastShardBadgeID = visibleShardID
    lastShardBadgeRealm = referenceRealm
    if visibleShardID ~= nil then
        self.shardText:SetText("#" .. tostring(shardID))
        if referenceRealm and referenceRealm ~= "" then
            self.shardRealmText:SetText(string.format(L.SHARD_BADGE_REFERENCE, referenceRealm))
            self.shardRealmText:Show()
        else
            self.shardRealmText:Hide()
        end
        local shardW = self.shardText:GetStringWidth() or 0
        local realmW = self.shardRealmText:IsShown()
            and (self.shardRealmText:GetStringWidth() or 0) or 0
        local iconW = self.shardBadgeIconSize or 14
        -- Largeur au contenu : ligne #66 a droite de l'icone, royaume sous l'icone.
        local pad = 3
        local shardRowW = iconW + 4 + shardW
        local contentW = self.shardRealmText:IsShown()
            and math.max(shardRowW, realmW) or shardRowW
        local w = math.ceil(contentW + pad * 2)
        self.shardFrame:SetWidth(math.max(32, w))
        local shardH = self.shardText:GetStringHeight() or 11
        if self.shardRealmText:IsShown() then
            shardH = shardH + 1 + (self.shardRealmText:GetStringHeight() or 10)
        end
        self.shardFrame:SetHeight(math.max(16, math.ceil(shardH + 4)))
        self.shardFrame:Show()
    else
        self.shardFrame:Hide()
    end
end

-- ============ Ecran de victoire totale ============

local victoryFrame = nil

-- Pool suffisant pour tous les fronts (ZoneDatabase au chargement peut etre plus petit qu'en jeu).
local MAX_VICTORY_STAT_LINES = 40

function Overlord.UI:ShowVictoryScreen(factionName)
    if victoryFrame and victoryFrame:IsShown() then return end

    local stats = {}
    local victorKills   = 0
    local defeatedKills = 0
    local isVictoryHorde  = (factionName == L.VICTORY_FACTION_HORDE)
    local defeatedFaction = isVictoryHorde and "Alliance" or "Horde"

    -- Snapshot zone uniquement : pas de GetFactionKillTotals (classement = semaine entiere, tous fronts).
    local snap = OverlordDB and OverlordDB.lastCampaignStats
    local currentCampaignId = OverlordDB and OverlordDB.campaignId
    local currentFront = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    local currentFrontId = currentFront and currentFront.id
    if snap then
        if snap.campaignId ~= currentCampaignId then
            snap = nil
        elseif snap.frontId and currentFrontId and snap.frontId ~= currentFrontId then
            snap = nil
        end
    end
    if snap and snap.zones and #snap.zones > 0 then
        for _, entry in ipairs(snap.zones) do
            table.insert(stats, { name = entry.name, kills = entry.kills or 0 })
        end
        local allyRaw  = snap.allyKills  or 0
        local enemyRaw = snap.enemyKills or 0
        victorKills   = isVictoryHorde and enemyRaw or allyRaw
        defeatedKills = isVictoryHorde and allyRaw  or enemyRaw
    end

    local lineH = 17
    local panelH = 290 + math.max(0, #stats) * lineH

    -- Cree tous les elements une seule fois, stocke les refs sur victoryFrame
    if not victoryFrame then
        victoryFrame = CreateFrame("Frame", "OverlordVictoryFrame", UIParent)
        victoryFrame:SetAllPoints()
        victoryFrame:SetFrameStrata("DIALOG")
        victoryFrame:SetFrameLevel(100)
        victoryFrame:EnableMouse(false)

        victoryFrame.bg = victoryFrame:CreateTexture(nil, "BACKGROUND")
        victoryFrame.bg:SetAllPoints()
        victoryFrame.bg:SetColorTexture(0, 0, 0, 0.65)

        local panel = CreateFrame("Frame", nil, victoryFrame, "BackdropTemplate")
        panel:EnableMouse(true)
        panel:SetPoint("CENTER", 0, 30)
        panel:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
            tile     = true,
            tileSize = 32,
            edgeSize = 32,
            insets   = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        victoryFrame.panel = panel

        panel.hdr = panel:CreateTexture(nil, "OVERLAY")
        panel.hdr:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
        panel.hdr:SetSize(280, 64)
        panel.hdr:SetPoint("TOP", 0, 12)

        panel.hdrTxt = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        panel.hdrTxt:SetPoint("TOP", 0, -1)
        panel.hdrTxt:SetText("Overlord")

        panel.glow = panel:CreateTexture(nil, "ARTWORK", nil, 0)
        panel.glow:SetSize(100, 100)
        panel.glow:SetPoint("TOP", 0, -28)
        panel.glow:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall")
        panel.glow:SetBlendMode("ADD")

        panel.fIcon = panel:CreateTexture(nil, "ARTWORK", nil, 1)
        panel.fIcon:SetSize(64, 64)
        panel.fIcon:SetPoint("TOP", 0, -46)

        panel.line1 = panel:CreateFontString(nil, "OVERLAY", "QuestFont_Huge")
        panel.line1:SetPoint("TOP", 0, -114)

        panel.line2 = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        panel.line2:SetPoint("TOP", panel.line1, "BOTTOM", 0, -2)

        panel.sub = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        panel.sub:SetPoint("TOP", panel.line2, "BOTTOM", 0, -6)

        panel.sep = panel:CreateTexture(nil, "ARTWORK")
        panel.sep:SetSize(340, 1)
        panel.sep:SetPoint("TOP", panel.sub, "BOTTOM", 0, -10)

        panel.statsHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        panel.statsHeader:SetPoint("TOP", panel.sep, "BOTTOM", 0, -8)

        panel.statNames = {}
        panel.statKills = {}
        for i = 1, MAX_VICTORY_STAT_LINES do
            local nm = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nm:SetJustifyH("LEFT")
            panel.statNames[i] = nm
            local kl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            kl:SetJustifyH("RIGHT")
            panel.statKills[i] = kl
        end

        panel.totalText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")

        panel.closeBtn = CreateWC3Button(panel, 120, 28, CLOSE or "Fermer")
        panel.closeBtn:SetPoint("BOTTOM", 0, 16)
        panel.closeBtn:SetScript("OnClick", function()
            if victoryFrame then victoryFrame:Hide() end
        end)

        -- ESC ferme le panneau (SetScript au lieu de UISpecialFrames pour eviter taint)
        victoryFrame:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:SetPropagateKeyboardInput(false)
                self:Hide()
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)
        victoryFrame:EnableKeyboard(true)
    end

    -- Met a jour les elements avec les donnees de cette victoire
    local panel = victoryFrame.panel
    panel:SetSize(420, panelH)
    panel:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], 0.97)
    panel:SetBackdropBorderColor(1, 0.82, 0, 1)

    panel.hdrTxt:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    panel.glow:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.3)
    panel.fIcon:SetTexture(isVictoryHorde
        and "Interface\\Timer\\Horde-Logo"
        or  "Interface\\Timer\\Alliance-Logo")

    panel.line1:SetText(L.VICTORY_LINE1)
    panel.line1:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local factionColor = isVictoryHorde
        and {1.0, 0.35, 0.20}
        or  {0.427, 0.702, 0.949}
    panel.line2:SetText(string.format(L.VICTORY_LINE2, factionName))
    panel.line2:SetTextColor(factionColor[1], factionColor[2], factionColor[3])

    local frontName = Overlord.Fronts and Overlord.Fronts:GetMapName()
    if not frontName or not L.FRONT_CONQUERED then return end
    panel.sub:SetText(string.format(L.FRONT_CONQUERED, frontName))
    panel.sub:SetTextColor(factionColor[1], factionColor[2], factionColor[3], 0.7)

    panel.sep:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.4)
    if #stats > 0 then
        panel.sep:Show()
        panel.statsHeader:SetText(L.CAMPAIGN_STATS)
        panel.statsHeader:SetTextColor(C.gold[1], C.gold[2], C.gold[3], 0.8)
        panel.statsHeader:Show()
    else
        panel.sep:Hide()
        panel.statsHeader:Hide()
    end

    for i = 1, MAX_VICTORY_STAT_LINES do
        local nm = panel.statNames[i]
        local kl = panel.statKills[i]
        if stats[i] then
            nm:ClearAllPoints()
            nm:SetPoint("TOPLEFT", panel.sep, "BOTTOMLEFT", 20, -26 - (i - 1) * lineH)
            nm:SetText(stats[i].name)
            nm:SetTextColor(C.white[1], C.white[2], C.white[3], 0.85)
            nm:Show()
            kl:ClearAllPoints()
            kl:SetPoint("TOPRIGHT", panel.sep, "BOTTOMRIGHT", -20, -26 - (i - 1) * lineH)
            kl:SetText(stats[i].kills .. " " .. (L.LB_COL_KILLS or "kills"))
            kl:SetTextColor(C.gray[1], C.gray[2], C.gray[3])
            kl:Show()
        else
            nm:Hide()
            kl:Hide()
        end
    end

    if #stats > 0 then
        local totalY = -26 - #stats * lineH - 8
        panel.totalText:ClearAllPoints()
        panel.totalText:SetPoint("TOP", panel.sep, "BOTTOM", 0, totalY)
        local victoryFaction = isVictoryHorde and "Horde" or "Alliance"
        panel.totalText:SetText(string.format(L.STATS_TOTAL_KILLS,
            victoryFaction,  victorKills,
            defeatedFaction, defeatedKills))
        panel.totalText:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        panel.totalText:Show()
    else
        panel.totalText:Hide()
    end

    -- Fade-in progressif (1 seconde)
    victoryFrame:Show()
    victoryFrame:SetAlpha(0)
    local fadeStart = GetTime()
    victoryFrame:SetScript("OnUpdate", function(self)
        local p = (GetTime() - fadeStart) / 1.0
        if p >= 1 then
            self:SetAlpha(1)
            self:SetScript("OnUpdate", nil)
        else
            self:SetAlpha(p)
        end
    end)

    -- Son de victoire
    if OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.UI_WARFRONTS_BATTLE_COMPLETE or 175409)
    end

    -- Fermeture automatique apres 30s
    C_Timer.After(30, function()
        if victoryFrame and victoryFrame:IsShown() then
            victoryFrame:Hide()
        end
    end)
end

-- ============ Mode spectateur (panel visible hors front) ============
-- Timers locaux a 1s pour eviter les paliers 5s ; refresh complet/sync restent espaces.

local spectatorRefreshTicker = nil
local spectatorSyncTicker = nil
local SPECTATOR_TIMER_INTERVAL = 1
local SPECTATOR_FULL_REFRESH_INTERVAL = 5
local spectatorLastFullRefresh = 0
local spectatorLastTimerTick = nil

-- Rafraichissement leger hors front : pas RefreshForces ni RefreshCommunityButton.
function Overlord.UI:RefreshSpectatorLocal()
    if not mainFrame or not mainFrame:IsShown() then return end
    local now = GetTime()
    local dt = spectatorLastTimerTick and math.max(0.001, math.min(now - spectatorLastTimerTick, 1.5))
        or SPECTATOR_TIMER_INTERVAL
    spectatorLastTimerTick = now
    if Overlord.ZoneControl and Overlord.Zones then
        local zones
        if Overlord.GetRemoteObserverZones then
            zones = Overlord:GetRemoteObserverZones(self:GetPanelViewFrontId())
        else
            zones = Overlord.Zones:GetDisplayOrderForFront(self:GetPanelViewFrontId()) or {}
        end
        for _, zone in ipairs(zones) do
            Overlord.ZoneControl:TickRemoteObserverZone(zone, dt)
        end
    end
    self:RefreshActiveZone()
    self:UpdateZoneListTimers()
    if now - spectatorLastFullRefresh >= SPECTATOR_FULL_REFRESH_INTERVAL then
        spectatorLastFullRefresh = now
        self:RefreshZoneList()
        self:RefreshDomination()
    end
end

function Overlord.UI:StartSpectatorMode()
    if Overlord.InActiveFront then return end
    -- Refresh UI depuis les donnees locales (zero cout reseau)
    if not spectatorRefreshTicker then
        spectatorLastFullRefresh = 0
        spectatorLastTimerTick = nil
        spectatorRefreshTicker = C_Timer.NewTicker(SPECTATOR_TIMER_INTERVAL, function()
            if Overlord.InActiveFront or Overlord.InstanceSuspended then
                Overlord.UI:StopSpectatorMode()
                return
            end
            -- Re-tenter l'activation si ZONE_CHANGED a ete manque (voyage rapide, chargement).
            if Overlord.CheckActiveFrontZone then
                Overlord:CheckActiveFrontZone()
            end
            if Overlord.UI and Overlord.UI:IsVisible() then
                Overlord.UI:RefreshSpectatorLocal()
            else
                Overlord.UI:StopSpectatorMode()
            end
        end)
    end
    -- Sync territoriale legere toutes les 2 min. Le mode spectateur ne doit jamais
    -- demander la construction du classement entier chez les receveurs idle.
    if not spectatorSyncTicker then
        if Overlord.Sync then
            Overlord.Sync:SendSyncRequest({ territorialOnly = true })
        end
        spectatorSyncTicker = C_Timer.NewTicker(120, function()
            if Overlord.InActiveFront or Overlord.InstanceSuspended or not Overlord.UI or not Overlord.UI:IsVisible() then
                Overlord.UI:StopSpectatorMode()
                return
            end
            if Overlord.Sync then
                Overlord.Sync:SendSyncRequest({ territorialOnly = true })
            end
        end)
    end
end

function Overlord.UI:StopSpectatorMode()
    if spectatorRefreshTicker then
        spectatorRefreshTicker:Cancel()
        spectatorRefreshTicker = nil
    end
    spectatorLastTimerTick = nil
    if spectatorSyncTicker then
        spectatorSyncTicker:Cancel()
        spectatorSyncTicker = nil
    end
end

function Overlord.UI:IsSpectatorSyncActive()
    return spectatorSyncTicker ~= nil
end

-- ============ Show / Hide / Toggle ============

function Overlord.UI:GetMainFrame()
    return mainFrame
end

function Overlord.UI:IsVisible()
    return mainFrame and mainFrame:IsShown()
end

-- Cache le panel en combat et le re-affiche en sortie de combat
local hiddenByCombat = false
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        if mainFrame and mainFrame:IsShown() then
            hiddenByCombat = true
            mainFrame:Hide()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if hiddenByCombat and mainFrame then
            hiddenByCombat = false
            mainFrame:Show()
            if Overlord.UI then Overlord.UI:Refresh() end
        end
    end
end)

-- Appele a la deconnexion : ecrit la position actuelle dans SavedVariables (secours si le drag n'a pas persiste)
function Overlord.UI:PersistPanelPosition()
    if not userMovedPanel or not mainFrame or not OverlordDB then return end
    SaveFramePosition()
end

function Overlord.UI:ResetPosition()
    userMovedPanel = false
    if mainFrame then mainFrame:SetUserPlaced(false) end
    if OverlordDB then
        OverlordDB.panelPos = nil
        OverlordDB.panelAnchor = nil
        OverlordDB.shardPopupPos = nil
        OverlordDB.shardPopupUserPlaced = nil
        OverlordDB.shardPopupLocked = nil
    end
    self:UpdatePanelAnchor()
    if self._shardMismatchPopup and self._shardMismatchPopup:IsShown() then
        ApplyShardPopupPosition(self._shardMismatchPopup)
    end
end

function Overlord.UI:Show(opts)
    if Overlord.InstanceSuspended then
        Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.DISABLED_IN_INSTANCE)
        return
    end
    local skipRefresh = type(opts) == "table" and opts.skipRefresh
    if mainFrame then
        self:UpdatePanelAnchor()
        mainFrame:Show()
        if Overlord.Popups and Overlord.Popups.SyncFeaturedFrontDock then
            Overlord.Popups:SyncFeaturedFrontDock()
        end
        if Overlord.CheckActiveFrontZone then
            Overlord:CheckActiveFrontZone()
        end
        if not skipRefresh then
            if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
                Overlord.MapMarkers:RequestOverlayRefresh()
            end
            self:Refresh()
            -- Meme frame : layout pas toujours finalise, GetWidth() peut rester 0 pour la barre domination.
            C_Timer.After(0, function()
                if Overlord.UI and Overlord.UI.RefreshDomination then
                    Overlord.UI:RefreshDomination()
                end
            end)
        end
        if OverlordDB and OverlordDB.config then
            OverlordDB.config.uiVisible = true
        end
        if not Overlord.InActiveFront then
            self:StartSpectatorMode()
        end
        if Overlord.Button and Overlord.Button.Show then
            Overlord.Button:Show()
        end
    end
end

-- autoHide = true : hors du front monde (masquage auto), preserve uiVisible pour le retour
function Overlord.UI:Hide(autoHide)
    if mainFrame then
        if Overlord.Button and Overlord.Button.Hide then
            Overlord.Button:Hide()
        end
        mainFrame:Hide()
        hiddenByCombat = false
        self:StopSpectatorMode()
        if not autoHide and OverlordDB and OverlordDB.config then
            OverlordDB.config.uiVisible = false
        end
    end
end

function Overlord.UI:Toggle()
    if mainFrame then
        if mainFrame:IsShown() then
            self:Hide()
        else
            self:Show()
        end
    end
end
