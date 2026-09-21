-- Popups.lua - Dialogues WC3 (annonces one-shot au login, etc.)
Overlord = Overlord or {}
Overlord.Popups = {}

local L = Overlord.L

-- Palette Human (or UI) - titre popup uniquement
local GOLD = { 0.85, 0.68, 0.20 }
local TUTORIAL_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local WELCOME_BOOK_ICON_SIZE = 44
local WELCOME_BOOK_ICON_GAP = 10
local WELCOME_FACTION_SEAL_SIZE = 52
local WELCOME_FACTION_SEAL_ATLAS = {
    Alliance = "Quest-Alliance-WaxSeal",
    Horde    = "Quest-Horde-WaxSeal",
}
local WELCOME_POPUP_ID = "welcome_first_install"
local GUILD_KEEP_REMINDER_POPUP_ID = "guild_keep_siege_reminder"
local FOREVER_LAUNCH_POPUP_ID = "forever_launch_1_0_0"
local FEATURED_FRONT_POPUP_ID = "daily_featured_front"
-- Vrais atlas Blizzard du systeme PlayerChoiceFrame (Interface\AddOns\Blizzard_PlayerChoice) :
-- "Header" = blason a ailes au-dessus du cadre, "TitleLeft/Right/Middle" = ruban 3 pieces.
-- Memes noms que le jeu utilise pour ses propres choix Alliance/Horde ("War Mode", etc.).
local FEATURED_FACTION_HEADER_ATLAS = {
    Alliance = "UI-Frame-Alliance-Header",
    Horde    = "UI-Frame-Horde-Header",
}
local FEATURED_FACTION_HEADER_YOFFSET = {
    Alliance = -48,
    Horde    = -55,
}
-- Atlas Horde plus large que l'Alliance : reduire pour aligner visuellement le panneau.
local FEATURED_FACTION_HEADER_SCALE = {
    Horde = 0.80,
}
local FEATURED_FACTION_TITLE_ATLAS = {
    Alliance = { left = "UI-Frame-Alliance-TitleLeft", right = "UI-Frame-Alliance-TitleRight", middle = "_UI-Frame-Alliance-TitleMiddle" },
    Horde    = { left = "UI-Frame-Horde-TitleLeft", right = "UI-Frame-Horde-TitleRight", middle = "_UI-Frame-Horde-TitleMiddle" },
}
local FEATURED_FRONT_PANEL_WIDTH = 300
local FEATURED_FRONT_TOGGLE_W = 20
local FEATURED_FRONT_TOGGLE_H = 52
local FEATURED_FRONT_CLOSE_SIZE = 10
-- Chevauchement de l'onglet sur le bord gauche du main (reliure livre).
local FEATURED_FRONT_SPINE_OVERLAP = 1
local FEATURED_FRONT_LAYOUT_VERSION = 56
local FEATURED_FRONT_ACTIVITY_ROW_H = 18
local FEATURED_FRONT_ACTIVITY_ROW_GAP = 3
local FEATURED_FRONT_ACTIVITY_MAX_ROWS = 8
local FEATURED_FRONT_ACTIVITY_VISIBLE_ROWS = 5
local FEATURED_FRONT_ACTIVITY_TITLE_H = 28
local FEATURED_FRONT_ACTIVITY_BOTTOM_PAD = 8
local FEATURED_FRONT_ACTIVITY_TEXT_PAD = 10
local FEATURED_FRONT_BODY_ACTIVITY_GAP = 10
local FEATURED_FRONT_BOUNTY_GAP = 10
local FEATURED_FRONT_NO_ACTIVE_LIFT = 10
local FEATURED_FRONT_ACTIONS_GAP = 8
local FEATURED_FRONT_ACTIVITY_ICON = 14
local FEATURED_FRONT_ACTIVITY_STAR = 10
local FEATURED_FRONT_ACTIVITY_CONTENT_W = 224
local FEATURED_FRONT_ACTIVITY_TITLE_ICON = "Bonus-Icon-PVP"
local FEATURED_FRONT_ACTIVITY_STAR_ATLAS = "QuestDailyIcon"
local FEATURED_FRONT_ART_HEIGHT = 112
local FEATURED_FRONT_TOP_Y = -18
local PANEL_LINK = "addon:Overlord:panel"

local function IsPanelAddonLink(link)
    if Overlord.UI and Overlord.UI.IsPanelAddonLink then
        return Overlord.UI:IsPanelAddonLink(link)
    end
    return type(link) == "string" and link == PANEL_LINK
end

local function OnPopupHyperlinkClick(_, link, _, button)
    if not IsPanelAddonLink(link) then return end
    if Overlord.UI and Overlord.UI.OpenPanelFromLink then
        Overlord.UI:OpenPanelFromLink(button)
    end
end

-- Hyperliens : SetHyperlinksEnabled sur le panneau parent du FontString (pas seulement le FS).
local function SetupDialogHyperlinks(f)
    if not f or not f.bodyPanel or not f.bodyFs then return end
    if Overlord.UI and Overlord.UI.EnsureAddonLinkHandlers then
        Overlord.UI:EnsureAddonLinkHandlers()
    end
    local panel = f.bodyPanel
    if panel.SetHyperlinksEnabled then
        panel:SetHyperlinksEnabled(true)
    end
    if f.SetHyperlinksEnabled then
        f:SetHyperlinksEnabled(true)
    end
    panel:EnableMouse(true)
    panel:SetScript("OnHyperlinkClick", OnPopupHyperlinkClick)
    panel:SetScript("OnHyperlinkEnter", function(_, link)
        if IsPanelAddonLink(link) then
            SetCursor("Interface\\Cursor\\Point")
        end
    end)
    panel:SetScript("OnHyperlinkLeave", function()
        ResetCursor()
    end)
end

local dialogFrame = nil
local dialogBlocker = nil
local featuredFrontFrame = nil
local featuredFrontToggleBtn = nil
local pendingSeenId = nil
local pendingMarkMode = nil -- "once" | "daily"
local pendingLoginChain = false
local loginAnnouncements = {}
local GUILD_KEEP_REMINDER_RECHECK_SEC = 30
local nextGuildKeepReminderCheckAt = 0

-- ---------------------------------------------------------------------------
-- Persistance (une fois par id de popup)
-- ---------------------------------------------------------------------------

-- Compatibilite avec les anciens flags numeriques ; les nouveaux sont booleens.
local function PopupValueSeen(v)
    return v == true or v == 1
end

function Overlord.Popups:HasSeen(id)
    if not id or not OverlordDB or not OverlordDB.config then return true end
    local seen = OverlordDB.config.popupsSeen
    if seen and PopupValueSeen(seen[id]) then return true end
    return false
end

function Overlord.Popups:MarkSeen(id)
    if not id or not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.popupsSeen = OverlordDB.config.popupsSeen or {}
    -- Boolean, pas 1 : c'est le test Retail (seen[id] == true).
    OverlordDB.config.popupsSeen[id] = true
end

function Overlord.Popups:PersistSeenFlags()
    if not OverlordDB or not OverlordDB.config or not OverlordDB.config.popupsSeen then return end
    for id, v in pairs(OverlordDB.config.popupsSeen) do
        if v == 1 then
            OverlordDB.config.popupsSeen[id] = true
        end
    end
end

-- Cle calendaire (premiere connexion du jour, heure client WoW).
function Overlord.Popups:GetCalendarDayKey()
    return date("%Y%m%d", time())
end

function Overlord.Popups:HasShownToday(id)
    if not id or not OverlordDB or not OverlordDB.config then return true end
    local daily = OverlordDB.config.popupsDailyShown
    return daily and daily[id] == self:GetCalendarDayKey()
end

function Overlord.Popups:MarkShownToday(id)
    if not id or not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.popupsDailyShown = OverlordDB.config.popupsDailyShown or {}
    OverlordDB.config.popupsDailyShown[id] = self:GetCalendarDayKey()
end

function Overlord.Popups:HasShownFeaturedFrontToday()
    if not FEATURED_FRONT_POPUP_ID or not OverlordDB or not OverlordDB.config then return true end
    local gk = Overlord.GuildKeep
    if not gk or not gk.GetServerSiegeDayKey then return true end
    local dayKey = gk:GetServerSiegeDayKey()
    local daily = OverlordDB.config.popupsDailyShown
    return daily and daily[FEATURED_FRONT_POPUP_ID] == dayKey
end

function Overlord.Popups:MarkFeaturedFrontShownToday()
    if not OverlordDB then return end
    local gk = Overlord.GuildKeep
    if not gk or not gk.GetServerSiegeDayKey then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.popupsDailyShown = OverlordDB.config.popupsDailyShown or {}
    OverlordDB.config.popupsDailyShown[FEATURED_FRONT_POPUP_ID] = gk:GetServerSiegeDayKey()
end

-- Ecrit le flag one-shot / quotidien des que la popup est affichee, pas a la
-- fermeture : un /reload pendant l'affichage perdait sinon popupsSeen.
function Overlord.Popups:CommitPendingPopupMark()
    if not pendingSeenId then return end
    if pendingMarkMode == "daily" then
        self:MarkShownToday(pendingSeenId)
    else
        self:MarkSeen(pendingSeenId)
    end
end

-- Conserver les identifiants deja vus lors des mises a jour de l'addon.
local function MigrateLegacyPopupFlags()
    if not OverlordDB or not OverlordDB.config then return end
    local cfg = OverlordDB.config
    if cfg.announceSeen then
        cfg.popupsSeen = cfg.popupsSeen or {}
        for k, v in pairs(cfg.announceSeen) do
            if v then
                cfg.popupsSeen[k] = true
            end
        end
        cfg.announceSeen = nil
    end
    if Overlord.Popups and Overlord.Popups.PersistSeenFlags then
        Overlord.Popups:PersistSeenFlags()
    end
    if cfg.popupsDailyShown and cfg.popupsDailyShown.daily_guild_kills then
        local dayKey = cfg.popupsDailyShown.daily_guild_kills
        if not cfg.popupsDailyShown.daily_battle_report then
            cfg.popupsDailyShown.daily_battle_report = dayKey
        end
        cfg.popupsDailyShown.daily_guild_kills = nil
    end
end

-- ---------------------------------------------------------------------------
-- Dialogues WC3
-- ---------------------------------------------------------------------------

local function HideDialog()
    if dialogFrame then dialogFrame:Hide() end
end

local function GetWelcomePopupTitle()
    if Overlord.PlayerFaction == "Horde" then
        return L.POPUP_WELCOME_TITLE_HORDE
    end
    return L.POPUP_WELCOME_TITLE_ALLIANCE
end

local function GetWelcomePopupBody()
    local name = Overlord and Overlord.SafeUnitName and select(1, Overlord:SafeUnitName("player"))
    if not name or name == "" then
        name = L.POPUP_WELCOME_NAME_FALLBACK or "Champion"
    end
    return string.format(L.POPUP_WELCOME_BODY or "", name)
end

-- Sceau de cire Blizzard (faction du joueur qui consulte la popup).
local function ApplyViewerFactionSeal(tex)
    if not tex then return false end
    local fac = Overlord.PlayerFaction or UnitFactionGroup("player")
    local atlas = WELCOME_FACTION_SEAL_ATLAS[fac]
    if not atlas or not tex.SetAtlas then
        tex:Hide()
        return false
    end
    tex:SetAtlas(atlas, true)
    tex:SetAlpha(0.92)
    tex:Show()
    return true
end

local function PlaceFactionSealOnPanel(f)
    if not f or not f.factionSeal or not f.bodyPanel then return end
    f.factionSeal:ClearAllPoints()
    f.factionSeal:SetPoint("CENTER", f.bodyPanel, "RIGHT", -30, 2)
end

