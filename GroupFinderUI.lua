-- PvP group finder window (rules and protocol: GroupFinder.lua).
-- Left: the groups recruiting. Right: the player's own listing, or the form to publish
-- one. Built on first use; repainted only while shown and only when something changed
-- (one coalesced pass, per-row paint keys, fixed row pool, no OnUpdate).
Overlord = Overlord or {}
local GFUI = Overlord.GroupFinderUI or {}
Overlord.GroupFinderUI = GFUI

-- Layout in one table (one upvalue for every builder).
local K = {
    W = 664, H = 520, H_MIN = 486, H_MAX = 640, PAD = 16, FOOT = 42, DOCK_GAP = 8,
    CROWN_SCALE = 0.668, CROWN_OVERHANG = 6,
    BAND_TOP = 34, BAND_H = 64, CLOTH_ALPHA = 0.95,
    BODY_TOP = 108,
    LIST_W = 396, CARD_W = 226, CARD_IN = 206,
    HEAD_H = 24, ROW_H = 44, MAX_ROWS = 10,
    REQ_ROWS = 4, REQ_H = 24,
    -- The form, from the top of its card: four label + control blocks, the option and
    -- its help text; the button and the reason from the bottom. The help text ends
    -- above the button whatever the height (three lines fit at H_MIN).
    FORM_TOP = -30, FORM_PITCH = 44, FORM_AUTO = -206, FORM_HELP = -229, FORM_HELP_GAP = 6,
    PUBLISH_Y = 34, PUBLISH_H = 30, REASON_Y = 7,
    REFRESH_MIN = 0.25,
}
GFUI.LAYOUT = K
local P = {
    gold = { 1, 0.82, 0 },
    goldDim = { 0.55, 0.42, 0.12 },
    cream = { 0.95, 0.88, 0.70 },
    text = { 0.92, 0.92, 0.92 },
    muted = { 0.62, 0.60, 0.56 },
    good = { 0.35, 0.86, 0.42 },
    bad = { 0.95, 0.38, 0.32 },
    rowOdd = { 0.10, 0.09, 0.08, 0.55 },
    rowEven = { 0.05, 0.05, 0.05, 0.40 },
    rowOwn = { 0.30, 0.22, 0.04, 0.55 },
}
local INTENT_ICON = {
    a = "Interface\\Icons\\Ability_Warrior_OffensiveStance",
    d = "Interface\\Icons\\Ability_Defend",
    h = "Interface\\Icons\\Ability_Hunter_SniperShot",
}
local INTENT_KEY = {
    a = { "GF_INTENT_ATTACK", "Attack" },
    d = { "GF_INTENT_DEFEND", "Defend" },
    h = { "GF_INTENT_HUNT", "Hunt" },
}
-- Answer to the player's sign-up: text and colour of the row's right end.
local STATE_KEY = {
    sent = { "GF_STATE_SENT", "Sent…", "gold" },
    pending = { "GF_STATE_PENDING", "Waiting", "gold" },
    invited = { "GF_STATE_INVITED", "Invited", "good" },
    declined = { "GF_STATE_DECLINED", "Declined", "bad" },
    full = { "GF_STATE_FULL", "Full", "bad" },
    gone = { "GF_STATE_GONE", "Withdrawn", "muted" },
    level = { "GF_STATE_LEVEL", "Level too low", "bad" },
    timeout = { "GF_STATE_TIMEOUT", "No answer", "muted" },
    lost = { "GF_STATE_LOST", "Not received", "bad" },
}
local LIVE_KEY = {
    sending = { "GF_LIVE_SENDING", "Publishing…", "gold" },
    live = { "GF_LIVE_ONLINE", "Listing online", "good" },
    retry = { "GF_LIVE_RETRY", "Busy, trying again…", "gold" },
    channel = { "GF_LIVE_CHANNEL", "Connecting…", "gold" },
    closed = { "GF_LIVE_CLOSED", "Group search unavailable for now", "bad" },
}
-- What an empty board says, by state of the channel (GF:ChannelState).
local EMPTY_KEY = {
    closed = { "GF_LIVE_CLOSED", "Group search unavailable for now" },
    connecting = { "GF_LIVE_CHANNEL", "Connecting…" },
    listening = { "GF_EMPTY_LISTENING", "Listening for groups…" },
    open = { "GF_EMPTY_TITLE", "No group is recruiting right now." },
}

local frame
local boardBuf = {}
-- Rows shown: what the list's height holds (the pool is K.MAX_ROWS).
GFUI.rows = GFUI.rows or math.floor((K.H - K.BODY_TOP - K.FOOT - K.HEAD_H - 4) / K.ROW_H)

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function Finder()
    return Overlord.GroupFinder
end

local function IntentText(intent)
    local key = INTENT_KEY[intent]
    return key and T(key[1], key[2]) or ""
end

