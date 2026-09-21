-- HallOfFameUI.lua - Hall of Fame (clone visuel AchievementFrame Blizzard)
Overlord = Overlord or {}
Overlord.HallOfFameUI = {}

local L = Overlord.L

local hofFrame = nil
local honorCards = {}
local recentCards = {}
local progressBars = {}
local categoryFrames = {}

local selectedCategory = "donors"
local searchText = ""
local achUILoaded = false

local HOF_FRAME_W = 768
local HOF_FRAME_H = 500
local HOF_RECENT_MAX = 4
local HOF_LIST_CARD_PAD_X = 18
local HOF_LIST_CARD_H = 56
-- SummaryAchievementTemplate + barre critères en bas (pas AchievementTemplate : barres natives en double).
local HOF_LIST_CARD_H_LIFETIME = 70
local SEARCH_DEBOUNCE_SEC = 0.18

local ACH_PATH = "Interface\\AchievementFrame\\"

local CARD_OPTS_RECENT = { recentHighlight = true }
local CARD_OPTS_NORMAL = { recentHighlight = false }

local SUB_BAR_DEFS = {
    { key = "HOF_CAT_GUILD", statKey = "guildCount" },
    { key = "HOF_CAT_PLAYER", statKey = "playerCount" },
    { key = "HOF_CAT_LIFETIME", statKey = "lifetimeEarnedCount", totalKey = "lifetimeTotalCount" },
    { key = "HOF_CAT_ALLIANCE", statKey = "allianceCount" },
    { key = "HOF_CAT_HORDE", statKey = "hordeCount" },
    { key = "HOF_CAT_WEEKLY", statKey = "weeklyCount" },
    { key = "HOF_CAT_DONORS", statKey = "donorCount" },
}

local searchDebounceTimer = nil
local hofRefreshPending = false
local hofRefreshLastAt = 0
local HOF_REFRESH_MIN_INTERVAL = 0.25
local lastListCategory = nil
local lastListSearchText = nil
local lastListLayoutCount = 0
local lastListLayoutCategory = nil
local pointsBannerText = nil
local blizzardSummaryIsolationInstalled = false

-- ---------------------------------------------------------------------------
-- Chargement Blizzard_AchievementUI (templates + fonctions bouclier)
-- ---------------------------------------------------------------------------

local function EnsureAchievementUILoaded()
    if achUILoaded then return true end
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI") then
        achUILoaded = true
        return true
    end
    if C_AddOns and C_AddOns.LoadAddOn then
        local ok, reason = C_AddOns.LoadAddOn("Blizzard_AchievementUI")
        if not ok and reason ~= "ADDON_ALREADY_LOADED" then
            return false
        end
    elseif AchievementFrame_LoadUI then
        AchievementFrame_LoadUI()
    end
    achUILoaded = true
    return true
end

-- ---------------------------------------------------------------------------
-- Chrome AchievementFrame (copie Blizzard_AchievementUI.xml)
-- ---------------------------------------------------------------------------

local function ApplyAchievementBackdrop(frame)
    -- Retail : ApplyBackdrop() lit frame.backdropInfo (comme KeyValue XML Blizzard).
    if not frame or not frame.ApplyBackdrop then return end
    local info = BACKDROP_ACHIEVEMENTS_0_64
    if not info then return end
    frame.backdropInfo = info
    frame:ApplyBackdrop()
end

local function BuildAchievementFrameChrome(frame)
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
    bg:SetPoint("TOPLEFT", 16, -16)
    bg:SetPoint("BOTTOMRIGHT", -16, 16)
    bg:SetTexture(ACH_PATH .. "UI-Achievement-AchievementBackground")
    bg:SetTexCoord(0, 1, 0, 0.5)

    local bgCover = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    bgCover:SetPoint("TOPLEFT", bg, "TOPLEFT")
    bgCover:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT")
    bgCover:SetColorTexture(0, 0, 0, 0.75)

    local metalLeft = frame:CreateTexture(nil, "ARTWORK")
    metalLeft:SetTexture(ACH_PATH .. "UI-Achievement-MetalBorder-Left")
    metalLeft:SetSize(16, 436)
    metalLeft:SetPoint("LEFT", 14, 0)
    metalLeft:SetTexCoord(0, 1, 0, 0.87)

    local metalRight = frame:CreateTexture(nil, "ARTWORK")
    metalRight:SetTexture(ACH_PATH .. "UI-Achievement-MetalBorder-Left")
    metalRight:SetSize(16, 436)
    metalRight:SetPoint("RIGHT", -13, 0)
    metalRight:SetTexCoord(1, 0, 0.87, 0)

    local metalBottom = frame:CreateTexture(nil, "ARTWORK")
    metalBottom:SetTexture(ACH_PATH .. "UI-Achievement-MetalBorder-Top")
    metalBottom:SetSize(450, 16)
    metalBottom:SetPoint("BOTTOMLEFT", 28, 13)
    metalBottom:SetPoint("BOTTOMRIGHT", -28, 13)
    metalBottom:SetTexCoord(0, 0.87, 1.0, 0)

    local metalTop = frame:CreateTexture(nil, "ARTWORK")
    metalTop:SetTexture(ACH_PATH .. "UI-Achievement-MetalBorder-Top")
    metalTop:SetSize(450, 16)
    metalTop:SetPoint("TOPLEFT", 28, -12)
    metalTop:SetPoint("TOPRIGHT", -28, -12)
    metalTop:SetTexCoord(0.87, 0, 0, 1)

    local catParchment = frame:CreateTexture(nil, "ARTWORK")
    catParchment:SetTexture(ACH_PATH .. "UI-Achievement-Parchment")
    catParchment:SetSize(195, 0)
    catParchment:SetPoint("TOPLEFT", 25, -23)
    catParchment:SetPoint("BOTTOMLEFT", 25, 23)
    catParchment:SetTexCoord(0, 0.5, 0, 1)

    local watermark = frame:CreateTexture(nil, "OVERLAY")
    watermark:SetTexture(ACH_PATH .. "UI-Achievement-AchievementWatermark")
    watermark:SetSize(256, 256)
    watermark:SetPoint("BOTTOMLEFT", catParchment, "BOTTOMLEFT", 0, 0)

    local function joint(name, point, x, y, tLeft, tRight, tTop, tBottom)
        local t = frame:CreateTexture(nil, "OVERLAY")
        t:SetTexture(ACH_PATH .. "UI-Achievement-MetalBorder-Joint")
        t:SetSize(32, 32)
        t:SetPoint(point, x, y)
        t:SetTexCoord(tLeft, tRight, tTop, tBottom)
        return t
    end
    joint("TOPLEFT", "TOPLEFT", 9, -7, 1, 0, 1, 0)
    joint("TOPRIGHT", "TOPRIGHT", -8, -7, 0, 1, 1, 0)
    joint("BOTTOMLEFT", "BOTTOMLEFT", 9, 8, 1, 0, 0, 1)
    joint("BOTTOMRIGHT", "BOTTOMRIGHT", -8, 8, 0, 1, 0, 1)

    local function woodCorner(point, x, y, tLeft, tRight, tTop, tBottom)
        local t = frame:CreateTexture(nil, "OVERLAY")
        t:SetTexture(ACH_PATH .. "UI-Achievement-WoodBorder-Corner")
        t:SetSize(64, 64)
        t:SetPoint(point, x, y)
        t:SetTexCoord(tLeft, tRight, tTop, tBottom)
    end
    woodCorner("TOPLEFT", 4, -2, 0, 1, 0, 1)
    woodCorner("TOPRIGHT", -4, -2, 1, 0, 0, 1)
    woodCorner("BOTTOMLEFT", 4, 3, 0, 1, 1, 0)
    woodCorner("BOTTOMRIGHT", -4, 3, 1, 0, 1, 0)
