-- 1.7.0 audit: the exact Recent activity text from Popups.lua, in all 7 languages:
-- kill bracket first, "1+ kill" under 5 kills, then capture brackets 1+/5+/10+;
-- the age only for a row without kill or capture (relay off).
local function stub()
    return setmetatable({}, { __index = function() return function() end end,
        __call = function() return nil end })
end
local function loadPopups(L)
    local e = setmetatable({}, { __index = function(_, k)
        local v = _G[k]
        if v ~= nil then return v end
        return stub()
    end })
    e._G = e
    e.Overlord = { L = L }
    setfenv(assert(loadfile("Popups.lua")), e)()
    return assert(e.Overlord.Popups.FormatFrontActivityText, "text formatter not exposed")
end

-- English (fallbacks and keys).
local format = loadPopups({})
assert(format(false, 30, 50, 3) == "...", "inactive row")
assert(format(true, 30, 23, 4) == "20+ kills")
assert(format(true, 200, 3, 12) == "1+ kill", "kills must come before captures")
assert(format(true, 200, 1, 0) == "1+ kill", "a single kill is 1+ kill")
assert(format(true, 200, 0, 1) == "1+ capture")
assert(format(true, 200, 0, 4) == "1+ capture")
assert(format(true, 200, 0, 5) == "5+ captures", "5 captures is the 5+ bracket")
assert(format(true, 200, 0, 7) == "5+ captures")
assert(format(true, 200, 0, 9) == "5+ captures" and format(true, 200, 0, 10) == "10+ captures")
assert(format(true, 200, 0, 15) == "10+ captures")
assert(format(true, 20, 0, 0) == "just now", "relay-off fallback")
assert(format(true, 130, 0, 0) == "2 min ago")

-- Every language defines the three new strings with the same placeholders.
local function collect(files)
    local found = {}
    for _, file in ipairs(files) do
        local text = assert(io.open(file, "rb")):read("*a")
        for key, value in text:gmatch('L%.([%u_]+)%s*=%s*"([^"]*)"') do
            found[key] = found[key] or {}
            found[key][#found[key] + 1] = value
        end
    end
    return found
end
local found = collect({ "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua" })
local kills = #(found.FEATURED_FRONT_ACTIVITY_KILLS or {})
assert(kills == 7, "expected 7 languages, found " .. kills)
for _, key in ipairs({ "FEATURED_FRONT_ACTIVITY_KILL_ONE", "FEATURED_FRONT_ACTIVITY_CAPTURE_ONE",
    "FEATURED_FRONT_ACTIVITY_CAPTURES" }) do
    local values = found[key] or {}
    assert(#values == kills, key .. " is missing in some languages (" .. #values .. "/" .. kills .. ")")
    for _, value in ipairs(values) do
        local slots = select(2, value:gsub("%%d", ""))
        assert(slots == (key == "FEATURED_FRONT_ACTIVITY_CAPTURES" and 1 or 0)
            and select(2, value:gsub("%%", "")) == slots, key .. " has a wrong placeholder: " .. value)
    end
end
-- A translated table is used as given (strings unlike the English fallbacks).
local fr = loadPopups({ FEATURED_FRONT_ACTIVITY_KILL_ONE = "1+ tué",
    FEATURED_FRONT_ACTIVITY_CAPTURES = "%d+ prises" })
assert(fr(true, 0, 2, 0) == "1+ tué" and fr(true, 0, 0, 6) == "5+ prises",
    tostring(fr(true, 0, 2, 0)) .. " / " .. tostring(fr(true, 0, 0, 6)))
-- A painted row: gold for 1+ kill / captures, and the value column widens (92..120 px)
-- for a long translation instead of cutting it.
local function fontString()
    local fs = { width = 92, text = "" }
    function fs:SetText(t) self.text = t end
    function fs:SetTextColor(r, g, b) self.color = { r, g, b } end
    function fs:SetWidth(w) self.width = w end
    -- Like a capped FontString: reports at most its own width unless unconstrained.
    function fs:GetStringWidth()
        local full = #self.text * 7
        if self.width and self.width > 0 then return math.min(full, self.width) end
        return full
    end
    return fs
end
local function paint(L, kills, captures, unbounded)
    local e = setmetatable({}, { __index = function(_, k)
        local v = _G[k]
        if v ~= nil then return v end
        return stub()
    end })
    e._G = e
    e.Overlord = { L = L }
    setfenv(assert(loadfile("Popups.lua")), e)()
    local paintRow = assert(e.Overlord.Popups.SetFeaturedFrontActivityRowForTest, "row painter not exposed")
    local row = { valueFs = fontString(), nameFs = fontString(), star = stub(), frontIcon = stub(),
        content = stub(), Show = function() end }
    if unbounded then
        -- Modern clients: the unbounded measure is used and the width is never zeroed.
        local fs = row.valueFs
        function fs:GetUnboundedStringWidth() return #self.text * 7 end
        local setWidth = fs.SetWidth
        function fs:SetWidth(w) assert(w ~= 0, "width zeroed despite GetUnboundedStringWidth"); setWidth(self, w) end
    end
    paintRow(row, "ashenvale", "Ashenvale", true, 200, false, kills, captures)
    return row.valueFs
end
local de = paint({ FEATURED_FRONT_ACTIVITY_CAPTURES = "%d+ Eroberungen" }, 0, 12)
assert(de.text == "10+ Eroberungen", de.text)
assert(de.width == #"10+ Eroberungen" * 7 + 2, "long text not given its full room: " .. tostring(de.width))
local deUnbounded = paint({ FEATURED_FRONT_ACTIVITY_CAPTURES = "%d+ Eroberungen" }, 0, 12, true)
assert(deUnbounded.width == #"10+ Eroberungen" * 7 + 2, "unbounded measure: " .. tostring(deUnbounded.width))
-- Never wider than 120 px: a very long translation is cut, not allowed to eat the name.
local long = paint({ FEATURED_FRONT_ACTIVITY_CAPTURES = "%d+ very long capture wording here" }, 0, 12)
assert(long.width == 120, "the value column grew past 120 px: " .. tostring(long.width))
local short = paint({}, 1, 0)
assert(short.text == "1+ kill" and short.width == 92, "short text changed the column: " .. tostring(short.width))
assert(short.color[1] == 1 and short.color[2] == 0.82, "1+ kill is not gold")
local caps = paint({}, 0, 3)
assert(caps.color[1] == 1 and caps.color[2] == 0.82, "captures are not gold")
print("Front activity text: kills first, 1+ kill, capture brackets, relay-off age, 7 locales OK")
