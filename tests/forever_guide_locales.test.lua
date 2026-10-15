-- Tutorial text: every locale gets every page key in its own language, with the
-- format slots Popups.lua fills (keep icons + hold minutes, mine list, release time).
local files = { "Locales.lua", "GuideLocales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua",
    "ForeverLocaleFixes.lua", "FrontLocales.lua", "GroupFinderLocales.lua" }
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
    "GUIDE_SECTION_GROUPS", "GUIDE_GROUPS_BODY",
    "GUIDE_SECTION_RANKS", "GUIDE_RANKS_BODY",
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
    -- 1.8.1 ranking sync badge: every locale has its texts; the progress line keeps
    -- one step number and one entry count.
    for _, key in ipairs({ "LB_SYNC_RECEIVING", "LB_SYNC_DONE", "LB_SYNC_TIP_RECEIVING",
        "LB_SYNC_TIP_DONE", "LB_SYNC_TIP_PROGRESS" }) do
        assert(type(L[key]) == "string" and L[key] ~= "", loc .. " misses " .. key)
    end
    assert(countSlots(L.LB_SYNC_TIP_PROGRESS, "d") == 1 and countSlots(L.LB_SYNC_TIP_PROGRESS, "s") == 1,
        loc .. ": badge progress line needs one %d and one %s")
    assert(string.format(L.LB_SYNC_TIP_PROGRESS, 2, "1,234"):find("1,234", 1, true))
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
        "LB_TOTAL_FORMAT", "LB_GUILD_TIP_TOTAL", "MW_ALERT" }) do
        assert(type(L[key]) == "string" and L[key]:find(unit, 1, true),
            loc .. ": " .. key .. " does not use " .. unit .. ": " .. tostring(L[key]))
    end
    -- 2.0.3: the locked-point message has a variant without the truce, shown once it is
    -- retired; same slot for the point's name, no word of a truce.
    local blocked = L.CAPTURE_BLOCKED_RULES_NOTRUCE
    assert(type(blocked) == "string" and blocked ~= L.CAPTURE_BLOCKED_RULES and countSlots(blocked, "s") == 1,
        loc .. ": no locked-point message without the truce")
    for _, word in ipairs({ "truce", "trêve", "tregua", "Waffenstillstand", "перемир", "trégua", "休战" }) do
        assert(not blocked:find(word, 1, true), loc .. ": CAPTURE_BLOCKED_RULES_NOTRUCE still names the truce")
    end
    -- The 15-minute truce, on every front.
    assert(L.GUIDE_SIEGE_BODY:find("%f[%d]15%f[%D]"), loc .. ": siege text lost the truce length")
    -- 2.0.3: Hillsbrad is a front like the others. The progress text names it with the
    -- six other fronts and no longer has a brawl line (nor a truce of its own).
    assert(L.GUIDE_PROGRESS_BODY_NOTRUCE == nil, loc .. ": the progress text still has a truce variant")
    assert(not L.GUIDE_PROGRESS_BODY:find("%f[%d]15%f[%D]"), loc .. ": the progress text still gives a truce length")
    local _, progressLines = L.GUIDE_PROGRESS_BODY:gsub("\n", "")
    assert(progressLines == 2, loc .. ": the progress text should keep three lines, not " .. (progressLines + 1))
    assert(not L.GUIDE_PROGRESS_BODY:find(L.ZONE_NAMES.hillsbrad_tarren_mill, 1, true),
        loc .. ": the progress text still describes the Southshore / Tarren Mill brawl")
    -- Named with the other fronts; its first letter may be lower case in the list
    -- ("contreforts de Hautebrande"), so the first UTF-8 character is left out.
    -- zhTW has no front names of its own (English) next to a Chinese tutorial.
    if loc ~= "zhTW" then
        local tail = L.FRONT_HILLSBRAD_NAME:gsub("^[%z\1-\127\194-\244][\128-\191]*", "")
        assert(L.GUIDE_PROGRESS_BODY:find(tail, 1, true),
            loc .. ": the progress text does not list " .. L.FRONT_HILLSBRAD_NAME .. " with the other fronts")
    end
    assert(not L.GUIDE_OUTPOST_BODY:find(L.ZONE_NAMES.hillsbrad_tarren_mill, 1, true),
        loc .. ": the outpost text still says Hillsbrad has none")
    -- 2.0.2: the siege text without the truce, shown once it is retired
    -- (Zones.TRUCELESS_FROM). Same lines, the fifteen minutes gone, nothing else.
    for _, key in ipairs({ "GUIDE_SIEGE_BODY" }) do
        local with, without = L[key], L[key .. "_NOTRUCE"]
        assert(type(without) == "string" and without ~= with, loc .. ": " .. key .. " has no text without the truce")
        assert(not without:find("%f[%d]15%f[%D]"), loc .. ": " .. key .. "_NOTRUCE still gives the truce length")
        local _, linesWith = with:gsub("\n", "")
        local _, linesWithout = without:gsub("\n", "")
        assert(linesWith == linesWithout, loc .. ": " .. key .. "_NOTRUCE lost or gained a line")
        assert(#without < #with and #without > #with - 80, loc .. ": " .. key .. "_NOTRUCE changed more than the truce")
    end
    -- Commands are quoted exactly as Commands.lua parses them, after every later locale
    -- fix (an old Shard -> Layer rewrite once turned /ov layer into /ov shard).
    for _, cmd in ipairs({ { "GUIDE_SHARD_BODY", "/ov network" },
        { "GUIDE_PANEL_BODY", "/ov show" }, { "GUIDE_PANEL_BODY", "/ov guide" },
        { "GUIDE_OPTIONS_BODY", "/ov lb" },
        { "GUIDE_ALERTS_BODY", "/ov guildkills" } }) do
        assert(L[cmd[1]]:find(cmd[2], 1, true), loc .. ": " .. cmd[1] .. " lost the command " .. cmd[2])
    end
    assert(not L.GUIDE_SHARD_BODY:find("/ov shard", 1, true), loc .. ": guide points to /ov shard")
    -- 2.0.4: the Nemesis alerts live in the options only (no command).
    assert(not L.GUIDE_ALERTS_BODY:find("/ov wanted", 1, true) and not L.GUIDE_ALERTS_BODY:find("/ov nemesis", 1, true),
        loc .. ": guide points to a removed Nemesis command")
    -- Layer Jumper removed in 1.6.1, its greyed button replaced by the PvP group finder:
    -- no text of it is left, and the guide never sends players to it.
    assert(not L.GUIDE_SHARD_BODY:find("/ov layer", 1, true)
        and not L.GUIDE_SHARD_BODY:find("Layer Jumper", 1, true), loc .. ": guide still offers the Layer Jumper")
    assert(not L.GUIDE_PANEL_BODY:find("Layer Jumper", 1, true),
        loc .. ": the panel guide still lists the removed Layer Jumper button")
    assert(L.HELP_LAYER == nil, loc .. ": /ov help still advertises /ov layer")
    assert(L.LAYER_JUMPER_BUTTON == nil and L.LAYER_JUMPER_REMOVED == nil,
        loc .. ": a Layer Jumper text is still defined")
    -- PvP group finder: its guide section quotes the command and the two-minute rule (2.0.3).
    assert(L.GUIDE_GROUPS_BODY:find("/ov groups", 1, true), loc .. ": groups section lost its command")
    assert(L.GUIDE_GROUPS_BODY:find("%f[%d]2%f[%D]") and not L.GUIDE_GROUPS_BODY:find("%f[%d]5%f[%D]"),
        loc .. ": groups section does not give the two-minute wait")
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
        mentions(L.GUIDE_PANEL_BODY, L.GF_BUTTON, "PvP Groups")
        mentions(L.GUIDE_GROUPS_BODY, L.GF_BUTTON, "PvP Groups")
    end
    if loc == "enUS" then
        english = {}
        for _, key in ipairs(guideKeys) do english[key] = L[key] end
    else
        -- A translated locale never falls back to the English tutorial body.
        for _, key in ipairs({ "GUIDE_RULES_BODY", "GUIDE_SIEGE_BODY", "GUIDE_GUILD_KEEP_BODY",
            "GUIDE_ALERTS_BODY", "GUIDE_TOOLS_BODY", "GUIDE_GROUPS_BODY" }) do
            assert(L[key] ~= english[key], loc .. " shows the English " .. key)
        end
    end
end
print("Forever guide locales: every page key, format slot and translation present")
