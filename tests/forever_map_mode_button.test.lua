-- 2.3.2: the Overlord button in the world map's corner can be hidden (options, the map's
-- Filters menu, /ov map button) and moved with right-click + drag. A right click alone does
-- nothing. Its place is kept as a share of the map's size and stays inside the map.
local methods = {}
local function frame(parent)
    return setmetatable({ parent = parent, scripts = {}, hooks = {}, width = 32, height = 32,
        scale = 1, shown = true }, { __index = methods })
end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:GetWidth() return self.width end
function methods:GetHeight() return self.height end
function methods:SetScale(s) self.scale = s end
function methods:GetScale() return self.scale end
function methods:GetEffectiveScale() return self.scale * (self.parent and self.parent:GetEffectiveScale() or 1) end
function methods:GetParent() return self.parent end
function methods:SetPoint(...) self.point = { ... } end
function methods:ClearAllPoints() self.point = nil end
function methods:SetScript(event, fn) self.scripts[event] = fn end
function methods:GetScript(event) return self.scripts[event] end
function methods:HookScript(event, fn) self.hooks[event] = fn end
function methods:CreateTexture() return frame(self) end
function methods:SetShown(v) self.shown = v and true or false end
function methods:Hide() self.shown = false end
function methods:IsMouseOver() return false end
function methods:GetFrameStrata() return "MEDIUM" end
function methods:GetFrameLevel() return 1 end
setmetatable(methods, { __index = function(_, name)
    if name:match("^Set") or name:match("^Register") then return function() end end
end })
function CreateFrame(_, _, parent) return frame(parent) end
C_Timer = { After = function() end }
GetTime = function() return 100 end
local mouseDown, cursor = false, { 0, 0 }
function IsShiftKeyDown() return false end
function IsMouseButtonDown(button) return mouseDown == button end
function GetCursorPosition() return cursor[1], cursor[2] end
GameTooltip = setmetatable({}, { __index = function() return function() end end })
local printed = {}
Overlord = { L = {}, UI = { ResolveLocalizedFontPath = function(_, f) return f end },
    PrintNotification = function(_, text) printed[#printed + 1] = text end }
OverlordDB = { config = {} }
-- The map's scroll area: 1000 x 600 at screen scale 0.5, its top right corner at (1100, 700).
local container = frame()
container.width, container.height, container.scale = 1000, 600, 0.5
function container:GetRight() return 1100 end
function container:GetTop() return 700 end
WorldMapFrame = { ScrollContainer = container }
assert(loadfile("MapMarkers.lua"))()
local mm = Overlord.MapMarkers
mm.GetWorldMapDisplayMode = function() return "compact" end
mm.GetNextWorldMapDisplayMode = function() return "full" end
local modes = 0
mm.SetWorldMapDisplayMode = function() modes = modes + 1 end
local btn = mm:CreateMapModeButton()
assert(btn and btn.shown, "map button not created")

-- 1. Default place: the corner, as before.
assert(btn.point[1] == "TOPRIGHT" and btn.point[2] == container and btn.point[4] == -5 and btn.point[5] == -5,
    "the button left the corner by default")

-- 2. A plain click changes the display; a right-click + drag moves the button, with no mode change.
btn.scripts.OnMouseDown(btn, "LeftButton")
btn.scripts.OnClick(btn, "LeftButton")
assert(modes == 1, "a click did not change the display")
mouseDown = "RightButton"
btn.scripts.OnMouseDown(btn, "RightButton")
assert(btn.scripts.OnUpdate, "a right press did not start the drag")
-- Cursor at the map's middle, in screen pixels (map units times the map's scale 0.5).
cursor ={ (1100 - 500) * 0.5, (700 - 300) * 0.5 }
btn.scripts.OnUpdate(btn)
local pos = OverlordDB.config.mapModeButtonPos
assert(pos and math.abs(pos.x - 0.5) < 1e-9 and math.abs(pos.y - 0.5) < 1e-9,
    "drag share wrong: " .. tostring(pos and pos.x) .. ", " .. tostring(pos and pos.y))
-- Anchored by its centre; offsets in the button's own scale (1.3 times the map's).
assert(btn.point[1] == "CENTER" and btn.point[3] == "TOPRIGHT"
    and math.abs(btn.point[4] - (-500 / 1.3)) < 1e-6 and math.abs(btn.point[5] - (-300 / 1.3)) < 1e-6,
    "moved button not placed at its share")
