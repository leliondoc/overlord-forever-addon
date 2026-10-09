-- LeaderboardUI.lua - Tableau de classement (style roster guilde officiel Blizzard)
Overlord = Overlord or {}
Overlord.LeaderboardUI = {}

local L = Overlord.L

local lbFrame = nil
local rows = {}
local guildRows = {}
local guildKeepRows = {}
local outpostRows = {}
-- Kills : 10 lignes visibles, scroll au-dela (meme principe que les listes Captures)
local MAX_VISIBLE_KILL_ROWS = 10
local KILL_ROW_HEIGHT = 26
-- Le cache fournit les 5000 premiers ; seules les lignes visibles ont une frame.
-- Nombre max de lignes affichables dans les listes Captures (avec scroll au-dela)
local MAX_CAPTURE_LINES = Overlord.Leaderboard.CAPTURE_RANK_LIMIT or 500
-- Meme hauteur de ligne que le classement kills (aspect unifie)
local CAPTURE_ROW_HEIGHT = 30
local GUILD_ROW_HEIGHT = 24
local VIRTUAL_ROW_OVERSCAN = 2
local GUILD_KEEP_ICON = 18
-- Colonne droite : tués guildes puis fortins (deux panneaux côte à côte)
local LB_MAIN_W = 418
-- 1.7.1 : guildes plus larges (colonne Membres) ; fortins et avant-postes rendent
-- 44 px chacun en gardant leurs colonnes centrees : la fenetre garde sa largeur.
local LB_GUILD_KILLS_W = 296
local LB_GUILD_KEEP_W = 374
local LB_OUTPOST_W = 374
local LB_COL_GAP = 12
-- Marge interieure : le cadre en bois des panneaux Blizzard est epais.
local LB_FRAME_PAD = 26
-- Le classement s'affiche 20 % plus grand que l'echelle de l'interface Overlord
-- (toujours ramene a la taille de l'ecran).
local LB_SIZE_BOOST = 1.2
local LB_FRAME_W = LB_FRAME_PAD + LB_MAIN_W + LB_COL_GAP + LB_GUILD_KILLS_W + LB_COL_GAP
    + LB_GUILD_KEEP_W + LB_COL_GAP + LB_OUTPOST_W + LB_FRAME_PAD
-- Colonnes guildes (tues) sur panneau 208. VH elargi a 58 px : les totaux de
-- guilde depassent 10 000 (5-6 chiffres) ; le rang reserve quatre chiffres.
-- Rang 8..40, nom 44..156, membres 160..220, VH 224..282 (centre du panneau a 148).
local LB_GUILD_COL_RANK = -124
local LB_GUILD_COL_NAME = -48
local LB_GUILD_COL_MEMBERS = 42
local LB_GUILD_COL_KILLS = 105
local LB_GUILD_NAME_W = 112
local LB_GUILD_RANK_W = 32
local LB_GUILD_MEMBERS_W = 60
local LB_GUILD_KILLS_TEXT_W = 58
-- Fortins : 3 colonnes equidistantes (fort -100, guilde 0, captures +100). Panneau de
-- 374 (centre a 187) : icone + nom 8..122, guilde 125..249, captures 257..317.
local LB_GK_KEEP_LEFT = 8
local LB_GK_KEEP_NAME_W = 92
local LB_GK_COL_KEEP = -100
local LB_GK_COL_GUILD = 0
local LB_GK_COL_WINS = 100
local LB_GK_GUILD_NAME_W = 124
local LB_GK_WINS_W = 60
-- Avant-postes : 3 colonnes (site, guilde, captures)
local LB_OP_OUTPOST_LEFT = LB_GK_KEEP_LEFT
local LB_OP_OUTPOST_NAME_W = LB_GK_KEEP_NAME_W
local LB_OP_COL_OUTPOST = LB_GK_COL_KEEP
local LB_OP_COL_GUILD = LB_GK_COL_GUILD
local LB_OP_COL_CAPTURES = LB_GK_COL_WINS
local LB_OP_GUILD_NAME_W = LB_GK_GUILD_NAME_W
local LB_OP_CAPTURES_W = LB_GK_WINS_W
-- Limite gauche de la colonne guilde (evite le chevauchement avec l'avant-poste)
local LB_OP_GUILD_COL_LEFT = (LB_OUTPOST_W / 2) + LB_OP_COL_GUILD - (LB_OP_GUILD_NAME_W / 2)
local LB_OP_GUILD_COL_RIGHT = LB_OP_GUILD_COL_LEFT + LB_OP_GUILD_NAME_W
local LB_OP_OUTPOST_NAME_MAX_W = LB_OP_GUILD_COL_LEFT - 4 - (LB_OP_OUTPOST_LEFT + GUILD_KEEP_ICON + 4)
-- Espacement vertical entre sections
local LB_GAP_SECTION = 12
local LB_GAP_HEADER = 4
-- Disposition type roster guilde (worldofwarcraft.blizzard.com)
local LB_ROW_PAD = 10
local LB_KILLS_SCROLL_GUTTER = 20
local LB_KILLS_RIGHT = LB_ROW_PAD + LB_KILLS_SCROLL_GUTTER
local LB_CAPTURE_PANEL_W = math.floor(LB_MAIN_W * 0.5)
local LB_ICON_SIZE = 22
local LB_HEADER_H = 24
-- Colonnes kills : # / icones race+classe compacts, nom elargi, tues fixe (roster Blizzard).
local LB_KILL_COL_RANK_W = 34
local LB_KILL_COL_ICON_W = 34
local LB_KILL_COL_KILLS_W = 50
-- Captures : deux icones compactes, nom lisible et compteur fixe.
local LB_CAPTURE_ROW_PAD = 4
local LB_CAPTURE_SCROLL_GUTTER = 18
local LB_CAPTURE_COL_ICON_W = 24
local LB_CAPTURE_COL_COUNT_W = 32

local function GetKillTableInnerLeft()
    return LB_ROW_PAD
end

local function GetKillTableInnerRight(panelW)
    return (panelW or LB_MAIN_W) - LB_KILLS_RIGHT
end

local function GetKillLayoutSegments(panelW)
    local left = GetKillTableInnerLeft()
    local right = GetKillTableInnerRight(panelW)
    local rankLeft = left
    local raceLeft = rankLeft + LB_KILL_COL_RANK_W
    local classLeft = raceLeft + LB_KILL_COL_ICON_W
    local playerLeft = classLeft + LB_KILL_COL_ICON_W
    local killsLeft = right - LB_KILL_COL_KILLS_W
    return {
        rank = {
            left = rankLeft,
            right = raceLeft,
            center = rankLeft + LB_KILL_COL_RANK_W * 0.5,
            width = LB_KILL_COL_RANK_W,
        },
        race = {
            left = raceLeft,
            right = classLeft,
            center = raceLeft + LB_KILL_COL_ICON_W * 0.5,
            width = LB_KILL_COL_ICON_W,
        },
        class = {
            left = classLeft,
            right = playerLeft,
            center = classLeft + LB_KILL_COL_ICON_W * 0.5,
            width = LB_KILL_COL_ICON_W,
        },
        player = {
            left = playerLeft,
            right = killsLeft,
            center = (playerLeft + killsLeft) * 0.5,
            width = killsLeft - playerLeft,
        },
        kills = {
            left = killsLeft,
            right = right,
            center = killsLeft + LB_KILL_COL_KILLS_W * 0.5,
            width = LB_KILL_COL_KILLS_W,
        },
    }
end

local function GetCaptureLayoutSegments(panelW)
    local left = LB_CAPTURE_ROW_PAD
    local right = (panelW or LB_CAPTURE_PANEL_W)
        - LB_CAPTURE_ROW_PAD - LB_CAPTURE_SCROLL_GUTTER
    local raceLeft = left
    local classLeft = raceLeft + LB_CAPTURE_COL_ICON_W
    local nameLeft = classLeft + LB_CAPTURE_COL_ICON_W
    local countLeft = right - LB_CAPTURE_COL_COUNT_W
    return {
        race = {
            left = raceLeft,
            right = classLeft,
            center = raceLeft + LB_CAPTURE_COL_ICON_W * 0.5,
            width = LB_CAPTURE_COL_ICON_W,
        },
        class = {
            left = classLeft,
            right = nameLeft,
            center = classLeft + LB_CAPTURE_COL_ICON_W * 0.5,
            width = LB_CAPTURE_COL_ICON_W,
        },
        name = {
            left = nameLeft,
            right = countLeft,
            center = (nameLeft + countLeft) * 0.5,
            width = countLeft - nameLeft,
        },
        count = {
            left = countLeft,
            right = right,
            center = countLeft + LB_CAPTURE_COL_COUNT_W * 0.5,
            width = LB_CAPTURE_COL_COUNT_W,
        },
    }
end
-- Aligne sur Leaderboard:NormalizeClassTokenForDisplay (trim, majuscules, token valide).
local function ResolveClassTokenForUI(class)
    if Overlord.Leaderboard and Overlord.Leaderboard.NormalizeClassTokenForDisplay then
        local t = Overlord.Leaderboard:NormalizeClassTokenForDisplay(class)
        if t then return t end
    end
    if not class or class == "" then return "UNKNOWN" end
    return string.upper((class:match("^%s*(.-)%s*$") or class))
end

local function GetClassColor(class)
    local token = ResolveClassTokenForUI(class)
    if RAID_CLASS_COLORS and token and RAID_CLASS_COLORS[token] then
        local c = RAID_CLASS_COLORS[token]
        return c.r, c.g, c.b
    end
    return nil, nil, nil
end

-- Nom captures : meme resolution de token que SetClassIcon (evite icone classe + nom couleur faction).
local function GetCaptureRowNameColor(entry, capClass, P)
    local token = ResolveClassTokenForUI((type(capClass) == "string" and capClass ~= "") and capClass or nil)
    if token ~= "UNKNOWN" then
        local r, g, b = GetClassColor(token)
        if r and g and b then
            return r, g, b
        end
    end
    if entry and entry.faction == "Horde" then
        return 1.0, 0.40, 0.27
    end
    if entry and entry.faction == "Alliance" then
        return 0.427, 0.702, 0.949
    end
    return P.gray[1], P.gray[2], P.gray[3]
end

local function SetClassIcon(texture, class)
    if not texture then return end
    if not class then texture:Hide(); return end
    if Overlord.UI and Overlord.UI.SetClassIcon then
        Overlord.UI.SetClassIcon(texture, class)
        texture:Show()
        return
    end
    texture:Hide()
end

local function SetRaceIcon(texture, raceFile, sex)
    if not texture then return false end
    if Overlord.UI then
        local race = raceFile
        if Overlord.Sync and Overlord.Sync.NormalizeRaceFileToken then
            race = Overlord.Sync:NormalizeRaceFileToken(raceFile)
        end
        if race and race ~= "" and Overlord.UI.SetClassicRaceIcon then
            local gender = tonumber(sex) == 3 and "female" or "male"
            if Overlord.UI.SetClassicRaceIcon(texture, race .. "-" .. gender) then
                return true
            end
        end
        -- Les races absentes de la feuille Classic conservent leur portrait Blizzard.
        if Overlord.UI.SetRaceIcon then
            return Overlord.UI.SetRaceIcon(texture, raceFile, sex)
        end
    end
    texture:Hide()
    return false
end

-- Couleurs du medal (rang 1, 2, 3)
local MEDAL_COLORS = {
    {1.0, 0.84, 0.0},
    {0.75, 0.75, 0.75},
    {0.80, 0.50, 0.20},
}

-- Faction crests (domination bar / chat alert logos) and row glows: podium rows
-- carry a faint medal tint, the player's own row (or guild) a gold one. Painted
-- only when a row's paint key changes, like the rest of the virtual rows.
local LB_CREST = {
    Alliance = "Interface\\Timer\\Alliance-Logo",
    Horde = "Interface\\Timer\\Horde-Logo",
}
local function LbCrestMarkup(faction, size)
    local path = LB_CREST[faction]
    return path and ("|T" .. path .. ":" .. (size or 16) .. ":" .. (size or 16) .. "|t") or ""
end
local function ApplyLbRowGlow(row, rank, isOwn)
    local glow = row.glow
    if not glow then return end
    local medal = MEDAL_COLORS[rank]
    if isOwn then
        glow:SetColorTexture(1.0, 0.82, 0.0, 0.16)
        glow:Show()
    elseif medal then
        glow:SetColorTexture(medal[1], medal[2], medal[3], 0.08)
        glow:Show()
    else
        glow:Hide()
    end
end

-- Rafraichissement differe (sync / nameplates / changement de zone).
local lbRefreshPending = false
local lbRefreshLastAt = 0
local lbRefreshToken = 0
local LB_REFRESH_MIN_INTERVAL = 1
local LB_REFRESH_DEBOUNCE = 0.12
local lbSectionsLayoutDone = false
local RenderKillRows
local RenderGuildRows
local RenderGuildKeepRows
local RenderOutpostRows
local RenderCaptureRows

local function CachedMeta(metaCache, name)
    local e = metaCache and metaCache[name]
    if e then return e[1], e[2], e[3], e[4] end
    if Overlord.Leaderboard then
        local c, f = Overlord.Leaderboard:GetExportPlayerMeta(name)
        local race, raceSex = "", 0
        if Overlord.Leaderboard.GetExportPlayerRace then
            race, raceSex = Overlord.Leaderboard:GetExportPlayerRace(name)
        end
        return c, f, race, raceSex
    end
    return "", "", "", 0
end

local function GetGuildKeepSiteDisplayName(siteKey)
    if not siteKey or siteKey == "" or not Overlord.GuildKeep then return "" end
    local site = Overlord.GuildKeep:GetSite(siteKey)
    if not site then return "" end
    if Overlord.GuildKeep.GetShortDisplayName then
        return Overlord.GuildKeep:GetShortDisplayName(site)
    end
    return (site.displayNameKey and L and L[site.displayNameKey]) or ""
end

local function GetOutpostSiteDisplayName(siteKey)
    if not siteKey or siteKey == "" or not Overlord.Outpost then return "" end
    local site = Overlord.Outpost:GetSite(siteKey)
    if not site then return "" end
    if Overlord.Outpost.GetShortDisplayName then
        return Overlord.Outpost:GetShortDisplayName(site)
    end
    return (site.displayNameKey and L and L[site.displayNameKey]) or ""
end

-- Mesure fiable par police (GetStringWidth renvoie 0 sur les lignes cachees).
local lbMeasureByFont = {}
local lbTruncateCache = {}
local lbTruncateCacheCount = 0
local LB_TRUNCATE_CACHE_MAX = 512

local function CacheTruncatedText(cacheKey, value)
    if lbTruncateCacheCount >= LB_TRUNCATE_CACHE_MAX then
        lbTruncateCache = {}
        lbTruncateCacheCount = 0
    end
    lbTruncateCache[cacheKey] = value
    lbTruncateCacheCount = lbTruncateCacheCount + 1
    return value
end

local function GetMeasureFontString(fontKey)
    if not lbFrame or not fontKey then return nil end
    local measure = lbMeasureByFont[fontKey]
    if not measure then
        measure = lbFrame:CreateFontString(nil, "OVERLAY", fontKey)
        lbMeasureByFont[fontKey] = measure
    end
    if measure.SetWidth then measure:SetWidth(0) end
    return measure
end

local function MeasureTextWidth(measure, str, fontKey, pxPerChar)
    measure:SetText(str or "")
    local w = measure:GetStringWidth() or 0
    if w > 0 then return w end
    local len = (utf8 and utf8.len and utf8.len(str)) or #(str or "")
    return len * pxPerChar
end

-- Tronque un libelle pour tenir dans maxWidth px (suffixe "..." si trop long).
local function TruncateTextToWidth(text, maxWidth, fontKey)
    if not text or text == "" then return text or "" end
    maxWidth = tonumber(maxWidth) or 0
    if maxWidth <= 0 then return text end
    fontKey = fontKey or "GameFontNormal"
    local cacheKey = text .. "\31" .. maxWidth .. "\31" .. fontKey
    local cached = lbTruncateCache[cacheKey]
    if cached then return cached end

    maxWidth = maxWidth - 2
    local measure = GetMeasureFontString(fontKey)
    if not measure then return text end
    local pxPerChar = (fontKey == "GameFontNormalSmall") and 5.5 or 7
    if MeasureTextWidth(measure, text, fontKey, pxPerChar) <= maxWidth then
        return CacheTruncatedText(cacheKey, text)
    end
    local suffix = "..."
    if MeasureTextWidth(measure, suffix, fontKey, pxPerChar) >= maxWidth then
        return CacheTruncatedText(cacheKey, suffix)
    end
    local function withSuffix(prefix)
        return (prefix:gsub("%s+$", "") or prefix) .. suffix
    end
    local result = suffix
    if utf8 and utf8.len and utf8.offset then
        local len = utf8.len(text)
        local lo, hi = 1, len
        while lo <= hi do
            local mid = math.floor((lo + hi) * 0.5)
            local cut = utf8.offset(text, mid + 1)
            if cut then
                local part = withSuffix(text:sub(1, cut - 1))
                if MeasureTextWidth(measure, part, fontKey, pxPerChar) <= maxWidth then
                    result = part
                    lo = mid + 1
                else
                    hi = mid - 1
                end
            else
                hi = mid - 1
            end
        end
    else
        local lo, hi = 1, #text
        while lo <= hi do
            local mid = math.floor((lo + hi) * 0.5)
            local part = withSuffix(text:sub(1, mid))
            if MeasureTextWidth(measure, part, fontKey, pxPerChar) <= maxWidth then
                result = part
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
    end
    return CacheTruncatedText(cacheKey, result)
end

-- Fortins / avant-postes : rebuild couteux (etat live), throttle au refresh UI.
local lbVolatileLists = {
    keeps = nil,
    outposts = nil,
    at = 0,
    pending = false,
    dirty = true,
    token = 0,
}
local LB_VOLATILE_LISTS_TTL = 30
local LB_VOLATILE_WORK_PER_SLICE = 64
local LB_VOLATILE_MS_PER_SLICE = 1

local function GetVolatileLeaderboardLists(lb, sortedGuilds)
    local now = GetTime()
    -- Ces listes ne dependent pas des compteurs joueurs. Les lier a l'epoch globale faisait
    -- rejouer les scans fortins/avant-postes apres chaque kill recu, annulant completement le TTL.
    if not lbVolatileLists.dirty and lbVolatileLists.keeps
        and (now - lbVolatileLists.at) < LB_VOLATILE_LISTS_TTL then
        return lbVolatileLists.keeps, lbVolatileLists.outposts
    end
    if not lbVolatileLists.pending and C_Timer and C_Timer.After then
        lbVolatileLists.pending = true
        lbVolatileLists.token = lbVolatileLists.token + 1
        local token = lbVolatileLists.token
        local work, started = 0, 0
        local worker = coroutine.create(function()
            local function yieldWork()
                work = work + 1
                local timedOut = debugprofilestop
                    and debugprofilestop() - started >= LB_VOLATILE_MS_PER_SLICE
                if work >= LB_VOLATILE_WORK_PER_SLICE or timedOut then coroutine.yield() end
            end
            local keeps = lb.GetSortedGuildKeeps
                and lb:GetSortedGuildKeeps(sortedGuilds, yieldWork) or {}
            local outposts = lb.GetSortedOutposts
                and lb:GetSortedOutposts(sortedGuilds, yieldWork) or {}
            return keeps, outposts
        end)
        local function runSlice()
            if token ~= lbVolatileLists.token or not lbVolatileLists.pending then return end
            work = 0
            started = debugprofilestop and debugprofilestop() or 0
            local ok, keepsOrErr, outposts = coroutine.resume(worker)
            if not ok then
                lbVolatileLists.pending = false
                C_Timer.After(1, function()
                    if token ~= lbVolatileLists.token then return end
                    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
                        Overlord.LeaderboardUI:RequestRefresh()
                    end
                end)
                return
            end
            if coroutine.status(worker) ~= "dead" then
                C_Timer.After(0, runSlice)
                return
            end
            lbVolatileLists.keeps = type(keepsOrErr) == "table" and keepsOrErr or {}
            lbVolatileLists.outposts = type(outposts) == "table" and outposts or {}
            lbVolatileLists.at = GetTime()
            lbVolatileLists.dirty = false
            lbVolatileLists.pending = false
            if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
                Overlord.LeaderboardUI:RequestRefresh()
            end
        end
        C_Timer.After(0, runSlice)
    end
    -- L'ancienne vue reste visible jusqu'au commit complet; le premier affichage
    -- utilise simplement deux listes vides pendant quelques tranches.
    return lbVolatileLists.keeps or {}, lbVolatileLists.outposts or {}
end

-- Textures Blizzard (barres de defilement) pour indiquer qu'on peut scroller
local SCROLL_IND_UP   = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up"
local SCROLL_IND_DOWN = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up"

-- Rail compact WC3, identique au selecteur de cibles des contrats.
-- La poignee reste un vrai Button draggable, sans template Blizzard ni allocation au scroll.
local function AttachCleanScrollRail(scroll, parent, upT, downT, P)
    if not scroll or not parent or scroll._overlordRefreshRail then return end

    -- Le cache opaque isole le rail des separateurs horizontaux des lignes qui
    -- defilent dessous. Il ne capture pas la souris et ne modifie pas le contenu.
    local railMask = CreateFrame("Frame", nil, parent)
    railMask:SetWidth(9)
    railMask:SetPoint("TOP", scroll, "TOPRIGHT", -11, -22)
    railMask:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", -11, 22)
    railMask:SetFrameLevel((scroll:GetFrameLevel() or 1) + 3)
    railMask:EnableMouse(false)
    local railMaskBg = railMask:CreateTexture(nil, "BACKGROUND")
    railMaskBg:SetAllPoints()
    railMaskBg:SetColorTexture(P.panel[1], P.panel[2], P.panel[3], 1)
    railMask:Hide()

    local track = railMask:CreateTexture(nil, "OVERLAY", nil, 5)
    track:SetWidth(3)
    track:SetPoint("TOP")
    track:SetPoint("BOTTOM")
    track:SetColorTexture(P.accentDm[1], P.accentDm[2], P.accentDm[3], 0.34)
    track:Hide()

    local thumb = CreateFrame("Button", nil, parent)
    thumb:SetSize(14, 18)
    thumb:SetFrameLevel((scroll:GetFrameLevel() or 1) + 4)
    thumb:EnableMouse(true)
    thumb:RegisterForDrag("LeftButton")

    local thumbBar = thumb:CreateTexture(nil, "OVERLAY", nil, 6)
    thumbBar:SetWidth(5)
    thumbBar:SetPoint("TOP", 0, -1)
    thumbBar:SetPoint("BOTTOM", 0, 1)
    thumbBar:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 0.88)
    thumb:Hide()

    local function RefreshRail()
        local maximum = scroll:GetVerticalScrollRange() or 0
        local current = scroll:GetVerticalScroll() or 0
        -- GetVerticalScrollRange peut conserver une ancienne valeur pendant un
        -- frame de layout. Le verdict semantique pose pendant Refresh evite donc
        -- d'afficher un rail fantome lorsque toutes les lignes tiennent deja.
        local hasScroll = scroll._overlordHasOverflow == true

        upT:SetShown(hasScroll)
        downT:SetShown(hasScroll)
        upT:SetAlpha(current > 1 and 0.85 or 0.28)
        downT:SetAlpha(current < maximum - 1 and 0.85 or 0.28)
        railMask:SetShown(hasScroll)
        track:SetShown(hasScroll)
        thumb:SetShown(hasScroll)

        if hasScroll then
            local viewportHeight = math.max(1, scroll:GetHeight() or 1)
            local contentHeight = math.max(viewportHeight,
                tonumber(scroll._overlordContentHeight) or (viewportHeight + maximum))
            local trackHeight = math.max(1, viewportHeight - 44)
            local thumbHeight = math.max(18,
                math.min(trackHeight, trackHeight * viewportHeight / contentHeight))
            local travel = math.max(0, trackHeight - thumbHeight)
            local offset = maximum > 0 and travel * current / maximum or 0
            thumb:ClearAllPoints()
            thumb:SetSize(14, thumbHeight)
            thumb:SetPoint("TOP", scroll, "TOPRIGHT", -11, -22 - offset)
        end
    end

    local function GetScaledCursorY()
        local _, cursorY = GetCursorPosition()
        local scale = UIParent and UIParent:GetEffectiveScale() or 1
        if not scale or scale <= 0 then scale = 1 end
        return cursorY / scale
    end

    local function UpdateThumbDrag(self)
        local maximum = scroll:GetVerticalScrollRange() or 0
        if maximum <= 2 then return end
        local trackTop = (scroll:GetTop() or 0) - 22
        local trackHeight = math.max(1, (scroll:GetHeight() or 1) - 44)
        local travel = math.max(0, trackHeight - (self:GetHeight() or 18))
        if travel <= 0 then return end
        local wantedTop = GetScaledCursorY() + (self.dragOffset or 0)
        local offset = math.max(0, math.min(travel, trackTop - wantedTop))
        scroll:SetVerticalScroll(maximum * offset / travel)
        RefreshRail()
    end

    local function StopThumbDrag(self)
        self.dragging = false
        self.dragOffset = nil
        self:SetScript("OnUpdate", nil)
        thumbBar:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 0.88)
    end

    thumb:SetScript("OnDragStart", function(self)
        if (scroll:GetVerticalScrollRange() or 0) <= 2 then return end
        local cursorY = GetScaledCursorY()
        self.dragOffset = (self:GetTop() or cursorY) - cursorY
        self.dragging = true
        thumbBar:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 1)
        self:SetScript("OnUpdate", UpdateThumbDrag)
    end)
    thumb:SetScript("OnDragStop", StopThumbDrag)
    thumb:SetScript("OnHide", StopThumbDrag)
    thumb:SetScript("OnEnter", function()
        thumbBar:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 1)
    end)
    thumb:SetScript("OnLeave", function(self)
        if not self.dragging then
            thumbBar:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 0.88)
        end
    end)

    scroll._overlordScrollRailMask = railMask
    scroll._overlordScrollTrack = track
    scroll._overlordScrollThumb = thumb
    scroll._overlordRefreshRail = RefreshRail
    scroll:HookScript("OnSizeChanged", RefreshRail)
