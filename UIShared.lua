-- UIShared.lua - Helpers UI partages entre panneaux, popups, classement, export
Overlord = Overlord or {}
Overlord.UI = Overlord.UI or {}

local DEFAULT_GOLD = { 0.85, 0.68, 0.20 }
local DEFAULT_GOLD_DIM = { 0.55, 0.42, 0.12 }
local DEFAULT_PANEL_BG = { 0.118, 0.118, 0.188, 0.85 }
local DEFAULT_FALLBACK_BG = { 0.165, 0.165, 0.227, 0.95 }
local DEFAULT_WHITE = { 0.925, 0.937, 0.969 }

local FACTION_WAX_SEAL_ATLAS = {
    Alliance = "Quest-Alliance-WaxSeal",
    Horde    = "Quest-Horde-WaxSeal",
}

local WOOD_BG_PATHS = {
    "Interface\\AddOns\\Overlord\\Textures\\panel_wood_talent",
    "Interface\\Collections\\CollectionsBackgroundTile",
}

-- Couleurs tooltips paneau (voir Core.lua : Overlord.UI_TT).
function Overlord.UI.TooltipPalette()
    return Overlord.UI_TT or { HL = { 1, 0.82, 0 }, BODY = { 1, 1, 1 }, MUTED = { 0.72, 0.72, 0.72 } }
end

-- Conserve les polices historiques sur les clients latin, mais utilise une
-- police Blizzard localisée pour les clients à glyphes cyrilliques ou chinois.
function Overlord.UI.ResolveLocalizedFontPath(fontObject, fallbackPath)
    if not ((Overlord.IsRussianLocale and Overlord.IsRussianLocale())
        or (Overlord.IsChineseLocale and Overlord.IsChineseLocale())) then
        return fallbackPath
    end
    if fontObject and fontObject.GetFont then
        local path = fontObject:GetFont()
        if path and path ~= "" then return path end
    end
    if type(STANDARD_TEXT_FONT) == "string" and STANDARD_TEXT_FONT ~= "" then
        return STANDARD_TEXT_FONT
    end
    return fallbackPath
end

-- Fleche flyout Blizzard (barre d'action) : meme visuel que les fortins/HUD haut.
-- Recupere la texture source depuis un bouton d'action reel (evite de deviner l'atlas).
function Overlord.UI.GetBlizzardFlyoutArrowSource()
    for i = 1, 12 do
        local btn = _G["ActionButton" .. i]
        if btn and btn.FlyoutArrow then
            return btn.FlyoutArrow
        end
    end
    return nil
end

-- side : "LEFT" (pointe vers la gauche) ou "RIGHT" (pointe vers la droite).
-- src : texture source (Overlord.UI.GetBlizzardFlyoutArrowSource()), optionnelle.
function Overlord.UI.ApplyFlyoutArrowStyle(tex, side, src, color)
    if not tex then return end
    local c = color or DEFAULT_GOLD
    tex:SetVertexColor(c[1], c[2], c[3])
    local styled = false
    if src then
        local atlas = src.GetAtlas and src:GetAtlas()
        if atlas and atlas ~= "" then
            styled = pcall(tex.SetAtlas, tex, atlas, true)
        end
        if not styled and src.GetTexture then
            local path = src:GetTexture()
            if path then
                tex:SetTexture(path)
                local a, b, cc, d, e, f, g, h = src:GetTexCoord()
                if a then
                    tex:SetTexCoord(a, b, cc, d, e, f, g, h)
                end
                styled = true
            end
        end
        if styled and tex.SetRotation then
            tex:SetRotation((side == "LEFT") and (math.pi / 2) or (-math.pi / 2))
        end
    end
    if not styled then
        tex:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
        tex:SetRotation(0)
        if side == "LEFT" then
            tex:SetTexCoord(1, 0, 0, 1)
        else
            tex:SetTexCoord(0, 1, 0, 1)
        end
    end
end

