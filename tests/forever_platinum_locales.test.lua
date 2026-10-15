-- 2.0.4: the mines' currency is Platinum in every language. No currency string may still
-- say "coin(s)", "moeda(s)" or 币 (the old Chinese word), and the tutorial and options
-- name the Nemesis, never "Most Wanted".
local FILES = { "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua", "ForeverLocaleFixes.lua", "GuideLocales.lua" }
local CURRENCY_KEYS = { "GOLD_", "MINE_", "GUIDE_SECTION_GOLD", "GUIDE_GOLD_BODY", "GUIDE_FEATURED_BODY",
    "GUIDE_ALERTS_BODY", "GUIDE_PANEL_BODY", "SOUND_ENABLED_TOOLTIP", "MAP_OVERLAY_OPACITY_TOOLTIP",
    "MINIMAP_OVERLAY_OPACITY_TOOLTIP" }

local checked = 0
for _, path in ipairs(FILES) do
    local f = assert(io.open(path, "rb"), "cannot read " .. path)
    local n = 0
    for line in f:lines() do
        n = n + 1
        local isCurrency = false
        for _, key in ipairs(CURRENCY_KEYS) do
            if line:find(key, 1, true) then isCurrency = true break end
        end
        if isCurrency and line:find('"', 1, true) then
            checked = checked + 1
            assert(not line:find("[Cc]oins?%f[^%a]"), path .. ":" .. n .. " still names the currency coin")
            assert(not line:find("[Mm]oedas?"), path .. ":" .. n .. " still names the currency moeda")
            assert(not line:find("币", 1, true), path .. ":" .. n .. " still names the currency 币")
        end
        assert(not (line:find("Most Wanted", 1, true) and line:find('"', 1, true) and not line:find("^%s*%-%-")),
            path .. ":" .. n .. " still says Most Wanted")
    end
    f:close()
end
assert(checked > 60, "too few currency strings checked: " .. checked)
print("Platinum locales: no coin, moeda or 币 left in " .. checked .. " currency strings, no Most Wanted OK")
