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
local FOREVER_LAUNCH_POPUP_ID = "forever_launch_1_0_0"
local FOREVER_NETWORK_NOTICE_ID = "forever_community_bnet_notice_1_0_17"
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
local FEATURED_FRONT_LAYOUT_VERSION = 60
local FEATURED_FRONT_ACTIVITY_ROW_H = 18
local FEATURED_FRONT_ACTIVITY_ROW_GAP = 3
local FEATURED_FRONT_ACTIVITY_MAX_ROWS = 8
local FEATURED_FRONT_ACTIVITY_VISIBLE_ROWS = 5
local FEATURED_FRONT_ACTIVITY_TITLE_H = 28
local FEATURED_FRONT_ACTIVITY_BOTTOM_PAD = 8
local FEATURED_FRONT_BODY_ACTIVITY_GAP = 10
local NEXT_OBJECTIVE_DETAILS_GAP = 8
local FEATURED_FRONT_BOTTOM_PAD = 16
local FEATURED_FRONT_ACTIVITY_RAIL_W = 24
local FEATURED_FRONT_FOOTER_GAP = 10
local FEATURED_FRONT_ACTIONS_GAP = 8
local FEATURED_FRONT_ACTIVITY_ICON = 14
local FEATURED_FRONT_ACTIVITY_STAR = 10
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
local featuredFrontFrame = nil
local featuredFrontToggleBtn = nil
local pendingSeenId = nil
local pendingMarkMode = nil -- "once" | "daily"
local pendingLoginChain = false
local loginAnnouncements = {}

-- La beta peut ecrire OverlordDB sans le recharger. Sans etat precedent fiable,
-- les annonces automatiques reviendraient a chaque connexion ou /reload.
local function CanAutoShowPersistentPopup()
    return Overlord.SavedVariablesLoadedAtLogin ~= false
end

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
function Overlord.Popups:GetCalendarDayKey(id)
    return date("%Y%m%d", time())
end

function Overlord.Popups:HasShownToday(id)
    if not id or not OverlordDB or not OverlordDB.config then return true end
    local daily = OverlordDB.config.popupsDailyShown
    return daily and daily[id] == self:GetCalendarDayKey(id)
end

function Overlord.Popups:MarkShownToday(id)
    if not id or not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.popupsDailyShown = OverlordDB.config.popupsDailyShown or {}
    OverlordDB.config.popupsDailyShown[id] = self:GetCalendarDayKey(id)
end

function Overlord.Popups:HasShownFeaturedFrontToday()
    if not FEATURED_FRONT_POPUP_ID or not OverlordDB or not OverlordDB.config then return true end
    local dayKey = date("%Y%m%d", time())
    local daily = OverlordDB.config.popupsDailyShown
    return daily and daily[FEATURED_FRONT_POPUP_ID] == dayKey
end