-- Palette + sceau de cire (faction du joueur qui consulte l'UI).
function Overlord.UI.GetViewerFactionPalette()
    local fac = Overlord.PlayerFaction or UnitFactionGroup("player")
    if fac == "Horde" then
        return {
            gold = { 0.82, 0.22, 0.12 },
            goldDim = { 0.52, 0.14, 0.08 },
            bright = { 1.0, 0.40, 0.27 },
            white = { 0.941, 0.878, 0.753 },
            panelBg = { 0.12, 0.05, 0.04, 0.88 },
            fallbackBg = { 0.165, 0.122, 0.102, 0.95 },
        }
    end
    return {
        gold = DEFAULT_GOLD,
        goldDim = DEFAULT_GOLD_DIM,
        bright = { 0.427, 0.702, 0.949 },
        white = DEFAULT_WHITE,
        panelBg = DEFAULT_PANEL_BG,
        fallbackBg = DEFAULT_FALLBACK_BG,
    }
end

local cachedWoodBgFile
local woodBgResolverFrame

local function ResolveWoodBgFile()
    if cachedWoodBgFile then
        return cachedWoodBgFile
    end
    cachedWoodBgFile = "Interface\\Tooltips\\UI-Tooltip-Background"
    if not woodBgResolverFrame then
        woodBgResolverFrame = CreateFrame("Frame")
        woodBgResolverFrame:Hide()
    end
    local probe = woodBgResolverFrame._woodProbe
    if not probe then
        probe = woodBgResolverFrame:CreateTexture(nil, "BACKGROUND")
        woodBgResolverFrame._woodProbe = probe
    end
    for _, path in ipairs(WOOD_BG_PATHS) do
        probe:SetTexture(path)
        local fid = probe.GetTextureFileID and probe:GetTextureFileID() or 0
        if fid and fid > 0 then
            cachedWoodBgFile = path
            break
        end
    end
    return cachedWoodBgFile
end

local function ApplyWoodBackdropColors(frame, panelWoodBgFile, fallbackBg)
    if panelWoodBgFile:find("CollectionsBackgroundTile", 1, true) then
        frame:SetBackdropColor(0.82, 0.74, 0.62, 0.96)
    elseif panelWoodBgFile:find("panel_wood_talent", 1, true) then
        frame:SetBackdropColor(1, 1, 1, 0.94)
    else
        frame:SetBackdropColor(fallbackBg[1], fallbackBg[2], fallbackBg[3], fallbackBg[4] or 0.95)
    end
end

-- Fond bois + bordure dialog (panneau principal, popups, classement…).
-- opts : fallbackBg {r,g,b,a}, borderColor {r,g,b}, borderAlpha (defaut 0.85)
function Overlord.UI.ApplyWoodDialogBackdrop(frame, opts)
    opts = opts or {}
    local fallbackBg = opts.fallbackBg or DEFAULT_FALLBACK_BG
    local borderColor = opts.borderColor or DEFAULT_GOLD
    local borderAlpha = opts.borderAlpha or 0.85

    local panelWoodBgFile = ResolveWoodBgFile()
    local woodTileSize = panelWoodBgFile:find("CollectionsBackgroundTile", 1, true) and 200 or 32
    frame:SetBackdrop({
        bgFile   = panelWoodBgFile,
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = woodTileSize,
        edgeSize = 32,
        insets   = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    ApplyWoodBackdropColors(frame, panelWoodBgFile, fallbackBg)
    frame:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderAlpha)
    frame._woodBackdropApplied = true
end

-- Mise à jour légère (faction) sans recréer le backdrop complet.
function Overlord.UI.UpdateWoodDialogBorder(frame, opts)
    if not frame or not frame.SetBackdropBorderColor then return end
    opts = opts or {}
    local fallbackBg = opts.fallbackBg or DEFAULT_FALLBACK_BG
    local borderColor = opts.borderColor or DEFAULT_GOLD
    local borderAlpha = opts.borderAlpha or 0.88
    local panelWoodBgFile = ResolveWoodBgFile()
    if frame.SetBackdropColor then
        ApplyWoodBackdropColors(frame, panelWoodBgFile, fallbackBg)
    end
    frame:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderAlpha)
end

-- Atlas Blizzard Trading Post (theme Horde vs Alliance) + accents Mode Guerre.
local PERKS_CHROME_TOP_ATLAS = "perks-theme-hordevsalliance-tp-topbig"
local PERKS_CHROME_BOTTOM_ATLAS = "perks-theme-hordevsalliance-tp-bottombig"
local PERKS_CHROME_ORB_ATLAS = "pvptalents-warmode-orb"
local PERKS_CHROME_RING_ATLAS = "Talent-RingWithDot"

-- BfA scenario Horde vs Alliance : TitleBG, partie haute seule (blason + ailes).
local BFA_SCENARIO_ALLIANCE_TOP_ATLAS = "AllianceScenario-TitleBG"
local BFA_SCENARIO_HORDE_TOP_ATLAS = "HordeScenario-TitleBG"
-- Hauteur lue depuis le haut de l'atlas ; trimBottomPx retire la ligne bleue en bas.
local BFA_SCENARIO_TITLE_KEEP_TOP_PX = 62
local BFA_SCENARIO_TITLE_TRIM_BOTTOM_PX = 8

local function HideStalePerksChrome(parent)
    local perks = parent._perksChrome
    if perks then
        if perks.top then perks.top:Hide() end
        if perks.bottom then perks.bottom:Hide() end
    end
    local wide = parent._perksChromeWide
    if wide then
        if wide.left then wide.left:Hide() end
        if wide.right then wide.right:Hide() end
        if wide.top then wide.top:Hide() end
        if wide.bottom then wide.bottom:Hide() end
    end
    local expandable = parent._expandableChrome
    if expandable then
        if expandable.topLeft then expandable.topLeft:Hide() end
        if expandable.topMid then expandable.topMid:Hide() end
        if expandable.topRight then expandable.topRight:Hide() end
        if expandable.top then expandable.top:Hide() end
        if expandable.holder then expandable.holder:Hide() end
        if expandable.topAlliance then expandable.topAlliance:Hide() end
        if expandable.topHorde then expandable.topHorde:Hide() end
        if expandable.bottom then expandable.bottom:Hide() end
    end
    local arena = parent._scenarioArenaChrome
    if arena and arena.banner then arena.banner:Hide() end
end

local function TrySetBlizzardAtlas(tex, atlas, useAtlasSize)
    if not tex or not atlas or not tex.SetAtlas then
        if tex then tex:Hide() end
        return false
    end
    local ok = pcall(tex.SetAtlas, tex, atlas, useAtlasSize ~= false)
    if not ok then
        tex:Hide()
        return false
    end
    tex:Show()
    return true
end

-- TitleBG : SetTexture + SetTexCoord (SetAtlas empeche le recadrage UV en retail).
local function ApplyScenarioTitleTopCrop(tex, atlas, keepTopPx, cropSidePx, trimBottomPx)
    if not tex or not atlas or not tex.SetTexture or not tex.SetTexCoord then
        if tex then tex:Hide() end
        return false
    end
    if not C_Texture or not C_Texture.GetAtlasInfo then
        tex:Hide()
        return false
    end

    local info = C_Texture.GetAtlasInfo(atlas)
    if not info or not info.file or not info.width or info.width <= 0 or not info.height then
        tex:Hide()
        return false
    end

    local leftU = info.leftTexCoord
    local rightU = info.rightTexCoord
    local topV = info.topTexCoord
    local bottomV = info.bottomTexCoord
    if not leftU or not rightU or not topV or not bottomV then
        tex:Hide()
        return false
    end

    local keepFromTop = keepTopPx or BFA_SCENARIO_TITLE_KEEP_TOP_PX
    local trimBottom = trimBottomPx or BFA_SCENARIO_TITLE_TRIM_BOTTOM_PX
    local keepH = keepFromTop - trimBottom
    if keepH <= 0 or keepFromTop > info.height then
        tex:Hide()
        return false
    end

    local cropPx = cropSidePx or 0
    if cropPx * 2 >= info.width then
        tex:Hide()
        return false
    end

    local uSpan = rightU - leftU
    local vSpan = bottomV - topV
    local uCropFrac = cropPx / info.width
    local u1 = leftU + uSpan * uCropFrac
    local u2 = rightU - uSpan * uCropFrac
    local v2 = topV + vSpan * (keepH / info.height)
    local outW = info.width - cropPx * 2

    tex:SetTexture(info.file)
    tex:SetTexCoord(u1, u2, topV, v2)
    tex:SetSize(outW, keepH)
    tex:Show()
    return true
end

-- Taille native (pixels UI) d'un atlas, mise en cache : sert a garder le ratio
-- largeur/hauteur d'origine quand on redimensionne le bandeau a la largeur du panneau.
local perksAtlasNativeSizeCache = {}
local function ResolvePerksAtlasNativeSize(atlas)
    local cached = perksAtlasNativeSizeCache[atlas]
    if cached then return cached[1], cached[2] end
    local w, h = 512, 128
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, info = pcall(C_Texture.GetAtlasInfo, atlas)
        if ok and info and info.width and info.width > 0 then
            w = info.width
            h = info.height or info.width
        end
    end
    perksAtlasNativeSizeCache[atlas] = { w, h }
    return w, h
end

-- Bandeaux haut/bas (Comptoir commercial) en couronne/socle du panneau : la
-- majeure partie du visuel deborde a l'exterieur du cadre (comme l'ecran
-- Blizzard "Campaign Results"), avec juste un leger chevauchement sur la
-- bordure doree existante pour la continuite visuelle. Ratio largeur/hauteur
-- d'origine conserve (pas d'etirement qui deforme le blason/les rubans).
-- opts : overhangSide, topOverhangSide, bottomOverhangSide, topOverlap, bottomOverlap, alpha
function Overlord.UI.ApplyPerksHordeVsAllianceChrome(parent, opts)
    if not parent then return nil end
    opts = opts or {}

    local overhangSide = opts.overhangSide or 10
    local topOverhangSide = opts.topOverhangSide or overhangSide
    local bottomOverhangSide = opts.bottomOverhangSide or overhangSide
    local topOverlap = opts.topOverlap or 6
    local bottomOverlap = opts.bottomOverlap or 6
    local alpha = opts.alpha or 1

    local chrome = parent._perksChrome
    if not chrome then
        chrome = {}
        parent._perksChrome = chrome
        chrome.top = parent:CreateTexture(nil, "OVERLAY", nil, 7)
        chrome.bottom = parent:CreateTexture(nil, "OVERLAY", nil, 7)
    end

    -- width : force une largeur de blason fixe (independante de la largeur du cadre).
    -- Sans ca, un cadre tres large (ex. tableau de classement multi-colonnes) etirerait
    -- le blason proportionnellement et le rendrait demesure en hauteur.
    local frameW = opts.width
    if not frameW or frameW <= 0 then
        frameW = parent.GetWidth and parent:GetWidth() or 0
    end
    if frameW <= 0 then frameW = opts.fallbackWidth or 340 end
    local topDesiredW = frameW + topOverhangSide * 2
    local bottomDesiredW = frameW + bottomOverhangSide * 2

    if TrySetBlizzardAtlas(chrome.top, PERKS_CHROME_TOP_ATLAS, false) then
        local nw, nh = ResolvePerksAtlasNativeSize(PERKS_CHROME_TOP_ATLAS)
        local scale = topDesiredW / nw
        chrome.top:SetSize(topDesiredW, nh * scale)
        chrome.top:ClearAllPoints()
        -- Le bas du visuel chevauche legerement le haut du cadre ; le reste (blason,
        -- rubans) depasse vers le haut, hors du panneau. Offset negatif = vers le bas
        -- (dans le cadre), sinon le bandeau flotte au-dessus avec un ecart visible.
        chrome.top:SetPoint("BOTTOM", parent, "TOP", 0, -topOverlap)
        chrome.top:SetAlpha(alpha)
    end

    if TrySetBlizzardAtlas(chrome.bottom, PERKS_CHROME_BOTTOM_ATLAS, false) then
        local nw, nh = ResolvePerksAtlasNativeSize(PERKS_CHROME_BOTTOM_ATLAS)
        local scale = bottomDesiredW / nw
        chrome.bottom:SetSize(bottomDesiredW, nh * scale)
        chrome.bottom:ClearAllPoints()
        -- Le haut du visuel chevauche legerement le bas du cadre ; le reste
        -- (coins colores) depasse vers le bas, hors du panneau. Offset positif = vers
        -- le haut (dans le cadre), sinon le bandeau flotte sous le panneau avec un ecart.
        chrome.bottom:SetPoint("TOP", parent, "BOTTOM", 0, bottomOverlap)
        chrome.bottom:SetAlpha(alpha)
    end

    return chrome
