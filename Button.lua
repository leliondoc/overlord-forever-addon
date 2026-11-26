-- Button.lua - Appel de faction et role General (communaute Overlord)
Overlord = Overlord or {}
Overlord.Button = {}

local L = Overlord.L

local BTN_SIZE = 36

local btnFrame = nil
local generalBtnFrame = nil
local cdFrame = nil
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

-- The guild horn, next to the faction's in the same prompt.
local function GetGuildCooldownRemaining()
    if Overlord.Sync and Overlord.Sync.GetGuildCallCooldownRemaining then
        return Overlord.Sync:GetGuildCallCooldownRemaining()
    end
    return 0
end

local function PlayerHasGuild()
    return IsInGuild and IsInGuild() and true or false
end

local function GuildHornReady()
    return PlayerHasGuild() and GetGuildCooldownRemaining() <= 0
end

local function FormatCooldown(sec)
    sec = math.max(0, math.ceil(sec))
    local h = math.floor(sec / 3600)
    local m = math.floor(sec % 3600 / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
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
    -- The button opens both horns: it shows the faction's countdown, or greys, only when the
    -- guild horn cannot sound either.
    local guildReady = GuildHornReady()
    if rem > 0 and not guildReady then
        local now = GetTime()
        -- Re-ancre le swipe seulement si le reste serveur a derive (>1.5 s)
        if not cdSwipeExpireAt or math.abs((cdSwipeExpireAt - now) - rem) > 1.5 then
            cdSwipeExpireAt = now + rem
            cdFrame:SetCooldown(now, rem)
        end
        -- Le chrono remplace le libelle : pose sur l'icone, il debordait sur le texte.
        if btnFrame.label then btnFrame.label:SetText(FormatCooldown(rem)) end
        btnFrame.icon:SetDesaturated(true)
        btnFrame.icon:SetAlpha(0.45)
    else
        cdSwipeExpireAt = nil
        cdFrame:Clear()
        if btnFrame.label and L.FACTION_CALL_BUTTON then btnFrame.label:SetText(L.FACTION_CALL_BUTTON) end
        if not guildReady and (rem > 0 or not Overlord.InActiveFront) then
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

local function CooldownTickerWanted()
    return not Overlord.InstanceSuspended and Overlord.UI and Overlord.UI.IsVisible
        and Overlord.UI:IsVisible() and true or false
end

-- The countdown only ticks while the panel shows it: opening the panel runs
-- Button:Show -> Refresh, which repaints the true remaining time and restarts it.
-- A ready guild horn is what the button shows: the faction countdown under it changes nothing
-- on screen, so no 1 s repaint for its 4 h (the tick that sees the guild delay end still repaints).
local function AnyCooldownRunning()
    return not GuildHornReady() and (GetCooldownRemaining() > 0 or GetGuildCooldownRemaining() > 0)
end

local function StartCooldownTicker()
    StopCooldownTicker()
    if not AnyCooldownRunning() then return end
    if not CooldownTickerWanted() then return end
    cdTicker = C_Timer.NewTicker(1, function()
        if not CooldownTickerWanted() then
            StopCooldownTicker()
            return
        end
        UpdateCooldownVisual()
        if not AnyCooldownRunning() then
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
        GameTooltip:AddLine(L.FACTION_CALL_BUTTON, t.HL[1], t.HL[2], t.HL[3])
        GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP, t.BODY[1], t.BODY[2], t.BODY[3], true)
        local rem = GetCooldownRemaining()
        if rem > 0 then
            GameTooltip:AddLine(string.format(L.FACTION_CALL_TOOLTIP_CD, FormatCooldown(rem)), t.MUTED[1], t.MUTED[2], t.MUTED[3])
        elseif not Overlord.InActiveFront then
            GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP_NOT_IN_FRONT, t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        else
            GameTooltip:AddLine(L.FACTION_CALL_TOOLTIP_SHARED, t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        end
        if PlayerHasGuild() then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L.GUILD_CALL_TOOLTIP, t.BODY[1], t.BODY[2], t.BODY[3], true)
            local guildRem = GetGuildCooldownRemaining()
            if guildRem > 0 then
                GameTooltip:AddLine(string.format(L.FACTION_CALL_TOOLTIP_CD, FormatCooldown(guildRem)), t.MUTED[1], t.MUTED[2], t.MUTED[3])
            else
                GameTooltip:AddLine(L.GUILD_CALL_TOOLTIP_SHARED, t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
            end
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
    if AnyCooldownRunning() then
        StartCooldownTicker()
    else
        StopCooldownTicker()
    end
end

-- Libelle du bouton de la grille : chrono pendant le cooldown, sinon "Call to Arms".
function Overlord.Button:RefreshFactionCallLabel()
    UpdateCooldownVisual()
end

function Overlord.Button:Show()
    if Overlord.InstanceSuspended then return end
    self:EnsureCreated()
    self:Refresh()
end

function Overlord.Button:Hide()
    StopCooldownTicker()
end

-- ---------- Appel aux armes : invite de confirmation ----------
-- Un clic sur le bouton de la grille n'envoie rien : il ouvre le bouton de caserne du camp
-- du joueur (decoration d'origine, 256 x 128) au centre de l'ecran, avec un cor dans sa
-- fente : ni fond ni texte. C'est le clic sur le cor qui sonne l'appel ; un clic ailleurs,
-- Echap ou dix secondes referment l'invite.
-- Deux casernes cote a cote pour un joueur en guilde, le cor de la faction a gauche,
-- celui de la guilde (tabard) a droite. Un cor qui ne peut pas sonner reste visible, grise,
-- avec son temps restant ou, au survol, la raison.
local CALL_PROMPT_ICON = "Interface\\Icons\\INV_Misc_Horn_01"
local GUILD_CALL_ICON = "Interface\\Icons\\INV_Shirt_GuildTabard_01"
local CALL_PROMPT_DECO = {
    Alliance = "garrzoneability-barracksalliance",
    Horde = "garrzoneability-barrackshorde",
}
local CALL_PROMPT_ARM_DELAY = 0.35 -- un double-clic sur la grille ne confirme pas
local CALL_PROMPT_TIMEOUT = 10
local CALL_PROMPT_GAP = 12
local callPrompt = nil

-- Ce qui distingue les deux cors ; les textes sont des cles de L, lues au survol.
local CALL_HORNS = {
    faction = {
        icon = CALL_PROMPT_ICON, remaining = GetCooldownRemaining,
        ready = function() return Overlord.InActiveFront == true end,
        title = "FACTION_CALL_TOOLTIP_TITLE", shared = "FACTION_CALL_TOOLTIP_SHARED",
        blockedTip = "FACTION_CALL_TOOLTIP_NOT_IN_FRONT", blockedMsg = "FACTION_CALL_NOT_IN_FRONT",
    },
    guild = {
        icon = GUILD_CALL_ICON, remaining = GetGuildCooldownRemaining,
        ready = PlayerHasGuild,
        title = "GUILD_CALL_TOOLTIP_TITLE", shared = "GUILD_CALL_TOOLTIP_SHARED",
        blockedTip = "GUILD_CALL_NO_GUILD", blockedMsg = "GUILD_CALL_NO_GUILD",
    },
}

local function HideCallPrompt()
    if callPrompt then callPrompt:Hide() end
end

local function CreateCallHorn(f, kind)
    local spec = CALL_HORNS[kind]
    local box = CreateFrame("Frame", nil, f)
    box:SetSize(256, 128)

    -- La fente des deux decorations fait 42 a 44 px, centree 1 px sous le milieu.
    local horn = CreateFrame("Button", nil, box)
    horn:SetSize(46, 46)
    horn:SetPoint("CENTER", 0, -1)
    horn:RegisterForClicks("LeftButtonUp")
    horn._olCallHorn = true
    local icon = horn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(spec.icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local glow = horn:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    glow:SetBlendMode("ADD")
    horn:SetScript("OnMouseDown", function()
        if box._ready then icon:SetVertexColor(0.7, 0.7, 0.7) end
    end)
    horn:SetScript("OnMouseUp", function()
        if box._ready then icon:SetVertexColor(1, 1, 1) end
    end)
    horn:SetScript("OnClick", function()
        if GetTime() - (f._shownAt or 0) < CALL_PROMPT_ARM_DELAY then return end
        if spec.remaining() > 0 then return end
        if not spec.ready() then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L[spec.blockedMsg] or ""))
            return
        end
        HideCallPrompt()
        if kind == "guild" then
            Overlord.Button:OnGuildCallClick()
        else
            Overlord.Button:OnClick(true)
        end
    end)
    horn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("BOTTOM", box, "TOP", 0, 2)
        local t = Overlord.UI.TooltipPalette()
        -- Titre et delai seulement : ce que fait l'appel est dit sur le bouton de la grille.
        GameTooltip:AddLine(L[spec.title] or "", t.HL[1], t.HL[2], t.HL[3])
        local rem = spec.remaining()
        if rem > 0 then
            GameTooltip:AddLine(string.format(L.FACTION_CALL_TOOLTIP_CD, FormatCooldown(rem)), t.MUTED[1], t.MUTED[2], t.MUTED[3])
        elseif not spec.ready() then
            GameTooltip:AddLine(L[spec.blockedTip] or "", t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        else
            GameTooltip:AddLine(L[spec.shared] or "", t.MUTED[1], t.MUTED[2], t.MUTED[3], true)
        end
        GameTooltip:Show()
    end)
    horn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- La decoration passe au-dessus de l'icone (ses bords la sertissent) sans prendre la souris.
    local decoFrame = CreateFrame("Frame", nil, box)
    decoFrame:SetAllPoints()
    decoFrame:SetFrameLevel(horn:GetFrameLevel() + 1)
    box.deco = decoFrame:CreateTexture(nil, "ARTWORK")
    box.deco:SetPoint("CENTER")

    local countdown = decoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countdown:SetPoint("CENTER", horn, "CENTER", 0, 0)
    countdown:SetShadowOffset(1, -1)

    -- Etat du cor : pret, ou grise (mais visible) avec le temps restant ecrit dessus.
    function box.Refresh()
        local rem = spec.remaining()
        countdown:SetText(rem > 0 and FormatCooldown(rem) or "")
        local ready = rem <= 0 and spec.ready() and true or false
        if box._ready ~= ready then
            box._ready = ready
            icon:SetDesaturated(not ready)
            if ready then icon:SetVertexColor(1, 1, 1) else icon:SetVertexColor(0.6, 0.6, 0.6) end
            glow:SetAlpha(ready and 1 or 0)
        end
    end
    return box
end

local function CreateCallPrompt()
    -- Plein ecran, invisible : un clic hors des cors referme. Enfant du bouton de la grille,
    -- l'invite disparait avec le panneau (instance comprise).
    local f = CreateFrame("Button", nil, btnFrame)
    f:SetFrameStrata("DIALOG")
    f:SetAllPoints(UIParent)
    f:RegisterForClicks("AnyUp")
    f:SetScript("OnClick", HideCallPrompt)
    f:Hide()

    f.horns = { faction = CreateCallHorn(f, "faction"), guild = CreateCallHorn(f, "guild") }
    local function refresh()
        for _, box in pairs(f.horns) do
            if box:IsShown() then box.Refresh() end
        end
    end
    local ticker = nil
    f:SetScript("OnShow", function(self)
        self._shownAt = GetTime()
        refresh()
        if not ticker then ticker = C_Timer.NewTicker(1, refresh) end
    end)
    -- Panneau ferme pendant l'invite : elle ne doit pas revenir avec lui.
    f:SetScript("OnHide", function(self)
        if ticker then ticker:Cancel(); ticker = nil end
        local owner = GameTooltip:GetOwner()
        if owner and owner._olCallHorn then GameTooltip:Hide() end
        self:Hide()
    end)
    if Overlord.UI and Overlord.UI.BindEscapeClose then
        Overlord.UI.BindEscapeClose(f, HideCallPrompt)
    end
    return f
end

local function ShowCallPrompt()
    if not btnFrame then return false end
    local deco = CALL_PROMPT_DECO[Overlord.PlayerFaction or UnitFactionGroup("player")]
    if not deco then return false end
    callPrompt = callPrompt or CreateCallPrompt()
    local f = callPrompt
    local faction, guild = f.horns.faction, f.horns.guild
    faction:ClearAllPoints()
    guild:ClearAllPoints()
    if PlayerHasGuild() then
        faction:SetPoint("RIGHT", UIParent, "CENTER", -CALL_PROMPT_GAP / 2, 0)
        guild:SetPoint("LEFT", UIParent, "CENTER", CALL_PROMPT_GAP / 2, 0)
        guild:Show()
    else
        faction:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        guild:Hide()
    end
    faction.deco:SetAtlas(deco, true)
    guild.deco:SetAtlas(deco, true)
    f:Show()
    local shownAt = f._shownAt
    C_Timer.After(CALL_PROMPT_TIMEOUT, function()
        if f:IsShown() and f._shownAt == shownAt then f:Hide() end
    end)
    return true
end

-- confirmed : vrai quand le clic vient du cor de la faction. Hors instance un clic sur la
-- grille ouvre toujours l'invite (le cor de la guilde sonne aussi hors front et en combat) ;
-- combat, delai et hors front se disent au clic sur le cor de la faction.
function Overlord.Button:OnClick(confirmed)
    if Overlord.InstanceSuspended then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L.DISABLED_IN_INSTANCE or ""))
        return
    end
    if not confirmed and ShowCallPrompt() then return end
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
    -- Seul le clic sur le cor envoie : sans invite possible, rien ne part.
    if not confirmed then return end
    local payload = Overlord.Sync:BuildFactionCallPayload()
    if not payload then return end
    local sent = Overlord.Sync:BroadcastFactionCall(payload)
    if not sent or sent == 0 then
        local remAfter = GetCooldownRemaining()
        if remAfter > 0 then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(
                L.FACTION_CALL_COOLDOWN_SHARED, FormatCooldown(remAfter)))
        else
            Overlord:PrintNotification("|cFFFF8C33[Overlord]|r " .. L.FACTION_CALL_NO_ONLINE)
        end
        return
    end
    self:Refresh()
    StartCooldownTicker()
    if Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("faction_call")
    end
    Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.FACTION_CALL_SENT)