local function ClassRGB(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return c.r, c.g, c.b end
    return 0.9, 0.9, 0.9
end

local function FormatClock(seconds)
    seconds = math.max(0, math.ceil(seconds))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Text of a refusal key returned by the finder (with its level or its time left).
local function Reason(key, arg)
    if not key then return "" end
    local text = T(key, key)
    if arg ~= nil then
        if key == "GF_ERR_COOLDOWN" then arg = FormatClock(arg) end
        local ok, out = pcall(string.format, text, arg)
        if ok then return out end
    end
    return text
end

local function Color(fontString, name, alpha)
    local c = P[name] or P.text
    fontString:SetTextColor(c[1], c[2], c[3], alpha or 1)
end

local function ClickSound()
    local cfg = OverlordDB and OverlordDB.config
    if cfg and cfg.soundEnabled == false then return end
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
end

local function TipLine(text, name, wrap)
    local c = P[name] or P.text
    GameTooltip:AddLine(text, c[1], c[2], c[3], wrap)
end

-- ---------------------------------------------------------------------------
-- Decoration
-- ---------------------------------------------------------------------------

-- Trading Post crown stretched to the window width without scaling the crest: the two
-- caps and the centre keep their ratio, the plain bar between them stretches (a
-- two-pixel slice). A group is of one faction, so the crown shows the player's half
-- only, mirrored onto the other side: lion caps and blue bar for the Alliance, Horde
-- caps and red bar for the Horde. The mirror line is the centre of the medallion
-- (column 264 of the 527 px wide atlas, measured on the texture: the W is symmetric
-- there, one column off and it loses its middle). Each side is cut where the bar is
-- bare, so no cloth is sliced.
local function BuildCrown(f)
    if not (C_Texture and C_Texture.GetAtlasInfo) then return end
    local ok, info = pcall(C_Texture.GetAtlasInfo, "perks-theme-hordevsalliance-tp-topbig")
    if not ok or type(info) ~= "table" then return end
    local file = info.file or info.filename
    local w, h = tonumber(info.width), tonumber(info.height)
    local l, r = tonumber(info.leftTexCoord), tonumber(info.rightTexCoord)
    local t, b = tonumber(info.topTexCoord), tonumber(info.bottomTexCoord)
    if not (file and w and h and l and r and t and b) or w <= 0 or h <= 0 then return end
    local s = K.CROWN_SCALE
    local unit = w / 527
    -- Columns fromCol..toCol (mirrored when they decrease), the top `rows` rows of the
    -- 108 (all of them when nil).
    local function piece(fromCol, toCol, rows)
        local tex = f:CreateTexture(nil, "OVERLAY", nil, 6)
        tex:SetTexture(file)
        local bottom, height = b, h * s
        if rows then
            bottom = t + (b - t) * rows / 108
            height = rows * (h / 108) * s
        end
        tex:SetTexCoord(l + (r - l) * fromCol / 527, l + (r - l) * toCol / 527, t, bottom)
        tex:SetHeight(height)
        return tex
    end
    -- Row 50 of the atlas sits on the window's top edge, as on the main panel.
    local above = 50 * (h / 108) * s
    -- The faction's half, from the outer cap to the medallion's centre: cap (lion and
    -- wing, or spiked corner with its banner and swag), bare bar slice, then the centre
    -- as strips read from the medallion outwards: { inner column, outer column, rows }.
    local capOuter, capInner, barOuter, barInner = 0, 92, 96, 98
    -- Alliance: the Horde cloth of the original hangs under the medallion (columns
    -- 243-264, from row 76 down, it looked like blood dripping); these strips stop at
    -- the rim. The outermost strip keeps its full height.
    local strips = { { 264, 251, 82 }, { 251, 247, 78 }, { 247, 243, 76 }, { 243, 102 } }
    if Overlord.PlayerFaction == "Horde" then
        capOuter, capInner, barOuter, barInner = 527, 350, 348, 346
        strips = { { 264, 344 } }
    end
    local capW = math.abs(capInner - capOuter) * unit * s
    local crown = {}
    -- Left side as read from the outside in; right side its mirror (columns swapped).
    local function side(mirrored)
        local cap = mirrored and piece(capInner, capOuter) or piece(capOuter, capInner)
        cap:SetWidth(capW)
        if mirrored then
            cap:SetPoint("TOPRIGHT", f, "TOPRIGHT", K.CROWN_OVERHANG, above)
        else
            cap:SetPoint("TOPLEFT", f, "TOPLEFT", -K.CROWN_OVERHANG, above)
        end
        local outermost
        for _, strip in ipairs(strips) do
            local inner, outer, rows = strip[1], strip[2], strip[3]
            local tex = mirrored and piece(inner, outer, rows) or piece(outer, inner, rows)
            tex:SetWidth(math.abs(inner - outer) * unit * s)
            if mirrored then
                if outermost then
                    tex:SetPoint("TOPLEFT", outermost, "TOPRIGHT")
                else
                    tex:SetPoint("TOPLEFT", f, "TOP", 0, above)
                end
            elseif outermost then
                tex:SetPoint("TOPRIGHT", outermost, "TOPLEFT")
            else
                tex:SetPoint("TOPRIGHT", f, "TOP", 0, above)
            end
            outermost = tex
            crown[#crown + 1] = tex
        end
        local bar = mirrored and piece(barInner, barOuter) or piece(barOuter, barInner)
        if mirrored then
            bar:SetPoint("TOPLEFT", outermost, "TOPRIGHT")
            bar:SetPoint("BOTTOMRIGHT", cap, "BOTTOMLEFT")
        else
            bar:SetPoint("TOPLEFT", cap, "TOPRIGHT")
            bar:SetPoint("BOTTOMRIGHT", outermost, "BOTTOMLEFT")
        end
        crown[#crown + 1] = bar
        crown[#crown + 1] = cap
    end
    side(false)
    side(true)
    f.crown = crown
end

-- Title band on the cloth of the domination bar (same file), the player's faction
-- only and once: its emblem end at the left, at its own ratio, then the plain cloth
-- stretched to the right end (the emblem is never stretched nor repeated). Dimmed so
-- the title reads on it.
local function BuildBand(f)
    local band = CreateFrame("Frame", nil, f, "BackdropTemplate")
    band:SetPoint("TOPLEFT", f, "TOPLEFT", K.PAD, -K.BAND_TOP)
    band:SetPoint("TOPRIGHT", f, "TOPRIGHT", -K.PAD, -K.BAND_TOP)
    band:SetHeight(K.BAND_H)
    band:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    band:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
    band:SetBackdropBorderColor(P.goldDim[1], P.goldDim[2], P.goldDim[3], 0.85)

    local isHorde = Overlord.PlayerFaction == "Horde"
    local innerH = K.BAND_H - 6
    local innerW = K.W - 2 * K.PAD - 6
    -- Same scale as a half of the domination bar's cloth: 235 file pixels per half band.
    local scale = (innerW / 2) / 235
    local emblemEnd = band:CreateTexture(nil, "ARTWORK")
    emblemEnd:SetPoint("TOPLEFT", 3, -3)
    emblemEnd:SetSize(90 * scale, innerH)
    local plainCloth = band:CreateTexture(nil, "ARTWORK")
    plainCloth:SetPoint("TOPLEFT", emblemEnd, "TOPRIGHT")
    plainCloth:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", -3, 3)
    local clothFile
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, info = pcall(C_Texture.GetAtlasInfo, "AllianceScenario-TitleBG")
        clothFile = ok and type(info) == "table" and (info.file or info.filename) or nil
    end
    if clothFile then
        -- File pixels (512 x 512): blue cloth x 5-240 with its lion in the last 90
        -- columns (150-240), red cloth x 250-485 with its emblem in 395-485, y 291-360.
        -- The middle strip in height. Read from the emblem end, so the emblem sits left.
        local halfV = math.min(34.5, innerH / scale / 2)
        local top, bottom = (325.5 - halfV) / 512, (325.5 + halfV) / 512
        local emblem, cut, plain = 240 / 512, 150 / 512, 5 / 512
        if isHorde then emblem, cut, plain = 485 / 512, 395 / 512, 250 / 512 end
        emblemEnd:SetTexture(clothFile)
        emblemEnd:SetTexCoord(emblem, cut, top, bottom)
        emblemEnd:SetVertexColor(1, 1, 1, K.CLOTH_ALPHA)
        plainCloth:SetTexture(clothFile)
        plainCloth:SetTexCoord(cut, plain, top, bottom)
        plainCloth:SetVertexColor(1, 1, 1, K.CLOTH_ALPHA)
        if not isHorde then
            -- The blue cloth is darker than the red: an additive copy lifts it a little.
            for index, part in ipairs({ emblemEnd, plainCloth }) do
                local lift = band:CreateTexture(nil, "ARTWORK", nil, 1)
                lift:SetAllPoints(part)
                lift:SetTexture(clothFile)
                if index == 1 then
                    lift:SetTexCoord(emblem, cut, top, bottom)
                else
                    lift:SetTexCoord(cut, plain, top, bottom)
                end
                lift:SetBlendMode("ADD")
                lift:SetVertexColor(1, 1, 1, 0.22 * K.CLOTH_ALPHA)
            end
        end
    else
        local r, g, b = 0.2, 0.45, 0.85
        if isHorde then r, g, b = 0.75, 0.15, 0.15 end
        emblemEnd:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
        emblemEnd:SetVertexColor(r, g, b, 0.75)
        plainCloth:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
        plainCloth:SetVertexColor(r, g, b, 0.75)
    end
    local shade = band:CreateTexture(nil, "ARTWORK", nil, 2)
    shade:SetPoint("TOPLEFT", 3, -3)
    shade:SetPoint("BOTTOMRIGHT", -3, 3)
    shade:SetColorTexture(0, 0, 0, 0.25)

    local title = band:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    title:SetPoint("TOP", band, "TOP", 0, -10)
    -- The faction's battle cry, in the game's own wording of each language.
    title:SetText(isHorde and T("GF_TITLE_HORDE", "For the Horde!")
        or T("GF_TITLE_ALLIANCE", "For the Alliance!"))
    Color(title, "gold")
    title:SetShadowOffset(1, -1)
    title:SetShadowColor(0, 0, 0, 0.9)
    local subtitle = band:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("BOTTOM", band, "BOTTOM", 0, 10)
    Color(subtitle, "cream")
    subtitle:SetShadowOffset(1, -1)
    subtitle:SetShadowColor(0, 0, 0, 0.9)
    f.subtitle = subtitle
end

-- Section title on a strip of the player's own cloth.
local function BuildHead(panel, width, text)
    local head = panel:CreateTexture(nil, "ARTWORK")
    head:SetPoint("TOPLEFT", 4, -4)
    head:SetSize(width - 8, K.HEAD_H - 4)
    head:SetColorTexture(0.03, 0.03, 0.04, 0.85)
    local line = panel:CreateTexture(nil, "ARTWORK", nil, 1)
    line:SetPoint("TOPLEFT", head, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT")
    line:SetHeight(1)
    line:SetColorTexture(P.goldDim[1], P.goldDim[2], P.goldDim[3], 0.7)
    local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", head, "LEFT", 8, 0)
    label:SetText(text)
    Color(label, "gold")
    return label, head
end

-- ---------------------------------------------------------------------------
-- Small controls
-- ---------------------------------------------------------------------------

-- A row of exclusive buttons. items = { { value, label }, ... }
local function BuildSegment(parent, items, totalWidth, onPick)
    local segment = { buttons = {} }
    local gap = 4
    local width = (totalWidth - gap * (#items - 1)) / #items
    for index, item in ipairs(items) do
        local btn = Overlord.UI.CreateWC3Button(parent, width, 24, item[2], function()
            ClickSound()
            onPick(item[1])
        end)
        btn.value = item[1]
        if index == 1 then
            segment.first = btn
        else
            btn:SetPoint("LEFT", segment.buttons[index - 1], "RIGHT", gap, 0)
        end
        segment.buttons[index] = btn
    end
    function segment:Set(value)
        if self.value == value then return end
        self.value = value
        for _, btn in ipairs(self.buttons) do
            Overlord.UI.SetWC3ButtonActive(btn, btn.value == value)
        end
    end
    return segment
end

local function BuildCheck(parent, text, onToggle)
    local box = CreateFrame("Button", nil, parent)
    box:SetSize(22, 22)
    local bg = box:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetAllPoints()
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:Hide()
    box:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", box, "RIGHT", 2, 1)
    label:SetText(text)
    box.check = check
    function box:SetChecked(value)
        self.checked = value and true or false
        self.check:SetShown(self.checked)
    end
    box:SetScript("OnClick", function(self)
        self:SetChecked(not self.checked)
        ClickSound()
        onToggle(self.checked)
    end)
    return box
end

local function BuildLabel(parent, text, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y)
    label:SetText(text)
    Color(label, "muted")
    return label
end

-- ---------------------------------------------------------------------------
-- Place picker
-- ---------------------------------------------------------------------------

local function FrontLabel(front)
    return front.dropdownLabel or front.mapName or front.id
end

local function SortedSites()
    local sites, list = Overlord.OutpostSites, {}
    if type(sites) ~= "table" then return list end
    for siteKey in pairs(sites) do list[#list + 1] = siteKey end
    table.sort(list)
    return list
end

function GFUI:SetFormTarget(kind, target)
    local form = self.form
    if not form then return end
    form.kind, form.target = kind, target or ""
    self.formError = nil
    self:Refresh()
end

function GFUI:OpenTargetMenu(anchor)
    local fronts = Overlord.Fronts
    if not (fronts and fronts.Order and fronts.Registry) then return end
    if MenuUtil and MenuUtil.CreateContextMenu then
        local ok = pcall(function()
            MenuUtil.CreateContextMenu(anchor, function(_, root)
                root:CreateButton(T("GF_TARGET_ANYWHERE", "Anywhere"), function()
                    GFUI:SetFormTarget("w", "")
                end)
                for _, frontId in ipairs(fronts.Order) do
                    local front = fronts.Registry[frontId]
                    if front then
                        local sub = root:CreateButton(FrontLabel(front))
                        sub:CreateButton(T("GF_TARGET_WHOLE_FRONT", "Whole front"), function()
                            GFUI:SetFormTarget("f", frontId)
                        end)
                        local zones = Overlord.Zones and Overlord.Zones.GetDisplayOrderForFront
                            and Overlord.Zones:GetDisplayOrderForFront(frontId)
                        if type(zones) ~= "table" or #zones == 0 then zones = front.zones or {} end
                        for _, zone in ipairs(zones) do
                            local zoneId = zone.id
                            sub:CreateButton(zone.name or zoneId, function()
                                GFUI:SetFormTarget("z", zoneId)
                            end)
                        end
                    end
                end
                local outpost = Overlord.Outpost
                local siteKeys = SortedSites()
                if outpost and outpost.GetSite and #siteKeys > 0 then
                    local sub = root:CreateButton(T("GF_TARGET_SITES", "Outposts and keeps"))
                    for _, siteKey in ipairs(siteKeys) do
                        local site = outpost:GetSite(siteKey)
                        if site then
                            local name = outpost.GetDisplayName and outpost:GetDisplayName(site) or siteKey
                            sub:CreateButton(name, function() GFUI:SetFormTarget("o", siteKey) end)
                        end
                    end
                end
            end)
        end)
        if ok then return end
    end
    -- No menu on this client: each click moves to the next whole front, then anywhere.
    local form = self.form
    local order = fronts.Order
    local nextIndex = 1
    if form.kind == "f" then
        for index, frontId in ipairs(order) do
            if frontId == form.target then nextIndex = index + 1 end
        end
    end
    if order[nextIndex] then
        self:SetFormTarget("f", order[nextIndex])
    else
        self:SetFormTarget("w", "")
    end
end

-- ---------------------------------------------------------------------------
-- The board (left)
-- ---------------------------------------------------------------------------

local function RowOnEnter(row)
    local entry, gf = row.entry, Finder()
    if not entry or not gf or not GameTooltip then return end
    row.hover:Show()
    local info = entry.info
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    TipLine(IntentText(entry.intent) .. " · " .. (info and info.name or ""), "gold")
    if info and info.frontName and info.frontName ~= "" and info.frontName ~= info.name then
        TipLine(string.format(T("GF_TIP_FRONT", "Front: %s"), info.frontName), "text")
    end
    local r, g, b = ClassRGB(gf.CLASSES[entry.class])
    GameTooltip:AddLine(string.format(T("GF_TIP_LEADER", "Leader: %s"), entry.name) .. "  "
        .. string.format(T("GF_ROW_LEVEL", "level %d"), entry.level), r, g, b)
    TipLine(string.format(T("GF_TIP_MEMBERS", "Members: %d / %d"), entry.count, entry.cap), "text")
    if entry.minLevel > 0 then
        TipLine(string.format(T("GF_ROW_MIN_LEVEL", "level %d+"), entry.minLevel), "text")
    end
    TipLine(entry.auto and T("GF_MODE_AUTO", "automatic invitation")
        or T("GF_MODE_MANUAL", "leader approves"), "text")
    if not entry.isOwn then
        local ok, reason, arg = gf:CanSignUp(entry)
        if not ok then TipLine(Reason(reason, arg), "bad", true) end
        TipLine(T("GF_TIP_COOLDOWN", "You can join a group every 2 minutes."), "muted", true)
    end
    if info and (info.kind == "z" or info.kind == "o") then
        TipLine(T("GF_TIP_MAP", "Click: waypoint on the map."), "muted", true)
    end
    GameTooltip:Show()
end

local function RowOnLeave(row)
    row.hover:Hide()
    if GameTooltip then GameTooltip:Hide() end
end

-- A row hidden under the mouse (the list got shorter, the window closed) gets no
-- OnLeave: its highlight and its tooltip go with it.
local function RowOnHide(row)
    row.hover:Hide()
    if GameTooltip and GameTooltip:IsOwned(row) then GameTooltip:Hide() end
end

local function RowOnClick(row)
    local entry, gf = row.entry, Finder()
    if entry and gf and entry.info then gf:ShowOnMap(entry.info) end
end

local function SignUpOnClick(btn)
    local row, gf = btn.row, Finder()
    local entry = row and row.entry
    if not entry or not gf or entry.isOwn then return end
    ClickSound()
    local ok, reason, arg = gf:SignUp(entry.key)
    if not ok and reason and Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. Reason(reason, arg))
    end
    GFUI:Refresh()
end

local function SignUpOnEnter(btn)
    local row, gf = btn.row, Finder()
    local entry = row and row.entry
    if not entry or not gf or not GameTooltip then return end
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    local ok, reason, arg = gf:CanSignUp(entry)
    if ok then
        TipLine(T("GF_SIGNUP", "Sign up"), "gold")
        TipLine(T("GF_TIP_COOLDOWN", "You can join a group every 2 minutes."), "muted", true)
    else
        TipLine(Reason(reason, arg), "bad", true)
    end
    GameTooltip:Show()
end

local function BuildRow(list, index)
    local row = CreateFrame("Button", nil, list)
    row:SetSize(K.LIST_W - 8, K.ROW_H)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -(K.HEAD_H + 2) - (index - 1) * K.ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.hover = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1, 0.82, 0, 0.07)
    row.hover:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(30, 30)
    row.icon:SetPoint("LEFT", row, "LEFT", 9, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 47, -7)
    row.title:SetWidth(190)     -- ends before the widest head count ("40/40")
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    row.classIcon = row:CreateTexture(nil, "ARTWORK")
    row.classIcon:SetSize(14, 14)
    row.classIcon:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 47, 7)
    row.leader = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.leader:SetPoint("LEFT", row.classIcon, "RIGHT", 4, 0)
    row.leader:SetWidth(153)    -- ends before the fill bar
    row.leader:SetJustifyH("LEFT")
    row.leader:SetWordWrap(false)

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.count:SetPoint("TOPRIGHT", row, "TOPRIGHT", -108, -8)
    row.count:SetJustifyH("RIGHT")
    row.barBg = row:CreateTexture(nil, "ARTWORK")
    row.barBg:SetSize(56, 5)
    row.barBg:SetPoint("TOPRIGHT", row, "TOPRIGHT", -108, -27)
    row.barBg:SetColorTexture(0, 0, 0, 0.6)
    row.bar = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.bar:SetPoint("TOPLEFT", row.barBg, "TOPLEFT")
    row.bar:SetHeight(5)
    row.bar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")

    row.button = Overlord.UI.CreateWC3Button(row, 94, 24, T("GF_SIGNUP", "Sign up"), SignUpOnClick)
    row.button:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.button.row = row
    row.button:HookScript("OnEnter", SignUpOnEnter)
    row.button:HookScript("OnLeave", GameTooltip_Hide or function() GameTooltip:Hide() end)
    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.status:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.status:SetWidth(94)
    row.status:SetJustifyH("CENTER")

    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)
    row:SetScript("OnHide", RowOnHide)
    row:SetScript("OnClick", RowOnClick)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta) GFUI:Scroll(-delta) end)
    row:Hide()
    return row
end

local function BuildList(f)
    local list = Overlord.UI.CreateWC3SubPanel(f, K.LIST_W, K.H - K.BODY_TOP - K.FOOT)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", K.PAD, -K.BODY_TOP)
    f.list = list
    local _, head = BuildHead(list, K.LIST_W, T("GF_LIST_HEADER", "Groups recruiting"))
    list.page = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    list.page:SetPoint("RIGHT", head, "RIGHT", -8, 0)
    list.rows = {}
    for index = 1, K.MAX_ROWS do list.rows[index] = BuildRow(list, index) end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta) GFUI:Scroll(-delta) end)

    list.emptyIcon = list:CreateTexture(nil, "ARTWORK")
    list.emptyIcon:SetSize(44, 44)
    list.emptyIcon:SetPoint("CENTER", list, "CENTER", 0, 38)
    -- The player's own crest (a file every client has).
    list.emptyIcon:SetTexture(Overlord.PlayerFaction == "Horde" and "Interface\\Timer\\Horde-Logo"
        or "Interface\\Timer\\Alliance-Logo")
    list.emptyIcon:SetAlpha(0.55)
    -- While the board is still connecting or listening, the crest breathes slowly
    -- (0.55 -> 0.2 and back, 1.6 s a cycle): the search is running. Animations are
    -- run by the game, and stop with the window.
    if list.emptyIcon.CreateAnimationGroup then
        local pulse = list.emptyIcon:CreateAnimationGroup()
        pulse:SetLooping("BOUNCE")
        local fade = pulse:CreateAnimation("Alpha")
        fade:SetFromAlpha(0.55)
        fade:SetToAlpha(0.2)
        fade:SetDuration(0.8)
        fade:SetSmoothing("IN_OUT")
        list.emptyPulse = pulse
    end
    list.emptyTitle = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    list.emptyTitle:SetPoint("TOP", list.emptyIcon, "BOTTOM", 0, -10)
    list.emptyTitle:SetWidth(K.LIST_W - 60)
    list.emptyTitle:SetText(T("GF_EMPTY_TITLE", "No group is recruiting right now."))
    Color(list.emptyTitle, "cream")
    list.emptyBody = list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    list.emptyBody:SetPoint("TOP", list.emptyTitle, "BOTTOM", 0, -6)
    list.emptyBody:SetWidth(K.LIST_W - 80)
    list.emptyBody:SetText(T("GF_EMPTY_BODY", "Publish yours: every Overlord player of your faction will see it."))
    Color(list.emptyBody, "muted")