end

-- Bandeau scenario BfA complet (style fin d'arene) : remplace le fond tooltip sur HUD etroit.
-- opts : width, keepTopPx, trimBottomPx, cropSidePx, wingPad, crestLift, alpha
function Overlord.UI.ApplyScenarioArenaBannerChrome(parent, opts)
    if not parent then return nil end
    opts = opts or {}
    HideStalePerksChrome(parent)

    local panelW = opts.width
    if not panelW or panelW <= 0 then
        panelW = parent.GetWidth and parent:GetWidth() or 0
    end
    if panelW <= 0 then panelW = 320 end

    local keepTopPx = opts.keepTopPx or 118
    local trimBottomPx = opts.trimBottomPx or 6
    local cropSidePx = opts.cropSidePx or 8
    local wingPad = opts.wingPad or 12
    local crestLift = opts.crestLift or 8
    local alpha = opts.alpha or 1

    local chrome = parent._scenarioArenaChrome
    if not chrome then
        chrome = {}
        parent._scenarioArenaChrome = chrome
    end
    if parent.SetClipsChildren then parent:SetClipsChildren(false) end
    if not chrome.banner then
        chrome.banner = parent:CreateTexture(nil, "ARTWORK", nil, 0)
    end

    local topAtlas = (Overlord.PlayerFaction == "Horde")
        and BFA_SCENARIO_HORDE_TOP_ATLAS or BFA_SCENARIO_ALLIANCE_TOP_ATLAS
    if ApplyScenarioTitleTopCrop(chrome.banner, topAtlas, keepTopPx, cropSidePx, trimBottomPx) then
        local texW, texH = chrome.banner:GetSize()
        local displayW = panelW + wingPad * 2
        local scale = displayW / texW
        local displayH = texH * scale
        chrome.banner:SetSize(displayW, displayH)
        chrome.banner:ClearAllPoints()
        -- Offset negatif : le blason depasse au-dessus du cadre logique.
        chrome.banner:SetPoint("TOP", parent, "TOP", 0, -crestLift)
        chrome.banner:SetAlpha(alpha)
        chrome.banner:Show()
    end

    if parent.SetBackdrop then
        parent:SetBackdrop(nil)
    end

    return chrome
end

-- Sous-panneau sombre a bordure doree fine.
-- opts : panelBg, borderColor, borderAlpha, insets
function Overlord.UI.CreateWC3SubPanel(parent, w, h, opts)
    opts = opts or {}
    local panelBg = opts.panelBg or DEFAULT_PANEL_BG
    local borderColor = opts.borderColor or DEFAULT_GOLD_DIM
    local borderAlpha = opts.borderAlpha or 0.55
    local insets = opts.insets or { left = 3, right = 3, top = 3, bottom = 3 }

    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(w, h)
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 12,
        insets   = insets,
    })
    f:SetBackdropColor(panelBg[1], panelBg[2], panelBg[3], panelBg[4] or 0.85)
    f:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderAlpha)
    return f
