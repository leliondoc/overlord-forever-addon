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
    "GUIDE_PAGE_INDICATOR", "FRONT_TRUCE_ENDED_KEPT", "FRONT_CAPITAL_LIBERATED",
    "FRONT_VICTORY_TOO_SOON", "FORTRESS_CAPTURE_AVAILABLE",
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
    -- 1.7: the fallen capital stays taken; liberation and the 6 h victory spacing.
    assert(countSlots(L.FRONT_TRUCE_ENDED_KEPT, "s") == 1, loc .. ": truce-end line needs the front")
    assert(countSlots(L.FRONT_CAPITAL_LIBERATED, "s") == 2, loc .. ": liberation line needs capital + front")
    assert(countSlots(L.FRONT_VICTORY_TOO_SOON, "s") == 2, loc .. ": too-soon line needs front + time")
    assert(string.format(L.FRONT_VICTORY_TOO_SOON, "F", "21:40"):find("21:40", 1, true))
    -- The victory spacing shown to players matches the code (6 h), the call to arms 4 h.
    -- Whole numbers only (a "16" or "24" would not do).
    assert(L.GUIDE_SIEGE_BODY:find("%f[%d]6%f[%D]"), loc .. ": siege text lost the victory spacing")
    assert(L.GUIDE_FACTION_CALL_BODY:find("%f[%d]4%f[%D]"), loc .. ": call to arms lost its cooldown")
    -- No text still promises the old capital protection (gone in 1.7.0).
    for _, key in ipairs({ "GUIDE_SIEGE_BODY", "GUIDE_PROGRESS_BODY", "CAPTURE_BLOCKED_RULES" }) do
        local text = L[key] or "" -- no string.lower: it can mangle UTF-8 bytes
        for _, stem in ipairs({ "protect", "Protect", "protecc", "Protecc", "proteç", "Proteç", "protég", "Protég", "protegid", "proteg", "geschützt", "schutz", "Schutz",
            "защищ", "защит", "保护", "immun" }) do
            assert(not text:find(stem, 1, true), loc .. ": " .. key .. " still mentions " .. stem)
        end
    end
    -- Honorable kills are written like the ladder column in every language (HK, VH,
    -- MH, ES, ПП, 击杀): they are shared by the whole group, not deaths (1.7.1).
    local unit = L.LB_COL_KILLS
    assert(type(unit) == "string" and unit ~= "", loc .. ": no ladder kill column label")
    for _, key in ipairs({ "FEATURED_FRONT_ACTIVITY_KILLS", "FEATURED_FRONT_ACTIVITY_KILL_ONE",
        "GUILD_KILL_ALERT", "GUILD_KILL_ALERT_FRONT", "GUILD_KILL_ALLY_ALERT", "GUILD_KILL_ALLY_ALERT_FRONT",
        "LB_TOTAL_FORMAT", "LB_GUILD_TIP_TOTAL", "MW_ALERT", "POPUP_BATTLE_REPORT_GUILD" }) do
        assert(type(L[key]) == "string" and L[key]:find(unit, 1, true),
            loc .. ": " .. key .. " does not use " .. unit .. ": " .. tostring(L[key]))
    end
    -- The 15-minute truce, on every front and on the Hillsbrad brawl.
    assert(L.GUIDE_SIEGE_BODY:find("%f[%d]15%f[%D]"), loc .. ": siege text lost the truce length")
    assert(L.GUIDE_PROGRESS_BODY:find("%f[%d]15%f[%D]"), loc .. ": guide lost the Hillsbrad note")
    -- Commands are quoted exactly as Commands.lua parses them, after every later locale
    -- fix (an old Shard -> Layer rewrite once turned /ov layer into /ov shard).
    for _, cmd in ipairs({ { "GUIDE_SHARD_BODY", "/ov network" },
        { "GUIDE_PANEL_BODY", "/ov show" }, { "GUIDE_PANEL_BODY", "/ov guide" },
        { "GUIDE_OPTIONS_BODY", "/ov lb" }, { "GUIDE_ALERTS_BODY", "/ov wanted" },
        { "GUIDE_ALERTS_BODY", "/ov guildkills" } }) do
        assert(L[cmd[1]]:find(cmd[2], 1, true), loc .. ": " .. cmd[1] .. " lost the command " .. cmd[2])
    end
    assert(not L.GUIDE_SHARD_BODY:find("/ov shard", 1, true), loc .. ": guide points to /ov shard")
    -- Layer Jumper removed in 1.6.1: the guide no longer sends players to it, and its
    -- greyed button explains why in every language.
    assert(not L.GUIDE_SHARD_BODY:find("/ov layer", 1, true)
        and not L.GUIDE_SHARD_BODY:find("Layer Jumper", 1, true), loc .. ": guide still offers the Layer Jumper")
    assert(not L.GUIDE_PANEL_BODY:find(L.LAYER_JUMPER_BUTTON, 1, true),
        loc .. ": the panel guide still lists the removed Layer Jumper button")
    assert(L.HELP_LAYER == nil, loc .. ": /ov help still advertises /ov layer")
    assert(type(L.LAYER_JUMPER_REMOVED) == "string" and #L.LAYER_JUMPER_REMOVED > 40,
        loc .. ": the greyed Layer Jumper button has no explanation")
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
    end
    if loc == "enUS" then
        english = {}
        for _, key in ipairs(guideKeys) do english[key] = L[key] end
        english.LAYER_JUMPER_REMOVED = L.LAYER_JUMPER_REMOVED
    else
        -- A translated locale never falls back to the English tutorial body.
        for _, key in ipairs({ "GUIDE_RULES_BODY", "GUIDE_SIEGE_BODY", "GUIDE_GUILD_KEEP_BODY",
            "GUIDE_ALERTS_BODY", "GUIDE_TOOLS_BODY" }) do
            assert(L[key] ~= english[key], loc .. " shows the English " .. key)
        end
        -- zhTW plays with the English interface: its greyed button reads English too.
        if loc ~= "zhTW" then
            assert(L.LAYER_JUMPER_REMOVED ~= english.LAYER_JUMPER_REMOVED,
                loc .. " shows the English Layer Jumper explanation")
        end
    end
end
print("Forever guide locales: every page key, format slot and translation present")