end

local function SetLeaderboardScrollExtent(scroll, child, rowCount, rowHeight)
    if not scroll or not child then return end
    local viewportHeight = math.max(1, scroll:GetHeight() or 1)
    local count = math.max(0, math.floor(tonumber(rowCount) or 0))
    local contentHeight = math.max(viewportHeight, math.max(1, count) * rowHeight)
    if math.abs((child:GetHeight() or 0) - contentHeight) > 0.5 then
        child:SetHeight(contentHeight)
    end
    scroll._overlordContentHeight = contentHeight
    scroll._overlordHasOverflow = count * rowHeight > viewportHeight + 2
    if not scroll._overlordHasOverflow and (scroll:GetVerticalScroll() or 0) ~= 0 then
        scroll:SetVerticalScroll(0)
    end
end

local function CreateScrollIndicators(parent, scroll)
    local upT = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    upT:SetTexture(SCROLL_IND_UP)
    upT:SetSize(18, 18)
    upT:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -2, -2)
    upT:SetAlpha(0.8)
    upT:Hide()

    local downT = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    downT:SetTexture(SCROLL_IND_DOWN)
    downT:SetSize(18, 18)
    downT:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -2, 2)
    downT:SetAlpha(0.8)
    downT:Hide()
    return upT, downT
end

local function UpdateLeaderboardScrollIndicator(scroll, upT, downT)
    if not scroll or not upT or not downT then return end
    if scroll._overlordRefreshRail then
        scroll._overlordRefreshRail()
        return
    end
    local maxS = scroll:GetVerticalScrollRange() or 0
    local cur = scroll:GetVerticalScroll() or 0
    local can = maxS > 2
    downT:SetShown(can and cur < maxS - 1)
    upT:SetShown(can and cur > 1)
end

-- Passe globale reservee aux changements de donnees/layout. Pendant un scroll, seul le rail
-- concerne est recalcule afin de ne pas repositionner six poignees a chaque pixel de drag.
function Overlord.LeaderboardUI:UpdateCaptureScrollIndicators()
    if not lbFrame then return end
    if lbFrame.scrollKills then
        UpdateLeaderboardScrollIndicator(
            lbFrame.scrollKills, lbFrame.killsScrollIndUp, lbFrame.killsScrollIndDown)
    end
    if lbFrame.scrollAlli then
        UpdateLeaderboardScrollIndicator(
            lbFrame.scrollAlli, lbFrame.alliScrollIndUp, lbFrame.alliScrollIndDown)
        UpdateLeaderboardScrollIndicator(
            lbFrame.scrollHorde, lbFrame.hordeScrollIndUp, lbFrame.hordeScrollIndDown)
    end
    if lbFrame.scrollGuild then
        UpdateLeaderboardScrollIndicator(
            lbFrame.scrollGuild, lbFrame.guildScrollIndUp, lbFrame.guildScrollIndDown)
    end
    if lbFrame.scrollGuildKeep then
        UpdateLeaderboardScrollIndicator(
            lbFrame.scrollGuildKeep, lbFrame.guildKeepScrollIndUp, lbFrame.guildKeepScrollIndDown)
    end
    if lbFrame.scrollOutpost then
        UpdateLeaderboardScrollIndicator(
            lbFrame.scrollOutpost, lbFrame.outpostScrollIndUp, lbFrame.outpostScrollIndDown)
    end
end

-- Palette style roster officiel (cachee, calculee une seule fois par session)
local cachedPalette = nil
local function GetPalette()
    if cachedPalette then return cachedPalette end
    cachedPalette = {
        bg       = {0.047, 0.047, 0.047, 0.96},
        panel    = {0.062, 0.062, 0.062, 0.98},
        header   = {0.047, 0.047, 0.047, 0.85},
        accent   = {0.973, 0.718, 0.0},
        accentDm = {0.55, 0.40, 0.0},
        muted    = {0.478, 0.420, 0.365},
        faction  = (Overlord.PlayerFaction == "Horde")
            and {0.749, 0.290, 0.290} or {0.290, 0.478, 0.749},
        bright   = (Overlord.PlayerFaction == "Horde")
            and {1.0, 0.40, 0.27} or {0.427, 0.702, 0.949},
        white    = {0.925, 0.937, 0.969},
        gray     = {0.478, 0.420, 0.365},
        rowEven  = {0.08, 0.07, 0.06, 0.55},
        rowOdd   = {0, 0, 0, 0},
        divider  = {0.15, 0.13, 0.11, 0.45},
    }
    return cachedPalette
end

local function ApplyOfficialHeaderColor(fs, P)
    if fs and P then
        fs:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    end
end

local function SetSecondaryTextColor(fs, P, medalColor)
    if not fs or not P then return end
    if medalColor then
        fs:SetTextColor(medalColor[1], medalColor[2], medalColor[3])
    else
        fs:SetTextColor(P.muted[1], P.muted[2], P.muted[3])
    end
end

local function CreateOfficialIconHolder(parent, size, P)
    local ui = Overlord.UI
    if ui and ui.CreateOfficialIconHolder then
        return ui.CreateOfficialIconHolder(parent, size, P and P.accent, { ring = false })
    end
end

local function ApplyRowDivider(row, P)
    if row.divider or not P then return end
    row.divider = row:CreateTexture(nil, "BORDER")
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", LB_ROW_PAD, 0)
    row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -LB_ROW_PAD, 0)
    row.divider:SetColorTexture(P.divider[1], P.divider[2], P.divider[3], P.divider[4] or 0.45)
end

-- Fond sombre plat + bordure doree discrete (style site Blizzard)
local function ApplyOfficialFrameBackdrop(frame, P)
    frame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(P.bg[1], P.bg[2], P.bg[3], P.bg[4] or 0.96)
    frame:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.28)
end

-- Sous-panneau plat (en-tete de colonnes ou zone de liste)
local function CreateOfficialSubPanel(parent, w, h, P, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(w, h)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile   = true,
        tileSize = 16,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    if opts.header then
        f:SetBackdropColor(P.header[1], P.header[2], P.header[3], P.header[4] or 0.85)
        f.bottomLine = f:CreateTexture(nil, "ARTWORK")
        f.bottomLine:SetHeight(1)
        f.bottomLine:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", LB_ROW_PAD, 0)
        f.bottomLine:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -LB_ROW_PAD, 0)
        f.bottomLine:SetColorTexture(P.divider[1], P.divider[2], P.divider[3], 0.5)
    else
        f:SetBackdropColor(P.panel[1], P.panel[2], P.panel[3], P.panel[4] or 0.98)
    end
    return f
end

-- Colonne gauche (kills + captures) ; guildes a droite, alignees sur toute la hauteur.
local function LayoutGuildScrollFill(panel, scroll)
    if not panel or not scroll then return end
    scroll:ClearAllPoints()
    scroll:SetPoint("TOP", panel, "TOP", 0, -4)
    scroll:SetPoint("BOTTOM", panel, "BOTTOM", 0, 4)
    scroll:SetPoint("LEFT", panel, "LEFT", 0, 0)
    scroll:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
end

local function LayoutGuildPanelFill()
    if not lbFrame then return end
    LayoutGuildScrollFill(lbFrame.guildPanel, lbFrame.scrollGuild)
    LayoutGuildScrollFill(lbFrame.guildKeepPanel, lbFrame.scrollGuildKeep)
    LayoutGuildScrollFill(lbFrame.outpostPanel, lbFrame.scrollOutpost)
end