end

-- Bouton style WC3 (texte, icone optionnelle, onClick optionnel).
-- opts : gold, white (tableaux RGB)
function Overlord.UI.CreateWC3Button(parent, w, h, text, onClick, icon, opts)
    opts = opts or {}
    local gold = opts.gold or DEFAULT_GOLD
    local white = opts.white or DEFAULT_WHITE

    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w, h)
    btn:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 14,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    btn:SetBackdropColor(0.12, 0.12, 0.18, 0.9)
    btn:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.6)

    local glow = btn:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\BUTTONS\\UI-Panel-Button-Highlight")
    glow:SetTexCoord(0, 0.625, 0, 0.6875)
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.15)

    local fontTemplate = (h <= 24) and "GameFontNormalSmall" or "GameFontNormal"
    local textObj = btn:CreateFontString(nil, "OVERLAY", fontTemplate)

    if icon then
        local iconSize = h - 8
        local iconTex = btn:CreateTexture(nil, "ARTWORK")
        iconTex:SetSize(iconSize, iconSize)
        iconTex:SetTexture(icon)
        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        btn.icon = iconTex
        textObj:SetPoint("CENTER", iconSize / 2 + 2, 0)
        iconTex:SetPoint("RIGHT", textObj, "LEFT", -4, 0)
    else
        textObj:SetPoint("CENTER")
    end

    textObj:SetText(text)
    textObj:SetTextColor(gold[1], gold[2], gold[3])
    btn.label = textObj
    btn.baseTextColor = { gold[1], gold[2], gold[3] }

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 1.0)
        self.label:SetTextColor(white[1], white[2], white[3])
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.6)
        local bc = self.baseTextColor
        self.label:SetTextColor(bc[1], bc[2], bc[3])
    end)
    btn:SetScript("OnMouseDown", function(self)
        self:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
    end)
    btn:SetScript("OnMouseUp", function(self)
        self:SetBackdropColor(0.12, 0.12, 0.18, 0.9)
    end)
    if onClick then
        btn:SetScript("OnClick", onClick)
    end
    return btn