end

local function CreateAchievementHeader(parent)
    local header = CreateFrame("Frame", nil, parent)
    header:SetSize(726, 106)
    header:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", 26, -38)

    header.Left = header:CreateTexture(nil, "BACKGROUND")
    header.Left:SetTexture(ACH_PATH .. "UI-Achievement-Header")
    header.Left:SetSize(512, 106)
    header.Left:SetPoint("BOTTOMLEFT")
    header.Left:SetTexCoord(0, 1, 0, 0.4140625)

    header.Right = header:CreateTexture(nil, "BACKGROUND")
    header.Right:SetTexture(ACH_PATH .. "UI-Achievement-Header")
    header.Right:SetSize(215, 100)
    header.Right:SetPoint("BOTTOMLEFT", header.Left, "BOTTOMRIGHT", 0, -6)
    header.Right:SetTexCoord(0, 0.419921875, 0.4140625, 0.8046875)

    header.PointBorder = header:CreateTexture(nil, "BORDER")
    header.PointBorder:SetTexture(ACH_PATH .. "UI-Achievement-Header")
    header.PointBorder:SetSize(133, 39)
    header.PointBorder:SetPoint("BOTTOM", 20, 16)
    header.PointBorder:SetTexCoord(0.419921875, 0.6796875, 0.4140625, 0.56640625)

    header.Title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.Title:SetSize(150, 20)
    header.Title:SetPoint("TOP", header.PointBorder, "TOP", 0, 12)
    header.Title:SetTextColor(1, 0.82, 0)
    header.Title:SetText(L.HOF_POINTS_LABEL)

    header.RightDDLInset = header:CreateTexture(nil, "BORDER")
    header.RightDDLInset:SetTexture(ACH_PATH .. "UI-Achievement-RightDDLInset")
    header.RightDDLInset:SetSize(128, 32)
    header.RightDDLInset:SetPoint("TOPRIGHT", -76, -56)

    header.Points = header:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    header.Points:SetPoint("TOP", header.PointBorder, "TOP", 0, -13)

    header.Shield = header:CreateTexture(nil, "ARTWORK")
    header.Shield:SetTexture(ACH_PATH .. "UI-Achievement-TinyShield")
    header.Shield:SetSize(20, 20)
    header.Shield:SetPoint("LEFT", header.Points, "RIGHT", 3, -1)
    header.Shield:SetTexCoord(0, 0.625, 0, 0.625)

    parent.Header = header
    return header
end

local function CreateSectionHeader(parent, titleText)
    local hdr = CreateFrame("Frame", nil, parent)
    hdr:SetHeight(20)
    hdr:SetPoint("TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", 0, 0)

    local tex = hdr:CreateTexture(nil, "BACKGROUND")
    tex:SetTexture(ACH_PATH .. "UI-Achievement-RecentHeader")
    tex:SetPoint("TOPLEFT", -20, 0)
    tex:SetPoint("BOTTOMRIGHT", 20, 0)
    tex:SetTexCoord(0, 1, 0, 0.71875)

    local title = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER")
    title:SetText(titleText)
    title:SetTextColor(1, 0.82, 0)

    return hdr
end

-- ---------------------------------------------------------------------------
-- Cartes hommages (SummaryAchievementTemplate Blizzard)
-- ---------------------------------------------------------------------------

local function OnHonorCardEnter(self)
    if self.Highlight then self.Highlight:Show() end
    local r = self._hofRow
    if not r then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(r.title or "", 1, 0.82, 0)
    if r.subtitle and r.subtitle ~= "" then
        GameTooltip:AddLine(r.subtitle, 1, 1, 1, true)
    end
    local progTotal = tonumber(r.progressTotal)
    local earned = r.earned
    if earned == nil then earned = true end
    if progTotal and progTotal > 0 and not earned then
        local progCurrent = math.min(tonumber(r.progressCurrent) or 0, progTotal)
        local fmt = L.HOF_PROGRESS_COUNT or "%d / %d"
        GameTooltip:AddLine(string.format(fmt, progCurrent, progTotal), 0, 1, 0)
    end
    GameTooltip:Show()
end

local function OnHonorCardLeave(self)
    if self.Highlight then self.Highlight:Hide() end
    GameTooltip:Hide()
end