end

function GFUI:Scroll(step)
    local total = self.total or 0
    local offset = math.max(0, math.min((self.offset or 0) + step, total - self.rows))
    if offset ~= (self.offset or 0) then
        self.offset = offset
        self:Refresh()
    end
end

local function PaintRow(row, entry, index, gf)
    row.entry = entry
    local own = entry.isOwn
    local status = (not own) and gf:GetApplyStatus(entry.key) or nil
    local can, reason = true, nil
    if not own and not status then can, reason = gf:CanSignUp(entry) end
    local key = entry.key .. "|" .. entry.intent .. entry.kind .. entry.target .. "|" .. entry.cap
        .. "|" .. entry.count .. "|" .. entry.minLevel .. "|" .. entry.class .. "|" .. entry.level
        .. "|" .. (own and "own" or status or reason or "ok") .. "|" .. (index % 2)
    if row.paintKey == key then return end
    row.paintKey = key

    local bg = own and P.rowOwn or ((index % 2 == 0) and P.rowEven or P.rowOdd)
    row.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    row.icon:SetTexture(INTENT_ICON[entry.intent])
    local info = entry.info
    row.title:SetText(IntentText(entry.intent) .. " · " .. (info and info.name or ""))
    Color(row.title, own and "gold" or "cream")
    local token = gf.CLASSES[entry.class]
    if Overlord.UI.SetClassIcon then Overlord.UI.SetClassIcon(row.classIcon, token) end
    local leaderText = entry.name .. "  " .. string.format(T("GF_ROW_LEVEL", "level %d"), entry.level)
    if entry.minLevel > 0 then
        leaderText = leaderText .. "  ·  " .. string.format(T("GF_ROW_MIN_LEVEL", "level %d+"), entry.minLevel)
    end
    row.leader:SetText(leaderText)
    row.leader:SetTextColor(ClassRGB(token))

    local full = entry.count >= entry.cap
    row.count:SetText(entry.count .. "/" .. entry.cap)
    Color(row.count, full and "bad" or "text")
    row.bar:SetWidth(math.max(1, 56 * math.min(1, entry.count / entry.cap)))
    local fill = full and P.bad or P.gold
    row.bar:SetVertexColor(fill[1], fill[2], fill[3], 0.9)

    local state = own and { "GF_STATE_OWN", "Your listing", "gold" } or STATE_KEY[status]
    if state then
        row.button:Hide()
        row.status:SetText(T(state[1], state[2]))
        Color(row.status, state[3])
        row.status:Show()
    else
        row.status:Hide()
        row.button:Show()
        row.button:SetAlpha(can and 1 or 0.45)
    end
