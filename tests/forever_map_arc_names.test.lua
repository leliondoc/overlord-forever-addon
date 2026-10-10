-- 1.8.2, compact world map (the default): a point's name follows the top of its
-- circle, one rotated letter per font string, in the font and colour of the status
-- line ("Alliance", "Capital"). A name too long for one arc takes two, cut between
-- two words. Run from the addon root with Lua 5.1.
local methods = {}
local function frame(parent)
    return setmetatable({ parent = parent, scripts = {}, hooks = {} }, { __index = methods })
end
setmetatable(methods, { __index = function(_, name)
    if name:match("^Set") or name:match("^Register") or name == "Hide" then return function() end end
end })
function CreateFrame(_, _, parent) return frame(parent) end
C_Timer = { After = function() end }
Minimap = frame()
Overlord = { L = {}, UI = { ResolveLocalizedFontPath = function(_, fallback) return fallback end } }
OverlordDB = { config = {} }
assert(loadfile("MapMarkers.lua"))()
local markers = Overlord.MapMarkers
assert(markers:GetWorldMapDisplayMode() == "compact", "the compact display is not the default")
OverlordDB.config.showMapZoneTitles = true
assert(markers:GetWorldMapDisplayMode() == "full", "a player's choice of the full display was not kept")
OverlordDB.config.showMapZoneTitles = nil