end

-- Etat actif (rouge natif WoW) vs repos WC3 : scripts souris coherents pour garder le rouge.
local NATIVE_RED_BTN = {
    bg = { 0.55, 0.07, 0.07 },
    bgHover = { 0.65, 0.10, 0.10 },
    bgPush = { 0.40, 0.04, 0.04 },
    border = { 0.95, 0.15, 0.15 },
    borderHover = { 1.00, 0.25, 0.25 },
}
local WC3_BTN_IDLE_BG = { 0.12, 0.12, 0.18 }
local WC3_BTN_IDLE_BG_PUSH = { 0.08, 0.08, 0.12 }

function Overlord.UI.GetWC3RedButtonChrome()
    return NATIVE_RED_BTN
end

function Overlord.UI.AttachWC3GridButtonTooltip(btn, text, opts)
    if not btn then return end
    btn._gridTooltip = text
    Overlord.UI.RefreshWC3GridButtonTooltip(btn, opts)
end

function Overlord.UI.RefreshWC3GridButtonTooltip(btn, opts)
    if not btn or not btn._gridTooltip or btn._olUnavailable then return end
    opts = opts or {}
    local gold = opts.gold or DEFAULT_GOLD
    local white = opts.white or DEFAULT_WHITE
    local text = btn._gridTooltip
    local active = btn._olActiveChrome and true or false
    if btn._olTooltipBoundActive == active and btn._olTooltipBoundText == text then
        return
    end
    btn._olTooltipBoundActive = active
    btn._olTooltipBoundText = text
    local r = NATIVE_RED_BTN

    Overlord.UI.SetWC3ButtonActive(btn, active, { gold = gold, white = white })

    local function restoreChrome(self)
        local isActive = self._olActiveChrome and true or false
        Overlord.UI.SetWC3ButtonActive(self, isActive, { gold = gold, white = white })
        local bc = self.baseTextColor
        if bc and self.label then
            self.label:SetTextColor(bc[1], bc[2], bc[3])
        end
    end

    btn:SetScript("OnEnter", function(self)
        if self._olActiveChrome then
            self:SetBackdropColor(r.bgHover[1], r.bgHover[2], r.bgHover[3], 1)
            self:SetBackdropBorderColor(r.borderHover[1], r.borderHover[2], r.borderHover[3], 1)
            if self.label then self.label:SetTextColor(1, 1, 1) end
        else
            self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 1.0)
            if self.label then self.label:SetTextColor(white[1], white[2], white[3]) end
        end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local tp = Overlord.UI.TooltipPalette and Overlord.UI.TooltipPalette()
        if tp then
            GameTooltip:AddLine(text, tp.HL[1], tp.HL[2], tp.HL[3])
        else
            GameTooltip:SetText(text, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        restoreChrome(self)
        GameTooltip:Hide()
    end)
end

function Overlord.UI.ApplyWC3ButtonChrome(btn, active, opts)
    opts = opts or {}
    local gold = opts.gold or DEFAULT_GOLD
    if not btn or not btn.label or btn._olUnavailable then return end
    btn._olActiveChrome = active and true or false
    if active then
        local r = NATIVE_RED_BTN
        btn:SetBackdropColor(r.bg[1], r.bg[2], r.bg[3], 1)
        btn:SetBackdropBorderColor(r.border[1], r.border[2], r.border[3], 1)
        btn.label:SetTextColor(1, 1, 1)
        btn.baseTextColor = { 1, 1, 1 }
    else
        btn:SetBackdropColor(WC3_BTN_IDLE_BG[1], WC3_BTN_IDLE_BG[2], WC3_BTN_IDLE_BG[3], 0.9)
        btn:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.6)
        btn.label:SetTextColor(gold[1], gold[2], gold[3])
        btn.baseTextColor = { gold[1], gold[2], gold[3] }
    end
end

local WC3_BTN_UNAVAIL_GRAY = { 0.50, 0.53, 0.63 }

-- Grise un bouton d'action hors perimetre (pas de SetEnabled : le tooltip doit rester).
function Overlord.UI.SetWC3ButtonUnavailable(btn, tooltipText, opts)
    if not btn or not btn.label then return end
    opts = opts or {}
    local gray = opts.gray or WC3_BTN_UNAVAIL_GRAY
    btn._olUnavailable = true
    btn._olActiveChrome = false
    btn._olPanelOpenState = false
    btn:SetBackdropColor(0.10, 0.10, 0.12, 0.78)
    btn:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.40)
    btn.label:SetTextColor(gray[1], gray[2], gray[3])
    btn.baseTextColor = { gray[1], gray[2], gray[3] }
    if btn.icon then
        if btn.icon.SetDesaturated then
            btn.icon:SetDesaturated(true)
        end
        btn.icon:SetVertexColor(0.62, 0.62, 0.62)
        btn.icon:SetAlpha(0.40)
    end
    btn:SetScript("OnClick", nil)
    btn:SetScript("OnMouseDown", nil)
    btn:SetScript("OnMouseUp", nil)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.72)
        if not tooltipText or tooltipText == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local tp = Overlord.UI.TooltipPalette and Overlord.UI.TooltipPalette()
        if tp then
            GameTooltip:AddLine(tooltipText, tp.MUTED[1], tp.MUTED[2], tp.MUTED[3], true)
        else
            GameTooltip:SetText(tooltipText, 0.72, 0.72, 0.72, 1, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.40)
        GameTooltip:Hide()
    end)
