-- Hall of Fame sidebar, real HallOfFameUI.lua on stub frames. With the shipped
-- single beta week, the beta is a plain category. With several weeks, like Retail:
-- opens collapsed (highlighted, newest week shown); a click expands it, a second
-- click collapses it without changing the week, another top-level category
-- collapses it. Child buttons are narrowed and re-colored, parents restored.

-- Stub frames: unknown fields are child frames, unknown Get* methods return numbers,
-- any other method is a no-op.
local function mock(name)
    local o = { _name = name, _shown = true }
    return setmetatable(o, {
        __index = function(t, k)
            if type(k) == "string" and k:sub(1, 1) == "_" then return nil end
            if type(k) == "string" and k:match("^Get%u") and k ~= "GetPoint" then
                return function() return 100, 100, 100, 1 end
            end
            local child = mock(k)
            rawset(t, k, child)
            return child
        end,
        __call = function() return mock("ret") end,
        __add = function() return 100 end, __sub = function() return 100 end,
        __mul = function() return 100 end, __div = function() return 100 end,
        __unm = function() return -100 end,
        __concat = function(a, b) return tostring(a) .. tostring(b) end,
    })
end

buttons = {}
CreateFrame = function(kind, _, _, template)
    local f = mock(template or kind)
    f.SetScript = function(self, event, fn) self["_" .. event] = fn end
    f.HookScript = f.SetScript
    f.Show = function(self) self._shown = true end
    f.Hide = function(self) self._shown = false end
    f.IsShown = function(self) return self._shown end
    if template == "AchievementCategoryTemplate" then
        local b = f.Button
        b.SetScript = f.SetScript
        b.Label.SetText = function(self, text) self._text = text end
        b.Label.GetTextColor = function() return 1, 0.82, 0, 1 end
        b.Label.SetTextColor = function(self, r, g, bl, a) self._color = { r, g, bl, a } end
        b.Background.GetVertexColor = function() return 1, 1, 1, 1 end
        b.Background.SetVertexColor = function(self, r, g, bl, a) self._color = { r, g, bl, a } end
        b.LockHighlight = function(self) self._hl = true end
        b.UnlockHighlight = function(self) self._hl = false end
        b.GetWidth = function(self) return self._width or 160 end
        b.SetWidth = function(self, w) self._width = w end
        b.GetNumPoints = function() return 1 end
        b.GetPoint = function() return "TOPRIGHT" end
        buttons[#buttons + 1] = f
    end
    return f
end
C_AddOns = { IsAddOnLoaded = function() return true end, LoadAddOn = function() return true end }
C_Timer = {
    NewTimer = function() return { Cancel = function() end } end,
    After = function() end,
    NewTicker = function() return { Cancel = function() end } end,
}
GetTime = function() return 0 end
UIParent, GameTooltip = mock("UIParent"), mock("GameTooltip")
hooksecurefunc = function() end
UISpecialFrames = {}
tinsert = table.insert
GetLocale = function() return "frFR" end
-- Fresh module load; extraWeek copies the shipped week 1 as a week 2 (later milestones).
local function load(extraWeek)
    buttons = {}
    Overlord = { L = {}, UI = setmetatable({}, { __index = function() return function() return 1 end end }) }
    dofile("Locales.lua")
    dofile("HallOfFameData.lua")
    if extraWeek then
        local entries = Overlord.BetaChampionEntries
        for i = 1, #entries do
            local copy = {}
            for k, v in pairs(entries[i]) do copy[k] = v end
            copy.week = 2
            entries[#entries + 1] = copy
        end
    end
    dofile("HallOfFameUI.lua")
    Overlord.HallOfFameUI:Show()
end

local function sidebar()
    local out = {}
    for _, f in ipairs(buttons) do
        if f._shown then out[#out + 1] = (f.Button._hl and "*" or "") .. f._hofCategoryId end
    end
    return table.concat(out, ",")
end
local function button(id)
    for _, f in ipairs(buttons) do
        if f._shown and f._hofCategoryId == id then return f.Button end
    end
    error("no visible button " .. id)
end
local function click(id)
    local b = button(id)
    b._OnClick(b)
    return sidebar()
end

-- Shipped data: week 1 only, the beta is a plain category that stays highlighted.
load(false)
assert(sidebar() == "*beta,donors", "single week: " .. sidebar())
assert(button("beta").Label._text == "Bêta" and button("donors").Label._text == "Donateurs")
assert(click("beta") == "*beta,donors", "a single week has no sub-category")
assert(click("donors") == "beta,*donors")
assert(click("beta") == "*beta,donors", "back to the beta week")

-- Several weeks: collapsed at opening, expand / collapse like Retail.
load(true)
assert(sidebar() == "*beta,donors", "opens collapsed on the beta: " .. sidebar())
assert(click("beta") == "beta,*beta:2,beta:1,donors", "expand opens the newest week")
local week = button("beta:1")
assert(week.Label._text == "Semaine 1" and week._width == 145 and week.Label._color[1] == 1
    and week.Background._color[1] == 0.6, "child style")
assert(button("beta")._width == 160 and button("beta").Label._color[2] == 0.82, "parent style restored")
assert(click("beta:1") == "beta,beta:2,*beta:1,donors")
assert(click("beta") == "*beta,donors", "second click collapses, beta stays highlighted")
assert(click("beta") == "beta,beta:2,*beta:1,donors", "re-expanding keeps the shown week")
assert(click("donors") == "beta,*donors", "another category collapses the beta")
assert(button("donors")._width == 160 and button("donors").Background._color[1] == 1,
    "a pooled child frame reused as a parent got its style back")
assert(click("beta") == "beta,*beta:2,beta:1,donors", "from another category, expand opens the newest week")

print("Hall of Fame sidebar: collapsed at opening, expand/collapse like Retail, child style restored OK")