local function ApplyDialogLayout(mode)
    local f = dialogFrame
    if not f or not f.bodyPanel or not f.bodyFs or not f.okBtn then return end
    if f._dialogLayoutMode == mode then return end
    f._dialogLayoutMode = mode
    if mode == "welcome" then
        f:SetSize(420, 210)
        if f.bodyPanel then f.bodyPanel:SetSize(388, 96) end
        if f.bookIcon then f.bookIcon:Show() end
        if f.guideBtn then f.guideBtn:Show() end
        if f.factionSeal then
            f.factionSeal:SetSize(WELCOME_FACTION_SEAL_SIZE, WELCOME_FACTION_SEAL_SIZE)
            ApplyViewerFactionSeal(f.factionSeal)
        end
        f.bodyFs:ClearAllPoints()
        f.bodyFs:SetPoint("TOPLEFT", f.bodyPanel, "TOPLEFT", 68, -10)
        f.bodyFs:SetPoint("BOTTOMRIGHT", f.bodyPanel, "BOTTOMRIGHT", -58, 10)
        if f.bookIcon then
            -- Un seul ancrage CENTER : TOP+BOTTOM etirait la texture malgre SetSize.
            f.bookIcon:SetSize(WELCOME_BOOK_ICON_SIZE, WELCOME_BOOK_ICON_SIZE)
            f.bookIcon:ClearAllPoints()
            f.bookIcon:SetPoint(
                "CENTER", f.bodyFs, "LEFT",
                -(WELCOME_BOOK_ICON_GAP + WELCOME_BOOK_ICON_SIZE / 2), 0
            )
        end
        PlaceFactionSealOnPanel(f)
        f.okBtn:ClearAllPoints()
        f.guideBtn:ClearAllPoints()
        f.guideBtn:SetPoint("TOPRIGHT", f.bodyPanel, "BOTTOM", -4, -10)
        f.okBtn:SetPoint("TOPLEFT", f.bodyPanel, "BOTTOM", 4, -10)
    elseif mode == "factionSeal" then
        f:SetSize(420, 200)
        if f.bodyPanel then f.bodyPanel:SetSize(388, 96) end
        if f.bookIcon then f.bookIcon:Hide() end
        if f.guideBtn then f.guideBtn:Hide() end
        if f.factionSeal then
            f.factionSeal:SetSize(WELCOME_FACTION_SEAL_SIZE, WELCOME_FACTION_SEAL_SIZE)
            ApplyViewerFactionSeal(f.factionSeal)
            f.factionSeal:Show()
        end
        f.bodyFs:ClearAllPoints()
        f.bodyFs:SetPoint("TOPLEFT", f.bodyPanel, "TOPLEFT", 14, -8)
        f.bodyFs:SetPoint("BOTTOMRIGHT", f.bodyPanel, "BOTTOMRIGHT", -58, 8)
        f.bodyFs:SetJustifyV("MIDDLE")
        PlaceFactionSealOnPanel(f)
        f.okBtn:ClearAllPoints()
        f.okBtn:SetPoint("TOP", f.bodyPanel, "BOTTOM", 0, -10)
    elseif mode == "patchNotes" then
        -- Notes de patch (one-shot login) : panneau haut, texte centre verticalement.
        f:SetSize(420, 380)
        if f.bodyPanel then f.bodyPanel:SetSize(388, 276) end
        if f.bookIcon then f.bookIcon:Hide() end
        if f.guideBtn then f.guideBtn:Hide() end
        if f.factionSeal then
            f.factionSeal:SetSize(WELCOME_FACTION_SEAL_SIZE, WELCOME_FACTION_SEAL_SIZE)
            ApplyViewerFactionSeal(f.factionSeal)
            f.factionSeal:Show()
        end
        f.bodyFs:ClearAllPoints()
        f.bodyFs:SetPoint("TOPLEFT", f.bodyPanel, "TOPLEFT", 12, -6)
        f.bodyFs:SetPoint("BOTTOMRIGHT", f.bodyPanel, "BOTTOMRIGHT", -58, 6)
        f.bodyFs:SetJustifyV("MIDDLE")
        PlaceFactionSealOnPanel(f)
        f.okBtn:ClearAllPoints()
        f.okBtn:SetPoint("TOP", f.bodyPanel, "BOTTOM", 0, -10)
    else
        f:SetSize(420, 200)
        if f.bodyPanel then f.bodyPanel:SetSize(388, 96) end
        if f.bookIcon then f.bookIcon:Hide() end
        if f.factionSeal then f.factionSeal:Hide() end
        if f.guideBtn then f.guideBtn:Hide() end
        f.bodyFs:ClearAllPoints()
        f.bodyFs:SetPoint("TOPLEFT", f.bodyPanel, "TOPLEFT", 14, -8)
        f.bodyFs:SetPoint("BOTTOMRIGHT", f.bodyPanel, "BOTTOMRIGHT", -14, 8)
        f.okBtn:ClearAllPoints()
        f.okBtn:SetPoint("TOP", f.bodyPanel, "BOTTOM", 0, -10)
    end
end

local function EnsureDialogFrame()
    if dialogFrame then
        SetupDialogHyperlinks(dialogFrame)
        return dialogFrame
    end

    local f = CreateFrame("Frame", "OverlordPopupDialog", UIParent, "BackdropTemplate")
    f:SetSize(420, 200)
    f:SetPoint("CENTER")
    Overlord.UI.ApplyWoodDialogBackdrop(f)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(6000)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    f:Hide()

    dialogBlocker = CreateFrame("Button", nil, UIParent)
    dialogBlocker:SetFrameStrata("FULLSCREEN_DIALOG")
    dialogBlocker:SetFrameLevel(5998)
    dialogBlocker:SetAllPoints(UIParent)
    dialogBlocker:EnableMouse(true)
    dialogBlocker:Hide()
    dialogBlocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Fond : bloque les clics jeu uniquement (fermeture = Compris, croix ou Echap)
    dialogBlocker:SetScript("OnClick", function() end)

    f:SetScript("OnShow", function(self)
        if dialogBlocker then dialogBlocker:Show() end
        if not self._skipPanelOpenSound and Overlord.PlayPanelOpenSound then
            Overlord:PlayPanelOpenSound()
        end
        self._skipPanelOpenSound = nil
        if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
            self:SetScale(Overlord.UI:GetEffectiveUiScale())
        else
            self:SetScale(1)
        end
    end)
    f:SetScript("OnHide", function(self)
        if pendingSeenId then
            Overlord.Popups:CommitPendingPopupMark()
            pendingSeenId = nil
            pendingMarkMode = nil
        end
        if dialogBlocker then dialogBlocker:Hide() end
        -- File d'attente login : popup suivante apres Compris / croix / Echap.
        if pendingLoginChain then
            pendingLoginChain = false
            C_Timer.After(0.05, function()
                if dialogFrame and dialogFrame:IsShown() then return end
                if Overlord.Popups and Overlord.Popups.TryShowNextLoginAnnouncement then
                    Overlord.Popups:TryShowNextLoginAnnouncement()
                end
            end)
        end
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
    end)

    f.titleFs = f:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    f.titleFs:SetPoint("TOP", 0, -16)
    f.titleFs:SetWidth(388)
    f.titleFs:SetJustifyH("CENTER")
    f.titleFs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    f.titleFs:SetShadowOffset(2, -2)

    f.bodyPanel = Overlord.UI.CreateWC3SubPanel(f, 388, 96)
    f.bodyPanel:SetPoint("TOP", 0, -48)

    f.bodyFs = f.bodyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.bodyFs:SetPoint("TOPLEFT", f.bodyPanel, "TOPLEFT", 14, -8)
    f.bodyFs:SetPoint("BOTTOMRIGHT", f.bodyPanel, "BOTTOMRIGHT", -14, 8)
    f.bodyFs:SetJustifyH("CENTER")
    f.bodyFs:SetJustifyV("MIDDLE")
    f.bodyFs:SetWordWrap(true)

    f.bookIcon = f.bodyPanel:CreateTexture(nil, "ARTWORK")
    f.bookIcon:SetSize(WELCOME_BOOK_ICON_SIZE, WELCOME_BOOK_ICON_SIZE)
    f.bookIcon:SetTexture(TUTORIAL_ICON)
    f.bookIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.bookIcon:Hide()

    f.factionSeal = f.bodyPanel:CreateTexture(nil, "ARTWORK")
    f.factionSeal:SetDrawLayer("ARTWORK", 1)
    f.factionSeal:Hide()

    f.guideBtn = Overlord.UI.CreateWC3Button(f, 168, 28, L.POPUP_WELCOME_GUIDE_BTN or L.GUIDE_BAR_LABEL, function()
        if Overlord.Popups and Overlord.Popups.ShowQuickGuide then
            Overlord.Popups:ShowQuickGuide()
        end
        HideDialog()
    end)
    f.guideBtn:Hide()

    f.okBtn = Overlord.UI.CreateWC3Button(f, 140, 28, L.POPUP_OK or L.EXPORT_CLOSE or "OK", HideDialog)
    f.okBtn:SetPoint("TOP", f.bodyPanel, "BOTTOM", 0, -10)

    Overlord.UI.CreateWC3CloseButton(f, HideDialog)
        :SetPoint("TOPRIGHT", -8, -8)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            HideDialog()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:EnableKeyboard(true)

    dialogFrame = f
    SetupDialogHyperlinks(f)
    return f
end

-- ---------------------------------------------------------------------------
-- Guide rapide (pages multiples, reouvrable - pas de MarkSeen)
-- ---------------------------------------------------------------------------

local quickGuideFrame = nil
local quickGuideBlocker = nil
local quickGuidePage = 1
local GUIDE_PAGE_COUNT = 3

local function HideQuickGuide()
    if quickGuideFrame then quickGuideFrame:Hide() end
end

local GUIDE_MINE_ATLAS = "Warfronts-FieldMapIcons-Empty-Mine"
local GUIDE_WOOD_ATLAS = "Warfronts-FieldMapIcons-Empty-LumberMill"

local function FormatGuideSection(sectionTitle, body)
    if not body or body == "" then return "" end
    if sectionTitle and sectionTitle ~= "" then
        return string.format("|cFFFFD100%s|r\n%s", sectionTitle, body)
    end
    return body
end