end

function Overlord.UI.SetWC3ButtonActive(btn, active, opts)
    opts = opts or {}
    local gold = opts.gold or DEFAULT_GOLD
    local white = opts.white or DEFAULT_WHITE
    if not btn or not btn.label or btn._olUnavailable then return end
    local isActive = active and true or false
    if btn._olActiveChrome == isActive then
        return
    end
    Overlord.UI.ApplyWC3ButtonChrome(btn, isActive, opts)
    btn._olTooltipBoundActive = nil
    btn._olTooltipBoundText = nil
    if isActive then
        local r = NATIVE_RED_BTN
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(r.bgHover[1], r.bgHover[2], r.bgHover[3], 1)
            self:SetBackdropBorderColor(r.borderHover[1], r.borderHover[2], r.borderHover[3], 1)
            self.label:SetTextColor(1, 1, 1)
        end)
        btn:SetScript("OnLeave", function(self)
            if not self._olActiveChrome then return end
            self:SetBackdropColor(r.bg[1], r.bg[2], r.bg[3], 1)
            self:SetBackdropBorderColor(r.border[1], r.border[2], r.border[3], 1)
            self.label:SetTextColor(1, 1, 1)
        end)
        btn:SetScript("OnMouseDown", function(self)
            self:SetBackdropColor(r.bgPush[1], r.bgPush[2], r.bgPush[3], 1)
        end)
        btn:SetScript("OnMouseUp", function(self)
            if not self._olActiveChrome then return end
            self:SetBackdropColor(r.bg[1], r.bg[2], r.bg[3], 1)
        end)
    else
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 1.0)
            self.label:SetTextColor(white[1], white[2], white[3])
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.6)
            local bc = self.baseTextColor
            self.label:SetTextColor(bc[1], bc[2], bc[3])
        end)
        btn:SetScript("OnMouseDown", function(self)
            self:SetBackdropColor(WC3_BTN_IDLE_BG_PUSH[1], WC3_BTN_IDLE_BG_PUSH[2], WC3_BTN_IDLE_BG_PUSH[3], 0.95)
        end)
        btn:SetScript("OnMouseUp", function(self)
            self:SetBackdropColor(WC3_BTN_IDLE_BG[1], WC3_BTN_IDLE_BG[2], WC3_BTN_IDLE_BG[3], 0.9)
        end)
    end
end

-- Bouton fermer X (partage : panneau principal, classement, popups, export…)
function Overlord.UI.CreateWC3CloseButton(parent, onClick, opts)
    opts = opts or {}
    local gold = opts.gold or DEFAULT_GOLD

    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(26, 26)
    btn:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 12,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    btn:SetBackdropColor(0.10, 0.10, 0.14, 0.92)
    btn:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.65)
    local glow = btn:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\BUTTONS\\UI-Panel-Button-Highlight")
    glow:SetTexCoord(0, 0.625, 0, 0.6875)
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.18)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetWidth(24)
    label:SetHeight(24)
    label:SetPoint("CENTER", btn, "CENTER", 0, 0)
    label:SetJustifyH("CENTER")
    label:SetJustifyV("MIDDLE")
    label:SetShadowOffset(0, 0)
    label:SetText("X")
    label:SetTextColor(gold[1], gold[2], gold[3])
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 1)
        label:SetTextColor(1, 1, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.65)
        label:SetTextColor(gold[1], gold[2], gold[3])
    end)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- Curseur +/- style WC3 (options addon, panneaux compacts).
