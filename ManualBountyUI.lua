-- ManualBountyUI.lua - Tableau de chasse autonome pour les primes en or
Overlord = Overlord or {}
Overlord.ManualBountyUI = {}

local L = Overlord.L
local UI = Overlord.UI
local C = {
    gold = { 0.85, 0.68, 0.20 },
    goldDim = { 0.55, 0.42, 0.12 },
    white = { 0.925, 0.937, 0.969 },
    muted = { 0.66, 0.66, 0.70 },
    red = { 0.86, 0.18, 0.12 },
    green = { 0.22, 0.78, 0.34 },
    panelBg = { 0.055, 0.045, 0.055, 0.94 },
}

local FRAME_W = 760
local FRAME_H = 620
local CONTENT_W = 708
local TARGET_ROW_H = 38
local CONTRACT_ROW_H = 64
local TARGET_POSTER_W = 418
local TARGET_POSTER_H = 170
-- Largeur utile du libelle guilde (affiche cible et liste).
local POSTER_GUILD_MAX_W = 268
local TARGET_META_MAX_W = 172
local TARGET_SEARCH_FOLD = {
    { "À", "a" }, { "Á", "a" }, { "Â", "a" }, { "Ã", "a" }, { "Ä", "a" }, { "Å", "a" },
    { "à", "a" }, { "á", "a" }, { "â", "a" }, { "ã", "a" }, { "ä", "a" }, { "å", "a" },
    { "Æ", "ae" }, { "æ", "ae" }, { "Ç", "c" }, { "ç", "c" },
    { "È", "e" }, { "É", "e" }, { "Ê", "e" }, { "Ë", "e" },
    { "è", "e" }, { "é", "e" }, { "ê", "e" }, { "ë", "e" },
    { "Ì", "i" }, { "Í", "i" }, { "Î", "i" }, { "Ï", "i" },
    { "ì", "i" }, { "í", "i" }, { "î", "i" }, { "ï", "i" },
    { "Ñ", "n" }, { "ñ", "n" },
    { "Ò", "o" }, { "Ó", "o" }, { "Ô", "o" }, { "Õ", "o" }, { "Ö", "o" }, { "Ø", "o" },
    { "ò", "o" }, { "ó", "o" }, { "ô", "o" }, { "õ", "o" }, { "ö", "o" }, { "ø", "o" },
    { "Œ", "oe" }, { "œ", "oe" },
    { "Ù", "u" }, { "Ú", "u" }, { "Û", "u" }, { "Ü", "u" },
    { "ù", "u" }, { "ú", "u" }, { "û", "u" }, { "ü", "u" },
    { "Ý", "y" }, { "Ÿ", "y" }, { "ý", "y" }, { "ÿ", "y" }, { "ß", "ss" },
}
local TARGET_SEARCH_FOLD_MAP = {}
for i = 1, #TARGET_SEARCH_FOLD do
    TARGET_SEARCH_FOLD_MAP[TARGET_SEARCH_FOLD[i][1]] = TARGET_SEARCH_FOLD[i][2]
end
-- Un match par caractere UTF-8, puis remplacement table en un seul gsub.
local TARGET_SEARCH_UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local panel
local blocker
local selectedTarget
local refreshPending = false
local CONTRACT_REFRESH_DEBOUNCE = 0.5
local BUILD_WORK_PER_SLICE = 64
local BUILD_MS_PER_SLICE = 1.25
local ShowConfirmation

local function BuildNowMs()
    if debugprofilestop then return debugprofilestop() end
    return (GetTime and GetTime() or 0) * 1000
end

local function GetLocalFullName()
    local sync = Overlord.Sync
    if sync and sync.GetPlayerFullName then
        return sync:GetPlayerFullName()
    end
    return Overlord:SafeUnitName("player", true)
end

local function NamesMatch(a, b)
    if not a or not b or a == "" or b == "" then return false end
    if a:lower() == b:lower() then return true end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        local ak = sync:GetCaptureContributorDedupKey(a)
        local bk = sync:GetCaptureContributorDedupKey(b)
        return ak ~= nil and bk ~= nil and ak == bk
    end
    return false
end

local function ShortName(name)
    return (name or ""):match("^([^%-]+)") or name or ""
end

-- Affichage : preferer la race live (communaute / LB) au token fige sur le contrat.
-- Corrige les primes posees quand Haranir tombait encore en BloodElf/Orc stale.
local function ResolveDisplayRace(playerName, storedRace, storedSex)
    local race = storedRace or ""
    local sex = math.floor(tonumber(storedSex) or 0)
    if playerName and playerName ~= "" and Overlord.Leaderboard
        and Overlord.Leaderboard.GetExportPlayerRace then
        local liveRace, liveSex = Overlord.Leaderboard:GetExportPlayerRace(playerName, true)
        if liveRace and liveRace ~= "" then
            race = liveRace
            liveSex = math.floor(tonumber(liveSex) or 0)
            if liveSex == 2 or liveSex == 3 then
                sex = liveSex
            end
        end
    end
    if sex ~= 2 and sex ~= 3 then sex = 0 end
    return race, sex
end

local mbMeasureByFont = {}

local function GetMeasureFontString(fontKey)
    if not panel or not fontKey then return nil end
    local measure = mbMeasureByFont[fontKey]
    if not measure then
        measure = panel:CreateFontString(nil, "OVERLAY", fontKey)
        mbMeasureByFont[fontKey] = measure
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
local mbTruncateCache = {}
local mbTruncateCacheCount = 0
local MB_TRUNCATE_CACHE_MAX = 256

local function CacheTruncatedText(cacheKey, value)
    if mbTruncateCacheCount >= MB_TRUNCATE_CACHE_MAX then
        mbTruncateCache = {}
        mbTruncateCacheCount = 0
    end
    mbTruncateCache[cacheKey] = value
    mbTruncateCacheCount = mbTruncateCacheCount + 1
    return value
end

local function TruncateTextToWidth(text, maxWidth, fontKey)
    if not text or text == "" then return text or "" end
    maxWidth = tonumber(maxWidth) or 0
    if maxWidth <= 0 then return text end
    fontKey = fontKey or "GameFontNormal"
    local cacheKey = text .. "\31" .. maxWidth .. "\31" .. fontKey
    local cached = mbTruncateCache[cacheKey]
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

local function FormatGuildPoster(guild)
    if not guild or guild == "" then return "" end
    local inner = TruncateTextToWidth(guild, POSTER_GUILD_MAX_W, "GameFontHighlight")
    return "<" .. inner .. ">"
end

local function FormatTargetMeta(guild, realm)
    local realmPart = realm or ""
    if not guild or guild == "" then
        return realmPart
    end
    local sep = "  |  "
    local suffix = sep .. realmPart
    local measure = GetMeasureFontString("GameFontNormalSmall")
    local suffixW = 0
    if measure then
        suffixW = MeasureTextWidth(measure, suffix, "GameFontNormalSmall", 5.5)
    else
        suffixW = #suffix * 5.5
    end
    local guildMax = TARGET_META_MAX_W - suffixW
    if guildMax <= 0 then
        return TruncateTextToWidth(guild .. suffix, TARGET_META_MAX_W, "GameFontNormalSmall")
    end
    return TruncateTextToWidth(guild, guildMax, "GameFontNormalSmall") .. suffix
end

local function StatusLabel(status)
    if status == "open" then return L.MB_STATUS_OPEN end
    if status == "claimed" then return L.MB_STATUS_CLAIMED end
    if status == "approved" then return L.MB_STATUS_APPROVED end
    if status == "paid" then return L.MB_STATUS_PAID end
    if status == "cancelled" then return L.MB_STATUS_CANCELLED end
    return status or ""
end

