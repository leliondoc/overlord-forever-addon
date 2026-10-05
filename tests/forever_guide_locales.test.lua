-- Tutorial text: every locale gets every page key in its own language, with the
-- format slots Popups.lua fills (keep icons + hold minutes, mine list, release time).
local files = { "Locales.lua", "GuideLocales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua",
    "ForeverLocaleFixes.lua", "FrontLocales.lua" }
local guideKeys = {
    "GUIDE_BTN_TOOLTIP", "GUIDE_PAGE1_TITLE", "GUIDE_PAGE2_TITLE", "GUIDE_PAGE3_TITLE",
    "GUIDE_SECTION_TRAVEL", "GUIDE_TRAVEL_ALLIANCE", "GUIDE_TRAVEL_HORDE",
    "GUIDE_SECTION_RULES", "GUIDE_RULES_BODY", "GUIDE_SECTION_PROGRESS", "GUIDE_PROGRESS_BODY",
    "GUIDE_SECTION_SHARD", "GUIDE_SHARD_BODY", "GUIDE_SECTION_PANEL", "GUIDE_PANEL_BODY",
    "GUIDE_SECTION_OPTIONS", "GUIDE_OPTIONS_BODY", "GUIDE_SECTION_CONTEST", "GUIDE_CONTEST_BODY",
    "GUIDE_SECTION_SIEGE", "GUIDE_SIEGE_BODY", "GUIDE_SECTION_GOLD", "GUIDE_GOLD_BODY",
    "GUIDE_SECTION_FEATURED", "GUIDE_FEATURED_BODY", "GUIDE_SECTION_GUILD_KEEP",
    "GUIDE_GUILD_KEEP_BODY", "GUIDE_SECTION_OUTPOST", "GUIDE_OUTPOST_BODY",
    "GUIDE_SECTION_FACTION_CALL", "GUIDE_FACTION_CALL_BODY", "GUIDE_SECTION_ALERTS",
    "GUIDE_ALERTS_BODY", "GUIDE_SECTION_TOOLS", "GUIDE_TOOLS_BODY",
    "GUIDE_BAR_LABEL", "GUIDE_TITLE", "GUIDE_CLOSE", "GUIDE_NEXT", "GUIDE_PREV",
    "GUIDE_PAGE_INDICATOR", "FRONT_CAPITAL_RELEASED", "CAPITAL_PROTECTED_UNTIL",
    "CAPITAL_PROTECTED_SHORT", "FORTRESS_CAPTURE_AVAILABLE", "FRONT_TRUCE_ENDED_FIGHT",
}

local function countSlots(text, slot)
    local n = 0
    for _ in text:gmatch("%%" .. slot) do n = n + 1 end
    return n
end