function Overlord.Popups:MarkFeaturedFrontShownToday()
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.popupsDailyShown = OverlordDB.config.popupsDailyShown or {}
    OverlordDB.config.popupsDailyShown[FEATURED_FRONT_POPUP_ID] =
        date("%Y%m%d", time())
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
        if f.warningIcon then f.warningIcon:Hide() end
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
    elseif mode == "warning" then
        f:SetSize(420, 200)
        f.bodyPanel:SetSize(388, 96)
        if f.bookIcon then f.bookIcon:Hide() end
        if f.factionSeal then f.factionSeal:Hide() end
        if f.guideBtn then f.guideBtn:Hide() end
        f.warningIcon:Show()
        f.bodyFs:ClearAllPoints()
        f.bodyFs:SetPoint("TOPLEFT", f.bodyPanel, "TOPLEFT", 68, -8)
        f.bodyFs:SetPoint("BOTTOMRIGHT", f.bodyPanel, "BOTTOMRIGHT", -14, 8)
        f.bodyFs:SetJustifyV("MIDDLE")
        f.okBtn:ClearAllPoints()
        f.okBtn:SetPoint("TOP", f.bodyPanel, "BOTTOM", 0, -10)
    elseif mode == "factionSeal" then
        if f.warningIcon then f.warningIcon:Hide() end
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
        if f.warningIcon then f.warningIcon:Hide() end
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
        if f.warningIcon then f.warningIcon:Hide() end
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
    if Overlord.UI.AttachOpenFade then Overlord.UI.AttachOpenFade(f) end
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

    -- No full-screen click blocker any more: like Blizzard windows, the dialog
    -- leaves the world usable (a mouse-enabled overlay over UIParent stopped
    -- right-drag camera look while the daily Battle Report was open). It still
    -- closes with its button, the cross or Escape.

    f:SetScript("OnShow", function(self)
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

    f.warningIcon = f.bodyPanel:CreateTexture(nil, "ARTWORK")
    f.warningIcon:SetSize(42, 42)
    f.warningIcon:SetPoint("LEFT", f.bodyPanel, "LEFT", 14, 0)
    f.warningIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    f.warningIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.warningIcon:Hide()

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
local quickGuidePage = 1
local GUIDE_PAGE_COUNT = 3

local function HideQuickGuide()
    if quickGuideFrame then quickGuideFrame:Hide() end
end

local GUIDE_MINE_ATLAS = "Warfronts-FieldMapIcons-Empty-Mine"

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
    local body = string.format(L.FORTRESS_OUTPOST_GUIDE_BODY, iconLine, capMin)
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
        return JoinGuideSections(
            FormatGuideSection(L.GUIDE_SECTION_CONTEST, L.GUIDE_CONTEST_BODY),
            FormatGuideSection(L.GUIDE_SECTION_GOLD, goldBody),
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

-- Corps du guide mis en cache par page (evite parcours MineDatabase a chaque flip).
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
    if Overlord.UI.AttachOpenFade then Overlord.UI.AttachOpenFade(f) end
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

    -- No full-screen click-to-close overlay (it blocked camera look); the guide
    -- closes with its cross or Escape, like Blizzard windows.

    f:SetScript("OnShow", function(self)
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
    if opts.showWarningIcon then
        ApplyDialogLayout("warning")
        dialogFrame.bodyFs:SetJustifyH("LEFT")
    elseif opts.showBookIcon or opts.showGuideButton then
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
    -- Optional auto-close (daily Battle Report): fades out after opts.autoCloseSec,
    -- postponed while the mouse is over the window so a player can still read it.
    -- A newer dialog bumps the token, so an older timer never closes it.
    local token = (dialogFrame._olAutoCloseToken or 0) + 1
    dialogFrame._olAutoCloseToken = token
    if dialogFrame._olFadeOut then dialogFrame._olFadeOut:Stop() end
    dialogFrame:SetAlpha(1)
    if opts.autoCloseSec and C_Timer and C_Timer.After then
        local function check()
            local f = dialogFrame
            if not f or not f:IsShown() or f._olAutoCloseToken ~= token then return end
            if f.IsMouseOver and f:IsMouseOver() then C_Timer.After(1, check); return end
            if not f._olFadeOut and f.CreateAnimationGroup then
                local group = f:CreateAnimationGroup()
                local fade = group:CreateAnimation("Alpha")
                fade:SetFromAlpha(1)
                fade:SetToAlpha(0)
                fade:SetDuration(0.4)
                group:SetScript("OnFinished", function()
                    f:SetAlpha(1)
                    -- Only the fade of the dialog still on screen may close it.
                    if f._olFadeToken == f._olAutoCloseToken then HideDialog() end
                end)
                f._olFadeOut = group
            end
            f._olFadeToken = token
            if f._olFadeOut then f._olFadeOut:Play() else HideDialog() end
        end
        C_Timer.After(opts.autoCloseSec, check)
    end
    dialogFrame:Show()
end

-- Enregistre une annonce login : { id, title, body, when? }
function Overlord.Popups:RegisterLoginAnnouncement(entry)
    if not entry or not entry.id then return end
    loginAnnouncements[#loginAnnouncements + 1] = entry
end

function Overlord.Popups:TryShowNextLoginAnnouncement()
    if not CanAutoShowPersistentPopup() then return false end
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


-- Joueur sur une carte de front actif (pas en capitale / hors zone de guerre).
local function IsPlayerOnActiveFront()
    if Overlord.InActiveFront then return true end
    if Overlord.IsPlayerInActiveFront then
        return Overlord:IsPlayerInActiveFront()
    end
    return false
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

function Overlord.Popups:TryShowNextDailyAnnouncement(forcePreview)
    if not forcePreview and not CanAutoShowPersistentPopup() then return false end
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
    if self:TryShowNextDailyAnnouncement(true) then return end
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
-- Prochain objectif : extension laterale du panneau principal (onglet fleche).
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

local function GetObjectiveFrontId()
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then return nil end
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    return front and front.id
end

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
        featuredFrontFrame:SetPoint("TOPRIGHT", mainFrame, "TOPLEFT", FEATURED_FRONT_SPINE_OVERLAP, 0)
        featuredFrontFrame:SetHeight(math.max(mainFrame:GetHeight() or 0, featuredFrontFrame._objectiveMinimumHeight or 0))
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
        Overlord.Popups:RefreshNextObjective()
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

-- Taille du combat par tranches : 5+, 10+, 20+, 30+... (sous 5 kills, la recence).
local FRONT_FIGHT_BRACKETS = { 500, 300, 200, 150, 100, 75, 50, 40, 30, 20, 10, 5 }
local function GetFrontFightBracket(kills)
    kills = tonumber(kills) or 0
    for _, floor in ipairs(FRONT_FIGHT_BRACKETS) do
        if kills >= floor then return floor end
    end
    return nil
end

local function FormatFrontActivityAge(active, ageSeconds, kills)
    if not active then return L.FEATURED_FRONT_ACTIVITY_DASH or "..." end
    local bracket = GetFrontFightBracket(kills)
    if bracket then
        return string.format(L.FEATURED_FRONT_ACTIVITY_KILLS or "%d+ kills", bracket)
    end
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
    row.content:SetHeight(FEATURED_FRONT_ACTIVITY_ROW_H)
    row.content:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.content:SetPoint("RIGHT", row, "RIGHT", -4, 0)

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
    row.valueFs:SetWidth(92)
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

local function SetFeaturedFrontActivityRow(row, frontId, label, active, ageSeconds, isFeatured, kills)
    if not row then return end
    row:Show()
    local ageText = FormatFrontActivityAge(active, ageSeconds, kills)
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
    local bracket = active and GetFrontFightBracket(kills)
    if bracket then
        -- Plus le combat est gros, plus c'est rouge.
        if bracket >= 50 then br, bg, bb = 1, 0.25, 0.25
        elseif bracket >= 20 then br, bg, bb = 1, 0.5, 0.15
        else br, bg, bb = 1, 0.82, 0.35 end
    end
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

local function ComputeFeaturedFrontActivityHeight(rowCount)
    local contentH = FEATURED_FRONT_ACTIVITY_TITLE_H
    if rowCount > 0 then
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

local function GetFeaturedFrontActivityMatchHeight(f, footerVisible)
    local actionsCard = GetFeaturedFrontActionsCard()
    if not actionsCard then return nil end
    local actionsH = actionsCard:GetHeight()
    if not actionsH or actionsH <= 0 then return nil end

    local matchH = actionsH
    local azFrame = GetFeaturedFrontActiveZoneFrame()
    if azFrame then
        matchH = (azFrame:GetHeight() or 64) + FEATURED_FRONT_ACTIONS_GAP + actionsH
    end

    if footerVisible and f and f.activityFooter then
        local footerH = f.activityFooter:GetHeight() or 30
        return math.max(0, matchH - footerH - FEATURED_FRONT_FOOTER_GAP)
    end
    return matchH
end

-- La carte garde la hauteur historique de cinq lignes. Les fronts supplementaires
-- restent accessibles dans un vrai viewport, sans pousser le bouton Contrats sous le cadre.
local function LayoutFeaturedFrontActivityScroll(f, rowCount)
    if not f or not f.activityScroll or not f.activityRowsContent then return end
    rowCount = math.max(0, math.floor(tonumber(rowCount) or 0))
    local showRows = rowCount > 0
    f.activityScroll:SetShown(showRows)
    if not showRows then
        f.activityScroll._overlordHasOverflow = false
        f.activityScroll._overlordContentHeight = 1
        f.activityRowsContent:SetHeight(1)
        f.activityScroll:SetVerticalScroll(0)
        if f.activityScroll.RefreshCleanRail then f.activityScroll:RefreshCleanRail() end
        return
    end

    local viewportH = math.max(1, (f.activityPanel:GetHeight() or 1)
        - FEATURED_FRONT_ACTIVITY_TITLE_H - FEATURED_FRONT_ACTIVITY_BOTTOM_PAD)
    local rowStep = FEATURED_FRONT_ACTIVITY_ROW_H + FEATURED_FRONT_ACTIVITY_ROW_GAP
    local rowsH = math.max(1, rowCount * rowStep - FEATURED_FRONT_ACTIVITY_ROW_GAP)
    local contentH = math.max(viewportH, rowsH)
    f.activityRowsContent:SetWidth(math.max(1, f.activityScroll:GetWidth() or 1))
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

-- The objective dock keeps its normal picture and five-row activity viewport,
-- even on two-point fronts whose main panel is shorter. Grow the dock instead
-- of squeezing the title, scrollbar and coins into a single-row card.
local function AnchorFeaturedFrontActivityBlock(f, contentH, footerVisible)
    local top = f:GetTop()
    local artTop = f.artFrame and f.artFrame:GetTop()
    if not top or not artTop or not f:IsShown() then
        f._activityBodyCollisionPending = true
        return
    end
    f._activityBodyCollisionPending = nil
    local bodyH = math.ceil(f.bodyFs:GetStringHeight() or 0)
    local detailsH = f.objectiveDetailsFs and f.objectiveDetailsFs:IsShown()
        and (NEXT_OBJECTIVE_DETAILS_GAP + math.ceil(f.objectiveDetailsFs:GetStringHeight() or 0)) or 0
    local footerH = footerVisible and f.activityFooter and f.activityFooter:GetHeight() or 0
    local footerSpace = footerH > 0 and (footerH + FEATURED_FRONT_FOOTER_GAP) or 0
    local fixedH = top - artTop + 16 + bodyH + detailsH
        + FEATURED_FRONT_BODY_ACTIVITY_GAP + footerSpace + FEATURED_FRONT_BOTTOM_PAD
    local main = GetMainPanelFrame()
    local requestedH = main and main:GetHeight() or f:GetHeight()
    -- Le dock garde la hauteur du principal (bords bas alignes) : la liste
    -- d'activite montre autant de lignes que la place le permet, deux au moins
    -- (elle defile). 1.4.2 : le principal a perdu le bandeau Communaute (42 px)
    -- et un minimum fixe de cinq lignes faisait depasser le dock en bas.
    local rows = FEATURED_FRONT_ACTIVITY_VISIBLE_ROWS
    local room = (requestedH or 0) - fixedH - FEATURED_FRONT_ART_HEIGHT
    while rows > 2 and ComputeFeaturedFrontActivityHeight(rows) > room do rows = rows - 1 end
    local minActivity = ComputeFeaturedFrontActivityHeight(rows)
    f._objectiveMinimumHeight = math.ceil(fixedH + FEATURED_FRONT_ART_HEIGHT + minActivity)
    local height = math.max(requestedH or 0, f._objectiveMinimumHeight)
    if f:GetHeight() ~= height then f:SetHeight(height) end
    local artH = FEATURED_FRONT_ART_HEIGHT
    if f.artFrame:GetHeight() ~= artH then
        f.artFrame:SetHeight(artH)
        f.vignette:SetHeight(artH - 8)
    end
    f.vignette:SetTexCoord(0.04, 0.96, 0.10, 0.82)
    local activityH = math.max(minActivity, math.min(contentH, height - fixedH - artH))
    f.activityPanel:ClearAllPoints()
    f.activityPanel:SetWidth(FEATURED_FRONT_PANEL_WIDTH - 48)
    f.activityPanel:SetPoint("BOTTOM", f, "BOTTOM", 0, FEATURED_FRONT_BOTTOM_PAD + footerSpace)
    f.activityPanel:SetHeight(activityH)
    f._activityResolvedHeight = activityH
    if f.activityFooter then
        f.activityFooter:SetShown(footerVisible)
        f.activityFooter:ClearAllPoints()
        f.activityFooter:SetWidth(FEATURED_FRONT_PANEL_WIDTH - 48)
        f.activityFooter:SetPoint("BOTTOM", f, "BOTTOM", 0, FEATURED_FRONT_BOTTOM_PAD)
    end
end

local function ApplyFeaturedFrontActivityLayout(f, rowCount)
    if not f or not f.activityPanel then return end
    rowCount = rowCount or f._activityRowCount or 0
    f._activityRowCount = rowCount

    local actionsCard = Overlord.UI and Overlord.UI.actionsCard
    if not actionsCard then return end

    local footerVisible = f.coinsRow ~= nil
    local minimumContentH = ComputeFeaturedFrontActivityHeight(rowCount)
    local contentH = minimumContentH
    local matchH = GetFeaturedFrontActivityMatchHeight(f, footerVisible)
    if matchH then
        contentH = math.max(contentH, matchH)
    end

    local bodyTextH = f.bodyFs and math.ceil(f.bodyFs:GetStringHeight() or 0) or 0
    if f.objectiveDetailsFs and f.objectiveDetailsFs:IsShown() then
        bodyTextH = bodyTextH + NEXT_OBJECTIVE_DETAILS_GAP
            + math.ceil(f.objectiveDetailsFs:GetStringHeight() or 0)
    end
    local layoutKey = rowCount .. "|" .. (footerVisible and 1 or 0) .. "|" .. contentH .. "|" .. bodyTextH
        .. "|" .. (f:GetHeight() or 0) .. "|" .. (GetFeaturedFrontActiveZoneFrame() and 1 or 0)
        .. "|" .. (GetMainPanelFrame() and GetMainPanelFrame():GetHeight() or 0)
    if f._activityLayoutKey == layoutKey and not f._activityBodyCollisionPending then return end
    f._activityLayoutKey = layoutKey

    AnchorFeaturedFrontActivityBlock(f, contentH, footerVisible)
    LayoutFeaturedFrontActivityScroll(f, rowCount)
end

function Overlord.Popups:RefreshFeaturedFrontCoins(panel)
    local row = panel or (featuredFrontFrame and featuredFrontFrame.coinsRow)
    local res = Overlord.Ressources
    if not row or not row:IsVisible() or not res or not res.GetGoldActionState then return end
    local g, maximum, cost, attackActive, reinforceActive = res:GetGoldActionState()
    if row._olGold == g and row._olMax == maximum and row._olCost == cost
        and row._olAttack == attackActive and row._olReinforce == reinforceActive then return end
    row._olGold, row._olMax, row._olCost = g, maximum, cost
    row._olAttack, row._olReinforce = attackActive, reinforceActive
    row.coinText:SetText("|TInterface\\MoneyFrame\\UI-GoldIcon:16:16:0:0|t  "
        .. string.format(L.GOLD_COUNTER or "Coins: %d / %d", g, maximum))
    for _, btn in ipairs(row.buttons) do
        local active = btn.isAttack and attackActive or (not btn.isAttack and reinforceActive)
        local available = not active and g >= cost
        btn._olBonusActive, btn._olCanSpend, btn._olCost = active, available, cost
        local r, green, b = GOLD[1], GOLD[2], GOLD[3]
        if active then r, green, b = 0.4, 0.9, 0.5
        elseif not available then r, green, b = 0.55, 0.55, 0.58 end
        btn:SetBackdropBorderColor(r, green, b, active and 0.85 or 0.6)
        btn.label:SetTextColor(r, green, b)
        local status = active and "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t"
            or (cost .. " |TInterface\\MoneyFrame\\UI-GoldIcon:12:12|t")
        btn.label:SetText(btn.actionLabel .. "  " .. status)
    end
end

-- A dedicated footer keeps the balance clear of the two equally sized actions.
-- All refreshes are event-driven; hidden panels catch up through OnShow.
function Overlord.Popups:CreateFeaturedFrontCoinsPanel(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(FEATURED_FRONT_PANEL_WIDTH - 48, 64)
    row.coinText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.coinText:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.coinText:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.coinText:SetHeight(18)
    row.coinText:SetJustifyH("CENTER")
    row.coinText:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    row.buttons = {}
    for i = 1, 2 do
        local isAttack = i == 2
        local actionLabel = isAttack and (L.GOLD_REINFORCE or "Attack")
            or (L.GOLD_BARRICADE or "Reinforce")
        local btn = Overlord.UI.CreateWC3Button(row, 122, 34,
            actionLabel, nil, nil, { gold = GOLD })
        btn.isAttack = isAttack
        btn.actionLabel = actionLabel
        btn:SetPoint(isAttack and "BOTTOMRIGHT" or "BOTTOMLEFT", row,
            isAttack and "BOTTOMRIGHT" or "BOTTOMLEFT", 0, 0)
        btn.label:ClearAllPoints()
        btn.label:SetPoint("LEFT", btn, "LEFT", 6, 0)
        btn.label:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
        btn.label:SetHeight(20)
        btn.label:SetFontObject("GameFontNormalSmall")
        btn.label:SetWordWrap(false)
        btn.label:SetJustifyH("CENTER")
        btn.label:SetJustifyV("MIDDLE")
        btn:SetScript("OnClick", function(self)
            if not self._olCanSpend then return end
            local res = Overlord.Ressources
            if self.isAttack then res:SpendReinforce() else res:SpendBarricade() end
            Overlord.Popups:RefreshFeaturedFrontCoins(row)
            if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(self.isAttack and (L.GOLD_REINFORCE or "Attack")
                or (L.GOLD_BARRICADE or "Reinforce"), GOLD[1], GOLD[2], GOLD[3])
            local tip = self.isAttack and L.GOLD_REINFORCE_TIP or L.GOLD_BARRICADE_TIP
            if tip then GameTooltip:AddLine(tip, 1, 1, 1, true) end
            if self._olBonusActive then
                local ready = self.isAttack and L.GOLD_REINFORCE_ACTIVE or L.GOLD_BARRICADE_ACTIVE
                GameTooltip:AddLine(ready or L.GOLD_BONUS_READY or "Ready", 0.4, 0.9, 0.5, true)
            elseif not self._olCanSpend then
                GameTooltip:AddLine(string.format(L.GOLD_NOT_ENOUGH or "Not enough coins (%d).",
                    self._olCost or 25), 1, 0.45, 0.35, true)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Preserve the status colors instead of the generic button's mouse chrome.
        btn:SetScript("OnMouseDown", nil)
        btn:SetScript("OnMouseUp", nil)
        row.buttons[i] = btn
    end
    row:SetScript("OnShow", function(self) Overlord.Popups:RefreshFeaturedFrontCoins(self) end)
    row:Hide()
    return row
end

function Overlord.Popups:RefreshFeaturedFrontActivity()
    if featuredFrontFrame and ApplyFeaturedFrontActivity then
        ApplyFeaturedFrontActivity(featuredFrontFrame)
    end
    self:RefreshNextObjective()
end

-- Bloc activite : sous-panneau WC3, une ligne par front (5 dernieres minutes).
ApplyFeaturedFrontActivity = function(f)
    if not f or not f.activityPanel then return end
    local fa = Overlord.FrontActivity
    if not fa or not fa.GetActivityRows then
        f.activityPanel:Hide()
        if f.activityFooter then f.activityFooter:Hide() end
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
    local featuredId = Overlord.Fronts and Overlord.Fronts.GetFeaturedFrontId and Overlord.Fronts:GetFeaturedFrontId()
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
    if #rows == 0 or not anyActive then
        HideFeaturedFrontActivityRows(f)
        ApplyFeaturedFrontActivityLayout(f, 0)
        return
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
                featuredId and data.frontId == featuredId,
                data.kills
            )
            visibleRows = visibleRows + 1
        end
    end
    ApplyFeaturedFrontActivityLayout(f, visibleRows)
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
        GameTooltip:SetText(expanded and (L.NEXT_OBJECTIVE_COLLAPSE or "Hide next objective")
            or (L.NEXT_OBJECTIVE_HEADER or "Next Objective"))
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
    -- Pas de clamp propre au dock : il le decalait vers le haut et cassait
    -- l'alignement. Le dock prend la hauteur du principal (liste d'activite
    -- reduite) ; le panneau principal n'est jamais deplace par l'addon.
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
    f.titleFs:SetText(L.NEXT_OBJECTIVE_HEADER or "Next Objective")

    -- Nom de la zone : centre horizontal du panneau, sous le ruban.
    f.frontNameFs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.frontNameFs:SetPoint("TOP", f.titleMiddle, "BOTTOM", 0, -16)
    f.frontNameFs:SetPoint("LEFT", f, "LEFT", 22, 0)
    f.frontNameFs:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    f.frontNameFs:SetJustifyH("CENTER")
    f.frontNameFs:SetWordWrap(false)
    f.frontNameFs:SetMaxLines(1)
    f.frontNameFs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    -- Vignette de hauteur constante, y compris sur les fronts a deux points.
    f.artFrame = Overlord.UI.CreateWC3SubPanel(f, FEATURED_FRONT_PANEL_WIDTH - 48, FEATURED_FRONT_ART_HEIGHT)
    f.artFrame:SetPoint("TOP", f.frontNameFs, "BOTTOM", 0, -12)

    f.vignette = f.artFrame:CreateTexture(nil, "ARTWORK")
    f.vignette:SetPoint("CENTER", f.artFrame, "CENTER", 0, 0)
    f.vignette:SetSize(FEATURED_FRONT_PANEL_WIDTH - 56, FEATURED_FRONT_ART_HEIGHT - 8)

    f.bodyFs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.bodyFs:SetPoint("TOPLEFT", f.artFrame, "BOTTOMLEFT", 4, -16)
    f.bodyFs:SetPoint("TOPRIGHT", f.artFrame, "BOTTOMRIGHT", -4, -16)
    f.bodyFs:SetJustifyH("CENTER")
    f.bodyFs:SetJustifyV("TOP")
    f.bodyFs:SetWordWrap(true)
    f.bodyFs:SetTextColor(1, 1, 1)

    f.objectiveDetailsFs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.objectiveDetailsFs:SetPoint("TOPLEFT", f.bodyFs, "BOTTOMLEFT", 0, -NEXT_OBJECTIVE_DETAILS_GAP)
    f.objectiveDetailsFs:SetPoint("TOPRIGHT", f.bodyFs, "BOTTOMRIGHT", 0, -NEXT_OBJECTIVE_DETAILS_GAP)
    f.objectiveDetailsFs:SetJustifyH("CENTER")
    f.objectiveDetailsFs:SetJustifyV("TOP")
    f.objectiveDetailsFs:SetWordWrap(true)
    f.objectiveDetailsFs:SetSpacing(3)
    f.objectiveDetailsFs:SetTextColor(0.82, 0.82, 0.78)
    f.objectiveDetailsFs:Hide()

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
        FEATURED_FRONT_PANEL_WIDTH - 48 - FEATURED_FRONT_ACTIVITY_RAIL_W,
        math.max(1, activityPanelHeight
            - FEATURED_FRONT_ACTIVITY_TITLE_H - FEATURED_FRONT_ACTIVITY_BOTTOM_PAD),
        FEATURED_FRONT_ACTIVITY_ROW_H + FEATURED_FRONT_ACTIVITY_ROW_GAP,
        false)
    f.activityScroll:ClearAllPoints()
    f.activityScroll:SetPoint(
        "TOPLEFT", f.activityPanel, "TOPLEFT", 0, -FEATURED_FRONT_ACTIVITY_TITLE_H)
    f.activityScroll:SetPoint(
        "BOTTOMRIGHT", f.activityPanel, "BOTTOMRIGHT", -FEATURED_FRONT_ACTIVITY_RAIL_W,
        FEATURED_FRONT_ACTIVITY_BOTTOM_PAD)
    f.activityScroll:Hide()

    if Overlord.Ressources then
        f.coinsRow = Overlord.Popups:CreateFeaturedFrontCoinsPanel(f)
        f.activityFooter = f.coinsRow
    end

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

    -- Le volet lateral possede l'activite et son ticker : le replier arrete tout
    -- travail periodique, puis la reouverture repeint immediatement la carte.
    f:SetScript("OnShow", function(self)
        StartFeaturedFrontActivityTicker()
        ApplyFeaturedFrontActivity(self)
        Overlord.Popups:RefreshNextObjective()
        Overlord.Popups:RefreshFeaturedFrontCoins()
    end)
    f:SetScript("OnHide", function()
        StopFeaturedFrontActivityTicker()
    end)

    featuredFrontFrame = f
    Overlord.Popups:RefreshFeaturedFrontCoins()
    SyncFeaturedFrontPanelAnchors()
    SetFeaturedFrontExpanded(IsFeaturedFrontExpanded(), false)
    return f
end

ApplyFeaturedFrontContent = function(f, frontId)
    if not f or not Overlord.Fronts then return false end
    local art = frontId and Overlord.Fronts:GetFeaturedFrontArtPath(frontId)
    if not frontId and Overlord.Fronts.GetHomeArtPath then
        art = Overlord.Fronts:GetHomeArtPath()
    end
    local name = frontId and Overlord.Fronts:GetFeaturedFrontDisplayName(frontId)
    local zone = frontId and Overlord.Zones and Overlord.Zones.GetNextObjectiveZone
        and Overlord.Zones:GetNextObjectiveZone(frontId)
    local text = zone and zone.name or (frontId and (L.NEXT_OBJECTIVE_NONE or "No objective available")
        or (L.NEXT_OBJECTIVE_OUTSIDE_FRONT or "Enter a war front to see your next objective."))
    local pendingSync = zone and Overlord.IsLoginZoneDisplayPending and Overlord:IsLoginZoneDisplayPending(zone)
    if pendingSync then
        text = L.MAP_SYNC_PENDING or "SYNC"
    end
    local details = ""
    if zone and not pendingSync and Overlord.ZoneIndicator and Overlord.ZoneIndicator.GetObjectiveDetails then
        details = Overlord.ZoneIndicator:GetObjectiveDetails(zone)
    end
    if not name and not frontId and Overlord.Fronts.GetHomeMotto then
        name = Overlord.Fronts:GetHomeMotto()
    end
    name = name or (L.NEXT_OBJECTIVE_NO_FRONT or "Outside a war front")
    if f._objectiveArt ~= art then
        f._objectiveArt = art
        f.vignette:SetTexture(art)
        f._activityLayoutKey = nil
    end
    if f._objectiveFrontName ~= name then
        f._objectiveFrontName = name
        f.frontNameFs:SetText(name)
    end
    if f._objectiveText ~= text then
        f._objectiveText = text
        f.bodyFs:SetText(text)
    end
    if f.objectiveDetailsFs and f._objectiveDetails ~= details then
        f._objectiveDetails = details
        f.objectiveDetailsFs:SetText(details)
        f.objectiveDetailsFs:SetShown(details ~= "")
    end
    ApplyFeaturedFrontActivityLayout(f) -- cached by dimensions, including main-panel resizing
    lastFeaturedFrontLoadedId = frontId
    return true
end

-- Reuse the panel's one-second UI tick. Hidden/collapsed panels
-- do no objective scans, and unchanged text/texture is not painted again.
function Overlord.Popups:RefreshNextObjective()
    if not featuredFrontFrame or not featuredFrontFrame:IsVisible() then return end
    ApplyFeaturedFrontContent(featuredFrontFrame, GetObjectiveFrontId())
end

LoadFeaturedFrontContent = function()
    if not Overlord.Fronts then return false end
    local frontId = GetObjectiveFrontId()
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

-- Onglet fleche sur le bord gauche du panneau principal ; restaure l'etat replie/deplie.
function Overlord.Popups:SyncFeaturedFrontDock()
    if not Overlord.Fronts then return end
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
        local frontId = GetObjectiveFrontId()
        local needsLoad = not featuredFrontFrame
            or not featuredFrontFrame:IsShown()
            or lastFeaturedFrontLoadedId ~= frontId
        if needsLoad then
            if LoadFeaturedFrontContent() then
                SetFeaturedFrontExpanded(true, false)
            end
        else
            SetFeaturedFrontExpanded(true, false)
            self:RefreshNextObjective()
        end
    elseif featuredFrontFrame then
        SetFeaturedFrontExpanded(false, false)
    else
        SyncFeaturedFrontPanelAnchors()
        ApplyFeaturedFrontToggleArrow(false)
    end
end

function Overlord.Popups:TryShowFeaturedFrontOnLogin()
    if not CanAutoShowPersistentPopup() then return false end
    if Overlord.InstanceSuspended or not Overlord.IsInitialized then return false end
    if dialogFrame and dialogFrame:IsShown() then return false end
    MigrateLegacyPopupFlags()
    if self:HasShownFeaturedFrontToday() then return false end
    return self:ShowFeaturedFrontDialog(false)
end

-- ---------------------------------------------------------------------------
-- Annonces enregistrees (ajouter ici les futurs popups one-shot)
-- ---------------------------------------------------------------------------

-- Avertissement prioritaire, une seule fois apres une sauvegarde chargee.
Overlord.Popups:RegisterLoginAnnouncement({
    id = FOREVER_NETWORK_NOTICE_ID,
    title = function() return L.FOREVER_NETWORK_NOTICE_TITLE end,
    body = function() return L.FOREVER_NETWORK_NOTICE_BODY end,
    when = function() return true end,
    opts = { showWarningIcon = true },
})

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



Overlord.Popups:RegisterLoginAnnouncement({
    id = "daily_battle_report",
    daily = true,
    -- Closes by itself after 4 s (kept open while hovered).
    opts = { showFactionSeal = true, autoCloseSec = 4 },
    when = function()
        if not IsPlayerOnActiveFront() then return false end
        return BuildBattleReportBody() ~= nil
    end,
    title = function()
        return L.POPUP_BATTLE_REPORT_TITLE
    end,
    body = BuildBattleReportBody,
})