local function StatusColor(status)
    if status == "open" then return C.gold[1], C.gold[2], C.gold[3] end
    if status == "claimed" then return 1.0, 0.48, 0.12 end
    if status == "approved" then return 0.30, 0.72, 1.0 end
    if status == "paid" then return C.green[1], C.green[2], C.green[3] end
    return C.muted[1], C.muted[2], C.muted[3]
end

local function SetFactionSeal(texture, faction)
    if not texture or not texture.SetAtlas then return false end
    local atlas = (faction == "Alliance")
        and "Quest-Alliance-WaxSeal"
        or "Quest-Horde-WaxSeal"
    local ok = pcall(texture.SetAtlas, texture, atlas, true)
    if ok then
        texture:SetSize(50, 50)
        texture:SetVertexColor(1, 1, 1)
        texture:Show()
        return true
    end
    texture:Hide()
    return false
end

local function ShowError(msg)
    if not msg or msg == "" then return end
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. msg)
    end
end

local SCROLL_IND_UP = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up"
local SCROLL_IND_DOWN = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up"

-- Scroll sans template Blizzard : molette, fondus et indicateur compact toujours lisible.
local function CreateCleanScroll(parent, width, height)
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
    topFade:SetHeight(12)
    topFade:SetColorTexture(0, 0, 0, 0.28)
    topFade:Hide()

    local bottomFade = scroll:CreateTexture(nil, "OVERLAY")
    bottomFade:SetPoint("BOTTOMLEFT")
    bottomFade:SetPoint("BOTTOMRIGHT")
    bottomFade:SetHeight(12)
    bottomFade:SetColorTexture(0, 0, 0, 0.32)
    bottomFade:Hide()

    local scrollIndUp = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    scrollIndUp:SetTexture(SCROLL_IND_UP)
    scrollIndUp:SetSize(18, 18)
    scrollIndUp:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 1, -2)
    scrollIndUp:SetAlpha(0.8)
    scrollIndUp:Hide()

    local scrollIndDown = parent:CreateTexture(nil, "OVERLAY", nil, 6)
    scrollIndDown:SetTexture(SCROLL_IND_DOWN)
    scrollIndDown:SetSize(18, 18)
    scrollIndDown:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 1, 2)
    scrollIndDown:SetAlpha(0.8)
    scrollIndDown:Hide()

    local scrollTrack = parent:CreateTexture(nil, "OVERLAY", nil, 5)
    scrollTrack:SetWidth(3)
    scrollTrack:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, -22)
    scrollTrack:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 8, 22)
    scrollTrack:SetColorTexture(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.34)
    scrollTrack:Hide()

    local scrollThumb = CreateFrame("Button", nil, parent)
    scrollThumb:SetSize(14, 18)
    scrollThumb:SetFrameLevel(scroll:GetFrameLevel() + 4)
    scrollThumb:EnableMouse(true)
    scrollThumb:RegisterForDrag("LeftButton")
    local scrollThumbBar = scrollThumb:CreateTexture(nil, "OVERLAY", nil, 6)
    scrollThumbBar:SetWidth(5)
    scrollThumbBar:SetPoint("TOP", 0, -1)
    scrollThumbBar:SetPoint("BOTTOM", 0, 1)
    scrollThumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.88)
    scrollThumb:Hide()

    local function RefreshFades()
        local current = scroll:GetVerticalScroll()
        local maximum = scroll:GetVerticalScrollRange()
        local hasScroll = maximum > 2
        topFade:SetShown(current > 1)
        bottomFade:SetShown(maximum > 1 and current < maximum - 1)
        scrollIndUp:SetShown(hasScroll)
        scrollIndDown:SetShown(hasScroll)
        scrollIndUp:SetAlpha(current > 1 and 0.85 or 0.28)
        scrollIndDown:SetAlpha(current < maximum - 1 and 0.85 or 0.28)
        scrollTrack:SetShown(hasScroll)
        scrollThumb:SetShown(hasScroll)
        if hasScroll then
            local viewportHeight = math.max(1, scroll:GetHeight() or height)
            local contentHeight = math.max(viewportHeight, child:GetHeight() or viewportHeight)
            local trackHeight = math.max(1, viewportHeight - 44)
            local thumbHeight = math.max(18,
                math.min(trackHeight, trackHeight * viewportHeight / contentHeight))
            local travel = math.max(0, trackHeight - thumbHeight)
            local offset = maximum > 0 and travel * current / maximum or 0
            scrollThumb:ClearAllPoints()
            scrollThumb:SetSize(14, thumbHeight)
            -- Rail : x=8, largeur=3, centre=9.5. La poignee cliquable fait 14 px,
            -- donc son bord gauche doit etre a 2.5 pour garder la barre centree.
            scrollThumb:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 2.5, -22 - offset)
        end
    end

    local function GetScaledCursorY()
        local _, cursorY = GetCursorPosition()
        local scale = UIParent and UIParent:GetEffectiveScale() or 1
        if not scale or scale <= 0 then scale = 1 end
        return cursorY / scale
    end

    local function UpdateThumbDrag(self)
        local maximum = scroll:GetVerticalScrollRange()
        if maximum <= 2 then return end
        local trackTop = (scroll:GetTop() or 0) - 22
        local trackHeight = math.max(1, (scroll:GetHeight() or height) - 44)
        local travel = math.max(0, trackHeight - (self:GetHeight() or 18))
        if travel <= 0 then return end
        local wantedTop = GetScaledCursorY() + (self.dragOffset or 0)
        local offset = math.max(0, math.min(travel, trackTop - wantedTop))
        scroll:SetVerticalScroll(maximum * offset / travel)
        RefreshFades()
    end

    local function StopThumbDrag(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
        scrollThumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.88)
    end

    scrollThumb:SetScript("OnDragStart", function(self)
        if scroll:GetVerticalScrollRange() <= 2 then return end
        local cursorY = GetScaledCursorY()
        self.dragOffset = (self:GetTop() or cursorY) - cursorY
        self.dragging = true
        scrollThumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
        self:SetScript("OnUpdate", UpdateThumbDrag)
    end)
    scrollThumb:SetScript("OnDragStop", StopThumbDrag)
    scrollThumb:SetScript("OnHide", StopThumbDrag)
    scrollThumb:SetScript("OnEnter", function()
        scrollThumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
    end)
    scrollThumb:SetScript("OnLeave", function(self)
        if not self.dragging then
            scrollThumbBar:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.88)
        end
    end)

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maximum = self:GetVerticalScrollRange()
        local nextValue = self:GetVerticalScroll() - delta * 34
        self:SetVerticalScroll(math.max(0, math.min(maximum, nextValue)))
        RefreshFades()
    end)
    scroll:HookScript("OnVerticalScroll", RefreshFades)
    scroll.RefreshFades = RefreshFades
    scroll.content = child
    return scroll, child
end

local function CreateSectionTitle(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetText(text or "")
    fs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    fs:SetShadowOffset(1, -1)
    return fs
end

local function CreateActionButton(parent, width, text, callback)
    return UI.CreateWC3Button(
        parent,
        width,
        24,
        text,
        callback,
        nil,
        { gold = C.gold, white = C.white }
    )
end

local function SetSelectedRow(f, selected)
    if f._selectedRow and f._selectedRow ~= selected then
        f._selectedRow.selection:Hide()
        f._selectedRow:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.25)
    end
    f._selectedRow = selected
    if selected then
        selected.selection:Show()
        selected:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 0.85)
    end
end