local function JoinGuideSections(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local block = select(i, ...)
        if block and block ~= "" then
            parts[#parts + 1] = block
        end
    end
    return table.concat(parts, "\n\n")
end

local function BuildResourceGuideIconLines(database, atlas)
    local lines = {}
    if not database or not atlas or atlas == "" then return "" end
    for _, entry in ipairs(database) do
        local name = entry.name or entry.id or "?"
        lines[#lines + 1] = string.format("|A:%s:18:18|a |cFFFFD100%s|r", atlas, name)
    end
    return table.concat(lines, "\n")
end

local function FormatGuideResourceBody(bodyFmt, database, atlas)
    if not bodyFmt or bodyFmt == "" then return "" end
    local icons = BuildResourceGuideIconLines(database, atlas)
    local pos = bodyFmt:find("%s", 1, true)
    if not pos then return bodyFmt end
    return bodyFmt:sub(1, pos - 1) .. icons .. bodyFmt:sub(pos + 2)
end

local function BuildGuildKeepGuideSection()
    if not L.GUIDE_SECTION_GUILD_KEEP or not L.GUIDE_GUILD_KEEP_BODY then return "" end
    local gk = Overlord.GuildKeep
    local site = gk and gk.GetDefaultSite and gk:GetDefaultSite()
    local capMin = math.floor(((gk and gk.GetDefaultHoldTimeRequired
        and gk:GetDefaultHoldTimeRequired(nil, site)) or (site and site.holdTimeRequired) or 900) / 60)
    local iconLine = string.format("%s %s   %s %s   %s %s",
        "|A:Warfronts-BaseMapIcons-Empty-MainHall:18:18|a", L.GUILD_KEEP_NEUTRAL or "Unclaimed",
        "|A:Warfronts-BaseMapIcons-Alliance-MainHall:18:18|a", L.THE_ALLIANCE or "Alliance",
        "|A:Warfronts-BaseMapIcons-Horde-MainHall:18:18|a", L.THE_HORDE or "Horde")
    local siegeRange = (gk and gk.GetSiegeWindowRangeLabel and gk:GetSiegeWindowRangeLabel()) or ""
    local victoryTime = (gk and gk.GetSiegeWindowEndLabel and gk:GetSiegeWindowEndLabel()) or ""
    local body = string.format(
        L.GUIDE_GUILD_KEEP_BODY,
        iconLine, siegeRange, capMin, victoryTime
    )
    return FormatGuideSection(L.GUIDE_SECTION_GUILD_KEEP, body)
end

local GUIDE_PAGE_TITLES = {
    function() return L.GUIDE_PAGE1_TITLE end,
    function() return L.GUIDE_PAGE2_TITLE end,
    function() return L.GUIDE_PAGE3_TITLE end,
}

local function BuildQuickGuidePageBody(page)
    if page == 1 then
        local travel = (Overlord.PlayerFaction == "Horde") and L.GUIDE_TRAVEL_HORDE or L.GUIDE_TRAVEL_ALLIANCE
        return JoinGuideSections(
            FormatGuideSection(L.GUIDE_SECTION_TRAVEL, travel),
            FormatGuideSection(L.GUIDE_SECTION_SHARD, L.GUIDE_SHARD_BODY),
            FormatGuideSection(L.GUIDE_SECTION_PROGRESS, L.GUIDE_PROGRESS_BODY),
            FormatGuideSection(L.GUIDE_SECTION_PANEL, L.GUIDE_PANEL_BODY),
            FormatGuideSection(L.GUIDE_SECTION_OPTIONS, L.GUIDE_OPTIONS_BODY),
            FormatGuideSection(L.GUIDE_SECTION_FEATURED, L.GUIDE_FEATURED_BODY)
        )
    end
    if page == 2 then
        local goldBody = FormatGuideResourceBody(L.GUIDE_GOLD_BODY, Overlord.MineDatabase, GUIDE_MINE_ATLAS)
        local woodBody = FormatGuideResourceBody(L.GUIDE_WOOD_BODY, Overlord.WoodDatabase, GUIDE_WOOD_ATLAS)
        return JoinGuideSections(
            FormatGuideSection(L.GUIDE_SECTION_CONTEST, L.GUIDE_CONTEST_BODY),
            FormatGuideSection(L.GUIDE_SECTION_GOLD, goldBody),
            FormatGuideSection(L.GUIDE_SECTION_WOOD, woodBody),
            FormatGuideSection(L.GUIDE_SECTION_SIEGE, L.GUIDE_SIEGE_BODY)
        )
    end
    if page == 3 then
        return JoinGuideSections(
            BuildGuildKeepGuideSection(),
            FormatGuideSection(L.GUIDE_SECTION_OUTPOST, L.GUIDE_OUTPOST_BODY),
            FormatGuideSection(L.GUIDE_SECTION_FACTION_CALL, L.GUIDE_FACTION_CALL_BODY),
            FormatGuideSection(L.GUIDE_SECTION_TOOLS, L.GUIDE_TOOLS_BODY)
        )
    end
    return ""
end

-- Corps du guide mis en cache par page (evite parcours MineDatabase/WoodDatabase a chaque flip).
local cachedGuideBody = {}
local cachedGuideBodyLocale = nil
local cachedGuideScrollHeights = {}

local function GetQuickGuidePageBody(page)
    local localeKey = GetLocale and GetLocale() or "enUS"
    if cachedGuideBodyLocale ~= localeKey then
        cachedGuideBody = {}
        cachedGuideScrollHeights = {}
        cachedGuideBodyLocale = localeKey
    end
    if not cachedGuideBody[page] then
        cachedGuideBody[page] = BuildQuickGuidePageBody(page)
        cachedGuideScrollHeights[page] = nil
    end
    return cachedGuideBody[page]
end

local function GetQuickGuideWindowTitle(page)
    local pageTitle = GUIDE_PAGE_TITLES[page] and GUIDE_PAGE_TITLES[page]() or ""
    local base = L.GUIDE_TITLE or "Tutorial"
    if pageTitle and pageTitle ~= "" then
        return base .. ": " .. pageTitle
    end
    return base
end

local function SetupQuickGuideHyperlinks(f)
    if not f or not f.scrollChild then return end
    if Overlord.UI and Overlord.UI.EnsureAddonLinkHandlers then
        Overlord.UI:EnsureAddonLinkHandlers()
    end
    local panel = f.scrollChild
    if panel.SetHyperlinksEnabled then
        panel:SetHyperlinksEnabled(true)
    end
    panel:EnableMouse(true)
    panel:SetScript("OnHyperlinkClick", OnPopupHyperlinkClick)
    panel:SetScript("OnHyperlinkEnter", function(_, link)
        if IsPanelAddonLink(link) then
            SetCursor("Interface\\Cursor\\Point")
        end
    end)
    panel:SetScript("OnHyperlinkLeave", function()
        ResetCursor()
    end)
end

local function PaintQuickGuide()
    if not quickGuideFrame then return end
    local page = quickGuidePage
    quickGuideFrame.titleFs:SetText(GetQuickGuideWindowTitle(page))
    if quickGuideFrame.pageFs then
        quickGuideFrame.pageFs:SetText(string.format(L.GUIDE_PAGE_INDICATOR or "Page %d / %d", page, GUIDE_PAGE_COUNT))
    end
    quickGuideFrame.bodyFs:SetText(GetQuickGuidePageBody(page))
    local scrollH = quickGuideFrame.scroll:GetHeight() or 320
    local childH = cachedGuideScrollHeights[page]
    if not childH then
        local textH = quickGuideFrame.bodyFs:GetStringHeight() or scrollH
        childH = math.max(textH + 12, scrollH)
        cachedGuideScrollHeights[page] = childH
    end
    quickGuideFrame.scrollChild:SetHeight(childH)
    quickGuideFrame.scroll:SetVerticalScroll(0)
    if quickGuideFrame.prevBtn then
        quickGuideFrame.prevBtn:SetShown(page > 1)
    end
    if quickGuideFrame.nextBtn then
        quickGuideFrame.nextBtn:SetShown(page < GUIDE_PAGE_COUNT)
    end
end

local function SetQuickGuidePage(page)
    quickGuidePage = math.max(1, math.min(GUIDE_PAGE_COUNT, tonumber(page) or 1))
    PaintQuickGuide()
end

local function EnsureQuickGuideFrame()
    if quickGuideFrame then return quickGuideFrame end

    local f = CreateFrame("Frame", "OverlordQuickGuideFrame", UIParent, "BackdropTemplate")
    f:SetSize(480, 500)
    f:SetPoint("CENTER")
    Overlord.UI.ApplyWoodDialogBackdrop(f)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(6100)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    f:Hide()

    quickGuideBlocker = CreateFrame("Button", nil, UIParent)
    quickGuideBlocker:SetFrameStrata("FULLSCREEN_DIALOG")
    quickGuideBlocker:SetFrameLevel(6098)
    quickGuideBlocker:SetAllPoints(UIParent)
    quickGuideBlocker:EnableMouse(true)
    quickGuideBlocker:Hide()
    quickGuideBlocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    quickGuideBlocker:SetScript("OnClick", HideQuickGuide)

    f:SetScript("OnShow", function(self)
        if quickGuideBlocker then quickGuideBlocker:Show() end
        if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
        if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
            self:SetScale(Overlord.UI:GetEffectiveUiScale())
        else
            self:SetScale(1)
        end
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)
    f:SetScript("OnHide", function()
        if quickGuideBlocker then quickGuideBlocker:Hide() end
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)

    f.titleFs = f:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    f.titleFs:SetPoint("TOP", 0, -14)
    f.titleFs:SetWidth(440)
    f.titleFs:SetJustifyH("CENTER")
    f.titleFs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    f.pageFs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.pageFs:SetPoint("TOP", f.titleFs, "BOTTOM", 0, -2)
    f.pageFs:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 0.85)

    f.scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", 16, -62)
    f.scroll:SetPoint("BOTTOMRIGHT", -32, 52)

    f.scrollChild = CreateFrame("Frame", nil, f.scroll)
    f.scrollChild:SetWidth(420)
    f.scroll:SetScrollChild(f.scrollChild)

    f.bodyFs = f.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.bodyFs:SetPoint("TOPLEFT", 4, -4)
    f.bodyFs:SetPoint("TOPRIGHT", -4, -4)
    f.bodyFs:SetJustifyH("LEFT")
    f.bodyFs:SetJustifyV("TOP")
    f.bodyFs:SetWordWrap(true)

    f.prevBtn = Overlord.UI.CreateWC3Button(f, 108, 28, L.GUIDE_PREV or "Previous", function()
        SetQuickGuidePage(quickGuidePage - 1)
    end)
    f.prevBtn:SetPoint("BOTTOMLEFT", 16, 16)

    f.nextBtn = Overlord.UI.CreateWC3Button(f, 108, 28, L.GUIDE_NEXT or "Next", function()
        SetQuickGuidePage(quickGuidePage + 1)
    end)
    f.nextBtn:SetPoint("BOTTOMRIGHT", -16, 16)

    f.closeBtn = Overlord.UI.CreateWC3Button(f, 120, 28, L.GUIDE_CLOSE or L.POPUP_OK, HideQuickGuide)
    f.closeBtn:SetPoint("BOTTOM", 0, 16)

    Overlord.UI.CreateWC3CloseButton(f, HideQuickGuide)
        :SetPoint("TOPRIGHT", -8, -8)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            HideQuickGuide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:EnableKeyboard(true)

    quickGuideFrame = f
    SetupQuickGuideHyperlinks(f)
    return f
end

function Overlord.Popups:ShowQuickGuide()
    quickGuidePage = 1
    EnsureQuickGuideFrame()
    PaintQuickGuide()
    quickGuideFrame:Show()
end

function Overlord.Popups:ToggleQuickGuide()
    EnsureQuickGuideFrame()
    if quickGuideFrame:IsShown() then
        HideQuickGuide()
    else
        self:ShowQuickGuide()
    end
end

function Overlord.Popups:IsQuickGuideShown()
    return quickGuideFrame ~= nil and quickGuideFrame:IsShown()
end

-- ---------------------------------------------------------------------------
-- API publique
-- ---------------------------------------------------------------------------

-- Affiche un dialogue WC3 generique (marque seenId a la fermeture).
-- markMode : "once" (defaut) ou "daily" (une fois par jour calendaire).
-- Apercu popup bienvenue (test en jeu : /run Overlord.Popups:PreviewWelcome()).
function Overlord.Popups:PreviewWelcome()
    EnsureDialogFrame()
    self:ShowDialog(
        nil,
        GetWelcomePopupTitle(),
        GetWelcomePopupBody(),
        nil,
        { showBookIcon = true, showGuideButton = true, playFactionHorn = true }
    )
end

-- opts : showBookIcon, showGuideButton (bienvenue) ; showFactionSeal ; playFactionHorn (Bloodlust / Heroism)
-- addonSoundKey : ex. "faction_call" (cor) ; okText : libelle bouton OK
function Overlord.Popups:ShowDialog(seenId, title, body, markMode, opts)
    if type(title) ~= "string" or title == "" or type(body) ~= "string" or body == "" then return end
    if seenId and (markMode or "once") ~= "daily" and self:HasSeen(seenId) then
        return
    end
    EnsureDialogFrame()
    opts = opts or {}
    pendingSeenId = seenId
    pendingMarkMode = markMode or "once"
    -- One-shot : marquer a l'affichage pour survivre a un /reload avant Compris.
    if seenId then
        self:CommitPendingPopupMark()
    end
    dialogFrame.titleFs:SetText(title)
    dialogFrame.bodyFs:SetText(body)
    if dialogFrame.okBtn then
        local okLabel = dialogFrame.okBtn.label or dialogFrame.okBtn
        if okLabel.SetText then
            okLabel:SetText(opts.okText or L.POPUP_OK or L.EXPORT_CLOSE or "OK")
        end
    end
    if opts.showBookIcon or opts.showGuideButton then
        ApplyDialogLayout("welcome")
        dialogFrame.bodyFs:SetJustifyH("LEFT")
    elseif opts.showFactionSeal then
        ApplyDialogLayout(opts.dialogLayout or "factionSeal")
        if opts.dialogLayout == "patchNotes" then
            dialogFrame.bodyFs:SetJustifyH("LEFT")
        else
            dialogFrame.bodyFs:SetJustifyH("CENTER")
        end
    else
        ApplyDialogLayout("default")
        dialogFrame.bodyFs:SetJustifyH("CENTER")
    end
    if opts.addonSoundKey and Overlord.PlayAddonSound then
        Overlord:PlayAddonSound(opts.addonSoundKey)
    elseif opts.playFactionHorn and Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("welcome_popup")
    end
    -- Bienvenue / cor de guerre : son dedie uniquement (pas lb_open en plus).
    dialogFrame._skipPanelOpenSound = opts.addonSoundKey or opts.playFactionHorn or nil
    dialogFrame:Show()
end

local function FormatAllyCallerName(name)
    if not name or name == "" then return "" end
    if Overlord.PlayerFaction == "Alliance" then
        return "|cFF4488FF" .. name .. "|r"
    elseif Overlord.PlayerFaction == "Horde" then
        return "|cFFFF4444" .. name .. "|r"
    end
    return "|cFFFFD100" .. name .. "|r"
end

local function FormatEnemyCallerName(name)
    if not name or name == "" then return "" end
    if Overlord.PlayerFaction == "Alliance" then
        return "|cFFFF4444" .. name .. "|r"
    elseif Overlord.PlayerFaction == "Horde" then
        return "|cFF4488FF" .. name .. "|r"
    end
    return "|cFFFF8800" .. name .. "|r"
end

local function FormatShortDisplayName(fullName)
    if not fullName or fullName == "" then return "?" end
    return fullName:match("^(.-)%-") or fullName
end

-- Popup RP quand un allie sonne le cor de guerre (reception FC).
function Overlord.Popups:ShowFactionCall(senderName, zoneName, frontName)
    if not senderName or senderName == "" then return end
    zoneName = zoneName or ""
    frontName = frontName or ""
    local caller = FormatAllyCallerName(senderName)
    local body
    if zoneName ~= "" and frontName ~= "" then
        body = string.format(L.POPUP_FACTION_CALL_BODY or "", caller, zoneName, frontName)
    elseif frontName ~= "" then
        body = string.format(L.POPUP_FACTION_CALL_BODY_FRONT or "", caller, frontName)
    else
        body = string.format(L.POPUP_FACTION_CALL_BODY_GENERIC or "", caller)
    end
    self:ShowDialog(nil, L.POPUP_FACTION_CALL_TITLE, body, nil, {
        showFactionSeal = true,
        addonSoundKey = "faction_call",
        okText = L.POPUP_FACTION_CALL_OK,
    })
end

-- Popup RP quand un allie assume le role de General (reception GE).
function Overlord.Popups:ShowGeneralAssumed(senderName, frontName, faction)
    if not senderName or senderName == "" then return end
    frontName = frontName or ""
    local caller = FormatAllyCallerName(senderName)
    local body
    if faction == "Horde" then
        body = string.format(L.POPUP_GENERAL_BODY_HORDE or "", caller, frontName)
    else
        body = string.format(L.POPUP_GENERAL_BODY or "", caller, frontName)
    end
    self:ShowDialog(nil, L.POPUP_GENERAL_TITLE, body, nil, {
        showFactionSeal = true,
        addonSoundKey = "general_assumed",
        okText = L.POPUP_GENERAL_OK,
    })
end

-- Alerte raid a chaque entree de front tant que la version reste en retard (cf. OnEnterFront).
function Overlord.Popups:ShowOutdatedVersion(latestVersion)
    if not latestVersion or latestVersion == "" or not L.RAID_WARNING_OUTDATED then return end
    local msg = string.format(L.RAID_WARNING_OUTDATED, tostring(Overlord.Version or "?"), latestVersion)
    if Overlord.PrintRaidWarning then
        Overlord:PrintRaidWarning(msg)
    end
end

-- Alerte map-wide : general ennemi assume le commandement (front actif).
function Overlord.Popups:ShowGeneralEnemySpotted(senderName, frontName)
    if not L or not L.POPUP_GENERAL_ENEMY_SPOTTED_BODY then return end
    local enemy = FormatEnemyCallerName(FormatShortDisplayName(senderName))
    local body = string.format(L.POPUP_GENERAL_ENEMY_SPOTTED_BODY, enemy, frontName or "")
    self:ShowDialog(nil, L.POPUP_GENERAL_ENEMY_SPOTTED_TITLE, body, nil, {
        showFactionSeal = true,
        addonSoundKey = "general_assumed",
        okText = L.POPUP_GENERAL_OK,
    })
end

-- Enregistre une annonce login : { id, title, body, when? }
function Overlord.Popups:RegisterLoginAnnouncement(entry)
    if not entry or not entry.id then return end
    loginAnnouncements[#loginAnnouncements + 1] = entry
end

function Overlord.Popups:TryShowNextLoginAnnouncement()
    if Overlord.InstanceSuspended or not Overlord.IsInitialized then return false end
    if dialogFrame and dialogFrame:IsShown() then return false end
    MigrateLegacyPopupFlags()

    for _, ann in ipairs(loginAnnouncements) do
        if ann.daily then
            -- Rapport de bataille : TryShowDailyOnLogin (flag jour, pas popupsSeen).
        elseif not self:HasSeen(ann.id) then
            if not ann.when or ann.when() then
                local title = type(ann.title) == "function" and ann.title() or ann.title
                local body  = type(ann.body)  == "function" and ann.body()  or ann.body
                if type(title) == "string" and title ~= "" and type(body) == "string" and body ~= "" then
                    pendingLoginChain = true
                    self:ShowDialog(ann.id, title, body, nil, ann.opts)
                    return true
                end
            end
        end
    end
    return false
end

function Overlord.Popups:TryShowOnLogin(attempt)
    attempt = attempt or 0
    if Overlord.InstanceSuspended or not Overlord.IsInitialized then return end
    if InCombatLockdown() and attempt < 6 then
        C_Timer.After(2, function() self:TryShowOnLogin(attempt + 1) end)
        return
    end
    self:TryShowNextLoginAnnouncement()
end

local function FormatFactionColoredName(label, faction)
    if not label or label == "" then return "" end
    if faction == "Alliance" then
        return "|cFF4488FF" .. label .. "|r"
    elseif faction == "Horde" then
        return "|cFFFF4444" .. label .. "|r"
    end
    return "|cFFFFFFFF" .. label .. "|r"
end

local function FormatGuildColoredName(guild, faction)
    return FormatFactionColoredName(guild, faction)
end

local function FormatPlayerColoredName(lb, playerName)
    if not playerName or playerName == "" then return "" end
    local _, faction = lb:GetExportPlayerMeta(playerName)
    local display = playerName:match("^(.-)%-") or playerName
    return FormatFactionColoredName(display, faction)
end

local function GetTopCapturerFromByFaction(byFaction)
    if not byFaction then return nil end
    local top = nil
    for _, list in ipairs({ byFaction.Alliance, byFaction.Horde }) do
        local entry = list and list[1]
        if entry and entry.name and (entry.count or 0) > 0 then
            if not top or entry.count > top.count then
                top = entry
            end
        end
    end
    return top
end

local function GetTopCapturer(lb, dc)
    if not lb then return nil end
    dc = dc or (lb.EnsureDisplayCache and lb:EnsureDisplayCache())
    return GetTopCapturerFromByFaction(dc and dc.byFaction)
end

-- Carte monde d'un front (Arathi, Gilneas, Loch, etc.).
local function IsPlayerOnFrontMap()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID or not Overlord.Zones or not Overlord.Zones.IsWarFrontMapID then
        return false
    end
    return Overlord.Zones:IsWarFrontMapID(mapID)
end

local function IsPlayerOnGuildKeepMap()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID or not Overlord.GuildKeep or not Overlord.GuildKeep.ResolveSiteByMapID then
        return false
    end
    return Overlord.GuildKeep:ResolveSiteByMapID(mapID) ~= nil
end

-- Joueur sur une carte de front actif (pas en capitale / hors zone de guerre).
local function IsPlayerOnActiveFront()
    if Overlord.InActiveFront then return true end
    if Overlord.IsPlayerInActiveFront then
        return Overlord:IsPlayerInActiveFront()
    end
    return false
end

local function IsPlayerOnSiegeReminderMap()
    return IsPlayerOnActiveFront() or IsPlayerOnFrontMap() or IsPlayerOnGuildKeepMap()
end

local function GetServerMinuteOfDay()
    local gk = Overlord.GuildKeep
    if gk and gk.GetSiegeMinuteOfDay then
        return gk:GetSiegeMinuteOfDay()
    end
    if GetGameTime then
        local h, m = GetGameTime()
        h = tonumber(h) or 0
        m = tonumber(m) or 0
        return h * 60 + m
    end
    local d = date("*t", time())
    return (tonumber(d.hour) or 0) * 60 + (tonumber(d.min) or 0)
end

local function IsGuildKeepReminderWindow()
    local gk = Overlord.GuildKeep
    if not gk or not gk.GetSiegeReminderStartMinute or not gk.GetSiegeWindowStartMinute then
        return false
    end
    local minute = GetServerMinuteOfDay()
    return minute >= gk:GetSiegeReminderStartMinute()
        and minute < gk:GetSiegeWindowStartMinute()
end

-- Corps du rapport de bataille (nil si aucune stat a afficher).
local battleReportBodyCache = nil
local battleReportBodyEpoch = nil

local function BuildBattleReportBody()
    local lb = Overlord.Leaderboard
    if not lb or not lb.EnsureDisplayCache then return nil end
    local dc = lb:EnsureDisplayCache()
    -- La vue initiale se construit en tranches. TryShowDailyOnLogin possede deja son
    -- retry differe; ne jamais contourner ce chemin par un tri complet synchrone ici.
    if not dc or dc.ready == false then return nil end
    -- Une vue stale est volontairement affichable pendant le build. Indexer le texte
    -- par l'epoch effectivement publie (pas l'epoch cible) permet au commit de le rafraichir.
    local epoch = dc.epoch or 0
    if battleReportBodyCache and battleReportBodyEpoch == epoch then
        return battleReportBodyCache
    end
    local lines = {}

    local sortedGuilds = dc.sortedGuilds or {}
    local topGuild = sortedGuilds and sortedGuilds[1]
    if topGuild and topGuild.guild and (topGuild.kills or 0) > 0 then
        lines[#lines + 1] = string.format(
            L.POPUP_BATTLE_REPORT_GUILD or "%s : %d",
            FormatGuildColoredName(topGuild.guild, topGuild.faction),
            topGuild.kills
        )
    end

    local sortedKills = dc.sortedKills or {}
    local topKiller = sortedKills and sortedKills[1]
    if topKiller and topKiller.name and (topKiller.kills or 0) > 0 then
        lines[#lines + 1] = string.format(
            L.POPUP_BATTLE_REPORT_KILLER or "%s : %d",
            FormatPlayerColoredName(lb, topKiller.name),
            topKiller.kills
        )
    end

    local topCapturer = GetTopCapturer(lb, dc)
    if topCapturer and topCapturer.name and (topCapturer.count or 0) > 0 then
        lines[#lines + 1] = string.format(
            L.POPUP_BATTLE_REPORT_CAPTURER or "%s : %d",
            FormatPlayerColoredName(lb, topCapturer.name),
            topCapturer.count
        )
    end

    if #lines == 0 then
        battleReportBodyCache = nil
        battleReportBodyEpoch = epoch
        return nil
    end
    battleReportBodyCache = table.concat(lines, "\n\n")
    battleReportBodyEpoch = epoch
    return battleReportBodyCache
end

function Overlord.Popups:TryShowNextDailyAnnouncement()
    if Overlord.InstanceSuspended or not Overlord.IsInitialized then return false end
    if dialogFrame and dialogFrame:IsShown() then return false end
    MigrateLegacyPopupFlags()

    for _, ann in ipairs(loginAnnouncements) do
        if ann.daily and not self:HasShownToday(ann.id) then
            if not ann.when or ann.when() then
                local title = type(ann.title) == "function" and ann.title() or ann.title
                local body  = type(ann.body)  == "function" and ann.body()  or ann.body
                if type(title) == "string" and title ~= "" and type(body) == "string" and body ~= "" then
                    self:ShowDialog(ann.id, title, body, "daily", ann.opts)
                    return true
                end
            end
        end
    end
    return false
end

local BATTLE_REPORT_PREVIEW_RETRY_DELAY = 0.05
local BATTLE_REPORT_PREVIEW_RETRY_LIMIT = 120

-- Reaffiche le rapport de bataille (efface le flag du jour, pour tests).
function Overlord.Popups:PreviewBattleReport(attempt)
    attempt = math.max(0, math.floor(tonumber(attempt) or 0))
    if not Overlord.IsInitialized then return end
    if attempt == 0 then
        if OverlordDB then
            OverlordDB.config = OverlordDB.config or {}
            OverlordDB.config.popupsDailyShown = OverlordDB.config.popupsDailyShown or {}
            OverlordDB.config.popupsDailyShown.daily_battle_report = nil
        end
        if Overlord.CheckActiveFrontZone then Overlord:CheckActiveFrontZone() end
        if not IsPlayerOnActiveFront() and not IsPlayerOnFrontMap() then
            if Overlord.PrintNotification and L.POPUP_BATTLE_REPORT_NOT_FRONT then
                Overlord:PrintNotification(
                    "|cFFFFD100[Overlord]|r " .. L.POPUP_BATTLE_REPORT_NOT_FRONT)
            end
            return
        end
    end
    local lb = Overlord.Leaderboard
    local dc = lb and lb.EnsureDisplayCache and lb:EnsureDisplayCache() or nil
    if dc and dc.ready == false and attempt < BATTLE_REPORT_PREVIEW_RETRY_LIMIT then
        C_Timer.After(BATTLE_REPORT_PREVIEW_RETRY_DELAY, function()
            local popups = Overlord.Popups
            if popups then popups:PreviewBattleReport(attempt + 1) end
        end)
        return
    end
    if attempt > 0 then
        if Overlord.CheckActiveFrontZone then Overlord:CheckActiveFrontZone() end
        if not IsPlayerOnActiveFront() and not IsPlayerOnFrontMap() then return end
    end
    if self:TryShowNextDailyAnnouncement() then return end
    if Overlord.PrintNotification and L.POPUP_BATTLE_REPORT_NO_DATA then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.POPUP_BATTLE_REPORT_NO_DATA)
    end
end

-- Popup quotidienne : retente si hors front (TP en cours) ou sync pas encore prete.
function Overlord.Popups:TryShowDailyOnLogin(attempt)
    attempt = attempt or 0
    if Overlord.InstanceSuspended or not Overlord.IsInitialized then return end
    if InCombatLockdown() and attempt < 6 then
        C_Timer.After(2, function() self:TryShowDailyOnLogin(attempt + 1) end)
        return
    end
    if Overlord.CheckActiveFrontZone then
        Overlord:CheckActiveFrontZone()
    end
    self:TryShowFeaturedFrontOnLogin()
    if self:TryShowNextDailyAnnouncement() then return end
    -- Retente seulement sur une carte de front (chargement / sync), pas en ville.
    if attempt < 4 and (IsPlayerOnActiveFront() or IsPlayerOnFrontMap()) then
        C_Timer.After(6, function() self:TryShowDailyOnLogin(attempt + 1) end)
    end
end

-- ---------------------------------------------------------------------------
-- Front du jour : extension laterale du panneau principal (repliable via onglet fleche).
-- ---------------------------------------------------------------------------

-- Forward declarations (dependances circulaires entre toggle / frame / contenu).
local EnsureFeaturedFrontToggle
local EnsureFeaturedFrontFrame
local ApplyFeaturedFrontContent
local ApplyFeaturedFrontActivity
local LoadFeaturedFrontContent
local ToggleFeaturedFrontExpanded
local StartFeaturedFrontActivityTicker
local StopFeaturedFrontActivityTicker

local lastFeaturedFrontLoadedId = nil

local function GetMainPanelFrame()
    if Overlord.UI and Overlord.UI.GetMainFrame then
        return Overlord.UI:GetMainFrame()
    end
    return _G.OverlordMainFrame
end

local function IsFeaturedFrontExpanded()
    if not OverlordDB or not OverlordDB.config then return true end
    local v = OverlordDB.config.featuredFrontExpanded
    if v == nil then return true end
    return v == true
end

local function SaveFeaturedFrontExpanded(expanded)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.featuredFrontExpanded = expanded and true or false
end

-- Ferme : fleche vers la gauche (deployer). Ouvert : croix (refermer).
local function ApplyFeaturedFrontToggleArrow(expanded)
    local tab = featuredFrontToggleBtn
    if not tab then return end
    if tab.closeMark then
        if expanded then
            tab.closeMark:Show()
        else
            tab.closeMark:Hide()
        end
    end
    local tex = tab.arrow
    if not tex then return end
    if expanded then
        tex:Hide()
        return
    end
    tex:Show()
    local src = Overlord.UI.GetBlizzardFlyoutArrowSource and Overlord.UI.GetBlizzardFlyoutArrowSource()
    Overlord.UI.ApplyFlyoutArrowStyle(tex, "LEFT", src, GOLD)
end

-- Croix de fermeture centree geometriquement (le glyphe × GameFont est decale).
local function CreateFeaturedFrontCloseMark(parent)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(FEATURED_FRONT_CLOSE_SIZE, FEATURED_FRONT_CLOSE_SIZE)
    holder:SetPoint("CENTER", parent, "CENTER", 0, 0)
    holder:Hide()

    local function addStroke(rotation)
        local line = holder:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        line:SetSize(FEATURED_FRONT_CLOSE_SIZE + 1, 1.5)
        line:SetPoint("CENTER", holder, "CENTER", 0, 0)
        line:SetRotation(rotation)
    end
    addStroke(math.rad(45))
    addStroke(math.rad(-45))
    return holder
end

-- Panneau front colle a la reliure du main ; onglet centre verticalement sur le bord gauche.
local function SyncFeaturedFrontPanelAnchors()
    local mainFrame = GetMainPanelFrame()
    if not mainFrame or not featuredFrontToggleBtn then return end

    featuredFrontToggleBtn:ClearAllPoints()
    -- Centre de l'onglet sur la couture front/main (bord droit du panneau front).
    featuredFrontToggleBtn:SetPoint("CENTER", mainFrame, "LEFT", FEATURED_FRONT_SPINE_OVERLAP, 0)

    if featuredFrontFrame then
        featuredFrontFrame:ClearAllPoints()
        featuredFrontFrame:SetPoint("TOP", mainFrame, "TOP", 0, 0)
        featuredFrontFrame:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 0)
        featuredFrontFrame:SetPoint("RIGHT", mainFrame, "LEFT", FEATURED_FRONT_SPINE_OVERLAP, 0)
    end