end

local function PaintList(f, gf)
    local list = f.list
    local total, players = gf:FillBoard(boardBuf)
    local own = gf.own
    local ownRow
    if own then
        -- The player's own listing heads the board (it is not read back from the channel).
        ownRow = GFUI.ownRow or { isOwn = true, key = "*own" }
        GFUI.ownRow = ownRow
        ownRow.intent, ownRow.kind, ownRow.target, ownRow.info = own.intent, own.kind, own.target, own.info
        ownRow.cap, ownRow.count, ownRow.minLevel, ownRow.auto = own.cap, gf:GroupSize(), own.minLevel, own.auto
        ownRow.class, ownRow.level = gf:PlayerClassIndex(), gf:PlayerLevel()
        ownRow.name = gf:PlayerName() or ""
        players = players + ownRow.count
    end
    local shown = total + (ownRow and 1 or 0)
    GFUI.total = shown
    local visible = GFUI.rows
    local offset = math.max(0, math.min(GFUI.offset or 0, shown - visible))
    GFUI.offset = offset
    for index = 1, K.MAX_ROWS do
        local at = offset + index
        local entry
        if index > visible then
            entry = nil
        elseif ownRow then
            entry = (at == 1) and ownRow or boardBuf[at - 1]
        else
            entry = boardBuf[at]
        end
        local row = list.rows[index]
        if entry then
            PaintRow(row, entry, at, gf)
            row:Show()
        else
            row.entry, row.paintKey = nil, nil
            row:Hide()
        end
    end
    local empty = shown == 0
    -- An empty board is only "nobody recruits" once the channel is open and has been
    -- listened to for a while; before that it says what it is waiting for.
    local channelState = empty and gf:ChannelState() or "open"
    list.channelState = empty and channelState or nil
    if empty and list.emptyKey ~= channelState then
        list.emptyKey = channelState
        local text = EMPTY_KEY[channelState] or EMPTY_KEY.open
        list.emptyTitle:SetText(T(text[1], text[2]))
    end
    list.emptyIcon:SetShown(empty)
    local pulse = list.emptyPulse
    if pulse then
        local searching = empty and (channelState == "listening" or channelState == "connecting")
        if searching and not pulse:IsPlaying() then
            pulse:Play()
        elseif not searching and pulse:IsPlaying() then
            pulse:Stop()
        end
    end
    list.emptyTitle:SetShown(empty)
    list.emptyBody:SetShown(empty and channelState == "open")
    if shown > visible then
        list.page:SetText(string.format("%d-%d / %d", offset + 1, math.min(shown, offset + visible), shown))
    else
        list.page:SetText("")
    end
    if shown > 0 then
        f.subtitle:SetText(string.format(T("GF_SUBTITLE", "Groups: %d · Players: %d"), shown, players))
    elseif channelState == "open" then
        f.subtitle:SetText(T("GF_SUBTITLE_NONE", "No group is recruiting"))
    else
        local text = EMPTY_KEY[channelState]
        f.subtitle:SetText(T(text[1], text[2]))
    end