mouseDown = false
btn.scripts.OnMouseUp(btn, "RightButton")
assert(btn.scripts.OnUpdate == nil, "the drag did not stop")
btn.scripts.OnClick(btn, "RightButton")
assert(modes == 1, "the end of a drag changed the display")
-- The next plain click works again.
btn.scripts.OnMouseDown(btn, "LeftButton")
btn.scripts.OnClick(btn, "LeftButton")
assert(modes == 2, "a click after a drag was swallowed")

-- 3. Dragged past the map's edge: the whole button stays inside.
mouseDown = "RightButton"
btn.scripts.OnMouseDown(btn, "RightButton")
cursor = { 5000, 5000 }
btn.scripts.OnUpdate(btn)
local half = 32 * 1.3 * 0.5
assert(math.abs(pos.x - half / 1000) < 1e-9 and math.abs(pos.y - half / 600) < 1e-9,
    "the button left the map: " .. pos.x .. ", " .. pos.y)
mouseDown = false
btn.scripts.OnUpdate(btn) -- button released elsewhere: the drag ends by itself
assert(btn.scripts.OnUpdate == nil, "a drag released outside the button kept running")
-- (released outside: no OnClick came) the next plain click is not swallowed.
btn.scripts.OnMouseDown(btn, "LeftButton")
btn.scripts.OnClick(btn, "LeftButton")
assert(modes == 3, "a click after a drag released outside was swallowed")

-- 4. The full map (another size): the button keeps its share.
pos.x, pos.y = 0.25, 0.75
container.width, container.height = 2000, 1200
container.hooks.OnSizeChanged(container)
assert(math.abs(btn.point[4] - (-500 / 1.3)) < 1e-6 and math.abs(btn.point[5] - (-900 / 1.3)) < 1e-6,
    "a moved button did not follow the map's size")

-- 5. A right click alone (no move) does nothing: no hiding, no notice, no mode change.
btn.scripts.OnMouseDown(btn, "RightButton")
btn.scripts.OnMouseUp(btn, "RightButton")
btn.scripts.OnClick(btn, "RightButton")
assert(OverlordDB.config.mapModeButtonHidden == nil and btn.shown and #printed == 0 and modes == 3,
    "a right click hid the button, printed or changed the display")
btn.scripts.OnMouseDown(btn, "LeftButton")
btn.scripts.OnClick(btn, "LeftButton")
assert(modes == 4, "a click after a right click was swallowed")
-- Hidden from the options or the Filters menu; it stays hidden when the map opens, and comes back.
assert(mm:SetMapModeButtonShown(false) and not btn.shown and not mm:IsMapModeButtonShown(),
    "the option did not hide the button")
btn.shown = true -- the map opens and shows its children
btn.scripts.OnShow(btn)
assert(not btn.shown, "the map's opening showed a hidden button")
assert(mm:SetMapModeButtonShown(true) and btn.shown and OverlordDB.config.mapModeButtonHidden == nil,
    "the button did not come back")
assert(mm:SetMapModeButtonShown(true) == false, "showing a shown button counted as a change")

-- 6. In an instance it stays hidden whatever the option.
Overlord.InstanceSuspended = true
mm:RefreshMapModeButton()
assert(not btn.shown, "map button shown in an instance")
Overlord.InstanceSuspended = nil
mm:RefreshMapModeButton()
assert(btn.shown)
print("Map mode button: hide, right-click + drag, kept share, right click alone ignored OK")