-- opts : label, tooltip, min, max, step, get, set, formatValue, formatMin, formatMax, width, height, onChanged
function Overlord.UI.CreateWC3StepperSlider(parent, opts)
    opts = opts or {}
    local gold = opts.gold or DEFAULT_GOLD
    local white = opts.white or DEFAULT_WHITE
    local rowW = opts.width or 420
    local rowH = opts.height or 58
    local minV = opts.min or 0
    local maxV = opts.max or 1
    local stepV = opts.step or 1

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(rowW, rowH)

    local labelFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    labelFs:SetPoint("TOPLEFT", 10, -2)
    labelFs:SetText(opts.label or "")
    labelFs:SetTextColor(gold[1], gold[2], gold[3])

    local trackW = rowW - 12
    local track = Overlord.UI.CreateWC3SubPanel(row, trackW, 30)
    track:SetPoint("TOPLEFT", 0, -22)
    row.track = track

    local minus = Overlord.UI.CreateWC3Button(track, 28, 24, "-", nil, nil, { gold = gold, white = white })
    minus:SetPoint("LEFT", 6, 0)
    local plus = Overlord.UI.CreateWC3Button(track, 28, 24, "+", nil, nil, { gold = gold, white = white })
    plus:SetPoint("RIGHT", -6, 0)

    local valueFs = track:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valueFs:SetPoint("CENTER", 0, 0)
    valueFs:SetTextColor(white[1], white[2], white[3])

    local minFs = track:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    minFs:SetPoint("LEFT", minus, "RIGHT", 8, 0)
    minFs:SetTextColor(0.55, 0.55, 0.6)
    local maxFs = track:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    maxFs:SetPoint("RIGHT", plus, "LEFT", -8, 0)
    maxFs:SetTextColor(0.55, 0.55, 0.6)

    local function fmtBound(v, formatter)
        if formatter then return formatter(v) end
        return tostring(v)
    end
    minFs:SetText(fmtBound(minV, opts.formatMin))
    maxFs:SetText(fmtBound(maxV, opts.formatMax))

    local function refresh()
        if not opts.get then return end
        local v = opts.get()
        valueFs:SetText(opts.formatValue and opts.formatValue(v) or tostring(v))
    end

    local function snap(raw)
        if opts.snap then return opts.snap(raw) end
        raw = tonumber(raw) or minV
        if raw < minV then raw = minV end
        if raw > maxV then raw = maxV end
        if stepV > 0 then
            raw = minV + math.floor((raw - minV) / stepV + 0.5) * stepV
        end
        return raw
    end

    local function applyDelta(delta)
        if not opts.get or not opts.set then return end
        local v = snap((tonumber(opts.get()) or minV) + delta)
        opts.set(v)
        refresh()
        if opts.onChanged then opts.onChanged(v) end
    end

    minus:SetScript("OnClick", function() applyDelta(-stepV) end)
    plus:SetScript("OnClick", function() applyDelta(stepV) end)

    if opts.tooltip then
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(opts.label or "", 1, 0.82, 0)
            GameTooltip:AddLine(opts.tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end

    row.Refresh = refresh
    function row:SetLayoutWidth(w)
        rowW = w
        self:SetWidth(w)
        local newTrackW = w - 12
        if self.track then
            self.track:SetWidth(newTrackW)
        end
    end
    refresh()
    return row
end

local CLASS_TEXTURE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes"
local CLASS_TCOORDS = {
    WARRIOR = { 0, 0.25, 0, 0.25 },
    MAGE = { 0.25, 0.49609375, 0, 0.25 },
    ROGUE = { 0.49609375, 0.7421875, 0, 0.25 },
    DRUID = { 0.7421875, 0.98828125, 0, 0.25 },
    HUNTER = { 0, 0.25, 0.25, 0.5 },
    SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
    PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 },
    WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
    PALADIN = { 0, 0.25, 0.5, 0.75 },
    DEATHKNIGHT = { 0.25, 0.49609375, 0.5, 0.75 },
    MONK = { 0.49609375, 0.7421875, 0.5, 0.75 },
    DEMONHUNTER = { 0.7421875, 0.98828125, 0.5, 0.75 },
    EVOKER = { 0, 0.25, 0.75, 1 },
    UNKNOWN = { 0, 0.25, 0, 0.25 },
}

function Overlord.UI.SetClassIcon(texture, class)
    if not texture then return end
    local token = class
    if Overlord.Leaderboard and Overlord.Leaderboard.NormalizeClassTokenForDisplay then
        token = Overlord.Leaderboard:NormalizeClassTokenForDisplay(class) or token
    elseif token then
        token = string.upper((token:match("^%s*(.-)%s*$") or token))
    end
    if not token or token == "" then token = "UNKNOWN" end
    texture:SetVertexColor(1, 1, 1)
    texture:SetTexture(CLASS_TEXTURE)
    local coords = (CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]) or CLASS_TCOORDS[token]
    if not coords then
        coords = CLASS_TCOORDS.UNKNOWN
        texture:SetVertexColor(0.42, 0.42, 0.42)
    end
    texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    texture:Show()
end

local RACE_ATLAS_TOKEN = {
    Scourge = "undead",
    HighmountainTauren = "highmountain",
    LightforgedDraenei = "lightforged",
    ZandalariTroll = "zandalari",
    Earthen = "earthen",
    EarthenDwarf = "earthen",
    Haranir = "haranir",
    Harronir = "haranir",
    Haronir = "haranir",
}

local CLASSIC_RACE_TEXTURE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races"
-- Coordonnees feuille Classic (creation de perso). Style pixel, pas raceicon-* Retail.
local CLASSIC_RACE_TCOORDS = {
    HUMAN_MALE       = { 0,     0.125, 0,    0.25 },
    DWARF_MALE       = { 0.125, 0.25,  0,    0.25 },
    GNOME_MALE       = { 0.25,  0.375, 0,    0.25 },
    NIGHTELF_MALE    = { 0.375, 0.5,   0,    0.25 },
    DRAENEI_MALE     = { 0.5,   0.625, 0,    0.25 },
    WORGEN_MALE      = { 0.625, 0.75,  0,    0.25 },

    TAUREN_MALE      = { 0,     0.125, 0.25, 0.5  },
    SCOURGE_MALE     = { 0.125, 0.25,  0.25, 0.5  },
    TROLL_MALE       = { 0.25,  0.375, 0.25, 0.5  },
    ORC_MALE         = { 0.375, 0.5,   0.25, 0.5  },
    BLOODELF_MALE    = { 0.5,   0.625, 0.25, 0.5  },
    GOBLIN_MALE      = { 0.625, 0.75,  0.25, 0.5  },

    HUMAN_FEMALE     = { 0,     0.125, 0.5,  0.75 },
    DWARF_FEMALE     = { 0.125, 0.25,  0.5,  0.75 },
    GNOME_FEMALE     = { 0.25,  0.375, 0.5,  0.75 },
    NIGHTELF_FEMALE  = { 0.375, 0.5,   0.5,  0.75 },
    DRAENEI_FEMALE   = { 0.5,   0.625, 0.5,  0.75 },
    WORGEN_FEMALE    = { 0.625, 0.75,  0.5,  0.75 },

    TAUREN_FEMALE    = { 0,     0.125, 0.75, 1.0  },
    SCOURGE_FEMALE   = { 0.125, 0.25,  0.75, 1.0  },
    TROLL_FEMALE     = { 0.25,  0.375, 0.75, 1.0  },
    ORC_FEMALE       = { 0.375, 0.5,   0.75, 1.0  },
    BLOODELF_FEMALE  = { 0.5,   0.625, 0.75, 1.0  },
    GOBLIN_FEMALE    = { 0.625, 0.75,  0.75, 1.0  },
}

