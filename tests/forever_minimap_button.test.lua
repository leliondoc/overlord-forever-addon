local methods = {}
local function frame(parent)
    return setmetatable({ parent = parent, scripts = {}, hooks = {}, width = 140, height = 140 },
        { __index = methods })
end
function methods:SetSize(w, h)
    self.width, self.height = w, h
    if self.hooks.OnSizeChanged then self.hooks.OnSizeChanged(self, w, h) end
end
function methods:GetWidth() return self.width end
function methods:GetHeight() return self.height end
function methods:GetParent() return self.parent end
function methods:SetParent(parent) self.parent = parent end
function methods:SetPoint(...) self.point = { ... } end
function methods:GetPoint() return unpack(self.point or {}) end
function methods:ClearAllPoints() self.point = nil end
function methods:SetScript(event, fn) self.scripts[event] = fn end
function methods:HookScript(event, fn) self.hooks[event] = fn end
function methods:CreateTexture() return frame(self) end
setmetatable(methods, { __index = function(_, name)
    if name:match("^Set") or name:match("^Register") or name == "Hide" then return function() end end
end })
function CreateFrame(_, _, parent) return frame(parent) end
local queued = {}
C_Timer = { After = function(_, fn) queued[#queued + 1] = fn end }
Minimap = frame()
Overlord = { L = {}, UI = { ResolveLocalizedFontPath = function(_, fallback) return fallback end } }
OverlordDB = { minimapAngle = math.pi, config = {} }
assert(loadfile("MapMarkers.lua"))()
local markers = Overlord.MapMarkers
Minimap:SetSize(280, 280)
local button = markers:CreateMinimapButton()
local function position(x, y)
    local point, relative, anchor, actualX, actualY = button:GetPoint()
    assert(point == "CENTER" and relative == Minimap and anchor == "CENTER")
    assert(math.abs(actualX - x) < 0.001 and math.abs(actualY - y) < 0.001,
        tostring(actualX) .. ", " .. tostring(actualY))
end
position(-145, 0)
-- Edit Mode finalizes a smaller minimap after the early ADDON_LOADED creation.
Minimap:SetSize(140, 140)
position(-75, 0)
for _, fn in ipairs(queued) do fn() end
position(-75, 0)
markers:SetMinimapButtonPos(math.pi / 2)
Minimap:SetSize(220, 100)
position(0, 55)
Minimap.hooks.OnShow(Minimap)
position(0, 55)
function GetMinimapShape() return "SQUARE" end
markers:SetMinimapButtonPos(math.pi / 4)
position(115, 55)
assert(markers:CreateMinimapButton() == button)

-- A collector owns the anchor, even when it leaves the original parent intact.
local bag = frame()
button:SetPoint("CENTER", bag, "CENTER", 12, 34)
Minimap:SetSize(180, 180)
markers:CreateMinimapButton()
assert(select(2, button:GetPoint()) == bag)
button:SetParent(bag)
button:SetPoint("CENTER", Minimap, "CENTER", 12, 34)
Minimap.hooks.OnShow(Minimap)
assert(select(4, button:GetPoint()) == 12)

-- World map display: three modes (full, compact, hidden) offered in Blizzard's
-- "Map Filters" menu and in an Overlord submenu of the minimap tracking menu,
-- registered only once. Compact = zone names off (names on hover).
-- Keep/outpost/mine map modules are not loaded here: missing methods are no-ops.
GetTime = GetTime or function() return 100 end
markers._worldMapFilterRegistered = false
markers._mapModeButton = false -- no world map in this stub: no corner button
setmetatable(markers, { __index = function() return function() end end })
local builders = {}
Menu = { ModifyMenu = function(tag, fn) builders[tag] = fn end }
assert(markers:RegisterWorldMapFilterToggle() and not markers:RegisterWorldMapFilterToggle())
assert(builders.MENU_WORLD_MAP_TRACKING and builders.MENU_MINIMAP_TRACKING, "Blizzard menus not extended")
local function menu()
    local m = { radios = {} }
    function m.CreateDivider() end
    function m.CreateTitle() end
    function m.CreateRadio(_, text, isSelected, setSelected, data)
        m.radios[data] = { get = function() return isSelected(data) end, set = function() setSelected(data) end }
    end
    function m.CreateCheckbox(_, text, isSelected, toggle) m.checkbox = { get = isSelected, set = toggle } end
    function m.CreateButton() m.sub = menu() return m.sub end
    return m
end
local filters = menu()
builders.MENU_WORLD_MAP_TRACKING(nil, filters)
local radios = filters.radios
assert(radios.full and radios.compact and radios.hidden, "Map filter modes missing")
assert(radios.compact.get() and not radios.full.get(), "Compact display should be the default (1.8.2)")
radios.compact.set()
assert(OverlordDB.config.showMapZoneTitles == false and OverlordDB.config.showWorldMapOverlays ~= false
    and radios.compact.get(), "Compact did not keep the map on with names off")
radios.hidden.set()
assert(OverlordDB.config.showWorldMapOverlays == false and radios.hidden.get(), "Filter did not hide the map displays")
assert(markers:GetNextWorldMapDisplayMode() == "full")
radios.full.set()
assert(OverlordDB.config.showWorldMapOverlays == true and OverlordDB.config.showMapZoneTitles == true
    and radios.full.get(), "Filter did not restore the full display")
assert(markers:GetNextWorldMapDisplayMode() == "compact")
assert(markers:SetWorldMapDisplayMode("bogus") == false and radios.full.get())
local tracking = menu()
builders.MENU_MINIMAP_TRACKING(nil, tracking)
assert(tracking.sub and tracking.sub.radios.compact and tracking.sub.checkbox, "Minimap tracking submenu missing")
tracking.sub.radios.compact.set()
assert(filters.radios.compact.get(), "Minimap menu and map filters disagree")
assert(tracking.sub.checkbox.get() == true, "Minimap icons should be on by default")
print("Minimap button: login resize, border radius, rectangle, square, show and button collectors OK")
