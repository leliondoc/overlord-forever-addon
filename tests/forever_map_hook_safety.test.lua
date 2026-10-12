-- 2.0: the world map is followed without any hooksecurefunc on WorldMapFrame. On this
-- client a method of a Blizzard object wrapped by an addon can start raising a bare
-- "attempt to call a nil value" in Blizzard's caller (the original runs, the addon's
-- post-hook is no longer called) until the game is relaunched: seen in game on
-- 2026-10-11 and 2026-10-12 (the front's circles stayed painted on the continent map),
-- and reported by other addons of this client. The displayed map is now read by the
-- addon's own driver at every frame while the map is open, and by the map's OnShow
-- script. Real MapMarkers.lua, permissive stub frames.
local e = setmetatable({}, { __index = _G })
e._G = e
local clock = 100
e.GetTime = function() return clock end
e.Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3 } }
e.C_Map = { GetMapInfo = function(id) return { mapID = id, mapType = 3, parentMapID = 1415 } end }
e.C_Timer = { After = function() end }
e.InCombatLockdown = function() return false end
local function permissive()
    return setmetatable({}, { __index = function() return function() end end })
end
local consulted = {}
e.Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }),
    Fronts = setmetatable({ Order = {}, Registry = {},
        GetMapID = function() return nil end,
        -- Two front maps: Elwynn (1429) and Arathi (1417).
        ResolveFrontByOverlayMapID = function(_, id)
            return (id == 1429 or id == 1417) and { id = id == 1429 and "elwynn" or "arathi" } or nil
        end }, { __index = function() return function() end end }),
    Zones = setmetatable({ IsActiveFrontMapID = function() return false end,
        IsMineMapID = function() return false end }, { __index = function() return function() end end }),
    Sync = { RequestConsultFrontSync = function(_, frontId) consulted[#consulted + 1] = frontId end },
    UI = { ResolveLocalizedFontPath = function(_, path) return path end } }
e.CreateFrame = function()
    local f = permissive()
    local scripts = {}
    rawset(f, "SetScript", function(_, name, fn) scripts[name] = fn end)
    rawset(f, "scripts", scripts)
    return f
end
-- The world map: what GetMapID returns is all the addon may read of it.
local shown, open, hooks = 1429, false, {}
local map = permissive()
rawset(map, "GetMapID", function() return shown end)
rawset(map, "IsShown", function() return open end)
rawset(map, "HookScript", function(_, name, fn) hooks[name] = fn end)
rawset(map, "SetMapID", function() end)
e.WorldMapFrame = map
-- No method of a Blizzard object is wrapped.
e.hooksecurefunc = function(owner, name)
    error("hooksecurefunc was called on " .. (owner == map and "WorldMapFrame" or tostring(owner)) .. " " .. tostring(name))
end
setfenv(assert(loadfile("MapMarkers.lua")), e)()
local mm = e.Overlord.MapMarkers
-- Methods of the companion files (keeps, emblems): not under test here.
local hidden = 0
setmetatable(mm, { __index = function(_, key)
    if type(key) == "string" and (key:find("^Hide") or key:find("^Refresh")) then return function() end end
end })
mm.HideAllOverlays = function() hidden = hidden + 1 end
mm._minimapInitialized = true
mm.CreateMapModeButton = function() end
mm.AreWorldMapOverlaysShown = function() return true end
mm:Initialize()
assert(mm._worldMapInitialized, "the world map driver did not initialise")
assert(rawget(map, "SetMapID") and not hooks.SetMapID, "fixture")
local driver = mm._updateFrame and mm._updateFrame.scripts.OnUpdate
assert(type(driver) == "function" and hooks.OnShow and hooks.OnHide, "driver or the map's script hooks are missing")
local function frame()
    clock = clock + 0.016
    pcall(driver, mm._updateFrame, 0.016)   -- the drawing after the map check may fail on stubs
end

-- The map opens on a front map: tracked, and that front's state is asked for once.
open = true
pcall(hooks.OnShow)   -- the canvas caching after the map check fails on stubs
assert(mm:GetTrackedMapID() == 1429, "the opening map is not tracked")
assert(#consulted == 1 and consulted[1] == "elwynn", "opening on a front map did not ask for that front")
frame()
assert(#consulted == 1 and mm:GetTrackedMapID() == 1429, "an unchanged map was treated as a change")

-- Right-click to the continent: seen at the very next frame, the front's layers go.
local hiddenBefore = hidden
shown = 1415
frame()
assert(mm:GetTrackedMapID() == 1415, "the driver did not follow the displayed map at the next frame")
assert(hidden > hiddenBefore, "the front's layers stayed on the continent map")
assert(#consulted == 1, "a map that is no front asked for a front")

-- Another front, map still open: followed, and asked for once however many frames pass.
shown = 1417
frame(); frame(); frame()
assert(mm:GetTrackedMapID() == 1417 and #consulted == 2 and consulted[2] == "arathi",
    "another front map was not followed and asked for once")

-- Map closed, Blizzard moves it meanwhile (our driver does not run closed): the change
-- is taken at the next opening.
open = false
pcall(hooks.OnHide)
shown = 1429
assert(mm:GetTrackedMapID() == 1417, "fixture: the closed map was read")
open = true
pcall(hooks.OnShow)
assert(mm:GetTrackedMapID() == 1429 and #consulted == 3 and consulted[3] == "elwynn",
    "a map changed while closed was not taken at the next opening")

-- A map id that cannot be read (nil, zero, an error) changes nothing.
rawset(map, "GetMapID", function() return 0 end)
frame()
rawset(map, "GetMapID", function() error("secret value") end)
frame()
assert(mm:GetTrackedMapID() == 1429, "an unreadable map id moved the tracked map")
print("World map followed without a method hook: at the next frame while open, at the next opening when closed OK")
