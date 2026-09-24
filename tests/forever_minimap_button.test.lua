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
print("Minimap button: login resize, border radius, rectangle, square, show and button collectors OK")