local function BindHonorCardScripts(card)
    if not card or card._hofScriptsBound then return end
    card:SetScript("OnClick", nil)
    card:SetScript("OnEnter", OnHonorCardEnter)
    card:SetScript("OnLeave", OnHonorCardLeave)
    card._hofScriptsBound = true
end

local function ConfigureHonorCardScripts(card, row)
    if not card then return end
    card._hofRow = row
    card.id = nil
    card.tooltipTitle = nil
    card.tooltip = nil
end

-- SummaryAchievementTemplate hérite de ComparisonPlayerTemplate : OnLoad appelle Desaturate().
local function ApplyHonorCardStandardEarnedStyle(card)
    if not card then return end
    card.accountWide = nil
    if card.Saturate then
        card:Saturate()
    end
end

-- Style bleu account-wide : reutilise Saturate() Blizzard (SummaryAchievementTemplate
-- attend TitleBar a alpha 0.5, pas le bandeau pleine opacite d'AchievementTemplate).
local function ApplyHonorCardCuratedStyle(card)
    if not card then return end
    card.accountWide = true
    if card.Saturate then
        card:Saturate()
    end
    card.saturatedStyle = "curated"
end

local function ApplyHonorCardEarnedState(card, row)
    if not card then return end
    if row and row.isCurated then
        ApplyHonorCardCuratedStyle(card)
    else
        ApplyHonorCardStandardEarnedStyle(card)
        card.saturatedStyle = nil
    end
end

local function ApplyHonorCardLockedState(card)
    if not card then return end
    card.accountWide = nil
    if card.Desaturate then
        card:Desaturate()
    end
end

-- SummaryAchievementTemplate s'enregistre dans AchievementFrameSummaryAchievements.buttons :
-- Blizzard réutilise alors nos cartes pour ses propres hauts faits récents.
local function DetachHonorCardFromBlizzardSummary(card)
    if not card then return end
    local summary = AchievementFrameSummaryAchievements
    local buttons = summary and summary.buttons
    if not buttons then return end
    for i = #buttons, 1, -1 do
        if buttons[i] == card then
            table.remove(buttons, i)
        end
    end
end

local function CreateHonorCard(parent, name)
    local card = CreateFrame("Button", name, parent, "SummaryAchievementTemplate")
    BindHonorCardScripts(card)
    DetachHonorCardFromBlizzardSummary(card)
    card._hofHonorCard = true
    return card
end

local function ResetHonorCardVisualCache(card)
    if not card then return end
    card._hofTitle = nil
    card._hofSubtitle = nil
    card._hofShieldPts = nil
    card._hofIcon = nil
    card._hofGlowMode = nil
    card._hofCardStyle = nil
    card._hofDateHidden = nil
    card._hofEarnedState = nil
    card._hofProgressKey = nil
    card._hofRowKind = nil
    card._hofRowId = nil
    card._hofRowCurated = nil
end

-- Identité stable sans concat de chaîne (les rebuild cache recréent les tables row).
local function SyncHonorCardRowIdentity(card, row)
    if not row then return end
    local data = row.data
    local rowId = (data and (data.id or data.entryKey)) or row.title
    local curated = row.isCurated and true or false
    if card._hofRowKind ~= row.kind or card._hofRowId ~= rowId or card._hofRowCurated ~= curated then
        card._hofRowKind = row.kind
        card._hofRowId = rowId
        card._hofRowCurated = curated
        card._hofCardStyle = nil
        card._hofGlowMode = nil
    end
end

local function GetListCardStep()
    if selectedCategory == "lifetime" then
        return HOF_LIST_CARD_H_LIFETIME
    end
    return HOF_LIST_CARD_H
end

local function CardLabel(card)
    return card.Label or card.label
end

local function CardDescription(card)
    return card.Description or card.description
end

local function CardShield(card)
    return card.Shield or card.shield
end

local function CardShieldPoints(card)
    local sh = CardShield(card)
    if not sh then return nil end
    return sh.Points or sh.points
end

local function CardIconTexture(card)
    local icon = card.Icon or card.icon
    return icon and icon.texture
end

local function LifetimeRowNeedsProgressBar(row)
    if not row or row.kind ~= "lifetime" then return false end
    if row.earned then return false end
    local cur = tonumber(row.progressCurrent) or 0
    local total = tonumber(row.progressTotal) or 0
    return cur > 0 and total > 0
end

-- Masque les barres résiduelles d'anciennes cartes AchievementTemplate.
local function HideLegacyAchievementTemplateBars(card)
    if not card then return end
    if card._hofAchProgressBar then
        card._hofAchProgressBar:Hide()
    end
    if card.objectives then
        card.objectives:Hide()
    end
    if card.Objectives then
        card.Objectives:Hide()
    end
end

-- Une seule barre critères (AchievementProgressBarTemplate) ancrée en bas de la carte Summary.
local function EnsureLifetimeProgressBar(card)
    if card._hofLifetimeBar then return card._hofLifetimeBar end
    if not EnsureAchievementUILoaded() then return nil end
    local bar = CreateFrame("StatusBar", nil, card, "AchievementProgressBarTemplate")
    if AchievementButton_LocalizeProgressBar then
        AchievementButton_LocalizeProgressBar(bar)
    end
    bar:ClearAllPoints()
    bar:SetHeight(13)
    bar:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 58, 5)
    bar:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -52, 5)
    bar:SetFrameLevel(card:GetFrameLevel() + 4)
    card._hofLifetimeBar = bar
    return bar
end

local function HideLifetimeProgressBar(card)
    if not card or not card._hofLifetimeBar then return end
    card._hofLifetimeBar._hofProgCur = nil
    card._hofLifetimeBar._hofProgTot = nil
    card._hofLifetimeBar:Hide()
end