local english
for _, loc in ipairs({ "enUS", "frFR", "esES", "esMX", "deDE", "ruRU", "ptBR", "zhCN", "zhTW" }) do
    Overlord = { L = {} }
    GetLocale = function() return loc end
    for _, file in ipairs(files) do assert(loadfile(file))() end
    local L = Overlord.L
    for _, key in ipairs(guideKeys) do
        assert(type(L[key]) == "string" and L[key] ~= "", loc .. " misses " .. key)
    end
    assert(countSlots(L.GUIDE_GUILD_KEEP_BODY, "s") == 1 and countSlots(L.GUIDE_GUILD_KEEP_BODY, "d") == 1,
        loc .. ": keep text needs one icon slot and one minutes slot")
    assert(string.format(L.GUIDE_GUILD_KEEP_BODY, "ICONS", 10):find("ICONS", 1, true))
    assert(countSlots(L.GUIDE_GOLD_BODY, "s") == 1, loc .. ": mine text needs one list slot")
    assert(countSlots(L.FRONT_CAPITAL_RELEASED, "s") == 2, loc .. ": release line needs front + time")
    assert(countSlots(L.FRONT_TRUCE_ENDED_FIGHT, "s") == 1, loc .. ": Hillsbrad truce-end line needs the front")
    assert(string.format(L.CAPITAL_PROTECTED_UNTIL, "21:40"):find("21:40", 1, true))
    assert(string.format(L.CAPITAL_PROTECTED_SHORT, "21:40"):find("21:40", 1, true))
    -- The protection length shown to players matches the code (6 h), the call to arms 4 h.
    -- Whole numbers only (a "16" or "24" would not do).
    assert(L.GUIDE_SIEGE_BODY:find("%f[%d]6%f[%D]"), loc .. ": siege text lost the protection length")
    assert(L.GUIDE_FACTION_CALL_BODY:find("%f[%d]4%f[%D]"), loc .. ": call to arms lost its cooldown")
    -- The 15-minute truce, on every front and on the Hillsbrad brawl (no protection there).
    assert(L.GUIDE_SIEGE_BODY:find("%f[%d]15%f[%D]"), loc .. ": siege text lost the truce length")
    assert(L.GUIDE_PROGRESS_BODY:find("%f[%d]15%f[%D]"), loc .. ": guide lost the Hillsbrad note")
    -- Commands are quoted exactly as Commands.lua parses them, after every later locale
    -- fix (an old Shard -> Layer rewrite once turned /ov layer into /ov shard).
    for _, cmd in ipairs({ { "GUIDE_SHARD_BODY", "/ov layer help on" }, { "GUIDE_SHARD_BODY", "/ov network" },
        { "GUIDE_PANEL_BODY", "/ov show" }, { "GUIDE_PANEL_BODY", "/ov guide" },
        { "GUIDE_OPTIONS_BODY", "/ov lb" }, { "GUIDE_ALERTS_BODY", "/ov wanted" },
        { "GUIDE_ALERTS_BODY", "/ov guildkills" } }) do
        assert(L[cmd[1]]:find(cmd[2], 1, true), loc .. ": " .. cmd[1] .. " lost the command " .. cmd[2])
    end
    assert(not L.GUIDE_SHARD_BODY:find("/ov shard", 1, true), loc .. ": guide points to /ov shard")
    -- The guide names the buttons exactly as the panel shows them in that language
    -- (zhTW reads the zhCN guide over an English interface: skipped).
    if loc ~= "zhTW" then
        local function mentions(body, label, what)
            assert(type(label) == "string" and label ~= "", loc .. " has no " .. what .. " label")
            assert(body:find(label, 1, true), loc .. ": guide does not name " .. what .. " as '" .. label .. "'")
        end
        mentions(L.GUIDE_FACTION_CALL_BODY, L.FACTION_CALL_BUTTON, "Call to arms")
        mentions(L.GUIDE_FACTION_CALL_BODY, L.GENERAL_BUTTON, "Command")
        mentions(L.GUIDE_PANEL_BODY, L.HOF_BUTTON, "Hall of Fame")
        mentions(L.GUIDE_TOOLS_BODY, L.HOF_BUTTON, "Hall of Fame")
        mentions(L.GUIDE_PANEL_BODY, L.GOLD_BARRICADE, "Reinforce")
        mentions(L.GUIDE_PANEL_BODY, L.GOLD_REINFORCE, "Attack")
        mentions(L.GUIDE_OPTIONS_BODY, L.MINIMAP_CAPTURE_ZONES_LABEL, "Minimap icons")
        mentions(L.GUIDE_SHARD_BODY, L.LAYER_JUMPER_BUTTON, "Layer Jumper")
        mentions(L.GUIDE_SHARD_BODY, (L.LJ_HELP_MODE or ""):match("^(.-)%s*[:：]") or "", "Help others")
    end
    if loc == "enUS" then
        english = {}
        for _, key in ipairs(guideKeys) do english[key] = L[key] end
    else
        -- A translated locale never falls back to the English tutorial body.
        for _, key in ipairs({ "GUIDE_RULES_BODY", "GUIDE_SIEGE_BODY", "GUIDE_GUILD_KEEP_BODY",
            "GUIDE_ALERTS_BODY", "GUIDE_TOOLS_BODY" }) do
            assert(L[key] ~= english[key], loc .. " shows the English " .. key)
        end
    end
end
print("Forever guide locales: every page key, format slot and translation present")