-- A fake overlay: every letter is 4 px wide and records where it is put.
local function overlay(name, noRotation)
    local o = { zone = { name = name }, made = {} }
    function o:CreateFontString()
        local g = { shown = false }
        function g:SetFont(path, size, flags) self.font, self.size, self.flags = path, size, flags end
        function g:SetTextColor(r, gg, b) self.color = { r, gg, b } end
        function g:SetShadowColor() end
        function g:SetShadowOffset() end
        function g:SetText(text) self.text = text end
        function g:GetStringWidth() return 4 end
        function g:ClearAllPoints() self.x, self.y = nil, nil end
        function g:SetPoint(point, _, _, x, y) self.point, self.x, self.y = point, x, y end
        function g:Show() self.shown = true end
        function g:Hide() self.shown = false end
        if not noRotation then function g:SetRotation(angle) self.rotation = angle end end
        self.made[#self.made + 1] = g
        return g
    end
    return o
end
local function shown(o)
    local list = {}
    for _, g in ipairs(o.made) do if g.shown then list[#list + 1] = g end end
    return list
end
local function radius(g) return math.sqrt(g.x * g.x + g.y * g.y) end
local function near(a, b) return math.abs(a - b) < 0.01 end

-- (1) A short name: one arc against the circle's edge, centred on its top.
local point = overlay("Go'Shek Farm")
markers.LayoutZoneArcName(point, 36, 60, true)
local letters = shown(point)
assert(#letters == 12 and #point.made == 12, "one font string per letter expected, got " .. #letters)
local edge = 36 * 0.54
for i, g in ipairs(letters) do
    assert(g.text == ("Go'Shek Farm"):sub(i, i), "letter " .. i .. " reads " .. tostring(g.text))
    assert(g.font == "Fonts\\FRIZQT__.TTF" and g.size == 7 and g.flags == "", "not the status line's font")
    assert(near(g.color[1], 0.85) and near(g.color[2], 0.75) and near(g.color[3], 0.45), "not the status line's colour")
    assert(g.point == "CENTER" and near(radius(g), letters[1].x and radius(letters[1])), "letters are not on one arc")
    assert(radius(g) > edge and radius(g) < edge + 8, "the name does not sit against the circle's edge")
    assert(g.y > 0, "a short name left the top of the circle")
    -- upright at the top, turned clockwise to the right of it
    assert(near(g.rotation, -math.atan2(g.x, g.y)), "letter " .. i .. " does not follow the circle")
    if i > 1 then assert(g.x > letters[i - 1].x, "the name does not read from left to right") end
end
assert(near(letters[1].x, -letters[12].x) and near(letters[1].y, letters[12].y), "the name is not centred on the top")
-- Nothing changes, nothing is laid out again.
letters[1].x = 999
markers.LayoutZoneArcName(point, 36, 60, true)
assert(letters[1].x == 999 and #point.made == 12, "an unchanged name was laid out again")
-- A zoom moves the letters with the circle.
markers.LayoutZoneArcName(point, 72, 120, true)
assert(radius(letters[1]) > 72 * 0.54 and letters[1].size == 12, "the name did not follow the circle's new size")
-- Hover or a capture in progress: the banner shows instead.
markers.LayoutZoneArcName(point, 72, 120, false)
assert(#shown(point) == 0, "the curved name stayed under the banner")
markers.LayoutZoneArcName(point, 72, 120, true)
assert(#shown(point) == 12, "the curved name did not come back after the banner")
markers.HideZoneArcName(point)
assert(#shown(point) == 0)

-- (2) A long name: two arcs, cut between two words, the first words on the outer one.
local long = overlay("Garnison du Ruisseau de l'Ouest")
markers.LayoutZoneArcName(long, 36, 60, true)
local outer, inner, hidden = {}, {}, 0
local rings = {}
for _, g in ipairs(long.made) do
    if g.shown then rings[#rings + 1] = radius(g) else hidden = hidden + 1 end
end
table.sort(rings)
assert(hidden == 1 and not near(rings[1], rings[#rings]), "a long name was not cut into two arcs at a space")
for _, g in ipairs(long.made) do
    if g.shown then
        local list = near(radius(g), rings[#rings]) and outer or inner
        list[#list + 1] = g
    end
end
local function read(list) local text = "" for _, g in ipairs(list) do text = text .. g.text end return text end
assert(read(outer) .. " " .. read(inner) == "Garnison du Ruisseau de l'Ouest",
    "the two arcs do not read as the name: " .. read(outer) .. " / " .. read(inner))
for _, list in ipairs({ outer, inner }) do
    local sweep = math.atan2(list[#list].x, list[#list].y) - math.atan2(list[1].x, list[1].y)
    assert(sweep > 0 and sweep < math.rad(210), "an arc goes too far round the circle: " .. math.deg(sweep))
end
assert(rings[1] > edge, "the inner arc is inside the circle")

-- (3) Names of other alphabets are cut by character, never by byte.
local russian = overlay("Стена Торадина")
markers.LayoutZoneArcName(russian, 36, 60, true)
assert(#russian.made == 14 and russian.made[1].text == "С" and russian.made[14].text == "а", "Cyrillic name cut by byte")
local chinese = overlay("索拉丁之墙")
markers.LayoutZoneArcName(chinese, 36, 60, true)
assert(#chinese.made == 5 and chinese.made[5].text == "墙" and #shown(chinese) == 5, "Chinese name cut by byte")

-- (4) An overlay given to another point keeps no letter of the previous name.
russian.zone = { name = "Refuge" }
markers.LayoutZoneArcName(russian, 36, 60, true)
assert(#shown(russian) == 6 and #russian.made == 14, "letters of the previous name stayed on a reused overlay")

-- (5) One word no circle can hold: nothing is written (the banner still shows on hover).
local endless = overlay(string.rep("W", 60))
markers.LayoutZoneArcName(endless, 20, 34, true)
assert(#shown(endless) == 0, "a name longer than the circle was written over itself")

-- (6) A client that cannot turn text: the name stays straight above the circle.
local flat = overlay("Refuge Pointe", true)
markers.LayoutZoneArcName(flat, 36, 60, true)
local straight = shown(flat)
assert(#straight == 1 and straight[1].text == "Refuge Pointe" and straight[1].point == "BOTTOM" and straight[1].y > edge,
    "without text rotation the name was not written straight above the circle")
print("Forever map arc names: compact by default, the name follows the circle (one or two arcs), any alphabet, reused overlays clean")