end

-- Ticker dedie : ne pas accrocher au UI:Refresh global (deja sollicite en event massif).
local FEATURED_FRONT_ACTIVITY_REFRESH_INTERVAL = 10
local featuredFrontActivityTicker = nil

StopFeaturedFrontActivityTicker = function()
    if featuredFrontActivityTicker then
        featuredFrontActivityTicker:Cancel()
        featuredFrontActivityTicker = nil
    end
end

StartFeaturedFrontActivityTicker = function()
    if featuredFrontActivityTicker then return end
    featuredFrontActivityTicker = C_Timer.NewTicker(FEATURED_FRONT_ACTIVITY_REFRESH_INTERVAL, function()
        -- L'activite appartient au volet lateral : aucun travail periodique quand
        -- ce volet est replie ou que le panneau principal est masque.
        local activityPanel = featuredFrontFrame and featuredFrontFrame.activityPanel
        if not activityPanel or not activityPanel:IsVisible() then
            StopFeaturedFrontActivityTicker()
            return
        end
        ApplyFeaturedFrontActivity(featuredFrontFrame)
    end)
end

local function SetFeaturedFrontExpanded(expanded, persist)
    if not featuredFrontFrame or not featuredFrontToggleBtn then return end
    local wasExpanded = featuredFrontFrame:IsShown()
    if expanded and wasExpanded then
        return
    end
    if not expanded and not wasExpanded then
        return
    end
    if not expanded and featuredFrontFrame._previewOnly then
        featuredFrontFrame._previewOnly = nil
    end
    if persist and not expanded and featuredFrontFrame and not featuredFrontFrame._previewOnly then
        Overlord.Popups:MarkFeaturedFrontShownToday()
    end
    if persist then
        SaveFeaturedFrontExpanded(expanded)
    end
    featuredFrontFrame:SetShown(expanded)
    SyncFeaturedFrontPanelAnchors()
    ApplyFeaturedFrontToggleArrow(expanded)