end

-- Le cor de la guilde : partout hors instance, combat compris.
function Overlord.Button:OnGuildCallClick()
    if Overlord.InstanceSuspended then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L.DISABLED_IN_INSTANCE or ""))
        return
    end
    local sync = Overlord.Sync
    if not sync or not sync.BroadcastGuildCall then return end
    if not PlayerHasGuild() then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GUILD_CALL_NO_GUILD)
        return
    end
    local rem = GetGuildCooldownRemaining()
    if rem > 0 then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.GUILD_CALL_COOLDOWN, FormatCooldown(rem)))
        return
    end
    if not sync:BroadcastGuildCall(sync:BuildGuildCallPayload()) then
        Overlord:PrintNotification("|cFFFF8C33[Overlord]|r " .. L.GUILD_CALL_FAILED)
        return
    end
    self:Refresh()
    if Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("faction_call")
    end
    Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.GUILD_CALL_SENT)
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

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["Button.lua"] = function() return { BTN_SIZE = BTN_SIZE, btnFrame = btnFrame, generalBtnFrame = generalBtnFrame, cdFrame = cdFrame, cdTicker = cdTicker, cdSwipeExpireAt = cdSwipeExpireAt, FACTION_ICON = FACTION_ICON, GENERAL_GRID_ICON = GENERAL_GRID_ICON, PANEL_BADGE_SCALE = PANEL_BADGE_SCALE, C_ALLIANCE = C_ALLIANCE, C_HORDE = C_HORDE, C = C, CALL_PROMPT_ICON = CALL_PROMPT_ICON, CALL_PROMPT_DECO = CALL_PROMPT_DECO, CALL_PROMPT_ARM_DELAY = CALL_PROMPT_ARM_DELAY, CALL_PROMPT_TIMEOUT = CALL_PROMPT_TIMEOUT, GUILD_CALL_ICON = GUILD_CALL_ICON, CALL_PROMPT_GAP = CALL_PROMPT_GAP, CALL_HORNS = CALL_HORNS, callPrompt = callPrompt, parentShowHooked = parentShowHooked } end