local function UpdateTargetCard(f)
    if not f or not f.poster then return end
    local poster = f.poster
    if not selectedTarget then
        poster.raceIcon:Hide()
        poster.raceFrame:Hide()
        poster.nameFs:ClearAllPoints()
        poster.nameFs:SetPoint("CENTER", poster, "CENTER", 0, -4)
        poster.nameFs:SetWidth(340)
        poster.nameFs:SetJustifyH("CENTER")
        poster.nameFs:SetText(L.MB_NO_TARGET)
        poster.guildFs:SetText("")
        poster.realmFs:SetText("")
        poster.raceFs:SetText("")
        poster.wantedIcon:SetDesaturated(true)
        poster.wantedIcon:SetAlpha(0.30)
        f.postBtn:Disable()
        f.postBtn:SetAlpha(0.48)
        return
    end

    poster.raceFrame:Show()
    poster.nameFs:ClearAllPoints()
    poster.nameFs:SetPoint("TOPLEFT", poster.raceFrame, "TOPRIGHT", 17, -2)
    poster.nameFs:SetPoint("RIGHT", poster, "RIGHT", -18, 0)
    poster.nameFs:SetJustifyH("LEFT")
    poster.nameFs:SetText(ShortName(selectedTarget.name))
    if selectedTarget.guild and selectedTarget.guild ~= "" then
        poster.guildFs:SetText(FormatGuildPoster(selectedTarget.guild))
    else
        poster.guildFs:SetText("")
    end
    poster.realmFs:SetText(selectedTarget.realm or "")
    poster.raceFs:SetText(selectedTarget.race or "")
    SetFactionSeal(poster.wantedIcon, selectedTarget.faction)
    poster.wantedIcon:SetDesaturated(false)
    poster.wantedIcon:SetAlpha(0.95)
    if UI.SetRaceIcon then
        local race, raceSex = ResolveDisplayRace(
            selectedTarget.name, selectedTarget.race, selectedTarget.raceSex)
        local shown = UI.SetRaceIcon(poster.raceIcon, race, raceSex)
        poster.raceIcon:SetShown(shown and true or false)
    end
    f.postBtn:Enable()
    f.postBtn:SetAlpha(1)
end

local function TargetRowOnEnter(self)
    self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 0.75)
end

local function TargetRowOnLeave(self)
    local f = self.ownerPanel
    if f and f._selectedRow ~= self then
        self:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.25)
    end
end

local function TargetRowOnClick(self)
    local f = self.ownerPanel
    if not f or not self.target then return end
    selectedTarget = self.target
    SetSelectedRow(f, self)
    UpdateTargetCard(f)
end

local function CreateTargetRow(f)
    local row = CreateFrame("Button", nil, f.targetContent, "BackdropTemplate")
    row:SetSize(f.targetContent:GetWidth(), TARGET_ROW_H)
    row:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    row:SetBackdropColor(0.045, 0.04, 0.055, 0.76)

    row.selection = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.selection:SetPoint("TOPLEFT", 3, -3)
    row.selection:SetPoint("BOTTOMRIGHT", -3, 3)
    row.selection:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.10)

    row.raceIcon = row:CreateTexture(nil, "ARTWORK")
    row.raceIcon:SetSize(26, 26)
    row.raceIcon:SetPoint("LEFT", 6, 0)

    row.nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameFs:SetPoint("TOPLEFT", row.raceIcon, "TOPRIGHT", 7, -2)
    row.nameFs:SetPoint("RIGHT", row, "RIGHT", -5, 0)
    row.nameFs:SetJustifyH("LEFT")

    row.metaFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.metaFs:SetPoint("TOPLEFT", row.nameFs, "BOTTOMLEFT", 0, -1)
    row.metaFs:SetPoint("RIGHT", row, "RIGHT", -5, 0)
    row.metaFs:SetJustifyH("LEFT")
    row.metaFs:SetWordWrap(false)
    row.metaFs:SetMaxLines(1)
    row.metaFs:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

    row.ownerPanel = f
    row:SetScript("OnEnter", TargetRowOnEnter)
    row:SetScript("OnLeave", TargetRowOnLeave)
    row:SetScript("OnClick", TargetRowOnClick)
    return row
end

local function RefreshTargetRows(f)
    if not f or not f.targetContent or not f.targetScroll then return end
    local targets = f.targetData or {}
    local step = TARGET_ROW_H + 3
    local first = math.max(1,
        math.floor((f.targetScroll:GetVerticalScroll() or 0) / step) + 1)
    local visibleCount = math.ceil((f.targetScroll:GetHeight() or 0) / step) + 2
    f.targetRows = f.targetRows or {}
    local selectedName = selectedTarget and selectedTarget.name

    for slot = 1, visibleCount do
        local index = first + slot - 1
        local target = targets[index]
        local row = f.targetRows[slot]
        if not row then
            row = CreateTargetRow(f)
            f.targetRows[slot] = row
        end
        if target then
            if row._mbDataIndex ~= index then
                row._mbDataIndex = index
                row._mbPaintKey = nil
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, -((index - 1) * step))
            end
            row.target = target
            local race, raceSex = ResolveDisplayRace(target.name, target.race, target.raceSex)
            local paintKey = index .. "|" .. tostring(target.name) .. "|"
                .. tostring(target.guild) .. "|" .. tostring(target.realm) .. "|"
                .. tostring(race) .. "|" .. tostring(raceSex) .. "|"
                .. ((selectedName and NamesMatch(selectedName, target.name)) and "1" or "0")
            if row._mbPaintKey ~= paintKey then
                row._mbPaintKey = paintKey
                row.selection:Hide()
                row:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.25)
                if UI.SetRaceIcon then
                    row.raceIcon:SetShown(
                        UI.SetRaceIcon(row.raceIcon, race, raceSex) and true or false)
                end
                row.nameFs:SetText(ShortName(target.name))
                row.metaFs:SetText(FormatTargetMeta(target.guild, target.realm))
            end
            row:Show()
            if selectedTarget and NamesMatch(selectedTarget.name, target.name) then
                selectedTarget = target
                SetSelectedRow(f, row)
            end
        else
            row:Hide()
            row.target = nil
            row._mbPaintKey = nil
            row._mbDataIndex = nil
        end
    end

    for i = visibleCount + 1, #f.targetRows do
        f.targetRows[i]:Hide()
        f.targetRows[i].target = nil
        f.targetRows[i]._mbPaintKey = nil
        f.targetRows[i]._mbDataIndex = nil
    end
end

