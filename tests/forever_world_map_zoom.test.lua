-- World map zoom (2026-10-17, "the points move in all directions" on a wheel zoom).
-- Blizzard changes the map scale at every frame of a wheel step; Overlord lays its markers
-- out again only 20 times a second. Between two layouts the overlay root takes the ratio
-- of the two scales, so every marker stays exactly on its map point at every frame; each
-- layout puts the root back at scale 1 (fixed-size icons keep their exact size).
-- Real MapMarkers.lua, a small stand-in for the game's frame geometry. Lua 5.1.
local methods = {}
local function frame(parent)
    return setmetatable({ parent = parent, scale = 1, w = 0, h = 0 }, { __index = methods })
end
function methods:GetParent() return self.parent end
function methods:SetParent(p) self.parent = p end
function methods:SetScale(k) self.scale = k end
function methods:GetEffectiveScale()
    return (self.parent and self.parent:GetEffectiveScale() or 1) * self.scale
end
function methods:SetSize(w, h) self.w, self.h = w, h end
function methods:GetWidth() return self.w end
function methods:GetHeight() return self.h end
function methods:SetAllPoints(other) self.all = other end
function methods:GetFrameLevel() return 1 end
function methods:GetFrameStrata() return "HIGH" end
function methods:ClearAllPoints() self.anchor = nil end
function methods:SetPoint(point, rel, relPoint, x, y)
    assert(point == "TOPLEFT" and relPoint == "TOPLEFT", "only TOPLEFT anchors are modelled")
    self.anchor = { rel = rel, x = x or 0, y = y or 0 }
end
-- Screen position of the top-left corner (screen pixels), then in the frame's own units.
function methods:ScreenTopLeft()
    if self.all then return self.all:ScreenTopLeft() end
    local a = assert(self.anchor, "frame not anchored")
    local rl, rt = a.rel:ScreenTopLeft()
    local eff = self:GetEffectiveScale()
    return rl + a.x * eff, rt + a.y * eff
end
function methods:GetLeft() local l = self:ScreenTopLeft(); return l / self:GetEffectiveScale() end
function methods:GetTop() local _, t = self:ScreenTopLeft(); return t / self:GetEffectiveScale() end
setmetatable(methods, { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return function() end end
end })

function CreateFrame(_, _, parent) return frame(parent) end
C_Timer = { After = function() end }
function securecall(fn, ...) return fn(...) end
Minimap = frame()
Overlord = { L = {}, UI = { ResolveLocalizedFontPath = function(_, fallback) return fallback end } }
OverlordDB = { config = {} }
assert(loadfile(OLD_MM or "MapMarkers.lua"))()
local MM = Overlord.MapMarkers

-- Blizzard's map: the scroll window at (100, 700) on screen, 1000 x 700; its canvas
-- (1002 x 668 map units) scaled by s, its top-left corner at (cl, ct) on screen.
local scroll = frame()
scroll.w, scroll.h = 1000, 700
function scroll:ScreenTopLeft() return 100, 700 end
local canvas = frame(scroll)
canvas.w, canvas.h = 1002, 668
local s, cl, ct = 1, 100, 700
function canvas:GetEffectiveScale() return s end
function canvas:ScreenTopLeft() return cl, ct end
WorldMapFrame = { ScrollContainer = scroll, IsShown = function() return true end }
scroll.Child = canvas
local _, parent = MM:GetWorldMapCanvas()
assert(parent, "no overlay root")
-- Before the zoom fix, no commit step existed (regression check against an old file).
local commit = MM.CommitWorldOverlayZoom or function() end

-- Markers at a few map points, laid out like the real layers (offset from the root).
local points = { { 20, 30 }, { 500, 334 }, { 980, 640 }, { 700, 100 } }
local placed = {}
local function layout()
    for i, p in ipairs(points) do
        local ox, oy = MM:GetWorldMapOverlayPoint(canvas, parent, p[1], p[2])
        placed[i] = { ox, oy }
    end
end
local function worstError()
    local rl, rt = parent:ScreenTopLeft()
    local eff = parent:GetEffectiveScale()
    local worst = 0
    for i, p in ipairs(points) do
        local sx, sy = rl + placed[i][1] * eff, rt + placed[i][2] * eff
        local ex, ey = cl + p[1] * s, ct - p[2] * s
        worst = math.max(worst, math.abs(sx - ex), math.abs(sy - ey))
    end
    return worst
end

MM:SyncWorldOverlayTransform(canvas)
layout()
assert(worstError() < 1e-6, "markers off their points before any zoom")

-- A wheel step: scale 1 -> 1.57 over 18 frames (eased) about a cursor at (600, 400);
-- the driver lays out again every third frame (20 Hz at 60 frames a second).
local function zoomTo(target, frames, cursorX, cursorY)
    local s0, l0, t0 = s, cl, ct
    local worst = 0
    for f = 1, frames do
        local e = 1 - (1 - f / frames) ^ 3
        local ns = s0 + (target - s0) * e
        cl = cursorX - (cursorX - l0) * ns / s0
        ct = cursorY - (cursorY - t0) * ns / s0
        s = ns
        MM:SyncWorldOverlayTransform(canvas)
        if f % 3 == 0 then
            commit(MM, canvas)
            assert(math.abs(parent:GetEffectiveScale() - 1) < 1e-9, "root not back at scale 1 for a layout")
            layout()
        end
        worst = math.max(worst, worstError())
    end
    return worst
end
local worst = zoomTo(1.57, 18, 600, 400)
assert(worst < 0.01, ("zoom in: a marker was %.1f px off its point"):format(worst))
worst = zoomTo(2.14, 18, 300, 600)
assert(worst < 0.01, ("zoom in again: a marker was %.1f px off its point"):format(worst))
worst = zoomTo(1, 18, 900, 200)
assert(worst < 0.01, ("zoom out: a marker was %.1f px off its point"):format(worst))

-- Pan only: a single translation, the root keeps scale 1.
for f = 1, 10 do
    cl, ct = cl - 7, ct + 3
    MM:SyncWorldOverlayTransform(canvas)
    assert(worstError() < 1e-6, "pan: markers off their points")
end
assert(math.abs(parent:GetEffectiveScale() - 1) < 1e-9, "pan changed the root scale")

-- After the zoom: one layout, root at scale 1, icons at their fixed size.
commit(MM, canvas)
layout()
assert(math.abs(parent:GetEffectiveScale() - 1) < 1e-9 and worstError() < 1e-6, "settled zoom: root or markers wrong")

print("World map zoom: markers on their points at every frame of a zoom, root at scale 1 for layouts OK")
