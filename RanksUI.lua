-- RanksUI.lua : l'onglet Overlord de la feuille de personnage (regles : Ranks.lua).
-- Un onglet lateral sous ceux de Blizzard, le logo Overlord dans le medaillon, a gauche
-- l'insigne du rang dans la couronne de lauriers, a droite les quinze rangs et ce
-- que chacun demande (Gloire, puis semaines dans le haut du classement). Le dernier,
-- Overlord, a sa propre ligne en tete de liste.
-- Rien n'est ecrit dans les tables de Blizzard : l'onglet est a nous, le panneau ouvert
-- par Blizzard est masque par son propre Hide et revient par son propre chemin. Le
-- panneau Monnaies, lui, n'est jamais masque : il reste affiche, invisible, sous le notre.
-- Onglet construit a la premiere ouverture de la feuille, panneaux au premier clic ;
-- pour l'onglet, ni OnUpdate, ni evenement a lui, ni minuterie, ni crochet sur une
-- methode de Blizzard (seulement des crochets de scripts) : un repeint a l'ouverture et
-- a chaque credit local tant qu'il est affiche. Le bandeau d'un rang atteint (en bas
-- du fichier) a son animation et attend la fin de la connexion. Coupe en instance.
Overlord = Overlord or {}
local UIR = Overlord.RanksUI or {}
Overlord.RanksUI = UIR

local LOGO = "Interface\\AddOns\\Overlord\\Textures\\overlord_minimap"
-- Le portrait de Blizzard (62 x 62 pose a -5, 7) n'est pas centre sur le trou de
-- l'anneau du cadre (coin de 95 x 95 pose a -13, 16, trou centre a 37,75 dedans) : le
-- trou est 1,25 px a gauche et 2,25 px au-dessus du centre de la texture, et l'axe du
-- blason est a 130,5 sur 256 dans notre image. Ces coordonnees ramenent le blason au
-- centre du trou ; le debord (2 px) reste sous le metal de l'anneau.
local LOGO_COORDS = { 0.030, 1.030, 0.036, 1.036 }

-- Mesures prises sur l'art du client : centre de l'anneau des lauriers a (132, 108)
-- dans son image de 262 x 220, socle du numero 68 px sous ce centre ; barre de 340 x 20
-- dans son cadre de 369 x 42 (decalage -9, -2, comme la barre de conquete de Blizzard).
local K = {
    RING_Y = -126, BADGE = 124, OVERLORD_BADGE = 128, GLOW = 300, SOCKET_DY = -68,
    PLATE_Y = -236, PLATE_W = 372, PLATE_H = 68, NAME_Y = -262, LINE_Y = -284,
    BAR_Y = -329, BAR_W = 340, BAR_H = 20, BAR_SCALE = 0.92, NEXT_Y = -372,
    STAT_X = 90, STAT_Y = -404, STAT_LABEL_Y = -424,
    LIST_TITLE_Y = -22, LIST_SUB_Y = -42, OVERLORD_Y = -68, OVERLORD_ICON = 40,
    ROWS_Y = -116, ROW_H = 24, ROW_ICON = 22, ROW_PAD = 12, PANE_W = 233,
}
UIR.LAYOUT = K

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function Num(value)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(value) end
    return tostring(value)
end

local function Text(parent, layer, font, justify)
    local fs = parent:CreateFontString(nil, layer, _G[font] and font or "GameFontNormal")
    if justify then fs:SetJustifyH(justify) end
    return fs
end

local function Atlas(parent, layer, sublevel, atlas, useSize)
    local tex = parent:CreateTexture(nil, layer, nil, sublevel)
    tex:SetAtlas(atlas, useSize)
    return tex
end

local function PlayerFaction()
    local faction = Overlord.PlayerFaction
    if faction ~= "Alliance" and faction ~= "Horde" and UnitFactionGroup then
        faction = UnitFactionGroup("player")
    end
    return faction == "Horde" and "horde" or "alliance"
end

local function BlizzardTabs()
    local host = CharacterFrame and CharacterFrame.ModeTabs
    return host and host.Tabs or nil
end

-- L'onglet se range sous le dernier onglet visible de Blizzard.
function UIR:AnchorTab()
    local tab, tabs = self.tab, BlizzardTabs()
    if not tab or not tabs then return end
    local last
    for index = 1, #tabs do
        if tabs[index]:IsShown() then last = tabs[index] end
    end
    tab:ClearAllPoints()
    if last then
        tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -2)
    else
        tab:SetPoint("TOPLEFT", CharacterFrame.ModeTabs, "TOPLEFT")
    end
end

function UIR:EnsureTab()
    if self.tab then return self.tab end
    local tab = CreateFrame("Frame", nil, CharacterFrame.ModeTabs, "LargeSideTabButtonTemplate")
    tab.tooltipText = T("RANK_TAB_TOOLTIP", "Overlord Rank")
    tab.Icon:SetTexture(LOGO)
    tab:SetFillToInterior(true)
    tab:SetChecked(false)
    tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
        if button == "LeftButton" and upInside then UIR:Select() end
    end)
    self.tab = tab
    return tab
end