local function UpdateLifetimeProgressBar(card, row, earned)
    HideLegacyAchievementTemplateBars(card)
    if earned or not LifetimeRowNeedsProgressBar(row) then
        HideLifetimeProgressBar(card)
        return
    end
    local bar = EnsureLifetimeProgressBar(card)
    if not bar then return end
    local progTotal = tonumber(row.progressTotal) or 0
    local capCurrent = math.min(tonumber(row.progressCurrent) or 0, progTotal)
    if bar._hofProgCur ~= capCurrent or bar._hofProgTot ~= progTotal then
        bar._hofProgCur = capCurrent
        bar._hofProgTot = progTotal
        bar:SetMinMaxValues(0, progTotal)
        bar:SetValue(capCurrent)
        bar.Text:SetText(string.format("%d/%d", capCurrent, progTotal))
    end
    bar:Show()
end

local function IsLegacyAchievementListCard(card)
    return card and (card._hofListStyle == "achievement" or card.objectives or card.Objectives)
end

-- Style partagé : AchievementFrameSummaryCategoryTemplate (résumé uniquement).
local function BindHofCategoryProgressBar(bar)
    if not bar or bar._hofProgressBound then return end
    bar._hofProgressBound = true
    -- Scripts Blizzard : OnShow réécrit Text via GetCategoryNumAchievements (0/0 sans categoryID).
    bar:SetScript("OnLoad", nil)
    bar:SetScript("OnShow", nil)
    bar:SetScript("OnEvent", nil)
    bar:UnregisterAllEvents()
    bar:SetStatusBarTexture("Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar")
    bar:SetStatusBarColor(0, 1, 0)

    function bar:SetProgress(label, current, total)
        current = tonumber(current) or 0
        total = tonumber(total) or 1
        if total <= 0 then total = 1 end
        local labelText = label or ""
        local valueText = current .. "/" .. total
        if self._hofLabelText ~= labelText then
            self._hofLabelText = labelText
            self.Label:SetText(labelText)
        end
        if self._hofValueText ~= valueText then
            self._hofValueText = valueText
            self.Text:SetText(valueText)
        end
        if self._hofCurrent ~= current or self._hofTotal ~= total then
            self._hofCurrent = current
            self._hofTotal = total
            self:SetMinMaxValues(0, total)
            self:SetValue(current)
        end
    end
end

local function InstallBlizzardAchievementIsolation()
    if blizzardSummaryIsolationInstalled or not AchievementFrame then return end
    blizzardSummaryIsolationInstalled = true
    AchievementFrame:HookScript("OnShow", function()
        if hofFrame and hofFrame:IsShown() then
            Overlord.HallOfFameUI:RequestRefreshIfShown()
        end
    end)
end

local function PopulateHonorCard(card, row, opts)
    if not card or not row then return end

    -- Récupération si Blizzard a écrasé la carte (fenêtre hauts faits native ouverte).
    if card.id and card._hofHonorCard then
        card.id = nil
        card.tooltipTitle = nil
        card.tooltip = nil
        ResetHonorCardVisualCache(card)
    end

    SyncHonorCardRowIdentity(card, row)

    local titleText = row.title or ""
    local label = CardLabel(card)
    if label and card._hofTitle ~= titleText then
        card._hofTitle = titleText
        label:SetText(titleText)
    end

    local desc = CardDescription(card)
    local subtitleText = row.subtitle or ""
    if desc and card._hofSubtitle ~= subtitleText then
        card._hofSubtitle = subtitleText
        desc:SetText(subtitleText)
    end
    if desc then
        desc:Show()
    end

    if card.DateCompleted and not card._hofDateHidden then
        card.DateCompleted:SetText("")
        card.DateCompleted:Hide()
        card._hofDateHidden = true
    end

    local pts = tonumber(row.points) or 0
    local shield = CardShield(card)
    local ptsFont = CardShieldPoints(card)
    if shield and ptsFont then
        if card._hofShieldPts ~= pts then
            card._hofShieldPts = pts
            if AchievementShield_SetPoints then
                AchievementShield_SetPoints(pts, ptsFont, GameFontNormal, GameFontNormalSmall)
            else
                ptsFont:SetText(pts > 0 and tostring(pts) or "")
            end
            local shieldIcon = shield.Icon or shield.icon
            if shieldIcon then
                if pts > 0 then
                    shieldIcon:SetTexture(ACH_PATH .. "UI-Achievement-Shields")
                    shieldIcon:SetTexCoord(0, 0.5, 0, 0.5)
                else
                    shieldIcon:SetTexture(ACH_PATH .. "UI-Achievement-Shields-NoPoints")
                    shieldIcon:SetTexCoord(0, 0.5, 0, 0.5)
                end
            end
        end
    end

    local iconTexFrame = CardIconTexture(card)
    if iconTexFrame then
        local iconTex = row.icon
        if card._hofIcon ~= iconTex then
            card._hofIcon = iconTex
            iconTexFrame:SetTexture(iconTex)
        end
    end

    local earned = row.earned
    if earned == nil then earned = true end
    local targetStyle = earned and (row.isCurated and "curated" or "earned") or "locked"
    if card._hofCardStyle ~= targetStyle then
        card._hofCardStyle = targetStyle
        if earned then
            ApplyHonorCardEarnedState(card, row)
            card._hofEarnedState = true
            card._hofEarnedApplied = true
        else
            ApplyHonorCardLockedState(card)
            card._hofEarnedState = false
            card._hofEarnedApplied = nil
        end
    end

    -- Surlignage « récent » (résumé) : ne pas écraser le style bleu curaté.
    if card.Glow and opts and opts.recentHighlight and not row.isCurated then
        if card._hofGlowMode ~= 1 then
            card._hofGlowMode = 1
            card.Glow:SetTexture(ACH_PATH .. "UI-Achievement-RecentHighlight")
            card.Glow:SetTexCoord(0, 1, 0, 0.5)
            card.Glow:SetVertexColor(1, 1, 1, 1)
            card.Glow:SetAlpha(1)
        end
    elseif card._hofGlowMode == 1 then
        card._hofGlowMode = 0
        if card.Glow then
            card.Glow:Hide()
        end
    end

    -- Anciennes barres (retirées) : masquer si encore présentes.
    if card._hofProgressBar then
        card._hofProgressBar:Hide()
    end

    UpdateLifetimeProgressBar(card, row, earned)

    ConfigureHonorCardScripts(card, row)
end

