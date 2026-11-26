-- Corner widget: a small Overlord button anywhere on the screen. Hovering it shows the
-- guild table (sorted as in the ranking's Guilds tab) and the Recent activity, without
-- opening anything; a click opens the Overlord panel like the minimap button. Left-drag
-- moves it. Optional (Options > On-screen panels), off by default, gone in instances.
-- Painted only while hovered (a repaint every 2 s then): no event, no timer otherwise,
-- nothing sent.
Overlord = Overlord or {}
local CW = Overlord.CornerWidget or {}
Overlord.CornerWidget = CW

CW.GUILD_ROWS = 5
CW.REPAINT_SEC = 2
local ICON = "Interface\\AddOns\\Overlord\\Textures\\overlord_minimap"
-- Colours of the minimap button's tooltip (header, factions) and the activity panel (names).
local GOLD = { 1, 0.82, 0.2 }
local HEAD = { 1, 0.82, 0 }
local FACTION = { Alliance = { 0.30, 0.62, 1 }, Horde = { 1, 0.30, 0.30 } }
local MUTED = { 0.6, 0.6, 0.6 }
local NAME = { 0.92, 0.92, 0.92 }

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

function CW:IsEnabled()
    local config = OverlordDB and OverlordDB.config
    return config ~= nil and config.showCornerWidget == true
end

local function Number(value)
    value = math.floor(tonumber(value) or 0)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(value) or tostring(value)
end

-- The rows the Guilds tab shows, in its order: by kills unless the player sorted it by
-- rating (GuildRating.List), from the ranking's display cache (its saved preview at login).
-- Only the hover itself asks for the cache (which may start its sliced build); the repaints
-- read the cache as it stands, so a hover never re-arms a build every 2 s.
-- Third value: false while the cache is still being built (nothing to say about guilds yet).
function CW:GuildRows(fresh)
    local lb = Overlord.Leaderboard
    local cache
    -- (Not before the login stages are done: the ranking's tables are not the real ones yet,
    -- a build started then would be thrown away. The saved preview answers meanwhile.)
    if fresh and Overlord._deferredModuleInitDone then
        cache = lb and lb.EnsureDisplayCache and lb:EnsureDisplayCache() or nil
        self._hoverCache = cache
    else
        cache = lb and lb._displayCache or self._hoverCache
    end
    if type(cache) ~= "table" then return {}, false, false end
    local rating, guilds = cache.sortedGuildRating or {}, cache.sortedGuilds or {}
    local config = OverlordDB and OverlordDB.config
    local byKills = not (config and config.leaderboardGuildSort == "rating")
    local ready = cache.ready ~= false
    if byKills or (#rating == 0 and #guilds > 0) then return guilds, false, ready end
    return rating, true, ready
end

local function OwnGuildKey()
    if not (IsInGuild and IsInGuild()) or not GetGuildInfo then return nil end
    local name = GetGuildInfo("player")
    return type(name) == "string" and name ~= "" and name:lower() or nil
end

local function AddGuildRow(tip, place, row, isRating, ownKey)
    local name = tostring(row.guild or "")
    local c = FACTION[row.faction] or NAME
    if ownKey and name:lower() == ownKey then c = HEAD end
    local value = isRating and row.points or row.kills
    tip:AddDoubleLine(place .. ". " .. name, Number(value), c[1], c[2], c[3], 1, 1, 1)
end

-- Where our guild stands further down, remembered for the same list: one walk per new
-- list (a rebuilt cache hands a new table), not one per repaint.
function CW:OwnGuildIndex(rows, ownKey)
    local memo = self._ownMemo
    if memo and memo.rows == rows and memo.key == ownKey
        and (not memo.index or tostring((rows[memo.index] or {}).guild or ""):lower() == ownKey) then
        return memo.index
    end
    local index = nil
    for i = self.GUILD_ROWS + 1, #rows do
        if tostring(rows[i].guild or ""):lower() == ownKey then
            index = i
            break
        end
    end
    self._ownMemo = { rows = rows, key = ownKey, index = index }
    return index
end

function CW:FillGuilds(tip, fresh)
    local rows, isRating, ready = self:GuildRows(fresh)
    tip:AddDoubleLine(T("LB_TABLE_GUILDS", "Guilds"),
        isRating and T("LB_COL_RATING", "Rating") or T("LB_COL_KILLS", "Kills"),
        HEAD[1], HEAD[2], HEAD[3], MUTED[1], MUTED[2], MUTED[3])
    if #rows == 0 then
        -- Still being built: not "no guild" (the next repaint shows them).
        tip:AddLine(ready and T("CORNER_WIDGET_NO_GUILDS", "No guild ranked yet this week.") or "...",
            MUTED[1], MUTED[2], MUTED[3])
        return
    end
    local ownKey = OwnGuildKey()
    local ownShown = false
    for i = 1, math.min(self.GUILD_ROWS, #rows) do
        local row = rows[i]
        AddGuildRow(tip, i, row, isRating, ownKey)
        if ownKey and tostring(row.guild or ""):lower() == ownKey then ownShown = true end
    end
    -- Our guild further down: its own line under the top ones.
    if ownKey and not ownShown then
        local index = self:OwnGuildIndex(rows, ownKey)
        if index then AddGuildRow(tip, index, rows[index], isRating, ownKey) end
    end
end

function CW:FillActivity(tip)
    tip:AddLine(T("FEATURED_FRONT_ACTIVITY_TITLE", "Recent activity (Last 5 min)"), HEAD[1], HEAD[2], HEAD[3])
    local fa, popups = Overlord.FrontActivity, Overlord.Popups
    local rows = fa and fa.GetActivityRows and fa:GetActivityRows() or {}
    local shown = 0
    for _, row in ipairs(rows) do
        if row.active then
            local text = popups and popups.FormatFrontActivityText
                and popups.FormatFrontActivityText(true, row.ageSeconds, row.kills, row.captures) or ""
            local r, g, b = 1, 0.82, 0.35
            if popups and popups.FrontActivityValueColor then
                r, g, b = popups.FrontActivityValueColor(true, row.ageSeconds, row.kills, row.captures)
            end
            tip:AddDoubleLine(tostring(row.label or ""), text, NAME[1], NAME[2], NAME[3], r, g, b)
            shown = shown + 1
        end
    end
    if shown == 0 then
        tip:AddLine(T("CORNER_WIDGET_QUIET", "No fighting in the last 5 minutes."), MUTED[1], MUTED[2], MUTED[3])
    end
end

function CW:FillTooltip(tip, fresh)
    tip:AddLine("Overlord", GOLD[1], GOLD[2], GOLD[3])
    if Overlord.InstanceSuspended then
        tip:AddLine(T("DISABLED_IN_INSTANCE", "Disabled in instances"), MUTED[1], MUTED[2], MUTED[3])
        return
    end
    tip:AddLine(" ")
    self:FillGuilds(tip, fresh)
    tip:AddLine(" ")
    self:FillActivity(tip)
    tip:AddLine(" ")
    tip:AddLine(T("CORNER_WIDGET_HINT", "Click: open Overlord. Drag: move."), MUTED[1], MUTED[2], MUTED[3])
end

local function Paint(button, fresh)
    if not GameTooltip then return end
    -- Right half of the screen: the tooltip opens towards the middle.
    local x = button:GetCenter()
    local width = UIParent and UIParent:GetWidth() or 0
    GameTooltip:SetOwner(button, (x and width > 0 and x > width / 2) and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    CW:FillTooltip(GameTooltip, fresh)
    GameTooltip:Show()
end

local function StopRepaint()
    if CW.repaint then
        CW.repaint:Cancel()
        CW.repaint = nil
    end
    CW._hoverCache, CW._ownMemo = nil, nil
end

local function SavePosition(button)
    if not OverlordDB then return end
    local point, _, relPoint, x, y = button:GetPoint(1)
    if not point then return end
    OverlordDB.cornerWidgetPos = { point = point, relPoint = relPoint or point, x = x or 0, y = y or 0 }
end

-- Default place: right edge of the screen, under the minimap.
function CW:ApplyPosition()
    local button = self.button
    if not button then return end
    local pos = type(OverlordDB and OverlordDB.cornerWidgetPos) == "table" and OverlordDB.cornerWidgetPos or nil
    button:ClearAllPoints()
    if pos and type(pos.point) == "string" then
        button:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, tonumber(pos.x) or 0, tonumber(pos.y) or 0)
    else
        button:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -240)
    end
end

function CW:Create()
    if self.button or not CreateFrame then return self.button end
    local button = CreateFrame("Button", "OverlordCornerWidget", UIParent)
    self.button = button
    button:SetSize(33, 33)
    button:SetFrameStrata("MEDIUM")
    button:SetClampedToScreen(true)
    button:SetMovable(true)
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp")
    -- The minimap button's look, so the player knows it at once.
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture(ICON)
    button:SetScript("OnDragStart", function(b)
        b._dragging = true
        StopRepaint()
        if GameTooltip then GameTooltip:Hide() end
        b:StartMoving()
    end)
    button:SetScript("OnDragStop", function(b)
        b:StopMovingOrSizing()
        SavePosition(b)
        b._dragging = nil
    end)
    button:SetScript("OnClick", function()
        if Overlord.InstanceSuspended then return end
        if Overlord.UI and Overlord.UI.Toggle then Overlord.UI:Toggle() end
    end)
    button:SetScript("OnEnter", function(b)
        if b._dragging then return end
        StopRepaint()
        Paint(b, true)
        if C_Timer and C_Timer.NewTicker then
            CW.repaint = C_Timer.NewTicker(CW.REPAINT_SEC, function()
                if b:IsShown() and GameTooltip and GameTooltip:IsOwned(b) then Paint(b) else StopRepaint() end
            end)
        end
    end)
    button:SetScript("OnLeave", function()
        StopRepaint()
        if GameTooltip then GameTooltip:Hide() end
    end)
    -- Hidden mid-drag (an instance, the option turned off): the move ends where it is.
    button:SetScript("OnHide", function(b)
        StopRepaint()
        if b._dragging then
            b:StopMovingOrSizing()
            SavePosition(b)
            b._dragging = nil
        end
    end)
    self:ApplyPosition()
    button:Hide()
    return button
end

-- Shown when the option is on and we are not in an instance; created on first use only.
function CW:Refresh()
    local want = self:IsEnabled() and not Overlord.InstanceSuspended
    if not want then
        if self.button then self.button:Hide() end
        return false
    end
    local button = self:Create()
    if button then button:Show() end
    return button ~= nil
end

function CW:OnInstanceSuspend()
    StopRepaint()
    if self.button then
        if GameTooltip and GameTooltip:IsOwned(self.button) then GameTooltip:Hide() end
        self.button:Hide()
    end
end

function CW:OnInstanceResume()
    self:Refresh()
end

if CreateFrame then
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("PLAYER_LOGIN")
    loader:SetScript("OnEvent", function(f)
        f:UnregisterAllEvents()
        pcall(CW.Refresh, CW)
    end)
end

-- (/ov perf mem: this file's own tables.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["CornerWidget.lua"] = function() return { CW = CW } end