end

-- ---------------------------------------------------------------------------
-- The card (right): form, or the live listing with its requests
-- ---------------------------------------------------------------------------

local function BuildForm(card)
    local form = CreateFrame("Frame", nil, card)
    form:SetAllPoints()
    card.form = form

    local y = K.FORM_TOP
    BuildLabel(form, T("GF_LABEL_INTENT", "Objective"), y)
    form.intent = BuildSegment(form, {
        { "a", IntentText("a") }, { "d", IntentText("d") }, { "h", IntentText("h") },
    }, K.CARD_IN, function(value)
        GFUI.form.intent = value
        GFUI:Refresh()
    end)
    form.intent.first:SetPoint("TOPLEFT", form, "TOPLEFT", 10, y - 14)

    y = y - K.FORM_PITCH
    BuildLabel(form, T("GF_LABEL_PLACE", "Place"), y)
    form.place = Overlord.UI.CreateWC3Button(form, K.CARD_IN, 24, "", function(self)
        ClickSound()
        GFUI:OpenTargetMenu(self)
    end)
    form.place:SetPoint("TOPLEFT", form, "TOPLEFT", 10, y - 14)
    form.place.arrow = form.place:CreateTexture(nil, "OVERLAY")
    form.place.arrow:SetSize(12, 12)
    form.place.arrow:SetPoint("RIGHT", form.place, "RIGHT", -6, 0)
    form.place.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    form.place.label:SetWidth(K.CARD_IN - 30)
    form.place.label:SetWordWrap(false)

    y = y - K.FORM_PITCH
    BuildLabel(form, T("GF_LABEL_SIZE", "Size"), y)
    local gf = Finder()
    local sizes = {}
    for _, size in ipairs(gf and gf.SIZES or { 5, 10, 20, 40 }) do sizes[#sizes + 1] = { size, tostring(size) } end
    form.size = BuildSegment(form, sizes, K.CARD_IN, function(value)
        GFUI.form.cap = value
        GFUI.formError = nil
        GFUI:Refresh()
    end)
    form.size.first:SetPoint("TOPLEFT", form, "TOPLEFT", 10, y - 14)

    y = y - K.FORM_PITCH
    BuildLabel(form, T("GF_LABEL_LEVEL", "Minimum level"), y)
    local levels = {}
    for _, level in ipairs(gf and gf.MIN_LEVELS or { 0, 20, 40, 60 }) do
        levels[#levels + 1] = { level, level == 0 and T("GF_LEVEL_ANY", "Any") or (level .. "+") }
    end
    form.level = BuildSegment(form, levels, K.CARD_IN, function(value)
        GFUI.form.minLevel = value
        GFUI:Refresh()
    end)
    form.level.first:SetPoint("TOPLEFT", form, "TOPLEFT", 10, y - 14)

    local autoLabel = T("GF_AUTO_LABEL", "Automatic invitation")
    local autoHelp = T("GF_AUTO_HELP",
        "Ticked: everyone who signs up is invited. Otherwise you approve each request.")
    form.auto = BuildCheck(form, autoLabel, function(checked)
        GFUI.form.auto = checked
    end)
    form.auto:SetPoint("TOPLEFT", form, "TOPLEFT", 8, K.FORM_AUTO)
    -- The same words on hover: whole even where the text below is cut short.
    form.auto:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        TipLine(autoLabel, "gold")
        TipLine(autoHelp, "text", true)
        GameTooltip:Show()
    end)
    form.auto:SetScript("OnLeave", GameTooltip_Hide or function() GameTooltip:Hide() end)

    form.publish = Overlord.UI.CreateWC3Button(form, K.CARD_IN, K.PUBLISH_H, T("GF_PUBLISH", "Publish"), function()
        local finder = Finder()
        if not finder then return end
        ClickSound()
        local ok, err = finder:Publish(GFUI.form)
        -- Only what the live check below cannot say again by itself is kept.
        GFUI.formError = (not ok and (err == "GF_ERR_FORM" or err == "GF_ERR_GROUP_FULL")) and err or nil
        GFUI:Refresh()
    end)
    form.publish:SetPoint("BOTTOM", form, "BOTTOM", 0, K.PUBLISH_Y)
    -- Held between the option and the button: a text too long for the room is cut
    -- with an ellipsis, it never runs over the button.
    form.autoHelp = form:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    form.autoHelp:SetPoint("TOPLEFT", form, "TOPLEFT", 12, K.FORM_HELP)
    form.autoHelp:SetPoint("BOTTOMRIGHT", form.publish, "TOPRIGHT", -2, K.FORM_HELP_GAP)
    form.autoHelp:SetJustifyH("LEFT")
    form.autoHelp:SetJustifyV("TOP")
    form.autoHelp:SetText(autoHelp)
    form.reason = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    form.reason:SetPoint("BOTTOM", form, "BOTTOM", 0, K.REASON_Y)
    form.reason:SetWidth(K.CARD_IN)
    Color(form.reason, "bad")
end

local function RequestOnClick(btn)
    local gf = Finder()
    local app = btn.app
    if not gf or not app then return end
    ClickSound()
    if btn.accept then
        local ok, reason = gf:Accept(app.key)
        if not ok and reason and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. Reason(reason))
        end
    else
        gf:Decline(app.key)
    end
    GFUI:Refresh()