local function LayoutLeaderboardSections()
    if not lbFrame then return end
    if lbSectionsLayoutDone then return end
    lbSectionsLayoutDone = true
    local header = lbFrame.headerBand
    local killsP = lbFrame.killsPanel
    local guildBlock = lbFrame.guildBlock
    local guildKeepBlock = lbFrame.guildKeepBlock
    local outpostBlock = lbFrame.outpostBlock
    local capPanel = lbFrame.capturesPanel
    local footer = lbFrame.footerBand
    local leftStack = lbFrame.leftStackAnchor
    if not (header and killsP and guildBlock and guildKeepBlock and outpostBlock and capPanel and footer and leftStack) then
        return
    end

    header:ClearAllPoints()
    header:SetPoint("TOP", lbFrame.totalText, "BOTTOM", 0, -10)
    header:SetPoint("LEFT", lbFrame, "LEFT", LB_FRAME_PAD, 0)

    killsP:ClearAllPoints()
    killsP:SetPoint("TOP", header, "BOTTOM", 0, -LB_GAP_HEADER)
    killsP:SetPoint("LEFT", lbFrame, "LEFT", LB_FRAME_PAD, 0)

    capPanel:ClearAllPoints()
    capPanel:SetPoint("TOP", killsP, "BOTTOM", 0, -LB_GAP_SECTION)
    capPanel:SetPoint("LEFT", lbFrame, "LEFT", LB_FRAME_PAD, 0)

    leftStack:ClearAllPoints()
    leftStack:SetPoint("TOPLEFT", header, "TOPLEFT")
    leftStack:SetPoint("BOTTOMRIGHT", capPanel, "BOTTOMRIGHT")

    -- Colonne tués guildes puis fortins (meme hauteur que la pile gauche)
    guildBlock:ClearAllPoints()
    guildBlock:SetPoint("LEFT", leftStack, "RIGHT", LB_COL_GAP, 0)
    guildBlock:SetPoint("TOP", header, "TOP", 0, 0)
    guildBlock:SetPoint("BOTTOM", capPanel, "BOTTOM", 0, 0)
    guildBlock:SetWidth(LB_GUILD_KILLS_W)

    guildKeepBlock:ClearAllPoints()
    guildKeepBlock:SetPoint("LEFT", guildBlock, "RIGHT", LB_COL_GAP, 0)
    guildKeepBlock:SetPoint("TOP", header, "TOP", 0, 0)
    guildKeepBlock:SetPoint("BOTTOM", capPanel, "BOTTOM", 0, 0)
    guildKeepBlock:SetWidth(LB_GUILD_KEEP_W)

    outpostBlock:ClearAllPoints()
    outpostBlock:SetPoint("LEFT", guildKeepBlock, "RIGHT", LB_COL_GAP, 0)
    outpostBlock:SetPoint("TOP", header, "TOP", 0, 0)
    outpostBlock:SetPoint("BOTTOM", capPanel, "BOTTOM", 0, 0)
    outpostBlock:SetWidth(LB_OUTPOST_W)

    LayoutGuildPanelFill()

    footer:ClearAllPoints()
    footer:SetPoint("TOP", capPanel, "BOTTOM", 0, -LB_GAP_SECTION)
    footer:SetPoint("LEFT", lbFrame, "LEFT", LB_FRAME_PAD, 0)
    footer:SetWidth(LB_MAIN_W + LB_COL_GAP + LB_GUILD_KILLS_W + LB_COL_GAP + LB_GUILD_KEEP_W
        + LB_COL_GAP + LB_OUTPOST_W)
end

-- Respecte l'echelle UI demandee sans jamais laisser le classement sortir de l'ecran.
local function FitLeaderboardFrameScale(preferredScale)
    if not lbFrame or not UIParent then return end
    preferredScale = tonumber(preferredScale) or lbFrame._preferredScale or 1
    if preferredScale <= 0 then preferredScale = 1 end
    lbFrame._preferredScale = preferredScale
    local availableW = math.max(1, (UIParent:GetWidth() or LB_FRAME_W) - 24)
    local availableH = math.max(1, (UIParent:GetHeight() or 500) - 24)
    local frameH = math.max(1, lbFrame:GetHeight() or 500)
    local fittedScale = math.max(
        0.1, math.min(preferredScale * LB_SIZE_BOOST, availableW / LB_FRAME_W, availableH / frameH))
    if math.abs((lbFrame:GetScale() or 1) - fittedScale) > 0.001 then
        lbFrame:SetScale(fittedScale)
    end
end

-- Ajuste la hauteur du cadre au contenu empile (evite le vide sous le pied de page).
local function FitLeaderboardFrameHeight()
    if not lbFrame or not lbFrame.footerBand then return end
    local frameTop = lbFrame:GetTop()
    local contentBottom = lbFrame.footerBand:GetBottom()
    if not frameTop or not contentBottom then return end
    local bottomPad = 28
    local currentScale = lbFrame:GetScale() or 1
    if currentScale <= 0 then currentScale = 1 end
    -- GetTop/GetBottom du cadre et de son enfant sont deja dans l'echelle du cadre :
    -- ne pas rediviser par l'echelle (le cadre etait trop court des qu'agrandi).
    local h = (frameTop - contentBottom) + bottomPad
    if h > 200 and math.abs(h - (lbFrame._lbFitHeight or 0)) > 0.5 then
        lbFrame._lbFitHeight = h
        lbFrame:SetHeight(h)
    end
    FitLeaderboardFrameScale(lbFrame._preferredScale or currentScale)
end