local CLASSIC_RACE_ALIASES = {
    UNDEAD = "SCOURGE",
    UNDEAD_MALE = "SCOURGE_MALE",
    UNDEAD_FEMALE = "SCOURGE_FEMALE",
    NIGHT_ELF = "NIGHTELF",
    BLOOD_ELF = "BLOODELF",
}

-- Normalise "raceicon-human-male", "human-male", "HUMAN_MALE" -> cle feuille Classic.
local function NormalizeClassicRaceKey(head)
    if type(head) ~= "string" or head == "" then return nil end
    local s = head
    s = s:gsub("^raceicon%-", "")
    s = s:gsub("%-", "_")
    s = s:upper()
    if CLASSIC_RACE_ALIASES[s] then
        s = CLASSIC_RACE_ALIASES[s]
    end
    local race, sex = s:match("^([A-Z]+)_([A-Z]+)$")
    if race and CLASSIC_RACE_ALIASES[race] then
        s = CLASSIC_RACE_ALIASES[race] .. "_" .. sex
    end
    if CLASSIC_RACE_TCOORDS[s] then return s end
    return nil
end

-- Icone race style Classic (feuille CharacterCreate), avec miroir horizontal optionnel.
function Overlord.UI.SetClassicRaceIcon(texture, head, flipHorizontal)
    if not texture then return false end
    local key = NormalizeClassicRaceKey(head)
    local coords = key and CLASSIC_RACE_TCOORDS[key]
    if not coords then return false end
    if texture.SetAtlas then
        pcall(texture.SetAtlas, texture, nil)
    end
    texture:SetTexture(CLASSIC_RACE_TEXTURE)
    local l, r, t, b = coords[1], coords[2], coords[3], coords[4]
    if flipHorizontal then
        texture:SetTexCoord(r, l, t, b)
    else
        texture:SetTexCoord(l, r, t, b)
    end
    texture:SetVertexColor(1, 1, 1)
    texture:Show()
    return true
end

-- Icone de race (atlas Blizzard raceicon-* ; style roster guilde officiel).
function Overlord.UI.SetRaceIcon(texture, raceFile, sex)
    if not texture then return false end
    local sync = Overlord.Sync
    if sync and sync.NormalizeRaceFileToken then
        raceFile = sync:NormalizeRaceFileToken(raceFile)
    end
    if not raceFile or raceFile == "" then
        if texture.SetAtlas then pcall(texture.SetAtlas, texture, nil) end
        texture:SetTexture(nil)
        texture:Hide()
        return false
    end
    local gender = (tonumber(sex) == 3) and "female" or "male"
    local atlasRace = RACE_ATLAS_TOKEN[raceFile] or string.lower(raceFile)
    -- Candidates : format roster standard, puis raceicon128 (certaines races Midnight).
    local candidates = {
        "raceicon-" .. atlasRace .. "-" .. gender,
        "raceicon128-" .. atlasRace .. "-" .. gender,
    }
    texture:SetVertexColor(1, 1, 1)
    if texture.SetTexture then texture:SetTexture(nil) end
    if texture.SetAtlas then
        for i = 1, #candidates do
            local atlas = candidates[i]
            local exists = true
            if C_Texture and C_Texture.GetAtlasInfo then
                local okInfo, info = pcall(C_Texture.GetAtlasInfo, atlas)
                exists = okInfo and info ~= nil
            end
            if exists then
                local ok = pcall(texture.SetAtlas, texture, atlas, false)
                if ok then
                    texture:Show()
                    return true
                end
            end
        end
        pcall(texture.SetAtlas, texture, nil)
    end
    texture:Hide()
    return false
end

local OFFICIAL_ICON_CIRCLE_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall"

-- Portrait circulaire + anneau RingBorder optionnel (classement, front du jour).
-- opts.ring = false : icone arrondie seule, sans anneau (classement).
function Overlord.UI.CreateOfficialIconHolder(parent, size, accentRgb, opts)
    opts = opts or {}
    local showRing = opts.ring ~= false
    local iconSz = size + 2
    local holderSz = showRing and (size + 4) or iconSz
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(holderSz, holderSz)

    local icon = holder:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSz, iconSz)
    icon:SetPoint("CENTER")
    local mask = holder:CreateMaskTexture()
    mask:SetTexture(OFFICIAL_ICON_CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

    local ring
    if showRing then
        ring = holder:CreateTexture(nil, "OVERLAY")
        ring:SetTexture("Interface\\COMMON\\RingBorder")
        ring:SetSize(holderSz, holderSz)
        ring:SetPoint("CENTER")
        if accentRgb then
            ring:SetVertexColor(accentRgb[1], accentRgb[2], accentRgb[3])
        end
    end

    holder.icon = icon
    holder.ring = ring
    return holder
end
