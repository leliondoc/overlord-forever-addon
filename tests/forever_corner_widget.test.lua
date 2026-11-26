-- Corner widget (CornerWidget.lua): off by default; once on, a small button on UIParent whose
-- tooltip shows the guild table (sorted as the Guilds tab) and the Recent activity, painted
-- only while hovered; gone in instances; nothing sent.
Overlord = { L = {}, MemoryParts = {} }
OverlordDB = { config = {} }

-- Minimal frames: what the widget calls, recorded.
local created, tickers = {}, {}
local function newFrame(kind, name, parent)
    local f = { kind = kind, name = name, parent = parent, shown = true, scripts = {}, points = {} }
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:Show() self.shown = true end
    function f:Hide()
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:IsShown() return self.shown end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(p, rel, rp, x, y) self.points[#self.points + 1] = { p, rel, rp, x, y } end
    function f:GetPoint() local p = self.points[1]; if p then return p[1], p[2], p[3], p[4], p[5] end end
    function f:GetCenter() return rawget(self, "cx") or 100, 100 end
    function f:CreateTexture() return setmetatable({}, { __index = function() return function() end end }) end
    function f:StartMoving() self.moving = true end
    function f:StopMovingOrSizing() self.moving = false; self.points = { { "TOPLEFT", UIParent, "BOTTOMLEFT", 300, 500 } } end
    function f:UnregisterAllEvents() end
    function f:RegisterEvent(e) self.event = e end
    -- (Any other method does nothing; fields stay nil.)
    setmetatable(f, { __index = function(_, k) if type(k) == "string" and k:sub(1, 1) ~= "_" then return function() end end end })
    created[#created + 1] = f
    return f
end
UIParent = { GetWidth = function() return 1000 end }
function CreateFrame(kind, name, parent) return newFrame(kind, name, parent) end
C_Timer = { NewTicker = function(sec, fn)
    local t = { sec = sec, fn = fn, cancelled = false }
    function t:Cancel() self.cancelled = true end
    tickers[#tickers + 1] = t
    return t
end }
function BreakUpLargeNumbers(n) return tostring(n) end
local guildName = "Fight The Power"
function IsInGuild() return guildName ~= nil end
function GetGuildInfo() return guildName end

local lines, owner, anchor = {}, nil, nil
GameTooltip = {
    SetOwner = function(_, o, a) owner, anchor = o, a end,
    ClearLines = function() lines = {} end,
    AddLine = function(_, text) lines[#lines + 1] = text end,
    AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. " | " .. r end,
    Show = function() end,
    Hide = function() owner = nil end,
    IsOwned = function(_, f) return owner == f end,
}

-- The ranking's display cache and the activity rows, as their modules hand them over.
local builds, cacheReady = 0, true
local guilds, rating = {}, {}
for i = 1, 9 do
    guilds[i] = { guild = "Guild " .. i, kills = 1000 - i, faction = i % 2 == 0 and "Horde" or "Alliance" }
    rating[i] = { guild = "Guild " .. (10 - i), points = 5000 - i, faction = "Alliance" }
end
guilds[8].guild = "Fight The Power"
Overlord.Leaderboard = { EnsureDisplayCache = function()
    builds = builds + 1
    return { sortedGuilds = guilds, sortedGuildRating = rating, ready = cacheReady }
end }
local activity = {
    { frontId = "arathi", label = "Arathi Highlands", active = true, ageSeconds = 30, kills = 25, captures = 0 },
    { frontId = "ashenvale", label = "Ashenvale", active = false },
}
Overlord.FrontActivity = { GetActivityRows = function() return activity end }
Overlord.Popups = {
    FormatFrontActivityText = function(_, _, kills) return kills .. "+ HK" end,
    FrontActivityValueColor = function() return 1, 0.5, 0.15 end,
}
-- Nothing may be sent.
Overlord.Sync = setmetatable({}, { __index = function(_, k) error("the widget used Sync." .. tostring(k)) end })
local toggles = 0
Overlord.UI = { Toggle = function() toggles = toggles + 1 end }

assert(loadfile("CornerWidget.lua"))()
local CW = Overlord.CornerWidget
local loader = created[#created]
assert(loader.event == "PLAYER_LOGIN", "the widget does not wait for the login")

-- 1. Off by default: nothing created at login.
loader.scripts.OnEvent(loader)
assert(CW.button == nil and builds == 0, "the widget appeared without its option")

-- 2. On: one button on UIParent, shown; an instance hides it, leaving shows it again.
OverlordDB.config.showCornerWidget = true
assert(CW:Refresh() == true and CW.button and CW.button.shown and CW.button.parent == UIParent,
    "the widget did not show once enabled")
assert(builds == 0, "the widget read the ranking without being hovered")
Overlord.InstanceSuspended = true
CW:OnInstanceSuspend()
assert(not CW.button.shown, "the widget stayed in an instance")
assert(CW:Refresh() == false and not CW.button.shown, "a refresh showed it in an instance")
Overlord.InstanceSuspended = false
CW:OnInstanceResume()
assert(CW.button.shown, "the widget did not come back after the instance")

-- 3. Hover: top 5 by kills, our guild further down on its own line, active fronts only.
local b = CW.button
-- (Before the login stages are done, a hover starts no ranking build: the tables are not real yet.)
Overlord._deferredModuleInitDone = nil
b.scripts.OnEnter(b)
assert(builds == 0, "a hover during the login stages started a ranking build")
if b.scripts.OnLeave then b.scripts.OnLeave(b) end
for i = #lines, 1, -1 do lines[i] = nil end
for i = #tickers, 1, -1 do tickers[i] = nil end
Overlord._deferredModuleInitDone = true
b.scripts.OnEnter(b)
local text = table.concat(lines, "\n")
assert(text:find("1. Guild 1 | 999", 1, true) and text:find("5. Guild 5 | 995", 1, true), "top guilds missing:\n" .. text)
assert(not text:find("6. Guild 6", 1, true), "more than five guilds shown")
assert(text:find("8. Fight The Power | 992", 1, true), "our guild further down is not shown")
assert(text:find("Arathi Highlands | 25+ HK", 1, true) and not text:find("Ashenvale", 1, true),
    "activity rows wrong:\n" .. text)
assert(anchor == "ANCHOR_RIGHT", "tooltip opens off the screen side")
assert(#tickers == 1 and tickers[1].sec == 2, "no repaint while hovered")
-- The repaints read the cache as it stands: only the hover asked for it.
local buildsHover = builds
tickers[1].fn()
text = table.concat(lines, "\n")
assert(builds == buildsHover, "a repaint asked the ranking for its cache again")
assert(text:find("1. Guild 1 | 999", 1, true) and text:find("8. Fight The Power | 992", 1, true),
    "the repaint lost the guilds:\n" .. text)
-- A build finished meanwhile: the next repaint shows it.
local rebuilt = {}
for i = 1, 9 do rebuilt[i] = { guild = i == 9 and "Fight The Power" or ("New " .. i), kills = 500 - i, faction = "Horde" } end
Overlord.Leaderboard._displayCache = { sortedGuilds = rebuilt, sortedGuildRating = {}, ready = true }
tickers[1].fn()
text = table.concat(lines, "\n")
assert(text:find("1. New 1 | 499", 1, true) and text:find("9. Fight The Power | 491", 1, true),
    "the repaint did not follow the rebuilt cache:\n" .. text)
assert(builds == buildsHover, "a repaint asked the ranking for its cache again")
Overlord.Leaderboard._displayCache = nil
b.scripts.OnLeave(b)
assert(tickers[1].cancelled and owner == nil, "the repaint outlived the hover")

-- 4. Sorted by rating like the Guilds tab: points; no guild and no fight: the empty lines.
OverlordDB.config.leaderboardGuildSort = "rating"
b.scripts.OnEnter(b)
text = table.concat(lines, "\n")
assert(text:find("1. Guild 9 | 4999", 1, true), "rating sort not followed:\n" .. text)
b.scripts.OnLeave(b)
guilds, rating = {}, {}
activity = {}
b.scripts.OnEnter(b)
text = table.concat(lines, "\n")
assert(text:find("No guild ranked yet this week.", 1, true) and text:find("No fighting in the last 5 minutes.", 1, true),
    "empty lines missing:\n" .. text)
b.scripts.OnLeave(b)
-- Still being built (no row yet): never "no guild".
cacheReady = false
b.scripts.OnEnter(b)
text = table.concat(lines, "\n")
assert(not text:find("No guild ranked yet this week.", 1, true) and text:find("\n...\n", 1, true),
    "a cache still being built said no guild:\n" .. text)
b.scripts.OnLeave(b)
cacheReady = true

-- 5. The ticker stops by itself once the tooltip belongs to someone else.
b.scripts.OnEnter(b)
local t = tickers[#tickers]
owner = "someone else"
t.fn()
assert(t.cancelled, "the repaint kept running for another tooltip")

-- 6. Click opens Overlord, never in an instance; a drag saves where it was put.
b.scripts.OnClick(b)
assert(toggles == 1, "a click did not open Overlord")
Overlord.InstanceSuspended = true
b.scripts.OnClick(b)
assert(toggles == 1, "a click opened Overlord in an instance")
Overlord.InstanceSuspended = false
b.scripts.OnDragStart(b)
b.scripts.OnDragStop(b)
local pos = OverlordDB.cornerWidgetPos
assert(pos and pos.point == "TOPLEFT" and pos.x == 300 and pos.y == 500, "the dragged place was not saved")
CW:ApplyPosition()
assert(b.points[1][1] == "TOPLEFT" and b.points[1][4] == 300, "the saved place is not restored")
-- Hidden mid-drag (an instance): the move ends and its place is kept.
OverlordDB.cornerWidgetPos = nil
b.scripts.OnDragStart(b)
assert(b.moving, "the drag did not start")
Overlord.InstanceSuspended = true
CW:OnInstanceSuspend()
assert(not b.moving and rawget(b, "_dragging") == nil and OverlordDB.cornerWidgetPos,
    "a drag outlived the hidden widget")
Overlord.InstanceSuspended = false
CW:OnInstanceResume()

-- 7. Off again: hidden.
OverlordDB.config.showCornerWidget = false
assert(CW:Refresh() == false and not b.shown, "the widget stayed after its option was turned off")

-- 8. Wiring: loaded after Popups, cut in instances by Core, an option, 7 languages, the tutorial.
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
assert(read("Overlord.toc"):find("\nPopups%.lua\r?\nCornerWidget%.lua\r?\n"), "the module is not loaded after Popups")
local core = read("Core.lua")
local _, suspends = core:gsub("pcall%(self%.CornerWidget%.OnInstanceSuspend, self%.CornerWidget%)", "")
assert(suspends == 2, "the widget is not hidden by both instance cuts (the login-deferred one too)")
assert(core:find("pcall(self.CornerWidget.OnInstanceSuspend, self.CornerWidget)", 1, true)
    and core:find("pcall(Overlord.CornerWidget.OnInstanceResume, Overlord.CornerWidget)", 1, true),
    "the instance cut is not wired")
assert(read("SettingsPanel.lua"):find('label = "CORNER_WIDGET_LABEL"', 1, true), "no option for the widget")
local function count(s, pat) local n = 0; for _ in s:gmatch(pat) do n = n + 1 end; return n end
for _, key in ipairs({ "CORNER_WIDGET_LABEL", "CORNER_WIDGET_TOOLTIP", "CORNER_WIDGET_NO_GUILDS",
    "CORNER_WIDGET_QUIET", "CORNER_WIDGET_HINT" }) do
    assert(count(read("Locales.lua"), "\nL%." .. key .. " = ") == 5
        and count(read("Locales_ptBR.lua"), "\nL%." .. key .. " = ") == 1
        and count(read("Locales_zhCN.lua"), "\nL%." .. key .. " = ") == 1, key .. " is not in the 7 languages")
end
local guide = read("GuideLocales.lua")
assert(guide:find("corner widget", 1, true) and guide:find("widget de coin", 1, true), "the tutorial does not name the widget")
print("Forever corner widget: off by default, hover-only paint, guild table + activity, instance cut, nothing sent OK")