local function NormalizeTargetSearch(value)
    value = value or ""
    value = value:gsub(TARGET_SEARCH_UTF8_CHAR, TARGET_SEARCH_FOLD_MAP)
    return (value:lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

local function TargetMatchesSearch(target, query)
    if not target or query == "" then return true end
    return (target._searchText or ""):find(query, 1, true) ~= nil
end

local function ApplyTargetFilter(f, resetScroll)
    if not f or not f.targetContent or not f.targetScroll then return end
    local allTargets = f.allTargetData or {}
    local query = NormalizeTargetSearch(
        f.targetSearchBox and f.targetSearchBox:GetText() or "")
    f._targetFilterToken = (f._targetFilterToken or 0) + 1
    local token = f._targetFilterToken
    local function commit(targets)
        if token ~= f._targetFilterToken then return end
        f.filteredTargetData = query ~= "" and targets or f.filteredTargetData
        f.targetData = targets
        f.targetContent:SetHeight(math.max(1, #targets * (TARGET_ROW_H + 3)))
        if resetScroll then f.targetScroll:SetVerticalScroll(0) end
        SetSelectedRow(f, nil)
        RefreshTargetRows(f)
        if f.targetEmptyFs then
            f.targetEmptyFs:SetText(
                query ~= "" and L.MB_SEARCH_NO_RESULTS or L.MB_NO_KNOWN_TARGETS)
            f.targetEmptyFs:SetShown(#targets == 0)
        end
        f.targetScroll:RefreshFades()
    end
    if query == "" then
        commit(allTargets)
        return
    end

    -- Le filtre peut porter sur 10k noms. Construire une nouvelle vue puis la
    -- publier atomiquement; les frappes suivantes annulent seulement le worker,
    -- jamais la liste actuellement visible.
    local filtered = {}
    local index = 1
    local function runSlice()
        if token ~= f._targetFilterToken then return end
        local startedAt = BuildNowMs()
        local work = 0
        while index <= #allTargets and work < BUILD_WORK_PER_SLICE
            and BuildNowMs() - startedAt < BUILD_MS_PER_SLICE do
            if TargetMatchesSearch(allTargets[index], query) then
                filtered[#filtered + 1] = allTargets[index]
            end
            index = index + 1
            work = work + 1
        end
        if index <= #allTargets then
            C_Timer.After(0, runSlice)
        else
            commit(filtered)
        end
    end
    C_Timer.After(0, runSlice)
end

local RebuildTargetList
RebuildTargetList = function(f, requestedRevision, force)
    if not f or not f.targetContent then return end
    local mb = Overlord.ManualBounty
    if not mb then return end
    requestedRevision = requestedRevision or (mb.GetTargetRevision
        and mb:GetTargetRevision() or -1)
    local state = f._targetListBuild or { token = 0 }
    f._targetListBuild = state
    if state.running then
        state.wantedRevision = requestedRevision
        return
    end
    if state.retryPending then
        if state.revision == requestedRevision then return end
        state.token = state.token + 1
        state.retryPending = false
    end
    if not force and state.failedRevision == requestedRevision then return end
    if state.revision ~= requestedRevision then
        state.failCount, state.failedRevision = 0, nil
    end

    state.token = state.token + 1
    local token = state.token
    state.running = true
    state.revision = requestedRevision
    state.wantedRevision = nil
    local worker = coroutine.create(function()
        local function yieldWork() coroutine.yield() end
        local targets = mb:GetKnownEnemyTargets(yieldWork) or {}
        local targetsByKey = {}
        local sync = Overlord.Sync
        for i = 1, #targets do
            local target = targets[i]
            target._searchText = NormalizeTargetSearch(
                (target.name or "") .. " " .. (target.realm or "") .. " "
                    .. (target.guild or ""))
            local key = sync and sync.GetCaptureContributorDedupKey
                and sync:GetCaptureContributorDedupKey(target.name)
                or (target.name or ""):lower()
            if key and key ~= "" then targetsByKey[key:lower()] = target end
            yieldWork()
        end
        return targets, targetsByKey
    end)

    local function runSlice()
        if token ~= state.token then return end
        local startedAt = BuildNowMs()
        local work = 0
        while coroutine.status(worker) ~= "dead" and work < BUILD_WORK_PER_SLICE
            and BuildNowMs() - startedAt < BUILD_MS_PER_SLICE do
            local ok, targets, targetsByKey = coroutine.resume(worker)
            if not ok then
                state.running = false
                state.failCount = (state.failCount or 0) + 1
                if state.failCount <= 3 then
                    state.retryPending = true
                    local delay = math.min(5, state.failCount)
                    C_Timer.After(delay, function()
                        if token ~= state.token then return end
                        state.retryPending = false
                        RebuildTargetList(f, requestedRevision, true)
                    end)
                else
                    state.failedRevision = requestedRevision
                end
                return
            end
            work = work + 1
            if coroutine.status(worker) == "dead" then
                state.running = false
                state.failCount, state.failedRevision = 0, nil
                if selectedTarget and selectedTarget.name then
                    local sync = Overlord.Sync
                    local key = sync and sync.GetCaptureContributorDedupKey
                        and sync:GetCaptureContributorDedupKey(selectedTarget.name)
                        or selectedTarget.name:lower()
                    selectedTarget = key and targetsByKey[key:lower()] or nil
                    if not selectedTarget then SetSelectedRow(f, nil) end
                end
                f.allTargetData = targets
                f._targetRevision = requestedRevision
                ApplyTargetFilter(f, false)
                UpdateTargetCard(f)
                local currentRevision = mb.GetTargetRevision
                    and mb:GetTargetRevision() or requestedRevision
                if currentRevision ~= requestedRevision or state.wantedRevision then
                    C_Timer.After(0, function()
                        RebuildTargetList(f, currentRevision)
                    end)
                end
                return
            end
        end
        C_Timer.After(0, runSlice)
    end
    C_Timer.After(0, runSlice)
end

local function ContractActionOnClick(self)
    local row = self:GetParent()
    local contract = row and row.contract
    local mb = Overlord.ManualBounty
    if not contract or not mb then return end

    if self.actionType == "cancel" then
        local ok, err = mb:CancelContract(contract.id)
        if not ok then ShowError(err) else Overlord.ManualBountyUI:Refresh() end
    elseif self.actionType == "authorize" then
        ShowConfirmation(
            L.MB_CONFIRM_APPROVE_TITLE,
            string.format(L.MB_CONFIRM_APPROVE_BODY,
                contract.id, contract.target, contract.claimer,
                mb:FormatCopper(contract.amountCopper)),
            L.MB_BTN_AUTHORIZE,
            function()
                local ok, err = mb:AuthorizePayment(contract.id)
                if not ok then ShowError(err) else Overlord.ManualBountyUI:Refresh() end
            end,
            L.MB_BTN_REJECT,
            function()
                local ok, err = mb:CancelContract(contract.id)
                if not ok then ShowError(err) else Overlord.ManualBountyUI:Refresh() end
            end
        )
    elseif self.actionType == "payment" then
        local mail = Overlord.ManualBountyMail
        if mail and mail.PreparePayment then
            local ok, err = mail:PreparePayment(contract.id)
            if not ok then
                ShowError(err)
            else
                Overlord.ManualBountyUI:Hide()
            end
        end
    elseif self.actionType == "cod" then
        local mail = Overlord.ManualBountyMail
        if mail and mail.PrepareCodPayment then
            local ok, err = mail:PrepareCodPayment(contract.id)
            if not ok then
                ShowError(err)
            else
                Overlord.ManualBountyUI:Hide()
            end
        end
    elseif self.actionType == "paid" then
        ShowConfirmation(
            L.MB_CONFIRM_PAID_TITLE,
            string.format(L.MB_CONFIRM_PAID_BODY,
                contract.id, contract.claimer, mb:FormatCopper(contract.amountCopper)),
            L.MB_BTN_PAID,
            function()
                local ok, err = mb:MarkPaid(contract.id)
                if not ok then ShowError(err) else Overlord.ManualBountyUI:Refresh() end
            end
        )
    end
end

local function ScheduleSettlementRefresh(remaining)
    if not panel or panel._settlementRefreshScheduled then return end
    panel._settlementRefreshScheduled = true
    C_Timer.After(math.max(0.1, tonumber(remaining) or 0) + 0.1, function()
        if not panel then return end
        panel._settlementRefreshScheduled = false
        panel._contractRevision = nil
        Overlord.ManualBountyUI:Refresh()
    end)
end

local function UpdateContractAction(row, contract, me)
    local button = row.actionButton
    button:Hide()
    button:Enable()
    button:SetAlpha(1)
    button.actionType = nil
    if contract.status == "open" and NamesMatch(contract.poster, me) then
        button:SetWidth(78)
        button.label:SetText(L.MB_BTN_CANCEL)
        button.actionType = "cancel"
    elseif contract.status == "claimed" and NamesMatch(contract.poster, me) then
        local remaining = Overlord.ManualBounty:GetClaimSettlementRemaining(contract)
        button:SetWidth(110)
        if remaining > 0 then
            button.label:SetText(string.format(L.MB_BTN_SETTLING, math.ceil(remaining)))
            button:Disable()
            button:SetAlpha(0.55)
            row.eligibilityFs:SetText(L.MB_CONTRACT_SETTLING)
            row.eligibilityFs:Show()
            ScheduleSettlementRefresh(remaining)
        else
            button.label:SetText(L.MB_BTN_REVIEW)
            button.actionType = "authorize"
        end
    elseif contract.status == "approved" and NamesMatch(contract.poster, me) then
        button:SetWidth(118)
        local entry = Overlord.ManualBounty:GetLocalSettlementEntry(contract.id)
        if entry and ((tonumber(entry.paymentSentAt) or 0) > 0
            or (tonumber(entry.codInvoiceSeenAt) or 0) > 0) then
            button.label:SetText(L.MB_BTN_PAID)
            button.actionType = "paid"
            row.eligibilityFs:SetText((tonumber(entry.codInvoiceSeenAt) or 0) > 0
                and L.MB_CONTRACT_COD_RECEIVED or L.MB_CONTRACT_PAYMENT_SENT)
            row.eligibilityFs:Show()
        else
            button.label:SetText(L.MB_BTN_DIRECT_PAYMENT)
            button.actionType = "payment"
        end
    elseif contract.status == "approved" and NamesMatch(contract.claimer, me) then
        local mail = Overlord.ManualBountyMail
        if mail and mail.WasCodInvoiceSent and mail:WasCodInvoiceSent(contract.id) then
            row.eligibilityFs:SetText(L.MB_CONTRACT_COD_SENT)
            row.eligibilityFs:Show()
        else
            button:SetWidth(118)
            button.label:SetText(L.MB_BTN_COD)
            button.actionType = "cod"
        end
    end
    if button.actionType or not button:IsEnabled() then button:Show() end
end

local function CreateContractRow(f)
    local row = CreateFrame("Frame", nil, f.contractContent, "BackdropTemplate")
    row:SetSize(f.contractContent:GetWidth(), CONTRACT_ROW_H)
    row:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 9,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    row:SetBackdropColor(0.04, 0.035, 0.05, 0.84)
    row:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.34)

    row.raceIcon = row:CreateTexture(nil, "ARTWORK")
    row.raceIcon:SetSize(38, 38)
    row.raceIcon:SetPoint("LEFT", 9, 0)

    row.targetFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.targetFs:SetPoint("TOPLEFT", row.raceIcon, "TOPRIGHT", 9, -2)
    row.targetFs:SetWidth(148)
    row.targetFs:SetJustifyH("LEFT")

    -- Colonne or : centrée verticalement comme l'icône de race, à droite avant le bouton.
    row.amountFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.amountFs:SetPoint("RIGHT", row, "RIGHT", -132, 0)
    row.amountFs:SetWidth(88)
    row.amountFs:SetJustifyH("RIGHT")
    row.amountFs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    row.statusFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.statusFs:SetPoint("TOPLEFT", row.targetFs, "BOTTOMLEFT", 0, -4)

    row.ownerFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.ownerFs:SetPoint("LEFT", row.statusFs, "RIGHT", 8, 0)
    row.ownerFs:SetPoint("RIGHT", row.amountFs, "LEFT", -10, 0)
    row.ownerFs:SetJustifyH("LEFT")
    row.ownerFs:SetWordWrap(false)
    row.ownerFs:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

    row.eligibilityFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.eligibilityFs:SetPoint("BOTTOMLEFT", row.raceIcon, "BOTTOMRIGHT", 9, 2)
    row.eligibilityFs:SetPoint("RIGHT", row.amountFs, "LEFT", -10, 0)
    row.eligibilityFs:SetJustifyH("LEFT")
    row.eligibilityFs:SetWordWrap(false)
    row.eligibilityFs:SetMaxLines(1)
    row.eligibilityFs:SetTextColor(0.52, 0.52, 0.56)
    local eligibilityFont, eligibilitySize, eligibilityFlags = row.eligibilityFs:GetFont()
    if eligibilityFont and eligibilitySize then
        row.eligibilityFs:SetFont(
            eligibilityFont, math.max(8, eligibilitySize - 1), eligibilityFlags)
    end
    row.eligibilityFs:Hide()

    row.actionButton = CreateActionButton(row, 110, "", ContractActionOnClick)
    row.actionButton:SetPoint("RIGHT", -18, 0)
    row.actionButton:Hide()
    return row
end

local function RefreshContractRows(f)
    if not f or not f.contractContent or not f.contractScroll then return end
    local contracts = f.contractData or {}
    local mb = Overlord.ManualBounty
    if not mb then return end
    local me = GetLocalFullName()
    local step = CONTRACT_ROW_H + 5
    local first = math.max(1,
        math.floor((f.contractScroll:GetVerticalScroll() or 0) / step) + 1)
    local visibleCount = math.ceil((f.contractScroll:GetHeight() or 0) / step) + 2
    f.contractRows = f.contractRows or {}

    for slot = 1, visibleCount do
        local index = first + slot - 1
        local contract = contracts[index]
        local row = f.contractRows[slot]
        if not row then
            row = CreateContractRow(f)
            f.contractRows[slot] = row
        end
        if contract then
            if row._mbDataIndex ~= index then
                row._mbDataIndex = index
                row._mbPaintKey = nil
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, -((index - 1) * step))
            end
            row.contract = contract
            local race, raceSex = ResolveDisplayRace(
                contract.target, contract.targetRace, contract.targetRaceSex)
            local paymentCompatible = mb.IsHunterPaymentCompatible
                and mb:IsHunterPaymentCompatible(contract, me) or false
            local unavailable = contract.status == "open" and not paymentCompatible
            local paintKey = index .. "|" .. tostring(contract.id or contract.target) .. "|"
                .. tostring(contract.status) .. "|" .. tostring(contract.amountCopper) .. "|"
                .. tostring(contract.poster) .. "|" .. tostring(contract.claimer) .. "|"
                .. tostring(race) .. "|" .. tostring(raceSex) .. "|"
                .. (unavailable and "1" or "0")
            if row._mbPaintKey ~= paintKey then
                row._mbPaintKey = paintKey
                if UI.SetRaceIcon then
                    row.raceIcon:SetShown(
                        UI.SetRaceIcon(row.raceIcon, race, raceSex) and true or false)
                end
                row.targetFs:SetText(ShortName(contract.target))
                row.amountFs:SetText(mb:FormatCopper(contract.amountCopper))
                local r, g, b = StatusColor(contract.status)
                row.statusFs:SetText(StatusLabel(contract.status))
                if contract.status ~= "open" and contract.claimer and contract.claimer ~= "" then
                    row.ownerFs:SetText(string.format(
                        L.MB_CONTRACT_CLAIMER,
                        ShortName(contract.poster),
                        ShortName(contract.claimer)
                    ))
                else
                    row.ownerFs:SetText(string.format(
                        L.MB_CONTRACT_POSTER,
                        ShortName(contract.poster)
                    ))
                end
                if unavailable then
                    row:SetBackdropColor(0.035, 0.035, 0.04, 0.62)
                    row:SetBackdropBorderColor(0.28, 0.28, 0.31, 0.34)
                    row.raceIcon:SetDesaturated(true)
                    row.raceIcon:SetAlpha(0.38)
                    row.targetFs:SetTextColor(0.55, 0.55, 0.59)
                    row.amountFs:SetTextColor(0.48, 0.48, 0.52)
                    row.statusFs:SetTextColor(0.48, 0.48, 0.52)
                    row.ownerFs:SetTextColor(0.46, 0.46, 0.50)
                    row.eligibilityFs:SetText(L.MB_CONTRACT_REMOTE_REALM)
                    row.eligibilityFs:Show()
                else
                    row:SetBackdropColor(0.04, 0.035, 0.05, 0.84)
                    row:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.34)
                    row.raceIcon:SetDesaturated(false)
                    row.raceIcon:SetAlpha(1)
                    row.targetFs:SetTextColor(C.white[1], C.white[2], C.white[3])
                    row.amountFs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
                    row.statusFs:SetTextColor(r, g, b)
                    row.ownerFs:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
                    row.eligibilityFs:Hide()
                end
            end
            UpdateContractAction(row, contract, me)
            row:Show()
        else
            row:Hide()
            row.contract = nil
            row._mbPaintKey = nil
            row._mbDataIndex = nil
        end
    end

    for i = visibleCount + 1, #f.contractRows do
        f.contractRows[i]:Hide()
        f.contractRows[i].contract = nil
        f.contractRows[i]._mbPaintKey = nil
        f.contractRows[i]._mbDataIndex = nil
    end
end

local RebuildContractList
RebuildContractList = function(f, requestedRevision, force)
    if not f or not f.contractContent then return end
    local mb = Overlord.ManualBounty
    if not mb then return end
    requestedRevision = requestedRevision or (mb.GetRevision and mb:GetRevision() or -1)
    local state = f._contractListBuild or { token = 0 }
    f._contractListBuild = state
    if state.running then
        state.wantedRevision = requestedRevision
        return
    end
    if state.retryPending then
        if state.revision == requestedRevision then return end
        state.token = state.token + 1
        state.retryPending = false
    end
    if not force and state.failedRevision == requestedRevision then return end
    if state.revision ~= requestedRevision then
        state.failCount, state.failedRevision = 0, nil
    end

    state.token = state.token + 1
    local token = state.token
    state.running = true
    state.revision = requestedRevision
    state.wantedRevision = nil
    local worker = coroutine.create(function()
        local function yieldWork() coroutine.yield() end
        return mb:GetSortedContracts(yieldWork) or {}
    end)
    local function runSlice()
        if token ~= state.token then return end
        local startedAt = BuildNowMs()
        local work = 0
        while coroutine.status(worker) ~= "dead" and work < BUILD_WORK_PER_SLICE
            and BuildNowMs() - startedAt < BUILD_MS_PER_SLICE do
            local ok, contracts = coroutine.resume(worker)
            if not ok then
                state.running = false
                state.failCount = (state.failCount or 0) + 1
                if state.failCount <= 3 then
                    state.retryPending = true
                    C_Timer.After(math.min(5, state.failCount), function()
                        if token ~= state.token then return end
                        state.retryPending = false
                        RebuildContractList(f, requestedRevision, true)
                    end)
                else
                    state.failedRevision = requestedRevision
                end
                return
            end
            work = work + 1
            if coroutine.status(worker) == "dead" then
                state.running = false
                state.failCount, state.failedRevision = 0, nil
                f.contractData = contracts
                f.contractContent:SetHeight(
                    math.max(1, #contracts * (CONTRACT_ROW_H + 5)))
                RefreshContractRows(f)
                f.contractEmptyFs:SetShown(#contracts == 0)
                f.contractScroll:RefreshFades()
                f._contractRevision = requestedRevision
                local currentRevision = mb.GetRevision
                    and mb:GetRevision() or requestedRevision
                if currentRevision ~= requestedRevision or state.wantedRevision then
                    C_Timer.After(0, function()
                        RebuildContractList(f, currentRevision)
                    end)
                end
                return
            end
        end
        C_Timer.After(0, runSlice)
    end
    C_Timer.After(0, runSlice)
end

-- Coalescer le scroll : une seule passe de lignes par frame.
local function ScheduleTargetScrollRefresh(f)
    if not f or f._targetScrollPending then return end
    f._targetScrollPending = true
    C_Timer.After(0, function()
        if not f then return end
        f._targetScrollPending = false
        RefreshTargetRows(f)
    end)
end

local function ScheduleContractScrollRefresh(f)
    if not f or f._contractScrollPending then return end
    f._contractScrollPending = true
    C_Timer.After(0, function()
        if not f then return end
        f._contractScrollPending = false
        RefreshContractRows(f)
    end)
end

local function CreatePoster(parent)
    local poster = UI.CreateWC3SubPanel(parent, TARGET_POSTER_W, TARGET_POSTER_H, {
        panelBg = { 0.10, 0.065, 0.035, 0.92 },
        borderColor = C.gold,
        borderAlpha = 0.72,
    })

    local parchment = poster:CreateTexture(nil, "BACKGROUND", nil, 1)
    parchment:SetPoint("TOPLEFT", 4, -4)
    parchment:SetPoint("BOTTOMRIGHT", -4, 4)
    parchment:SetTexture("Interface\\ACHIEVEMENTFRAME\\UI-Achievement-Parchment-Horizontal")
    parchment:SetTexCoord(0, 1, 0, 1)
    parchment:SetVertexColor(0.58, 0.43, 0.24, 0.34)

    poster.wantedIcon = poster:CreateTexture(nil, "ARTWORK")
    poster.wantedIcon:SetSize(50, 50)
    poster.wantedIcon:SetPoint("TOPRIGHT", -14, -12)
    SetFactionSeal(poster.wantedIcon, Overlord.PlayerFaction == "Alliance" and "Horde" or "Alliance")

    poster.raceFrame = CreateFrame("Frame", nil, poster, "BackdropTemplate")
    poster.raceFrame:SetSize(76, 76)
    poster.raceFrame:SetPoint("LEFT", 24, 0)
    poster.raceFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    poster.raceFrame:SetBackdropColor(0.03, 0.025, 0.035, 0.96)
    poster.raceFrame:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 0.78)

    poster.raceIcon = poster.raceFrame:CreateTexture(nil, "ARTWORK")
    poster.raceIcon:SetPoint("TOPLEFT", 6, -6)
    poster.raceIcon:SetPoint("BOTTOMRIGHT", -6, 6)

    poster.nameFs = poster:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    poster.nameFs:SetPoint("TOPLEFT", poster.raceFrame, "TOPRIGHT", 17, -2)
    poster.nameFs:SetPoint("RIGHT", poster, "RIGHT", -18, 0)
    poster.nameFs:SetJustifyH("LEFT")
    poster.nameFs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    poster.nameFs:SetShadowOffset(2, -2)

    poster.guildFs = poster:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    poster.guildFs:SetPoint("TOPLEFT", poster.nameFs, "BOTTOMLEFT", 0, -5)
    poster.guildFs:SetPoint("RIGHT", poster, "RIGHT", -18, 0)
    poster.guildFs:SetJustifyH("LEFT")
    poster.guildFs:SetWordWrap(false)
    poster.guildFs:SetMaxLines(1)

    poster.realmFs = poster:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    poster.realmFs:SetPoint("TOPLEFT", poster.guildFs, "BOTTOMLEFT", 0, -5)
    poster.realmFs:SetJustifyH("LEFT")
    poster.realmFs:SetTextColor(C.white[1], C.white[2], C.white[3])

    poster.raceFs = poster:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    poster.raceFs:SetPoint("TOPLEFT", poster.realmFs, "BOTTOMLEFT", 0, -4)
    poster.raceFs:SetJustifyH("LEFT")
    poster.raceFs:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

    return poster
end

local function CreateAmountEntry(parent)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(144, 34)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(5)
    box:SetJustifyH("RIGHT")
    box:SetTextInsets(8, 30, 0, 0)
    box:SetFontObject(GameFontHighlight)
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0.035, 0.03, 0.045, 0.96)
    box:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.75)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.75)
    end)
    box:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        if (tonumber(self:GetText()) or 0) > 10000 then
            self:SetText("10000")
            self:SetCursorPosition(5)
        end
    end)

    local coin = box:CreateTexture(nil, "ARTWORK")
    coin:SetSize(21, 21)
    coin:SetPoint("RIGHT", -6, 0)
    coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    return box