local function EnsureHonorCardPool(pool, parent, count, anchorHeader)
    for i = count + 1, #pool do
        if pool[i] then
            pool[i]:Hide()
        end
    end

    for i = 1, count do
        if not pool[i] then
            pool[i] = CreateHonorCard(parent, "OverlordHofHonorCard" .. i)
            if i == 1 and anchorHeader then
                pool[i]:SetPoint("TOPLEFT", anchorHeader, "BOTTOMLEFT", 18, 2)
                pool[i]:SetPoint("TOPRIGHT", anchorHeader, "BOTTOMRIGHT", -18, 2)
            else
                pool[i]:SetPoint("TOPLEFT", pool[i - 1], "BOTTOMLEFT", 0, 3)
                pool[i]:SetPoint("TOPRIGHT", pool[i - 1], "BOTTOMRIGHT", 0, 3)
            end
        end
        pool[i]:SetParent(parent)
        pool[i]:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Barres de progression (AchievementFrameSummaryCategoryTemplate)
-- ---------------------------------------------------------------------------

local function CreateMainProgressBar(parent, anchorHeader)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(488, 21)
    bar:SetPoint("TOP", anchorHeader, "BOTTOM", 0, -6)
    bar:SetStatusBarTexture("Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar")
    bar:SetStatusBarColor(0, 1, 0)
    bar:SetMinMaxValues(0, 100)

    bar.Label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bar.Label:SetPoint("LEFT", 6, 4)

    bar.Text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.Text:SetPoint("RIGHT", -5, 3)

    bar.Left = bar:CreateTexture(nil, "OVERLAY")
    bar.Left:SetTexture(ACH_PATH .. "UI-Achievement-Header")
    bar.Left:SetSize(32, 48)
    bar.Left:SetPoint("TOPLEFT", -15, 16)
    bar.Left:SetTexCoord(0.423828125, 0.486, 0.56640625, 0.75)

    bar.Right = bar:CreateTexture(nil, "OVERLAY")
    bar.Right:SetTexture(ACH_PATH .. "UI-Achievement-Header")
    bar.Right:SetSize(32, 48)
    bar.Right:SetPoint("TOPRIGHT", 15, 16)
    bar.Right:SetTexCoord(0.486, 0.423828125, 0.75, 0.56640625)

    bar.Middle = bar:CreateTexture(nil, "OVERLAY")
    bar.Middle:SetTexture(ACH_PATH .. "UI-Achievement-Header")
    bar.Middle:SetPoint("TOPLEFT", bar.Left, "TOPRIGHT")
    bar.Middle:SetPoint("BOTTOMRIGHT", bar.Right, "BOTTOMLEFT")
    bar.Middle:SetTexCoord(0.889224609375, 0.486, 0.75, 0.56640625)

    bar.FillBg = bar:CreateTexture(nil, "BACKGROUND")
    bar.FillBg:SetColorTexture(0, 0, 0, 0.5)
    bar.FillBg:SetHeight(15)
    bar.FillBg:SetPoint("LEFT", 2, 0)
    bar.FillBg:SetPoint("RIGHT", -2, 0)

    function bar:SetProgress(label, current, total)
        current = tonumber(current) or 0
        total = tonumber(total) or 1
        if total <= 0 then total = 1 end
        local labelText = label or ""
        local valueText = current .. "/" .. total
        if self._hofLabelText ~= labelText then
            self._hofLabelText = labelText
            self.Label:SetText(labelText)
        end
        if self._hofValueText ~= valueText then
            self._hofValueText = valueText
            self.Text:SetText(valueText)
        end
        if self._hofCurrent ~= current or self._hofTotal ~= total then
            self._hofCurrent = current
            self._hofTotal = total
            self:SetMinMaxValues(0, total)
            self:SetValue(current)
        end
    end

    return bar
end

local function CreateCategoryProgressBar(parent, name)
    local bar = CreateFrame("StatusBar", name, parent, "AchievementFrameSummaryCategoryTemplate")
    bar:SetSize(234, 21)
    BindHofCategoryProgressBar(bar)
    return bar
end

local function SetCategorySelected(catFrame, selected)
    if not catFrame or not catFrame.Button then return end
    if selected then
        catFrame.Button:LockHighlight()
    else
        catFrame.Button:UnlockHighlight()
    end
end

local function UpdateCategoryButtons()
    for i = 1, #categoryFrames do
        local cf = categoryFrames[i]
        SetCategorySelected(cf, cf._hofCategoryId == selectedCategory)
    end
end

-- ---------------------------------------------------------------------------
-- Rafraîchissement contenu
-- ---------------------------------------------------------------------------

local function RefreshPointsBannerFromStats(stats)
    if not hofFrame or not hofFrame.Header or not stats then return end
    local ptsText = tostring(stats.totalPoints or 0)
    if pointsBannerText ~= ptsText and hofFrame.Header.Points then
        pointsBannerText = ptsText
        hofFrame.Header.Points:SetText(ptsText)
    end
end

local function RefreshSummaryView(view)
    if not hofFrame or not hofFrame.summaryPanel or not view then return end
    local panel = hofFrame.summaryPanel
    local stats = view.stats
    local data = Overlord.HallOfFameData
    local recentRows = (data and data.GetRecentHonorRows) and data:GetRecentHonorRows(
        HOF_RECENT_MAX,
        searchText ~= "" and searchText or nil
    ) or {}
    local recentCount = #recentRows

    if recentCount == 0 then
        EnsureHonorCardPool(recentCards, panel.achievementsArea, 0, panel.recentHeader)
        if panel.emptyText then
            panel.emptyText:SetText(
                searchText ~= "" and (L.HOF_SEARCH_NO_RESULTS or L.HOF_SECTION_EMPTY) or L.HOF_SECTION_EMPTY
            )
            panel.emptyText:Show()
        end
    else
        if panel.emptyText then panel.emptyText:Hide() end
        EnsureHonorCardPool(recentCards, panel.achievementsArea, recentCount, panel.recentHeader)
        for i = 1, recentCount do
            PopulateHonorCard(recentCards[i], recentRows[i], i == 1 and CARD_OPTS_RECENT or CARD_OPTS_NORMAL)
        end
    end

    local total = stats.totalCount
    if total <= 0 then total = 1 end
    local earnedTotal = stats.earnedCount or stats.totalCount

    if progressBars[1] then
        local mainLabel = L.HOF_PROGRESS_TOTAL
        progressBars[1]:SetProgress(mainLabel, earnedTotal, total)
    end

    for i = 1, #SUB_BAR_DEFS do
        local def = SUB_BAR_DEFS[i]
        local bar = progressBars[i + 1]
        if bar then
            bar:Show()
            local barTotal = def.totalKey and stats[def.totalKey] or total
            if not barTotal or barTotal <= 0 then barTotal = total end
            bar:SetProgress(L[def.key] or def.key, stats[def.statKey] or 0, barTotal)
        end
    end
    for i = #SUB_BAR_DEFS + 2, #progressBars do
        if progressBars[i] then progressBars[i]:Hide() end
    end