end

local function TrySetAtlas(tex, atlas)
    if not tex or not atlas or not tex.SetAtlas then
        if tex then tex:Hide() end
        return false
    end
    local ok = pcall(tex.SetAtlas, tex, atlas, true)
    if not ok then
        tex:Hide()
        return false
    end
    tex:Show()
    return true
end

local function ApplyFeaturedFrontHeader(f, faction)
    local atlas = FEATURED_FACTION_HEADER_ATLAS[faction]
    local yOffset = FEATURED_FACTION_HEADER_YOFFSET[faction] or -48
    f.factionHeader:ClearAllPoints()
    f.factionHeader:SetPoint("BOTTOM", f, "TOP", 0, yOffset)
    if not TrySetAtlas(f.factionHeader, atlas) then return false end
    local scale = FEATURED_FACTION_HEADER_SCALE[faction]
    if scale then
        local w, h = f.factionHeader:GetSize()
        if w > 0 and h > 0 then
            f.factionHeader:SetSize(w * scale, h * scale)
        end
    end
    return true
end

local function ApplyFeaturedFrontTitleRibbon(f, faction)
    local kit = FEATURED_FACTION_TITLE_ATLAS[faction]
    if not kit then
        f.titleLeft:Hide()
        f.titleRight:Hide()
        f.titleMiddle:Hide()
        return false
    end
    local okLeft = TrySetAtlas(f.titleLeft, kit.left)
    local okRight = TrySetAtlas(f.titleRight, kit.right)
    local okMiddle = TrySetAtlas(f.titleMiddle, kit.middle)
    return okLeft and okRight and okMiddle
end

-- Applique une vignette WarBoard (meme crop que le panneau front du jour).
local function ApplyFrontActivityIcon(tex, spec)
    if not tex then return end
    if not spec or not spec.path then
        tex:Hide()
        tex._frontIconKey = nil
        return
    end
    local key = spec.path .. "\31" .. tostring(spec.texCoord and spec.texCoord[1] or "")
    if tex._frontIconKey == key then return end
    tex._frontIconKey = key
    tex:Show()
    tex:SetVertexColor(1, 1, 1, 1)
    local tc = spec.texCoord
    if tc then
        tex:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
    else
        tex:SetTexCoord(0, 1, 0, 1)
    end
    if tex.SetAtlas then tex:SetAtlas(nil) end
    tex:SetTexture(spec.path)
end

local function GetFrontActivityAgeColor(active, ageSeconds)
    if not active then return 0.45, 0.45, 0.45 end
    if (ageSeconds or 0) < 60 then return 1, 0.82, 0.35 end
    return 0.82, 0.82, 0.82
end

local function FormatFrontActivityAge(active, ageSeconds)
    if not active then return L.FEATURED_FRONT_ACTIVITY_DASH or "..." end
    ageSeconds = math.max(0, tonumber(ageSeconds) or 0)
    if ageSeconds < 60 then
        return L.FEATURED_FRONT_ACTIVITY_JUST_NOW or "just now"
    end
    local minutes = math.min(5, math.floor(ageSeconds / 60))
    return string.format(L.FEATURED_FRONT_ACTIVITY_MIN_AGO or "%d min ago", minutes)
end

-- Ligne activite : colonne etoile fixe + icone front + nom + recence, alignes a gauche.
local function LayoutFeaturedFrontActivityRowIcons(row, isFeatured)
    if not row or not row.frontIcon or not row.content then return end
    row.frontIcon:ClearAllPoints()
    -- Colonne etoile toujours reservee : aligne icones et noms entre lignes actives/inactives.
    local iconLeft = FEATURED_FRONT_ACTIVITY_STAR + 2
    row.frontIcon:SetPoint("LEFT", row.content, "LEFT", iconLeft, 0)
end

local function CreateFeaturedFrontActivityRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(FEATURED_FRONT_ACTIVITY_ROW_H)

    row.content = CreateFrame("Frame", nil, row)
    row.content:SetSize(FEATURED_FRONT_ACTIVITY_CONTENT_W, FEATURED_FRONT_ACTIVITY_ROW_H)
    row.content:SetPoint("LEFT", row, "LEFT", 10, 0)

    row.star = row.content:CreateTexture(nil, "ARTWORK")
    row.star:SetSize(FEATURED_FRONT_ACTIVITY_STAR, FEATURED_FRONT_ACTIVITY_STAR)
    row.star:SetPoint("LEFT", row.content, "LEFT", 0, 0)
    row.star:Hide()

    row.frontIcon = row.content:CreateTexture(nil, "ARTWORK")
    row.frontIcon:SetSize(FEATURED_FRONT_ACTIVITY_ICON, FEATURED_FRONT_ACTIVITY_ICON)
    row.frontIcon:SetPoint("LEFT", row.content, "LEFT", 0, 0)

    row.valueFs = row.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.valueFs:SetPoint("RIGHT", row.content, "RIGHT", 0, 0)
    row.valueFs:SetPoint("TOP", row.content, "TOP", 0, 0)
    row.valueFs:SetPoint("BOTTOM", row.content, "BOTTOM", 0, 0)
    row.valueFs:SetWidth(80)
    row.valueFs:SetJustifyH("RIGHT")
    row.valueFs:SetJustifyV("MIDDLE")
    row.valueFs:SetWordWrap(false)
    row.valueFs:SetMaxLines(1)

    row.nameFs = row.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameFs:SetPoint("LEFT", row.frontIcon, "RIGHT", 6, 0)
    row.nameFs:SetPoint("RIGHT", row.valueFs, "LEFT", -4, 0)
    row.nameFs:SetPoint("TOP", row.content, "TOP", 0, 0)
    row.nameFs:SetPoint("BOTTOM", row.content, "BOTTOM", 0, 0)
    row.nameFs:SetJustifyH("LEFT")
    row.nameFs:SetJustifyV("MIDDLE")
    row.nameFs:SetWordWrap(false)
    row.nameFs:SetMaxLines(1)

    row:Hide()
    return row
end

local function SetFeaturedFrontActivityRow(row, frontId, label, active, ageSeconds, isFeatured)
    if not row then return end
    row:Show()
    local ageText = FormatFrontActivityAge(active, ageSeconds)
    local cacheKey = (frontId or "") .. "\31" .. (label or "") .. "\31" .. ageText
        .. "\31" .. (isFeatured and "1" or "0")
    if row._activityKey == cacheKey then return end
    row._activityKey = cacheKey

    if isFeatured then
        row.star:Show()
        row.star:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
        if row.star.SetAtlas then
            pcall(row.star.SetAtlas, row.star, FEATURED_FRONT_ACTIVITY_STAR_ATLAS, false)
        end
    else
        row.star:Hide()
    end
    LayoutFeaturedFrontActivityRowIcons(row, isFeatured)

    local fronts = Overlord.Fronts
    local iconSpec = fronts and fronts.GetFrontActivityIcon and fronts:GetFrontActivityIcon(frontId)
    ApplyFrontActivityIcon(row.frontIcon, iconSpec)

    local br, bg, bb = GetFrontActivityAgeColor(active, ageSeconds)
    if active then
        row.valueFs:SetText(ageText)
        row.valueFs:SetTextColor(br, bg, bb)
        row.frontIcon:SetAlpha(1)
    else
        row.valueFs:SetText(ageText)
        row.valueFs:SetTextColor(br, bg, bb)
        row.frontIcon:SetAlpha(0.72)
    end
    if isFeatured then
        row.nameFs:SetText("|cFFFFD100" .. label .. "|r")
    elseif active then
        row.nameFs:SetText(label)
        row.nameFs:SetTextColor(0.92, 0.92, 0.92)
    else
        row.nameFs:SetText(label)
        row.nameFs:SetTextColor(0.58, 0.58, 0.58)
    end
end

local function HideFeaturedFrontActivityRows(f)
    if not f or not f.activityRows then return end
    for _, row in ipairs(f.activityRows) do
        row:Hide()
    end
end

local function ComputeFeaturedFrontActivityHeight(rowCount, showEmpty)
    local contentH = FEATURED_FRONT_ACTIVITY_TITLE_H
    if showEmpty then
        contentH = contentH + 36 + FEATURED_FRONT_ACTIVITY_BOTTOM_PAD
    elseif rowCount > 0 then
        local visibleRows = math.min(rowCount, FEATURED_FRONT_ACTIVITY_VISIBLE_ROWS)
        contentH = contentH + visibleRows * (FEATURED_FRONT_ACTIVITY_ROW_H + FEATURED_FRONT_ACTIVITY_ROW_GAP)
            + FEATURED_FRONT_ACTIVITY_BOTTOM_PAD
    else
        contentH = contentH + FEATURED_FRONT_ACTIVITY_BOTTOM_PAD
    end
    return contentH
end

-- Hauteur du bloc activite pour aligner activite + prime sur la zone active ou la grille d'actions.
local function GetFeaturedFrontActionsCard()
    return Overlord.UI and Overlord.UI.actionsCard
end

local function GetFeaturedFrontActiveZoneFrame()
    local azFrame = Overlord.UI and Overlord.UI.activeZoneFrame
    if azFrame and azFrame:IsShown() then return azFrame end
    return nil
end

local function GetFeaturedFrontActivityMatchHeight(f, bountyVisible)
    local actionsCard = GetFeaturedFrontActionsCard()
    if not actionsCard then return nil end
    local actionsH = actionsCard:GetHeight()
    if not actionsH or actionsH <= 0 then return nil end

    local matchH = actionsH
    local azFrame = GetFeaturedFrontActiveZoneFrame()
    if azFrame then
        matchH = (azFrame:GetHeight() or 64) + FEATURED_FRONT_ACTIONS_GAP + actionsH
    end

    if bountyVisible and f and f.bountyBtn then
        local bountyH = f.bountyBtn:GetHeight() or 30
        return math.max(0, matchH - bountyH - FEATURED_FRONT_BOUNTY_GAP)
    end
    return matchH
end

-- Texte vide : centrage vertical mesure (le panneau garde sa hauteur d'alignement actions).
local function LayoutFeaturedFrontActivityEmptyText(f)
    if not f or not f.activityEmptyFs or not f.activityPanel then return end
    local pad = FEATURED_FRONT_ACTIVITY_TEXT_PAD
    local panelH = f.activityPanel:GetHeight() or 0
    local areaH = panelH - FEATURED_FRONT_ACTIVITY_TITLE_H - FEATURED_FRONT_ACTIVITY_BOTTOM_PAD
    if areaH < 0 then areaH = 0 end

    f.activityEmptyFs:ClearAllPoints()
    f.activityEmptyFs:SetPoint("LEFT", f.activityPanel, "LEFT", pad, 0)
    f.activityEmptyFs:SetPoint("RIGHT", f.activityPanel, "RIGHT", -pad, 0)
    f.activityEmptyFs:SetJustifyH("CENTER")
    f.activityEmptyFs:SetWordWrap(true)
    f.activityEmptyFs:SetShadowOffset(0, 0)

    local textH = f.activityEmptyFs:GetStringHeight() or 0
    local topInset = math.max(0, math.floor((areaH - textH) * 0.5))
    f.activityEmptyFs:SetPoint("TOP", f.activityPanel, "TOP", 0, -(FEATURED_FRONT_ACTIVITY_TITLE_H + topInset))
end

local function ApplyFeaturedFrontActivityAnchors(f, contentH, bountyVisible, verticalShift)
    local actionsCard = GetFeaturedFrontActionsCard()
    if not actionsCard then return end
    local azFrame = GetFeaturedFrontActiveZoneFrame()
    local hasActiveZone = azFrame ~= nil
    local topAnchor = azFrame or actionsCard
    verticalShift = math.max(0, verticalShift or 0)

    f.activityPanel:ClearAllPoints()
    f.activityPanel:SetPoint("LEFT", f, "LEFT", 24, 0)
    f.activityPanel:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.activityPanel:SetHeight(contentH)

    if bountyVisible and f.bountyBtn then
        f.bountyBtn:SetShown(true)
        f.bountyBtn:ClearAllPoints()
        f.bountyBtn:SetPoint("LEFT", f, "LEFT", 24, 0)
        f.bountyBtn:SetPoint("RIGHT", f, "RIGHT", -24, 0)
        if hasActiveZone then
            f.activityPanel:SetPoint("TOP", topAnchor, "TOP", 0, -verticalShift)
            f.bountyBtn:SetPoint("TOP", f.activityPanel, "BOTTOM", 0, -FEATURED_FRONT_BOUNTY_GAP)
        else
            f.bountyBtn:SetPoint(
                "BOTTOM", actionsCard, "BOTTOM", 0,
                FEATURED_FRONT_NO_ACTIVE_LIFT - verticalShift)
            f.activityPanel:SetPoint("BOTTOM", f.bountyBtn, "TOP", 0, FEATURED_FRONT_BOUNTY_GAP)
        end
        return
    end

    if f.bountyBtn then
        f.bountyBtn:Hide()
    end
    if hasActiveZone then
        f.activityPanel:SetPoint("TOP", topAnchor, "TOP", 0, -verticalShift)
    else
        f.activityPanel:SetPoint(
            "BOTTOM", actionsCard, "BOTTOM", 0,
            FEATURED_FRONT_NO_ACTIVE_LIFT - verticalShift)
    end
end

-- La carte garde la hauteur historique de cinq lignes. Les fronts supplementaires
-- restent accessibles dans un vrai viewport, sans pousser le bouton Contrats sous le cadre.
local function LayoutFeaturedFrontActivityScroll(f, rowCount, showEmpty)
    if not f or not f.activityScroll or not f.activityRowsContent then return end
    rowCount = math.max(0, math.floor(tonumber(rowCount) or 0))
    local showRows = rowCount > 0 and not showEmpty
    f.activityScroll:SetShown(showRows)
    if not showRows then
        f.activityScroll._overlordHasOverflow = false
        f.activityScroll._overlordContentHeight = 1
        f.activityRowsContent:SetHeight(1)
        f.activityScroll:SetVerticalScroll(0)
        if f.activityScroll.RefreshCleanRail then f.activityScroll:RefreshCleanRail() end
        return
    end

    local viewportH = math.max(1, f.activityScroll:GetHeight()
        or ((f.activityPanel:GetHeight() or 1)
            - FEATURED_FRONT_ACTIVITY_TITLE_H - FEATURED_FRONT_ACTIVITY_BOTTOM_PAD))
    local rowStep = FEATURED_FRONT_ACTIVITY_ROW_H + FEATURED_FRONT_ACTIVITY_ROW_GAP
    local rowsH = math.max(1, rowCount * rowStep - FEATURED_FRONT_ACTIVITY_ROW_GAP)
    local contentH = math.max(viewportH, rowsH)
    f.activityRowsContent:SetHeight(contentH)
    f.activityScroll._overlordContentHeight = contentH
    f.activityScroll._overlordHasOverflow = rowsH > viewportH + 1
    if not f.activityScroll._overlordHasOverflow then
        f.activityScroll:SetVerticalScroll(0)
    else
        local maximum = math.max(0, contentH - viewportH)
        if (f.activityScroll:GetVerticalScroll() or 0) > maximum then
            f.activityScroll:SetVerticalScroll(maximum)
        end
    end
    if f.activityScroll.RefreshCleanRail then f.activityScroll:RefreshCleanRail() end
end

local function AnchorFeaturedFrontActivityBlock(f, contentH, minimumContentH, bountyVisible)
    -- Preserve the visual alignment with the main panel whenever it fits.  Long
    -- localized body copy can wrap to an extra line, though, so measure the real
    -- rendered bounds and move the whole activity/bounty block only as far as
    -- needed to keep a stable gap below it.
    ApplyFeaturedFrontActivityAnchors(f, contentH, bountyVisible, 0)

    if f.IsShown and not f:IsShown() then
        -- Hidden frames do not always expose final FontString bounds.  The show
        -- path calls the layout again, so defer collision resolution until then.
        f._activityBodyCollisionPending = true
        return
    end

    local panelTop = f.activityPanel and f.activityPanel:GetTop()
    local bodyBottom = f.bodyFs and f.bodyFs:GetBottom()
    if not panelTop or not bodyBottom then
        f._activityBodyCollisionPending = true
        return
    end

    f._activityBodyCollisionPending = nil
    local verticalShift = math.max(
        0, math.ceil(panelTop + FEATURED_FRONT_BODY_ACTIVITY_GAP - bodyBottom))
    f._activityBodyCollisionShift = verticalShift
    if verticalShift > 0 then
        -- The matching height intentionally contains blank stretch so that this
        -- card lines up with the main-panel blocks.  Consume that stretch first:
        -- the activity rows keep their full minimum height and the bottom edge
        -- stays stable unless the localized copy really needs more room.
        local shrink = math.min(
            verticalShift, math.max(0, contentH - (minimumContentH or contentH)))
        local resolvedHeight = contentH - shrink
        local anchorShift = verticalShift
        if not GetFeaturedFrontActiveZoneFrame() then
            -- This variant is bottom-anchored, so shrinking already lowers its
            -- top edge.  Only move the bottom for any overlap left afterward.
            anchorShift = verticalShift - shrink
        end
        f._activityResolvedHeight = resolvedHeight
        ApplyFeaturedFrontActivityAnchors(f, resolvedHeight, bountyVisible, anchorShift)
    else
        f._activityResolvedHeight = contentH
    end
end

local function ApplyFeaturedFrontActivityLayout(f, rowCount, showEmpty)
    if not f or not f.activityPanel then return end
    rowCount = rowCount or f._activityRowCount or 0
    if showEmpty == nil then
        showEmpty = f._activityShowEmpty == true
    end
    f._activityRowCount = rowCount
    f._activityShowEmpty = showEmpty

    local actionsCard = Overlord.UI and Overlord.UI.actionsCard
    if not actionsCard then return end

    local hasContracts = Overlord.ManualBounty
        and Overlord.ManualBounty.HasOpenContracts
        and Overlord.ManualBounty:HasOpenContracts()
    local bountyVisible = hasContracts
    local minimumContentH = ComputeFeaturedFrontActivityHeight(rowCount, showEmpty)
    local contentH = minimumContentH
    local matchH = GetFeaturedFrontActivityMatchHeight(f, bountyVisible)
    if matchH then
        contentH = math.max(contentH, matchH)
    end

    local bodyTextH = f.bodyFs and math.ceil(f.bodyFs:GetStringHeight() or 0) or 0
    local layoutKey = rowCount .. "|" .. (showEmpty and 1 or 0) .. "|"
        .. (bountyVisible and 1 or 0) .. "|" .. contentH .. "|" .. bodyTextH
    if f._activityLayoutKey == layoutKey and not f._activityBodyCollisionPending then return end
    f._activityLayoutKey = layoutKey

    AnchorFeaturedFrontActivityBlock(f, contentH, minimumContentH, bountyVisible)
    LayoutFeaturedFrontActivityScroll(f, rowCount, showEmpty)

    if f.activityEmptyFs and showEmpty and f.activityTitleFs then
        LayoutFeaturedFrontActivityEmptyText(f)
    end
end

function Overlord.Popups:RefreshFeaturedFrontBountyButton()
    if featuredFrontFrame and ApplyFeaturedFrontActivity then
        ApplyFeaturedFrontActivity(featuredFrontFrame)
    end
end

-- Bloc activite : sous-panneau WC3, une ligne par front (5 dernieres minutes).
ApplyFeaturedFrontActivity = function(f)
    if not f or not f.activityPanel then return end
    local fa = Overlord.FrontActivity
    if not fa or not fa.GetActivityRows then
        f.activityPanel:Hide()
        if f.bountyBtn then f.bountyBtn:Hide() end
        return
    end
    f.activityPanel:Show()
    if f.activityTitleFs then
        f.activityTitleFs:Show()
        local title = L.FEATURED_FRONT_ACTIVITY_TITLE or "Recent activity (Last 5 min)"
        if f.activityTitleFs._activityTitleKey ~= title then
            f.activityTitleFs._activityTitleKey = title
            f.activityTitleFs:SetText(title)
        end
    end

    local rows = fa:GetActivityRows()
    local featuredId = lastFeaturedFrontLoadedId
        or (Overlord.Fronts and Overlord.Fronts.GetFeaturedFrontId and Overlord.Fronts:GetFeaturedFrontId())
    local anyActive = false
    for _, row in ipairs(rows) do
        if row.active then anyActive = true break end
    end

    for i = #rows + 1, #(f.activityRows or {}) do
        local row = f.activityRows[i]
        if row then
            row:Hide()
        end
    end
    if f.activityEmptyFs then f.activityEmptyFs:Hide() end

    if #rows == 0 or not anyActive then
        HideFeaturedFrontActivityRows(f)
        if f.activityEmptyFs then
            f.activityEmptyFs:Show()
            local emptyText = L.FEATURED_FRONT_ACTIVITY_NONE or "No fighting reported in the last 5 minutes"
            if f.activityEmptyFs._activityEmptyKey ~= emptyText then
                f.activityEmptyFs._activityEmptyKey = emptyText
                f.activityEmptyFs:SetText(emptyText)
            end
        end
        ApplyFeaturedFrontActivityLayout(f, 0, true)
        return
    end
    if f.activityEmptyFs then
        f.activityEmptyFs._activityEmptyKey = nil
    end

    local visibleRows = 0
    for i, data in ipairs(rows) do
        local rowFrame = f.activityRows[i]
        if rowFrame then
            SetFeaturedFrontActivityRow(
                rowFrame,
                data.frontId,
                data.label,
                data.active,
                data.ageSeconds,
                featuredId and data.frontId == featuredId
            )
            visibleRows = visibleRows + 1
        end
    end
    ApplyFeaturedFrontActivityLayout(f, visibleRows, false)
end

EnsureFeaturedFrontToggle = function(mainFrame)
    if featuredFrontToggleBtn and featuredFrontToggleBtn._layoutVersion == FEATURED_FRONT_LAYOUT_VERSION then
        return featuredFrontToggleBtn
    end
    if featuredFrontToggleBtn then
        featuredFrontToggleBtn:Hide()
        featuredFrontToggleBtn = nil
    end

    local tab = CreateFrame("Button", "OverlordFeaturedFrontToggle", mainFrame, "BackdropTemplate")
    tab._layoutVersion = FEATURED_FRONT_LAYOUT_VERSION
    tab:SetSize(FEATURED_FRONT_TOGGLE_W, FEATURED_FRONT_TOGGLE_H)
    tab:SetFrameLevel(mainFrame:GetFrameLevel() + 12)
    tab:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 4, bottom = 4 },
    })
    tab:SetBackdropColor(0.08, 0.08, 0.12, 0.94)
    tab:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.75)

    local glow = tab:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\BUTTONS\\UI-Panel-Button-Highlight")
    glow:SetTexCoord(0, 0.625, 0, 0.6875)
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.20)

    tab.arrow = tab:CreateTexture(nil, "ARTWORK")
    tab.arrow:SetSize(12, 12)
    tab.arrow:SetPoint("CENTER", tab, "CENTER", 0, 0)

    tab.closeMark = CreateFeaturedFrontCloseMark(tab)

    tab:SetScript("OnClick", ToggleFeaturedFrontExpanded)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local expanded = featuredFrontFrame and featuredFrontFrame:IsShown()
        GameTooltip:SetText(expanded and (L.FEATURED_FRONT_COLLAPSE or "Masquer") or (L.FEATURED_FRONT_EXPAND or "Front du jour"))
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    featuredFrontToggleBtn = tab
    return tab
