-- Button.lua - Appel de faction et role General (communaute Overlord)
Overlord = Overlord or {}
Overlord.Button = {}

local L = Overlord.L

local COOLDOWN_SEC = 600
local FACTION_CALL_MIN_ENEMIES = 5
local BTN_SIZE = 36
local BTN_GAP = 4

local btnFrame = nil
local generalBtnFrame = nil
local cdFrame = nil
local cdText = nil
local cdTicker = nil
local cdSwipeExpireAt = nil -- fin du swipe CooldownFrame (GetTime() session)

local FACTION_ICON = {
    Alliance = "Interface\\Icons\\INV_BannerPVP_02",
    Horde    = "Interface\\Icons\\INV_BannerPVP_01",
}

-- Grille panneau principal : meme disposition icone+texte que les autres boutons WC3.
local GENERAL_GRID_ICON = "Interface\\Icons\\Ability_Warrior_RallyingCry"

-- Agrandissement panneau sans SetTexCoord (incompatible avec SetAtlas en retail)
local PANEL_BADGE_SCALE = 1.5

local function GetGeneralTooltipTitle()
    if Overlord.PlayerFaction == "Horde" then
        return L.GENERAL_TOOLTIP_TITLE_HORDE
    end
    return L.GENERAL_TOOLTIP_TITLE_ALLIANCE
end

-- Palette WC3 (alignee sur UI.lua)
local C_ALLIANCE = {
    gold = { 0.85, 0.68, 0.20 },
    bg   = { 0.12, 0.12, 0.18 },
    white = { 0.925, 0.937, 0.969 },
}
local C_HORDE = {
    gold = { 0.82, 0.22, 0.12 },
    bg   = { 0.14, 0.08, 0.06 },
    white = { 0.941, 0.878, 0.753 },
}
local C = C_ALLIANCE

local function GetCooldownRemaining()
    if Overlord.Sync and Overlord.Sync.GetFactionCallCooldownRemaining then
        return Overlord.Sync:GetFactionCallCooldownRemaining()
    end
    return 0
end

local function FormatCooldown(sec)
    sec = math.max(0, math.ceil(sec))
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%d:%02d", m, s)
end

local function HasCommunityClub()
    return Overlord.Sync and Overlord.Sync.FindCommunityClub and Overlord.Sync:FindCommunityClub()
end

local function HasNearbyEnemies(forceRefresh)
    if not Overlord.InActiveFront then return false end
    if Overlord.UI and Overlord.UI.GetNearbyEnemyCountRaw then
        return Overlord.UI:GetNearbyEnemyCountRaw(forceRefresh) >= FACTION_CALL_MIN_ENEMIES
    end
    return false
end

local function GetRedChrome()
    if Overlord.UI and Overlord.UI.GetWC3RedButtonChrome then
        return Overlord.UI.GetWC3RedButtonChrome()
    end
    return nil
end

local function IsGridActionButton(btn)
    return btn and (btn == btnFrame or (btn == generalBtnFrame and btn._olGridIcon))
end

local function ApplyButtonBackdrop(btn, borderAlpha)
    if not btn then return end
    if IsGridActionButton(btn) and Overlord.UI and Overlord.UI.ApplyWC3ButtonChrome then
        local active = btn._olActiveChrome and true or false
        Overlord.UI.ApplyWC3ButtonChrome(btn, active, { gold = C.gold, white = C.white })
        return
    end
    borderAlpha = borderAlpha or 0.6
    if btn._olHover then borderAlpha = 1 end
    btn:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], 0.92)
    btn:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], borderAlpha)
end

local function ApplyGeneralGridIconLayout(btn)
    if not btn or not btn.icon or not btn.label then return end
    local h = btn:GetHeight() or 28
    local iconSize = h - 8
    local layoutKey = tostring(iconSize)
    if btn._olGridIconLayoutKey == layoutKey then return end
    btn._olGridIconLayoutKey = layoutKey
    btn.icon:ClearAllPoints()
    btn.icon:SetSize(iconSize, iconSize)
    btn.label:ClearAllPoints()
    btn.label:SetPoint("CENTER", btn, "CENTER", iconSize / 2 + 2, 0)
    btn.icon:SetPoint("RIGHT", btn.label, "LEFT", -4, 0)