end

local function SyncListScrollWidth()
    if not hofFrame or not hofFrame.listScroll or not hofFrame.listScrollChild then return end
    local scroll = hofFrame.listScroll
    local w = scroll:GetWidth()
    if w and w > 1 then
        hofFrame.listScrollChild:SetWidth(w)
    end
end

local function LayoutListHonorCards(content, rows)
    local rowCount = #rows
    local cardStep = GetListCardStep()
    local cardH = cardStep - 3
    local relayout = (rowCount ~= lastListLayoutCount) or (selectedCategory ~= lastListLayoutCategory)
    lastListLayoutCategory = selectedCategory

    for i = 1, rowCount do
        local card = honorCards[i]
        if IsLegacyAchievementListCard(card) then
            card:Hide()
            card:SetParent(nil)
            honorCards[i] = nil
            card = nil
            relayout = true
        end
        if not card then
            honorCards[i] = CreateHonorCard(content, "OverlordHofListCard" .. i)
            relayout = true
            card = honorCards[i]
        end
        local row = rows[i]
        card:SetParent(content)
        if relayout then
            card:ClearAllPoints()
            local yOff = -4 - (i - 1) * cardStep
            card:SetPoint("TOPLEFT", content, "TOPLEFT", HOF_LIST_CARD_PAD_X, yOff)
            card:SetPoint("TOPRIGHT", content, "TOPRIGHT", -HOF_LIST_CARD_PAD_X, yOff)
            card:SetHeight(cardH)
        end
        card:Show()
        PopulateHonorCard(card, row, nil)
    end
    for i = rowCount + 1, #honorCards do
        if honorCards[i] then honorCards[i]:Hide() end
    end
    lastListLayoutCount = rowCount
    content:SetHeight(rowCount > 0 and (rowCount * cardStep) or 64)
end

local function RefreshListView(view, resetScroll)
    if not hofFrame or not hofFrame.listScrollChild or not view then return end
    SyncListScrollWidth()
    local content = hofFrame.listScrollChild
    local rows = view.rows

    if #rows == 0 then
        EnsureHonorCardPool(honorCards, content, 0, nil)
        lastListLayoutCount = 0
        if not content.emptyLabel then
            content.emptyLabel = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            content.emptyLabel:SetPoint("TOP", 0, -24)
            content.emptyLabel:SetWidth(content:GetWidth() or 500)
            content.emptyLabel:SetJustifyH("CENTER")
            content.emptyLabel:SetWordWrap(true)
        end
        content.emptyLabel:SetText(
            searchText ~= "" and (L.HOF_SEARCH_NO_RESULTS or L.HOF_SECTION_EMPTY) or L.HOF_SECTION_EMPTY
        )
        content.emptyLabel:Show()
        content:SetHeight(64)
        if resetScroll then
            hofFrame.listScroll:SetVerticalScroll(0)
        end
        return
    end

    if content.emptyLabel then content.emptyLabel:Hide() end
    LayoutListHonorCards(content, rows)
    if resetScroll then
        hofFrame.listScroll:SetVerticalScroll(0)
    else
        local maxScroll = hofFrame.listScroll:GetVerticalScrollRange()
        local curScroll = hofFrame.listScroll:GetVerticalScroll()
        if curScroll > maxScroll then
            hofFrame.listScroll:SetVerticalScroll(maxScroll)
        end
    end
end

function Overlord.HallOfFameUI:Refresh()
    if not hofFrame then return end
    if not hofFrame:IsShown() then return end
    local data = Overlord.HallOfFameData
    if not data then return end

    UpdateCategoryButtons()

    local isSummary = (selectedCategory == "summary")
    if hofFrame.summaryPanel then hofFrame.summaryPanel:SetShown(isSummary) end
    if hofFrame.listPanel then hofFrame.listPanel:SetShown(not isSummary) end

    local resetListScroll = (selectedCategory ~= lastListCategory) or (searchText ~= lastListSearchText)
    lastListCategory = selectedCategory
    lastListSearchText = searchText

    local view = data:GetHonorView(selectedCategory, searchText)
    RefreshPointsBannerFromStats(view.stats)

    if isSummary then
        RefreshSummaryView(view)
    else
        RefreshListView(view, resetListScroll)
    end
end

local function OnCategorySelected(categoryId)
    selectedCategory = categoryId or "donors"
    Overlord.HallOfFameUI:Refresh()
end

local function OnCategoryButtonClick(self)
    OnCategorySelected(self._hofCategoryId)
end

local function ScheduleSearchRefresh()
    if searchDebounceTimer then
        searchDebounceTimer:Cancel()
    end
    searchDebounceTimer = C_Timer.NewTimer(SEARCH_DEBOUNCE_SEC, function()
        searchDebounceTimer = nil
        Overlord.HallOfFameUI:Refresh()
    end)
end

local function OnSearchChanged(text)
    local nextText = text or ""
    if nextText == searchText then return end
    searchText = nextText
    ScheduleSearchRefresh()
end

local function SyncSearchBoxAppearance(searchBox)
    if not searchBox then return end
    if SearchBoxTemplate_OnTextChanged then
        SearchBoxTemplate_OnTextChanged(searchBox)
    end