-- ---------- Preneurs et rivalites de la semaine (fiefs et avant-postes) ----------
-- Volet qui prend la place des tableaux Fiefs et Avant-postes le temps de le lire
-- (bouton dans l'en-tete des avant-postes). Donnees : le registre des prises signees,
-- deja local (Leaderboard:GetOutpostWeeklyStats), aucun paquet de plus.
local SitesWeek = {
    ROWS = 16,
    ICON = "Interface\\Icons\\INV_Scroll_03",
    RGB = { Alliance = { 0.427, 0.702, 0.949 }, Horde = { 1.0, 0.40, 0.27 } },
}

function SitesWeek.Colored(text, faction)
    local c = SitesWeek.RGB[faction]
    if not c then return text end
    return string.format("|cFF%02X%02X%02X%s|r", c[1] * 255, c[2] * 255, c[3] * 255, text)
end

function SitesWeek.ToggleButton(parent, tipTitle, tipBody)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 20)
    btn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(SitesWeek.ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    btn:SetScript("OnClick", function() Overlord.LeaderboardUI:ToggleSitesWeek() end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tipTitle or "", 1, 0.82, 0)
        if tipBody then GameTooltip:AddLine(tipBody, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    return btn
end

-- Une moitie du volet : bandeau de colonnes, panneau, lignes fixes defilees a la molette.
function SitesWeek.Half(view, P, anchorPoint, columns, emptyText)
    local header = CreateOfficialSubPanel(view, LB_GUILD_KEEP_W, LB_HEADER_H, P, { header = true })
    header:SetPoint(anchorPoint, view, anchorPoint, 0, 0)
    for _, col in ipairs(columns) do
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER", header, "CENTER", col.x, 0)
        fs:SetWidth(col.w)
        fs:SetJustifyH("CENTER")
        fs:SetText(col.text or "")
        ApplyOfficialHeaderColor(fs, P)
    end
    local panel = CreateOfficialSubPanel(view, LB_GUILD_KEEP_W, 400, P)
    panel:SetPoint("TOP", header, "BOTTOM", 0, -LB_GAP_HEADER)
    panel:SetPoint("BOTTOM", view, "BOTTOM", 0, 0)
    panel:SetPoint("LEFT", header, "LEFT", 0, 0)
    panel:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    local half = { header = header, panel = panel, rows = {}, offset = 0, list = {} }
    for i = 1, SitesWeek.ROWS do
        local row = CreateFrame("Frame", nil, panel)
        row:SetSize(LB_GUILD_KEEP_W - 8, GUILD_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4 - (i - 1) * GUILD_ROW_HEIGHT)
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(P.rowEven[1], P.rowEven[2], P.rowEven[3], P.rowEven[4])
        end
        row.cells = {}
        for c, col in ipairs(columns) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("CENTER", row, "CENTER", col.x, 0)
            fs:SetWidth(col.w)
            fs:SetJustifyH(col.justify or "CENTER")
            fs:SetWordWrap(false)
            row.cells[c] = fs
        end
        row:Hide()
        half.rows[i] = row
    end
    half.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    half.empty:SetPoint("CENTER", panel, "CENTER", 0, 0)
    half.empty:SetWidth(LB_GUILD_KEEP_W - 24)
    half.empty:SetText(emptyText or "")
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        half.offset = math.max(0, math.min(half.offset - delta * 3, #half.list - 1))
        Overlord.LeaderboardUI:RefreshSitesWeek()
    end)
    return half
end

function SitesWeek.Paint(half, fill)
    local visible = math.max(1, math.floor(((half.panel:GetHeight() or 0) - 8) / GUILD_ROW_HEIGHT))
    visible = math.min(visible, SitesWeek.ROWS)
    half.offset = math.max(0, math.min(half.offset, #half.list - visible))
    for i = 1, SitesWeek.ROWS do
        local index = half.offset + i
        local entry = i <= visible and half.list[index] or nil
        local row = half.rows[i]
        if entry then
            fill(row.cells, entry, index)
            row:Show()
        else
            row:Hide()
        end
    end
    half.empty:SetShown(#half.list == 0)
end

function Overlord.LeaderboardUI:CreateSitesWeekView(P)
    if not lbFrame or lbFrame.sitesWeek then return end
    local view = CreateFrame("Frame", nil, lbFrame)
    view:SetPoint("TOPLEFT", lbFrame.guildKeepBlock, "TOPLEFT", 0, 0)
    view:SetPoint("BOTTOMRIGHT", lbFrame.outpostBlock, "BOTTOMRIGHT", 0, 0)
    view:Hide()
    lbFrame.sitesWeek = view
    -- Gauche : preneurs (rang, joueur, fiefs, avant-postes).
    view.capturers = SitesWeek.Half(view, P, "TOPLEFT", {
        { x = -150, w = 32, text = "#" },
        { x = -40, w = 180, text = L.SITES_WEEK_COL_CAPTURERS or "Capturers this week", justify = "LEFT" },
        { x = 80, w = 60, text = L.LB_COL_KEEP or "Keep" },
        { x = 145, w = 60, text = L.LB_COL_OUTPOST or "Outpost" },
    }, L.SITES_WEEK_EMPTY_CAPTURERS)
    -- Droite : rivalites (guilde qui prend, guilde qui perd, nombre de prises).
    view.rivalries = SitesWeek.Half(view, P, "TOPRIGHT", {
        { x = -150, w = 32, text = "#" },
        { x = -30, w = 200, text = L.SITES_WEEK_COL_RIVALRIES or "Rivalries this week", justify = "LEFT" },
        { x = 110, w = 50, text = L.LB_COL_CAPTURES or "Captures" },
    }, L.SITES_WEEK_EMPTY_RIVALRIES)
    SitesWeek.ToggleButton(view.rivalries.header, L.SITES_WEEK_BACK or "Back")
    SitesWeek.ToggleButton(lbFrame.outpostHeaderBand, L.SITES_WEEK_TIP_TITLE, L.SITES_WEEK_TIP_BODY)
    lbFrame:HookScript("OnHide", function()
        if lbFrame.sitesWeek and lbFrame.sitesWeek:IsShown() then Overlord.LeaderboardUI:ToggleSitesWeek() end
    end)
end

function Overlord.LeaderboardUI:ToggleSitesWeek()
    local view = lbFrame and lbFrame.sitesWeek
    if not view then return end
    local show = not view:IsShown()
    view:SetShown(show)
    lbFrame.guildKeepBlock:SetShown(not show)
    lbFrame.outpostBlock:SetShown(not show)
    if show then
        view.capturers.offset, view.rivalries.offset = 0, 0
        self:RefreshSitesWeek()
    end
end

function Overlord.LeaderboardUI:RefreshSitesWeek()
    local view = lbFrame and lbFrame.sitesWeek
    local lb = Overlord.Leaderboard
    if not view or not view:IsShown() or not lb or not lb.GetOutpostWeeklyStats then return end
    local stats, late = lb:GetOutpostWeeklyStats()
    if late and not view.rereadPending and C_Timer and C_Timer.After then
        view.rereadPending = true
        C_Timer.After(3, function()
            view.rereadPending = nil
            Overlord.LeaderboardUI:RefreshSitesWeek()
        end)
    end
    view.capturers.list = stats.capturers or {}
    view.rivalries.list = stats.rivalries or {}
    local nameW = 150
    SitesWeek.Paint(view.capturers, function(cells, c, index)
        cells[1]:SetText(index)
        local short = Ambiguate and Ambiguate(c.name, "short") or c.name
        cells[2]:SetText(LbCrestMarkup(c.faction, 14) .. " "
            .. SitesWeek.Colored(TruncateTextToWidth(short, nameW, "GameFontNormal"), c.faction))
        cells[3]:SetText(c.keeps > 0 and c.keeps or "-")
        cells[4]:SetText(c.outposts > 0 and c.outposts or "-")
    end)
    SitesWeek.Paint(view.rivalries, function(cells, r, index)
        cells[1]:SetText(index)
        local half = 88
        cells[2]:SetText(SitesWeek.Colored(TruncateTextToWidth(r.taker, half, "GameFontNormal"), r.takerFaction)
            .. " |cFFB0A080>|r "
            .. SitesWeek.Colored(TruncateTextToWidth(r.victim, half, "GameFontNormal"), r.victimFaction))
        cells[3]:SetText(r.count)
    end)
end

function Overlord.LeaderboardUI:CreateFrame()
    local P = GetPalette()

    lbFrame = CreateFrame("Frame", "OverlordLeaderboardFrame", UIParent, "BackdropTemplate")
    if Overlord.UI.AttachOpenFade then Overlord.UI.AttachOpenFade(lbFrame) end
    lbFrame:SetSize(LB_FRAME_W, 500)
    lbFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    ApplyOfficialFrameBackdrop(lbFrame, P)
    lbFrame:EnableMouse(true)
    lbFrame:SetMovable(true)
    lbFrame:RegisterForDrag("LeftButton")
    lbFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    lbFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    lbFrame:SetFrameStrata("HIGH")
    lbFrame:SetFrameLevel(50)
    lbFrame:SetClampedToScreen(true)
    lbFrame._preferredScale = 1
    lbFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
    lbFrame:RegisterEvent("UI_SCALE_CHANGED")
    lbFrame:SetScript("OnEvent", function()
        FitLeaderboardFrameScale(lbFrame._preferredScale)
    end)

    -- Titre (or officiel Blizzard)
    local title = lbFrame:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    title:SetPoint("TOP", 0, -27)
    title:SetText(L.LB_TITLE)
    title:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    title:SetShadowOffset(1, -1)
    title:SetShadowColor(0, 0, 0, 0.6)

    -- Sous-titre : date de la campagne, lisible (creme, taille normale).
    lbFrame.subtitle = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbFrame.subtitle:SetPoint("TOP", title, "BOTTOM", 0, -3)
    local startDate, endDate = Overlord:GetCampaignDateRange()
    lbFrame.subtitle:SetText(string.format(L.LB_CAMPAIGN_DATE, startDate, endDate))
    lbFrame.subtitle:SetTextColor(0.95, 0.88, 0.70, 1)
    lbFrame.subtitle:SetShadowOffset(1, -1)

    -- Kills Alliance / Horde sous la campagne (blasons de part et d'autre).
    lbFrame.totalText = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbFrame.totalText:SetPoint("TOP", lbFrame.subtitle, "BOTTOM", 0, -6)
    lbFrame.totalText:SetTextColor(P.white[1], P.white[2], P.white[3])
    -- Cadre en bois neutre des panneaux Blizzard, sur une couche a part : le fond
    -- actuel reste dessous.
    lbFrame.bgBorder = Overlord.UI.ApplyWoodenNeutralFrame
        and Overlord.UI.ApplyWoodenNeutralFrame(lbFrame)

    -- Reuse the existing panel texture and fonts. No search icon/atlas or ticker.
    local searchPanel = CreateOfficialSubPanel(lbFrame, 266, 28, P, { header = true })
    searchPanel:SetPoint("TOPLEFT", lbFrame, "TOPLEFT", LB_FRAME_PAD, -20)
    local searchBox = CreateFrame("EditBox", nil, searchPanel)
    lbFrame.searchBox = searchBox
    searchBox:SetPoint("TOPLEFT", 10, -2)
    searchBox:SetPoint("BOTTOMRIGHT", -30, 2)
    searchBox:SetFontObject("GameFontHighlightSmall")
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(64)
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    placeholder:SetPoint("LEFT")
    placeholder:SetText(L.LB_SEARCH_PLACEHOLDER or "Player or guild...")
    placeholder:SetTextColor(P.muted[1], P.muted[2], P.muted[3])
    local clear = CreateFrame("Button", nil, searchPanel)
    lbFrame.searchClear = clear
    clear:SetSize(26, 24)
    clear:SetPoint("RIGHT", -2, 0)
    clear:SetNormalFontObject("GameFontNormal")
    clear:SetHighlightFontObject("GameFontHighlight")
    clear:SetText("×")
    clear:Hide()
    clear:SetScript("OnClick", function() searchBox:SetText(""); searchBox:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(box)
        local text = box:GetText() or ""
        placeholder:SetShown(text == "")
        clear:SetShown(text ~= "")
        Overlord.LeaderboardUI:SetSearchText(text)
    end)
    searchBox:SetScript("OnEscapePressed", function(box) box:SetText(""); box:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    searchBox:SetScript("OnHide", function(box) box:ClearFocus() end)
    -- Campagne en cours (ruleset) : les joueurs savent dans quelle campagne ils sont.
    local rulesetLabel = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rulesetLabel:SetPoint("LEFT", searchPanel, "RIGHT", 10, 0)
    rulesetLabel:SetJustifyH("LEFT")
    rulesetLabel:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    local ruleset = Overlord.RealmPools and Overlord.RealmPools.GetRuleset and Overlord.RealmPools:GetRuleset() or "pvp"
    local rulesetNames = {
        pvp = L.RULESET_NAME_PVP or "PvP", normal = L.RULESET_NAME_NORMAL or "Normal",
        rp = L.RULESET_NAME_RP or "RP", hardcore = L.RULESET_NAME_HARDCORE or "Hardcore",
    }
    rulesetLabel:SetText(string.format(L.LB_RULESET_LABEL or "%s ruleset", rulesetNames[ruleset] or tostring(ruleset)))
    lbFrame.rulesetLabel = rulesetLabel
    lbFrame.searchStatus = searchPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- A cote du ruleset (sous la recherche se trouvent les infos de campagne).
    lbFrame.searchStatus:SetPoint("LEFT", rulesetLabel, "RIGHT", 14, 0)
    lbFrame.searchStatus:SetTextColor(P.muted[1], P.muted[2], P.muted[3])
    lbFrame:SetScript("OnHide", function()
        if lbFrame.search then lbFrame.search:Cancel() end
        if lbFrame.infoTicker then lbFrame.infoTicker:Cancel(); lbFrame.infoTicker = nil end
    end)

    -- Infos de part et d'autre du titre (donnees deja locales, aucun paquet), sur les
    -- deux lignes du centre (date de campagne, totaux) : a gauche la campagne, a droite
    -- le joueur et sa guilde, meme police que le centre.
    local function InfoLine(row, side)
        local fs = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        -- Un seul point : les lignes du centre sont centrees sur le cadre, donc leur
        -- haut-centre est au milieu ; on se decale jusqu'a la marge.
        local reach = LB_FRAME_W / 2 - LB_FRAME_PAD - 4
        if side == "LEFT" then
            fs:SetPoint("TOPLEFT", row, "TOP", -reach, 0)
        else
            fs:SetPoint("TOPRIGHT", row, "TOP", reach, 0)
        end
        fs:SetJustifyH(side)
        fs:SetWidth(440)
        fs:SetWordWrap(false)
        fs:SetMaxLines(1)
        fs:SetShadowOffset(1, -1)
        return fs
    end
    lbFrame.infoLeft = { InfoLine(lbFrame.subtitle, "LEFT"), InfoLine(lbFrame.totalText, "LEFT") }
    lbFrame.infoRight = { InfoLine(lbFrame.subtitle, "RIGHT"), InfoLine(lbFrame.totalText, "RIGHT") }
    lbFrame:HookScript("OnShow", function()
        if lbFrame.infoTicker or not (C_Timer and C_Timer.NewTicker) then return end
        lbFrame.infoTicker = C_Timer.NewTicker(30, function()
            if lbFrame:IsShown() then Overlord.LeaderboardUI:RefreshInfoLines() end
        end)
    end)

    -- En-tetes de colonnes (bandeau sombre, meme largeur que les lignes)
    lbFrame.leftStackAnchor = CreateFrame("Frame", nil, lbFrame)
    lbFrame.leftStackAnchor:Hide()

    local headerBand = CreateOfficialSubPanel(lbFrame, LB_MAIN_W, LB_HEADER_H, P, { header = true })
    headerBand:SetPoint("TOP", lbFrame.subtitle, "BOTTOM", 0, -6)
    lbFrame.headerBand = headerBand
    local killCols = GetKillLayoutSegments()
    local hRank = headerBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hRank:SetPoint("CENTER", headerBand, "LEFT", killCols.rank.center, 0)
    hRank:SetWidth(killCols.rank.width)
    hRank:SetJustifyH("CENTER")
    hRank:SetText("#")
    ApplyOfficialHeaderColor(hRank, P)

    local hRace = headerBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hRace:SetPoint("CENTER", headerBand, "LEFT", killCols.race.center, 0)
    hRace:SetWidth(killCols.race.width)
    hRace:SetJustifyH("CENTER")
    hRace:SetText(L.LB_COL_RACE)
    ApplyOfficialHeaderColor(hRace, P)

    local hClass = headerBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hClass:SetPoint("CENTER", headerBand, "LEFT", killCols.class.center, 0)
    hClass:SetWidth(killCols.class.width)
    hClass:SetJustifyH("CENTER")
    hClass:SetText(L.LB_COL_CLASS)
    ApplyOfficialHeaderColor(hClass, P)

    local hName = headerBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hName:SetPoint("CENTER", headerBand, "LEFT", killCols.player.center, 0)
    hName:SetWidth(killCols.player.width)
    hName:SetJustifyH("CENTER")
    hName:SetText(L.LB_COL_PLAYER)
    ApplyOfficialHeaderColor(hName, P)

    local hKills = headerBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hKills:SetPoint("CENTER", headerBand, "LEFT", killCols.kills.center, 0)
    hKills:SetWidth(killCols.kills.width)
    hKills:SetJustifyH("CENTER")
    hKills:SetText(L.LB_COL_KILLS)
    ApplyOfficialHeaderColor(hKills, P)

    -- Classement kills : 10 lignes visibles, defilement molette comme les captures
    local killsViewportH = MAX_VISIBLE_KILL_ROWS * KILL_ROW_HEIGHT
    lbFrame.killsViewportH = killsViewportH

    local killsPanel = CreateOfficialSubPanel(lbFrame, LB_MAIN_W, killsViewportH + 8, P)
    killsPanel:SetPoint("TOP", headerBand, "BOTTOM", 0, -4)
    lbFrame.killsPanel = killsPanel

    local scrollKills = CreateFrame("ScrollFrame", "OverlordLBScrollKills", killsPanel)
    scrollKills:SetSize(LB_MAIN_W, killsViewportH)
    scrollKills:SetPoint("TOP", killsPanel, "TOP", 0, -4)
    scrollKills:EnableMouse(true)
    scrollKills:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.LB_KILLS_SCROLL_TOOLTIP, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    scrollKills:SetScript("OnLeave", GameTooltip_Hide)
    scrollKills:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = KILL_ROW_HEIGHT * 3
        local newVal = cur - delta * step
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
    end)
    scrollKills:HookScript("OnVerticalScroll", function()
        if RenderKillRows then RenderKillRows(false) end
        UpdateLeaderboardScrollIndicator(
            scrollKills, lbFrame.killsScrollIndUp, lbFrame.killsScrollIndDown)
    end)

    local scrollChildKills = CreateFrame("Frame", nil, scrollKills)
    scrollChildKills:SetWidth(LB_MAIN_W)
    scrollChildKills:SetHeight(killsViewportH)
    scrollKills:SetScrollChild(scrollChildKills)
    lbFrame.killsScrollIndUp, lbFrame.killsScrollIndDown =
        CreateScrollIndicators(killsPanel, scrollKills)
    AttachCleanScrollRail(scrollKills, killsPanel,
        lbFrame.killsScrollIndUp, lbFrame.killsScrollIndDown, P)

    lbFrame.scrollKills = scrollKills
    lbFrame.scrollChildKills = scrollChildKills

    -- Conteneur captures dans un sous-panneau WC3
    local capturesBlockH = 200
    local captureScrollBottomInset = 14

    -- Classement guildes (tués) : colonne droite, hauteur = kills + captures
    local guildBlock = CreateFrame("Frame", nil, lbFrame)
    guildBlock:SetSize(LB_GUILD_KILLS_W, 400)
    lbFrame.guildBlock = guildBlock

    local guildHeaderBand = CreateOfficialSubPanel(guildBlock, LB_GUILD_KILLS_W, LB_HEADER_H, P, { header = true })
    guildHeaderBand:SetPoint("TOP", guildBlock, "TOP", 0, 0)
    lbFrame.guildHeaderBand = guildHeaderBand
    local ghRank = guildHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ghRank:SetPoint("CENTER", guildHeaderBand, "CENTER", LB_GUILD_COL_RANK, 0)
    ghRank:SetWidth(LB_GUILD_RANK_W)
    ghRank:SetJustifyH("CENTER")
    ghRank:SetText("#")
    ApplyOfficialHeaderColor(ghRank, P)
    local ghName = guildHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ghName:SetPoint("CENTER", guildHeaderBand, "CENTER", LB_GUILD_COL_NAME, 0)
    ghName:SetWidth(LB_GUILD_NAME_W)
    ghName:SetJustifyH("CENTER")
    ghName:SetText(L.LB_COL_GUILD or "Guild")
    ApplyOfficialHeaderColor(ghName, P)
    -- Membres classes de la guilde : un gros total vient souvent d'une grosse guilde.
    local ghMembers = guildHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ghMembers:SetPoint("CENTER", guildHeaderBand, "CENTER", LB_GUILD_COL_MEMBERS, 0)
    ghMembers:SetWidth(LB_GUILD_MEMBERS_W)
    ghMembers:SetJustifyH("CENTER")
    ghMembers:SetText(L.LB_COL_MEMBERS or "Members")
    ApplyOfficialHeaderColor(ghMembers, P)
    local ghKills = guildHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ghKills:SetPoint("CENTER", guildHeaderBand, "CENTER", LB_GUILD_COL_KILLS, 0)
    ghKills:SetWidth(LB_GUILD_KILLS_TEXT_W)
    ghKills:SetJustifyH("CENTER")
    ghKills:SetText(L.LB_COL_KILLS)
    ApplyOfficialHeaderColor(ghKills, P)

    local guildPanel = CreateOfficialSubPanel(guildBlock, LB_GUILD_KILLS_W, 400, P)
    guildPanel:SetPoint("TOP", guildHeaderBand, "BOTTOM", 0, -LB_GAP_HEADER)
    guildPanel:SetPoint("BOTTOM", guildBlock, "BOTTOM", 0, 0)
    guildPanel:SetPoint("LEFT", guildBlock, "LEFT", 0, 0)
    guildPanel:SetPoint("RIGHT", guildBlock, "RIGHT", 0, 0)
    lbFrame.guildPanel = guildPanel

    local scrollGuild = CreateFrame("ScrollFrame", "OverlordLBScrollGuild", guildPanel)
    scrollGuild:EnableMouse(true)
    scrollGuild:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.LB_KILLS_SCROLL_TOOLTIP, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    scrollGuild:SetScript("OnLeave", GameTooltip_Hide)
    scrollGuild:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = GUILD_ROW_HEIGHT * 3
        local newVal = cur - delta * step
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
    end)
    scrollGuild:HookScript("OnVerticalScroll", function()
        if RenderGuildRows then RenderGuildRows(false) end
        UpdateLeaderboardScrollIndicator(
            scrollGuild, lbFrame.guildScrollIndUp, lbFrame.guildScrollIndDown)
    end)

    local scrollChildGuild = CreateFrame("Frame", nil, scrollGuild)
    scrollChildGuild:SetWidth(LB_GUILD_KILLS_W)
    scrollChildGuild:SetHeight(GUILD_ROW_HEIGHT * 10)
    scrollGuild:SetScrollChild(scrollChildGuild)
    lbFrame.guildScrollIndUp, lbFrame.guildScrollIndDown =
        CreateScrollIndicators(guildPanel, scrollGuild)
    AttachCleanScrollRail(scrollGuild, guildPanel,
        lbFrame.guildScrollIndUp, lbFrame.guildScrollIndDown, P)

    lbFrame.scrollGuild = scrollGuild
    lbFrame.scrollChildGuild = scrollChildGuild

    lbFrame.guildEmptyHint = guildPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lbFrame.guildEmptyHint:SetPoint("CENTER", scrollGuild, "CENTER", 0, 0)
    lbFrame.guildEmptyHint:SetWidth(LB_GUILD_KILLS_W - 24)
    lbFrame.guildEmptyHint:SetJustifyH("CENTER")
    lbFrame.guildEmptyHint:SetTextColor(P.gray[1], P.gray[2], P.gray[3], 0.85)
    lbFrame.guildEmptyHint:SetText(L.LB_GUILD_EMPTY or "")
    lbFrame.guildEmptyHint:Hide()

    -- Fortins guildes : 3e colonne a droite du tableau tués
    local guildKeepBlock = CreateFrame("Frame", nil, lbFrame)
    guildKeepBlock:SetSize(LB_GUILD_KEEP_W, 400)
    lbFrame.guildKeepBlock = guildKeepBlock

    local guildKeepHeaderBand = CreateOfficialSubPanel(guildKeepBlock, LB_GUILD_KEEP_W, LB_HEADER_H, P, { header = true })
    guildKeepHeaderBand:SetPoint("TOP", guildKeepBlock, "TOP", 0, 0)
    lbFrame.guildKeepHeaderBand = guildKeepHeaderBand
    local gkhKeep = guildKeepHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gkhKeep:SetPoint("CENTER", guildKeepHeaderBand, "CENTER", LB_GK_COL_KEEP, 0)
    gkhKeep:SetWidth(GUILD_KEEP_ICON + 4 + LB_GK_KEEP_NAME_W)
    gkhKeep:SetJustifyH("CENTER")
    gkhKeep:SetText(L.LB_COL_KEEP or "Keep")
    ApplyOfficialHeaderColor(gkhKeep, P)
    local gkhGuild = guildKeepHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gkhGuild:SetPoint("CENTER", guildKeepHeaderBand, "CENTER", LB_GK_COL_GUILD, 0)
    gkhGuild:SetWidth(LB_GK_GUILD_NAME_W)
    gkhGuild:SetJustifyH("CENTER")
    gkhGuild:SetText(L.LB_COL_GUILD or "Guild")
    ApplyOfficialHeaderColor(gkhGuild, P)
    local gkhWins = guildKeepHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gkhWins:SetPoint("CENTER", guildKeepHeaderBand, "CENTER", LB_GK_COL_WINS, 0)
    gkhWins:SetWidth(LB_GK_WINS_W)
    gkhWins:SetJustifyH("CENTER")
    gkhWins:SetText(L.LB_COL_CAPTURES or "Captures")
    ApplyOfficialHeaderColor(gkhWins, P)

    local guildKeepPanel = CreateOfficialSubPanel(guildKeepBlock, LB_GUILD_KEEP_W, 400, P)
    guildKeepPanel:SetPoint("TOP", guildKeepHeaderBand, "BOTTOM", 0, -LB_GAP_HEADER)
    guildKeepPanel:SetPoint("BOTTOM", guildKeepBlock, "BOTTOM", 0, 0)
    guildKeepPanel:SetPoint("LEFT", guildKeepBlock, "LEFT", 0, 0)
    guildKeepPanel:SetPoint("RIGHT", guildKeepBlock, "RIGHT", 0, 0)
    lbFrame.guildKeepPanel = guildKeepPanel

    local scrollGuildKeep = CreateFrame("ScrollFrame", "OverlordLBScrollGuildKeep", guildKeepPanel)
    scrollGuildKeep:EnableMouse(true)
    scrollGuildKeep:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.LB_KILLS_SCROLL_TOOLTIP, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    scrollGuildKeep:SetScript("OnLeave", GameTooltip_Hide)
    scrollGuildKeep:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = GUILD_ROW_HEIGHT * 3
        local newVal = cur - delta * step
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
    end)
    scrollGuildKeep:HookScript("OnVerticalScroll", function()
        if RenderGuildKeepRows then RenderGuildKeepRows(false) end
        UpdateLeaderboardScrollIndicator(
            scrollGuildKeep, lbFrame.guildKeepScrollIndUp, lbFrame.guildKeepScrollIndDown)
    end)

    local scrollChildGuildKeep = CreateFrame("Frame", nil, scrollGuildKeep)
    scrollChildGuildKeep:SetWidth(LB_GUILD_KEEP_W)
    scrollChildGuildKeep:SetHeight(GUILD_ROW_HEIGHT * 10)
    scrollGuildKeep:SetScrollChild(scrollChildGuildKeep)
    lbFrame.guildKeepScrollIndUp, lbFrame.guildKeepScrollIndDown =
        CreateScrollIndicators(guildKeepPanel, scrollGuildKeep)
    AttachCleanScrollRail(scrollGuildKeep, guildKeepPanel,
        lbFrame.guildKeepScrollIndUp, lbFrame.guildKeepScrollIndDown, P)

    lbFrame.scrollGuildKeep = scrollGuildKeep
    lbFrame.scrollChildGuildKeep = scrollChildGuildKeep

    lbFrame.guildKeepEmptyHint = guildKeepPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lbFrame.guildKeepEmptyHint:SetPoint("CENTER", scrollGuildKeep, "CENTER", 0, 0)
    lbFrame.guildKeepEmptyHint:SetWidth(LB_GUILD_KEEP_W - 16)
    lbFrame.guildKeepEmptyHint:SetJustifyH("CENTER")
    lbFrame.guildKeepEmptyHint:SetTextColor(P.gray[1], P.gray[2], P.gray[3], 0.85)
    lbFrame.guildKeepEmptyHint:SetText(L.LB_GUILD_KEEP_EMPTY or "")
    lbFrame.guildKeepEmptyHint:Hide()

    -- Avant-postes : 4e colonne a droite des fortins
    local outpostBlock = CreateFrame("Frame", nil, lbFrame)
    outpostBlock:SetSize(LB_OUTPOST_W, 400)
    lbFrame.outpostBlock = outpostBlock

    local outpostHeaderBand = CreateOfficialSubPanel(outpostBlock, LB_OUTPOST_W, LB_HEADER_H, P, { header = true })
    outpostHeaderBand:SetPoint("TOP", outpostBlock, "TOP", 0, 0)
    lbFrame.outpostHeaderBand = outpostHeaderBand
    local ophOutpost = outpostHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ophOutpost:SetPoint("CENTER", outpostHeaderBand, "CENTER", LB_OP_COL_OUTPOST, 0)
    ophOutpost:SetWidth(GUILD_KEEP_ICON + 4 + LB_OP_OUTPOST_NAME_W)
    ophOutpost:SetJustifyH("CENTER")
    ophOutpost:SetText(L.LB_COL_OUTPOST or "Outpost")
    ApplyOfficialHeaderColor(ophOutpost, P)
    local ophGuild = outpostHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ophGuild:SetPoint("CENTER", outpostHeaderBand, "CENTER", LB_OP_COL_GUILD, 0)
    ophGuild:SetWidth(LB_OP_GUILD_NAME_W)
    ophGuild:SetJustifyH("CENTER")
    ophGuild:SetText(L.LB_COL_GUILD or "Guild")
    ApplyOfficialHeaderColor(ophGuild, P)
    local ophCaptures = outpostHeaderBand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ophCaptures:SetPoint("CENTER", outpostHeaderBand, "CENTER", LB_OP_COL_CAPTURES, 0)
    ophCaptures:SetWidth(LB_OP_CAPTURES_W)
    ophCaptures:SetJustifyH("CENTER")
    ophCaptures:SetText(L.LB_COL_CAPTURES or "Captures")
    ApplyOfficialHeaderColor(ophCaptures, P)

    local outpostPanel = CreateOfficialSubPanel(outpostBlock, LB_OUTPOST_W, 400, P)
    outpostPanel:SetPoint("TOP", outpostHeaderBand, "BOTTOM", 0, -LB_GAP_HEADER)
    outpostPanel:SetPoint("BOTTOM", outpostBlock, "BOTTOM", 0, 0)
    outpostPanel:SetPoint("LEFT", outpostBlock, "LEFT", 0, 0)
    outpostPanel:SetPoint("RIGHT", outpostBlock, "RIGHT", 0, 0)
    lbFrame.outpostPanel = outpostPanel

    local scrollOutpost = CreateFrame("ScrollFrame", "OverlordLBScrollOutpost", outpostPanel)
    scrollOutpost:EnableMouse(true)
    scrollOutpost:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.LB_KILLS_SCROLL_TOOLTIP, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    scrollOutpost:SetScript("OnLeave", GameTooltip_Hide)
    scrollOutpost:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = GUILD_ROW_HEIGHT * 3
        local newVal = cur - delta * step
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
    end)
    scrollOutpost:HookScript("OnVerticalScroll", function()
        if RenderOutpostRows then RenderOutpostRows(false) end
        UpdateLeaderboardScrollIndicator(
            scrollOutpost, lbFrame.outpostScrollIndUp, lbFrame.outpostScrollIndDown)
    end)

    local scrollChildOutpost = CreateFrame("Frame", nil, scrollOutpost)
    scrollChildOutpost:SetWidth(LB_OUTPOST_W)
    scrollChildOutpost:SetHeight(GUILD_ROW_HEIGHT * 10)
    scrollOutpost:SetScrollChild(scrollChildOutpost)
    lbFrame.outpostScrollIndUp, lbFrame.outpostScrollIndDown =
        CreateScrollIndicators(outpostPanel, scrollOutpost)
    AttachCleanScrollRail(scrollOutpost, outpostPanel,
        lbFrame.outpostScrollIndUp, lbFrame.outpostScrollIndDown, P)

    lbFrame.scrollOutpost = scrollOutpost
    lbFrame.scrollChildOutpost = scrollChildOutpost

    lbFrame.outpostEmptyHint = outpostPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lbFrame.outpostEmptyHint:SetPoint("CENTER", scrollOutpost, "CENTER", 0, 0)
    lbFrame.outpostEmptyHint:SetWidth(LB_OUTPOST_W - 16)
    lbFrame.outpostEmptyHint:SetJustifyH("CENTER")
    lbFrame.outpostEmptyHint:SetTextColor(P.gray[1], P.gray[2], P.gray[3], 0.85)
    lbFrame.outpostEmptyHint:SetText(L.LB_OUTPOST_EMPTY or "")
    lbFrame.outpostEmptyHint:Hide()
    self:CreateSitesWeekView(P)

    -- Pied de page (positionne par LayoutLeaderboardSections)
    local footerBand = CreateOfficialSubPanel(lbFrame,
        LB_MAIN_W + LB_COL_GAP + LB_GUILD_KILLS_W + LB_COL_GAP + LB_GUILD_KEEP_W + LB_COL_GAP + LB_OUTPOST_W,
        28, P)
    lbFrame.footerBand = footerBand

    local capturesPanel = CreateOfficialSubPanel(lbFrame, LB_MAIN_W, capturesBlockH + 10, P)
    lbFrame.capturesPanel = capturesPanel

    local capturesContainer = CreateFrame("Frame", nil, capturesPanel)
    capturesContainer:SetSize(LB_MAIN_W, capturesBlockH)
    capturesContainer:SetPoint("TOP", capturesPanel, "TOP", 0, -6)
    capturesContainer:SetPoint("LEFT", capturesPanel, "LEFT", 4, 0)
    lbFrame.capturesContainer = capturesContainer

    -- Separateur vertical entre les deux colonnes captures
    local colDivider = capturesContainer:CreateTexture(nil, "ARTWORK")
    colDivider:SetColorTexture(P.divider[1], P.divider[2], P.divider[3], 0.35)
    colDivider:SetSize(1, capturesBlockH - 12)
    colDivider:SetPoint("CENTER", capturesContainer, "CENTER", 0, -6)

    local colWidth = LB_CAPTURE_PANEL_W

    -- Colonne gauche : Alliance - Captures (scroll a la molette uniquement)
    local leftCol = CreateFrame("Frame", nil, capturesContainer)
    leftCol:SetSize(colWidth, capturesBlockH)
    leftCol:SetPoint("LEFT", capturesContainer, "LEFT", 0, 0)

    lbFrame.captionAlli = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbFrame.captionAlli:SetPoint("TOP", leftCol, "TOP", 0, -2)
    lbFrame.captionAlli:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    lbFrame.captionAlli:SetText(LbCrestMarkup("Alliance", 18) .. " " .. (L.LB_CAPTURES_ALLIANCE or "Alliance: Captures"))

    local captureScrollViewportH = capturesBlockH - 16 - captureScrollBottomInset

    local scrollAlli = CreateFrame("ScrollFrame", "OverlordLBScrollAlli", leftCol)
    scrollAlli:SetSize(colWidth, captureScrollViewportH)
    scrollAlli:SetPoint("TOP", leftCol, "TOP", 0, -16)
    scrollAlli:EnableMouse(true)
    scrollAlli:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(L.LB_CAPTURES_SCROLL_TOOLTIP, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    scrollAlli:SetScript("OnLeave", GameTooltip_Hide)
    scrollAlli:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = CAPTURE_ROW_HEIGHT * 3
        local newVal = cur - delta * step
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
    end)
    scrollAlli:HookScript("OnVerticalScroll", function()
        if RenderCaptureRows then RenderCaptureRows("Alliance", false) end
        UpdateLeaderboardScrollIndicator(
            scrollAlli, lbFrame.alliScrollIndUp, lbFrame.alliScrollIndDown)
    end)

    local scrollChildAlli = CreateFrame("Frame", nil, scrollAlli)
    scrollChildAlli:SetWidth(colWidth)
    scrollChildAlli:SetHeight(captureScrollViewportH)
    scrollAlli:SetScrollChild(scrollChildAlli)
    lbFrame.alliScrollIndUp, lbFrame.alliScrollIndDown =
        CreateScrollIndicators(leftCol, scrollAlli)
    AttachCleanScrollRail(scrollAlli, leftCol,
        lbFrame.alliScrollIndUp, lbFrame.alliScrollIndDown, P)

    lbFrame.alliLines = {}

    -- Colonne droite : Horde - Captures (scroll a la molette uniquement)
    local rightCol = CreateFrame("Frame", nil, capturesContainer)
    rightCol:SetSize(colWidth, capturesBlockH)
    rightCol:SetPoint("RIGHT", capturesContainer, "RIGHT", 0, 0)

    lbFrame.captionHorde = rightCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbFrame.captionHorde:SetPoint("TOP", rightCol, "TOP", 0, -2)
    lbFrame.captionHorde:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    lbFrame.captionHorde:SetText(LbCrestMarkup("Horde", 18) .. " " .. (L.LB_CAPTURES_HORDE or "Horde: Captures"))

    local scrollHorde = CreateFrame("ScrollFrame", "OverlordLBScrollHorde", rightCol)
    scrollHorde:SetSize(colWidth, captureScrollViewportH)
    scrollHorde:SetPoint("TOP", rightCol, "TOP", 0, -16)
    scrollHorde:EnableMouse(true)
    scrollHorde:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(L.LB_CAPTURES_SCROLL_TOOLTIP, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    scrollHorde:SetScript("OnLeave", GameTooltip_Hide)
    scrollHorde:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = CAPTURE_ROW_HEIGHT * 3
        local newVal = cur - delta * step
        newVal = math.max(0, math.min(maxScroll, newVal))
        self:SetVerticalScroll(newVal)
    end)
    scrollHorde:HookScript("OnVerticalScroll", function()
        if RenderCaptureRows then RenderCaptureRows("Horde", false) end
        UpdateLeaderboardScrollIndicator(
            scrollHorde, lbFrame.hordeScrollIndUp, lbFrame.hordeScrollIndDown)
    end)

    local scrollChildHorde = CreateFrame("Frame", nil, scrollHorde)
    scrollChildHorde:SetWidth(colWidth)
    scrollChildHorde:SetHeight(captureScrollViewportH)
    scrollHorde:SetScrollChild(scrollChildHorde)
    lbFrame.hordeScrollIndUp, lbFrame.hordeScrollIndDown =
        CreateScrollIndicators(rightCol, scrollHorde)
    AttachCleanScrollRail(scrollHorde, rightCol,
        lbFrame.hordeScrollIndUp, lbFrame.hordeScrollIndDown, P)

    lbFrame.hordeLines = {}

    -- Reference des scrolls pour Refresh
    lbFrame.scrollAlli = scrollAlli
    lbFrame.scrollHorde = scrollHorde
    lbFrame.scrollChildAlli = scrollChildAlli
    lbFrame.scrollChildHorde = scrollChildHorde
    lbFrame.captureLineHeight = CAPTURE_ROW_HEIGHT
    lbFrame.captureColWidth = colWidth
    lbFrame.captureScrollHeight = captureScrollViewportH
    lbFrame.capturesBlockH = capturesBlockH

    self:UpdateCaptureScrollIndicators() -- kills + captures

    -- Les totaux sont en haut : le pied de page ne garde que sa place (repere du bas).
    footerBand:SetHeight(1)
    footerBand:SetAlpha(0)

    local closeBtn = Overlord.UI.CreateWC3CloseButton(lbFrame, function() Overlord.LeaderboardUI:Hide() end, { gold = P.accent })
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    -- Au-dessus des coins du cadre en bois.
    if lbFrame.bgBorder then closeBtn:SetFrameLevel(lbFrame.bgBorder:GetFrameLevel() + 5) end

    -- ESC ferme le panneau (SetScript au lieu de UISpecialFrames pour eviter taint)
    -- SetPropagateKeyboardInput est protegee en combat : ne pas l'appeler sous InCombatLockdown.
    lbFrame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            if not InCombatLockdown() then
                self:SetPropagateKeyboardInput(false)
            end
            Overlord.LeaderboardUI:Hide()
        elseif not InCombatLockdown() then
            self:SetPropagateKeyboardInput(true)
        end
    end)
    lbFrame:EnableKeyboard(true)
    LayoutLeaderboardSections()
    FitLeaderboardFrameHeight()
    lbFrame:Hide()
end

-- Pools bornes aux lignes visibles (+ overscan). Les frames WoW ne sont jamais liberees : leur
-- nombre ne doit donc jamais suivre la taille historique du classement.
function Overlord.LeaderboardUI:EnsureKillRows(count)
    if not lbFrame or not lbFrame.scrollChildKills or count < 1 then return end
    local parent = lbFrame.scrollChildKills
    local P = GetPalette()
    while #rows < count do
        local i = #rows + 1
        rows[i] = self:CreateRow(parent, i, -(i - 1) * KILL_ROW_HEIGHT, P)
    end
end

function Overlord.LeaderboardUI:EnsureGuildRows(count)
    if not lbFrame or not lbFrame.scrollChildGuild or count < 1 then return end
    local parent = lbFrame.scrollChildGuild
    local P = GetPalette()
    while #guildRows < count do
        local i = #guildRows + 1
        guildRows[i] = self:CreateGuildRow(parent, i, -(i - 1) * GUILD_ROW_HEIGHT, P)
    end
end

function Overlord.LeaderboardUI:EnsureGuildKeepRows(count)
    if not lbFrame or not lbFrame.scrollChildGuildKeep or count < 1 then return end
    local parent = lbFrame.scrollChildGuildKeep
    local P = GetPalette()
    while #guildKeepRows < count do
        local i = #guildKeepRows + 1
        guildKeepRows[i] = self:CreateGuildKeepRow(parent, i, -(i - 1) * GUILD_ROW_HEIGHT, P)
    end
end

function Overlord.LeaderboardUI:EnsureOutpostRows(count)
    if not lbFrame or not lbFrame.scrollChildOutpost or count < 1 then return end
    local parent = lbFrame.scrollChildOutpost
    local P = GetPalette()
    while #outpostRows < count do
        local i = #outpostRows + 1
        outpostRows[i] = self:CreateOutpostRow(parent, i, -(i - 1) * GUILD_ROW_HEIGHT, P)
    end
end

function Overlord.LeaderboardUI:EnsureCaptureRows(faction, count)
    if not lbFrame or count < 1 then return end
    local isAlliance = faction == "Alliance"
    local parent = isAlliance and lbFrame.scrollChildAlli or lbFrame.scrollChildHorde
    local pool = isAlliance and lbFrame.alliLines or lbFrame.hordeLines
    if not parent or not pool then return end
    local P = GetPalette()
    local width = lbFrame.captureColWidth or LB_CAPTURE_PANEL_W
    while #pool < count do
        local i = #pool + 1
        pool[i] = self:CreateCaptureRow(parent, i, 0, P, width)
    end
end

-- Survol d'une ligne de joueur : guilde connue, lue en memoire (meme source que
-- les totaux de guilde). Aucun message reseau, travail uniquement a l'entree.
function Overlord.LeaderboardUI.OnKillRowEnter(row)
    local name = row and row._olPlayerName
    if not name or not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local r, g, b = 1, 1, 1
    if row.name and row.name.GetTextColor then r, g, b = row.name:GetTextColor() end
    GameTooltip:AddLine(row._olDisplayName or name, r or 1, g or 1, b or 1)
    local lb = Overlord.Leaderboard
    local guild = ""
    if lb and lb.GetHotPlayerGuildState then
        guild = lb:GetHotPlayerGuildState(name) or ""
    elseif lb and lb.GetPlayerInfo then
        local info = lb:GetPlayerInfo(name)
        guild = info and info.guild or ""
    end
    if guild ~= "" then
        GameTooltip:AddLine(string.format(L.LB_ROW_GUILD or "Guild: %s", guild), 0.4, 1, 0.4)
    else
        GameTooltip:AddLine(L.LB_ROW_NO_GUILD or "Guild unknown", 0.6, 0.6, 0.6)
    end
    if L.LB_KILLS_SCROLL_TOOLTIP then
        GameTooltip:AddLine(L.LB_KILLS_SCROLL_TOOLTIP, 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

-- 1.4.0: hovering a guild lists its ranked members (top 10 + how many more),
-- read from the display cache built in the background. No network, no scan.
function Overlord.LeaderboardUI.OnGuildRowEnter(row)
    local entry = row and row._olGuildEntry
    if not entry or not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local r, g, b = 1, 1, 1
    if row.name and row.name.GetTextColor then r, g, b = row.name:GetTextColor() end
    GameTooltip:AddLine("<" .. tostring(entry.guild or "") .. ">", r or 1, g or 1, b or 1)
    local lb = Overlord.Leaderboard
    local summary = lb and lb.GetGuildMembersSummary and lb:GetGuildMembersSummary(entry.guild)
    local total = tonumber(entry.kills) or 0
    if summary then
        GameTooltip:AddLine(string.format(L.LB_GUILD_TIP_SUMMARY or "%d ranked members, %d HK",
            summary.count, total), 0.8, 0.8, 0.8)
        local sync = Overlord.Sync
        for i = 1, #summary.names do
            local name = summary.names[i]
            local shown = (sync and sync.CanonicalForeverName and sync:CanonicalForeverName(name)) or name
            local class = lb.GetExportPlayerMeta and select(1, lb:GetExportPlayerMeta(name)) or nil
            local cr, cg, cb = GetClassColor(class)
            GameTooltip:AddDoubleLine(i .. ". " .. tostring(shown), tostring(summary.kills[i]),
                cr or 0.85, cg or 0.85, cb or 0.85, 1, 0.82, 0)
        end
        local more = summary.count - #summary.names
        if more > 0 then
            GameTooltip:AddLine(string.format(L.LB_GUILD_TIP_MORE or "+ %d more", more), 0.6, 0.6, 0.6)
        end
    else
        GameTooltip:AddLine(string.format(L.LB_GUILD_TIP_TOTAL or "%d HK", total), 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

-- 1.7.2: hovering a keep or outpost row names the character who took the site
-- (the capture is signed by him on the network). Read from the row entry, no scan.
function Overlord.LeaderboardUI.OnSiteRowEnter(row)
    local entry = row and row._olSiteEntry
    if not entry or not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local r, g, b = 1, 1, 1
    if row.name and row.name.GetTextColor then r, g, b = row.name:GetTextColor() end
    GameTooltip:AddLine("<" .. tostring(entry.guild or "") .. ">", r or 1, g or 1, b or 1)
    local siteName = entry.keepSiteKey and GetGuildKeepSiteDisplayName(entry.keepSiteKey)
        or GetOutpostSiteDisplayName(entry.outpostSiteKey)
    if siteName and siteName ~= "" then
        GameTooltip:AddLine(siteName, 0.8, 0.8, 0.8)
    end
    local capturer = entry.capturer
    if type(capturer) == "string" and capturer ~= "" then
        local sync = Overlord.Sync
        local shown = (sync and sync.CanonicalForeverName and sync:CanonicalForeverName(capturer)) or capturer
        GameTooltip:AddLine(string.format(L.LB_OUTPOST_CAPTURED_BY or "Taken by %s", shown), 0.4, 1, 0.4)
    end
    GameTooltip:Show()
end

function Overlord.LeaderboardUI.OnSiteRowWheel(row, delta)
    local scroll = lbFrame and (row and row._olSiteEntry and row._olSiteEntry.keepSiteKey
        and lbFrame.scrollGuildKeep or lbFrame.scrollOutpost)
    local handler = scroll and scroll:GetScript("OnMouseWheel")
    if handler then handler(scroll, delta) end
end

function Overlord.LeaderboardUI.OnGuildRowWheel(_, delta)
    local scroll = lbFrame and lbFrame.scrollGuild
    local handler = scroll and scroll:GetScript("OnMouseWheel")
    if handler then handler(scroll, delta) end
end

-- La ligne capte la souris pour le survol : la molette reste au classement.
function Overlord.LeaderboardUI.OnKillRowWheel(_, delta)
    local scroll = lbFrame and lbFrame.scrollKills
    local handler = scroll and scroll:GetScript("OnMouseWheel")
    if handler then handler(scroll, delta) end
end

function Overlord.LeaderboardUI:CreateRow(parent, index, yOffset, P)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(LB_MAIN_W, KILL_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    local bgColor = (index % 2 == 0) and P.rowEven or P.rowOdd
    row.bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
    ApplyRowDivider(row, P)

    -- Compat refresh : barre de faction desactivee (style roster officiel)
    row.factionBar = row:CreateTexture(nil, "ARTWORK")
    row.factionBar:SetSize(0, 0)
    row.factionBar:Hide()

    local killCols = GetKillLayoutSegments()

    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.rank:SetPoint("CENTER", row, "LEFT", killCols.rank.center, 0)
    row.rank:SetWidth(killCols.rank.width)
    row.rank:SetJustifyH("CENTER")

    row.raceIconHolder = CreateOfficialIconHolder(row, LB_ICON_SIZE, P)
    row.raceIconHolder:SetPoint("CENTER", row, "LEFT", killCols.race.center, 0)
    row.raceIcon = row.raceIconHolder.icon

    row.classIconHolder = CreateOfficialIconHolder(row, LB_ICON_SIZE, P)
    row.classIconHolder:SetPoint("CENTER", row, "LEFT", killCols.class.center, 0)
    row.classIcon = row.classIconHolder.icon

    row.glow = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.glow:SetAllPoints()
    row.glow:Hide()

    row.crest = row:CreateTexture(nil, "OVERLAY")
    row.crest:SetSize(19, 19)
    row.crest:SetPoint("LEFT", row, "LEFT", killCols.player.left + 4, 0)
    row.crest:Hide()

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row, "LEFT", killCols.player.left + 26, 0)
    row.name:SetPoint("RIGHT", row, "LEFT", killCols.player.right - 6, 0)
    row.name:SetJustifyH("CENTER")
    row.name:SetWordWrap(false)
    row.name:SetNonSpaceWrap(false)

    row.kills = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.kills:SetPoint("CENTER", row, "LEFT", killCols.kills.center, 0)
    row.kills:SetWidth(killCols.kills.width)
    row.kills:SetJustifyH("CENTER")

    row:EnableMouse(true)
    row:SetScript("OnEnter", Overlord.LeaderboardUI.OnKillRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", Overlord.LeaderboardUI.OnKillRowWheel)

    row:Hide()
    return row
end

-- Ligne du classement guildes (#, nom, tués).
function Overlord.LeaderboardUI:CreateGuildRow(parent, index, yOffset, P)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(LB_GUILD_KILLS_W, GUILD_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    local bgColor = (index % 2 == 0) and P.rowEven or P.rowOdd
    row.bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
    ApplyRowDivider(row, P)

    row.factionBar = row:CreateTexture(nil, "ARTWORK")
    row.factionBar:SetSize(0, 0)
    row.factionBar:Hide()

    row.glow = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.glow:SetAllPoints()
    row.glow:Hide()

    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.rank:SetPoint("CENTER", row, "CENTER", LB_GUILD_COL_RANK, 0)
    row.rank:SetWidth(LB_GUILD_RANK_W)
    row.rank:SetJustifyH("CENTER")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("CENTER", row, "CENTER", LB_GUILD_COL_NAME, 0)
    row.name:SetWidth(LB_GUILD_NAME_W)
    row.name:SetJustifyH("CENTER")
    row.name:SetWordWrap(false)

    row.members = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.members:SetPoint("CENTER", row, "CENTER", LB_GUILD_COL_MEMBERS, 0)
    row.members:SetWidth(LB_GUILD_MEMBERS_W)
    row.members:SetJustifyH("CENTER")

    row.kills = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.kills:SetPoint("CENTER", row, "CENTER", LB_GUILD_COL_KILLS, 0)
    row.kills:SetWidth(LB_GUILD_KILLS_TEXT_W)
    row.kills:SetJustifyH("CENTER")

    row:EnableMouse(true)
    row:SetScript("OnEnter", Overlord.LeaderboardUI.OnGuildRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", Overlord.LeaderboardUI.OnGuildRowWheel)

    row:Hide()
    return row
end

function Overlord.LeaderboardUI:CreateGuildKeepRow(parent, index, yOffset, P)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(LB_GUILD_KEEP_W, GUILD_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    local bgColor = (index % 2 == 0) and P.rowEven or P.rowOdd
    row.bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
    ApplyRowDivider(row, P)

    row.factionBar = row:CreateTexture(nil, "ARTWORK")
    row.factionBar:SetSize(0, 0)
    row.factionBar:Hide()

    row.keepIcon = row:CreateTexture(nil, "ARTWORK")
    row.keepIcon:SetSize(GUILD_KEEP_ICON, GUILD_KEEP_ICON)
    row.keepIcon:SetPoint("LEFT", row, "LEFT", LB_GK_KEEP_LEFT, 0)
    row.keepIcon:Hide()

    row.keepName = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.keepName:SetPoint("LEFT", row.keepIcon, "RIGHT", 4, 0)
    row.keepName:SetWidth(LB_GK_KEEP_NAME_W)
    row.keepName:SetJustifyH("LEFT")
    row.keepName:SetWordWrap(false)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("CENTER", row, "CENTER", LB_GK_COL_GUILD, 0)
    row.name:SetWidth(LB_GK_GUILD_NAME_W)
    row.name:SetJustifyH("CENTER")
    row.name:SetWordWrap(false)

    row.wins = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.wins:SetPoint("CENTER", row, "CENTER", LB_GK_COL_WINS, 0)
    row.wins:SetWidth(LB_GK_WINS_W)
    row.wins:SetJustifyH("CENTER")

    row:EnableMouse(true)
    row:SetScript("OnEnter", Overlord.LeaderboardUI.OnSiteRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", Overlord.LeaderboardUI.OnSiteRowWheel)

    row:Hide()
    return row
end

function Overlord.LeaderboardUI:CreateOutpostRow(parent, index, yOffset, P)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(LB_OUTPOST_W, GUILD_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    local bgColor = (index % 2 == 0) and P.rowEven or P.rowOdd
    row.bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
    ApplyRowDivider(row, P)

    row.factionBar = row:CreateTexture(nil, "ARTWORK")
    row.factionBar:SetSize(0, 0)
    row.factionBar:Hide()

    row.outpostIcon = row:CreateTexture(nil, "ARTWORK")
    row.outpostIcon:SetSize(GUILD_KEEP_ICON, GUILD_KEEP_ICON)
    row.outpostIcon:SetPoint("LEFT", row, "LEFT", LB_OP_OUTPOST_LEFT, 0)
    row.outpostIcon:Hide()

    row.outpostTextClip = CreateFrame("Frame", nil, row)
    row.outpostTextClip:SetPoint("TOP", row, "TOP", 0, 0)
    row.outpostTextClip:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
    row.outpostTextClip:SetPoint("LEFT", row.outpostIcon, "RIGHT", 4, 0)
    row.outpostTextClip:SetPoint("RIGHT", row, "LEFT", LB_OP_GUILD_COL_LEFT - 4, 0)
    row.outpostTextClip:SetClipsChildren(true)

    row.outpostName = row.outpostTextClip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.outpostName:SetPoint("LEFT", row.outpostTextClip, "LEFT", 0, 0)
    row.outpostName:SetPoint("RIGHT", row.outpostTextClip, "RIGHT", 0, 0)
    row.outpostName:SetJustifyH("LEFT")
    row.outpostName:SetWordWrap(false)
    row.outpostName:SetNonSpaceWrap(false)

    row.guildTextClip = CreateFrame("Frame", nil, row)
    row.guildTextClip:SetPoint("TOP", row, "TOP", 0, 0)
    row.guildTextClip:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
    row.guildTextClip:SetPoint("LEFT", row, "LEFT", LB_OP_GUILD_COL_LEFT, 0)
    row.guildTextClip:SetPoint("RIGHT", row, "LEFT", LB_OP_GUILD_COL_RIGHT, 0)
    row.guildTextClip:SetClipsChildren(true)

    row.name = row.guildTextClip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row.guildTextClip, "LEFT", 0, 0)
    row.name:SetPoint("RIGHT", row.guildTextClip, "RIGHT", 0, 0)
    row.name:SetJustifyH("CENTER")
    row.name:SetWordWrap(false)
    row.name:SetNonSpaceWrap(false)

    row.captures = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.captures:SetPoint("CENTER", row, "CENTER", LB_OP_COL_CAPTURES, 0)
    row.captures:SetWidth(LB_OP_CAPTURES_W)
    row.captures:SetJustifyH("CENTER")

    row:EnableMouse(true)
    row:SetScript("OnEnter", Overlord.LeaderboardUI.OnSiteRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", Overlord.LeaderboardUI.OnSiteRowWheel)

    row:Hide()
    return row
end

-- Ligne du tableau captures : style roster officiel (icone circulaire, nom a gauche)
function Overlord.LeaderboardUI:CreateCaptureRow(parent, index, yOffset, P, width)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width, CAPTURE_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    local bgColor = (index % 2 == 0) and P.rowEven or P.rowOdd
    row.bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
    ApplyRowDivider(row, P)

    row.factionBar = row:CreateTexture(nil, "ARTWORK")
    row.factionBar:SetSize(0, 0)
    row.factionBar:Hide()

    local capCols = GetCaptureLayoutSegments(width)
    row.raceIconHolder = CreateOfficialIconHolder(row, LB_ICON_SIZE, P)
    row.raceIconHolder:SetPoint("CENTER", row, "LEFT", capCols.race.center, 0)
    row.raceIcon = row.raceIconHolder.icon

    row.classIconHolder = CreateOfficialIconHolder(row, LB_ICON_SIZE, P)
    row.classIconHolder:SetPoint("CENTER", row, "LEFT", capCols.class.center, 0)
    row.classIcon = row.classIconHolder.icon

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", capCols.name.left + 2, -2)
    row.name:SetPoint("TOPRIGHT", row, "TOPLEFT", capCols.name.right - 2, -2)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetNonSpaceWrap(false)

    row.locale = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.locale:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, 0)
    row.locale:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, 0)
    row.locale:SetJustifyH("LEFT")
    row.locale:SetWordWrap(false)
    row.locale:SetNonSpaceWrap(false)
    row.locale:SetTextColor(P.muted[1], P.muted[2], P.muted[3])

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.count:SetPoint("CENTER", row, "LEFT", capCols.count.center, 0)
    row.count:SetWidth(capCols.count.width)
    row.count:SetJustifyH("CENTER")

    row:Hide()
    return row
end

local function GetVirtualRowWindow(scroll, rowHeight, totalCount, maxCount)
    local total = math.max(0, math.floor(tonumber(totalCount) or 0))
    if maxCount then total = math.min(total, maxCount) end
    if total == 0 then return 1, 0, 0 end
    local viewportHeight = math.max(rowHeight, (scroll and scroll:GetHeight()) or rowHeight)
    local poolSize = math.min(total,
        math.max(1, math.ceil(viewportHeight / rowHeight) + VIRTUAL_ROW_OVERSCAN))
    local offset = math.max(0, (scroll and scroll:GetVerticalScroll()) or 0)
    local first = math.min(total, math.floor(offset / rowHeight) + 1)
    return first, poolSize, total
end

local function BeginVirtualRender(scroll, first, poolSize, total, force)
    if not scroll then return false end
    if not force and scroll._lbVirtualFirst == first
        and scroll._lbVirtualPoolSize == poolSize
        and scroll._lbVirtualTotal == total then
        return false
    end
    scroll._lbVirtualFirst = first
    scroll._lbVirtualPoolSize = poolSize
    scroll._lbVirtualTotal = total
    return true
end

-- Met a jour la fenetre virtuelle sans court-circuiter le paint (les paintKeys
-- gerent deja les Set* inchanges quand les donnees n'ont pas bouge).
local function SyncVirtualRenderWindow(scroll, first, poolSize, total, force)
    BeginVirtualRender(scroll, first, poolSize, total, force)
end

local function PrepareVirtualRow(row, dataIndex, rowHeight, P)
    if not row or row._lbDataIndex == dataIndex then return end
    row._lbDataIndex = dataIndex
    row._lbPaintKey = nil
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", row:GetParent(), "TOPLEFT", 0, -(dataIndex - 1) * rowHeight)
    if row.bg then
        local bgColor = (dataIndex % 2 == 0) and P.rowEven or P.rowOdd
        row.bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
    end
end

local function HideUnusedVirtualRows(pool, used)
    for i = used + 1, #pool do
        local row = pool[i]
        if row then
            row._lbPaintKey = nil
            row:Hide()
        end
    end
end

RenderKillRows = function(force)
    if not lbFrame or not lbFrame._lbView then return end
    local view = lbFrame._lbView
    local sortedKills = view.sortedKills or {}
    local first, poolSize, total = GetVirtualRowWindow(
        lbFrame.scrollKills, KILL_ROW_HEIGHT, #sortedKills)
    Overlord.LeaderboardUI:EnsureKillRows(poolSize)
    SyncVirtualRenderWindow(lbFrame.scrollKills, first, poolSize, total, force)

    local P = GetPalette()
    local metaCache = view.meta or {}
    local localeCache = view.locale or {}
    local duplicateShortNames = view.duplicateShortNames or {}
    local sync = Overlord.Sync
    local myName = sync and sync.GetPlayerFullName and sync:GetPlayerFullName()
    myName = myName and sync.CanonicalForeverName and sync:CanonicalForeverName(myName) or myName
    local used = 0
    for slot = 1, poolSize do
        local dataIndex = first + slot - 1
        local row = rows[slot]
        local entry = dataIndex <= total and sortedKills[dataIndex] or nil
        if row and entry then
            used = slot
            PrepareVirtualRow(row, dataIndex, KILL_ROW_HEIGHT, P)
            local class, faction, raceFile, raceSex = CachedMeta(metaCache, entry.name)
            local nameStr = (type(entry.name) == "string") and entry.name or tostring(entry.name or "")
            local shortName = (Overlord.Sync and Overlord.Sync.CanonicalForeverName
                and Overlord.Sync:CanonicalForeverName(nameStr)) or nameStr
            local locTag = localeCache[entry.name]
            if locTag and locTag ~= "" then shortName = shortName .. " (" .. locTag .. ")" end
            -- Lignes virtuelles reutilisees au defilement : le survol suit le joueur affiche.
            if row._olPlayerName ~= entry.name then
                row._olPlayerName, row._olDisplayName = entry.name, shortName
                if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(row) then
                    Overlord.LeaderboardUI.OnKillRowEnter(row)
                end
            else
                row._olDisplayName = shortName
            end
            local rank = view.ranks and view.ranks.sortedKills[dataIndex] or dataIndex
            local isOwn = myName ~= nil and shortName:sub(1, #myName) == myName
                and (#shortName == #myName or shortName:sub(#myName + 1, #myName + 2) == " (")
            -- Most Wanted : tete de mort devant les cinq meilleurs ennemis (MostWanted.lua).
            local wanted = Overlord.MostWanted and Overlord.MostWanted.IsWanted
                and Overlord.MostWanted:IsWanted(entry.name) ~= nil
            local paintKey = rank .. "|" .. tostring(entry.kills) .. "|" .. tostring(class) .. "|"
                .. tostring(faction) .. "|" .. tostring(raceFile) .. "|" .. tostring(raceSex) .. "|"
                .. shortName .. (isOwn and "|me" or "") .. (wanted and "|w" or "")
            if row._lbPaintKey ~= paintKey then
                row._lbPaintKey = paintKey
                local medalColor = MEDAL_COLORS[rank]
                if row.crest then
                    local crest = LB_CREST[faction]
                    if crest then row.crest:SetTexture(crest) end
                    row.crest:SetShown(crest ~= nil)
                end
                ApplyLbRowGlow(row, rank, isOwn)
                row.rank:SetText(rank)
                SetSecondaryTextColor(row.rank, P, medalColor)
                if raceFile and raceFile ~= "" then
                    local raceIconShown = SetRaceIcon(row.raceIcon, raceFile, raceSex)
                    if row.raceIconHolder then row.raceIconHolder:SetShown(raceIconShown) end
                elseif row.raceIconHolder then
                    row.raceIcon:Hide()
                    row.raceIconHolder:Hide()
                end
                SetClassIcon(row.classIcon, class)
                if row.classIconHolder then row.classIconHolder:Show() end
                local cr, cg, cb = GetClassColor(class)
                row.name:SetText(wanted
                    and ("|TInterface\\TargetingFrame\\UI-TargetingFrame-Skull:12|t " .. shortName)
                    or shortName)
                if cr and cg and cb then
                    row.name:SetTextColor(cr, cg, cb)
                else
                    row.name:SetTextColor(P.gray[1], P.gray[2], P.gray[3])
                end
                row.kills:SetText(entry.kills)
                SetSecondaryTextColor(row.kills, P, medalColor)
            end
            row:Show()
        end
    end
    HideUnusedVirtualRows(rows, used)
end

RenderGuildRows = function(force)
    if not lbFrame or not lbFrame._lbView then return end
    local sortedGuilds = lbFrame._lbView.sortedGuilds or {}
    local first, poolSize, total = GetVirtualRowWindow(
        lbFrame.scrollGuild, GUILD_ROW_HEIGHT, #sortedGuilds)
    Overlord.LeaderboardUI:EnsureGuildRows(poolSize)
    SyncVirtualRenderWindow(lbFrame.scrollGuild, first, poolSize, total, force)
    local P = GetPalette()
    local myGuild = Overlord.Outpost and Overlord.Outpost.GetLocalPlayerGuild
        and Overlord.Outpost:GetLocalPlayerGuild() or ""
    local lbMembers = Overlord.Leaderboard
    local used = 0
    for slot = 1, poolSize do
        local dataIndex = first + slot - 1
        local row = guildRows[slot]
        local entry = dataIndex <= total and sortedGuilds[dataIndex] or nil
        if row and entry then
            used = slot
            PrepareVirtualRow(row, dataIndex, GUILD_ROW_HEIGHT, P)
            -- Reused virtual rows: the tooltip follows the guild shown.
            if row._olGuildEntry ~= entry then
                row._olGuildEntry = entry
                if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(row) then
                    Overlord.LeaderboardUI.OnGuildRowEnter(row)
                end
            end
            local rank = lbFrame._lbView.ranks and lbFrame._lbView.ranks.sortedGuilds[dataIndex] or dataIndex
            local isOwn = myGuild ~= "" and entry.guild == myGuild
            local membersSummary = lbMembers and lbMembers.GetGuildMembersSummary
                and lbMembers:GetGuildMembersSummary(entry.guild)
            local memberCount = membersSummary and tonumber(membersSummary.count) or nil
            local paintKey = rank .. "|" .. tostring(entry.guild or "") .. "|"
                .. tostring(entry.kills or 0) .. "|" .. tostring(entry.faction or "")
                .. "|" .. tostring(memberCount or "") .. (isOwn and "|me" or "")
            if row._lbPaintKey ~= paintKey then
                row._lbPaintKey = paintKey
                local medalColor = MEDAL_COLORS[rank]
                ApplyLbRowGlow(row, rank, isOwn)
                row.rank:SetText(rank)
                SetSecondaryTextColor(row.rank, P, medalColor)
                row.factionBar:Hide()
                row.name:SetText(entry.guild or "")
                if entry.faction == "Horde" then
                    row.name:SetTextColor(1.0, 0.40, 0.27)
                elseif entry.faction == "Alliance" then
                    row.name:SetTextColor(0.427, 0.702, 0.949)
                else
                    row.name:SetTextColor(P.white[1], P.white[2], P.white[3])
                end
                local guildKills = tonumber(entry.kills) or 0
                row.kills:SetText(guildKills >= 1000000
                    and string.format("%.1fM", guildKills / 1000000) or guildKills)
                SetSecondaryTextColor(row.kills, P, medalColor)
                if row.members then
                    row.members:SetText(memberCount and tostring(memberCount) or "-")
                    row.members:SetTextColor(0.8, 0.8, 0.8)
                end
            end
            row:Show()
        end
    end
    HideUnusedVirtualRows(guildRows, used)
end

RenderGuildKeepRows = function(force)
    if not lbFrame or not lbFrame._lbView then return end
    local list = lbFrame._lbView.sortedGuildKeeps or {}
    local first, poolSize, total = GetVirtualRowWindow(
        lbFrame.scrollGuildKeep, GUILD_ROW_HEIGHT, #list)
    Overlord.LeaderboardUI:EnsureGuildKeepRows(poolSize)
    SyncVirtualRenderWindow(lbFrame.scrollGuildKeep, first, poolSize, total, force)
    local P = GetPalette()
    local used = 0
    for slot = 1, poolSize do
        local dataIndex = first + slot - 1
        local row = guildKeepRows[slot]
        local entry = dataIndex <= total and list[dataIndex] or nil
        if row and entry then
            used = slot
            PrepareVirtualRow(row, dataIndex, GUILD_ROW_HEIGHT, P)
            -- Reused virtual rows: the tooltip follows the site shown.
            if row._olSiteEntry ~= entry then
                row._olSiteEntry = entry
                if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(row) then
                    Overlord.LeaderboardUI.OnSiteRowEnter(row)
                end
            end
            local rank = lbFrame._lbView.ranks and lbFrame._lbView.ranks.sortedGuildKeeps[dataIndex] or dataIndex
            local medalColor = MEDAL_COLORS[rank]
            local keepName = GetGuildKeepSiteDisplayName(entry.keepSiteKey)
            local wins = math.floor(tonumber(entry.wins) or 0)
            local paintKey = rank .. "|" .. tostring(entry.guild or "") .. "|"
                .. tostring(entry.faction or "") .. "|" .. tostring(entry.keepSiteKey or "") .. "|"
                .. tostring(wins) .. "|" .. (entry.currentlyHeld and "1" or "0") .. "|"
                .. tostring(entry.keepAtlas or "") .. "|" .. keepName
            if row._lbPaintKey ~= paintKey then
                row._lbPaintKey = paintKey
                row.factionBar:Hide()
                row.name:SetText(entry.guild or "")
                if entry.faction == "Horde" then
                    row.name:SetTextColor(1.0, 0.40, 0.27)
                elseif entry.faction == "Alliance" then
                    row.name:SetTextColor(0.427, 0.702, 0.949)
                elseif medalColor then
                    row.name:SetTextColor(medalColor[1], medalColor[2], medalColor[3])
                else
                    row.name:SetTextColor(P.white[1], P.white[2], P.white[3])
                end
                if entry.currentlyHeld and entry.keepAtlas and row.keepIcon and row.keepIcon.SetAtlas then
                    row.keepIcon:SetAtlas(entry.keepAtlas, false)
                    row.keepIcon:SetSize(GUILD_KEEP_ICON, GUILD_KEEP_ICON)
                    row.keepIcon:Show()
                elseif row.keepIcon then
                    row.keepIcon:Hide()
                end
                if row.keepName then
                    row.keepName:SetText(keepName)
                    row.keepName:SetShown(keepName ~= "")
                    if keepName ~= "" then SetSecondaryTextColor(row.keepName, P, medalColor) end
                end
                row.wins:SetText(tostring(wins))
                SetSecondaryTextColor(row.wins, P, (wins > 0 or entry.currentlyHeld) and medalColor or nil)
            end
            row:Show()
        end
    end
    HideUnusedVirtualRows(guildKeepRows, used)
end

RenderOutpostRows = function(force)
    if not lbFrame or not lbFrame._lbView then return end
    local list = lbFrame._lbView.sortedOutposts or {}
    local first, poolSize, total = GetVirtualRowWindow(
        lbFrame.scrollOutpost, GUILD_ROW_HEIGHT, #list)
    Overlord.LeaderboardUI:EnsureOutpostRows(poolSize)
    SyncVirtualRenderWindow(lbFrame.scrollOutpost, first, poolSize, total, force)
    local P = GetPalette()
    local used = 0
    for slot = 1, poolSize do
        local dataIndex = first + slot - 1
        local row = outpostRows[slot]
        local entry = dataIndex <= total and list[dataIndex] or nil
        if row and entry then
            used = slot
            PrepareVirtualRow(row, dataIndex, GUILD_ROW_HEIGHT, P)
            -- Reused virtual rows: the tooltip follows the site shown.
            if row._olSiteEntry ~= entry then
                row._olSiteEntry = entry
                if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(row) then
                    Overlord.LeaderboardUI.OnSiteRowEnter(row)
                end
            end
            local rank = lbFrame._lbView.ranks and lbFrame._lbView.ranks.sortedOutposts[dataIndex] or dataIndex
            local medalColor = MEDAL_COLORS[rank]
            local outpostName = GetOutpostSiteDisplayName(entry.outpostSiteKey)
            local captures = math.floor(tonumber(entry.captures) or 0)
            local paintKey = rank .. "|" .. tostring(entry.guild or "") .. "|"
                .. tostring(entry.faction or "") .. "|" .. tostring(entry.outpostSiteKey or "") .. "|"
                .. tostring(captures) .. "|" .. (entry.currentlyHeld and "1" or "0") .. "|"
                .. tostring(entry.outpostAtlas or "") .. "|" .. outpostName
            if row._lbPaintKey ~= paintKey then
                row._lbPaintKey = paintKey
                row.factionBar:Hide()
                row.name:SetText(TruncateTextToWidth(entry.guild or "", LB_OP_GUILD_NAME_W, "GameFontNormal"))
                if entry.faction == "Horde" then
                    row.name:SetTextColor(1.0, 0.40, 0.27)
                elseif entry.faction == "Alliance" then
                    row.name:SetTextColor(0.427, 0.702, 0.949)
                elseif medalColor then
                    row.name:SetTextColor(medalColor[1], medalColor[2], medalColor[3])
                else
                    row.name:SetTextColor(P.white[1], P.white[2], P.white[3])
                end
                if entry.currentlyHeld and entry.outpostAtlas and row.outpostIcon and row.outpostIcon.SetAtlas then
                    -- Taille fixe : avec la taille native de l'atlas (parfois 0 sur Forever),
                    -- le nom du site sautait vers la gauche sur certaines lignes seulement.
                    row.outpostIcon:SetAtlas(entry.outpostAtlas, false)
                    row.outpostIcon:SetSize(GUILD_KEEP_ICON, GUILD_KEEP_ICON)
                    row.outpostIcon:Show()
                elseif row.outpostIcon then
                    row.outpostIcon:Hide()
                end
                if row.outpostName then
                    row.outpostName:SetText(TruncateTextToWidth(
                        outpostName, LB_OP_OUTPOST_NAME_MAX_W, "GameFontNormalSmall"))
                    row.outpostName:SetShown(outpostName ~= "")
                    if outpostName ~= "" then SetSecondaryTextColor(row.outpostName, P, medalColor) end
                end
                row.captures:SetText(tostring(captures))
                SetSecondaryTextColor(row.captures, P, medalColor)
            end
            row:Show()
        end
    end
    HideUnusedVirtualRows(outpostRows, used)
end

RenderCaptureRows = function(faction, force)
    if not lbFrame or not lbFrame._lbView then return end
    local isAlliance = faction == "Alliance"
    local list = (lbFrame._lbView.byFaction and lbFrame._lbView.byFaction[faction]) or {}
    local scroll = isAlliance and lbFrame.scrollAlli or lbFrame.scrollHorde
    local pool = isAlliance and lbFrame.alliLines or lbFrame.hordeLines
    local first, poolSize, total = GetVirtualRowWindow(
        scroll, CAPTURE_ROW_HEIGHT, #list, MAX_CAPTURE_LINES)
    Overlord.LeaderboardUI:EnsureCaptureRows(faction, poolSize)
    SyncVirtualRenderWindow(scroll, first, poolSize, total, force)
    local P = GetPalette()
    local metaCache = lbFrame._lbView.meta or {}
    local localeCache = lbFrame._lbView.locale or {}
    local used = 0
    for slot = 1, poolSize do
        local dataIndex = first + slot - 1
        local row = pool[slot]
        local entry = dataIndex <= total and list[dataIndex] or nil
        if row and entry then
            used = slot
            PrepareVirtualRow(row, dataIndex, CAPTURE_ROW_HEIGHT, P)
            local nameStr = tostring(entry.name or "")
            local shortName = (Overlord.Sync and Overlord.Sync.CanonicalForeverName
                and Overlord.Sync:CanonicalForeverName(nameStr)) or nameStr
            local locTag = localeCache[entry.name]
            local localeLabel = (locTag and locTag ~= "") and ("(" .. locTag .. ")") or ""
            local metaClass, _, raceFile, raceSex = CachedMeta(metaCache, entry.name)
            local capClass = (metaClass and metaClass ~= "") and metaClass or entry.class or "UNKNOWN"
            local rank = lbFrame._lbView.ranks and lbFrame._lbView.ranks[faction][dataIndex] or dataIndex
            local capKey = faction .. "|" .. rank .. "|" .. shortName .. "|" .. localeLabel .. "|"
                .. capClass .. "|" .. tostring(raceFile) .. "|" .. tostring(raceSex) .. "|"
                .. tostring(entry.count)
            if row._lbPaintKey ~= capKey then
                row._lbPaintKey = capKey
                local raceIconShown = SetRaceIcon(row.raceIcon, raceFile, raceSex)
                if row.raceIconHolder then row.raceIconHolder:SetShown(raceIconShown) end
                SetClassIcon(row.classIcon, capClass)
                local cr, cg, cb = GetCaptureRowNameColor(entry, capClass, P)
                row.name:SetTextColor(cr, cg, cb)
                row.name:SetText(shortName)
                row.locale:SetText(localeLabel)
                row.count:SetText(entry.count)
                SetSecondaryTextColor(row.count, P, MEDAL_COLORS[rank])
                if row.classIconHolder then row.classIconHolder:Show() end
            end
            row:Show()
        end
    end
    HideUnusedVirtualRows(pool, used)
end

local function GetLeaderboardScrollValue(scroll)
    if not scroll or not scroll.GetVerticalScroll then return 0 end
    return scroll:GetVerticalScroll() or 0
end

local function CaptureLeaderboardScrollPositions()
    if not lbFrame then return nil end
    local saved = lbFrame._savedScrollPositions or {}
    lbFrame._savedScrollPositions = saved
    saved.alli = GetLeaderboardScrollValue(lbFrame.scrollAlli)
    saved.horde = GetLeaderboardScrollValue(lbFrame.scrollHorde)
    saved.kills = GetLeaderboardScrollValue(lbFrame.scrollKills)
    saved.guild = GetLeaderboardScrollValue(lbFrame.scrollGuild)
    saved.guildKeep = GetLeaderboardScrollValue(lbFrame.scrollGuildKeep)
    saved.outpost = GetLeaderboardScrollValue(lbFrame.scrollOutpost)
    return saved
end

local function RestoreLeaderboardScrollValue(scroll, value)
    if not scroll or not scroll.SetVerticalScroll then return end
    if scroll._overlordHasOverflow == false then
        scroll:SetVerticalScroll(0)
        return
    end
    value = tonumber(value) or 0
    local maxScroll = (scroll.GetVerticalScrollRange and scroll:GetVerticalScrollRange()) or 0
    if maxScroll < 0 then maxScroll = 0 end
    scroll:SetVerticalScroll(math.max(0, math.min(maxScroll, value)))
end

local function RestoreLeaderboardScrollPositions(saved)
    if not lbFrame or not saved then return end
    -- Les refresh sync ne doivent pas faire remonter le joueur en haut du classement.
    RestoreLeaderboardScrollValue(lbFrame.scrollAlli, saved.alli)
    RestoreLeaderboardScrollValue(lbFrame.scrollHorde, saved.horde)
    RestoreLeaderboardScrollValue(lbFrame.scrollKills, saved.kills)
    RestoreLeaderboardScrollValue(lbFrame.scrollGuild, saved.guild)
    RestoreLeaderboardScrollValue(lbFrame.scrollGuildKeep, saved.guildKeep)
    RestoreLeaderboardScrollValue(lbFrame.scrollOutpost, saved.outpost)
end

local function ResetLeaderboardScrollPositions()
    if not lbFrame then return end
    RestoreLeaderboardScrollValue(lbFrame.scrollAlli, 0)
    RestoreLeaderboardScrollValue(lbFrame.scrollHorde, 0)
    RestoreLeaderboardScrollValue(lbFrame.scrollKills, 0)
    RestoreLeaderboardScrollValue(lbFrame.scrollGuild, 0)
    RestoreLeaderboardScrollValue(lbFrame.scrollGuildKeep, 0)
    RestoreLeaderboardScrollValue(lbFrame.scrollOutpost, 0)
end

function Overlord.LeaderboardUI:PaintView()
    if not lbFrame or not lbFrame:IsShown() or not lbFrame._lbView then return end
    local view = lbFrame._lbView
    local searching = lbFrame.searchQuery and lbFrame.searchQuery ~= ""
    local savedScroll = not lbFrame.searchResetScroll and CaptureLeaderboardScrollPositions()
    if lbFrame.searchResetScroll then ResetLeaderboardScrollPositions() end
    lbFrame.searchResetScroll = nil
    if lbFrame.guildEmptyHint then
        lbFrame.guildEmptyHint:SetShown(not searching and #view.sortedGuilds == 0)
    end
    if lbFrame.guildKeepEmptyHint then
        lbFrame.guildKeepEmptyHint:SetShown(not searching and #view.sortedGuildKeeps == 0)
    end
    if lbFrame.outpostEmptyHint then
        lbFrame.outpostEmptyHint:SetShown(not searching and #view.sortedOutposts == 0)
    end

    LayoutLeaderboardSections()
    FitLeaderboardFrameHeight()

    local killCount = #view.sortedKills
    local alliCount = math.min(#(view.byFaction.Alliance or {}), MAX_CAPTURE_LINES)
    local hordeCount = math.min(#(view.byFaction.Horde or {}), MAX_CAPTURE_LINES)
    SetLeaderboardScrollExtent(
        lbFrame.scrollKills, lbFrame.scrollChildKills, killCount, KILL_ROW_HEIGHT)
    SetLeaderboardScrollExtent(
        lbFrame.scrollGuild, lbFrame.scrollChildGuild, #view.sortedGuilds, GUILD_ROW_HEIGHT)
    SetLeaderboardScrollExtent(
        lbFrame.scrollGuildKeep, lbFrame.scrollChildGuildKeep,
        #view.sortedGuildKeeps, GUILD_ROW_HEIGHT)
    SetLeaderboardScrollExtent(
        lbFrame.scrollOutpost, lbFrame.scrollChildOutpost,
        #view.sortedOutposts, GUILD_ROW_HEIGHT)
    SetLeaderboardScrollExtent(
        lbFrame.scrollAlli, lbFrame.scrollChildAlli, alliCount, CAPTURE_ROW_HEIGHT)
    SetLeaderboardScrollExtent(
        lbFrame.scrollHorde, lbFrame.scrollChildHorde, hordeCount, CAPTURE_ROW_HEIGHT)
    RestoreLeaderboardScrollPositions(savedScroll)

    -- Peinture virtuelle : paintKeys sautent les Set* inchanges.
    -- force=false : BeginVirtualRender ne coupe plus le paint (fenetre inchangee).
    RenderKillRows(false)
    RenderGuildRows(false)
    RenderGuildKeepRows(false)
    RenderOutpostRows(false)
    RenderCaptureRows("Alliance", false)
    RenderCaptureRows("Horde", false)
    self:UpdateCaptureScrollIndicators()
    -- Blizzard peut publier GetVerticalScrollRange un frame apres SetHeight. Une passe
    -- differee unique corrige rails/thumbs sans OnUpdate permanent.
    C_Timer.After(0, function()
        local ui = Overlord.LeaderboardUI
        if ui and ui:IsShown() then ui:UpdateCaptureScrollIndicators() end
    end)
end

local function SetSearchStatus(text)
    if lbFrame._searchStatus ~= text then
        lbFrame._searchStatus = text
        lbFrame.searchStatus:SetText(text)
    end
end

local function PublishSearchView(view)
    lbFrame._lbView = view
    if lbFrame.searchQuery and lbFrame.searchQuery ~= "" then
        local count = #view.sortedKills + #view.sortedGuilds + #view.sortedGuildKeeps
            + #view.sortedOutposts + #view.byFaction.Alliance + #view.byFaction.Horde
        SetSearchStatus(count == 0 and (L.LB_SEARCH_EMPTY or "No matches") or "")
    else
        SetSearchStatus("")
    end
    Overlord.LeaderboardUI:PaintView()
end

function Overlord.LeaderboardUI:ApplySearch()
    if not self:IsShown() or not lbFrame._lbSource then return end
    if not lbFrame.searchQuery or lbFrame.searchQuery == "" then
        if lbFrame.search and (lbFrame.search.job or lbFrame.search.result) then
            lbFrame.search:Request(lbFrame._lbSource, "")
        end
        PublishSearchView(lbFrame._lbSource)
        return
    end
    if not lbFrame.search then
        lbFrame.search = Overlord.LeaderboardSearch:New(function() return self:IsShown() end, PublishSearchView)
    end
    local view = lbFrame.search:Request(lbFrame._lbSource, lbFrame.searchQuery)
    if view then PublishSearchView(view)
    else SetSearchStatus(L.LB_SEARCH_WORKING or "Searching...") end
end

function Overlord.LeaderboardUI:SetSearchText(text)
    if not lbFrame then return end
    -- La recherche filtre les tableaux : le volet preneurs/rivalites leur rend la place.
    if text and text ~= "" and lbFrame.sitesWeek and lbFrame.sitesWeek:IsShown() then
        self:ToggleSitesWeek()
    end
    local query = Overlord.LeaderboardSearch:Normalize(text)
    if query == (lbFrame.searchQuery or "") then return end
    lbFrame.searchQuery = query
    lbFrame.searchResetScroll = true
    self:ApplySearch()
end

local function InfoNumber(value)
    value = math.floor(tonumber(value) or 0)
    if BreakUpLargeNumbers then
        local ok, text = pcall(BreakUpLargeNumbers, value)
        if ok and text then return text end
    end
    return tostring(value)
end

local function InfoText(label, value)
    return "|cFFF8B700" .. label .. "|r " .. value
end

local function InfoSetLine(fs, text)
    if not fs then return end
    if fs._infoText ~= text then
        fs._infoText = text
        fs:SetText(text or "")
    end
end

-- Un seul passage sur la liste par reconstruction du classement : rang du joueur,
-- ecart avec le suivant, joueurs classes par faction ; guilde du joueur.
local function ComputeLeaderboardInfo(dc)
    local info = { allianceRanked = 0, hordeRanked = 0 }
    local sync = Overlord.Sync
    local canon = sync and sync.CanonicalForeverName
    local myName = sync and sync.GetPlayerFullName and sync:GetPlayerFullName()
    myName = myName and canon and sync:CanonicalForeverName(myName) or myName
    -- Seuls les noms qui commencent comme le notre sont normalises (pas 5 000 appels).
    local myShort = type(myName) == "string" and (myName:match("^(.-)%-") or myName) or nil
    if myShort == "" then myShort = nil end
    info.nameReady = myShort ~= nil
    local meta = dc.meta or {}
    local sorted = dc.sortedKills or {}
    for i = 1, #sorted do
        local row = sorted[i]
        local m = row and meta[row.name]
        local faction = m and m[2]
        if faction == "Alliance" then info.allianceRanked = info.allianceRanked + 1
        elseif faction == "Horde" then info.hordeRanked = info.hordeRanked + 1 end
        if myShort and not info.myRank and type(row.name) == "string"
            and row.name:find(myShort, 1, true) == 1 then
            local name = canon and sync:CanonicalForeverName(row.name) or row.name
            if name == myName then
                info.myRank, info.myKills = i, tonumber(row.kills) or 0
                local above = sorted[i - 1]
                if above then info.aboveKills = tonumber(above.kills) or 0 end
            end
        end
    end
    local myGuild = Overlord.Outpost and Overlord.Outpost.GetLocalPlayerGuild
        and Overlord.Outpost:GetLocalPlayerGuild() or ""
    if myGuild ~= "" then
        info.guild = myGuild
        for i, entry in ipairs(dc.sortedGuilds or {}) do
            if entry.guild == myGuild then
                info.guildRank, info.guildKills = i, tonumber(entry.kills) or 0
                break
            end
        end
    end
    return info
end

function Overlord.LeaderboardUI:RefreshInfoLines(dc)
    if not lbFrame or not lbFrame.infoLeft then return end
    if dc and lbFrame._infoDc ~= dc then
        -- Copie sauvegardee (500 premiers) ou cache pas pret : rang et joueurs classes
        -- seraient faux. Nom du joueur pas encore connu : on recalculera au prochain rafraichissement.
        if dc.fromSavedCache or dc.ready == false then
            lbFrame._infoDc, lbFrame._info = dc, nil
        else
            local info = ComputeLeaderboardInfo(dc)
            lbFrame._info = info
            if info.nameReady then lbFrame._infoDc = dc end
        end
    end
    local info = lbFrame._info
    local left, right = lbFrame.infoLeft, lbFrame.infoRight

    -- Gauche : fin de campagne, joueurs classes.
    local startTs = Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs() or 0
    local now = (Overlord.ServerNow and Overlord.ServerNow()) or (GetServerTime and GetServerTime()) or 0
    local remaining = (startTs > 0 and now > 0) and (startTs + 604800 - now) or 0
    local duration
    if remaining > 0 and SecondsToTime then
        local ok, text = pcall(SecondsToTime, remaining - remaining % 60, true, false, 2)
        duration = ok and text or nil
    end
    InfoSetLine(left[1], duration and InfoText(L.LB_INFO_ENDS or "Campaign ends in", duration) or "")
    if not info then
        InfoSetLine(left[2], "")
        InfoSetLine(right[1], "")
        InfoSetLine(right[2], "")
        return
    end
    InfoSetLine(left[2], InfoText(L.LB_INFO_RANKED or "Ranked players:", string.format(
        L.LB_INFO_RANKED_VALUE or "|cFF4488FF%s Alliance|r · |cFFFF4444%s Horde|r",
        InfoNumber(info.allianceRanked), InfoNumber(info.hordeRanked))))

    -- Droite : rang du joueur et ecart avec le suivant, puis sa guilde.
    local unit = L.LB_COL_KILLS or "HK"
    if info.myRank then
        local nextText = info.aboveKills
            and string.format(L.LB_INFO_NEXT or "%s HK to pass #%d",
                InfoNumber(math.max(1, info.aboveKills - info.myKills + 1)), info.myRank - 1)
            or (L.LB_INFO_FIRST or "You lead the ladder!")
        InfoSetLine(right[1], InfoText(L.LB_INFO_YOU or "You:", string.format("#%d · %s %s",
            info.myRank, InfoNumber(info.myKills), unit)) .. "  |cFFB8B8B8(" .. nextText .. ")|r")
    else
        InfoSetLine(right[1], InfoText(L.LB_INFO_YOU or "You:", L.LB_INFO_UNRANKED or "not ranked yet"))
    end
    if info.guild and info.guildRank then
        InfoSetLine(right[2], InfoText("<" .. info.guild .. ">", string.format("#%d · %s %s",
            info.guildRank, InfoNumber(info.guildKills), unit)))
    else
        InfoSetLine(right[2], "")
    end
end

function Overlord.LeaderboardUI:Refresh()
    if not lbFrame or not lbFrame:IsShown() or not Overlord.Leaderboard then return end
    local lb = Overlord.Leaderboard
    local dc = lb.EnsureDisplayCache and lb:EnsureDisplayCache()
    if not dc then return end
    local sortedGuildKeeps, sortedOutposts = GetVolatileLeaderboardLists(lb, dc.sortedGuilds)
    local view = lbFrame._lbSource or {}
    lbFrame._lbSource = view
    view.sortedKills = dc.sortedKills or {}
    view.byFaction = dc.byFaction or { Alliance = {}, Horde = {} }
    view.sortedGuilds = dc.sortedGuilds or {}
    view.sortedGuildKeeps = sortedGuildKeeps or {}
    view.sortedOutposts = sortedOutposts or {}
    self:RefreshSitesWeek()
    view.meta = dc.meta or {}
    view.locale = dc.locale or {}
    view.duplicateShortNames = dc.duplicateShortNames or {}
    -- Totaux avant le dessin : la hauteur du cadre est calculee avec leur ligne.
    local totalFmt = string.format(L.LB_TOTAL_FORMAT, dc.alliKills or 0, dc.hordeKills or 0)
    if lbFrame._lbTotalFmt ~= totalFmt then
        lbFrame._lbTotalFmt = totalFmt
        lbFrame.totalText:SetText(LbCrestMarkup("Alliance", 24) .. "  " .. totalFmt
            .. "  " .. LbCrestMarkup("Horde", 24))
    end
    self:ApplySearch()

    self:RefreshInfoLines(dc)

    local startDate, endDate = Overlord:GetCampaignDateRange()
    local subFmt = string.format(L.LB_CAMPAIGN_DATE, startDate, endDate)
    if dc.fromSavedCache then
        subFmt = subFmt .. "  ·  " .. (L.LB_CACHED_REFRESHING or "Saved ranking · updating…")
    end
    if lbFrame._lbSubFmt ~= subFmt then
        lbFrame._lbSubFmt = subFmt
        lbFrame.subtitle:SetText(subFmt)
    end
end

function Overlord.LeaderboardUI:ApplyFrameScale(scale)
    if lbFrame and type(scale) == "number" and scale > 0 then
        FitLeaderboardFrameScale(scale)
    end
end

function Overlord.LeaderboardUI:Show()
    if not lbFrame then
        self:CreateFrame()
    end
    if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
        self:ApplyFrameScale(Overlord.UI:GetEffectiveUiScale())
    else
        self:ApplyFrameScale(1)
    end
    lbFrame:Show()
    -- Ouverture manuelle : repartir du haut ; refresh sync visibles : conserver le scroll.
    ResetLeaderboardScrollPositions()
    lbRefreshPending = false
    lbRefreshToken = lbRefreshToken + 1
    if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
    if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
        Overlord.UI:ScheduleActionGridActiveRefresh()
    end
    self:Refresh()
    lbRefreshLastAt = GetTime()
end

function Overlord.LeaderboardUI:Hide()
    if lbFrame and lbFrame:IsShown() and Overlord.PlayPanelCloseSound then
        Overlord:PlayPanelCloseSound()
    end
    if lbFrame then lbFrame:Hide() end
    lbRefreshPending = false
    lbRefreshToken = lbRefreshToken + 1
    if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
        Overlord.UI:ScheduleActionGridActiveRefresh()
    end
end

function Overlord.LeaderboardUI:Toggle()
    if lbFrame and lbFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function Overlord.LeaderboardUI:IsShown()
    return lbFrame ~= nil and lbFrame:IsShown()
end

function Overlord.LeaderboardUI:RequestRefresh()
    if not self:IsShown() then return end
    if lbRefreshPending then return end
    local now = GetTime()
    lbRefreshPending = true
    lbRefreshToken = lbRefreshToken + 1
    local token = lbRefreshToken
    -- Debounce aussi le premier paquet d'une rafale. L'ancien chemin le rendait tout de suite,
    -- puis reconstruisait le classement toutes les 350 ms pendant un SR/LK/LC massif.
    local earliest = math.max(now + LB_REFRESH_DEBOUNCE,
        lbRefreshLastAt + LB_REFRESH_MIN_INTERVAL)
    local delay = math.max(0.01, earliest - now)
    C_Timer.After(delay, function()
        if token ~= lbRefreshToken then return end
        lbRefreshPending = false
        if not Overlord.LeaderboardUI or not Overlord.LeaderboardUI:IsShown() then return end
        lbRefreshLastAt = GetTime()
        Overlord.LeaderboardUI:Refresh()
    end)
end

-- Rafraichissement sans ouvrir le panneau (nameplates / sync)
local lastRefreshIfVisibleAt = 0
local REFRESH_IF_VISIBLE_INTERVAL = 4
local refreshIfVisiblePending = false

function Overlord.LeaderboardUI:RefreshIfVisible()
    -- Les appels de cette voie viennent des registres secondaires (GK/OP/ressources/bounty).
    -- Invalider meme panneau ferme : sinon une mutation recue entre Hide et Show pouvait
    -- reutiliser pendant 30 s la liste de sites construite avant la mutation.
    -- Une mutation annule le worker en cours. Conserver les anciennes listes pendant
    -- le rebuild evite un panneau vide, mais le drapeau dirty contourne bien le TTL.
    lbVolatileLists.token = lbVolatileLists.token + 1
    lbVolatileLists.pending = false
    lbVolatileLists.dirty = true
    if not self:IsShown() then return end
    local now = GetTime()
    local elapsed = now - lastRefreshIfVisibleAt
    if lastRefreshIfVisibleAt == 0 or elapsed >= REFRESH_IF_VISIBLE_INTERVAL then
        lastRefreshIfVisibleAt = now
        self:RequestRefresh()
        return
    end
    -- Conserver le throttle 4 s, mais ne jamais perdre le dernier etat d'une rafale
    -- GK/GH/LO/LOC : un seul rendu trailing suffit pour afficher le registre converge.
    if refreshIfVisiblePending then return end
    refreshIfVisiblePending = true
    C_Timer.After(math.max(0.01, REFRESH_IF_VISIBLE_INTERVAL - elapsed), function()
        refreshIfVisiblePending = false
        local ui = Overlord.LeaderboardUI
        if not ui or not ui:IsShown() then return end
        lastRefreshIfVisibleAt = GetTime()
        ui:RequestRefresh()
    end)
end