end

EnsureFeaturedFrontFrame = function()
    if Overlord.UI and Overlord.UI.Initialize then
        Overlord.UI:Initialize()
    end
    local mainFrame = GetMainPanelFrame()
    if not mainFrame then return nil end

    if featuredFrontFrame and featuredFrontFrame._layoutVersion == FEATURED_FRONT_LAYOUT_VERSION then
        EnsureFeaturedFrontToggle(mainFrame)
        return featuredFrontFrame
    end
    if featuredFrontFrame then
        featuredFrontFrame:Hide()
        featuredFrontFrame = nil
    end

    local toggle = EnsureFeaturedFrontToggle(mainFrame)

    local f = CreateFrame("Frame", "OverlordFeaturedFrontDialog", mainFrame, "BackdropTemplate")
    f._layoutVersion = FEATURED_FRONT_LAYOUT_VERSION
    f:SetWidth(FEATURED_FRONT_PANEL_WIDTH)
    f:SetFrameLevel(mainFrame:GetFrameLevel() + 8)
    f:EnableMouse(true)
    f:Hide()
    Overlord.UI.ApplyWoodDialogBackdrop(f)

    -- Blason a ailes Alliance/Horde, deborde au-dessus du cadre.
    f.factionHeader = f:CreateTexture(nil, "ARTWORK")
    f.factionHeader:SetDrawLayer("ARTWORK", 3)

    -- Ruban titre (parchemin + cornes), fixe sous le blason.
    f.titleLeft = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.titleLeft:SetPoint("TOPLEFT", f, "TOPLEFT", 22, FEATURED_FRONT_TOP_Y)
    f.titleRight = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.titleRight:SetPoint("TOPRIGHT", f, "TOPRIGHT", -22, FEATURED_FRONT_TOP_Y)
    f.titleMiddle = f:CreateTexture(nil, "ARTWORK", nil, 0)
    f.titleMiddle:SetHorizTile(true)
    f.titleMiddle:SetPoint("TOPLEFT", f.titleLeft, "TOPRIGHT", -60, 0)
    f.titleMiddle:SetPoint("BOTTOMRIGHT", f.titleRight, "BOTTOMLEFT", 60, 0)

    f.titleFs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.titleFs:SetPoint("TOP", f.titleMiddle, "TOP", 0, 0)
    f.titleFs:SetPoint("BOTTOM", f.titleMiddle, "BOTTOM", 0, 0)
    f.titleFs:SetPoint("LEFT", f, "LEFT", 22, 0)
    f.titleFs:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    f.titleFs:SetJustifyH("CENTER")
    f.titleFs:SetJustifyV("MIDDLE")
    f.titleFs:SetShadowOffset(0, 0)
    f.titleFs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    f.titleFs:SetText(L.FEATURED_FRONT_TITLE or "Featured Front")

    -- Nom de la zone : centre horizontal du panneau, sous le ruban.
    f.frontNameFs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.frontNameFs:SetPoint("TOP", f.titleMiddle, "BOTTOM", 0, -16)
    f.frontNameFs:SetPoint("LEFT", f, "LEFT", 22, 0)
    f.frontNameFs:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    f.frontNameFs:SetJustifyH("CENTER")
    f.frontNameFs:SetWordWrap(false)
    f.frontNameFs:SetMaxLines(1)
    f.frontNameFs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    -- Vignette hauteur fixe (jamais etiree), sous le nom de zone.
    f.artFrame = Overlord.UI.CreateWC3SubPanel(f, FEATURED_FRONT_PANEL_WIDTH - 48, FEATURED_FRONT_ART_HEIGHT)
    f.artFrame:SetPoint("TOP", f.frontNameFs, "BOTTOM", 0, -12)
    f.artFrame:SetPoint("LEFT", f, "LEFT", 24, 0)
    f.artFrame:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    f.vignette = f.artFrame:CreateTexture(nil, "ARTWORK")
    f.vignette:SetPoint("CENTER", f.artFrame, "CENTER", 0, 0)
    f.vignette:SetSize(FEATURED_FRONT_PANEL_WIDTH - 56, FEATURED_FRONT_ART_HEIGHT - 8)

    f.bodyFs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.bodyFs:SetPoint("TOPLEFT", f.artFrame, "BOTTOMLEFT", 4, -16)
    f.bodyFs:SetPoint("TOPRIGHT", f.artFrame, "BOTTOMRIGHT", -4, -16)
    f.bodyFs:SetJustifyH("CENTER")
    f.bodyFs:SetJustifyV("TOP")
    f.bodyFs:SetWordWrap(true)

    -- Bloc activite recente : hauteur recalee sur la grille d'actions (ApplyFeaturedFrontActivityLayout).
    local actionsCard = Overlord.UI.actionsCard
    local activityPanelHeight = actionsCard and actionsCard:GetHeight() or 169
    f.activityPanel = Overlord.UI.CreateWC3SubPanel(
        f, FEATURED_FRONT_PANEL_WIDTH - 48, activityPanelHeight)
    f.activityPanel:SetPoint("TOP", actionsCard, "TOP", 0, 0)
    f.activityPanel:SetPoint("LEFT", f, "LEFT", 24, 0)
    f.activityPanel:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.activityPanel:Hide()

    f.activityScroll, f.activityRowsContent = Overlord.UI:CreateCleanScroll(
        f.activityPanel,
        FEATURED_FRONT_PANEL_WIDTH - 56,
        math.max(1, activityPanelHeight
            - FEATURED_FRONT_ACTIVITY_TITLE_H - FEATURED_FRONT_ACTIVITY_BOTTOM_PAD),
        FEATURED_FRONT_ACTIVITY_ROW_H + FEATURED_FRONT_ACTIVITY_ROW_GAP,
        false)
    f.activityScroll:ClearAllPoints()
    f.activityScroll:SetPoint(
        "TOPLEFT", f.activityPanel, "TOPLEFT", 0, -FEATURED_FRONT_ACTIVITY_TITLE_H)
    f.activityScroll:SetPoint(
        "BOTTOMRIGHT", f.activityPanel, "BOTTOMRIGHT", -8, FEATURED_FRONT_ACTIVITY_BOTTOM_PAD)
    f.activityScroll:Hide()

    f.bountyBtn = Overlord.UI.CreateWC3Button(
        f,
        FEATURED_FRONT_PANEL_WIDTH - 48,
        30,
        L.FEATURED_FRONT_BOUNTIES_ACTIVE,
        function()
            if Overlord.ManualBountyUI and Overlord.ManualBountyUI.Show then
                Overlord.ManualBountyUI:Show()
            end
        end,
        "Interface\\Icons\\INV_Misc_Coin_01",
        { gold = GOLD }
    )
    f.bountyBtn:SetPoint("TOP", f.activityPanel, "BOTTOM", 0, -10)
    Overlord.UI.SetWC3ButtonActive(f.bountyBtn, true, { gold = GOLD })
    f.bountyBtn:Hide()

    f.activityTitleFs = f.activityPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.activityTitleFs:SetPoint("TOP", f.activityPanel, "TOP", 0, -8)
    f.activityTitleFs:SetPoint("BOTTOM", f.activityPanel, "TOP", 0, -FEATURED_FRONT_ACTIVITY_TITLE_H)
    f.activityTitleFs:SetPoint("LEFT", f.activityPanel, "LEFT", 10, 0)
    f.activityTitleFs:SetPoint("RIGHT", f.activityPanel, "RIGHT", -10, 0)
    f.activityTitleFs:SetJustifyH("CENTER")
    f.activityTitleFs:SetJustifyV("MIDDLE")
    f.activityTitleFs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    -- L'icone est separee du texte afin de ne pas decaler le titre visuellement.
    f.activityTitleIcon = f.activityPanel:CreateTexture(nil, "OVERLAY")
    f.activityTitleIcon:SetSize(14, 14)
    f.activityTitleIcon:SetPoint("TOPLEFT", f.activityPanel, "TOPLEFT", 10, -11)
    if f.activityTitleIcon.SetAtlas then
        pcall(f.activityTitleIcon.SetAtlas, f.activityTitleIcon, FEATURED_FRONT_ACTIVITY_TITLE_ICON, false)
    end

    f.activityRows = {}
    local rowTop = 0
    for i = 1, FEATURED_FRONT_ACTIVITY_MAX_ROWS do
        local row = CreateFeaturedFrontActivityRow(f.activityRowsContent)
        row:SetPoint("TOPLEFT", f.activityRowsContent, "TOPLEFT", 0,
            rowTop - (i - 1) * (FEATURED_FRONT_ACTIVITY_ROW_H + FEATURED_FRONT_ACTIVITY_ROW_GAP))
        row:SetPoint("TOPRIGHT", f.activityRowsContent, "TOPRIGHT", 0,
            rowTop - (i - 1) * (FEATURED_FRONT_ACTIVITY_ROW_H + FEATURED_FRONT_ACTIVITY_ROW_GAP))
        f.activityRows[i] = row
    end

    f.activityEmptyFs = f.activityPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.activityEmptyFs:SetWordWrap(true)
    f.activityEmptyFs:SetMaxLines(3)
    f.activityEmptyFs:SetTextColor(0.55, 0.55, 0.55)
    f.activityEmptyFs:SetShadowOffset(0, 0)
    f.activityEmptyFs:Hide()

    -- Le volet lateral possede l'activite et son ticker : le replier arrete tout
    -- travail periodique, puis la reouverture repeint immediatement la carte.
    f:SetScript("OnShow", function(self)
        StartFeaturedFrontActivityTicker()
        ApplyFeaturedFrontActivity(self)
    end)
    f:SetScript("OnHide", function()
        StopFeaturedFrontActivityTicker()
    end)

    featuredFrontFrame = f
    SyncFeaturedFrontPanelAnchors()
    SetFeaturedFrontExpanded(IsFeaturedFrontExpanded(), false)
    return f
