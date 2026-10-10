-- 1.8.2, compact world map (the default): a point's name is written inside its
-- circle, along the inner edge, one rotated letter per font string, in the font and
-- colour of the status line ("Alliance", "Capital"). It starts on the top arc; a name
-- too long for it goes on on the bottom arc, cut between two words. While the login
-- map is pending the status ("SYNCING") takes the bottom arc. Only a name no circle
-- can hold goes against the edge, outside. Run from the addon root with Lua 5.1.
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
-- A player who had used the mode button before 1.8.2 has "full" saved: everyone
-- starts again in compact once, at the first load; a choice made afterwards is kept.
OverlordDB.config.showMapZoneTitles = true
assert(markers:GetWorldMapDisplayMode() == "full")
pcall(markers.Initialize, markers)
assert(OverlordDB.config.mapCompactDefaultApplied == true and markers:GetWorldMapDisplayMode() == "compact",
    "a display saved before 1.8.2 kept the full mode at the first load")
OverlordDB.config.showMapZoneTitles = true
pcall(markers.Initialize, markers)
assert(not markers:ApplyCompactDefaultOnce() and markers:GetWorldMapDisplayMode() == "full",
    "the full display chosen after the update was reset again")
OverlordDB.config.showMapZoneTitles = nil

-- A fake overlay: a letter is half its font size wide and records where it is put.
local function overlay(name, noRotation)
    local o = { zone = { name = name }, made = {} }
    function o:CreateFontString()
        local g = { shown = false }
        function g:SetFont(path, size, flags) self.font, self.size, self.flags = path, size, flags end
        function g:SetTextColor(r, gg, b) self.color = { r, gg, b } end
        function g:SetShadowColor() end
        function g:SetShadowOffset() end
        function g:SetText(text) self.text = text end
        function g:GetStringWidth() return self.size * 0.5 end
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
local function read(list) local text = "" for _, g in ipairs(list) do text = text .. g.text end return text end
-- The letters of the top arc (y > 0) and of the bottom arc (y < 0), in reading order.
local function arcs(o)
    local top, bottom = {}, {}
    for _, g in ipairs(o.made) do
        if g.shown then
            local list = g.y > 0 and top or bottom
            list[#list + 1] = g
        end
    end
    return top, bottom
end
local function checkTop(list, edge, what)
    for i, g in ipairs(list) do
        assert(radius(g) < edge, what .. ": a letter of the top arc is outside the circle")
        assert(near(g.rotation, -math.atan2(g.x, g.y)), what .. ": a letter of the top arc does not follow the circle")
        if i > 1 then assert(g.x > list[i - 1].x, what .. ": the top arc does not read from left to right") end
    end
    assert(near(list[1].x, -list[#list].x), what .. ": the top arc is not centred")
end
local function checkBottom(list, edge, what)
    for i, g in ipairs(list) do
        assert(radius(g) < edge, what .. ": a letter of the bottom arc is outside the circle")
        -- upright at the very bottom, its top toward the centre
        assert(near(g.rotation, math.atan2(g.x, -g.y)), what .. ": a letter of the bottom arc does not follow the circle")
        if i > 1 then assert(g.x > list[i - 1].x, what .. ": the bottom arc does not read from left to right") end
    end
    assert(near(list[1].x, -list[#list].x), what .. ": the bottom arc is not centred")
end

-- (1) A short name: one arc inside the circle, along its edge, centred on the top.
local point = overlay("Refuge")
markers.LayoutZoneArcName(point, 60, 100, true)
local letters = shown(point)
assert(#letters == 6 and #point.made == 6, "one font string per letter expected, got " .. #letters)
for i, g in ipairs(letters) do
    assert(g.text == ("Refuge"):sub(i, i), "letter " .. i .. " reads " .. tostring(g.text))
    assert(g.font == "Fonts\\FRIZQT__.TTF" and g.size == 10 and g.flags == "", "not the status line's font")
    assert(near(g.color[1], 0.85) and near(g.color[2], 0.75) and near(g.color[3], 0.45), "not the status line's colour")
    assert(g.point == "CENTER" and near(radius(g), 24) and g.y > 0, "the name is not along the inner edge, at the top")
end
checkTop(letters, 30, "short name")
-- Nothing changes, nothing is laid out again.
letters[1].x = 999
markers.LayoutZoneArcName(point, 60, 100, true)
assert(letters[1].x == 999 and #point.made == 6, "an unchanged name was laid out again")
-- A zoom moves the letters with the circle.
markers.LayoutZoneArcName(point, 90, 150, true)
assert(near(radius(letters[1]), 45 - 1 - 7.5) and letters[1].size == 15, "the name did not follow the circle's new size")
-- Hover or a capture in progress: the banner shows instead.
markers.LayoutZoneArcName(point, 90, 150, false)
assert(#shown(point) == 0, "the curved name stayed under the banner")
markers.LayoutZoneArcName(point, 90, 150, true)
assert(#shown(point) == 6, "the curved name did not come back after the banner")
markers.HideZoneArcName(point)
assert(#shown(point) == 0)

-- (2) A name too long for the top arc goes on on the bottom arc, cut between two words.
local two = overlay("Dabyrie's Farmstead")
markers.LayoutZoneArcName(two, 36, 60, true)
local top, bottom = arcs(two)
assert(read(top) == "Dabyrie's" and read(bottom) == "Farmstead",
    "the name was not cut between its two words: " .. read(top) .. " / " .. read(bottom))
checkTop(top, 18, "two arcs")
checkBottom(bottom, 18, "two arcs")
assert(top[1].size == 7, "a name that fits on two arcs was made smaller")

-- (3) While the login map is pending, "SYNCING" stays written in the circle (bottom arc).
local syncing = overlay("Refuge")
syncing._olArcStatus = "SYNCING"
markers.LayoutZoneArcName(syncing, 60, 100, true)
top, bottom = arcs(syncing)
assert(read(top) == "Refuge" and read(bottom) == "SYNCING", "the sync status is not written under the name: "
    .. read(top) .. " / " .. read(bottom))
checkTop(top, 30, "syncing")
checkBottom(bottom, 30, "syncing")
syncing._olArcStatus = nil
markers.LayoutZoneArcName(syncing, 60, 100, true)
top, bottom = arcs(syncing)
assert(read(top) == "Refuge" and #bottom == 0, "the sync status stayed after the sync")
-- The name keeps to the top arc while the status holds the bottom one.
local both = overlay("Dabyrie's Farmstead")
both._olArcStatus = "SYNCING"
markers.LayoutZoneArcName(both, 60, 100, true)
top, bottom = arcs(both)
assert(read(top) == "Dabyrie's Farmstead" and read(bottom) == "SYNCING" and top[1].size < 10,
    "with the sync status the name was not kept on the top arc: " .. read(top) .. " / " .. read(bottom))

-- (4) A long name in a large circle: a smaller font rather than leaving the circle.
local long = overlay("Garnison du Ruisseau de l'Ouest")
markers.LayoutZoneArcName(long, 80, 133, true)
top, bottom = arcs(long)
assert(read(top) .. " " .. read(bottom) == "Garnison du Ruisseau de l'Ouest" and #bottom > 0,
    "the two arcs do not read as the name: " .. read(top) .. " / " .. read(bottom))
checkTop(top, 40, "long name")
checkBottom(bottom, 40, "long name")
assert(top[1].size < 13.5 and top[1].size >= 6, "the font was not reduced to keep the name in the circle")
-- The same name in a small circle cannot be held: against the edge, outside, two arcs.
markers.LayoutZoneArcName(long, 36, 60, true)
local rings, hidden = {}, 0
for _, g in ipairs(long.made) do
    if g.shown then
        rings[#rings + 1] = radius(g)
        assert(g.y > -radius(g) * 0.9, "an outside arc went all the way round")
    else
        hidden = hidden + 1
    end
end
table.sort(rings)
assert(hidden == 1 and rings[1] > 36 * 0.54 and not near(rings[1], rings[#rings]),
    "a name no circle can hold was not written outside on two arcs")

-- (4b) During an animated zoom the letters are hidden and laid out once it settles
-- (the layout used to be redone up to twenty times a second).
do
    local clock = 500
    local realTime = GetTime
    GetTime = function() return clock end
    assert(markers:SettleZoneArcs() == false, "a settle pass ran with nothing pending")
    GetTime = realTime
end

-- (5) Names of other alphabets are cut by character, never by byte.
local russian = overlay("Стена Торадина")
markers.LayoutZoneArcName(russian, 60, 100, true)
assert(#russian.made == 14 and russian.made[1].text == "С" and russian.made[14].text == "а", "Cyrillic name cut by byte")
local chinese = overlay("索拉丁之墙")
markers.LayoutZoneArcName(chinese, 60, 100, true)
assert(#chinese.made == 5 and chinese.made[5].text == "墙" and #shown(chinese) == 5, "Chinese name cut by byte")

-- (6) An overlay given to another point keeps no letter of the previous name.
russian.zone = { name = "Refuge" }
markers.LayoutZoneArcName(russian, 60, 100, true)
assert(#shown(russian) == 6 and #russian.made == 14, "letters of the previous name stayed on a reused overlay")

-- (7) One word no circle can hold, inside or outside: nothing is written (the banner
-- still shows on hover).
local endless = overlay(string.rep("W", 80))
markers.LayoutZoneArcName(endless, 20, 34, true)
assert(#shown(endless) == 0, "a name longer than the circle was written over itself")

-- (8) A client that cannot turn text: the name stays straight, at the top of the circle.
local flat = overlay("Refuge Pointe", true)
markers.LayoutZoneArcName(flat, 60, 100, true)
local straight = shown(flat)
assert(#straight == 1 and straight[1].text == "Refuge Pointe" and straight[1].point == "TOP",
    "without text rotation the name was not written straight at the top of the circle")
print("Forever map arc names: compact by default, the name inside the circle (top arc, then bottom), sync status kept, "
    .. "any alphabet, reused overlays clean")