end

local function ApplyGeneralGridIconTexture(icon)
    if not icon then return end
    if icon.SetAtlas then
        pcall(icon.SetAtlas, icon, nil)
    end
    icon:SetTexture(GENERAL_GRID_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:Show()
end

local function ApplyGeneralPanelIconLayout(tex, btn)
    if not tex or not btn then return end
    local size = btn._olPanelBadgeSize
    if not size then
        size = math.floor((btn:GetHeight() or BTN_SIZE) * (btn._olPanelBadgeScale or PANEL_BADGE_SCALE))
    end
    local layoutKey = tostring(size)
    if tex._olPanelLayoutKey == layoutKey then return end
    tex._olPanelLayoutKey = layoutKey
    tex:ClearAllPoints()
    tex:SetSize(size, size)
    tex:SetPoint("CENTER", btn, "CENTER", 0, 0)
end

local function ApplyGeneralFactionIcon(tex, faction)
    if not tex then return end
    faction = faction or Overlord.PlayerFaction or UnitFactionGroup("player")
    local atlas
    if Overlord.General and type(Overlord.General.GetFactionBadgeAtlas) == "function" then
        atlas = Overlord.General:GetFactionBadgeAtlas(faction)
    end
    if not atlas or type(tex.SetAtlas) ~= "function" then return end

    local panelKey = faction .. ":" .. atlas
    if tex._olPanelKey == panelKey then return end
    tex._olPanelKey = panelKey

    if generalBtnFrame and generalBtnFrame._olPanelBadge ~= false then
        ApplyGeneralPanelIconLayout(tex, generalBtnFrame)
    end

    if type(tex.SetTexture) == "function" then
        pcall(tex.SetTexture, tex, nil)
    end
    if type(tex.SetTexCoord) == "function" then
        tex:SetTexCoord(0, 1, 0, 1)
    end
    -- Meme methode que GeneralMap.lua (pas useAtlasSize : la taille du bouton prime)
    pcall(tex.SetAtlas, tex, atlas)
    tex:Show()
end

local function ApplyTheme()
    C = (Overlord.PlayerFaction == "Horde") and C_HORDE or C_ALLIANCE
    if btnFrame then
        ApplyButtonBackdrop(btnFrame)
        if btnFrame.icon then
            local tex = FACTION_ICON[Overlord.PlayerFaction] or FACTION_ICON.Alliance
            btnFrame.icon:SetTexture(tex)
        end
    end
end

local function UpdateCooldownVisual()
    if not btnFrame or not cdFrame then return end
    local rem = GetCooldownRemaining()
    if rem > 0 then
        local now = GetTime()
        -- Re-ancre le swipe seulement si le reste serveur a derive (>1.5 s)
        if not cdSwipeExpireAt or math.abs((cdSwipeExpireAt - now) - rem) > 1.5 then
            cdSwipeExpireAt = now + rem
            cdFrame:SetCooldown(now, rem)
        end
        if cdText then
            cdText:SetText(FormatCooldown(rem))
            cdText:Show()
        end
        btnFrame.icon:SetDesaturated(true)
        btnFrame.icon:SetAlpha(0.45)
    else
        cdSwipeExpireAt = nil
        cdFrame:Clear()
        if cdText then cdText:Hide() end
        if not HasCommunityClub() or not HasNearbyEnemies(false) then
            btnFrame.icon:SetDesaturated(true)
            btnFrame.icon:SetAlpha(0.35)
        else
            btnFrame.icon:SetDesaturated(false)
            btnFrame.icon:SetAlpha(1)
        end
    end
end

local function GetGeneralSlotHolderShort()
    local gen = Overlord.General
    if not gen or not gen.GetSlot then return nil end
    local slot = gen:GetSlot(Overlord.PlayerFaction)
    if not slot or not slot.holder then return nil end
    return (slot.holder:match("^(.-)%-") or slot.holder)
end

local function IsGeneralFrontContext()
    if Overlord.General and Overlord.General.IsGeneralFrontContext then
        return Overlord.General:IsGeneralFrontContext()
    end
    return Overlord.InActiveFront == true
end

function Overlord.Button:RefreshGeneralButton()
    if not generalBtnFrame or not generalBtnFrame.icon then return end
    if generalBtnFrame._olUnavailable then return end
    local icon = generalBtnFrame.icon
    local gen = Overlord.General
    local active = gen and gen.IsLocalHolder and gen:IsLocalHolder()
    local slotHolder = GetGeneralSlotHolderShort()
    local slotTakenByOther = slotHolder and not active
    local canLead = gen and gen.IsRaidLeader and gen:IsRaidLeader()
    local disabled = not active and (
        Overlord.InstanceSuspended
        or not canLead
        or slotTakenByOther
        or not IsGeneralFrontContext()
        or not HasCommunityClub()
    )

    local faction = Overlord.PlayerFaction or UnitFactionGroup("player")
    if generalBtnFrame._olGridIcon then
        ApplyGeneralGridIconLayout(generalBtnFrame)
        if generalBtnFrame._olAtlasKey ~= "grid" then
            generalBtnFrame._olAtlasKey = "grid"
            ApplyButtonBackdrop(generalBtnFrame)
            ApplyGeneralGridIconTexture(icon)
        end
    else
        local atlasKey = faction
        if gen and gen.GetFactionBadgeAtlas then
            atlasKey = faction .. ":" .. (gen:GetFactionBadgeAtlas(faction) or "")
        end
        if generalBtnFrame._olAtlasKey ~= atlasKey then
            generalBtnFrame._olAtlasKey = atlasKey
            ApplyButtonBackdrop(generalBtnFrame)
            ApplyGeneralFactionIcon(icon, faction)
        end
    end

    local stateKey = (active and "1" or "0") .. (disabled and "1" or "0")
        .. (generalBtnFrame._olHover and "1" or "0")
    if generalBtnFrame._olStateKey == stateKey then return end
    generalBtnFrame._olStateKey = stateKey

    if active then
        icon:SetDesaturated(false)
        icon:SetAlpha(1)
    elseif disabled then
        icon:SetDesaturated(true)
        icon:SetAlpha(0.35)
    else
        icon:SetDesaturated(false)
        icon:SetAlpha(0.85)
    end

    if generalBtnFrame._olGridIcon and Overlord.UI and Overlord.UI.ApplyWC3ButtonChrome then
        Overlord.UI.ApplyWC3ButtonChrome(generalBtnFrame, active, { gold = C.gold, white = C.white })
    end
end

local function StopCooldownTicker()
    if cdTicker then
        cdTicker:Cancel()
        cdTicker = nil
    end
end

local function StartCooldownTicker()
    StopCooldownTicker()
    if GetCooldownRemaining() <= 0 then return end
    cdTicker = C_Timer.NewTicker(1, function()
        UpdateCooldownVisual()
        if GetCooldownRemaining() <= 0 then
            StopCooldownTicker()
        end
    end)
end

local function WireFactionCallGridButton(btn)
    if not btn or not btn.icon then return end
    btnFrame = btn

    if not cdFrame then
        cdFrame = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
        cdFrame:SetAllPoints(btn.icon)
        cdFrame:SetDrawEdge(false)
        cdFrame:SetHideCountdownNumbers(true)
        cdFrame:EnableMouse(false)
    end
    if not cdText then
        cdText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cdText:SetPoint("CENTER", btn.icon, "CENTER", 0, 0)
        cdText:SetFont(cdText:GetFont(), 10, "OUTLINE")
        cdText:SetTextColor(1, 0.95, 0.75)
        cdText:EnableMouse(false)
        cdText:Hide()
    end

    btn:SetScript("OnClick", function()
        Overlord.Button:OnClick()
    end)
    btn:SetScript("OnEnter", function(self)
        self._fcHover = true
        local r = GetRedChrome()
        if self._olActiveChrome and r then
            self:SetBackdropColor(r.bgHover[1], r.bgHover[2], r.bgHover[3], 1)
            self:SetBackdropBorderColor(r.borderHover[1], r.borderHover[2], r.borderHover[3], 1)
        else
            self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
        end
        if self.label then
            self.label:SetTextColor(C.white[1], C.white[2], C.white[3])
        end
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 8)
        local t = Overlord.UI.TooltipPalette()
        GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP_TITLE, t.HL[1], t.HL[2], t.HL[3])
        GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP, t.BODY[1], t.BODY[2], t.BODY[3], true)
        local rem = GetCooldownRemaining()
        if rem > 0 then
            GameTooltip:AddLine(string.format(L.FACTION_CALL_TOOLTIP_CD, FormatCooldown(rem)), t.MUTED[1], t.MUTED[2], t.MUTED[3])
        elseif not Overlord.InActiveFront then
            GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP_NOT_IN_FRONT, t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        elseif not HasCommunityClub() then
            GameTooltip:AddLine(L.FACTION_CALL_NO_COMMUNITY, t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        elseif not HasNearbyEnemies(false) then
            GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP_NO_ENEMIES, t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        else
            GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP_SHARED, t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        self._fcHover = false
        ApplyButtonBackdrop(self)
        if self.label and self.baseTextColor then
            self.label:SetTextColor(self.baseTextColor[1], self.baseTextColor[2], self.baseTextColor[3])
        end
        GameTooltip:Hide()
    end)