end

ApplyFeaturedFrontContent = function(f, frontId)
    if not f or not frontId or not Overlord.Fronts then return false end
    local art = Overlord.Fronts:GetFeaturedFrontArtPath(frontId)
    local name = Overlord.Fronts:GetFeaturedFrontDisplayName(frontId)
    if not art or not name then return false end
    f.vignette:SetTexture(art)
    f.vignette:SetTexCoord(0.04, 0.96, 0.10, 0.82)
    f.frontNameFs:SetText(name)
    lastFeaturedFrontLoadedId = frontId
    f.bodyFs:SetText(L.FEATURED_FRONT_BODY or "")
    ApplyFeaturedFrontActivity(f)
    return true
end

LoadFeaturedFrontContent = function()
    if not Overlord.Fronts or not Overlord.Fronts.GetFeaturedFrontId then return false end
    local frontId = Overlord.Fronts:GetFeaturedFrontId()
    if not frontId then return false end
    if not Overlord.Fronts:GetFeaturedFrontArtPath(frontId) then return false end
    if not Overlord.Fronts:GetFeaturedFrontDisplayName(frontId) then return false end
    local f = EnsureFeaturedFrontFrame()
    if not f then return false end
    local faction = Overlord.PlayerFaction or UnitFactionGroup("player")
    ApplyFeaturedFrontHeader(f, faction)
    ApplyFeaturedFrontTitleRibbon(f, faction)
    return ApplyFeaturedFrontContent(f, frontId)
end

ToggleFeaturedFrontExpanded = function()
    local expanded = not (featuredFrontFrame and featuredFrontFrame:IsShown())
    if expanded and not LoadFeaturedFrontContent() then
        return
    end
    SetFeaturedFrontExpanded(expanded, true)
end

function Overlord.Popups:ShowFeaturedFrontDialog(forcePreview)
    if not forcePreview and self:HasShownFeaturedFrontToday() then return false end
    if not LoadFeaturedFrontContent() then return false end
    if Overlord.UI then
        Overlord.UI:Show()
    end
    local f = featuredFrontFrame
    if not f then return false end
    f._previewOnly = forcePreview and true or nil
    SetFeaturedFrontExpanded(true, true)
    if featuredFrontToggleBtn then featuredFrontToggleBtn:Show() end
    if not forcePreview then
        self:MarkFeaturedFrontShownToday()
    end
    return true
end

function Overlord.Popups:PreviewFeaturedFront()
    if not Overlord.IsInitialized then return end
    if OverlordDB then
        OverlordDB.config = OverlordDB.config or {}
        OverlordDB.config.popupsDailyShown = OverlordDB.config.popupsDailyShown or {}
        OverlordDB.config.popupsDailyShown[FEATURED_FRONT_POPUP_ID] = nil
    end
    self:ShowFeaturedFrontDialog(true)
end

function Overlord.Popups:ToggleFeaturedFrontPanel()
    local mainFrame = GetMainPanelFrame()
    if mainFrame and mainFrame:IsShown() then
        ToggleFeaturedFrontExpanded()
    elseif Overlord.UI then
        Overlord.UI:Show()
        ToggleFeaturedFrontExpanded()
    end
end

-- Onglet fleche sur le bord gauche du panneau principal ; restaure l'etat replie/deplie.
function Overlord.Popups:SyncFeaturedFrontDock()
    if not Overlord.Fronts or not Overlord.Fronts.GetFeaturedFrontId then return end
    if Overlord.UI and Overlord.UI.Initialize then
        Overlord.UI:Initialize()
    end
    local mainFrame = GetMainPanelFrame()
    if not mainFrame then return end
    EnsureFeaturedFrontToggle(mainFrame)
    if featuredFrontToggleBtn then
        featuredFrontToggleBtn:Show()
    end
    if IsFeaturedFrontExpanded() then
        local frontId = Overlord.Fronts:GetFeaturedFrontId()
        local needsLoad = not featuredFrontFrame
            or not featuredFrontFrame:IsShown()
            or lastFeaturedFrontLoadedId ~= frontId
        if needsLoad then
            if LoadFeaturedFrontContent() then
                SetFeaturedFrontExpanded(true, false)
            end
        else
            SetFeaturedFrontExpanded(true, false)
        end
    elseif featuredFrontFrame then
        SetFeaturedFrontExpanded(false, false)
    else
        SyncFeaturedFrontPanelAnchors()
        ApplyFeaturedFrontToggleArrow(false)
    end
end

function Overlord.Popups:TryShowFeaturedFrontOnLogin()
    if Overlord.InstanceSuspended or not Overlord.IsInitialized then return false end
    if dialogFrame and dialogFrame:IsShown() then return false end
    MigrateLegacyPopupFlags()
    if self:HasShownFeaturedFrontToday() then return false end
    return self:ShowFeaturedFrontDialog(false)
end

-- ---------------------------------------------------------------------------
-- Annonces enregistrees (ajouter ici les futurs popups one-shot)
-- ---------------------------------------------------------------------------

-- Une fois par compte : jamais vu (nouvelle install ou veterane sans popupsSeen).
Overlord.Popups:RegisterLoginAnnouncement({
    id = WELCOME_POPUP_ID,
    title = function()
        return GetWelcomePopupTitle()
    end,
    body = function()
        return GetWelcomePopupBody()
    end,
    opts = { showBookIcon = true, showGuideButton = true, playFactionHorn = true },
})

-- Annonce one-shot Forever : fronts v1, hors contenu Retail.
Overlord.Popups:RegisterLoginAnnouncement({
    id = FOREVER_LAUNCH_POPUP_ID,
    title = function()
        return L.POPUP_UPDATE_FOREVER_1000_TITLE
    end,
    body = function()
        return L.POPUP_UPDATE_FOREVER_1000_BODY
    end,
    opts = { showFactionSeal = true, addonSoundKey = "faction_call", dialogLayout = "patchNotes" },
})

local function BuildGuildKeepReminderBody()
    if not Overlord.GuildKeep or not Overlord.GuildKeep.GetGuildHeldSiteForPlayer then return nil end
    local st, site = Overlord.GuildKeep:GetGuildHeldSiteForPlayer()
    if not st or not site then return nil end
    local keepName = Overlord.GuildKeep.GetDisplayName
        and Overlord.GuildKeep:GetDisplayName(site) or ((L and L.GUILD_KEEP_SHORT) or "Guild Keep")
    local siegeStart = (Overlord.GuildKeep.GetSiegeWindowStartLabel
        and Overlord.GuildKeep:GetSiegeWindowStartLabel()) or ""
    return string.format(L.POPUP_GUILD_KEEP_REMINDER_BODY or "", keepName, siegeStart)
end

function Overlord.Popups:TryShowGuildKeepSiegeReminder()
    if Overlord.InstanceSuspended or not Overlord.IsInitialized then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    if dialogFrame and dialogFrame:IsShown() then return false end
    local now = GetTime and GetTime() or 0
    if now > 0 and now < nextGuildKeepReminderCheckAt then return false end
    if now > 0 then nextGuildKeepReminderCheckAt = now + GUILD_KEEP_REMINDER_RECHECK_SEC end
    MigrateLegacyPopupFlags()
    if self:HasShownToday(GUILD_KEEP_REMINDER_POPUP_ID) then return false end
    if not IsGuildKeepReminderWindow() then return false end
    if not IsPlayerOnSiegeReminderMap() then return false end
    local body = BuildGuildKeepReminderBody()
    if not body then return false end
    self:ShowDialog(
        GUILD_KEEP_REMINDER_POPUP_ID,
        L.POPUP_GUILD_KEEP_REMINDER_TITLE,
        body,
        "daily",
        { showFactionSeal = true, addonSoundKey = "faction_call", okText = L.POPUP_FACTION_CALL_OK }
    )
    return true
end

Overlord.Popups:RegisterLoginAnnouncement({
    id = "daily_battle_report",
    daily = true,
    opts = { showFactionSeal = true },
    when = function()
        if not IsPlayerOnActiveFront() then return false end
        return BuildBattleReportBody() ~= nil
    end,
    title = function()
        return L.POPUP_BATTLE_REPORT_TITLE
    end,
    body = BuildBattleReportBody,
})