end

local function CreateTargetSearchEntry(parent, ownerPanel, width)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width or TARGET_POSTER_W, 30)
    box:SetAutoFocus(false)
    box:SetMaxLetters(48)
    box:SetJustifyH("LEFT")
    box:SetTextInsets(9, 9, 0, 0)
    box:SetFontObject(GameFontHighlight)
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0.035, 0.03, 0.045, 0.96)
    box:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.75)

    box.placeholder = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    box.placeholder:SetPoint("LEFT", 9, 0)
    box.placeholder:SetPoint("RIGHT", -9, 0)
    box.placeholder:SetJustifyH("LEFT")
    box.placeholder:SetText(L.MB_SEARCH_PLACEHOLDER)
    box.placeholder:SetTextColor(C.muted[1], C.muted[2], C.muted[3], 0.78)

    local function RefreshPlaceholder(self)
        self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus())
    end
    box:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then
            self:SetText("")
        else
            self:ClearFocus()
        end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
        self:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        RefreshPlaceholder(self)
        self:SetBackdropBorderColor(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.75)
    end)
    box:SetScript("OnTextChanged", function(self)
        RefreshPlaceholder(self)
        ApplyTargetFilter(ownerPanel, true)
    end)
    RefreshPlaceholder(box)
    return box
end