end

local function WireGeneralGridButton(btn)
    if not btn or not btn.icon then return end
    generalBtnFrame = btn
    generalBtnFrame._olPanelBadge = false
    generalBtnFrame._olGridIcon = true
    btn.icon._olPanelLayoutKey = nil
    btn.icon._olPanelKey = nil
    ApplyGeneralGridIconTexture(btn.icon)
    ApplyGeneralGridIconLayout(btn)

    btn:SetScript("OnClick", function()
        Overlord.Button:OnGeneralClick()
    end)
    btn:SetScript("OnEnter", function(self)
        self._olHover = true
        local r = GetRedChrome()
        if self._olActiveChrome and r then
            self:SetBackdropColor(r.bgHover[1], r.bgHover[2], r.bgHover[3], 1)
            self:SetBackdropBorderColor(r.borderHover[1], r.borderHover[2], r.borderHover[3], 1)
        else
            self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
        end
        if self.label then
            self.label:SetTextColor(C.white[1], C.white[2], C.white[3])
        end
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 8)
        local t = Overlord.UI.TooltipPalette()
        GameTooltip:AddLine(GetGeneralTooltipTitle(), t.HL[1], t.HL[2], t.HL[3])
        GameTooltip:AddLine(L.GENERAL_TOOLTIP or "", t.BODY[1], t.BODY[2], t.BODY[3], true)
        local gen = Overlord.General
        local active = gen and gen.IsLocalHolder and gen:IsLocalHolder()
        local slotHolder = GetGeneralSlotHolderShort()
        if active then
            GameTooltip:AddLine(L.GENERAL_TOOLTIP_RELEASE or "", t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        elseif Overlord.InstanceSuspended then
            GameTooltip:AddLine(L.GENERAL_INSTANCE or "", t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        elseif gen and gen.IsRaidLeader and not gen:IsRaidLeader() then
            GameTooltip:AddLine(L.GENERAL_NOT_LEADER or "", t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        elseif slotHolder then
            GameTooltip:AddLine(string.format(L.GENERAL_SLOT_TAKEN or "%s", slotHolder), t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        elseif not Overlord.InActiveFront then
            GameTooltip:AddLine(L.GENERAL_NOT_ON_FRONT or "", t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        elseif not HasCommunityClub() then
            GameTooltip:AddLine(L.GENERAL_NOT_COMMUNITY or "", t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        self._olHover = false
        Overlord.Button:RefreshGeneralButton()
        if self.label and self.baseTextColor then
            self.label:SetTextColor(self.baseTextColor[1], self.baseTextColor[2], self.baseTextColor[3])
        end
        GameTooltip:Hide()
    end)
end

function Overlord.Button:AttachActionGridButtons(factionBtn, generalBtn)
    ApplyTheme()
    WireFactionCallGridButton(factionBtn)
    WireGeneralGridButton(generalBtn)
    if Overlord.UI and Overlord.UI.ApplyWC3ButtonChrome then
        local opts = { gold = C.gold, white = C.white }
        Overlord.UI.ApplyWC3ButtonChrome(factionBtn, false, opts)
        Overlord.UI.ApplyWC3ButtonChrome(generalBtn, false, opts)
    end
    self:Refresh()
    if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
        Overlord.UI:ScheduleActionGridActiveRefresh()
    end
end

function Overlord.Button:Refresh()
    ApplyTheme()
    UpdateCooldownVisual()
    self:RefreshGeneralButton()
    if GetCooldownRemaining() > 0 then
        StartCooldownTicker()
    else
        StopCooldownTicker()
    end
end

function Overlord.Button:Show()
    if Overlord.InstanceSuspended then return end
    self:EnsureCreated()
    self:Refresh()
end

function Overlord.Button:Hide()
    StopCooldownTicker()
end

function Overlord.Button:OnClick()
    if Overlord.InstanceSuspended then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L.DISABLED_IN_INSTANCE or ""))
        return
    end
    if InCombatLockdown() then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.FACTION_CALL_COMBAT)
        return
    end
    local rem = GetCooldownRemaining()
    if rem > 0 then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.FACTION_CALL_COOLDOWN_SHARED, FormatCooldown(rem)))
        return
    end
    if not Overlord.InActiveFront then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.FACTION_CALL_NOT_IN_FRONT)
        return
    end
    if not HasNearbyEnemies(true) then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.FACTION_CALL_NO_ENEMIES)
        return
    end
    if not HasCommunityClub() then
        Overlord:PrintNotification("|cffff6600[Overlord]|r " .. L.FACTION_CALL_NO_COMMUNITY)
        return
    end
    local payload = Overlord.Sync:BuildFactionCallPayload()
    if not payload then return end
    local sent = Overlord.Sync:BroadcastFactionCall(payload)
    if not sent or sent == 0 then
        local remAfter = GetCooldownRemaining()
        if remAfter > 0 then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(
                L.FACTION_CALL_COOLDOWN_SHARED, FormatCooldown(remAfter)))
        elseif not HasNearbyEnemies(true) then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.FACTION_CALL_NO_ENEMIES)
        elseif not HasCommunityClub() then
            Overlord:PrintNotification("|cffff6600[Overlord]|r " .. L.FACTION_CALL_NO_COMMUNITY)
        else
            Overlord:PrintNotification("|cffff6600[Overlord]|r " .. L.FACTION_CALL_NO_ONLINE)
        end
        return
    end
    self:Refresh()
    StartCooldownTicker()
    if Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("faction_call")
    end
    Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. string.format(L.FACTION_CALL_SENT, sent))
end

function Overlord.Button:OnGeneralClick()
    if not Overlord.General or not Overlord.General.ToggleRole then return end
    Overlord.General:ToggleRole()
    self:RefreshGeneralButton()
    if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
        Overlord.UI:ScheduleActionGridActiveRefresh()
    end
end

local parentShowHooked = false

local function EnsureParentHooks(parent)
    if parentShowHooked or not parent then return end
    parentShowHooked = true
    parent:HookScript("OnShow", function()
        if Overlord.Button then Overlord.Button:Show() end
    end)
    parent:HookScript("OnHide", function()
        if Overlord.Button then Overlord.Button:Hide() end
    end)
end

function Overlord.Button:EnsureCreated()
    local parent = _G.OverlordMainFrame
    if not parent then return false end
    EnsureParentHooks(parent)
    return btnFrame ~= nil or generalBtnFrame ~= nil
end

function Overlord.Button:Initialize()
    C_Timer.After(0, function()
        if Overlord.InstanceSuspended then return end
        Overlord.Button:EnsureCreated()
    end)
end