end

local function BindHallOfFameSearchBox(searchBox)
    if SearchBoxTemplate_OnLoad then
        SearchBoxTemplate_OnLoad(searchBox)
    end
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function(self)
        SyncSearchBoxAppearance(self)
        OnSearchChanged(self:GetText())
    end)
    searchBox:SetScript("OnEditFocusGained", function(self)
        if SearchBoxTemplate_OnEditFocusGained then
            SearchBoxTemplate_OnEditFocusGained(self)
        end
    end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if SearchBoxTemplate_OnEditFocusLost then
            SearchBoxTemplate_OnEditFocusLost(self)
        end
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText("")
        SyncSearchBoxAppearance(self)
        searchText = ""
        if searchDebounceTimer then
            searchDebounceTimer:Cancel()
            searchDebounceTimer = nil
        end
        Overlord.HallOfFameUI:Refresh()
    end)
end

-- ---------------------------------------------------------------------------
-- Construction de la fenêtre
-- ---------------------------------------------------------------------------

function Overlord.HallOfFameUI:CreateFrame()
    if not EnsureAchievementUILoaded() then
        return
    end
    InstallBlizzardAchievementIsolation()

    hofFrame = CreateFrame("Frame", "OverlordHallOfFameFrame", UIParent, "BackdropTemplate")
    hofFrame:SetSize(HOF_FRAME_W, HOF_FRAME_H)
    hofFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    ApplyAchievementBackdrop(hofFrame)
    BuildAchievementFrameChrome(hofFrame)
    hofFrame:EnableMouse(true)
    hofFrame:SetMovable(true)
    hofFrame:RegisterForDrag("LeftButton")
    hofFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    hofFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    hofFrame:SetFrameStrata("HIGH")
    hofFrame:SetFrameLevel(50)
    hofFrame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "OverlordHallOfFameFrame")

    CreateAchievementHeader(hofFrame)

    local closeBtn = CreateFrame("Button", nil, hofFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", 0, 0)
    closeBtn:SetScript("OnClick", function()
        Overlord.HallOfFameUI:Hide()
    end)

    local searchBox = CreateFrame("EditBox", nil, hofFrame, "SearchBoxTemplate")
    searchBox:SetSize(107, 30)
    searchBox:SetPoint("TOPLEFT", hofFrame.Header.RightDDLInset, "TOPLEFT", 12, 2)
    BindHallOfFameSearchBox(searchBox)
    hofFrame.searchBox = searchBox

    -- Sidebar catégories (AchivementGoldBorderBackdrop)
    local sidebar = CreateFrame("Frame", nil, hofFrame, "AchivementGoldBorderBackdrop")
    sidebar:SetPoint("TOPLEFT", 21, -19)
    sidebar:SetPoint("BOTTOMLEFT", 21, 20)
    sidebar:SetWidth(175)
    hofFrame.sidebar = sidebar

    local cats = Overlord.HallOfFameData and Overlord.HallOfFameData.CATEGORIES or {}
    for i = 1, #cats do
        local catDef = cats[i]
        local catFrame = CreateFrame("Frame", nil, sidebar, "AchievementCategoryTemplate")
        catFrame:SetSize(158, 24)
        catFrame:SetPoint("TOPLEFT", 4, -((i - 1) * 28 + 6))
        catFrame._hofCategoryId = catDef.id
        catFrame.Button.Label:SetText(L[catDef.labelKey] or catDef.id)
        catFrame.Button._hofCategoryId = catDef.id
        catFrame.Button:SetScript("OnClick", OnCategoryButtonClick)
        categoryFrames[i] = catFrame
    end

    -- Panneau résumé (clone AchievementFrameSummary)
    local summaryPanel = CreateFrame("Frame", nil, hofFrame)
    summaryPanel:SetPoint("TOPLEFT", hofFrame, "TOPLEFT", 218, -19)
    summaryPanel:SetPoint("BOTTOM", sidebar, "BOTTOM", 0, 0)
    summaryPanel:SetPoint("RIGHT", hofFrame, "RIGHT", -44, 0)
    hofFrame.summaryPanel = summaryPanel

    local summaryBg = summaryPanel:CreateTexture(nil, "BACKGROUND")
    summaryBg:SetTexture(ACH_PATH .. "UI-Achievement-AchievementBackground")
    summaryBg:SetPoint("TOPLEFT", 3, -3)
    summaryBg:SetPoint("BOTTOMRIGHT", -3, 3)
    summaryBg:SetTexCoord(0, 1, 0, 0.5)

    CreateFrame("Frame", nil, summaryPanel, "AchivementGoldBorderBackdrop"):SetAllPoints()

    local achievementsArea = CreateFrame("Frame", nil, summaryPanel)
    achievementsArea:SetPoint("TOPLEFT", 5, -10)
    achievementsArea:SetPoint("TOPRIGHT", -5, -10)
    achievementsArea:SetHeight(210)
    summaryPanel.achievementsArea = achievementsArea

    summaryPanel.recentHeader = CreateSectionHeader(achievementsArea, L.HOF_RECENT_TITLE)

    summaryPanel.emptyText = achievementsArea:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    summaryPanel.emptyText:SetPoint("TOP", summaryPanel.recentHeader, "BOTTOM", 0, -30)
    summaryPanel.emptyText:Hide()

    local progressArea = CreateFrame("Frame", nil, summaryPanel)
    progressArea:SetPoint("TOPLEFT", achievementsArea, "BOTTOMLEFT", 0, -6)
    progressArea:SetPoint("TOPRIGHT", achievementsArea, "BOTTOMRIGHT", 0, -6)
    progressArea:SetHeight(164)
    summaryPanel.progressArea = progressArea

    local progressHeader = CreateSectionHeader(progressArea, L.HOF_PROGRESS_TITLE)
    progressBars[1] = CreateMainProgressBar(progressArea, progressHeader)

    progressBars[2] = CreateCategoryProgressBar(progressArea, "OverlordHofProgBar2")
    progressBars[2]:SetPoint("TOPLEFT", progressBars[1], "BOTTOMLEFT", 0, -13)

    progressBars[3] = CreateCategoryProgressBar(progressArea, "OverlordHofProgBar3")
    progressBars[3]:SetPoint("TOPLEFT", progressBars[2], "TOPRIGHT", 20, 0)

    progressBars[4] = CreateCategoryProgressBar(progressArea, "OverlordHofProgBar4")
    progressBars[4]:SetPoint("TOPLEFT", progressBars[2], "BOTTOMLEFT", 0, -10)

    progressBars[5] = CreateCategoryProgressBar(progressArea, "OverlordHofProgBar5")
    progressBars[5]:SetPoint("TOPLEFT", progressBars[4], "TOPRIGHT", 20, 0)

    progressBars[6] = CreateCategoryProgressBar(progressArea, "OverlordHofProgBar6")
    progressBars[6]:SetPoint("TOPLEFT", progressBars[4], "BOTTOMLEFT", 0, -10)

    progressBars[7] = CreateCategoryProgressBar(progressArea, "OverlordHofProgBar7")
    progressBars[7]:SetPoint("TOPLEFT", progressBars[6], "TOPRIGHT", 20, 0)

    progressBars[8] = CreateCategoryProgressBar(progressArea, "OverlordHofProgBar8")
    progressBars[8]:SetPoint("TOPLEFT", progressBars[7], "BOTTOMLEFT", 0, -10)

    -- Panneau liste (autres catégories)
    local listPanel = CreateFrame("Frame", nil, hofFrame)
    listPanel:SetPoint("TOPLEFT", hofFrame, "TOPLEFT", 218, -19)
    listPanel:SetPoint("BOTTOM", sidebar, "BOTTOM", 0, 0)
    listPanel:SetPoint("RIGHT", hofFrame, "RIGHT", -44, 0)
    listPanel:Hide()
    hofFrame.listPanel = listPanel

    local listBg = listPanel:CreateTexture(nil, "BACKGROUND")
    listBg:SetTexture(ACH_PATH .. "UI-Achievement-AchievementBackground")
    listBg:SetPoint("TOPLEFT", 3, -3)
    listBg:SetPoint("BOTTOMRIGHT", -3, 3)
    listBg:SetTexCoord(0, 1, 0, 0.5)

    CreateFrame("Frame", nil, listPanel, "AchivementGoldBorderBackdrop"):SetAllPoints()

    local listScroll = CreateFrame("ScrollFrame", nil, listPanel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 5, -10)
    listScroll:SetPoint("BOTTOMRIGHT", -5, 10)
    hofFrame.listScroll = listScroll

    local listScrollChild = CreateFrame("Frame", nil, listScroll)
    listScrollChild:SetWidth(1)
    listScroll:SetScrollChild(listScrollChild)
    hofFrame.listScrollChild = listScrollChild

    listScroll:HookScript("OnSizeChanged", SyncListScrollWidth)

    listScroll:EnableMouseWheel(true)
    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = GetListCardStep()
        local newVal = cur - delta * step
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
    end)

    -- Onglet bas (AchievementFrameTabButtonTemplate)
    local tab = CreateFrame("Button", nil, hofFrame, "AchievementFrameTabButtonTemplate")
    tab:SetPoint("TOPLEFT", hofFrame, "BOTTOMLEFT", 17, 3)
    tab:SetText(L.HOF_TITLE)
    if PanelTemplates_SelectTab then
        PanelTemplates_SelectTab(tab)
    end
    hofFrame.tab = tab

    hofFrame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            Overlord.HallOfFameUI:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    hofFrame:EnableKeyboard(true)

    selectedCategory = "donors"
    searchText = ""
    UpdateCategoryButtons()
    hofFrame:Hide()