local function EnsureConfirmationDialog(f)
    if f.confirmShield then return end
    local shield = CreateFrame("Button", nil, f)
    shield:SetAllPoints(f)
    shield:SetFrameLevel(f:GetFrameLevel() + 40)
    shield:EnableMouse(true)
    local shade = shield:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.72)

    local dialog = CreateFrame("Frame", nil, shield, "BackdropTemplate")
    dialog:SetSize(520, 290)
    dialog:SetPoint("CENTER")
    dialog:SetFrameLevel(shield:GetFrameLevel() + 2)
    UI.ApplyWoodDialogBackdrop(dialog, {
        borderColor = C.gold,
        borderAlpha = 0.88,
        fallbackBg = C.panelBg,
    })

    dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dialog.title:SetPoint("TOP", 0, -20)
    dialog.title:SetWidth(460)
    dialog.title:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    dialog.body = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dialog.body:SetPoint("TOP", dialog.title, "BOTTOM", 0, -16)
    dialog.body:SetWidth(460)
    dialog.body:SetHeight(150)
    dialog.body:SetJustifyH("LEFT")
    dialog.body:SetJustifyV("TOP")
    dialog.body:SetWordWrap(true)

    local function hide()
        dialog.onConfirm = nil
        dialog.onSecondary = nil
        shield:Hide()
    end

    dialog.cancelBtn = UI.CreateWC3Button(
        dialog, 128, 30, L.MB_BTN_BACK, hide, nil,
        { gold = C.gold, white = C.white })
    dialog.cancelBtn:SetPoint("BOTTOMLEFT", 18, 18)

    dialog.secondaryBtn = UI.CreateWC3Button(
        dialog, 128, 30, "", function()
            local callback = dialog.onSecondary
            hide()
            if callback then callback() end
        end, nil, { gold = C.gold, white = C.white })
    dialog.secondaryBtn:SetPoint("BOTTOM", 0, 18)

    dialog.confirmBtn = UI.CreateWC3Button(
        dialog, 128, 30, "", function()
            local callback = dialog.onConfirm
            hide()
            if callback then callback() end
        end, nil, { gold = C.gold, white = C.white })
    dialog.confirmBtn:SetPoint("BOTTOMRIGHT", -18, 18)

    shield:Hide()
    f.confirmShield = shield
    f.confirmDialog = dialog