local function BuildLeft(self)
    local host = CharacterFrame.LeftPaneHost
    local left = CreateFrame("Frame", nil, CharacterFrame)
    left:SetAllPoints(host)
    left:SetFrameLevel(host:GetFrameLevel() + 2)
    -- Le volet arrete la souris comme les panneaux de Blizzard (qui couvrent toute la
    -- feuille, souris activee) : sans cela, leur panneau une fois masque, le monde
    -- derriere la fenetre repondait au survol et aux clics a travers notre onglet.
    left:EnableMouse(true)
    -- (Un script de molette vide : pose seul il activerait la molette, qui ne doit
    -- etre prise que le temps ou le panneau Monnaies est couvert, voir CoverPanel.)
    left:SetScript("OnMouseWheel", function() end)
    left:EnableMouseWheel(false)
    left:Hide()

    local cloth = Atlas(left, "ARTWORK", 1, "honorsystem-prestige-laurel-bg-" .. PlayerFaction(), true)
    cloth:SetPoint("CENTER", left, "TOP", 0, K.RING_Y)
    local laurel = Atlas(left, "ARTWORK", 2, "honorsystem-prestige-laurel", true)
    laurel:SetPoint("CENTER", left, "TOP", -1, K.RING_Y - 2)
    local glow = Atlas(left, "ARTWORK", 3, "titleprestige-starglow")
    glow:SetSize(K.GLOW, K.GLOW)
    glow:SetPoint("CENTER", left, "TOP", 0, K.RING_Y)
    glow:SetBlendMode("ADD")
    glow:Hide()
    local badge = left:CreateTexture(nil, "OVERLAY")
    badge:SetPoint("CENTER", left, "TOP", 0, K.RING_Y)
    local socket = Text(left, "OVERLAY", "GameFontNormalSmall")
    socket:SetPoint("CENTER", left, "TOP", 0, K.RING_Y + K.SOCKET_DY)

    local plate = Atlas(left, "ARTWORK", 1, "titleprestige-title-bg")
    plate:SetSize(K.PLATE_W, K.PLATE_H)
    plate:SetPoint("TOP", left, "TOP", 0, K.PLATE_Y)
    local name = Text(left, "OVERLAY", "GameFontHighlightHuge")
    name:SetPoint("CENTER", left, "TOP", 0, K.NAME_Y)
    local line = Text(left, "OVERLAY", "GameFontNormal")
    line:SetPoint("CENTER", left, "TOP", 0, K.LINE_Y)

    -- La barre, son cadre (9 px a gauche) et la bague du rang suivant (34 px a droite)
    -- font 383 px : reduits a BAR_SCALE et centres ensemble dans le volet. Les ecarts
    -- d'un cadre reduit se comptent dans sa propre echelle.
    local bar = CreateFrame("StatusBar", nil, left)
    bar:SetScale(K.BAR_SCALE)
    bar:SetSize(K.BAR_W, K.BAR_H)
    bar:SetPoint("TOP", left, "TOP", -12.5, K.BAR_Y / K.BAR_SCALE)
    bar:SetMinMaxValues(0, 1)
    local barBack = Atlas(bar, "BACKGROUND", -1, "pvpqueue-conquestbar-background")
    barBack:SetAllPoints()
    local fill = Atlas(bar, "ARTWORK", 0, "_pvpqueue-conquestbar-fill-yellow")
    bar:SetStatusBarTexture(fill)
    local over = CreateFrame("Frame", nil, bar)
    over:SetAllPoints()
    local border = Atlas(over, "ARTWORK", 0, "pvpqueue-conquestbar-frame", true)
    border:SetPoint("LEFT", bar, "LEFT", -9, -2)
    local barText = Text(over, "OVERLAY", "GameFontHighlight")
    barText:SetPoint("CENTER", bar, "CENTER", 0, 0)
    -- Le bout droit du cadre est un socle : Blizzard y pose une recompense dans une
    -- bague (36 px a -8, -2 du bord). Ici l'insigne du rang a atteindre.
    local endDisc = over:CreateTexture(nil, "BORDER")
    endDisc:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    endDisc:SetVertexColor(0.05, 0.04, 0.03)
    endDisc:SetSize(30, 30)
    endDisc:SetPoint("CENTER", bar, "RIGHT", 10, -2)
    local endIcon = over:CreateTexture(nil, "ARTWORK", nil, 1)
    endIcon:SetSize(30, 30)
    endIcon:SetPoint("CENTER", endDisc, "CENTER")
    local endRing = Atlas(over, "OVERLAY", 0, "honorsystem-bar-rewardborder-circle", true)
    endRing:SetPoint("CENTER", endDisc, "CENTER")
    self.endIcon = endIcon
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function(owner)
        GameTooltip:SetOwner(owner, "ANCHOR_TOP")
        GameTooltip:SetText(T("RANK_GLORY", "Glory"), 1, 0.82, 0)
        local ranks = Overlord.Ranks
        GameTooltip:AddLine(string.format(T("RANK_TIP_GLORY", "%d per honorable kill, %d per capture."),
            ranks.GLORY_PER_KILL, ranks.GLORY_PER_CAPTURE), 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(T("RANK_TIP_TOP", "Beyond rank 10, finish weeks at the top."), 1, 1, 1, true)
        local rec = ranks:GetRecord(false)
        for _, top in ipairs(ranks.PLACE_TIERS) do
            if top == 1 then
                GameTooltip:AddLine(string.format(T("RANK_TIP_WEEKS_FIRST", "Weeks finished first: %d"),
                    ranks:GetTopWeeks(rec, top)), 1, 0.82, 0)
            else
                GameTooltip:AddLine(string.format(T("RANK_TIP_WEEKS", "Weeks in the top %d: %d"),
                    top, ranks:GetTopWeeks(rec, top)), 1, 0.82, 0)
            end
        end
        local lordTier = ranks.TIERS[ranks.MAX_RANK]
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format(T("RANK_TIP_OVERLORD",
            "Overlord: %s Glory and %d weeks finished first of your faction, with %s honorable kills or more each week."),
            Num(lordTier.glory), lordTier.weeks, Num(ranks.WEEK_FIRST_MIN_KILLS)), 1, 1, 1, true)
        -- Depuis quand le classement a ete compare a celui d'autres joueurs : ce qui
        -- decide si une semaine dans le top 3 ou finie premier comptera (vert : dans le
        -- delai demande, orange : au-dela).
        GameTooltip:AddLine(" ")
        local seen = ranks:GetLadderSeenAt()
        local age = seen > 0 and GetServerTime and (GetServerTime() - seen) or nil
        if age and age >= 0 then
            local span
            if SecondsToTime then
                local ok, text = pcall(SecondsToTime, math.max(60, age - age % 60), true, false, 2)
                span = ok and text or nil
            end
            span = span or (math.floor(age / 60) .. " min")
            if age < ranks.WEEK_FRESH_SEC then
                GameTooltip:AddLine(string.format(T("RANK_TIP_COMPARED", "Ranking compared with other players %s ago."),
                    span), 0.4, 1, 0.4, true)
            else
                GameTooltip:AddLine(string.format(T("RANK_TIP_COMPARED", "Ranking compared with other players %s ago."),
                    span), 1, 0.6, 0.2, true)
            end
        else
            GameTooltip:AddLine(T("RANK_TIP_NOT_COMPARED", "Ranking not compared with other players yet."),
                1, 0.6, 0.2, true)
        end
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", GameTooltip_Hide)

    local nextText = Text(left, "OVERLAY", "GameFontHighlightSmall")
    nextText:SetPoint("CENTER", left, "TOP", 0, K.NEXT_Y)
    nextText:SetTextColor(0.78, 0.74, 0.66)

    local kills = Text(left, "OVERLAY", "GameFontHighlightLarge")
    kills:SetPoint("CENTER", left, "TOP", -K.STAT_X, K.STAT_Y)
    local killsLabel = Text(left, "OVERLAY", "GameFontNormalSmall")
    killsLabel:SetPoint("CENTER", left, "TOP", -K.STAT_X, K.STAT_LABEL_Y)
    killsLabel:SetText(T("RANK_KILLS", "Honorable kills"))
    local captures = Text(left, "OVERLAY", "GameFontHighlightLarge")
    captures:SetPoint("CENTER", left, "TOP", K.STAT_X, K.STAT_Y)
    local capturesLabel = Text(left, "OVERLAY", "GameFontNormalSmall")
    capturesLabel:SetPoint("CENTER", left, "TOP", K.STAT_X, K.STAT_LABEL_Y)
    capturesLabel:SetText(T("RANK_CAPTURES", "Captures"))

    self.left, self.glow, self.badge, self.socket = left, glow, badge, socket
    self.name, self.line, self.bar, self.barText, self.nextText = name, line, bar, barText, nextText
    self.kills, self.captures = kills, captures