end

local function RequestOnEnter(btn)
    if not GameTooltip then return end
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    TipLine(btn.accept and T("GF_ACCEPT", "Invite") or T("GF_DECLINE", "Decline"), "gold")
    GameTooltip:Show()
end

local function BuildRequestButton(row, texture, accept)
    local btn = CreateFrame("Button", nil, row)
    btn:SetSize(20, 20)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(texture)
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    btn.accept = accept
    btn:SetScript("OnClick", RequestOnClick)
    btn:SetScript("OnEnter", RequestOnEnter)
    btn:SetScript("OnLeave", GameTooltip_Hide or function() GameTooltip:Hide() end)
    return btn
end

local function BuildLive(card)
    local live = CreateFrame("Frame", nil, card)
    live:SetAllPoints()
    card.live = live

    live.icon = live:CreateTexture(nil, "ARTWORK")
    live.icon:SetSize(30, 30)
    live.icon:SetPoint("TOPLEFT", live, "TOPLEFT", 10, -34)
    live.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    live.title = live:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    live.title:SetPoint("TOPLEFT", live.icon, "TOPRIGHT", 8, -1)
    live.title:SetWidth(K.CARD_IN - 40)
    live.title:SetJustifyH("LEFT")
    live.title:SetWordWrap(false)
    Color(live.title, "gold")
    live.facts = live:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    live.facts:SetPoint("BOTTOMLEFT", live.icon, "BOTTOMRIGHT", 8, 1)
    live.facts:SetWidth(K.CARD_IN - 40)
    live.facts:SetJustifyH("LEFT")
    live.facts:SetWordWrap(false)
    live.state = live:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    live.state:SetPoint("TOPLEFT", live, "TOPLEFT", 10, -72)
    live.state:SetWidth(K.CARD_IN)
    live.state:SetJustifyH("LEFT")

    live.requestsLabel = BuildLabel(live, T("GF_REQUESTS", "Requests"), -94)
    live.rows = {}
    for index = 1, K.REQ_ROWS do
        local row = CreateFrame("Frame", nil, live)
        row:SetSize(K.CARD_IN, K.REQ_H)
        row:SetPoint("TOPLEFT", live, "TOPLEFT", 10, -110 - (index - 1) * K.REQ_H)
        row.classIcon = row:CreateTexture(nil, "ARTWORK")
        row.classIcon:SetSize(16, 16)
        row.classIcon:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.classIcon, "RIGHT", 4, 0)
        row.name:SetWidth(K.CARD_IN - 70)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.decline = BuildRequestButton(row, "Interface\\RaidFrame\\ReadyCheck-NotReady", false)
        row.decline:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.accept = BuildRequestButton(row, "Interface\\RaidFrame\\ReadyCheck-Ready", true)
        row.accept:SetPoint("RIGHT", row.decline, "LEFT", -4, 0)
        row:Hide()
        live.rows[index] = row
    end
    live.note = live:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    live.note:SetPoint("TOPLEFT", live, "TOPLEFT", 10, -112 - K.REQ_ROWS * K.REQ_H)
    live.note:SetWidth(K.CARD_IN)
    live.note:SetJustifyH("LEFT")

    live.unlist = Overlord.UI.CreateWC3Button(live, K.CARD_IN, 26, T("GF_UNLIST", "Withdraw the listing"), function()
        local gf = Finder()
        if not gf then return end
        ClickSound()
        gf:Unpublish("user")
        GFUI:Refresh()
    end)
    live.unlist:SetPoint("BOTTOM", live, "BOTTOM", 0, 12)
    live.convert = Overlord.UI.CreateWC3Button(live, K.CARD_IN, 24, T("GF_CONVERT", "Convert to raid"), function()
        local gf = Finder()
        if not gf then return end
        ClickSound()
        gf:ConvertToRaid()
    end)
    live.convert:SetPoint("BOTTOM", live.unlist, "TOP", 0, 6)
end

local function BuildCard(f)
    local card = Overlord.UI.CreateWC3SubPanel(f, K.CARD_W, K.H - K.BODY_TOP - K.FOOT)
    card:SetPoint("TOPRIGHT", f, "TOPRIGHT", -K.PAD, -K.BODY_TOP)
    f.card = card
    card.head = BuildHead(card, K.CARD_W, "")
    BuildForm(card)
    BuildLive(card)
end

local function PlaceText(gf, kind, target)
    local info = gf:DescribeTarget(kind, target)
    if kind == "z" and info.frontName ~= "" then return info.name .. " (" .. info.frontName .. ")" end
    return info.name
end

