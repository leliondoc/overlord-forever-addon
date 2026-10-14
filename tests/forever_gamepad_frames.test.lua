-- Gamepad interface (Options > Controller > Enable gamepad UI). Blizzard's stick
-- navigation wraps the global CreateFrame: every frame created WITH a parent that sits
-- under one of its open windows makes it walk that whole window again, inside the
-- addon's execution (Blizzard_GamepadSmartNavigation, SetupFrameHooks / UpdateParent).
-- The world map is such a window, and the addon creates its circles, pins and emblems
-- under it. With the gamepad interface on, those frames are created without a parent
-- and attached afterwards: the same frame (parent, strata, one level above), and that
-- hook has nothing to walk. With mouse and keyboard nothing changes.
-- Real MapMarkers.lua, stub frames. Run from the addon root with Lua 5.1.
local methods = {}
local function frame(parent)
    return setmetatable({ parent = parent, strata = "MEDIUM", level = 1 }, { __index = methods })
end
function methods:SetParent(parent) self.parent = parent end
function methods:GetParent() return self.parent end
function methods:SetFrameStrata(strata) self.strata = strata end
function methods:GetFrameStrata() return self.strata end
function methods:SetFrameLevel(level) self.level = level end
function methods:GetFrameLevel() return self.level end
setmetatable(methods, { __index = function(_, name)
    if name:match("^Set") or name:match("^Register") or name == "Hide" then return function() end end
end })

-- What Blizzard's hook would see: the parent handed to CreateFrame.
local calls = {}
function CreateFrame(frameType, name, parent)
    calls[#calls + 1] = { frameType = frameType, name = name, parent = parent }
    return frame(parent)
end
C_Timer = { After = function() end }
Minimap = frame()
Overlord = { L = {}, UI = { ResolveLocalizedFontPath = function(_, fallback) return fallback end } }
OverlordDB = { config = {} }
assert(loadfile("MapMarkers.lua"))()
local newFrame = Overlord.MapMarkers.NewFrame
assert(type(newFrame) == "function", "the map's frame factory is missing")

local canvas = frame()
canvas.strata, canvas.level = "HIGH", 40

-- No gamepad API at all, then mouse and keyboard: a plain CreateFrame with its parent.
local gamepad = false
for pass = 1, 2 do
    calls = {}
    local made = newFrame("Frame", canvas)
    assert(#calls == 1 and calls[1].frameType == "Frame" and calls[1].name == nil
        and calls[1].parent == canvas and made.parent == canvas,
        "pass " .. pass .. ": the frame is no longer created under its parent")
    InputUtil = { IsGamepadUIEnabled = function() return gamepad end }
end

-- Gamepad interface: no parent is handed to CreateFrame, and the frame ends where a
-- child created the usual way would be.
gamepad = true
calls = {}
local button = newFrame("Button", canvas)
assert(#calls == 1 and calls[1].frameType == "Button" and calls[1].parent == nil,
    "with the gamepad interface a parent is still handed to CreateFrame")
assert(button.parent == canvas, "the frame was not attached to its parent")
assert(button.strata == "HIGH" and button.level == 41, "the frame is not one level above its parent, in its strata")

-- No file of the world map hands a parent to CreateFrame itself any more, the minimap
-- aside (the minimap is not one of Blizzard's navigation windows).
local function withoutComments(text)
    return (text:gsub("%-%-[^\n]*", ""))
end
for _, name in ipairs({ "MapMarkers.lua", "MapMarkersKeep.lua", "MapWorldEmblems.lua", "GeneralMap.lua" }) do
    local file = assert(io.open(name, "rb"))
    local code = withoutComments(file:read("*a"))
    file:close()
    for kind, parent in code:gmatch('CreateFrame%(%s*"(%a+)"%s*,%s*[^,%)]+,%s*([^,%)]+)') do
        assert(parent:match("^%s*Minimap%s*$"),
            name .. ": CreateFrame(\"" .. kind .. "\", ..., " .. parent .. ") bypasses MapMarkers.NewFrame")
    end
end

-- The rank tab is not created at all on the character sheet with the gamepad interface.
do
    local file = assert(io.open("RanksUI.lua", "rb"))
    local code = withoutComments(file:read("*a"))
    file:close()
    local guard = code:find("if not UIR.tab and GamepadUI() then", 1, true)
    local create = code:find("local tab = UIR:EnsureTab()", 1, true)
    assert(guard and create and guard < create, "the rank tab is created before the gamepad check")
end