end

local function BuildRight(self)
    local host = CharacterFrame.RightPaneHost
    local right = CreateFrame("Frame", nil, host)
    right:SetAllPoints(host)
    right:SetFrameLevel(host:GetFrameLevel() + 2)
    right:EnableMouse(true)
    right:SetScript("OnMouseWheel", function() end)
    right:EnableMouseWheel(false)
    right:Hide()
    local ranks = Overlord.Ranks

    local title = Text(right, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", right, "TOP", 0, K.LIST_TITLE_Y)
    title:SetText(T("RANK_LIST_TITLE", "Overlord Ranks"))
    local sub = Text(right, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("CENTER", right, "TOP", 0, K.LIST_SUB_Y)
    sub:SetText(T("RANK_LIST_SUBTITLE", "Ranks kept for life"))

    -- Le dernier rang, Overlord, en tete : une ligne plus haute que les autres.
    local top = ranks.MAX_RANK
    local topTier = ranks.TIERS[top]
    local lordBack = right:CreateTexture(nil, "BACKGROUND")
    lordBack:SetColorTexture(1, 0.82, 0, 0.12)
    lordBack:SetPoint("TOPLEFT", right, "TOPLEFT", 8, K.OVERLORD_Y + 2)
    lordBack:SetPoint("BOTTOMRIGHT", right, "TOPRIGHT", -8, K.OVERLORD_Y - K.OVERLORD_ICON - 2)
    lordBack:Hide()
    local lordIcon = right:CreateTexture(nil, "ARTWORK")
    lordIcon:SetTexture(ranks:GetRankIcon(top))
    lordIcon:SetSize(K.OVERLORD_ICON, K.OVERLORD_ICON)
    lordIcon:SetPoint("TOPLEFT", right, "TOPLEFT", K.ROW_PAD, K.OVERLORD_Y)
    local lordName = Text(right, "OVERLAY", "GameFontNormalMed2", "LEFT")
    lordName:SetPoint("TOPLEFT", lordIcon, "TOPRIGHT", 8, -5)
    lordName:SetText(ranks:GetRankName(top))
    local lordSub = Text(right, "OVERLAY", "GameFontHighlightSmall", "LEFT")
    lordSub:SetPoint("TOPLEFT", lordName, "BOTTOMLEFT", 0, -4)
    lordSub:SetText(string.format(T("RANK_NEED_FIRST", "%s · First x%d"), Num(topTier.glory), topTier.weeks))
    lordSub:SetTextColor(0.78, 0.74, 0.66)

    -- Les autres, du plus haut au plus bas : on grimpe vers l'Overlord.
    local rows = {}
    for rank = top - 1, 1, -1 do
        local y = K.ROWS_Y - (top - 1 - rank) * K.ROW_H
        local back = right:CreateTexture(nil, "BACKGROUND")
        back:SetColorTexture(1, 0.82, 0, 0.12)
        back:SetPoint("TOPLEFT", right, "TOPLEFT", 8, y)
        back:SetPoint("BOTTOMRIGHT", right, "TOPRIGHT", -8, y - K.ROW_H + 1)
        back:Hide()
        local icon = right:CreateTexture(nil, "ARTWORK")
        icon:SetTexture(ranks:GetRankIcon(rank))
        icon:SetSize(K.ROW_ICON, K.ROW_ICON)
        icon:SetPoint("LEFT", back, "LEFT", K.ROW_PAD - 8 + 2, 0)
        local need = Text(right, "OVERLAY", "GameFontHighlightSmall", "RIGHT")
        need:SetPoint("RIGHT", back, "RIGHT", -6, 0)
        local tier = ranks.TIERS[rank]
        need:SetText(tier.top and string.format(T("RANK_NEED_TOP", "Top %d x%d"), tier.top, tier.weeks)
            or Num(tier.glory))
        local label = Text(right, "OVERLAY", "GameFontHighlight", "LEFT")
        label:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        label:SetPoint("RIGHT", need, "LEFT", -6, 0)
        label:SetWordWrap(false)
        label:SetText(ranks:GetRankName(rank))
        -- Un nom trop long pour sa ligne (il partage la largeur avec ce que le rang
        -- demande) passe en petite police plutot que d'etre coupe.
        local room = K.PANE_W - 16 - 6 - K.ROW_ICON - 8 - 6 - 6 - (need:GetStringWidth() or 0)
        local wide = label.GetUnboundedStringWidth and label:GetUnboundedStringWidth() or label:GetStringWidth()
        if (wide or 0) > room then label:SetFontObject("GameFontHighlightSmall") end
        rows[rank] = { back = back, icon = icon, label = label, need = need }
    end

    self.right, self.rows, self.lordBack = right, rows, lordBack
end

local function PaintRows(self, rank)
    for index = 1, #self.rows do
        local row = self.rows[index]
        local earned = rank >= index
        row.back:SetShown(index == rank)
        row.icon:SetDesaturated(not earned)
        row.icon:SetAlpha(earned and 1 or 0.45)
        if index == rank then
            row.label:SetTextColor(1, 0.82, 0)
        elseif earned then
            row.label:SetTextColor(1, 1, 1)
        else
            row.label:SetTextColor(0.5, 0.5, 0.5)
        end
        if earned then
            row.need:SetTextColor(1, 1, 1)
        else
            row.need:SetTextColor(0.5, 0.5, 0.5)
        end
    end
end

-- Repeint depuis l'etat local. Un credit ne retouche que la barre et les deux
-- compteurs ; l'insigne, le nom et les lignes des rangs seulement quand le rang change.
-- Jusqu'au rang 10 la barre montre la Gloire, ensuite les semaines finies dans le haut
-- du classement.
function UIR:Refresh()
    if not self.selected or not self.built then return end
    local ranks = Overlord.Ranks
    local s = ranks:GetState()
    local rank = s.rank
    local lord = rank >= ranks.MAX_RANK
    local rankChanged = self.paintRank ~= rank
    if not rankChanged and self.paintGlory == s.glory and self.paintKills == s.kills
        and self.paintGate == s.gateHave then
        return
    end
    self.paintGlory, self.paintKills, self.paintGate = s.glory, s.kills, s.gateHave

    self.bar:SetValue(s.progress)
    if s.nextAt then
        self.barText:SetText(Num(s.glory) .. " / " .. Num(s.nextAt))
    elseif s.gateTop == 1 then
        self.barText:SetText(string.format(T("RANK_BAR_FIRST", "Weeks finished first: %d / %d"),
            s.gateHave, s.gateNeed))
    elseif s.gateTop then
        self.barText:SetText(string.format(T("RANK_BAR_TOP", "Weeks in the top %d: %d / %d"),
            s.gateTop, s.gateHave, s.gateNeed))
    else
        self.barText:SetText(Num(s.glory))
    end
    if self.paintKillsText ~= s.kills then
        self.paintKillsText = s.kills
        self.kills:SetText(Num(s.kills))
    end
    if self.paintCaptures ~= s.captures then
        self.paintCaptures = s.captures
        self.captures:SetText(Num(s.captures))
    end
    if not rankChanged then return end
    self.paintRank = rank

    if rank > 0 then
        local size = lord and K.OVERLORD_BADGE or K.BADGE
        self.badge:SetTexture(ranks:GetRankIcon(rank))
        self.badge:SetSize(size, size)
        self.badge:Show()
        self.socket:SetText(rank)
        self.line:SetText(string.format(T("RANK_NUMBER", "Rank %d"), rank))
    else
        self.badge:Hide()
        self.socket:SetText("")
        self.line:SetText("")
    end
    self.name:SetText(ranks:GetRankName(rank))
    -- L'Overlord : nom en or, halo derriere l'insigne, sa ligne allumee a droite.
    if lord then
        self.name:SetTextColor(1, 0.82, 0)
    else
        self.name:SetTextColor(1, 1, 1)
    end
    self.glow:SetShown(lord)
    self.lordBack:SetShown(lord)
    if rank < ranks.MAX_RANK then
        self.nextText:SetText(string.format(T("RANK_NEXT", "Next rank: %s"), ranks:GetRankName(rank + 1)))
    else
        self.nextText:SetText(T("RANK_MAX", "Highest rank reached"))
    end
    self.endIcon:SetTexture(ranks:GetRankIcon(math.min(rank + 1, ranks.MAX_RANK)))
    PaintRows(self, rank)
end

function UIR:ApplyTitle()
    CharacterFrame:SetTitleColor(NORMAL_FONT_COLOR)
    CharacterFrame:SetTitle("Overlord")
end

function UIR:ApplyPortrait()
    local portrait = CharacterFrame:GetPortrait()
    portrait:SetTexCoord(LOGO_COORDS[1], LOGO_COORDS[2], LOGO_COORDS[3], LOGO_COORDS[4])
    portrait:SetTexture(LOGO)
end

-- Titre, medaillon et onglet coche : poses a la selection, et repris apres le bouton
-- du volet droit (le seul chemin par lequel Blizzard repeint tout, onglet ouvert).
-- Blizzard repose aussi le titre et le portrait seuls (changement de nom, de grade,
-- de portrait) : ces deux-la sont repris a part, sur ses evenements.
function UIR:ApplyChrome()
    self:ApplyTitle()
    self:ApplyPortrait()
    -- Blizzard ne montre le bandeau de pierre que sur son premier onglet : notre titre
    -- de liste s'y pose aussi.
    local stone = CharacterFrame.RightPaneHost.StoneBg
    if stone then stone:Show() end
    local tabs = BlizzardTabs()
    for index = 1, tabs and #tabs or 0 do
        local selected = tabs[index].SelectedTexture
        if selected then selected:Hide() end
    end
    self.tab:SetChecked(true)
end

local function RestoreChrome()
    CharacterFrame:UpdateTitle()
    CharacterFrame:UpdatePortrait()
    if CharacterFrame.UpdateRightPaneHeader then CharacterFrame:UpdateRightPaneHeader() end
    local tabs, active = BlizzardTabs(), CharacterFrame.activeSubframe
    for index = 1, tabs and #tabs or 0 do
        local tab = tabs[index]
        if tab.SelectedTexture then tab.SelectedTexture:SetShown(tab.frameName == active) end
    end
end

-- Un panneau de Blizzard qui s'affiche pendant que notre onglet est ouvert : c'est que
-- le joueur a choisi un autre onglet (clic, raccourci, marchand...). Notre onglet se
-- ferme a cet instant, quel que soit le chemin pris par Blizzard pour l'afficher.
local function OnBlizzardPanelShown()
    if UIR.selected then UIR:Deselect(true) end
end

-- Chaque panneau de la feuille est suivi une fois ; ceux crees plus tard le sont a la
-- selection suivante.
function UIR:WatchBlizzardPanels()
    local watched = self.watched
    if not watched then
        watched = {}
        self.watched = watched
    end
    for _, name in ipairs(CHARACTERFRAME_SUBFRAMES or {}) do
        local frame = _G[name]
        if frame and not watched[name] and frame.HookScript then
            watched[name] = true
            frame:HookScript("OnShow", OnBlizzardPanelShown)
        end
    end
end

local function AnyBlizzardPanelShown()
    for _, name in ipairs(CHARACTERFRAME_SUBFRAMES or {}) do
        local frame = _G[name]
        if frame and frame:IsShown() then return true end
    end
    return false
end

-- Le panneau Monnaies n'est jamais masque ni remontre par nous. Son script de fermeture
-- remet a zero la monnaie choisie : lance depuis un addon, il marquerait ces champs, que
-- le transfert de monnaies entre personnages (une fonction reservee au code de Blizzard)
-- relit ensuite, et le jeu refuserait le transfert jusqu'au rechargement. Il reste donc
-- affiche sous notre onglet : rendu invisible (alpha 0), et ses volets, que Blizzard pose
-- au-dessus de la feuille, passes dessous pour ne plus repondre a la souris (le panneau
-- lui-meme, souris activee, couvre la feuille). Ce ne sont que des reglages d'affichage :
-- aucun script de Blizzard ne tourne, aucun champ n'est ecrit. Une fenetre a part ouverte
-- depuis ce panneau (le journal des transferts) reste telle quelle, visible.
local COVERED_PANELS = { TokenFrame = true }

-- Toujours appelee sous pcall ; ce qui a ete change est note au fur et a mesure, pour
-- que UncoverPanel remette tout meme apres un echec en cours de route.
local function CoverPanel(self, frame)
    local saved = { frame = frame, alpha = frame:GetAlpha(), kids = {} }
    self.covered = saved
    frame:SetAlpha(0)
    local kids = { frame:GetChildren() }
    for index = 1, #kids do
        local child = kids[index]
        if child.IsToplevel and child:IsToplevel() then
            if child.SetIgnoreParentAlpha and child.IsIgnoringParentAlpha then
                saved.kids[#saved.kids + 1] = { frame = child, ignore = child:IsIgnoringParentAlpha() and true or false }
                child:SetIgnoreParentAlpha(true)
            end
        elseif child.SetFrameStrata and child.GetFrameStrata then
            saved.kids[#saved.kids + 1] = { frame = child, strata = child:GetFrameStrata() }
            child:SetFrameStrata("BACKGROUND")
        end
    end
    -- La molette traverse un cadre qui ne l'ecoute pas : sans cela elle ferait defiler,
    -- sous nos volets, la liste invisible des monnaies.
    if self.left and self.left.EnableMouseWheel then self.left:EnableMouseWheel(true) end
    if self.right and self.right.EnableMouseWheel then self.right:EnableMouseWheel(true) end
end

-- Remet le panneau couvert comme Blizzard l'avait laisse (sans effet s'il n'y en a pas).
local function UncoverPanel(self)
    local saved = self.covered
    if not saved then return end
    self.covered = nil
    for index = 1, #saved.kids do
        local kid = saved.kids[index]
        local child = kid.frame
        if kid.strata then
            -- La strate relevee avant de couvrir est remise telle quelle, et reste posee
            -- sur le volet : ne rien supposer de la facon dont le moteur note une strate
            -- venue du XML (la rendre « heritee » pourrait enterrer la liste sous la feuille).
            pcall(child.SetFrameStrata, child, kid.strata)
        elseif kid.ignore ~= nil then
            pcall(child.SetIgnoreParentAlpha, child, kid.ignore)
        end
    end
    pcall(saved.frame.SetAlpha, saved.frame, saved.alpha or 1)
    if self.left and self.left.EnableMouseWheel then self.left:EnableMouseWheel(false) end
    if self.right and self.right.EnableMouseWheel then self.right:EnableMouseWheel(false) end
end

function UIR:Select()
    if self.selected or Overlord.InstanceSuspended or not self.tab then return end
    self:WatchBlizzardPanels()
    -- Le panneau a masquer et a rendre ensuite : celui que Blizzard tient pour actif
    -- s'il est affiche, sinon le premier affiche. Tout autre panneau encore affiche
    -- est masque aussi, rien ne doit rester sous le notre.
    local shown
    local active = CharacterFrame.activeSubframe
    for _, name in ipairs(CHARACTERFRAME_SUBFRAMES or {}) do
        local frame = _G[name]
        if frame and frame:IsShown() and (not shown or name == active) then shown = frame end
    end
    if shown and InCombatLockdown() and shown:IsProtected() then return end
    -- Construits ensemble ou pas du tout : un volet sans l'autre laisserait la feuille
    -- vide au clic suivant.
    if not self.built then
        BuildLeft(self)
        BuildRight(self)
        self.built = true
    end
    -- Selectionne avant le Hide : celui-ci declenche un RefreshDisplay de Blizzard,
    -- apres lequel notre titre et notre medaillon doivent etre reposes.
    self.selected = true
    self.hiddenSub = shown
    -- (pcall : une erreur dans le OnHide d'un panneau de Blizzard ne doit pas laisser
    -- notre onglet a moitie selectionne, sans volets et sourd aux clics suivants.)
    for _, name in ipairs(CHARACTERFRAME_SUBFRAMES or {}) do
        local frame = _G[name]
        if frame and frame:IsShown() then
            -- Le panneau Monnaies est couvert, pas masque (voir COVERED_PANELS). Si un de
            -- ces reglages etait refuse, tout est remis et il est masque comme les autres.
            local covered = false
            if COVERED_PANELS[name] and not self.covered then
                covered = pcall(CoverPanel, self, frame)
                if not covered then UncoverPanel(self) end
            end
            if not covered then pcall(frame.Hide, frame) end
        end
    end
    self.left:Show()
    self.right:Show()
    self:ApplyChrome()
    self.paintGlory = nil
    self:Refresh()
end

-- switching : Blizzard affiche lui-meme un autre panneau. Sinon (feuille fermee,
-- instance) le panneau que nous avions masque est remis. Dans les deux cas le titre, le
-- portrait et les onglets coches sont remis nous-memes d'apres l'etat de Blizzard, sans
-- compter sur un rafraichissement de sa part.
function UIR:Deselect(switching)
    if not self.selected then return end
    self.selected = false
    self.left:Hide()
    self.right:Hide()
    self.tab:SetChecked(false)
    -- Le portrait du joueur que Blizzard va reposer se dessine sur la texture entiere.
    CharacterFrame:GetPortrait():SetTexCoord(0, 1, 0, 1)
    local hidden = self.hiddenSub
    self.hiddenSub = nil
    -- Un panneau couvert (Monnaies) est reste affiche : il redevient visible, sans Show.
    local covered = self.covered and self.covered.frame
    UncoverPanel(self)
    -- (Un panneau protege ne se montre pas en combat : Blizzard le remontrera lui-meme
    -- a la prochaine ouverture.)
    if not switching and hidden and hidden ~= covered and not (InCombatLockdown() and hidden:IsProtected()) then
        hidden:Show()
    end
    RestoreChrome()
end

-- Deuxieme securite : apres un clic sur un onglet de Blizzard, notre onglet ne reste
-- jamais ouvert. Blizzard a deja traite le clic ; s'il n'a affiche aucun panneau, celui
-- que nous avions masque est remis.
local function OnBlizzardTabMouseUp(_, button, upInside)
    if button ~= "LeftButton" or upInside == false or not UIR.selected then return end
    UIR:Deselect(AnyBlizzardPanelShown())
end

-- Un crochet de script, pose sous pcall : un crochet qui echoue ne doit pas empecher
-- les autres. L'etat de chacun est garde pour le diagnostic
-- (/run for k, v in pairs(Overlord.RanksUI.hooks) do print(k, v) end).
local function HookFrameScript(frame, script, label, fn)
    UIR.hooks = UIR.hooks or {}
    if not frame or type(frame.HookScript) ~= "function" then
        UIR.hooks[label] = "absent"
        return
    end
    local ok, err = pcall(frame.HookScript, frame, script, fn)
    UIR.hooks[label] = ok and "ok" or tostring(err)
end

function UIR:OnInstanceSuspend()
    self:Deselect(false)
    if self.tab then self.tab:Hide() end
    -- Le bandeau d'un rang atteint ne suit pas le joueur en instance.
    local toast = Overlord.RankToast
    if toast then
        toast.queue = nil
        if toast.frame then
            toast.life:Stop()
            toast.flash:Stop()
            toast.frame:Hide()
        end
        toast.showing = false
    end
end

-- Pas d'onglet en instance, ni a la manette : Blizzard y pose son repere d'onglet
-- suivant sous son dernier onglet, la ou est le notre, et navigue par sa propre liste.
local function ShouldShowTab()
    if Overlord.InstanceSuspended then return false end
    return not (InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled())
end

function UIR:OnInstanceResume()
    if self.tab then
        self.tab:SetShown(ShouldShowTab())
        self:AnchorTab()
    end
end

function UIR:Attach()
    if self.attached then return end
    local frame = CharacterFrame
    if not frame or not frame.ModeTabs or not frame.LeftPaneHost or not frame.RightPaneHost
        or not frame.HookScript then return end
    self.attached = true
    frame:HookScript("OnShow", function()
        -- (Filet : un panneau couvert ne reste jamais invisible, notre onglet ferme.)
        if not UIR.selected then UncoverPanel(UIR) end
        local tab = UIR:EnsureTab()
        tab:SetShown(ShouldShowTab())
        UIR:AnchorTab()
    end)
    frame:HookScript("OnHide", function() UIR:Deselect(false) end)
    -- Fermeture de notre onglet : sur l'affichage d'un panneau de Blizzard et sur le
    -- clic de ses onglets (crochets de scripts).
    self:WatchBlizzardPanels()
    local tabs = BlizzardTabs()
    for index = 1, tabs and #tabs or 0 do
        if tabs[index].HookScript then tabs[index]:HookScript("OnMouseUp", OnBlizzardTabMouseUp) end
    end
    -- AUCUN crochet sur les methodes de la feuille (ShowSubFrame, RefreshDisplay...) :
    -- une methode enveloppee qui echouerait ferait echouer l'appel de Blizzard lui-meme
    -- (la feuille ne s'ouvrirait plus, l'onglet Personnage resterait sans modele), pas
    -- seulement notre onglet. Onglet ouvert, Blizzard ne repose titre, portrait et
    -- onglets coches que par deux chemins, suivis par leurs scripts : ses propres
    -- evenements (nom, grade, portrait du joueur) et le bouton du volet droit.
    HookFrameScript(frame, "OnEvent", "OnEvent", function(_, event, unit)
        if not UIR.selected then return end
        if (event == "UNIT_NAME_UPDATE" or event == "UNIT_PORTRAIT_UPDATE") and unit ~= "player" then return end
        UIR:ApplyTitle()
        UIR:ApplyPortrait()
    end)
    HookFrameScript(frame.RightPaneToggleButton, "OnClick", "RightPaneToggle", function()
        if UIR.selected then UIR:ApplyChrome() end
    end)
end

-- ---------------------------------------------------------------- bandeau de rang
-- Un rang atteint s'annonce en bas de l'ecran sur le bandeau de haut fait du jeu, avec
-- l'insigne du rang et les points de son haut fait. Un seul cadre, construit au premier
-- rang atteint ; pas d'OnUpdate (des animations), un bandeau a la fois, les suivants
-- attendent leur tour. Rien en instance, et rien pendant les premieres secondes d'une
-- connexion (une semaine close a la connexion peut donner un rang).
local Toast = Overlord.RankToast or {}
Overlord.RankToast = Toast

-- Mesures prises sur ui-achievement-alert-background (310 x 101) : case de l'icone
-- centree a (43, 51), nom a 51 de haut, blason a (272, 51). Pas de ligne de titre :
-- elle mordait sur le cadre, et l'insigne et le nom du rang disent deja tout.
local TOAST = {
    W = 310, H = 101, BOTTOM = 128, ICON_X = 43, MID_Y = -51, ICON = 48, ICON_BACK = 50,
    NAME_X = 158, NAME_W = 150, SHIELD_X = 272,
    FADE_IN = 0.2, HOLD = 5, FADE_OUT = 0.8, LOGIN_DELAY = 8, MAX_QUEUE = 4,
    SOUND = 569143,   -- le jingle de haut fait du jeu
}
Toast.LAYOUT = TOAST

local function BuildToast(self)
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(TOAST.W, TOAST.H)
    frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, TOAST.BOTTOM)
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(false)
    frame:Hide()

    local back = Atlas(frame, "BACKGROUND", 0, "ui-achievement-alert-background", true)
    back:SetPoint("CENTER")
    local iconBack = frame:CreateTexture(nil, "BORDER")
    iconBack:SetColorTexture(0.05, 0.04, 0.03)
    iconBack:SetSize(TOAST.ICON_BACK, TOAST.ICON_BACK)
    iconBack:SetPoint("CENTER", frame, "TOPLEFT", TOAST.ICON_X, TOAST.MID_Y)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(TOAST.ICON, TOAST.ICON)
    icon:SetPoint("CENTER", iconBack, "CENTER")
    local iconFrame = Atlas(frame, "OVERLAY", 0, "ui-achievement-iconframe", true)
    iconFrame:SetPoint("CENTER", iconBack, "CENTER", -1, 1)

    local name = Text(frame, "OVERLAY", "GameFontHighlightMedium")
    name:SetPoint("CENTER", frame, "TOPLEFT", TOAST.NAME_X, TOAST.MID_Y)
    name:SetWidth(TOAST.NAME_W)
    name:SetWordWrap(false)

    local shield = Atlas(frame, "ARTWORK", 0, "ui-achievement-shield-2", true)
    shield:SetPoint("CENTER", frame, "TOPLEFT", TOAST.SHIELD_X, TOAST.MID_Y)
    local points = Text(frame, "OVERLAY", "GameFontNormal")
    points:SetPoint("CENTER", shield, "CENTER", 1, -1)
    points:SetTextColor(1, 1, 1)

    -- L'eclat du jeu a l'apparition, puis le bandeau s'efface seul.
    local glow = Atlas(frame, "OVERLAY", 1, "ui-achievement-alert-glow-glow", true)
    glow:SetPoint("CENTER")
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0)
    local flash = glow:CreateAnimationGroup()
    local flashIn = flash:CreateAnimation("Alpha")
    flashIn:SetFromAlpha(0)
    flashIn:SetToAlpha(1)
    flashIn:SetDuration(0.2)
    flashIn:SetOrder(1)
    local flashOut = flash:CreateAnimation("Alpha")
    flashOut:SetFromAlpha(1)
    flashOut:SetToAlpha(0)
    flashOut:SetDuration(0.5)
    flashOut:SetOrder(2)
    flash:SetToFinalAlpha(true)

    local life = frame:CreateAnimationGroup()
    local fadeIn = life:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(TOAST.FADE_IN)
    fadeIn:SetOrder(1)
    local fadeOut = life:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(TOAST.FADE_OUT)
    fadeOut:SetStartDelay(TOAST.HOLD)
    fadeOut:SetOrder(2)
    life:SetScript("OnFinished", function()
        frame:Hide()
        self.showing = false
        self:Pump()
    end)

    self.frame, self.icon, self.name, self.points = frame, icon, name, points
    self.flash, self.life = flash, life
end

-- Affiche le prochain rang en attente, s'il n'y a pas deja un bandeau a l'ecran.
function Toast:Pump()
    if self.broken then return end
    -- Marque « a l'ecran » sans y etre (une erreur en cours de pose, un cadre masque
    -- par autre chose) : le bandeau ne doit pas rester muet jusqu'au rechargement.
    if self.showing and not (self.frame and self.frame:IsShown()) then self.showing = false end
    if self.showing then return end
    local queue = self.queue
    local rank = queue and table.remove(queue, 1)
    if not rank then return end
    if Overlord.InstanceSuspended then
        self.queue = nil
        return
    end
    local ranks = Overlord.Ranks
    local tier = ranks and ranks.TIERS[rank]
    if not tier then return self:Pump() end
    if not self.frame then
        -- Un cadre qui ne se construit pas n'est pas retente a chaque rang (chaque essai
        -- en laisserait un morceau) : le bandeau est abandonne pour la session.
        if not pcall(BuildToast, self) or not self.frame then
            self.broken, self.queue = true, nil
            return
        end
    end
    self.icon:SetTexture(ranks:GetRankIcon(rank))
    self.name:SetText(ranks:GetRankName(rank))
    self.points:SetText(tier.points or "")
    self.frame:SetAlpha(0)
    self.frame:Show()
    self.showing = true
    self.life:Stop()
    self.life:Play()
    self.flash:Stop()
    self.flash:Play()
    local config = OverlordDB and OverlordDB.config
    if PlaySoundFile and not (config and config.soundEnabled == false) then
        PlaySoundFile(TOAST.SOUND, "Master")
    end
end

-- Un rang vient d'etre atteint. Pendant les premieres secondes d'une connexion le
-- bandeau attend que l'ecran soit la.
function Toast:Show(rank)
    if Overlord.InstanceSuspended or type(rank) ~= "number" then return end
    local queue = self.queue
    if not queue then
        queue = {}
        self.queue = queue
    end
    if #queue >= TOAST.MAX_QUEUE then return end
    queue[#queue + 1] = rank
    local wait = (self.readyAt or 0) - GetTime()
    if wait <= 0 then
        self:Pump()
    elseif not self.waiting then
        self.waiting = true
        C_Timer.After(wait, function()
            self.waiting = false
            self:Pump()
        end)
    end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    Toast.readyAt = GetTime() + TOAST.LOGIN_DELAY
    UIR:Attach()
    -- La feuille de personnage existe a la connexion ; si un jour elle venait plus
    -- tard, un second essai suffit (sans elle, l'onglet ne paraitrait jamais).
    if not UIR.attached and C_Timer and C_Timer.After then
        C_Timer.After(5, function() UIR:Attach() end)
    end
end)