local function PaintForm(card, gf)
    local form, data = card.form, GFUI.form
    card.head:SetText(T("GF_CARD_CREATE", "Create my group"))
    form.intent:Set(data.intent)
    form.size:Set(data.cap)
    form.level:Set(data.minLevel)
    local place = PlaceText(gf, data.kind, data.target)
    if form.placeText ~= place then
        form.placeText = place
        form.place.label:SetText(place)
    end
    if form.auto.checked ~= data.auto then form.auto:SetChecked(data.auto) end
    local ok, err = gf:CheckPublish()
    if GFUI.formError == "GF_ERR_GROUP_FULL" and gf:GroupSize() < data.cap then GFUI.formError = nil end
    local reason = GFUI.formError or ((not ok) and err) or nil
    form.publish:SetAlpha(ok and 1 or 0.45)
    form.reason:SetText(reason and Reason(reason) or "")
end

local function PaintLive(card, gf, own)
    local live = card.live
    card.head:SetText(T("GF_CARD_MINE", "My group"))
    live.icon:SetTexture(INTENT_ICON[own.intent])
    live.title:SetText(IntentText(own.intent) .. " · " .. (own.info and own.info.name or ""))
    local facts = gf:GroupSize() .. "/" .. own.cap
    if own.minLevel > 0 then
        facts = facts .. "  ·  " .. string.format(T("GF_ROW_MIN_LEVEL", "level %d+"), own.minLevel)
    end
    live.facts:SetText(facts)
    -- The invitation mode sits on the state line, which wraps (the summary does not).
    local state = LIVE_KEY[own.state] or LIVE_KEY.sending
    if own.state == "channel" and gf:ChannelState() == "closed" then state = LIVE_KEY.closed end
    live.state:SetText(T(state[1], state[2]) .. "  ·  " .. (own.auto
        and T("GF_MODE_AUTO", "automatic invitation") or T("GF_MODE_MANUAL", "leader approves")))
    Color(live.state, state[3])

    local pending = gf.pending
    for index = 1, K.REQ_ROWS do
        local row, app = live.rows[index], pending[index]
        if app then
            local token = gf.CLASSES[app.class]
            if Overlord.UI.SetClassIcon then Overlord.UI.SetClassIcon(row.classIcon, token) end
            row.name:SetText(app.name .. "  " .. app.level)
            row.name:SetTextColor(ClassRGB(token))
            row.accept.app, row.decline.app = app, app
            row:Show()
        else
            row.accept.app, row.decline.app = nil, nil
            row:Hide()
        end
    end
    local needRaid = #pending > 0 and not gf:CanInviteNow()
    if needRaid then
        live.note:SetText(T("GF_NEED_RAID", "Group of five: convert to raid to keep inviting."))
        Color(live.note, "bad")
    elseif #pending > K.REQ_ROWS then
        live.note:SetText(string.format(T("GF_REQUESTS_MORE", "+%d more"), #pending - K.REQ_ROWS))
        Color(live.note, "muted")
    elseif #pending == 0 then
        live.note:SetText(T("GF_REQUESTS_NONE", "No request yet."))
        Color(live.note, "muted")
    else
        live.note:SetText("")
    end
    live.note:ClearAllPoints()
    live.note:SetPoint("TOPLEFT", live, "TOPLEFT", 10,
        -112 - math.min(#pending, K.REQ_ROWS) * K.REQ_H)
    live.convert:SetShown(own.cap > 5 and gf:IsGrouped() and not gf:IsRaid() and gf:IsLeader())
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function HideWindow()
    GFUI:Hide()
end

-- Hidden prebuild: the window was built inside the click that first opened it (about
-- 7 ms in one frame). It is now built ahead, hidden, one block per frame, 35 s after a
-- loading screen, never in combat or in an instance (the ranking does the same at 30 s).
-- A click during the build finishes it at once, as a first open always did.
local GfBuild = { DELAY = 35 }

-- Yield point between the blocks of CreateFrame; a no-op outside the hidden build.
function GfBuild.Step()
    if GfBuild.sync or not GfBuild.co or coroutine.running() ~= GfBuild.co then return end
    coroutine.yield()
end

function GFUI:CreateFrame()
    if frame or not CreateFrame or not Overlord.UI then return frame end
    local f = CreateFrame("Frame", "OverlordGroupFinderFrame", UIParent, "BackdropTemplate")
    f:SetSize(K.W, K.H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    if Overlord.UI.ApplyWoodDialogBackdrop then Overlord.UI.ApplyWoodDialogBackdrop(f) end
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(50)
    -- Several Overlord windows share this layer: the one shown or clicked last goes in
    -- front, whole (without this their contents interleave where they overlap).
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        GFUI._userMoved = true
        self._dockKey = nil
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    f:Hide()

    BuildCrown(f)
    GfBuild.Step()
    BuildBand(f)
    GfBuild.Step()
    BuildList(f)
    GfBuild.Step()
    BuildCard(f)
    GfBuild.Step()
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOM", f, "BOTTOM", 0, 17)
    footer:SetWidth(K.W - 2 * K.PAD)
    footer:SetText(T("GF_FOOTER", "Seen by the Overlord players of your faction. Off in instances."))

    f:SetScript("OnShow", function(self)
        self:Raise()
        if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
        self:SetScale(Overlord.UI.GetEffectiveUiScale and Overlord.UI:GetEffectiveUiScale() or 1)
        if Overlord.UI.ScheduleActionGridActiveRefresh then Overlord.UI:ScheduleActionGridActiveRefresh() end
    end)
    f:SetScript("OnHide", function()
        GFUI._refreshPending = false
        GFUI._refreshToken = (GFUI._refreshToken or 0) + 1
        if GameTooltip then GameTooltip:Hide() end
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        if Overlord.UI.ScheduleActionGridActiveRefresh then Overlord.UI:ScheduleActionGridActiveRefresh() end
    end)
    -- Hooks last: they wrap the scripts set above.
    if Overlord.UI.AttachOpenFade then Overlord.UI.AttachOpenFade(f) end
    local cross = Overlord.UI.CreateWC3CloseButton(f, HideWindow)
    cross:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    if Overlord.UI.BindEscapeClose then Overlord.UI.BindEscapeClose(f, HideWindow) end
    frame = f
    return f
end

-- The form starts on the player's last choices, else on the front the player stands on.
function GFUI:EnsureForm(gf)
    if self.form then return end
    local form = gf:GetForm()
    local db = gf:DB()
    if not (db and db.form) then
        local fronts = Overlord.Fronts
        if fronts and fronts.ResolveFrontByMapID and C_Map and C_Map.GetBestMapForUnit then
            local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
            local front = ok and mapID and fronts:ResolveFrontByMapID(mapID) or nil
            if front and gf:IsValidTarget("f", front.id) then form.kind, form.target = "f", front.id end
        end
    end
    self.form = form
end

function GFUI:Refresh()
    local gf = Finder()
    if not frame or not frame:IsShown() or not gf then return end
    self._refreshedAt = GetTime()
    self:EnsureForm(gf)
    PaintList(frame, gf)
    local own = gf.own
    local card = frame.card
    card.form:SetShown(not own)
    card.live:SetShown(own and true or false)
    if own then
        PaintLive(card, gf, own)
    else
        PaintForm(card, gf)
    end
    -- One repaint when the sign-up cooldown ends (the buttons come back).
    local left = gf:SignupCooldownRemaining()
    if left > 0 and not self._cooldownTimer then
        self._cooldownTimer = true
        C_Timer.After(left + 0.5, function()
            GFUI._cooldownTimer = nil
            GFUI:RequestRefresh()
        end)
    end
    -- An empty board waiting on the channel looks again by itself: every 5 s until the
    -- channel answers, then once when the listening time is over.
    local waiting = frame.list.channelState
    if waiting and waiting ~= "open" and not self._channelTimer then
        local delay = 5
        if waiting == "listening" then
            local _, remaining = gf:ChannelState()
            delay = (remaining or 0) + 0.5
        end
        self._channelTimer = true
        C_Timer.After(delay, function()
            GFUI._channelTimer = nil
            GFUI:RequestRefresh()
        end)
    end
end

-- Coalesced: any number of changes within a quarter of a second cost one pass, and
-- nothing at all while the window is hidden.
function GFUI:RequestRefresh()
    if not frame or not frame:IsShown() or self._refreshPending then return end
    self._refreshPending = true
    local token = (self._refreshToken or 0) + 1
    self._refreshToken = token
    local delay = math.max(0.05, (self._refreshedAt or 0) + K.REFRESH_MIN - GetTime())
    C_Timer.After(delay, function()
        if GFUI._refreshToken ~= token then return end
        GFUI._refreshPending = false
        GFUI:Refresh()
    end)
end

-- Requests waiting for the leader, on the panel's grid button.
function GFUI:UpdateGridBadge(count)
    local btn = Overlord.UI and Overlord.UI.groupFinderBtn
    if not btn or not btn.label then return end
    local label = T("GF_BUTTON", "PvP Groups")
    if count and count > 0 then label = label .. " (" .. count .. ")" end
    btn.label:SetText(label)
end

-- The window takes the height it is given (within its limits): the two panels
-- stretch and the list shows as many rows as fit.
function GFUI:ApplyHeight(height)
    if not frame then return end
    height = math.max(K.H_MIN, math.min(K.H_MAX, math.floor((tonumber(height) or K.H) + 0.5)))
    if frame._height == height then return end
    frame._height = height
    frame:SetHeight(height)
    local panelH = height - K.BODY_TOP - K.FOOT
    frame.list:SetHeight(panelH)
    frame.card:SetHeight(panelH)
    self.rows = math.max(1, math.min(K.MAX_ROWS, math.floor((panelH - K.HEAD_H - 4) / K.ROW_H)))
end

-- Docked like the side panel: against the left edge of the Overlord panels (the
-- side panel when it is open, else the main panel), tops level, same height. On the
-- right of the main panel when there is no room on the left. Anchored, so it follows
-- the main panel; a drag by the player keeps it where he drops it for the session.
function GFUI:DockToPanel()
    if not frame or self._userMoved then return end
    local main = Overlord.UI and Overlord.UI.GetMainFrame and Overlord.UI:GetMainFrame()
    if not main or not main:IsShown() then return end
    local side = OverlordFeaturedFrontDialog
    local anchor = (side and side:IsShown()) and side or main
    self:ApplyHeight(main:GetHeight())
    local left = anchor:GetLeft()
    local key = (left and left < K.W + K.DOCK_GAP) and "right" or anchor
    if frame._dockKey == key then return end
    frame._dockKey = key
    frame:ClearAllPoints()
    if key == "right" then
        frame:SetPoint("TOPLEFT", main, "TOPRIGHT", K.DOCK_GAP, 0)
    else
        frame:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -K.DOCK_GAP, 0)
    end
end

-- The main panel changed height or its side panel opened or closed (UI.lua, Popups.lua).
function GFUI:OnPanelLayoutChanged()
    if not frame or not frame:IsShown() then return end
    local rows = self.rows
    self:DockToPanel()
    if self.rows ~= rows then self:Refresh() end
end

-- The panel's scale changed (UI.lua): same scale here, at once.
function GFUI:ApplyFrameScale(scale)
    if frame and math.abs((frame:GetScale() or 0) - scale) > 0.001 then frame:SetScale(scale) end
end

function GFUI:IsShown()
    return frame ~= nil and frame:IsShown() and true or false
end

function GFUI:Show()
    local gf = Finder()
    if not gf then return end
    if gf.InInstance() then
        if Overlord.PrintNotification then
            Overlord:PrintNotification("|cFF00FF00[Overlord]|r "
                .. T("DISABLED_IN_INSTANCE", "Overlord is disabled in instances."))
        end
        return
    end
    GfBuild.Finish()
    if not frame then self:CreateFrame() end
    if not frame then return end
    frame:SetScale(Overlord.UI.GetEffectiveUiScale and Overlord.UI:GetEffectiveUiScale() or 1)
    self:DockToPanel()
    frame:Show()
    self:Refresh()
end

function GFUI:Hide()
    if frame and frame:IsShown() then frame:Hide() end
end

function GFUI:Toggle()
    if self:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function GfBuild.Blocked()
    local gf = Finder()
    if not gf or Overlord.InstanceSuspended or (gf.InInstance and gf.InInstance()) then return true end
    if InCombatLockdown and InCombatLockdown() then
        local driver = GfBuild.driver
        if driver and driver.RegisterEvent then driver:RegisterEvent("PLAYER_REGEN_ENABLED") end
        return true
    end
    return false
end

function GfBuild.Resume()
    local co = GfBuild.co
    if not co then return end
    local ok, err = coroutine.resume(co)
    if ok and coroutine.status(co) ~= "dead" then return end
    GfBuild.co = nil
    GfBuild.done = true
    local driver = GfBuild.driver
    if driver and driver.UnregisterAllEvents then driver:UnregisterAllEvents() end
    -- A build cut short leaves frame nil: the next Show builds the window the usual way.
    if not ok then
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) end
    end
end

-- One block per frame while nothing blocks; combat or the next loading screen resumes it.
function GfBuild.Slice()
    GfBuild.sliceArmed = nil
    if not GfBuild.co or GfBuild.Blocked() then return end
    GfBuild.Resume()
    if GfBuild.co then
        GfBuild.sliceArmed = true
        C_Timer.After(0, GfBuild.Slice)
    end
end

function GfBuild.Start()
    GfBuild.armed = nil
    if GfBuild.done or GfBuild.sliceArmed then return end
    if frame and not GfBuild.co then
        GfBuild.done = true
        local driver = GfBuild.driver
        if driver and driver.UnregisterAllEvents then driver:UnregisterAllEvents() end
        return
    end
    if GfBuild.Blocked() then return end
    if not GfBuild.co then
        GfBuild.co = coroutine.create(function() GFUI:CreateFrame() end)
    end
    GfBuild.Slice()
end

-- Show: a build still running ends now, in the click.
function GfBuild.Finish()
    if not GfBuild.co then return end
    GfBuild.sync = true
    while GfBuild.co do GfBuild.Resume() end
    GfBuild.sync = nil
end

if CreateFrame and C_Timer and C_Timer.After then
    local driver = CreateFrame("Frame")
    GfBuild.driver = driver
    driver:RegisterEvent("PLAYER_ENTERING_WORLD")
    driver:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_ENABLED" and self.UnregisterEvent then self:UnregisterEvent(event) end
        if GfBuild.done or GfBuild.armed or GfBuild.sliceArmed then return end
        GfBuild.armed = true
        C_Timer.After(event == "PLAYER_ENTERING_WORLD" and GfBuild.DELAY or 2, GfBuild.Start)
    end)
end