end

function Overlord.HallOfFameUI:RequestRefreshIfShown()
    if not hofFrame or not hofFrame:IsShown() then return end
    local now = GetTime()
    if now - hofRefreshLastAt >= HOF_REFRESH_MIN_INTERVAL then
        hofRefreshLastAt = now
        hofRefreshPending = false
        self:Refresh()
        return
    end
    if hofRefreshPending then return end
    hofRefreshPending = true
    local delay = math.max(0.01, HOF_REFRESH_MIN_INTERVAL - (now - hofRefreshLastAt))
    C_Timer.After(delay, function()
        hofRefreshPending = false
        if Overlord.HallOfFameUI and hofFrame and hofFrame:IsShown() then
            hofRefreshLastAt = GetTime()
            Overlord.HallOfFameUI:Refresh()
        end
    end)
end

function Overlord.HallOfFameUI:Show()
    if not hofFrame then
        self:CreateFrame()
    end
    if not hofFrame then return end
    if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
        hofFrame:SetScale(Overlord.UI:GetEffectiveUiScale())
    else
        hofFrame:SetScale(1)
    end
    if hofFrame.searchBox then
        hofFrame.searchBox:SetText("")
        SyncSearchBoxAppearance(hofFrame.searchBox)
        searchText = ""
    end
    if searchDebounceTimer then
        searchDebounceTimer:Cancel()
        searchDebounceTimer = nil
    end
    lastListCategory = nil
    lastListSearchText = nil
    pointsBannerText = nil
    hofFrame:Show()
    SyncListScrollWidth()
    if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
    if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
        Overlord.UI:ScheduleActionGridActiveRefresh()
    end
    self:Refresh()
end

function Overlord.HallOfFameUI:Hide()
    if searchDebounceTimer then
        searchDebounceTimer:Cancel()
        searchDebounceTimer = nil
    end
    if hofFrame and hofFrame:IsShown() and Overlord.PlayPanelCloseSound then
        Overlord:PlayPanelCloseSound()
    end
    if hofFrame then hofFrame:Hide() end
    if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
        Overlord.UI:ScheduleActionGridActiveRefresh()
    end
end

function Overlord.HallOfFameUI:Toggle()
    if hofFrame and hofFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function Overlord.HallOfFameUI:IsShown()
    return hofFrame and hofFrame:IsShown()
end