end

ShowConfirmation = function(title, body, confirmText, onConfirm, secondaryText, onSecondary)
    if not panel then return end
    EnsureConfirmationDialog(panel)
    local dialog = panel.confirmDialog
    dialog.title:SetText(title or "")
    dialog.body:SetText(body or "")
    dialog.confirmBtn.label:SetText(confirmText or L.MB_BTN_CONFIRM)
    dialog.onConfirm = onConfirm
    dialog.onSecondary = onSecondary
    dialog.secondaryBtn:SetShown(secondaryText ~= nil and onSecondary ~= nil)
    if secondaryText then dialog.secondaryBtn.label:SetText(secondaryText) end
    panel.confirmShield:Show()
end

local function EnsurePanel()
    if panel then return panel end

    local f = CreateFrame("Frame", "OverlordManualBountyPanel", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    UI.ApplyWoodDialogBackdrop(f)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(6100)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    f:Hide()
    panel = f
    tinsert(UISpecialFrames, f:GetName())

    blocker = CreateFrame("Button", nil, UIParent)
    blocker:SetFrameStrata("FULLSCREEN_DIALOG")
    blocker:SetFrameLevel(6098)
    blocker:SetAllPoints(UIParent)
    blocker:EnableMouse(true)
    blocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    blocker:SetScript("OnClick", function()
        Overlord.ManualBountyUI:Hide()
    end)
    blocker:Hide()

    f:SetScript("OnShow", function(self)
        blocker:Show()
        if UI.GetEffectiveUiScale then
            self:SetScale(UI:GetEffectiveUiScale())
        else
            self:SetScale(1)
        end
        if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
        Overlord.ManualBountyUI:Refresh()
        -- Laisser le panneau se peindre avant le scan roster ponctuel. Aucun
        -- catalogue complet ne tourne tant que le joueur ne l'ouvre pas.
        C_Timer.After(0, function()
            if self:IsShown() and Overlord.ManualBountySync
                and Overlord.ManualBountySync.RequestCatalogSync then
                Overlord.ManualBountySync:RequestCatalogSync()
            end
        end)
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)
    f:SetScript("OnHide", function()
        blocker:Hide()
        if f.confirmShield then f.confirmShield:Hide() end
        f._targetFilterToken = (f._targetFilterToken or 0) + 1
        for _, state in ipairs({ f._targetListBuild, f._contractListBuild }) do
            if state then
                state.token = (state.token or 0) + 1
                state.running = false
                state.retryPending = false
            end
        end
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            Overlord.ManualBountyUI:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:EnableKeyboard(true)

    local closeX = UI.CreateWC3CloseButton(f, function()
        Overlord.ManualBountyUI:Hide()
    end, { gold = C.gold })
    closeX:SetPoint("TOPRIGHT", -10, -10)

    local titleFs = f:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    titleFs:SetPoint("TOP", 0, -18)
    titleFs:SetText(L.MB_TITLE)
    titleFs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    titleFs:SetShadowOffset(2, -2)

    local hintFs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintFs:SetPoint("TOP", titleFs, "BOTTOM", 0, -7)
    hintFs:SetWidth(650)
    hintFs:SetJustifyH("CENTER")
    hintFs:SetText(L.MB_HINT)
    hintFs:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

    -- Colonne de gauche : registre des cibles connues.
    local roster = UI.CreateWC3SubPanel(f, 266, 266, {
        panelBg = C.panelBg,
        borderColor = C.goldDim,
        borderAlpha = 0.55,
    })
    roster:SetPoint("TOPLEFT", 26, -90)
    f.roster = roster

    local targetsTitle = CreateSectionTitle(roster, L.MB_TARGETS_LABEL)
    targetsTitle:SetPoint("TOPLEFT", 12, -10)

    -- Gouttiere a droite reservee a l'indicateur de defilement, hors des lignes.
    f.targetScroll, f.targetContent = CreateCleanScroll(roster, 216, 211)
    f.targetScroll:SetPoint("TOPLEFT", 12, -43)
    f.targetScroll:HookScript("OnVerticalScroll", function()
        ScheduleTargetScrollRefresh(f)
    end)

    f.targetEmptyFs = roster:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.targetEmptyFs:SetPoint("TOPLEFT", 17, -52)
    f.targetEmptyFs:SetPoint("BOTTOMRIGHT", -17, 18)
    f.targetEmptyFs:SetJustifyH("CENTER")
    f.targetEmptyFs:SetJustifyV("MIDDLE")
    f.targetEmptyFs:SetWordWrap(true)
    f.targetEmptyFs:SetText(L.MB_NO_KNOWN_TARGETS)
    f.targetEmptyFs:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
    f.targetEmptyFs:Hide()

    -- Colonne de droite : affiche de la cible et montant.
    f.poster = CreatePoster(f)
    f.poster:SetPoint("TOPRIGHT", -26, -90)

    f.targetSearchBox = CreateTargetSearchEntry(f, f, TARGET_POSTER_W)
    f.targetSearchBox:SetPoint("TOPRIGHT", f.poster, "BOTTOMRIGHT", 0, -6)

    local amountPanel = UI.CreateWC3SubPanel(f, TARGET_POSTER_W, 44, {
        panelBg = C.panelBg,
        borderColor = C.goldDim,
        borderAlpha = 0.55,
    })
    amountPanel:SetPoint("TOPRIGHT", f.targetSearchBox, "BOTTOMRIGHT", 0, -6)

    local amountLabel = amountPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    amountLabel:SetPoint("LEFT", 13, 0)
    amountLabel:SetText(L.MB_AMOUNT_LABEL)
    amountLabel:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    f.amountBox = CreateAmountEntry(amountPanel)
    f.amountBox:SetPoint("RIGHT", -147, 0)

    f.postBtn = UI.CreateWC3Button(
        amountPanel,
        132,
        30,
        L.MB_BTN_POST,
        function()
            local mb = Overlord.ManualBounty
            if not mb or not selectedTarget then
                ShowError(L.MB_ERR_NO_TARGET)
                return
            end
            if not Overlord.InActiveFront then
                ShowError(L.MB_ERR_NOT_ON_FRONT)
                return
            end
            -- La liste des cibles peut etre reconstruite pendant que la confirmation
            -- est ouverte. Figer le nom evite que le callback relise une selection
            -- devenue nil (ou remplacee) apres un rafraichissement asynchrone.
            local confirmedTarget = {
                name = selectedTarget.name,
                class = selectedTarget.class,
                faction = selectedTarget.faction,
                race = selectedTarget.race,
                raceSex = selectedTarget.raceSex,
                guild = selectedTarget.guild,
                realm = selectedTarget.realm,
                communityEligible = selectedTarget.communityEligible == true,
            }
            local targetName = confirmedTarget.name
            if not targetName or targetName == "" then
                ShowError(L.MB_ERR_NO_TARGET)
                return
            end
            local gold = tonumber(f.amountBox:GetText()) or 0
            local amountCopper = math.floor(gold * 10000)
            if amountCopper < mb.MIN_COPPER or amountCopper > mb.MAX_COPPER then
                ShowError(L.MB_ERR_AMOUNT)
                return
            end
            local exposure = mb:GetOutstandingExposureCopper() + amountCopper
            ShowConfirmation(
                L.MB_CONFIRM_POST_TITLE,
                string.format(L.MB_CONFIRM_POST_BODY,
                    targetName, mb:FormatCopper(amountCopper),
                    mb:FormatCopper(exposure)),
                L.MB_BTN_POST,
                function()
                    local _, err = mb:CreateContract(targetName, amountCopper, confirmedTarget)
                    if err then
                        ShowError(err)
                    else
                        f.amountBox:SetText("")
                        Overlord.ManualBountyUI:Refresh()
                    end
                end
            )
        end,
        nil,
        { gold = C.gold, white = C.white }
    )
    f.postBtn:SetPoint("RIGHT", -7, 0)

    -- Partie basse : tableau des contrats sur toute la largeur.
    local contractsPanel = UI.CreateWC3SubPanel(f, CONTENT_W, 190, {
        panelBg = C.panelBg,
        borderColor = C.goldDim,
        borderAlpha = 0.55,
    })
    contractsPanel:SetPoint("TOPLEFT", 26, -372)

    local contractsTitle = CreateSectionTitle(
        contractsPanel,
        L.MB_CONTRACTS_LABEL
    )
    contractsTitle:SetPoint("TOPLEFT", 12, -10)

    f.exposureFs = contractsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.exposureFs:SetPoint("TOPRIGHT", -16, -14)
    f.exposureFs:SetTextColor(1.0, 0.55, 0.18)

    -- Gouttiere a droite reservee aux fleches, hors des lignes.
    f.contractScroll, f.contractContent = CreateCleanScroll(contractsPanel, 658, 137)
    f.contractScroll:SetPoint("TOPLEFT", 12, -43)
    f.contractScroll:HookScript("OnVerticalScroll", function()
        ScheduleContractScrollRefresh(f)
    end)

    f.contractEmptyFs = contractsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.contractEmptyFs:SetPoint("TOPLEFT", 18, -53)
    f.contractEmptyFs:SetPoint("BOTTOMRIGHT", -18, 15)
    f.contractEmptyFs:SetJustifyH("CENTER")
    f.contractEmptyFs:SetJustifyV("MIDDLE")
    f.contractEmptyFs:SetText(L.MB_NO_CONTRACTS)
    f.contractEmptyFs:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
    f.contractEmptyFs:Hide()

    local closeBtn = UI.CreateWC3Button(
        f,
        128,
        30,
        L.MB_BTN_CLOSE,
        function() Overlord.ManualBountyUI:Hide() end,
        nil,
        { gold = C.gold, white = C.white }
    )
    -- Centre vertical dans le pied visible (hors bordure doree du dialog bois en bas).
    local FOOTER_BORDER_BOTTOM = 14
    local footerVisualH = FRAME_H - 372 - 190 - FOOTER_BORDER_BOTTOM
    closeBtn:SetPoint("TOP", contractsPanel, "BOTTOM", 0, -math.floor((footerVisualH - 30) / 2))

    UpdateTargetCard(f)
    return f
end

function Overlord.ManualBountyUI:Refresh()
    local f = panel
    if not f or not f:IsShown() then return end
    local mb = Overlord.ManualBounty
    local revision = mb and mb:GetRevision() or -1
    local targetRevision = mb and mb.GetTargetRevision
        and mb:GetTargetRevision() or -1

    if f.exposureFs and mb and mb.GetOutstandingExposureCopper then
        f.exposureFs:SetText(string.format(
            L.MB_EXPOSURE, mb:FormatCopper(mb:GetOutstandingExposureCopper())))
    end

    if f._targetRevision ~= targetRevision then
        RebuildTargetList(f, targetRevision)
    end
    if f._contractRevision ~= revision then
        RebuildContractList(f, revision)
    end
end

local function RunRequestedRefresh()
    refreshPending = false
    Overlord.ManualBountyUI:Refresh()
end

function Overlord.ManualBountyUI:RequestRefresh()
    if not panel or not panel:IsShown() or refreshPending then return end
    refreshPending = true
    C_Timer.After(CONTRACT_REFRESH_DEBOUNCE, RunRequestedRefresh)
end

function Overlord.ManualBountyUI:Toggle()
    local f = EnsurePanel()
    if f:IsShown() then
        f:Hide()
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        ShowError(L.CANNOT_IN_COMBAT)
        return
    end
    f:Show()
end

function Overlord.ManualBountyUI:Hide()
    if panel then panel:Hide() end
end

function Overlord.ManualBountyUI:IsShown()
    return panel and panel:IsShown() or false
end

function Overlord.ManualBountyUI:Show()
    local f = EnsurePanel()
    if InCombatLockdown and InCombatLockdown() then
        ShowError(L.CANNOT_IN_COMBAT)
        return
    end
    f:Show()
end

function Overlord.ManualBountyUI:Initialize()
    if self._initialized then return end
    self._initialized = true
end
